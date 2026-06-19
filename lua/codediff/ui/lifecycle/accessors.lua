-- Accessor functions (getters and setters) for diff sessions
local M = {}
local config = require("codediff.config")

-- Eager require: effects.lua has no circular dependencies; loading it up front
-- avoids a lazy-require failure when TabLeave fires after a `cd` changes CWD.
local effects_ledger = require("codediff.ui.lifecycle.effects")

-- Lazy require to avoid circular dependency: init → session → accessors → session
local function get_active_diffs()
  return require("codediff.ui.lifecycle.session").get_active_diffs()
end

-- Compatibility shim: keep the local name used by existing call sites below.
local function get_effects()
  return effects_ledger
end

-- Check if a revision represents a virtual buffer
local function is_virtual_revision(revision)
  return revision ~= nil and revision ~= "WORKING"
end

-- ============================================================================
-- PUBLIC API - GETTERS (return copies/values, safe)
-- ============================================================================

--- Get session
--- @param tabpage number
--- @return table|nil
function M.get_session(tabpage)
  local active_diffs = get_active_diffs()
  return active_diffs[tabpage]
end

--- Get mode
function M.get_mode(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  return sess and sess.mode or nil
end

--- Get current session layout
function M.get_layout(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  return sess and sess.layout or nil
end

--- Get git context
function M.get_git_context(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return nil
  end

  return {
    git_root = sess.git_root,
    original_revision = sess.original_revision,
    modified_revision = sess.modified_revision,
  }
end

--- Get buffer IDs
function M.get_buffers(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return nil, nil
  end
  return sess.original_bufnr, sess.modified_bufnr
end

--- Get window IDs
function M.get_windows(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return nil, nil
  end
  return sess.original_win, sess.modified_win
end

--- Get paths
function M.get_paths(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return nil, nil
  end
  return sess.original_path, sess.modified_path
end

--- Find tabpage containing a buffer
function M.find_tabpage_by_buffer(bufnr)
  local active_diffs = get_active_diffs()
  for tabpage, sess in pairs(active_diffs) do
    if sess.original_bufnr == bufnr or sess.modified_bufnr == bufnr or sess.result_bufnr == bufnr then
      return tabpage
    end
  end
  return nil
end

--- Check if original buffer is virtual
function M.is_original_virtual(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end
  return is_virtual_revision(sess.original_revision)
end

--- Check if modified buffer is virtual
function M.is_modified_virtual(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end
  return is_virtual_revision(sess.modified_revision)
end

--- Check if suspended
function M.is_suspended(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  return sess and sess.suspended or false
end

--- Get explorer reference (for explorer mode)
function M.get_explorer(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  return sess and sess.explorer
end

--- Get the merge base (stage :1) content for the conflict file.
--- This is the common ancestor — the real "original" — used by smart-combine
--- and discard operations that need merge-base coordinates. Distinct from
--- result_base_lines, which is the auto-merged *seed* content of the Result
--- buffer (and not the merge base).
function M.get_merge_base_lines(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  return sess and sess.merge_base_lines
end

--- Get the seed content of the Result buffer (auto-merged result).
--- This is what the Result buffer was initialized to, and what every
--- accept/discard action compares against to decide whether a conflict
--- region is still in its initial unresolved state. NOT the merge base —
--- see get_merge_base_lines for that.
function M.get_result_base_lines(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  return sess and sess.result_base_lines
end

--- Get result buffer and window
function M.get_result(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return nil, nil
  end
  return sess.result_bufnr, sess.result_win
end

--- Get conflict blocks for a session
--- @param tabpage number
--- @return table|nil List of conflict blocks
function M.get_conflict_blocks(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  return sess and sess.conflict_blocks
end

--- Get all conflict files for a session
function M.get_conflict_files(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return {}
  end
  return sess.conflict_files or {}
end

--- Check if any conflict files have unsaved changes
--- Returns list of unsaved file paths
function M.get_unsaved_conflict_files(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess or not sess.conflict_files then
    return {}
  end

  local unsaved = {}
  for file_path, _ in pairs(sess.conflict_files) do
    -- Find buffer for this file
    local bufnr = vim.fn.bufnr(file_path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
      if vim.bo[bufnr].modified then
        table.insert(unsaved, file_path)
      end
    end
  end
  return unsaved
end

-- ============================================================================
-- PUBLIC API - SETTERS (validated mutations)
-- ============================================================================

--- Update suspended state
function M.update_suspended(tabpage, suspended)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.suspended = suspended
  return true
end

--- Update session layout
function M.update_layout(tabpage, layout)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.layout = layout
  return true
end

--- Update diff result (cached)
function M.update_diff_result(tabpage, diff_lines)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.stored_diff_result = diff_lines
  return true
end

--- Update changedtick
function M.update_changedtick(tabpage, original_tick, modified_tick)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.changedtick.original = original_tick
  sess.changedtick.modified = modified_tick
  return true
end

--- Update mtime
function M.update_mtime(tabpage, original_mtime, modified_mtime)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.mtime.original = original_mtime
  sess.mtime.modified = modified_mtime
  return true
end

--- Update paths (for file switching/sync)
function M.update_paths(tabpage, original_path, modified_path)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.original_path = original_path
  sess.modified_path = modified_path
  return true
end

--- Update buffer numbers (for file switching/sync when buffers change)
--- Also updates buffer states (for suspend/resume to work correctly)
---
--- Phase 5: before re-pointing sess.original_bufnr/modified_bufnr, detach any
--- bufnrs that are genuinely leaving the session (not reused as either new bufnr).
--- This restores their user-visible keymaps immediately and drops their ledger entries.
--- After re-pointing, register BufWinLeave hooks on any newly added bufnrs.
function M.update_buffers(tabpage, original_bufnr, modified_bufnr)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  -- Collect bufnrs that are genuinely leaving (not equal to either new bufnr).
  local new_bufnrs = { [original_bufnr] = true, [modified_bufnr] = true }
  local outgoing = {}
  if sess.original_bufnr and not new_bufnrs[sess.original_bufnr] then
    table.insert(outgoing, sess.original_bufnr)
  end
  if sess.modified_bufnr and sess.modified_bufnr ~= sess.original_bufnr and not new_bufnrs[sess.modified_bufnr] then
    table.insert(outgoing, sess.modified_bufnr)
  end

  -- Detach outgoing buffers: restore their keymaps and drop ledger entries.
  -- Window options are NOT touched here (win opts are keyed by winid, not bufnr;
  -- the windows themselves stay alive for the new buffers).
  for _, old_buf in ipairs(outgoing) do
    effects_ledger.detach_buffer(sess, old_buf)
  end

  local state = require("codediff.ui.lifecycle.state")

  sess.original_bufnr = original_bufnr
  sess.modified_bufnr = modified_bufnr

  -- Save buffer states for new buffers (critical for suspend/resume!)
  sess.original_state = state.save_buffer_state(original_bufnr)
  sess.modified_state = state.save_buffer_state(modified_bufnr)

  -- Register BufWinLeave hooks on newly added bufnrs (not already tracked by a hook).
  -- The session stores its tab_augroup so we can register buffer-local autocmds.
  local session_mod = require("codediff.ui.lifecycle.session")
  local augroup = sess._tab_augroup
  if augroup then
    -- Register for each new bufnr if not already in outgoing set (already-tracked ones
    -- had their hook registered when first encountered; new bufnrs need fresh hooks).
    -- It's safe to re-register: duplicate BufWinLeave hooks are harmless since the
    -- guard in the callback checks active_diffs[tabpage] and sess.updating.
    session_mod.register_buf_win_leave(tabpage, original_bufnr, augroup)
    if modified_bufnr ~= original_bufnr then
      session_mod.register_buf_win_leave(tabpage, modified_bufnr, augroup)
    end
  end

  return true
end

--- Update git root (for file switching when changing repos)
function M.update_git_root(tabpage, git_root)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.git_root = git_root
  return true
end

--- Update revisions (for file switching/sync)
function M.update_revisions(tabpage, original_revision, modified_revision)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.original_revision = original_revision
  sess.modified_revision = modified_revision
  return true
end

--- Set explorer reference (for explorer mode)
function M.set_explorer(tabpage, explorer)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.explorer = explorer
  return true
end

--- Set result buffer and window (for conflict mode)
function M.set_result(tabpage, result_bufnr, result_win)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.result_bufnr = result_bufnr
  sess.result_win = result_win

  -- Mark result window with restore flag
  if result_win and vim.api.nvim_win_is_valid(result_win) then
    vim.w[result_win].codediff_restore = 1
  end

  -- Register BufWinLeave for the result buffer so that if only the result
  -- window is closed, the effects ledger restores its keymaps (mirrors the
  -- registration done for original_bufnr/modified_bufnr in session.lua).
  if result_bufnr then
    local session_mod = require("codediff.ui.lifecycle.session")
    local augroup = sess._tab_augroup
    if augroup then
      session_mod.register_buf_win_leave(tabpage, result_bufnr, augroup)
    end
  end

  return true
end

--- Store the seed content for the Result buffer (auto-merged result).
--- See get_result_base_lines for semantics.
function M.set_result_base_lines(tabpage, result_base_lines)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end
  sess.result_base_lines = result_base_lines
  return true
end

--- Store the merge base (stage :1) content for the conflict file.
--- See get_merge_base_lines for semantics; this is kept separate from
--- result_base_lines so smart-combine can still walk merge-base coordinates
--- after the Result buffer has been auto-merged.
function M.set_merge_base_lines(tabpage, merge_base_lines)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end
  sess.merge_base_lines = merge_base_lines
  return true
end

--- Store conflict blocks (mapping alignments) for a session
--- @param tabpage number
--- @param blocks table List of conflict blocks from compute_mapping_alignments
function M.set_conflict_blocks(tabpage, blocks)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end
  sess.conflict_blocks = blocks
  return true
end

--- Track a file opened in conflict mode (for unsaved warning)
function M.track_conflict_file(tabpage, file_path)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.conflict_files = sess.conflict_files or {}
  sess.conflict_files[file_path] = true
  return true
end

--- Prompt user about unsaved conflict files before closing
--- Returns true if user confirms close, false if cancelled
function M.confirm_close_with_unsaved(tabpage)
  local unsaved = M.get_unsaved_conflict_files(tabpage)
  if #unsaved == 0 then
    return true -- No unsaved files, proceed
  end

  -- Build message
  local msg = "The following merge result files have unsaved changes:\n\n"
  for _, path in ipairs(unsaved) do
    -- Show just filename for readability
    local filename = vim.fn.fnamemodify(path, ":t")
    msg = msg .. "  • " .. filename .. "\n"
  end
  msg = msg .. "\nDiscard changes and close?"

  -- Show confirmation dialog
  local choice = vim.fn.confirm(msg, "&Discard\n&Cancel", 2, "Warning")

  if choice == 1 then
    -- Discard: reload buffers from disk to restore original content (with conflict markers)
    for _, path in ipairs(unsaved) do
      local bufnr = vim.fn.bufnr(path)
      if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
        -- Reload from disk to restore original file content
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd("edit!")
        end)
      end
    end
    return true
  else
    -- Cancel
    return false
  end
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

  local effects = get_effects()
  opts = opts or {}
  local base_opts = { noremap = true, silent = true, nowait = true }

  local function set_on(bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
      local merged = vim.tbl_extend("force", base_opts, opts, { buffer = bufnr })
      effects.set_keymap(sess, mode, lhs, rhs, merged)
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

  get_effects().restore_keymaps(sess)
end

--- Setup auto-sync on file switch: automatically update diff when user edits a different file in working buffer
--- Only activates when one side is virtual (git revision) and other is working file
--- @param tabpage number Tabpage ID
--- @param original_is_virtual boolean Whether original side is virtual (git revision)
--- @param modified_is_virtual boolean Whether modified side is virtual
function M.setup_auto_sync_on_file_switch(tabpage, original_is_virtual, modified_is_virtual)
  -- Only setup if one side is virtual (commit) and other is working file
  if original_is_virtual == modified_is_virtual then
    return -- Both virtual or both real - no sync needed
  end

  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    vim.notify("[codediff] No session found for auto-sync setup", vim.log.levels.ERROR)
    return
  end

  -- Determine which window is working
  local working_win = original_is_virtual and sess.modified_win or sess.original_win
  local working_side = original_is_virtual and "modified" or "original"

  if not working_win or not vim.api.nvim_win_is_valid(working_win) then
    vim.notify("[codediff] Working window not found for auto-sync", vim.log.levels.WARN)
    return
  end

  -- Track current file path
  local current_path = sess[working_side .. "_path"]

  -- Setup listener using BufWinEnter (fires when buffer enters window, even if existing buffer)
  local sync_group = vim.api.nvim_create_augroup("codediff_working_sync_" .. tabpage, { clear = true })

  -- Listen to BufWinEnter - fires when ANY buffer enters the window (including existing buffers)
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = sync_group,
    callback = function(args)
      -- Check if this buffer is in the working window
      local buf_win = vim.fn.bufwinid(args.buf)
      if buf_win ~= working_win then
        return
      end

      local new_path = vim.api.nvim_buf_get_name(args.buf)

      -- Skip virtual files - they're programmatic, not user navigation
      if new_path:match("^codediff://") then
        return
      end

      -- Check if file changed
      if new_path == "" or new_path == current_path then
        return
      end

      -- Update tracked path
      current_path = new_path

      -- Path changed! Need to update both sides
      vim.schedule(function()
        -- Get git root (might have changed if user switched to different repo)
        local git = require("codediff.core.git")
        local view = require("codediff.ui.view")

        git.get_git_root(new_path, function(err, new_git_root)
          if err then
            -- Not in git, just update paths without git context
            vim.schedule(function()
              -- Get relative path if possible
              local relative_path = new_path
              if sess.git_root then
                relative_path = git.get_relative_path(new_path, sess.git_root)
              end

              -- No pre-fetching needed, buffers will load content
              view.update(tabpage, {
                mode = sess.mode,
                git_root = nil,
                original_path = working_side == "original" and new_path or relative_path,
                modified_path = working_side == "modified" and new_path or relative_path,
                original_revision = working_side == "original" and nil or sess.original_revision,
                modified_revision = working_side == "modified" and nil or sess.modified_revision,
              })
            end)
            return
          end

          -- In git! Get relative path
          local relative_path = git.get_relative_path(new_path, new_git_root)

          -- No pre-fetching needed, buffers will load content
          vim.schedule(function()
            view.update(tabpage, {
              mode = sess.mode,
              git_root = new_git_root,
              original_path = relative_path,
              modified_path = relative_path,
              original_revision = sess.original_revision,
              modified_revision = sess.modified_revision,
            })
          end)
        end)
      end)
    end,
  })
end

return M
