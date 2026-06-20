-- Tree data structure building for explorer
-- Handles creating the tree hierarchy from git status
local M = {}

local Tree = require("codediff.ui.lib.tree")
local config = require("codediff.config")
local filter = require("codediff.ui.explorer.filter")
local nodes = require("codediff.ui.explorer.nodes")

-- Filter files based on explorer.file_filter config
-- Returns files that should be shown (not ignored)
local function filter_files(files)
  local explorer_config = config.options.explorer or {}
  local file_filter = explorer_config.file_filter or {}
  local ignore_patterns = file_filter.ignore or {}

  return filter.apply(files, ignore_patterns)
end

-- Build a per-repo group node: inner folder-tree of that repo's files (all in "unstaged" group).
-- Used exclusively by view_mode == "repo".
local function create_repo_group_node(repo_label, git_root, files)
  local inner_nodes = nodes.create_tree_file_nodes(files, git_root, "unstaged")
  return Tree.Node({
    -- Use repo_label as both text and the collapse-state key (via node.data.name).
    text = string.format("%s (%d)", repo_label, #files),
    data = { type = "group", name = repo_label },
  }, inner_nodes)
end

-- Create tree data structure from git status result
-- @param multi_repo boolean?: true when the caller is a genuine multi-repo session.
--   When view_mode is "repo" but multi_repo is falsy the function falls back to the
--   normal tree/list layout so that a stale global view_mode cannot corrupt a
--   single-repo or dir-mode render.
function M.create_tree_data(status_result, git_root, base_revision, is_dir_mode, visible_groups, multi_repo)
  local explorer_config = config.options.explorer or {}
  local view_mode = explorer_config.view_mode or "list"
  visible_groups = visible_groups or explorer_config.visible_groups or {}

  -- Filter merge artifacts and apply file filter
  local unstaged = nodes.filter_merge_artifacts(filter_files(status_result.unstaged))
  local staged = nodes.filter_merge_artifacts(filter_files(status_result.staged))
  local conflicts = status_result.conflicts and nodes.filter_merge_artifacts(filter_files(status_result.conflicts)) or {}

  -- Repo-grouped view: partition the merged file list by repo and emit one group node per repo.
  -- Only makes sense for multi-repo sessions (files carry repo_label + git_root).
  -- Guard: fall back to normal layout when view_mode is "repo" but the session is
  -- not genuinely multi-repo (e.g. the global was left stale after a previous multi-repo
  -- session and the current caller is single-repo or dir-mode).
  if view_mode == "repo" and multi_repo then
    -- Merge all files into one list, preserving order (unstaged first, then staged, then conflicts).
    local all_files = {}
    for _, f in ipairs(unstaged) do
      table.insert(all_files, f)
    end
    for _, f in ipairs(staged) do
      table.insert(all_files, f)
    end
    for _, f in ipairs(conflicts) do
      table.insert(all_files, f)
    end

    -- Partition by repo_label, preserving first-seen order of labels.
    local by_label = {}
    local label_order = {}
    local label_root = {} -- repo_label -> git_root mapping

    for _, file in ipairs(all_files) do
      local label = file.repo_label or (file.git_root and vim.fn.fnamemodify(file.git_root, ":t")) or "unknown"
      if not by_label[label] then
        by_label[label] = {}
        label_root[label] = file.git_root or git_root
        table.insert(label_order, label)
      end
      table.insert(by_label[label], file)
    end

    local repo_group_nodes = {}
    for _, label in ipairs(label_order) do
      table.insert(repo_group_nodes, create_repo_group_node(label, label_root[label], by_label[label]))
    end
    return repo_group_nodes
  end

  local create_nodes = (view_mode == "tree") and nodes.create_tree_file_nodes or nodes.create_file_nodes
  local unstaged_nodes = create_nodes(unstaged, git_root, "unstaged")
  local staged_nodes = create_nodes(staged, git_root, "staged")
  local conflict_nodes = create_nodes(conflicts, git_root, "conflicts")

  if is_dir_mode or base_revision then
    -- Dir or revision mode: single group showing all changes
    return {
      Tree.Node({
        text = string.format("Changes (%d)", #unstaged),
        data = { type = "group", name = "unstaged" },
      }, unstaged_nodes),
    }
  else
    -- Status mode: separate conflicts/staged/unstaged groups
    local tree_nodes = {}

    -- Conflicts first (most important)
    if #conflict_nodes > 0 and visible_groups.conflicts ~= false then
      table.insert(
        tree_nodes,
        Tree.Node({
          text = string.format("Merge Changes (%d)", #conflicts),
          data = { type = "group", name = "conflicts" },
        }, conflict_nodes)
      )
    end

    -- Unstaged changes
    if visible_groups.unstaged ~= false then
      table.insert(
        tree_nodes,
        Tree.Node({
          text = string.format("Changes (%d)", #unstaged),
          data = { type = "group", name = "unstaged" },
        }, unstaged_nodes)
      )
    end

    -- Staged changes
    if visible_groups.staged ~= false then
      table.insert(
        tree_nodes,
        Tree.Node({
          text = string.format("Staged Changes (%d)", #staged),
          data = { type = "group", name = "staged" },
        }, staged_nodes)
      )
    end

    return tree_nodes
  end
end

return M
