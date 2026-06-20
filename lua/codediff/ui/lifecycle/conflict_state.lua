-- Conflict/merge sub-domain state for diff sessions.
-- Owns the merge-base/result seed content, conflict blocks, the set of
-- conflict files opened in a tab, and the unsaved-on-close confirmation.
local M = {}

-- Lazy require to avoid circular dependency: init → session → accessors → session
local function get_active_diffs()
  return require("codediff.ui.lifecycle.session").get_active_diffs()
end

-- ============================================================================
-- GETTERS
-- ============================================================================

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
-- SETTERS
-- ============================================================================

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

return M
