-- Auto-sync a diff on file switch: when one side of the diff is a git revision
-- (virtual) and the other is a live working file, follow the working window as
-- the user edits different files and re-run the diff against the new path.
local M = {}

-- Lazy require to avoid circular dependency: init → session → accessors → session
local function get_active_diffs()
  return require("codediff.ui.lifecycle.session").get_active_diffs()
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
