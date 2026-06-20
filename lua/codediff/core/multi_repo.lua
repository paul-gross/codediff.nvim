-- Multi-repo aggregation for codediff.nvim
-- Fans out get_diff_revisions across N (root, base, target) specs and merges
-- all resulting file entries into one status_result for the explorer.
local M = {}

local git = require("codediff.core.git")

--- Aggregate diff results across multiple repo specs.
-- Each spec is { root=string, base=string, target=string, label=string? }.
-- The callback receives (merged_status_result, errors) where:
--   merged_status_result = { unstaged = {...}, staged = {}, conflicts = {} }
--   errors = list of { root=string, error=string } (may be empty)
-- One invalid/non-git root records a per-repo error and continues; the rest
-- of the repos are still processed and their entries included in the result.
--
-- Each file entry in the merged result carries:
--   entry.git_root       = canonical git root for the repo
--   entry.base_revision  = resolved base commit hash
--   entry.target_revision = resolved target commit hash
--   entry.repo_label     = human-readable repo label (basename by default)
--
-- @param specs table: list of { root, base, target, label? }
-- @param callback function: function(merged_status_result, errors)
function M.aggregate(specs, callback)
  if not specs or #specs == 0 then
    callback({ unstaged = {}, staged = {}, conflicts = {} }, {})
    return
  end

  local total = #specs
  local pending = total
  -- Per-spec ordered results: index i holds { entries, error } for specs[i]
  local results = {}
  for i = 1, total do
    results[i] = nil
  end
  local errors = {}

  local function finish_spec(i, entries, err)
    results[i] = { entries = entries, err = err }
    if err then
      table.insert(errors, { root = specs[i].root, error = err })
    end

    pending = pending - 1
    if pending == 0 then
      -- Merge all entries in spec input order
      local merged = { unstaged = {}, staged = {}, conflicts = {} }
      for _, result in ipairs(results) do
        if result.entries then
          for _, entry in ipairs(result.entries) do
            table.insert(merged.unstaged, entry)
          end
        end
      end
      callback(merged, errors)
    end
  end

  for i, spec in ipairs(specs) do
    local root = spec.root
    local base = spec.base
    local target = spec.target
    local label = spec.label or vim.fn.fnamemodify(root, ":t")

    -- Validate that root is a git repo by calling get_git_root on it.
    -- get_git_root accepts a directory path and returns the canonical git root.
    git.get_git_root(root, function(err_root, canonical_root)
      if err_root then
        finish_spec(i, nil, "Not a git repository: " .. tostring(err_root))
        return
      end

      -- Resolve base revision to a commit hash
      git.resolve_revision(base, canonical_root, function(err_base, base_hash)
        if err_base then
          finish_spec(i, nil, "Failed to resolve base revision '" .. tostring(base) .. "': " .. tostring(err_base))
          return
        end

        -- Resolve target revision to a commit hash
        git.resolve_revision(target, canonical_root, function(err_target, target_hash)
          if err_target then
            finish_spec(i, nil, "Failed to resolve target revision '" .. tostring(target) .. "': " .. tostring(err_target))
            return
          end

          -- Get diff between the two resolved revisions
          git.get_diff_revisions(base_hash, target_hash, canonical_root, function(err_diff, status_result)
            if err_diff then
              finish_spec(i, nil, "Failed to get diff: " .. tostring(err_diff))
              return
            end

            -- Tag every returned entry with per-repo metadata
            local entries = {}
            for _, entry in ipairs(status_result.unstaged or {}) do
              entry.git_root = canonical_root
              entry.base_revision = base_hash
              entry.target_revision = target_hash
              entry.repo_label = label
              table.insert(entries, entry)
            end

            finish_spec(i, entries, nil)
          end)
        end)
      end)
    end)
  end
end

return M
