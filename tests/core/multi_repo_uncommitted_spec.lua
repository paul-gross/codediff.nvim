-- Multi-repo uncommitted (dirty) aggregation tests (issue #6).
-- Covers M.aggregate_uncommitted: working-tree status fan-out across N repos
-- preserving all three buckets (staged / unstaged / conflicts), repo tagging,
-- clean-repo omission, same-relpath collision, per-repo staging isolation,
-- and per-repo error isolation. Also covers the diff_repos_uncommitted entry point.

local helpers = require("tests.helpers")
local multi_repo = require("codediff.core.multi_repo")
local git = require("codediff.core.git")

-- Create a repo with one staged change, one unstaged change, and one untracked file.
--   staged.txt    -> committed then modified + `git add`  (staged bucket: M)
--   unstaged.txt  -> committed then modified, NOT added   (unstaged bucket: M)
--   untracked.txt -> new file, never added                (unstaged bucket: ??)
local function make_dirty_repo(prefix)
  local repo = helpers.create_temp_git_repo()
  repo.write_file("staged.txt", { prefix .. " staged base" })
  repo.write_file("unstaged.txt", { prefix .. " unstaged base" })
  repo.git("add .")
  repo.git("commit -m 'base'")

  repo.write_file("staged.txt", { prefix .. " staged change" })
  repo.git("add staged.txt")
  repo.write_file("unstaged.txt", { prefix .. " unstaged change" })
  repo.write_file("untracked.txt", { prefix .. " new" })

  return repo
end

-- Create a repo that is committed and clean (no working-tree changes).
local function make_clean_repo(prefix)
  local repo = helpers.create_temp_git_repo()
  repo.write_file("clean.txt", { prefix .. " content" })
  repo.git("add .")
  repo.git("commit -m 'base'")
  return repo
end

-- Create a repo with an active, unresolved merge conflict on conf.txt.
local function make_conflict_repo(prefix)
  local repo = helpers.create_temp_git_repo()
  repo.write_file("conf.txt", { prefix .. " base" })
  repo.git("add .")
  repo.git("commit -m 'base'")

  repo.git("checkout -b feature")
  repo.write_file("conf.txt", { prefix .. " feature change" })
  repo.git("add conf.txt")
  repo.git("commit -m 'feature'")

  repo.git("checkout main")
  repo.write_file("conf.txt", { prefix .. " main change" })
  repo.git("add conf.txt")
  repo.git("commit -m 'main'")

  -- Conflicting merge — leaves conf.txt with conflict markers and an unmerged index.
  repo.git("merge feature")
  return repo
end

local function aggregate_wait(roots, timeout_ms)
  timeout_ms = timeout_ms or 8000
  local done = false
  local got_result, got_errors
  multi_repo.aggregate_uncommitted(roots, function(result, errors)
    got_result = result
    got_errors = errors
    done = true
  end)
  vim.wait(timeout_ms, function()
    return done
  end, 50)
  return done, got_result, got_errors
end

local function roots_in_bucket(bucket)
  local roots = {}
  for _, e in ipairs(bucket or {}) do
    roots[e.git_root] = true
  end
  return roots
end

local function get_cached_files(repo_dir)
  local output = helpers.git_cmd(repo_dir, "diff --cached --name-only")
  if not output or output == "" then
    return {}
  end
  local result = {}
  for _, l in ipairs(vim.split(vim.trim(output), "\n")) do
    if l ~= "" then
      table.insert(result, l)
    end
  end
  return result
end

describe("multi_repo.aggregate_uncommitted", function()
  it("returns empty result for empty roots", function()
    local done, result, errors = aggregate_wait({})
    assert.is_true(done, "callback must be called")
    assert.is_not_nil(result)
    assert.equals(0, #result.unstaged)
    assert.equals(0, #result.staged)
    assert.equals(0, #result.conflicts)
    assert.equals(0, #errors)
  end)

  it("aggregates all three buckets across two dirty repos, tagged per repo", function()
    local repo1 = make_dirty_repo("r1")
    local repo2 = make_dirty_repo("r2")

    local done, result, errors = aggregate_wait({
      { root = repo1.dir, label = "repo-one" },
      { root = repo2.dir, label = "repo-two" },
    })

    assert.is_true(done, "callback must be called")
    assert.equals(0, #errors, "no errors expected: " .. vim.inspect(errors))

    -- staged bucket: staged.txt from each repo
    local staged_roots = roots_in_bucket(result.staged)
    assert.is_not_nil(staged_roots[repo1.dir], "repo1 staged entry must be present")
    assert.is_not_nil(staged_roots[repo2.dir], "repo2 staged entry must be present")

    -- unstaged bucket: unstaged.txt + untracked.txt from each repo
    local unstaged_roots = roots_in_bucket(result.unstaged)
    assert.is_not_nil(unstaged_roots[repo1.dir], "repo1 unstaged entries must be present")
    assert.is_not_nil(unstaged_roots[repo2.dir], "repo2 unstaged entries must be present")

    -- every entry across every bucket carries git_root + repo_label
    for _, bucket in ipairs({ "staged", "unstaged", "conflicts" }) do
      for _, e in ipairs(result[bucket]) do
        assert.is_not_nil(e.git_root, bucket .. " entry must carry git_root")
        assert.is_not_nil(e.repo_label, bucket .. " entry must carry repo_label")
        -- uncommitted entries must NOT carry revision tags (selects the working-tree path)
        assert.is_nil(e.base_revision, bucket .. " entry must not carry base_revision")
        assert.is_nil(e.target_revision, bucket .. " entry must not carry target_revision")
      end
    end

    -- labels honor the provided override
    local labels = {}
    for _, e in ipairs(result.staged) do
      labels[e.repo_label] = true
    end
    assert.is_true(labels["repo-one"] or labels["repo-two"], "provided labels must be used")

    repo1.cleanup()
    repo2.cleanup()
  end)

  it("omits clean repos and records no error for them", function()
    local dirty = make_dirty_repo("dirty")
    local clean = make_clean_repo("clean")

    local done, result, errors = aggregate_wait({
      { root = dirty.dir },
      { root = clean.dir },
    })

    assert.is_true(done)
    assert.equals(0, #errors, "clean repo must not produce an error")

    local all_roots = {}
    for _, bucket in ipairs({ "staged", "unstaged", "conflicts" }) do
      for _, e in ipairs(result[bucket]) do
        all_roots[e.git_root] = true
      end
    end
    assert.is_not_nil(all_roots[dirty.dir], "dirty repo must contribute entries")
    assert.is_nil(all_roots[clean.dir], "clean repo must be omitted (no entries)")

    dirty.cleanup()
    clean.cleanup()
  end)

  it("preserves the conflicts bucket tagged with the conflicting repo's root", function()
    local conflict = make_conflict_repo("cf")
    local dirty = make_dirty_repo("d")

    local done, result, errors = aggregate_wait({
      { root = conflict.dir, label = "conflicted" },
      { root = dirty.dir, label = "dirty" },
    })

    assert.is_true(done)
    assert.equals(0, #errors, "no errors expected: " .. vim.inspect(errors))

    assert.is_true(#result.conflicts >= 1, "conflicts bucket must hold the conflicted file")
    local found = false
    for _, e in ipairs(result.conflicts) do
      if e.git_root == conflict.dir and e.path == "conf.txt" then
        found = true
        assert.equals("conflicted", e.repo_label)
      end
    end
    assert.is_true(found, "conf.txt from the conflicted repo must be in the conflicts bucket")

    conflict.cleanup()
    dirty.cleanup()
  end)

  it("produces distinct entries for the same relative path across two repos", function()
    local repo_a = helpers.create_temp_git_repo()
    repo_a.write_file("README.md", { "A original" })
    repo_a.git("add .")
    repo_a.git("commit -m 'base'")
    repo_a.write_file("README.md", { "A modified" })

    local repo_b = helpers.create_temp_git_repo()
    repo_b.write_file("README.md", { "B original" })
    repo_b.git("add .")
    repo_b.git("commit -m 'base'")
    repo_b.write_file("README.md", { "B modified" })

    local done, result = aggregate_wait({ { root = repo_a.dir }, { root = repo_b.dir } })
    assert.is_true(done)

    local readme = {}
    for _, e in ipairs(result.unstaged) do
      if e.path == "README.md" then
        table.insert(readme, e)
      end
    end
    assert.equals(2, #readme, "both README.md entries must be present")
    assert.are_not.equals(readme[1].git_root, readme[2].git_root, "entries must have distinct git_root")

    repo_a.cleanup()
    repo_b.cleanup()
  end)

  it("per-file staging via entry git_root affects only that repo", function()
    local repo1 = make_dirty_repo("iso1")
    local repo2 = make_dirty_repo("iso2")

    local done, result = aggregate_wait({ { root = repo1.dir }, { root = repo2.dir } })
    assert.is_true(done)

    -- Find repo1's unstaged.txt entry and stage it via its own git_root.
    local target
    for _, e in ipairs(result.unstaged) do
      if e.git_root == repo1.dir and e.path == "unstaged.txt" then
        target = e
        break
      end
    end
    assert.is_not_nil(target, "repo1 unstaged.txt entry must exist")

    local staged = false
    git.stage_file(target.git_root, target.path, function(err)
      assert.is_nil(err, "stage_file should not error: " .. tostring(err))
      staged = true
    end)
    vim.wait(5000, function()
      return staged
    end, 50)

    assert.is_true(vim.tbl_contains(get_cached_files(repo1.dir), "unstaged.txt"), "repo1 unstaged.txt must now be staged")
    assert.is_false(vim.tbl_contains(get_cached_files(repo2.dir), "unstaged.txt"), "repo2 must NOT have unstaged.txt staged")

    repo1.cleanup()
    repo2.cleanup()
  end)

  it("records a per-repo error for an invalid root without dropping valid entries", function()
    local dirty = make_dirty_repo("ok")

    local done, result, errors = aggregate_wait({
      { root = "/tmp/not-a-git-repo-codediff-uncommitted-test", label = "bad" },
      { root = dirty.dir, label = "good" },
    })

    assert.is_true(done)
    assert.equals(1, #errors, "exactly one per-repo error expected")
    assert.equals("/tmp/not-a-git-repo-codediff-uncommitted-test", errors[1].root)
    assert.is_not_nil(errors[1].error)

    local all_roots = {}
    for _, bucket in ipairs({ "staged", "unstaged", "conflicts" }) do
      for _, e in ipairs(result[bucket]) do
        all_roots[e.git_root] = true
      end
    end
    assert.is_not_nil(all_roots[dirty.dir], "valid repo entries must survive the bad root")

    dirty.cleanup()
  end)

  it("accepts bare string roots and defaults label to the basename", function()
    local repo = make_dirty_repo("bare")

    local done, result = aggregate_wait({ repo.dir })
    assert.is_true(done)

    local expected_label = vim.fn.fnamemodify(repo.dir, ":t")
    assert.is_true(#result.staged >= 1)
    assert.equals(expected_label, result.staged[1].repo_label, "label must default to basename")

    repo.cleanup()
  end)
end)

describe("require('codediff').diff_repos_uncommitted end-to-end", function()
  local codediff

  before_each(function()
    codediff = require("codediff")
  end)

  it("is a function", function()
    assert.is_function(codediff.diff_repos_uncommitted)
  end)

  it("calls view.create with multi_repo + multi_repo_mode='uncommitted' and merged entries", function()
    local repo1 = make_dirty_repo("e1")
    local repo2 = make_dirty_repo("e2")

    local view = require("codediff.ui.view")
    local original_create = view.create
    local captured
    view.create = function(session_config)
      captured = session_config
    end

    codediff.diff_repos_uncommitted({ repo1.dir, repo2.dir })

    local ok = vim.wait(8000, function()
      return captured ~= nil
    end, 50)

    view.create = original_create

    assert.is_true(ok, "view.create should have been called")
    assert.equals("explorer", captured.mode)
    assert.is_nil(captured.git_root)
    assert.is_true(captured.explorer_data.multi_repo, "multi_repo must be true")
    assert.equals("uncommitted", captured.explorer_data.multi_repo_mode, "mode must be uncommitted")
    assert.equals(2, #captured.explorer_data.repos, "repos must carry both roots")

    local sr = captured.explorer_data.status_result
    local roots = {}
    for _, bucket in ipairs({ "staged", "unstaged", "conflicts" }) do
      for _, e in ipairs(sr[bucket]) do
        roots[e.git_root] = true
      end
    end
    assert.is_not_nil(roots[repo1.dir], "entries from repo1 must be present")
    assert.is_not_nil(roots[repo2.dir], "entries from repo2 must be present")

    repo1.cleanup()
    repo2.cleanup()
  end)

  it("errors (no crash) on an empty roots list", function()
    local notified = false
    local original_notify = vim.notify
    vim.notify = function(msg, level, ...)
      if level == vim.log.levels.ERROR then
        notified = true
      end
      original_notify(msg, level, ...)
    end

    codediff.diff_repos_uncommitted({})

    vim.notify = original_notify
    assert.is_true(notified, "empty roots must emit an ERROR notification")
  end)
end)
