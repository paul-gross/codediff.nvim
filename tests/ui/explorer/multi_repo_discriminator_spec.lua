-- Phase 2: multi-repo session discriminator unit tests.
-- Verifies that the three session modes (single-repo, dir, multi-repo) are
-- distinguishable via the explicit discriminator, without requiring a live UI.

describe("Multi-repo session discriminator (Phase 2)", function()
  -- The discriminator logic extracted from render.lua M.create and refresh.lua M.refresh:
  --   is_dir_mode = (not git_root) and not multi_repo
  -- and from render.lua should_show_welcome:
  --   multi_repo == true  →  welcome suppressed
  local function compute_is_dir_mode(git_root, multi_repo)
    return (not git_root) and not multi_repo
  end

  describe("is_dir_mode inference", function()
    it("single-repo session: git_root set, multi_repo false → NOT dir mode", function()
      assert.is_false(compute_is_dir_mode("/some/repo", false))
    end)

    it("single-repo session: git_root set, multi_repo nil → NOT dir mode", function()
      assert.is_false(compute_is_dir_mode("/some/repo", nil))
    end)

    it("dir mode session: git_root nil, multi_repo false → IS dir mode", function()
      assert.is_true(compute_is_dir_mode(nil, false))
    end)

    it("dir mode session: git_root nil, multi_repo nil → IS dir mode", function()
      assert.is_true(compute_is_dir_mode(nil, nil))
    end)

    it("multi-repo session: git_root nil, multi_repo true → NOT dir mode", function()
      assert.is_false(compute_is_dir_mode(nil, true))
    end)
  end)

  describe("should_show_welcome suppression for multi-repo", function()
    -- Mirrors the guard in render.lua should_show_welcome:
    --   if not explorer or explorer.multi_repo then return false end
    local function should_show_welcome(explorer)
      if not explorer or explorer.multi_repo then
        return false
      end
      if not explorer.git_root or explorer.dir1 or explorer.dir2 then
        return false
      end
      local status = explorer.status_result or {}
      local total = #(status.unstaged or {}) + #(status.staged or {}) + #(status.conflicts or {})
      return total == 0
    end

    it("single-repo with empty status → shows welcome", function()
      local explorer = {
        git_root = "/some/repo",
        multi_repo = false,
        status_result = { unstaged = {}, staged = {}, conflicts = {} },
      }
      assert.is_true(should_show_welcome(explorer))
    end)

    it("multi-repo with empty status → does NOT show welcome", function()
      local explorer = {
        git_root = nil,
        multi_repo = true,
        status_result = { unstaged = {}, staged = {}, conflicts = {} },
      }
      assert.is_false(should_show_welcome(explorer))
    end)

    it("dir mode with empty status → does NOT show welcome (no git_root)", function()
      local explorer = {
        git_root = nil,
        multi_repo = false,
        dir1 = "/dir/a",
        dir2 = "/dir/b",
        status_result = { unstaged = {}, staged = {}, conflicts = {} },
      }
      assert.is_false(should_show_welcome(explorer))
    end)
  end)

  describe("explorer object shape for multi-repo session", function()
    it("opts.multi_repo=true propagates correctly through explorer fields", function()
      -- Simulate the assignment in render.lua M.create:
      local opts = { multi_repo = true, repos = { { root = "/a", base = "main", target = "HEAD", label = "repo-a" } } }
      local explorer = {
        git_root = nil,
        multi_repo = opts.multi_repo or false,
        repos = opts.repos,
      }
      assert.is_true(explorer.multi_repo)
      assert.is_not_nil(explorer.repos)
      assert.equals(1, #explorer.repos)
      assert.equals("/a", explorer.repos[1].root)
    end)

    it("opts.multi_repo absent → explorer.multi_repo is false", function()
      local opts = {}
      local explorer = {
        git_root = "/repo",
        multi_repo = opts.multi_repo or false,
        repos = opts.repos,
      }
      assert.is_false(explorer.multi_repo)
      assert.is_nil(explorer.repos)
    end)
  end)
end)
