-- Phase 3: multi_repo aggregation unit tests.
-- Creates two independent temp git repos, runs aggregate(), and asserts that
-- entries from both repos are present and correctly tagged.
-- Also verifies per-repo error isolation: an invalid root records an error
-- without dropping the valid repo's entries.

local helpers = require("tests.helpers")
local multi_repo = require("codediff.core.multi_repo")

--- Create a temp git repo with:
--   base commit: file "base.txt" containing base_content
--   target commit: file "changed.txt" added (so there is a diff vs base)
-- Returns the repo handle (with .dir, .cleanup, etc.) plus base_hash, target_hash.
local function make_two_commit_repo(repo_name, base_content, target_content)
  local repo = helpers.create_temp_git_repo()

  -- Base commit
  repo.write_file("base.txt", { base_content or "base" })
  repo.git("add base.txt")
  repo.git("commit -m 'base commit'")
  local base_out = repo.git("rev-parse HEAD")
  local base_hash = vim.trim(base_out)

  -- Target commit: add a new file
  repo.write_file("changed.txt", { target_content or "changed" })
  repo.git("add changed.txt")
  repo.git("commit -m 'target commit'")
  local target_out = repo.git("rev-parse HEAD")
  local target_hash = vim.trim(target_out)

  return repo, base_hash, target_hash
end

describe("multi_repo.aggregate (Phase 3)", function()
  it("returns empty result for empty specs", function()
    local done = false
    local got_result = nil
    local got_errors = nil

    multi_repo.aggregate({}, function(result, errors)
      got_result = result
      got_errors = errors
      done = true
    end)

    vim.wait(2000, function()
      return done
    end)

    assert.is_true(done, "callback must be called")
    assert.is_not_nil(got_result)
    assert.equals(0, #got_result.unstaged)
    assert.equals(0, #got_errors)
  end)

  it("aggregates entries from two independent repos with correct tags", function()
    local repo1, base1, target1 = make_two_commit_repo("repo1", "repo1-base", "repo1-changed")
    local repo2, base2, target2 = make_two_commit_repo("repo2", "repo2-base", "repo2-changed")

    local done = false
    local got_result = nil
    local got_errors = nil

    local specs = {
      { root = repo1.dir, base = base1, target = target1, label = "repo-one" },
      { root = repo2.dir, base = base2, target = target2, label = "repo-two" },
    }

    multi_repo.aggregate(specs, function(result, errors)
      got_result = result
      got_errors = errors
      done = true
    end)

    vim.wait(5000, function()
      return done
    end)

    assert.is_true(done, "callback must be called")
    assert.is_not_nil(got_result)

    -- No errors for valid repos
    assert.equals(0, #got_errors, "no errors expected for valid repos")

    -- Both repos contributed at least one entry (changed.txt in each)
    assert.is_true(#got_result.unstaged >= 2, "merged result must have entries from both repos, got: " .. #got_result.unstaged)

    -- Collect entries by repo_label for easier assertions
    local by_label = {}
    for _, entry in ipairs(got_result.unstaged) do
      by_label[entry.repo_label] = by_label[entry.repo_label] or {}
      table.insert(by_label[entry.repo_label], entry)
    end

    assert.is_not_nil(by_label["repo-one"], "entries from repo-one must be present")
    assert.is_not_nil(by_label["repo-two"], "entries from repo-two must be present")

    -- Verify tags on repo-one entries
    for _, entry in ipairs(by_label["repo-one"]) do
      assert.equals(repo1.dir, entry.git_root, "git_root must match repo1.dir")
      assert.equals(base1, entry.base_revision, "base_revision must match resolved base1 hash")
      assert.equals(target1, entry.target_revision, "target_revision must match resolved target1 hash")
      assert.equals("repo-one", entry.repo_label, "repo_label must be 'repo-one'")
    end

    -- Verify tags on repo-two entries
    for _, entry in ipairs(by_label["repo-two"]) do
      assert.equals(repo2.dir, entry.git_root, "git_root must match repo2.dir")
      assert.equals(base2, entry.base_revision, "base_revision must match resolved base2 hash")
      assert.equals(target2, entry.target_revision, "target_revision must match resolved target2 hash")
      assert.equals("repo-two", entry.repo_label, "repo_label must be 'repo-two'")
    end

    -- staged and conflicts buckets are always empty (revision diff mode)
    assert.equals(0, #(got_result.staged or {}))
    assert.equals(0, #(got_result.conflicts or {}))

    repo1.cleanup()
    repo2.cleanup()
  end)

  it("uses basename as default label when label is not provided", function()
    local repo1, base1, target1 = make_two_commit_repo("repo1-nolabel")

    local done = false
    local got_result = nil

    -- No label field — basename of dir should be used
    local specs = {
      { root = repo1.dir, base = base1, target = target1 },
    }

    multi_repo.aggregate(specs, function(result, _errors)
      got_result = result
      done = true
    end)

    vim.wait(5000, function()
      return done
    end)

    assert.is_true(done, "callback must be called")
    assert.is_true(#got_result.unstaged >= 1, "must have at least one entry")

    local entry = got_result.unstaged[1]
    local expected_label = vim.fn.fnamemodify(repo1.dir, ":t")
    assert.equals(expected_label, entry.repo_label, "default label should be basename of root")

    repo1.cleanup()
  end)

  it("records per-repo error for invalid root WITHOUT dropping valid repo entries", function()
    local repo1, base1, target1 = make_two_commit_repo("repo1-error-isolation")

    local done = false
    local got_result = nil
    local got_errors = nil

    local specs = {
      -- Invalid (non-git) root goes first so it fires its callback before the valid one
      { root = "/tmp/this-is-not-a-git-repo-codediff-test", base = "HEAD", target = "HEAD", label = "bad-repo" },
      { root = repo1.dir, base = base1, target = target1, label = "good-repo" },
    }

    multi_repo.aggregate(specs, function(result, errors)
      got_result = result
      got_errors = errors
      done = true
    end)

    vim.wait(5000, function()
      return done
    end)

    assert.is_true(done, "callback must be called")

    -- Should have exactly one error (for the bad repo)
    assert.equals(1, #got_errors, "exactly one per-repo error expected")
    assert.equals("/tmp/this-is-not-a-git-repo-codediff-test", got_errors[1].root)
    assert.is_not_nil(got_errors[1].error)

    -- Valid repo's entries must still be present
    assert.is_true(#got_result.unstaged >= 1, "valid repo entries must survive despite error in other repo")

    local good_entries = {}
    for _, entry in ipairs(got_result.unstaged) do
      if entry.repo_label == "good-repo" then
        table.insert(good_entries, entry)
      end
    end
    assert.is_true(#good_entries >= 1, "good-repo entries must be present in merged result")

    -- Tags on good entries must be correct
    for _, entry in ipairs(good_entries) do
      assert.equals(repo1.dir, entry.git_root)
      assert.equals(base1, entry.base_revision)
      assert.equals(target1, entry.target_revision)
    end

    repo1.cleanup()
  end)

  it("preserves spec input order in merged result", function()
    local repo1, base1, target1 = make_two_commit_repo("repo-order-1", "a", "a-changed")
    local repo2, base2, target2 = make_two_commit_repo("repo-order-2", "b", "b-changed")

    local done = false
    local got_result = nil

    local specs = {
      { root = repo1.dir, base = base1, target = target1, label = "first" },
      { root = repo2.dir, base = base2, target = target2, label = "second" },
    }

    multi_repo.aggregate(specs, function(result, _errors)
      got_result = result
      done = true
    end)

    vim.wait(5000, function()
      return done
    end)

    assert.is_true(done, "callback must be called")
    assert.is_true(#got_result.unstaged >= 2)

    -- Entries from "first" must all appear before entries from "second"
    local first_seen = false
    local second_seen = false
    local order_ok = true
    for _, entry in ipairs(got_result.unstaged) do
      if entry.repo_label == "first" then
        first_seen = true
        if second_seen then
          order_ok = false
        end
      elseif entry.repo_label == "second" then
        second_seen = true
      end
    end

    assert.is_true(order_ok, "entries from first spec must precede entries from second spec")
    assert.is_true(first_seen, "first spec entries must be present")
    assert.is_true(second_seen, "second spec entries must be present")

    repo1.cleanup()
    repo2.cleanup()
  end)
end)
