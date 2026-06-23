-- Test: Git root is resolved from tab cwd, not from the focused buffer's directory

local h = dofile("tests/helpers.lua")

local function setup_command()
  local commands = require("codediff.commands")
  vim.api.nvim_create_user_command("CodeDiff", function(opts)
    commands.vscode_diff(opts)
  end, {
    nargs = "*",
    bang = true,
    complete = function()
      return { "file", "install" }
    end,
  })
end

describe("cwd root resolution", function()
  local original_cwd
  local repo_a
  local repo_b

  before_each(function()
    require("codediff").setup({ diff = { layout = "side-by-side" } })
    setup_command()

    original_cwd = vim.fn.getcwd()

    -- Create repo A (this will be the tab cwd)
    repo_a = h.create_temp_git_repo()
    repo_a.write_file("file_a.txt", { "repo a line 1", "repo a line 2" })
    repo_a.git("add file_a.txt")
    repo_a.git('commit -m "initial commit"')
    -- Leave an uncommitted change so the explorer has something to show
    repo_a.write_file("file_a.txt", { "repo a line 1 modified", "repo a line 2" })

    -- Create repo B (a buffer from here will be open, but cwd will be repo A)
    repo_b = h.create_temp_git_repo()
    repo_b.write_file("file_b.txt", { "repo b line 1", "repo b line 2" })
    repo_b.git("add file_b.txt")
    repo_b.git('commit -m "initial commit"')
    -- Leave an uncommitted change in repo B as well
    repo_b.write_file("file_b.txt", { "repo b line 1 modified", "repo b line 2" })
  end)

  after_each(function()
    local lifecycle = require("codediff.ui.lifecycle")
    lifecycle.cleanup_all()
    vim.cmd("tabnew")
    vim.cmd("tabonly")
    vim.fn.chdir(original_cwd)
    vim.wait(100)
    repo_a.cleanup()
    repo_b.cleanup()
  end)

  it("resolves git root from tab cwd when buffer is in a different repo", function()
    local lifecycle = require("codediff.ui.lifecycle")

    -- Set cwd to repo A — this is what :CodeDiff should use
    vim.fn.chdir(repo_a.dir)

    -- Open a buffer whose path lives inside repo B
    vim.cmd("edit " .. repo_b.path("file_b.txt"))

    -- Confirm the buffer is indeed pointing at repo B's file
    local buf_name = vim.api.nvim_buf_get_name(0)
    assert.is_true(buf_name:find(repo_b.dir, 1, true) ~= nil, "Buffer should be in repo B")

    -- Run :CodeDiff — should open explorer rooted at repo A (the cwd)
    vim.cmd("CodeDiff")

    -- Wait for the explorer session to appear
    local tabpage
    local ready = vim.wait(6000, function()
      for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
        local session = lifecycle.get_session(tp)
        if session and session.mode == "explorer" and session.git_root then
          tabpage = tp
          return true
        end
      end
      return false
    end, 50)

    assert.is_true(ready, "Explorer session should be created")

    local session = lifecycle.get_session(tabpage)
    assert.is_not_nil(session, "Session should exist")
    assert.is_not_nil(session.git_root, "Session should have git_root")

    -- The git_root must be repo A's root, not repo B's
    local got = vim.fn.fnamemodify(session.git_root, ":p"):gsub("[/\\]$", "")
    local want = vim.fn.fnamemodify(repo_a.dir, ":p"):gsub("[/\\]$", "")
    assert.equal(want, got, "git_root should be repo A (cwd), not repo B (buffer path)")
  end)
end)
