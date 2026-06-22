local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local layout = require("codediff.ui.layout")

local function normalize_inline_layout(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end

  lifecycle.update_layout(tabpage, "inline")
  lifecycle.set_single_pane(tabpage, nil)

  local original_win, modified_win = lifecycle.get_windows(tabpage)
  local keep_win = (modified_win and vim.api.nvim_win_is_valid(modified_win) and modified_win) or (original_win and vim.api.nvim_win_is_valid(original_win) and original_win)

  if not keep_win then
    return false
  end

  lifecycle.set_windows(tabpage, keep_win, keep_win)

  local close_win = nil
  if original_win and modified_win and original_win ~= modified_win then
    close_win = keep_win == modified_win and original_win or modified_win
  end

  if close_win and vim.api.nvim_win_is_valid(close_win) then
    vim.api.nvim_set_current_win(keep_win)
    pcall(vim.api.nvim_win_close, close_win, true)
  end

  return true
end

local function normalize_side_by_side_layout(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end

  local original_win, modified_win = lifecycle.get_windows(tabpage)
  local current_win = (modified_win and vim.api.nvim_win_is_valid(modified_win) and modified_win) or (original_win and vim.api.nvim_win_is_valid(original_win) and original_win)

  if not current_win then
    return false
  end

  lifecycle.update_layout(tabpage, "side-by-side")
  lifecycle.set_single_pane(tabpage, true)
  lifecycle.set_windows(tabpage, nil, current_win)
  return true
end

-- Re-render the current file in the new layout.
-- For explorer/history: call rerender_current which re-triggers on_file_select.
-- For standalone: rebuild session_config from existing session fields.
local function rerender_current_file(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end

  local mode = lifecycle.get_mode(tabpage)

  if mode == "explorer" then
    local explorer = lifecycle.get_explorer(tabpage)
    return explorer and require("codediff.ui.explorer").rerender_current(explorer) or false
  end

  if mode == "history" then
    local history = lifecycle.get_explorer(tabpage)
    return history and require("codediff.ui.history").rerender_current(history) or false
  end

  -- Standalone mode: rebuild from session fields
  local ctx = lifecycle.get_git_context(tabpage)
  local original_path, modified_path = lifecycle.get_paths(tabpage)
  local session_config = {
    mode = mode,
    git_root = ctx and ctx.git_root,
    original_path = original_path,
    modified_path = modified_path,
    original_revision = ctx and ctx.original_revision,
    modified_revision = ctx and ctx.modified_revision,
  }
  return require("codediff.ui.view").update(tabpage, session_config, false)
end

function M.toggle(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end

  local _, result_win = lifecycle.get_result(tabpage)
  if result_win and vim.api.nvim_win_is_valid(result_win) then
    vim.notify("Cannot toggle layout in conflict mode", vim.log.levels.WARN)
    return false
  end

  local current_layout = lifecycle.get_layout(tabpage)
  local target_layout = current_layout == "inline" and "side-by-side" or "inline"
  local normalize = target_layout == "inline" and normalize_inline_layout or normalize_side_by_side_layout

  -- Disable compact mode before changing layout (window IDs will change)
  local compact = require("codediff.ui.view.compact")
  local was_compact = lifecycle.is_compact_mode(tabpage)
  if was_compact then
    compact.disable(tabpage)
  end

  if not normalize(tabpage) then
    return false
  end

  if rerender_current_file(tabpage) then
    layout.arrange(tabpage)
  end

  -- Re-enable compact mode in new layout
  if was_compact then
    compact.enable(tabpage)
  end

  return true
end

return M
