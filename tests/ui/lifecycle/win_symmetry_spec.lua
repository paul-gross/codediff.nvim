-- Phase 3 window-option symmetry probe.
-- Verifies that scrollbind / wrap / cursorline / list are:
--   (a) set to codediff's values while the diff is alive, and
--   (b) fully restored to the user's pre-diff values on cleanup.
--
-- Uses lifecycle.create_session + effects.set_win_opt to simulate the
-- render.lua path without opening a real diff tab (no side-effects from
-- side_by_side.lua, async git fetch, etc.).

local lifecycle = require("codediff.ui.lifecycle")
local effects = require("codediff.ui.lifecycle.effects")
local highlights = require("codediff.ui.highlights")
local diff = require("codediff.core.diff")

describe("window option symmetry (Phase 3 effects ledger)", function()
  local left_buf, right_buf, left_win, right_win, tabpage

  before_each(function()
    highlights.setup()
    lifecycle.setup()

    left_buf = vim.api.nvim_create_buf(false, true)
    right_buf = vim.api.nvim_create_buf(false, true)

    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, { "hello", "world" })
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, { "hello", "earth" })

    vim.cmd("tabnew")
    tabpage = vim.api.nvim_get_current_tabpage()
    vim.cmd("vsplit")
    left_win = vim.fn.win_getid(1)
    right_win = vim.fn.win_getid(2)
    vim.api.nvim_win_set_buf(left_win, left_buf)
    vim.api.nvim_win_set_buf(right_win, right_buf)
  end)

  after_each(function()
    lifecycle.cleanup_all()
    pcall(vim.cmd, "tabclose!")
    pcall(vim.api.nvim_buf_delete, left_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, right_buf, { force = true })
  end)

  it("restores scrollbind / wrap / cursorline / list to pre-diff values on cleanup", function()
    -- ----------------------------------------------------------------
    -- Step 1: establish known non-default user values on both windows
    -- ----------------------------------------------------------------
    local pre = {
      scrollbind = false,
      wrap = true,
      cursorline = false,
      list = false,
    }
    for opt, val in pairs(pre) do
      vim.wo[left_win][opt] = val
      vim.wo[right_win][opt] = val
    end

    -- ----------------------------------------------------------------
    -- Step 2: open diff (create_session)
    -- ----------------------------------------------------------------
    local lines_diff = diff.compute_diff(vim.api.nvim_buf_get_lines(left_buf, 0, -1, false), vim.api.nvim_buf_get_lines(right_buf, 0, -1, false))
    lifecycle.create_session(tabpage, "standalone", nil, "a.txt", "b.txt", "WORKING", "WORKING", left_buf, right_buf, left_win, right_win, lines_diff)

    local sess = lifecycle.get_session(tabpage)
    assert.is_not_nil(sess, "session should exist after create_session")

    -- ----------------------------------------------------------------
    -- Step 3: simulate render.lua writing codediff's window options
    -- (pre-seed with user originals so the ledger is correct even
    --  though we're bypassing the real preseed in side_by_side.lua)
    -- ----------------------------------------------------------------
    local codediff_vals = {
      scrollbind = true,
      wrap = false,
      cursorline = true,
      list = false,
    }
    for opt, cdval in pairs(codediff_vals) do
      effects.preseed_win_opt(sess, left_win, opt, pre[opt], cdval)
      effects.preseed_win_opt(sess, right_win, opt, pre[opt], cdval)
    end

    -- ----------------------------------------------------------------
    -- Step 4: assert diff is alive and options are codediff values
    -- ----------------------------------------------------------------
    assert.is_true(vim.wo[left_win].scrollbind, "scrollbind should be TRUE on left_win while diff is alive")
    assert.is_true(vim.wo[right_win].scrollbind, "scrollbind should be TRUE on right_win while diff is alive")
    assert.is_false(vim.wo[left_win].wrap, "wrap should be false on left_win during diff")
    assert.is_false(vim.wo[right_win].wrap, "wrap should be false on right_win during diff")

    -- ----------------------------------------------------------------
    -- Step 5: cleanup and assert restoration
    -- ----------------------------------------------------------------
    lifecycle.cleanup(tabpage)

    for opt, user_val in pairs(pre) do
      assert.equal(user_val, vim.wo[left_win][opt], ("left_win.%s should be restored to user value %s"):format(opt, tostring(user_val)))
      assert.equal(user_val, vim.wo[right_win][opt], ("right_win.%s should be restored to user value %s"):format(opt, tostring(user_val)))
    end
  end)

  it("TabLeave does NOT restore window options (diff still alive)", function()
    local lines_diff = diff.compute_diff(vim.api.nvim_buf_get_lines(left_buf, 0, -1, false), vim.api.nvim_buf_get_lines(right_buf, 0, -1, false))

    -- Set user values that differ from codediff's
    vim.wo[left_win].scrollbind = false
    vim.wo[right_win].scrollbind = false

    lifecycle.create_session(tabpage, "standalone", nil, "a.txt", "b.txt", "WORKING", "WORKING", left_buf, right_buf, left_win, right_win, lines_diff)

    local sess = lifecycle.get_session(tabpage)
    assert.is_not_nil(sess)

    -- Simulate render setting scrollbind=true
    effects.preseed_win_opt(sess, left_win, "scrollbind", false, true)
    effects.preseed_win_opt(sess, right_win, "scrollbind", false, true)

    assert.is_true(vim.wo[left_win].scrollbind, "scrollbind should be true during diff")
    assert.is_true(vim.wo[right_win].scrollbind, "scrollbind should be true during diff")

    -- Fire TabLeave manually (clears keymaps, does NOT restore win opts)
    vim.api.nvim_exec_autocmds("TabLeave", { group = "codediff_lifecycle_tab_" .. tabpage })

    -- Session should still exist
    assert.is_not_nil(lifecycle.get_session(tabpage), "session should survive TabLeave")

    -- scrollbind should still be true (win opts NOT restored on TabLeave)
    assert.is_true(vim.wo[left_win].scrollbind, "scrollbind should remain TRUE after TabLeave (session still alive)")
    assert.is_true(vim.wo[right_win].scrollbind, "scrollbind should remain TRUE after TabLeave (session still alive)")
  end)

  it("preseed_win_opt correctly seeds ledger so set_win_opt does not clobber user prev", function()
    -- This tests the capture-once invariant through preseed: if a pre-session raw
    -- write sets wrap=false (user had wrap=true), and then preseed_win_opt is called
    -- with user_prev=true, subsequent set_win_opt calls must not overwrite the prev.
    local lines_diff = diff.compute_diff(vim.api.nvim_buf_get_lines(left_buf, 0, -1, false), vim.api.nvim_buf_get_lines(right_buf, 0, -1, false))

    -- User had wrap=true
    vim.wo[left_win].wrap = true
    -- Raw pre-session write (as in side_by_side.lua before create_session)
    vim.wo[left_win].wrap = false

    lifecycle.create_session(tabpage, "standalone", nil, "a.txt", "b.txt", "WORKING", "WORKING", left_buf, right_buf, left_win, right_win, lines_diff)
    local sess = lifecycle.get_session(tabpage)

    -- Pre-seed: user had true, codediff set false
    effects.preseed_win_opt(sess, left_win, "wrap", true, false)

    -- Subsequent set_win_opt calls (from render.lua autocmd re-apply)
    effects.set_win_opt(sess, left_win, "wrap", false)
    effects.set_win_opt(sess, left_win, "wrap", false)

    -- Cleanup should restore to user's original (true)
    lifecycle.cleanup(tabpage)
    assert.is_true(vim.wo[left_win].wrap, "wrap should be restored to user's true after preseed + multiple set_win_opt")
  end)
end)
