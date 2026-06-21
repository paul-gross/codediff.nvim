-- Refresh re-aggregation routing for multi-repo sessions (issue #6).
-- An uncommitted multi-repo session must re-run aggregate_uncommitted on refresh,
-- while a committed multi-repo session must re-run aggregate. The aggregation
-- functions are stubbed to record which one fires (and to skip the heavy
-- process_result path by not invoking the callback).

local refresh_mod = require("codediff.ui.explorer.refresh")
local multi_repo = require("codediff.core.multi_repo")
local Tree = require("codediff.ui.lib.tree")

-- Build a minimal explorer stub with a real (empty) Tree and a valid window so
-- refresh() passes its window-validity and collapsed-state collection guards.
local function make_explorer_stub(mode)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local tree = Tree.new({ bufnr = bufnr })
  tree:set_nodes({})
  return {
    is_hidden = false,
    winid = vim.api.nvim_get_current_win(),
    tree = tree,
    git_root = nil,
    multi_repo = true,
    multi_repo_mode = mode,
    repos = { { root = "/tmp/repo-a" }, { root = "/tmp/repo-b" } },
  }
end

describe("refresh re-aggregation routing (multi-repo)", function()
  local orig_aggregate, orig_uncommitted
  local called

  before_each(function()
    called = { committed = false, uncommitted = false, repos = nil }
    orig_aggregate = multi_repo.aggregate
    orig_uncommitted = multi_repo.aggregate_uncommitted
    -- Record-only stubs that intentionally do NOT invoke the callback, so the
    -- downstream process_result/tree rendering never runs in this unit test.
    multi_repo.aggregate = function(repos, _cb)
      called.committed = true
      called.repos = repos
    end
    multi_repo.aggregate_uncommitted = function(repos, _cb)
      called.uncommitted = true
      called.repos = repos
    end
  end)

  after_each(function()
    multi_repo.aggregate = orig_aggregate
    multi_repo.aggregate_uncommitted = orig_uncommitted
  end)

  it("uncommitted session re-runs aggregate_uncommitted, not aggregate", function()
    local explorer = make_explorer_stub("uncommitted")
    refresh_mod.refresh(explorer)
    assert.is_true(called.uncommitted, "aggregate_uncommitted must be called")
    assert.is_false(called.committed, "aggregate (committed) must NOT be called")
    assert.equals(explorer.repos, called.repos, "explorer.repos must be passed through")
  end)

  it("committed session re-runs aggregate, not aggregate_uncommitted", function()
    local explorer = make_explorer_stub("committed")
    refresh_mod.refresh(explorer)
    assert.is_true(called.committed, "aggregate (committed) must be called")
    assert.is_false(called.uncommitted, "aggregate_uncommitted must NOT be called")
  end)

  it("defaults to committed aggregation when multi_repo_mode is unset (back-compat)", function()
    local explorer = make_explorer_stub(nil)
    refresh_mod.refresh(explorer)
    assert.is_true(called.committed, "absent mode must fall back to committed aggregation")
    assert.is_false(called.uncommitted)
  end)
end)
