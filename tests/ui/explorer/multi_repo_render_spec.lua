-- Phase 5: multi-repo explorer rendering unit tests.
-- Validates:
--   1. Flat "list" mode: per-row repo label rendered in each file row.
--   2. view_mode == "repo": tree partitioned into one group node per repo; get_all_files works.
--   3. toggle_view_mode: 3-state on multi-repo, 2-state on single-repo.

local helpers = require("tests.helpers")
local nodes_mod = require("codediff.ui.explorer.nodes")
local tree_mod = require("codediff.ui.explorer.tree")
local actions_mod = require("codediff.ui.explorer.actions")
local config = require("codediff.config")
local refresh_mod = require("codediff.ui.explorer.refresh")
local multi_repo = require("codediff.core.multi_repo")

--- Build a two-commit temp repo. Returns repo handle, base_hash, target_hash.
local function make_two_commit_repo(unique_filename)
  unique_filename = unique_filename or "changed.txt"
  local repo = helpers.create_temp_git_repo()

  repo.write_file("base.txt", { "base content" })
  repo.git("add base.txt")
  repo.git("commit -m 'base'")
  local base_hash = vim.trim(repo.git("rev-parse HEAD"))

  repo.write_file(unique_filename, { "changed content" })
  repo.git("add " .. unique_filename)
  repo.git("commit -m 'target'")
  local target_hash = vim.trim(repo.git("rev-parse HEAD"))

  return repo, base_hash, target_hash
end

--- Build a synthetic status_result with entries tagged with repo_label/git_root.
-- @param entries: list of { path, repo_label, git_root } tables
local function make_multi_repo_status(entries)
  local unstaged = {}
  for _, e in ipairs(entries) do
    table.insert(unstaged, {
      path = e.path,
      status = "M",
      repo_label = e.repo_label,
      git_root = e.git_root or "/fake/root/" .. (e.repo_label or "repo"),
    })
  end
  return { unstaged = unstaged, staged = {}, conflicts = {} }
end

-- =============================================================================
-- 1. Flat "list" mode: repo label appears in rendered text
-- =============================================================================

describe("Phase 5 — flat list mode repo label", function()
  local saved_view_mode

  before_each(function()
    config.setup({})
    saved_view_mode = config.options.explorer.view_mode
    config.options.explorer.view_mode = "list"
  end)

  after_each(function()
    config.options.explorer.view_mode = saved_view_mode
  end)

  it("includes repo_label in rendered row text when data.repo_label is set", function()
    local status = make_multi_repo_status({
      { path = "src/main.lua", repo_label = "repo-one", git_root = "/repo1" },
      { path = "src/main.lua", repo_label = "repo-two", git_root = "/repo2" },
    })

    -- Build flat nodes
    local file_nodes = nodes_mod.create_file_nodes(status.unstaged, nil, "unstaged")
    assert.equals(2, #file_nodes, "should have 2 file nodes")

    -- Prepare each node for rendering and check label presence
    local max_width = 80
    local rendered_texts = {}
    for _, node in ipairs(file_nodes) do
      local line = nodes_mod.prepare_node(node, max_width, nil, nil)
      table.insert(rendered_texts, line:content())
    end

    -- Each rendered row must contain its repo label
    assert.is_true(rendered_texts[1]:find("repo%-one", 1, false) ~= nil, "first row should contain 'repo-one', got: " .. rendered_texts[1])
    assert.is_true(rendered_texts[2]:find("repo%-two", 1, false) ~= nil, "second row should contain 'repo-two', got: " .. rendered_texts[2])
  end)

  it("two files with the same relative path render DISTINCTLY (different labels)", function()
    local status = make_multi_repo_status({
      { path = "README.md", repo_label = "alpha-repo", git_root = "/a" },
      { path = "README.md", repo_label = "beta-repo", git_root = "/b" },
    })

    local file_nodes = nodes_mod.create_file_nodes(status.unstaged, nil, "unstaged")
    local texts = {}
    for _, node in ipairs(file_nodes) do
      local line = nodes_mod.prepare_node(node, 80, nil, nil)
      table.insert(texts, line:content())
    end

    -- Both rows contain "README.md" (same filename)
    assert.is_true(texts[1]:find("README", 1, true) ~= nil, "first row should show filename")
    assert.is_true(texts[2]:find("README", 1, true) ~= nil, "second row should show filename")

    -- But they differ (different labels make them distinct)
    assert.are_not.equals(texts[1], texts[2], "same-filename rows must render distinctly")

    -- And each has its own label
    assert.is_true(texts[1]:find("alpha%-repo", 1, false) ~= nil, "first row must show alpha-repo")
    assert.is_true(texts[2]:find("beta%-repo", 1, false) ~= nil, "second row must show beta-repo")
  end)

  it("does NOT show any label for single-repo nodes (data.repo_label is nil)", function()
    local status = {
      unstaged = { { path = "src/init.lua", status = "M" } },
      staged = {},
      conflicts = {},
    }
    local file_nodes = nodes_mod.create_file_nodes(status.unstaged, "/single/repo", "unstaged")
    assert.equals(1, #file_nodes)
    assert.is_nil(file_nodes[1].data.repo_label, "single-repo node should have no repo_label")

    local line = nodes_mod.prepare_node(file_nodes[1], 80, nil, nil)
    local text = line:content()
    -- No parenthesised label should appear
    assert.is_true(text:find("%(") == nil, "single-repo row must not contain a repo label, got: " .. text)
  end)
end)

-- =============================================================================
-- 2. view_mode == "repo": group node per repo, files inside
-- =============================================================================

describe("Phase 5 — repo view mode tree structure", function()
  local saved_view_mode

  before_each(function()
    config.setup({})
    saved_view_mode = config.options.explorer.view_mode
    config.options.explorer.view_mode = "repo"
  end)

  after_each(function()
    config.options.explorer.view_mode = saved_view_mode
  end)

  it("creates exactly one group node per distinct repo_label", function()
    local status = make_multi_repo_status({
      { path = "a.lua", repo_label = "repo-A", git_root = "/a" },
      { path = "b.lua", repo_label = "repo-A", git_root = "/a" },
      { path = "c.lua", repo_label = "repo-B", git_root = "/b" },
    })

    local root_nodes = tree_mod.create_tree_data(status, nil, nil, false, nil, true)
    -- Should have exactly 2 group nodes (one per label)
    assert.equals(2, #root_nodes, "should have 2 repo group nodes, got " .. #root_nodes)

    local group_names = {}
    for _, node in ipairs(root_nodes) do
      assert.equals("group", node.data.type, "top-level node must be of type 'group'")
      table.insert(group_names, node.data.name)
    end

    -- Groups are named by repo_label
    assert.is_true(vim.tbl_contains(group_names, "repo-A"), "should have 'repo-A' group")
    assert.is_true(vim.tbl_contains(group_names, "repo-B"), "should have 'repo-B' group")
  end)

  it("each repo group contains only its own repo's files (via get_all_files)", function()
    local Tree = require("codediff.ui.lib.tree")
    local status = make_multi_repo_status({
      { path = "x.lua", repo_label = "repo-X", git_root = "/x" },
      { path = "y.lua", repo_label = "repo-X", git_root = "/x" },
      { path = "z.lua", repo_label = "repo-Y", git_root = "/y" },
    })

    local root_nodes = tree_mod.create_tree_data(status, nil, nil, false, nil, true)
    -- Expand all groups so get_all_files can recurse
    for _, node in ipairs(root_nodes) do
      node:expand()
    end

    -- Build a minimal tree object to test get_all_files
    -- Use the nui.tree compatible Tree from our lib
    local tree = Tree.new({ bufnr = vim.api.nvim_create_buf(false, true) })
    tree:set_nodes(root_nodes)
    for _, node in ipairs(root_nodes) do
      node:expand()
    end

    local all_files = refresh_mod.get_all_files(tree)
    -- Total: 2 from repo-X + 1 from repo-Y = 3
    assert.equals(3, #all_files, "get_all_files should return all 3 file nodes")

    -- Verify each file's repo_label
    local x_count = 0
    local y_count = 0
    for _, f in ipairs(all_files) do
      if f.data.repo_label == "repo-X" then
        x_count = x_count + 1
      end
      if f.data.repo_label == "repo-Y" then
        y_count = y_count + 1
      end
    end
    assert.equals(2, x_count, "repo-X should contribute 2 files")
    assert.equals(1, y_count, "repo-Y should contribute 1 file")
  end)

  it("repo group name matches repo_label (unique key for collapse-state persistence)", function()
    local status = make_multi_repo_status({
      { path = "f.lua", repo_label = "unique-label-1", git_root = "/r1" },
      { path = "f.lua", repo_label = "unique-label-2", git_root = "/r2" },
    })

    local root_nodes = tree_mod.create_tree_data(status, nil, nil, false, nil, true)
    assert.equals(2, #root_nodes)

    local names = {}
    for _, node in ipairs(root_nodes) do
      table.insert(names, node.data.name)
    end
    assert.is_true(vim.tbl_contains(names, "unique-label-1"), "group name must be 'unique-label-1'")
    assert.is_true(vim.tbl_contains(names, "unique-label-2"), "group name must be 'unique-label-2'")
    -- Names must be distinct so collapse state doesn't collide
    assert.are_not.equals(names[1], names[2], "group names must be distinct")
  end)
end)

-- =============================================================================
-- 3. toggle_view_mode: 3-state for multi-repo, 2-state for single-repo
-- =============================================================================

describe("Phase 5 — toggle_view_mode cycling", function()
  local saved_view_mode

  before_each(function()
    config.setup({})
    saved_view_mode = config.options.explorer.view_mode
  end)

  after_each(function()
    config.options.explorer.view_mode = saved_view_mode
  end)

  -- Stub refresh to a no-op for toggle tests
  local function make_noop_explorer(is_multi_repo)
    return {
      multi_repo = is_multi_repo or false,
      -- We will stub refresh; stub is applied in each test
    }
  end

  it("multi-repo explorer cycles list -> tree -> repo -> list", function()
    -- Stub refresh so it doesn't error (no real tree/bufnr)
    local original_refresh = refresh_mod.refresh
    refresh_mod.refresh = function() end

    local explorer = make_noop_explorer(true)

    config.options.explorer.view_mode = "list"
    actions_mod.toggle_view_mode(explorer)
    assert.equals("tree", config.options.explorer.view_mode, "list->tree on multi-repo")

    actions_mod.toggle_view_mode(explorer)
    assert.equals("repo", config.options.explorer.view_mode, "tree->repo on multi-repo")

    actions_mod.toggle_view_mode(explorer)
    assert.equals("list", config.options.explorer.view_mode, "repo->list on multi-repo")

    refresh_mod.refresh = original_refresh
  end)

  it("single-repo explorer cycles list -> tree -> list (no 'repo' step)", function()
    local original_refresh = refresh_mod.refresh
    refresh_mod.refresh = function() end

    local explorer = make_noop_explorer(false)

    config.options.explorer.view_mode = "list"
    actions_mod.toggle_view_mode(explorer)
    assert.equals("tree", config.options.explorer.view_mode, "list->tree on single-repo")

    actions_mod.toggle_view_mode(explorer)
    assert.equals("list", config.options.explorer.view_mode, "tree->list on single-repo (no repo step)")

    -- Repeat to confirm there is no "repo" in the cycle
    actions_mod.toggle_view_mode(explorer)
    assert.equals("tree", config.options.explorer.view_mode, "list->tree again")

    actions_mod.toggle_view_mode(explorer)
    assert.equals("list", config.options.explorer.view_mode, "tree->list again, no repo")

    refresh_mod.refresh = original_refresh
  end)

  it("explorer with multi_repo=nil treated as single-repo (2-state cycle)", function()
    local original_refresh = refresh_mod.refresh
    refresh_mod.refresh = function() end

    local explorer = { multi_repo = nil }

    config.options.explorer.view_mode = "list"
    actions_mod.toggle_view_mode(explorer)
    assert.equals("tree", config.options.explorer.view_mode)

    actions_mod.toggle_view_mode(explorer)
    assert.equals("list", config.options.explorer.view_mode)

    refresh_mod.refresh = original_refresh
  end)
end)

-- =============================================================================
-- 4. End-to-end: aggregate two real repos, verify render labels + repo groups
-- =============================================================================

describe("Phase 5 — aggregate + render integration", function()
  it("aggregate result produces labelled flat list nodes and repo group nodes", function()
    local repo1, base1, target1 = make_two_commit_repo("file_repo1.lua")
    local repo2, base2, target2 = make_two_commit_repo("file_repo2.lua")

    -- Use explicit labels
    local specs = {
      { root = repo1.dir, base = base1, target = target1, label = "project-one" },
      { root = repo2.dir, base = base2, target = target2, label = "project-two" },
    }

    local done = false
    local got_result = nil
    multi_repo.aggregate(specs, function(result, _errors)
      got_result = result
      done = true
    end)
    vim.wait(6000, function()
      return done
    end)
    assert.is_true(done, "aggregate must complete")
    assert.is_not_nil(got_result)

    -- --- Flat list mode ---
    config.options.explorer.view_mode = "list"
    local flat_nodes = nodes_mod.create_file_nodes(got_result.unstaged, nil, "unstaged")
    assert.is_true(#flat_nodes >= 2, "should have at least one file per repo")

    local found_label1, found_label2 = false, false
    for _, node in ipairs(flat_nodes) do
      local line = nodes_mod.prepare_node(node, 80, nil, nil)
      local text = line:content()
      if text:find("project%-one", 1, false) then
        found_label1 = true
      end
      if text:find("project%-two", 1, false) then
        found_label2 = true
      end
    end
    assert.is_true(found_label1, "flat list must show 'project-one' label")
    assert.is_true(found_label2, "flat list must show 'project-two' label")

    -- --- Repo group mode ---
    config.options.explorer.view_mode = "repo"
    local root_nodes = tree_mod.create_tree_data(got_result, nil, nil, false, nil, true)

    -- Should have exactly 2 group nodes
    assert.equals(2, #root_nodes, "repo mode must produce 2 group nodes for 2 repos")

    local group_names = {}
    for _, node in ipairs(root_nodes) do
      table.insert(group_names, node.data.name)
    end
    assert.is_true(vim.tbl_contains(group_names, "project-one"), "should have group 'project-one'")
    assert.is_true(vim.tbl_contains(group_names, "project-two"), "should have group 'project-two'")

    repo1.cleanup()
    repo2.cleanup()
  end)
end)

-- =============================================================================
-- 5. Regression: stale global view_mode="repo" must NOT corrupt single-repo renders
-- (must-fix 1)
-- =============================================================================

describe("must-fix 1 — stale global view_mode='repo' regression", function()
  local saved_view_mode

  before_each(function()
    config.setup({})
    saved_view_mode = config.options.explorer.view_mode
    -- Simulate leftover global state from a prior multi-repo session
    config.options.explorer.view_mode = "repo"
  end)

  after_each(function()
    config.options.explorer.view_mode = saved_view_mode
  end)

  it("single-repo status result with stale view_mode='repo' does NOT produce a single repo group", function()
    -- Files with NO repo_label (genuine single-repo)
    local status = {
      unstaged = {
        { path = "src/main.lua", status = "M" },
        { path = "src/util.lua", status = "A" },
      },
      staged = {},
      conflicts = {},
    }
    local git_root = "/single/repo"

    -- Call WITHOUT multi_repo=true (simulates single-repo caller)
    local root_nodes = tree_mod.create_tree_data(status, git_root, nil, false, nil, false)

    -- Must NOT produce a single repo-group node with a bogus label.
    -- Instead it falls back to the normal "Changes" group (list/tree layout).
    -- The normal layout yields exactly 1 group node named "unstaged".
    assert.is_not_nil(root_nodes, "must return nodes")
    assert.is_true(#root_nodes > 0, "must have at least one node")

    -- None of the top-level nodes should have a data.name that looks like a
    -- repo-group (i.e. a name other than "unstaged"/"staged"/"conflicts").
    for _, node in ipairs(root_nodes) do
      local name = node.data and node.data.name
      local is_normal_group = name == "unstaged" or name == "staged" or name == "conflicts"
      assert.is_true(is_normal_group, "top-level node must be a normal group (unstaged/staged/conflicts), got: " .. tostring(name))
    end
  end)

  it("dir-mode status result with stale view_mode='repo' falls back to normal layout", function()
    local status = {
      unstaged = {
        { path = "fileA.txt", status = "M" },
      },
      staged = {},
      conflicts = {},
    }

    -- Dir mode: git_root=nil, multi_repo=false (is_dir_mode=true)
    local root_nodes = tree_mod.create_tree_data(status, nil, nil, true, nil, false)

    assert.is_not_nil(root_nodes)
    assert.is_true(#root_nodes == 1, "dir mode must produce exactly one 'Changes' group")
    assert.equals("unstaged", root_nodes[1].data.name, "dir mode group must be named 'unstaged'")
  end)
end)

-- =============================================================================
-- 6. Regression: initial render directory expansion in repo mode (must-fix 2)
-- =============================================================================

describe("must-fix 2 — initial render expands directories in repo mode", function()
  local saved_view_mode

  before_each(function()
    config.setup({})
    saved_view_mode = config.options.explorer.view_mode
    config.options.explorer.view_mode = "repo"
  end)

  after_each(function()
    config.options.explorer.view_mode = saved_view_mode
  end)

  it("repo mode: inner directory nodes are expanded after create_tree_data + manual expansion (mirrors render.lua logic)", function()
    -- Construct a status where files are in subdirectories, tagged with a repo_label.
    local status = {
      unstaged = {
        { path = "src/a.lua", status = "M", repo_label = "repo-A", git_root = "/a" },
        { path = "src/b.lua", status = "M", repo_label = "repo-A", git_root = "/a" },
      },
      staged = {},
      conflicts = {},
    }

    local Tree = require("codediff.ui.lib.tree")
    local root_nodes = tree_mod.create_tree_data(status, nil, nil, false, nil, true)

    -- Mirror the expansion logic from render.lua for view_mode == "repo"
    -- (top-level group expand, then directory children expand)
    for _, node in ipairs(root_nodes) do
      if node.data and node.data.type == "group" then
        node:expand()
      end
    end

    local bufnr = vim.api.nvim_create_buf(false, true)
    local tree = Tree.new({ bufnr = bufnr })
    tree:set_nodes(root_nodes)

    -- The expansion block that render.lua now applies for "repo" mode too:
    local explorer_cfg = config.options.explorer or {}
    if explorer_cfg.view_mode == "tree" or explorer_cfg.view_mode == "repo" then
      local function expand_all_dirs(parent_node)
        if not parent_node:has_children() then
          return
        end
        for _, child_id in ipairs(parent_node:get_child_ids()) do
          local child = tree:get_node(child_id)
          if child and child.data and child.data.type == "directory" then
            child:expand()
            expand_all_dirs(child)
          end
        end
      end
      for _, node in ipairs(root_nodes) do
        expand_all_dirs(node)
      end
    end

    -- After expansion, get_all_files must see all files (not just collapsed dirs)
    local all_files = refresh_mod.get_all_files(tree)
    assert.equals(2, #all_files, "repo mode must expose all files after dir expansion, got: " .. #all_files)
  end)
end)
