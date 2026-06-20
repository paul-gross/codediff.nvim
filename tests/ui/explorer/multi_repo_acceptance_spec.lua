-- Phase 6: multi-repo acceptance matrix.
-- Proves the hardest correctness criteria:
--   a. Same-relpath collision — two repos each with README.md; distinct nodes,
--      correct per-root content, staging only touches the staged repo.
--   b. Navigation across repo boundary — next_file/prev_file + hunk cycling
--      crosses from repo A files into repo B files.
--   c. stage_all / unstage_all fan-out — operates per repo in explorer.repos.
--   d. Both list and repo view_mode expose all files via get_all_files.

local helpers = require("tests.helpers")
local multi_repo = require("codediff.core.multi_repo")
local actions_mod = require("codediff.ui.explorer.actions")
local refresh_mod = require("codediff.ui.explorer.refresh")
local nodes_mod = require("codediff.ui.explorer.nodes")
local tree_mod = require("codediff.ui.explorer.tree")
local config = require("codediff.config")
local git = require("codediff.core.git")
local Tree = require("codediff.ui.lib.tree")

-- ---------------------------------------------------------------------------
-- Helper: create a working-tree repo with staged/unstaged changes suitable
-- for stage_all / unstage_all tests (revision diff mode would have nothing
-- to stage — use git status mode instead).
-- Returns a repo handle where there is 1 unstaged modified file (feature.txt)
-- ---------------------------------------------------------------------------
local function make_git_status_repo(content_a, content_b)
  local repo = helpers.create_temp_git_repo()

  -- Commit the initial file
  repo.write_file("feature.txt", { content_a or "initial content" })
  repo.git("add feature.txt")
  repo.git("commit -m 'initial'")

  -- Modify the file in working tree (unstaged change)
  repo.write_file("feature.txt", { content_b or "modified content" })

  return repo
end

-- ---------------------------------------------------------------------------
-- Helper: wait for an async aggregate to complete and return the result.
-- ---------------------------------------------------------------------------
local function aggregate_wait(specs, timeout_ms)
  timeout_ms = timeout_ms or 8000
  local done = false
  local got_result, got_errors
  multi_repo.aggregate(specs, function(result, errors)
    got_result = result
    got_errors = errors
    done = true
  end)
  vim.wait(timeout_ms, function()
    return done
  end, 50)
  return done, got_result, got_errors
end

-- ---------------------------------------------------------------------------
-- Helper: build a minimal Tree object backed by a scratch buffer, populate
-- it with nodes, expand all top-level groups, and return { tree, all_files }.
-- ---------------------------------------------------------------------------
local function build_tree_with_status(status, git_root, is_dir_mode, multi_repo_flag)
  local root_nodes = tree_mod.create_tree_data(status, git_root, nil, is_dir_mode or false, nil, multi_repo_flag)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local tree = Tree.new({ bufnr = bufnr })
  tree:set_nodes(root_nodes)
  for _, node in ipairs(root_nodes) do
    node:expand()
    -- Also expand children (for repo/tree mode)
    if node:has_children() then
      for _, child_id in ipairs(node:get_child_ids()) do
        local child = tree:get_node(child_id)
        if child and child.data and child.data.type == "directory" then
          child:expand()
        end
      end
    end
  end
  return tree, refresh_mod.get_all_files(tree)
end

-- ---------------------------------------------------------------------------
-- Helper: run git -C <dir> diff --cached --name-only and return lines
-- ---------------------------------------------------------------------------
local function get_cached_files(repo_dir)
  local output = helpers.git_cmd(repo_dir, "diff --cached --name-only")
  if not output or output == "" then
    return {}
  end
  local lines = vim.split(vim.trim(output), "\n")
  local result = {}
  for _, l in ipairs(lines) do
    if l ~= "" then
      table.insert(result, l)
    end
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Helper: check whether there are staged changes in a repo
-- ---------------------------------------------------------------------------
local function has_staged_changes(repo_dir)
  local files = get_cached_files(repo_dir)
  return #files > 0
end

-- ===========================================================================
-- a. Same-relpath collision
-- ===========================================================================

describe("Phase 6a — same-relpath collision across two repos", function()
  local repo_a, repo_b

  before_each(function()
    config.setup({})

    -- Both repos have a README.md with DIFFERENT content
    repo_a = helpers.create_temp_git_repo()
    repo_a.write_file("README.md", { "Repo A original" })
    repo_a.git("add README.md")
    repo_a.git("commit -m 'base'")
    local base_a = vim.trim(repo_a.git("rev-parse HEAD"))
    repo_a.write_file("README.md", { "Repo A changed" })
    repo_a.git("add README.md")
    repo_a.git("commit -m 'target'")
    local target_a = vim.trim(repo_a.git("rev-parse HEAD"))
    repo_a._base = base_a
    repo_a._target = target_a

    repo_b = helpers.create_temp_git_repo()
    repo_b.write_file("README.md", { "Repo B original" })
    repo_b.git("add README.md")
    repo_b.git("commit -m 'base'")
    local base_b = vim.trim(repo_b.git("rev-parse HEAD"))
    repo_b.write_file("README.md", { "Repo B changed" })
    repo_b.git("add README.md")
    repo_b.git("commit -m 'target'")
    local target_b = vim.trim(repo_b.git("rev-parse HEAD"))
    repo_b._base = base_b
    repo_b._target = target_b
  end)

  after_each(function()
    if repo_a then
      repo_a.cleanup()
    end
    if repo_b then
      repo_b.cleanup()
    end
  end)

  it("aggregate produces TWO distinct nodes for the same relative path README.md", function()
    local specs = {
      { root = repo_a.dir, base = repo_a._base, target = repo_a._target, label = "repo-a" },
      { root = repo_b.dir, base = repo_b._base, target = repo_b._target, label = "repo-b" },
    }

    local done, result, errors = aggregate_wait(specs)

    assert.is_true(done, "aggregate must complete")
    assert.equals(0, #errors, "no errors expected: " .. vim.inspect(errors))

    -- Should have exactly 2 entries, both with path == "README.md"
    assert.equals(2, #result.unstaged, "must have 2 entries (one per repo)")

    local readme_entries = {}
    for _, e in ipairs(result.unstaged) do
      if e.path == "README.md" then
        table.insert(readme_entries, e)
      end
    end
    assert.equals(2, #readme_entries, "both entries must have path README.md")

    -- They must be distinct by git_root
    assert.are_not.equals(readme_entries[1].git_root, readme_entries[2].git_root,
      "entries must have different git_root")
  end)

  it("nodes built from aggregate have distinct identity (git_root in node.data)", function()
    local specs = {
      { root = repo_a.dir, base = repo_a._base, target = repo_a._target, label = "repo-a" },
      { root = repo_b.dir, base = repo_b._base, target = repo_b._target, label = "repo-b" },
    }

    local done, result = aggregate_wait(specs)
    assert.is_true(done, "aggregate must complete")

    config.options.explorer.view_mode = "list"
    local _, all_files = build_tree_with_status(result, nil, false)

    -- Both nodes must be present
    assert.equals(2, #all_files, "tree must expose both README.md file nodes")

    -- Both must have path == README.md but different git_root
    local roots_seen = {}
    for _, f in ipairs(all_files) do
      assert.equals("README.md", f.data.path, "path should be README.md")
      assert.is_not_nil(f.data.git_root, "node.data.git_root must be set")
      roots_seen[f.data.git_root] = true
    end
    assert.equals(2, vim.tbl_count(roots_seen), "two distinct git_roots in the nodes")
  end)

  it("get_file_content with per-entry git_root returns correct per-repo content", function()
    -- Verify: README.md at repo_a._target contains "Repo A changed"
    --         README.md at repo_b._target contains "Repo B changed"
    local done_a, content_a = false, nil
    git.get_file_content(repo_a._target, repo_a.dir, "README.md", function(err, lines)
      assert.is_nil(err, "should not error: " .. tostring(err))
      content_a = table.concat(lines or {}, "\n")
      done_a = true
    end)
    vim.wait(5000, function()
      return done_a
    end, 50)

    local done_b, content_b = false, nil
    git.get_file_content(repo_b._target, repo_b.dir, "README.md", function(err, lines)
      assert.is_nil(err, "should not error: " .. tostring(err))
      content_b = table.concat(lines or {}, "\n")
      done_b = true
    end)
    vim.wait(5000, function()
      return done_b
    end, 50)

    assert.is_true(done_a and done_b, "both content fetches must complete")

    -- Content must differ — each repo's version is correct
    assert.is_true(content_a:find("Repo A changed", 1, true) ~= nil,
      "repo_a README should contain 'Repo A changed', got: " .. tostring(content_a))
    assert.is_true(content_b:find("Repo B changed", 1, true) ~= nil,
      "repo_b README should contain 'Repo B changed', got: " .. tostring(content_b))
    assert.are_not.equals(content_a, content_b, "per-repo content must differ")
  end)

  it("staging README.md in repo_a ONLY affects repo_a index, not repo_b", function()
    -- Set up working-tree changes in both repos (not revision-diff)
    local work_a = helpers.create_temp_git_repo()
    work_a.write_file("README.md", { "A original" })
    work_a.git("add README.md")
    work_a.git("commit -m 'initial'")
    work_a.write_file("README.md", { "A modified" })

    local work_b = helpers.create_temp_git_repo()
    work_b.write_file("README.md", { "B original" })
    work_b.git("add README.md")
    work_b.git("commit -m 'initial'")
    work_b.write_file("README.md", { "B modified" })

    -- Verify both start with clean index
    assert.is_false(has_staged_changes(work_a.dir), "repo_a should start with clean index")
    assert.is_false(has_staged_changes(work_b.dir), "repo_b should start with clean index")

    -- Stage only repo_a's README.md (using the per-entry git_root)
    local done_stage = false
    git.stage_file(work_a.dir, "README.md", function(err)
      assert.is_nil(err, "stage_file should not error: " .. tostring(err))
      done_stage = true
    end)
    vim.wait(5000, function()
      return done_stage
    end, 50)
    assert.is_true(done_stage, "staging must complete")

    -- repo_a should now have README.md staged
    local staged_a = get_cached_files(work_a.dir)
    assert.is_true(vim.tbl_contains(staged_a, "README.md"),
      "repo_a README.md must be staged, got: " .. vim.inspect(staged_a))

    -- repo_b must remain clean
    assert.is_false(has_staged_changes(work_b.dir),
      "repo_b index must remain clean after staging repo_a only")

    work_a.cleanup()
    work_b.cleanup()
  end)
end)

-- ===========================================================================
-- b. Navigation across repo boundary
-- ===========================================================================

describe("Phase 6b — navigation across repo boundary", function()
  local repo_a, repo_b

  before_each(function()
    config.setup({})
    config.options.explorer.view_mode = "list"
    config.options.diff = config.options.diff or {}
    config.options.diff.cycle_next_file = true

    -- repo_a: has file_a.txt changed
    repo_a = helpers.create_temp_git_repo()
    repo_a.write_file("file_a.txt", { "file a content" })
    repo_a.git("add file_a.txt")
    repo_a.git("commit -m 'base'")
    local base_a = vim.trim(repo_a.git("rev-parse HEAD"))
    repo_a.write_file("file_a.txt", { "file a changed" })
    repo_a.git("add file_a.txt")
    repo_a.git("commit -m 'target'")
    local target_a = vim.trim(repo_a.git("rev-parse HEAD"))
    repo_a._base = base_a
    repo_a._target = target_a

    -- repo_b: has file_b.txt changed
    repo_b = helpers.create_temp_git_repo()
    repo_b.write_file("file_b.txt", { "file b content" })
    repo_b.git("add file_b.txt")
    repo_b.git("commit -m 'base'")
    local base_b = vim.trim(repo_b.git("rev-parse HEAD"))
    repo_b.write_file("file_b.txt", { "file b changed" })
    repo_b.git("add file_b.txt")
    repo_b.git("commit -m 'target'")
    local target_b = vim.trim(repo_b.git("rev-parse HEAD"))
    repo_b._base = base_b
    repo_b._target = target_b
  end)

  after_each(function()
    if repo_a then
      repo_a.cleanup()
    end
    if repo_b then
      repo_b.cleanup()
    end
  end)

  it("navigate_next crosses from repo A into repo B", function()
    local specs = {
      { root = repo_a.dir, base = repo_a._base, target = repo_a._target, label = "repo-a" },
      { root = repo_b.dir, base = repo_b._base, target = repo_b._target, label = "repo-b" },
    }

    local done, result = aggregate_wait(specs)
    assert.is_true(done, "aggregate must complete")
    assert.is_true(#result.unstaged >= 2, "need at least 2 files")

    -- Build tree and explorer stub
    local tree, all_files = build_tree_with_status(result, nil, false)

    local selected_data = {}
    local explorer = {
      git_root = nil,
      multi_repo = true,
      repos = {
        { root = repo_a.dir, base = repo_a._base, target = repo_a._target, label = "repo-a" },
        { root = repo_b.dir, base = repo_b._base, target = repo_b._target, label = "repo-b" },
      },
      tree = tree,
      winid = -1, -- invalid winid: skips visual cursor-move branch
      on_file_select = function(file_data)
        table.insert(selected_data, file_data)
      end,
      current_file_path = nil,
      current_file_group = nil,
      current_file_git_root = nil,
    }

    -- Call navigate_next from no selection → selects first file
    actions_mod.navigate_next(explorer)

    assert.equals(1, #selected_data, "navigate_next should have triggered on_file_select")
    local first = selected_data[1]
    local first_root = first.git_root

    -- Set explorer state as if on_file_select updated it
    explorer.current_file_path = first.path
    explorer.current_file_group = first.group
    explorer.current_file_git_root = first.git_root

    -- Navigate again → should cross to next file
    actions_mod.navigate_next(explorer)
    assert.equals(2, #selected_data, "second navigate_next should fire on_file_select again")
    local second = selected_data[2]

    -- Since there's one file per repo, the second file must be in the other repo
    assert.are_not.equals(first_root, second.git_root,
      "navigation must cross the repo boundary: first_root=" .. tostring(first_root)
      .. " second_root=" .. tostring(second.git_root))
  end)

  it("navigate_prev crosses from repo B back into repo A", function()
    local specs = {
      { root = repo_a.dir, base = repo_a._base, target = repo_a._target, label = "repo-a" },
      { root = repo_b.dir, base = repo_b._base, target = repo_b._target, label = "repo-b" },
    }

    local done, result = aggregate_wait(specs)
    assert.is_true(done, "aggregate must complete")
    assert.is_true(#result.unstaged >= 2, "need at least 2 files")

    local tree, all_files = build_tree_with_status(result, nil, false)

    local selected_data = {}
    local explorer = {
      git_root = nil,
      multi_repo = true,
      repos = {
        { root = repo_a.dir },
        { root = repo_b.dir },
      },
      tree = tree,
      winid = -1, -- invalid winid: skips visual cursor-move branch
      on_file_select = function(file_data)
        table.insert(selected_data, file_data)
      end,
      current_file_path = nil,
      current_file_group = nil,
      current_file_git_root = nil,
    }

    -- navigate_prev from no selection → selects last file
    actions_mod.navigate_prev(explorer)
    assert.equals(1, #selected_data, "navigate_prev should fire on_file_select")
    local last = selected_data[1]
    local last_root = last.git_root

    explorer.current_file_path = last.path
    explorer.current_file_group = last.group
    explorer.current_file_git_root = last.git_root

    -- navigate_prev again → should cross to previous file (different repo)
    actions_mod.navigate_prev(explorer)
    assert.equals(2, #selected_data, "second navigate_prev should fire on_file_select")
    local prev = selected_data[2]

    assert.are_not.equals(last_root, prev.git_root,
      "prev navigation must cross repo boundary: last_root=" .. tostring(last_root)
      .. " prev_root=" .. tostring(prev.git_root))
  end)

  it("all_files exposes files from both repos enabling cross-boundary hunk cycling", function()
    -- Validates get_all_files returns files from both repos; the caller (hunk cycling)
    -- iterates this list. Boundary crossing happens because list order interleaves repos.
    local specs = {
      { root = repo_a.dir, base = repo_a._base, target = repo_a._target, label = "repo-a" },
      { root = repo_b.dir, base = repo_b._base, target = repo_b._target, label = "repo-b" },
    }

    local done, result = aggregate_wait(specs)
    assert.is_true(done, "aggregate must complete")

    local tree, all_files = build_tree_with_status(result, nil, false)

    assert.is_true(#all_files >= 2, "get_all_files must return files from both repos")

    local roots = {}
    for _, f in ipairs(all_files) do
      roots[f.data.git_root] = true
    end
    -- Both repo roots must appear in the flat file list
    assert.is_not_nil(roots[repo_a.dir], "repo_a files must be in get_all_files result")
    assert.is_not_nil(roots[repo_b.dir], "repo_b files must be in get_all_files result")
  end)
end)

-- ===========================================================================
-- c. stage_all / unstage_all fan-out
-- ===========================================================================

describe("Phase 6c — stage_all / unstage_all fan-out", function()
  local work_a, work_b

  before_each(function()
    config.setup({})

    -- Two repos, each with an unstaged modified file
    work_a = make_git_status_repo("A original", "A modified")
    work_b = make_git_status_repo("B original", "B modified")

    -- Both start with a clean index
    assert.is_false(has_staged_changes(work_a.dir), "work_a must start clean")
    assert.is_false(has_staged_changes(work_b.dir), "work_b must start clean")
  end)

  after_each(function()
    if work_a then
      work_a.cleanup()
    end
    if work_b then
      work_b.cleanup()
    end
  end)

  it("stage_all fans out to both repos — both indexes staged after call", function()
    local explorer = {
      git_root = nil,
      multi_repo = true,
      repos = {
        { root = work_a.dir },
        { root = work_b.dir },
      },
      status_result = nil,
    }

    actions_mod.stage_all(explorer)

    -- Wait for async git ops to complete
    vim.wait(5000, function()
      return has_staged_changes(work_a.dir) and has_staged_changes(work_b.dir)
    end, 100)

    -- Both repos must have staged changes
    assert.is_true(has_staged_changes(work_a.dir),
      "work_a must have staged changes after stage_all")
    assert.is_true(has_staged_changes(work_b.dir),
      "work_b must have staged changes after stage_all")
  end)

  it("unstage_all fans out to both repos — both indexes clean after call", function()
    -- First stage both repos manually
    local staged_a = false
    local staged_b = false
    git.stage_all(work_a.dir, function()
      staged_a = true
    end)
    git.stage_all(work_b.dir, function()
      staged_b = true
    end)
    vim.wait(5000, function()
      return staged_a and staged_b
    end, 100)

    assert.is_true(has_staged_changes(work_a.dir), "work_a should be staged before unstage_all")
    assert.is_true(has_staged_changes(work_b.dir), "work_b should be staged before unstage_all")

    -- Now fan-out unstage_all
    local explorer = {
      git_root = nil,
      multi_repo = true,
      repos = {
        { root = work_a.dir },
        { root = work_b.dir },
      },
      status_result = nil,
    }

    actions_mod.unstage_all(explorer)

    -- Wait for async git ops to complete
    vim.wait(5000, function()
      return not has_staged_changes(work_a.dir) and not has_staged_changes(work_b.dir)
    end, 100)

    assert.is_false(has_staged_changes(work_a.dir),
      "work_a index must be clean after unstage_all")
    assert.is_false(has_staged_changes(work_b.dir),
      "work_b index must be clean after unstage_all")
  end)

  it("stage_all / unstage_all is a no-op notification for non-git (no git_root + no multi_repo)", function()
    local notified = false
    local original_notify = vim.notify
    vim.notify = function(msg, level, ...)
      if level == vim.log.levels.WARN then
        notified = true
      end
      original_notify(msg, level, ...)
    end

    local explorer = {
      git_root = nil,
      multi_repo = false,
    }

    actions_mod.stage_all(explorer)
    actions_mod.unstage_all(explorer)

    vim.notify = original_notify

    assert.is_true(notified, "should warn when not in git mode")
    -- repos are unchanged (no git ops ran)
    assert.is_false(has_staged_changes(work_a.dir), "work_a must remain unchanged")
    assert.is_false(has_staged_changes(work_b.dir), "work_b must remain unchanged")
  end)

  it("stage_all falls back to status_result entries when repos is absent", function()
    -- Explorer with multi_repo=true but repos=nil: fallback to status_result entries.
    local explorer = {
      git_root = nil,
      multi_repo = true,
      repos = nil,
      status_result = {
        unstaged = {
          { path = "feature.txt", git_root = work_a.dir },
          { path = "feature.txt", git_root = work_b.dir },
        },
        staged = {},
        conflicts = {},
      },
    }

    actions_mod.stage_all(explorer)

    vim.wait(5000, function()
      return has_staged_changes(work_a.dir) and has_staged_changes(work_b.dir)
    end, 100)

    assert.is_true(has_staged_changes(work_a.dir),
      "work_a staged via status_result fallback")
    assert.is_true(has_staged_changes(work_b.dir),
      "work_b staged via status_result fallback")
  end)
end)

-- ===========================================================================
-- d. Both view_mode="list" and view_mode="repo" expose all files
-- ===========================================================================

describe("Phase 6d — get_all_files exposes all files in both view modes", function()
  local repo_a, repo_b

  before_each(function()
    config.setup({})

    repo_a = helpers.create_temp_git_repo()
    repo_a.write_file("alpha.txt", { "alpha" })
    repo_a.git("add alpha.txt")
    repo_a.git("commit -m 'base'")
    local base_a = vim.trim(repo_a.git("rev-parse HEAD"))
    repo_a.write_file("alpha.txt", { "alpha changed" })
    repo_a.git("add alpha.txt")
    repo_a.git("commit -m 'target'")
    local target_a = vim.trim(repo_a.git("rev-parse HEAD"))
    repo_a._base = base_a
    repo_a._target = target_a

    repo_b = helpers.create_temp_git_repo()
    repo_b.write_file("beta.txt", { "beta" })
    repo_b.git("add beta.txt")
    repo_b.git("commit -m 'base'")
    local base_b = vim.trim(repo_b.git("rev-parse HEAD"))
    repo_b.write_file("beta.txt", { "beta changed" })
    repo_b.git("add beta.txt")
    repo_b.git("commit -m 'target'")
    local target_b = vim.trim(repo_b.git("rev-parse HEAD"))
    repo_b._base = base_b
    repo_b._target = target_b
  end)

  after_each(function()
    if repo_a then
      repo_a.cleanup()
    end
    if repo_b then
      repo_b.cleanup()
    end
  end)

  it("list mode and repo mode both surface all files from both repos", function()
    local specs = {
      { root = repo_a.dir, base = repo_a._base, target = repo_a._target, label = "proj-a" },
      { root = repo_b.dir, base = repo_b._base, target = repo_b._target, label = "proj-b" },
    }

    local done, result = aggregate_wait(specs)
    assert.is_true(done, "aggregate must complete")

    local total = #result.unstaged
    assert.is_true(total >= 2, "aggregate must have entries from both repos, got: " .. total)

    -- --- list mode ---
    config.options.explorer.view_mode = "list"
    local _, list_files = build_tree_with_status(result, nil, false)

    assert.equals(total, #list_files,
      string.format("list mode: expected %d files, got %d", total, #list_files))

    local list_roots = {}
    for _, f in ipairs(list_files) do
      list_roots[f.data.git_root] = true
    end
    assert.is_not_nil(list_roots[repo_a.dir], "list mode must expose repo_a files")
    assert.is_not_nil(list_roots[repo_b.dir], "list mode must expose repo_b files")

    -- --- repo mode ---
    config.options.explorer.view_mode = "repo"
    local _, repo_files = build_tree_with_status(result, nil, false, true)

    assert.equals(total, #repo_files,
      string.format("repo mode: expected %d files, got %d", total, #repo_files))

    local repo_roots = {}
    for _, f in ipairs(repo_files) do
      repo_roots[f.data.git_root] = true
    end
    assert.is_not_nil(repo_roots[repo_a.dir], "repo mode must expose repo_a files")
    assert.is_not_nil(repo_roots[repo_b.dir], "repo mode must expose repo_b files")
  end)

  it("list mode count matches repo mode count (no mode drops entries)", function()
    local specs = {
      { root = repo_a.dir, base = repo_a._base, target = repo_a._target, label = "proj-a" },
      { root = repo_b.dir, base = repo_b._base, target = repo_b._target, label = "proj-b" },
    }

    local done, result = aggregate_wait(specs)
    assert.is_true(done, "aggregate must complete")

    config.options.explorer.view_mode = "list"
    local _, list_files = build_tree_with_status(result, nil, false)

    config.options.explorer.view_mode = "repo"
    local _, repo_files = build_tree_with_status(result, nil, false, true)

    assert.equals(#list_files, #repo_files,
      string.format("file count mismatch: list=%d repo=%d", #list_files, #repo_files))
  end)
end)
