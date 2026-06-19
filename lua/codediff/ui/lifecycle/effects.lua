-- Effects ledger for diff sessions
-- Tracks buffer-local keymaps and window options set by codediff,
-- capturing the prior state before each change so it can be restored on cleanup.
-- All writes go through this module; direct vim.keymap.set / vim.wo writes
-- are deferred to later phases that reroute existing call sites.
local M = {}

-- ============================================================================
-- KEYMAP LEDGER
-- Data model: sess.effects.keymaps[bufnr][mode][canon_lhs] = {mode, lhs, prev, owned}
-- canon_lhs is lhs resolved through nvim_replace_termcodes once at set-time.
-- This makes the ledger key and the vim.keymap.del call resolution-stable: if
-- mapleader/maplocalleader changes between set and restore, the canonical form
-- is used for del rather than re-resolving <leader> at del-time.
-- prev is the maparg dict captured before the first write, or nil if no prior map.
-- ============================================================================

--- Resolve lhs to the canonical internal form Neovim uses to store keymaps.
--- Expands <leader>, <localleader>, and all termcodes once, at call time.
---@param lhs string
---@return string
local function canon_lhs(lhs)
  return vim.api.nvim_replace_termcodes(lhs, true, true, true)
end

--- Set a buffer-local keymap and record the prior mapping in the ledger.
--- opts MUST include buffer = <bufnr>.
--- mode may be a string or a list of strings; multi-mode fans out to one
--- ledger entry per mode.
--- First capture wins: if an entry already exists for (bufnr, mode, canon_lhs)
--- the prev is not overwritten, but the rhs is updated by re-calling vim.keymap.set.
---@param sess table  diff session (must have sess.effects)
---@param mode string|table  keymap mode(s)
---@param lhs string  left-hand side (may contain <leader>/<localleader>/termcodes)
---@param rhs string|function  right-hand side
---@param opts table  must contain buffer = bufnr
function M.set_keymap(sess, mode, lhs, rhs, opts)
  local bufnr = opts and opts.buffer
  if not bufnr then
    error("effects.set_keymap: opts.buffer is required")
  end

  -- Fan out multi-mode
  if type(mode) == "table" then
    for _, m in ipairs(mode) do
      M.set_keymap(sess, m, lhs, rhs, opts)
    end
    return
  end

  -- Resolve lhs once at set-time; this is the stable ledger key and the form
  -- used for vim.keymap.del in restore_buffer.
  local key = canon_lhs(lhs)

  local keymaps = sess.effects.keymaps
  if not keymaps[bufnr] then
    keymaps[bufnr] = {}
  end
  if not keymaps[bufnr][mode] then
    keymaps[bufnr][mode] = {}
  end

  local entry = keymaps[bufnr][mode][key]
  if not entry then
    -- First time: capture the prior mapping in buffer context using the canonical
    -- form so maparg and del both operate on the same resolved string.
    local prev = nil
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_call(bufnr, function()
        local dict = vim.fn.maparg(key, mode, false, true)
        -- An empty dict means no prior map exists
        if next(dict) ~= nil then
          prev = dict
        end
      end)
    end
    keymaps[bufnr][mode][key] = { mode = mode, lhs = key, prev = prev, owned = true }
  end
  -- Always (re-)apply the keymap (updates rhs on repeated calls).
  -- Use the canonical lhs (already expanded via nvim_replace_termcodes) so that
  -- a mid-session mapleader change cannot cause a second binding under the raw
  -- form to leak alongside the ledger-tracked canonical-form binding.
  vim.keymap.set(mode, key, rhs, opts)
end

-- ============================================================================
-- WINDOW-OPTION LEDGER
-- Data model: sess.effects.win_opts[win][option] = {win, option, prev, epoch}
-- epoch is compared against vim.w[win].codediff_effects_epoch to guard recycle.
-- ============================================================================

--- Set a window option and record the prior value in the ledger.
--- First capture wins: subsequent calls to the same (win, option) update the
--- option value but do NOT overwrite the captured prev.
---@param sess table  diff session (must have sess.effects + sess.effects_epoch)
---@param win number  window handle
---@param option string  window option name
---@param value any  new value
function M.set_win_opt(sess, win, option, value)
  local win_opts = sess.effects.win_opts
  if not win_opts[win] then
    win_opts[win] = {}
  end

  if not win_opts[win][option] then
    -- First capture
    local prev = vim.wo[win][option]
    win_opts[win][option] = { win = win, option = option, prev = prev, epoch = sess.effects_epoch }
    -- Stamp the window so restore_window can guard against winid recycle
    vim.w[win].codediff_effects_epoch = sess.effects_epoch
  end
  vim.wo[win][option] = value
end

-- ============================================================================
-- RESTORE FUNCTIONS
-- ============================================================================

--- Restore all keymaps set on a single buffer, then drop its ledger entries.
---@param sess table
---@param bufnr number
function M.restore_buffer(sess, bufnr)
  local keymaps = sess.effects.keymaps
  local buf_entries = keymaps[bufnr]
  if not buf_entries then
    return
  end

  if not vim.api.nvim_buf_is_valid(bufnr) then
    keymaps[bufnr] = nil
    return
  end

  for mode, lhs_map in pairs(buf_entries) do
    for lhs, entry in pairs(lhs_map) do
      -- Always delete the buffer-local map codediff set first. This is required
      -- even when restoring a prior map: if the prior map was global (buffer=0),
      -- calling mapset() inside nvim_buf_call restores the global but leaves the
      -- buffer-local codediff map shadowing it. Deleting first ensures a clean
      -- slate before the optional mapset.
      pcall(vim.keymap.del, mode, lhs, { buffer = bufnr })

      if entry.prev ~= nil then
        -- Restore the original mapping. mapset must run in buffer context so
        -- the buffer-local scope is applied correctly (mirrors the capture path
        -- which also uses nvim_buf_call).
        local prev = entry.prev
        pcall(vim.api.nvim_buf_call, bufnr, function()
          vim.fn.mapset(mode, false, prev)
        end)
      end
      -- No prior map: the pcall(vim.keymap.del) above is sufficient.
    end
  end

  keymaps[bufnr] = nil
end

--- Restore window options for a single window, then drop its ledger entries.
--- Only restores if the window is valid AND its epoch matches the session epoch
--- (guards against winid recycle).
---@param sess table
---@param win number
function M.restore_window(sess, win)
  local win_opts = sess.effects.win_opts
  local win_entries = win_opts[win]
  if not win_entries then
    return
  end

  if vim.api.nvim_win_is_valid(win) and vim.w[win].codediff_effects_epoch == sess.effects_epoch then
    for option, entry in pairs(win_entries) do
      pcall(function()
        vim.wo[win][option] = entry.prev
      end)
    end
  end

  win_opts[win] = nil
end

--- Restore all buffers that have keymap ledger entries.
---@param sess table
function M.restore_keymaps(sess)
  local keymaps = sess.effects.keymaps
  -- Collect keys first to avoid modifying during iteration
  local bufnrs = {}
  for bufnr in pairs(keymaps) do
    table.insert(bufnrs, bufnr)
  end
  for _, bufnr in ipairs(bufnrs) do
    M.restore_buffer(sess, bufnr)
  end
end

--- Restore all windows that have option ledger entries.
---@param sess table
function M.restore_window_opts(sess)
  local win_opts = sess.effects.win_opts
  local wins = {}
  for win in pairs(win_opts) do
    table.insert(wins, win)
  end
  for _, win in ipairs(wins) do
    M.restore_window(sess, win)
  end
end

--- Restore all effects (keymaps + window options).
---@param sess table
function M.restore_all(sess)
  M.restore_keymaps(sess)
  M.restore_window_opts(sess)
end

--- Named alias for restore_buffer; used by later phases when detaching a buffer
--- from a session (e.g. on file-switch).
---@param sess table
---@param bufnr number
function M.detach_buffer(sess, bufnr)
  M.restore_buffer(sess, bufnr)
end

--- Pre-seed the ledger with a known prior value captured before any codediff write.
--- Used when create_session runs AFTER the first raw window-option write (e.g. in
--- side_by_side.lua / inline_view.lua where buffers are prepared before async render).
--- If an entry for (win, option) already exists, this is a no-op (capture-once holds).
--- Applies current_value to the window.
---@param sess table  diff session (must have sess.effects + sess.effects_epoch)
---@param win number  window handle
---@param option string  window option name
---@param user_prev any  value captured from the window BEFORE any codediff write
---@param current_value any  the codediff value to apply (re-applies same value as the raw write)
function M.preseed_win_opt(sess, win, option, user_prev, current_value)
  local win_opts = sess.effects.win_opts
  if not win_opts[win] then
    win_opts[win] = {}
  end
  if not win_opts[win][option] then
    win_opts[win][option] = { win = win, option = option, prev = user_prev, epoch = sess.effects_epoch }
    vim.w[win].codediff_effects_epoch = sess.effects_epoch
  end
  vim.wo[win][option] = current_value
end

--- Return a flat snapshot of all effects currently recorded in the ledger.
--- Read-only; does not modify any state. Useful for live-session leak debugging
--- and in test assertions that need to verify ledger contents without triggering
--- restore paths.
---
--- Returns a table with two lists:
---   keymaps: array of { bufnr, mode, lhs, has_prev }
---   win_opts: array of { win, option, prev, epoch }
---
--- has_prev = true means a prior user mapping was captured and will be restored;
--- false means the lhs had no prior mapping (codediff simply added one).
---@param sess table  diff session (must have sess.effects)
---@return { keymaps: table[], win_opts: table[] }
function M.describe(sess)
  local result = { keymaps = {}, win_opts = {} }
  for bufnr, modes in pairs(sess.effects.keymaps) do
    for mode, lhs_map in pairs(modes) do
      for lhs, entry in pairs(lhs_map) do
        table.insert(result.keymaps, {
          bufnr = bufnr,
          mode = mode,
          lhs = lhs,
          has_prev = entry.prev ~= nil,
        })
      end
    end
  end
  for win, opts in pairs(sess.effects.win_opts) do
    for option, entry in pairs(opts) do
      table.insert(result.win_opts, {
        win = win,
        option = option,
        prev = entry.prev,
        epoch = entry.epoch,
      })
    end
  end
  return result
end

return M
