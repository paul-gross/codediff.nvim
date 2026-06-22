local M = {}

local welcome = require("codediff.ui.welcome")

local option_names = {
  "number",
  "relativenumber",
  "signcolumn",
  "foldcolumn",
  "statuscolumn",
}

local welcome_opts = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  statuscolumn = " ",
}

local function is_valid_window(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

local function read_window_opts(winid)
  local opts = {}
  for _, name in ipairs(option_names) do
    opts[name] = vim.wo[winid][name]
  end
  return opts
end

local function apply_opts(winid, opts)
  for name, value in pairs(opts) do
    vim.wo[winid][name] = value
  end
end

-- Lazy require: session.lua (a lifecycle module) requires this file at load time,
-- so reaching back into lifecycle at the top level would form a require cycle.
local function lifecycle()
  return require("codediff.ui.lifecycle")
end

function M.capture_session_profiles(tabpage)
  if not tabpage then
    return
  end

  local original_win, modified_win = lifecycle().get_windows(tabpage)
  if is_valid_window(original_win) then
    lifecycle().capture_window_profile(tabpage, "original", read_window_opts(original_win))
  end
  if is_valid_window(modified_win) then
    lifecycle().capture_window_profile(tabpage, "modified", read_window_opts(modified_win))
  end
end

function M.apply(winid)
  if not is_valid_window(winid) then
    return
  end

  apply_opts(winid, welcome_opts)
end

function M.apply_normal(winid)
  if not is_valid_window(winid) then
    return
  end

  local tabpage, side = lifecycle().find_tabpage_by_window(winid)
  if not tabpage or not side then
    return
  end

  M.capture_session_profiles(tabpage)
  local normal_opts = lifecycle().get_window_profile(tabpage, side)
  if not normal_opts then
    return
  end

  apply_opts(winid, normal_opts)
end

function M.sync(winid)
  if not is_valid_window(winid) then
    return
  end

  local bufnr = vim.api.nvim_win_get_buf(winid)
  if welcome.is_welcome_buffer(bufnr) then
    M.apply(winid)
  else
    M.apply_normal(winid)
  end
end

function M.sync_later(winid)
  vim.schedule(function()
    M.sync(winid)
  end)
end

return M
