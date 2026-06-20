-- Session CRUD operations for diff views
-- Manages the active_diffs data structure
local M = {}

local config = require("codediff.config")
local virtual_file = require("codediff.core.virtual_file")
local tab_keymaps = require("codediff.ui.lifecycle.tab_keymaps")
local welcome_window = require("codediff.ui.view.welcome_window")

-- Monotonic counter for effects epochs; incremented once per create_session call.
-- Each session gets a unique epoch used to guard against winid recycle in the
-- window-option ledger.
local _effects_epoch_counter = 0

-- Track active diff sessions
-- Structure: {
--   tabpage_id = {
--     original_bufnr, modified_bufnr, original_win, modified_win,
--     mode = "standalone" | "explorer",
--     git_root = string?,
--     original_path = string,
--     modified_path = string,
--     original_revision = string?, -- nil | "WORKING" | "STAGED" | commit_hash
--     modified_revision = string?,
--     original_state, modified_state,
--     suspended = bool,
--     stored_diff_result = table,
--     changedtick = { original = number, modified = number },
--     mtime = { original = number?, modified = number? },
--     -- Conflict mode result buffer (3-way merge)
--     result_bufnr = number?,  -- Real file buffer reset to BASE
--     result_win = number?,    -- Bottom window for result
--     conflict_files = table?, -- { [file_path] = true } tracks files opened in conflict mode
--   }
-- }
local active_diffs = {}

-- Get the active_diffs table (for other modules to access)
function M.get_active_diffs()
  return active_diffs
end

-- Check if a revision represents a virtual buffer
local function is_virtual_revision(revision)
  return revision ~= nil and revision ~= "WORKING"
end

-- Compute virtual URI from revision (not stored, computed on-demand)
local function compute_virtual_uri(git_root, revision, path)
  if not is_virtual_revision(revision) then
    return nil
  end
  return virtual_file.create_url(git_root, revision, path)
end

-- Expose compute_virtual_uri for other modules
M.compute_virtual_uri = compute_virtual_uri

-- ============================================================================
-- BufWinLeave hook registration (Phase 5)
-- Defined before create_session so it can be called from within that function.
-- ============================================================================

--- Register a BufWinLeave autocmd on a single diff buffer.
--- When the buffer genuinely leaves the diff surface (not mid-update, not just
--- a focus change between the two panes), the effects ledger restores that
--- buffer's keymaps.
---
--- Guards applied (in order):
---   1. active_diffs[tabpage] must exist (no-op after full cleanup avoids double-restore).
---   2. sess.updating must be false (skip if a file-switch render is in progress;
---      update_buffers handles the detach after the new bufnrs are in place).
---   3. vim.schedule post-event check: if the buffer is still displayed in one of the
---      session's diff windows after the leave event (e.g. layout reshuffle or
---      inter-pane <C-w>w focus change), it did not actually leave. Only detach when
---      the buffer is truly gone from all tracked diff windows.
---
---@param tabpage number  tabpage this session belongs to
---@param bufnr number    the diff buffer to watch
---@param tab_augroup number  the per-tab augroup created by create_session
function M.register_buf_win_leave(tabpage, bufnr, tab_augroup)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = tab_augroup,
    buffer = bufnr,
    callback = function()
      -- Guard 1: session still alive
      local sess = active_diffs[tabpage]
      if not sess then
        return
      end

      -- Guard 2: mid-render/file-switch in progress; update_buffers will handle detach
      if sess.updating then
        return
      end

      -- Guard 3: schedule a post-event check to see if the buffer is still visible
      -- in one of the session's diff windows (inter-pane <C-w>w or layout reshuffle).
      local leaving_buf = bufnr
      vim.schedule(function()
        local s = active_diffs[tabpage]
        if not s then
          return
        end

        -- If the buffer is still displayed in any diff window, it did not truly leave.
        local diff_wins = {
          s.original_win,
          s.modified_win,
          s.result_win,
        }
        for _, win in ipairs(diff_wins) do
          if win and vim.api.nvim_win_is_valid(win) then
            if vim.api.nvim_win_get_buf(win) == leaving_buf then
              -- Still visible in a diff window → not a real leave; do nothing.
              return
            end
          end
        end

        -- Truly left: restore this buffer's keymaps via the effects ledger.
        local effects = require("codediff.ui.lifecycle.effects")
        effects.detach_buffer(s, leaving_buf)
      end)
    end,
  })
end

function M.create_session(
  tabpage,
  mode,
  git_root,
  original_path,
  modified_path,
  original_revision,
  modified_revision,
  original_bufnr,
  modified_bufnr,
  original_win,
  modified_win,
  lines_diff,
  reapply_keymaps
)
  local state = require("codediff.ui.lifecycle.state")
  -- Save buffer states
  local original_state = state.save_buffer_state(original_bufnr)
  local modified_state = state.save_buffer_state(modified_bufnr)

  -- Assign a unique epoch for the effects ledger (guards winid recycle)
  _effects_epoch_counter = _effects_epoch_counter + 1
  local session_epoch = _effects_epoch_counter

  -- Create complete session in one step
  active_diffs[tabpage] = {
    -- Mode & Git Context (immutable)
    mode = mode,
    git_root = git_root,
    original_path = original_path,
    modified_path = modified_path,
    original_revision = original_revision,
    modified_revision = modified_revision,

    -- Buffers & Windows
    original_bufnr = original_bufnr,
    modified_bufnr = modified_bufnr,
    original_win = original_win,
    modified_win = modified_win,
    original_state = original_state,
    modified_state = modified_state,

    -- Lifecycle state
    layout = "side-by-side",
    suspended = false,
    stored_diff_result = lines_diff,
    changedtick = {
      original = vim.api.nvim_buf_get_changedtick(original_bufnr),
      modified = vim.api.nvim_buf_get_changedtick(modified_bufnr),
    },
    mtime = {
      original = state.get_file_mtime(original_bufnr),
      modified = state.get_file_mtime(modified_bufnr),
    },

    -- Explorer reference (only for explorer mode)
    explorer = nil,

    -- Conflict mode result buffer (3-way merge)
    result_bufnr = nil,
    result_win = nil,
    conflict_files = {}, -- Tracks files opened in conflict mode for unsaved warning
    reapply_keymaps = reapply_keymaps,

    -- Effects ledger: captures prior state before codediff sets keymaps / window options.
    -- Populated by effects.lua; dormant until later phases route their writes here.
    effects = { keymaps = {}, win_opts = {} },
    effects_epoch = session_epoch,

    -- Guard flag: true while update_buffers + setup_all_keymaps are in progress.
    -- Prevents BufWinLeave from prematurely detaching buffers mid-render.
    updating = false,
  }

  welcome_window.capture_session_profiles(active_diffs[tabpage])

  -- Mark windows with restore flag
  vim.w[original_win].codediff_restore = 1
  vim.w[modified_win].codediff_restore = 1

  -- Continuously enforce inlay hint settings via LspAttach (handles LazyVim re-enabling)
  if config.options.diff.disable_inlay_hints and vim.lsp.inlay_hint then
    vim.lsp.inlay_hint.enable(false, { bufnr = original_bufnr })
    vim.lsp.inlay_hint.enable(false, { bufnr = modified_bufnr })
  end

  -- Setup tab autocmds
  local tab_augroup = vim.api.nvim_create_augroup("codediff_lifecycle_tab_" .. tabpage, { clear = true })

  -- Re-disable inlay hints when LSP attaches (LazyVim/distributions may re-enable them)
  if config.options.diff.disable_inlay_hints then
    vim.api.nvim_create_autocmd("LspAttach", {
      group = tab_augroup,
      callback = function(ev)
        if not active_diffs[tabpage] then
          return
        end
        vim.schedule(function()
          if vim.api.nvim_get_current_tabpage() == tabpage then
            pcall(vim.lsp.inlay_hint.enable, false, { bufnr = ev.buf })
          end
        end)
      end,
    })
  end

  -- Force disable winbar to prevent alignment issues (except in conflict mode)
  local function sync_window_ui(sess, win)
    -- In conflict mode, preserve existing winbar titles (set by conflict_window.lua)
    if sess and sess.result_win and vim.api.nvim_win_is_valid(sess.result_win) then
      return
    end
    -- Normal diff mode: disable winbar
    if sess and sess.original_win and vim.api.nvim_win_is_valid(sess.original_win) then
      vim.wo[sess.original_win].winbar = ""
    end
    if sess and sess.modified_win and vim.api.nvim_win_is_valid(sess.modified_win) then
      vim.wo[sess.modified_win].winbar = ""
    end
  end

  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "WinEnter", "FileType" }, {
    group = tab_augroup,
    callback = function()
      local sess = active_diffs[tabpage]
      if not sess then
        return
      end
      local win = vim.api.nvim_get_current_win()
      if win == sess.original_win or win == sess.modified_win then
        sync_window_ui(sess, win)
        -- Re-apply critical window options that might get reset by ftplugins/autocmds
        local effects = require("codediff.ui.lifecycle.effects")
        effects.set_win_opt(sess, win, "wrap", false)
        welcome_window.sync(win)
      end
    end,
  })

  vim.api.nvim_create_autocmd("TabLeave", {
    group = tab_augroup,
    callback = function()
      local current_tab = vim.api.nvim_get_current_tabpage()
      if current_tab == tabpage then
        tab_keymaps.clear_tab_keymaps(tabpage)
        state.suspend_diff(tabpage)
      end
    end,
  })

  vim.api.nvim_create_autocmd("TabEnter", {
    group = tab_augroup,
    callback = function()
      vim.schedule(function()
        local current_tab = vim.api.nvim_get_current_tabpage()
        if current_tab == tabpage and active_diffs[tabpage] then
          local sess = active_diffs[tabpage]
          if sess.reapply_keymaps then
            pcall(sess.reapply_keymaps)
          end
          state.resume_diff(tabpage)
        end
      end)
    end,
  })

  -- Register BufWinLeave hooks on the initial diff buffers.
  -- On file-switch, accessors.update_buffers calls M.register_buf_win_leave for
  -- newly added buffers (using sess._tab_augroup to reach the per-tab augroup).
  M.register_buf_win_leave(tabpage, original_bufnr, tab_augroup)
  if modified_bufnr ~= original_bufnr then
    M.register_buf_win_leave(tabpage, modified_bufnr, tab_augroup)
  end

  -- Store the tab_augroup so update_buffers can register hooks on new buffers.
  active_diffs[tabpage]._tab_augroup = tab_augroup
end

return M
