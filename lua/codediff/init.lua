-- vscode-diff main API
local M = {}

-- Configuration setup
function M.setup(opts)
  local config = require("codediff.config")
  config.setup(opts)

  local render = require("codediff.ui")
  render.setup_highlights()
end

-- Navigate to next hunk in the current diff view
-- Returns true if navigation succeeded, false otherwise
function M.next_hunk()
  local navigation = require("codediff.ui.view.navigation")
  return navigation.next_hunk()
end

-- Navigate to previous hunk in the current diff view
-- Returns true if navigation succeeded, false otherwise
function M.prev_hunk()
  local navigation = require("codediff.ui.view.navigation")
  return navigation.prev_hunk()
end

-- Navigate to next file in explorer/history mode
-- In single-file history mode, navigates to next commit instead
-- Returns true if navigation succeeded, false otherwise
function M.next_file()
  local navigation = require("codediff.ui.view.navigation")
  return navigation.next_file()
end

-- Navigate to previous file in explorer/history mode
-- In single-file history mode, navigates to previous commit instead
-- Returns true if navigation succeeded, false otherwise
function M.prev_file()
  local navigation = require("codediff.ui.view.navigation")
  return navigation.prev_file()
end

--- Open a multi-repo diff explorer session aggregating changed files across N repos.
-- @param specs table: list of { root=string, base=string, target=string, label=string? }
--   Each element may also use positional fields: { root, base, target } (indices 1, 2, 3).
-- @param opts table?: optional options (e.g. { layout = "inline" })
function M.diff_repos(specs, opts)
  opts = opts or {}

  -- Normalise each spec: accept both { root=, base=, target= } and positional { root, base, target }
  local normalised = {}
  for i, spec in ipairs(specs) do
    local root = spec.root or spec[1]
    local base = spec.base or spec[2]
    local target = spec.target or spec[3]
    local label = spec.label

    if not root or not base or not target then
      vim.notify(string.format("codediff.diff_repos: spec[%d] is missing root, base, or target", i), vim.log.levels.ERROR)
      return
    end

    -- Expand ~ and resolve relative paths to absolute paths
    root = vim.fn.fnamemodify(vim.fn.expand(root), ":p")
    -- Strip trailing slash so the label and comparisons work consistently
    root = root:gsub("[/\\]$", "")

    normalised[i] = { root = root, base = base, target = target, label = label }
  end

  if #normalised == 0 then
    vim.notify("codediff.diff_repos: specs list is empty", vim.log.levels.ERROR)
    return
  end

  local multi_repo = require("codediff.core.multi_repo")
  local view = require("codediff.ui.view")

  multi_repo.aggregate(normalised, function(merged_status_result, errors)
    -- Surface per-repo errors as warnings (non-fatal; valid repos still contribute)
    if errors and #errors > 0 then
      vim.schedule(function()
        for _, e in ipairs(errors) do
          vim.notify("codediff multi-repo: " .. e.root .. ": " .. e.error, vim.log.levels.WARN)
        end
      end)
    end

    vim.schedule(function()
      ---@type SessionConfig
      local session_config = {
        mode = "explorer",
        git_root = nil, -- nil + multi_repo=true distinguishes from dir mode
        original_path = "",
        modified_path = "",
        original_revision = nil,
        modified_revision = nil,
        layout = opts.layout,
        explorer_data = {
          status_result = merged_status_result,
          multi_repo = true,
          repos = normalised,
        },
      }

      view.create(session_config, "")
    end)
  end)
end

return M
