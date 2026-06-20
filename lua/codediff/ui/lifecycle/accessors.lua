-- Accessors for the core diff-session fields (mode, layout, buffers, windows,
-- paths, revisions, git_root, suspended, diff_result, changedtick, mtime,
-- explorer, is_*_virtual). The conflict/merge, tab-keymap, and auto-sync
-- sub-domains live in sibling modules behind the same lifecycle facade.
local M = {}

-- Eager require: effects.lua has no circular dependencies; loading it up front
-- avoids a lazy-require failure when an autocmd fires after a `cd` changes CWD.
-- update_buffers consults the ledger to detach outgoing buffers.
local effects_ledger = require("codediff.ui.lifecycle.effects")

-- Lazy require to avoid circular dependency: init → session → accessors → session
local function get_active_diffs()
  return require("codediff.ui.lifecycle.session").get_active_diffs()
end

-- Check if a revision represents a virtual buffer
local function is_virtual_revision(revision)
  return revision ~= nil and revision ~= "WORKING"
end

-- GETTERS (return copies/values, safe)

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

-- SETTERS (validated mutations)

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

return M
