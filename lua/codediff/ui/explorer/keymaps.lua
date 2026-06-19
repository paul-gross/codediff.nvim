-- Keymaps for explorer panel
local config = require("codediff.config")
local actions_module = require("codediff.ui.explorer.actions")
local refresh_module = require("codediff.ui.explorer.refresh")
local tree_utils = require("codediff.ui.lib.tree_utils")

local M = {}

-- Setup keymaps for explorer panel
-- @param explorer: explorer object with tree, split, git_root, on_file_select, etc.
function M.setup(explorer)
  local tree = explorer.tree
  local split = explorer.split
  local git_root = explorer.git_root

  local lifecycle = require("codediff.ui.lifecycle")
  local session = lifecycle.get_session(explorer.tabpage)

  local map_options = { noremap = true, silent = true, nowait = true }
  local explorer_keymaps = config.options.keymaps.explorer or {}

  -- Helper: route a buffer-local keymap through the effects ledger when a session
  -- is available; fall back to a direct vim.keymap.set when the session is not yet
  -- present (e.g. during directory-comparison before first view.update).
  local function set_keymap(mode, lhs, rhs, extra_opts)
    local opts = vim.tbl_extend("force", map_options, extra_opts or {}, { buffer = split.bufnr })
    if session then
      local effects = require("codediff.ui.lifecycle.effects")
      effects.set_keymap(session, mode, lhs, rhs, opts)
    else
      vim.keymap.set(mode, lhs, rhs, opts)
    end
  end

  -- Toggle expand/collapse or select file
  if explorer_keymaps.select then
    set_keymap("n", explorer_keymaps.select, function()
      local node = tree:get_node()
      if not node then
        return
      end

      if node.data and (node.data.type == "group" or node.data.type == "directory") then
        -- Toggle group or directory
        if node:is_expanded() then
          node:collapse()
        else
          node:expand()
        end
        tree:render()
      else
        -- File selected
        if node.data then
          explorer.on_file_select(node.data)
          -- Optionally focus the modified (right) pane after file load
          if config.options.explorer.focus_on_select then
            vim.schedule(function()
              local _, mod_win = lifecycle.get_windows(explorer.tabpage)
              if mod_win and vim.api.nvim_win_is_valid(mod_win) then
                vim.api.nvim_set_current_win(mod_win)
              end
            end)
          end
        end
      end
    end, { desc = "Select/toggle entry" })
  end

  -- Double click also works for files
  set_keymap("n", "<2-LeftMouse>", function()
    local node = tree:get_node()
    if not node or not node.data or node.data.type == "group" or node.data.type == "directory" then
      return
    end
    explorer.on_file_select(node.data)
  end, { desc = "Select file" })

  -- Hover to show full path (K key, like LSP hover)
  local hover_win = nil
  if explorer_keymaps.hover then
    set_keymap("n", explorer_keymaps.hover, function()
      -- Close existing hover window
      if hover_win and vim.api.nvim_win_is_valid(hover_win) then
        vim.api.nvim_win_close(hover_win, true)
        hover_win = nil
        return
      end

      local node = tree:get_node()
      if not node or not node.data or node.data.type == "group" then
        return
      end

      local full_path = node.data.path
      local display_text = git_root .. "/" .. full_path

      -- Create hover buffer
      local hover_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(hover_buf, 0, -1, false, { display_text })
      vim.bo[hover_buf].modifiable = false

      -- Calculate window position (next to cursor)
      local cursor = vim.api.nvim_win_get_cursor(0)
      local row = cursor[1] - 1
      local col = vim.api.nvim_win_get_width(0)

      -- Calculate window dimensions with wrapping
      local max_width = 80
      local text_len = #display_text
      local width = math.min(text_len + 2, max_width)
      local height = math.ceil(text_len / (max_width - 2)) -- Account for padding

      -- Create floating window with wrap enabled
      hover_win = vim.api.nvim_open_win(hover_buf, false, {
        relative = "win",
        row = row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
      })

      -- Enable wrap in hover window
      vim.wo[hover_win].wrap = true

      -- Auto-close on cursor move or buffer leave
      vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave" }, {
        buffer = split.bufnr,
        once = true,
        callback = function()
          if hover_win and vim.api.nvim_win_is_valid(hover_win) then
            vim.api.nvim_win_close(hover_win, true)
            hover_win = nil
          end
        end,
      })
    end, { desc = "Show full path" })
  end

  -- Refresh explorer (R key)
  if explorer_keymaps.refresh then
    set_keymap("n", explorer_keymaps.refresh, function()
      refresh_module.refresh(explorer)
    end, { desc = "Refresh explorer" })
  end

  -- Toggle view mode (i key) - switch between 'list' and 'tree'
  if explorer_keymaps.toggle_view_mode then
    set_keymap("n", explorer_keymaps.toggle_view_mode, function()
      actions_module.toggle_view_mode(explorer)
    end, { desc = "Toggle list/tree view" })
  end

  -- Stage all files (S key)
  if explorer_keymaps.stage_all then
    set_keymap("n", explorer_keymaps.stage_all, function()
      actions_module.stage_all(explorer)
    end, { desc = "Stage all files" })
  end

  -- Unstage all files (U key)
  if explorer_keymaps.unstage_all then
    set_keymap("n", explorer_keymaps.unstage_all, function()
      actions_module.unstage_all(explorer)
    end, { desc = "Unstage all files" })
  end

  -- Restore/discard changes (X key)
  if explorer_keymaps.restore then
    set_keymap("n", explorer_keymaps.restore, function()
      actions_module.restore_entry(explorer, tree)
    end, { desc = "Restore/discard changes" })
  end

  -- Toggle Changes (unstaged) group visibility
  if explorer_keymaps.toggle_changes then
    set_keymap("n", explorer_keymaps.toggle_changes, function()
      actions_module.toggle_group(explorer, "unstaged")
    end, { desc = "Toggle Changes visibility" })
  end

  -- Toggle Staged Changes group visibility
  if explorer_keymaps.toggle_staged then
    set_keymap("n", explorer_keymaps.toggle_staged, function()
      actions_module.toggle_group(explorer, "staged")
    end, { desc = "Toggle Staged Changes visibility" })
  end

  -- Fold keymaps (Vim-style: zo/zO/zc/zC/za/zA/zR/zM)
  tree_utils.setup_fold_keymaps({
    tree = tree,
    keymaps = explorer_keymaps,
    bufnr = split.bufnr,
    session = session,
  })

  -- Note: next_file/prev_file keymaps are set via view/keymaps.lua:setup_all_keymaps()
  -- which uses set_tab_keymap to set them on all buffers including explorer
end

return M
