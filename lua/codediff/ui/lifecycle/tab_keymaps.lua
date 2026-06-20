-- Tab-wide keymap management for diff sessions.
-- Sets a keymap on every buffer that belongs to a diff tab (both diff buffers,
-- explorer, result) and tears them all down again on close. Every set/clear is
-- routed through the effects ledger so the prior mapping is captured before it
-- is overwritten and restored on cleanup.
local M = {}

-- Eager require: effects.lua has no circular dependencies; loading it up front
-- avoids a lazy-require failure when an autocmd fires after a `cd` changes CWD.
local effects_ledger = require("codediff.ui.lifecycle.effects")

-- Lazy require to avoid circular dependency: init → session → accessors → session
local function get_active_diffs()
  return require("codediff.ui.lifecycle.session").get_active_diffs()
end

--- Set a keymap on all buffers in the diff tab (both diff buffers + explorer + result)
--- This is the unified API for setting tab-wide keymaps.
--- Each vim.keymap.set call is routed through the effects ledger so the prior
--- mapping is captured before being overwritten and can be restored on cleanup.
--- @param tabpage number Tab page ID
--- @param mode string Keymap mode ('n', 'v', etc.)
--- @param lhs string Left-hand side of the keymap
--- @param rhs function|string Right-hand side (callback or command)
--- @param opts? table Optional keymap options (will be merged with buffer-local defaults)
--- @return boolean success True if keymaps were set
function M.set_tab_keymap(tabpage, mode, lhs, rhs, opts)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  opts = opts or {}
  local base_opts = { noremap = true, silent = true, nowait = true }

  local function set_on(bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
      local merged = vim.tbl_extend("force", base_opts, opts, { buffer = bufnr })
      effects_ledger.set_keymap(sess, mode, lhs, rhs, merged)
    end
  end

  set_on(sess.original_bufnr)
  set_on(sess.modified_bufnr)

  local explorer = sess.explorer
  if explorer and explorer.bufnr then
    set_on(explorer.bufnr)
  end

  if sess.result_bufnr then
    set_on(sess.result_bufnr)
  end

  return true
end

--- Remove codediff keymaps from a session's buffers.
--- Uses the effects ledger to restore each buffer to its pre-codediff state
--- (mapset for prior maps, keymap.del for maps with no prior).
--- After this call the ledger entries are dropped so a subsequent
--- reapply_keymaps / set_tab_keymap captures cleanly again.
function M.clear_tab_keymaps(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return
  end

  effects_ledger.restore_keymaps(sess)
end

return M
