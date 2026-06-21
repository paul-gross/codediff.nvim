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

--- Aggregate uncommitted (working-tree) changes across multiple repo roots.
-- The dirty-state counterpart of M.aggregate: instead of a base..target
-- revision diff per repo, this fans out git.get_status across N roots and
-- merges every repo's working-tree status into one status_result, preserving
-- ALL THREE buckets (staged / unstaged / conflicts) across repos.
--
-- Each root may be a string path or a table { root=string, label=string? }
-- (positional { root } also accepted), mirroring how M.aggregate accepts specs.
--
-- The callback receives (merged_status_result, errors) where:
--   merged_status_result = { unstaged = {...}, staged = {...}, conflicts = {...} }
--   errors = list of { root=string, error=string } (may be empty)
-- One invalid/non-git root records a per-repo error and continues; the rest of
-- the repos are still processed. Repos with no dirty files contribute no
-- entries, so they are naturally omitted from the merged result.
--
-- Each file entry in the merged result carries:
--   entry.git_root   = canonical git root for the repo
--   entry.repo_label = human-readable repo label (basename by default)
-- (No base_revision/target_revision — the working-tree path in the explorer is
--  selected by their absence, mirroring a single-repo uncommitted session.)
--
-- @param roots table: list of root strings or { root, label? } tables
-- @param callback function: function(merged_status_result, errors)
function M.aggregate_uncommitted(roots, callback)
  if not roots or #roots == 0 then
    callback({ unstaged = {}, staged = {}, conflicts = {} }, {})
    return
  end

  local total = #roots
  local pending = total
  -- Per-root ordered results: index i holds { buckets, err } for roots[i]
  local results = {}
  for i = 1, total do
    results[i] = nil
  end
  local errors = {}

  -- Normalise a roots[i] element to (root_path, label?)
  local function unpack_root(r)
    if type(r) == "table" then
      return r.root or r[1], r.label
    end
    return r, nil
  end

  local function finish_root(i, buckets, err, root_path)
    results[i] = { buckets = buckets, err = err }
    if err then
      table.insert(errors, { root = root_path, error = err })
    end

    pending = pending - 1
    if pending == 0 then
      -- Merge all buckets in root input order, preserving each repo's
      -- staged/unstaged/conflicts contents.
      local merged = { unstaged = {}, staged = {}, conflicts = {} }
      for _, result in ipairs(results) do
        if result.buckets then
          for _, bucket in ipairs({ "unstaged", "staged", "conflicts" }) do
            for _, entry in ipairs(result.buckets[bucket] or {}) do
              table.insert(merged[bucket], entry)
            end
          end
        end
      end
      callback(merged, errors)
    end
  end

  for i, r in ipairs(roots) do
    local root_path, label = unpack_root(r)

    -- Validate that root is a git repo by resolving its canonical root.
    git.get_git_root(root_path, function(err_root, canonical_root)
      if err_root then
        finish_root(i, nil, "Not a git repository: " .. tostring(err_root), root_path)
        return
      end

      local repo_label = label or vim.fn.fnamemodify(canonical_root, ":t")

      git.get_status(canonical_root, function(err_status, status_result)
        if err_status then
          finish_root(i, nil, "Failed to get status: " .. tostring(err_status), root_path)
          return
        end

        -- Tag every entry across all three buckets with per-repo metadata.
        local buckets = { unstaged = {}, staged = {}, conflicts = {} }
        for _, bucket in ipairs({ "unstaged", "staged", "conflicts" }) do
          for _, entry in ipairs(status_result[bucket] or {}) do
            entry.git_root = canonical_root
            entry.repo_label = repo_label
            table.insert(buckets[bucket], entry)
          end
        end

        finish_root(i, buckets, nil, root_path)
      end)
    end)
  end
end

return M
