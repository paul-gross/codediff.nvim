-- Comprehensive symmetry regression suite for the effects ledger (Phase 6).
--
-- Verifies that every close/escape path leaves the editor state exactly as
-- it was BEFORE the diff was opened: buffer-local keymaps (modes n/o/x/v)
-- and diff-owned window options (scrollbind, wrap, cursorline, list) are
-- fully symmetric — captured before set, restored on every exit path.
--
-- Key probe: the "churn" test (N=5 open/close cycles) reproduces the original
-- user symptom from esmuellert/codediff.nvim#394 (scrollbind accumulating,
-- dead keymaps accumulating after many open/close cycles).
--
-- All tests are headless-safe: no winline()/pixel-rendering assertions.

local view = require("codediff.ui.view")
local lifecycle = require("codediff.ui.lifecycle")
local highlights = require("codediff.ui.highlights")

-- ============================================================================
-- Helpers
-- ============================================================================

--- Return a list of all buffer-local keymaps for a given mode on bufnr.
--- Returns a table keyed by lhs string; each value is the full maparg dict.
local function get_buf_keymaps(bufnr, mode)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end
  local result = {}
  local maps = vim.api.nvim_buf_get_keymap(bufnr, mode)
  for _, m in ipairs(maps) do
    result[m.lhs] = {
      lhs = m.lhs,
      rhs = m.rhs or "",
      noremap = m.noremap,
      silent = m.silent,
      desc = m.desc or "",
    }
  end
  return result
end

--- Return the values of the four diff-owned window options for a window.
local function get_win_opts(win)
  if not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  return {
    scrollbind = vim.wo[win].scrollbind,
    wrap = vim.wo[win].wrap,
    cursorline = vim.wo[win].cursorline,
    list = vim.wo[win].list,
  }
end

--- Snapshot the full symmetry state for a list of (bufnr, win) pairs.
--- Returns a comparable table:
---   { buffers = { [bufnr] = { n={}, o={}, x={}, v={} } },
---     windows = { [win]   = { scrollbind, wrap, cursorline, list } } }
--- The snapshot is taken at call time; bufnrs/wins must be valid.
local function snapshot(bufnrs, wins)
  local snap = { buffers = {}, windows = {} }
  for _, bufnr in ipairs(bufnrs) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      snap.buffers[bufnr] = {
        n = get_buf_keymaps(bufnr, "n"),
        o = get_buf_keymaps(bufnr, "o"),
        x = get_buf_keymaps(bufnr, "x"),
        v = get_buf_keymaps(bufnr, "v"),
      }
    end
  end
  for _, win in ipairs(wins) do
    snap.windows[win] = get_win_opts(win)
  end
  return snap
end

--- Wait for a session to be ready (stored_diff_result populated).
local function wait_for_session(tabpage, timeout_ms)
  timeout_ms = timeout_ms or 5000
  local sess
  local ok = vim.wait(timeout_ms, function()
    sess = lifecycle.get_session(tabpage)
    return sess ~= nil and sess.stored_diff_result ~= nil
  end, 20)
  return ok, sess
end

--- Open a side-by-side diff and wait for the session to be ready.
--- Returns tabpage, sess.
local function open_diff(left_path, right_path)
  view.create({
    mode = "standalone",
    git_root = nil,
    original_path = left_path,
    modified_path = right_path,
    original_revision = nil,
    modified_revision = nil,
  })
  local tabpage = vim.api.nvim_get_current_tabpage()
  local ok, sess = wait_for_session(tabpage, 5000)
  assert.is_true(ok, "session should be ready after view.create")
  return tabpage, sess
end

--- Close the tab containing tabpage (simulates :tabclose).
--- After tabclose the tabpage handle is invalid; the TabClosed autocmd fires
--- and the scheduled cleanup_diff removes the session.
local function close_tab(tabpage)
  if vim.api.nvim_tabpage_is_valid(tabpage) then
    -- Switch to the diff tab then close it
    vim.api.nvim_set_current_tabpage(tabpage)
    vim.cmd("tabclose!")
    -- Allow TabClosed / scheduled cleanup to run
    vim.wait(200, function()
      return lifecycle.get_session(tabpage) == nil
    end, 10)
  end
end

-- ============================================================================
-- Fixture setup / teardown
-- ============================================================================

local left_path, right_path

local function setup_files()
  require("codediff").setup({
    diff = { layout = "side-by-side" },
    keymaps = {
      view = {
        quit = "q",
        open_in_prev_tab = "gf",
        close_on_open_in_prev_tab = false,
      },
    },
  })
  highlights.setup()

  left_path = vim.fn.tempname() .. "_sym_left.txt"
  right_path = vim.fn.tempname() .. "_sym_right.txt"
  vim.fn.writefile({ "alpha", "bravo", "charlie", "delta", "echo" }, left_path)
  vim.fn.writefile({ "alpha", "BRAVO", "charlie", "DELTA", "echo" }, right_path)
end

local function teardown_files()
  lifecycle.cleanup_all()
  while vim.fn.tabpagenr("$") > 1 do
    pcall(vim.cmd, "tabclose!")
  end
  pcall(vim.fn.delete, left_path)
  pcall(vim.fn.delete, right_path)
end

-- ============================================================================
-- Suite 1: q keymap close path
-- ============================================================================

describe("effects symmetry – q (quit keymap)", function()
  before_each(setup_files)
  after_each(teardown_files)

  it("q close path: keymaps and window opts restored to pre-diff state", function()
    -- We open the diff inside a NEW tab so we can close the diff tab without
    -- exiting nvim (exactly as in the real usage scenario).
    -- First, snapshot the state of the CURRENT window/buffer before opening.
    local host_buf = vim.api.nvim_get_current_buf()
    local host_win = vim.api.nvim_get_current_win()

    -- Pre-seed representative USER state so the assert proves real restoration.
    vim.keymap.set("n", "q", ":echo 'user-q'<CR>", { buffer = host_buf, noremap = true, desc = "user-q" })
    vim.keymap.set("n", "do", ":echo 'user-do'<CR>", { buffer = host_buf, noremap = true, desc = "user-do" })
    vim.wo[host_win].scrollbind = false
    vim.wo[host_win].wrap = true
    vim.wo[host_win].cursorline = false
    vim.wo[host_win].list = false

    -- Snapshot before opening
    local before = snapshot({ host_buf }, { host_win })

    -- Open the diff (creates a new tab)
    local tabpage, sess = open_diff(left_path, right_path)

    local orig_buf = sess.original_bufnr
    local mod_buf = sess.modified_bufnr
    local orig_win = sess.original_win
    local mod_win = sess.modified_win

    -- Verify diff is alive: q should be bound on diff buffers
    assert.is_not_nil(vim.fn.maparg("q", "n", false, true).lhs, "q should be bound on diff buffers while open")

    -- Close via q keymap: find the q-keymap rhs function and call it.
    -- In headless we cannot send keystrokes, so we invoke lifecycle.cleanup
    -- directly — this is the exact code path the q keymap executes when
    -- vim.fn.tabpagenr("$") > 1 (tabclose branch):
    lifecycle.cleanup(tabpage)
    close_tab(tabpage)

    -- Allow any scheduled work to drain
    vim.wait(100)

    -- Snapshot after close
    local after = snapshot({ host_buf }, { host_win })

    assert.are.same(before.buffers[host_buf], after.buffers[host_buf], "buffer keymaps should be fully restored after q close")
    assert.are.same(before.windows[host_win], after.windows[host_win], "window options should be fully restored after q close")

    -- Cleanup user maps
    pcall(vim.keymap.del, "n", "q", { buffer = host_buf })
    pcall(vim.keymap.del, "n", "do", { buffer = host_buf })
  end)
end)

-- ============================================================================
-- Suite 2: :tabclose close path
-- ============================================================================

describe("effects symmetry – :tabclose", function()
  before_each(setup_files)
  after_each(teardown_files)

  it(":tabclose path: keymaps and window opts restored", function()
    local host_buf = vim.api.nvim_get_current_buf()
    local host_win = vim.api.nvim_get_current_win()

    vim.wo[host_win].scrollbind = false
    vim.wo[host_win].wrap = true

    local before = snapshot({ host_buf }, { host_win })

    local tabpage, sess = open_diff(left_path, right_path)
    local diff_wins = { sess.original_win, sess.modified_win }

    -- Confirm scrollbind is true on the diff windows (codediff sets it)
    assert.is_true(vim.wo[diff_wins[1]].scrollbind, "scrollbind should be true on diff windows while open")

    -- Close via :tabclose! (simulates the real close path)
    close_tab(tabpage)

    -- Allow cleanup to settle
    vim.wait(200)

    local after = snapshot({ host_buf }, { host_win })
    assert.are.same(before.buffers[host_buf], after.buffers[host_buf], "buffer keymaps should match pre-diff state after :tabclose")
    assert.are.same(before.windows[host_win], after.windows[host_win], "window options should match pre-diff state after :tabclose")
  end)
end)

-- ============================================================================
-- Suite 3: WinClosed (close one diff window via nvim_win_close)
-- ============================================================================

describe("effects symmetry – WinClosed", function()
  before_each(setup_files)
  after_each(teardown_files)

  it("closing one diff window triggers cleanup and restores state", function()
    local host_buf = vim.api.nvim_get_current_buf()
    local host_win = vim.api.nvim_get_current_win()

    vim.wo[host_win].scrollbind = false
    vim.wo[host_win].wrap = true

    local before = snapshot({ host_buf }, { host_win })

    local tabpage, sess = open_diff(left_path, right_path)
    local orig_win = sess.original_win

    -- Close one diff window via nvim_win_close (simulates <C-w>c / :close)
    -- This triggers the WinClosed autocmd.
    if vim.api.nvim_win_is_valid(orig_win) then
      vim.api.nvim_win_close(orig_win, true)
    end

    -- Wait for the scheduled WinClosed handler + cleanup to settle
    vim.wait(500, function()
      return lifecycle.get_session(tabpage) == nil
    end, 20)

    -- If the diff tab is still open (cleanup didn't tabclose), close it
    if vim.api.nvim_tabpage_is_valid(tabpage) then
      pcall(vim.api.nvim_set_current_tabpage, tabpage)
      pcall(vim.cmd, "tabclose!")
      vim.wait(200)
    end

    local after = snapshot({ host_buf }, { host_win })
    assert.are.same(before.buffers[host_buf], after.buffers[host_buf], "buffer keymaps should be restored after WinClosed cleanup")
    assert.are.same(before.windows[host_win], after.windows[host_win], "window options should be restored after WinClosed cleanup")
  end)
end)

-- ============================================================================
-- Suite 3b: scrollbind NOT leaked on surviving diff window after WinClosed
-- (targeted regression probe for esmuellert/codediff.nvim#394 first-open path)
-- ============================================================================

describe("effects symmetry – scrollbind not leaked on surviving diff window (WinClosed)", function()
  before_each(setup_files)
  after_each(teardown_files)

  it("scrollbind on surviving modified_win is restored to pre-diff value after close", function()
    -- Open diff; capture the windows codediff actually wrote scrollbind on.
    local tabpage, sess = open_diff(left_path, right_path)
    local orig_win = sess.original_win
    local mod_win = sess.modified_win

    -- After a successful render, codediff sets scrollbind=true on both diff windows.
    -- This is the codediff-owned value; the user's value was false (default).
    assert.is_true(vim.wo[mod_win].scrollbind, "scrollbind should be true on modified_win while diff is open")

    -- Record the diff window handles for the post-cleanup assertion.
    -- We check mod_win specifically because it survives the WinClosed of orig_win
    -- (cleanup fires when diff_win_count drops to 1, restoring window opts via the
    -- effects ledger, but the surviving window stays open in the diff tab).
    local expected_scrollbind = false -- user's pre-diff value

    -- Close original_win — this drops diff_win_count to 1, triggering cleanup_diff
    -- which calls effects.restore_window_opts. If scrollbind was never captured in
    -- the ledger (the #394 bug), restore is a no-op and mod_win keeps scrollbind=true.
    vim.api.nvim_win_close(orig_win, true)

    -- Wait for the scheduled WinClosed handler and cleanup to run
    vim.wait(500, function()
      return lifecycle.get_session(tabpage) == nil
    end, 20)

    -- mod_win must still be valid (it was NOT the one we closed)
    assert.is_true(vim.api.nvim_win_is_valid(mod_win), "modified_win should still be valid after closing only original_win")

    -- KEY ASSERTION: scrollbind must be restored to the user's value (false),
    -- not left as codediff's value (true). Failure here == the #394 leak.
    assert.is_false(vim.wo[mod_win].scrollbind, "scrollbind on surviving modified_win must be restored to false after cleanup (was leaked true before Fix B)")

    -- Tidy up: close the diff tab if still open
    if vim.api.nvim_tabpage_is_valid(tabpage) then
      pcall(vim.api.nvim_set_current_tabpage, tabpage)
      pcall(vim.cmd, "tabclose!")
      vim.wait(200)
    end
  end)
end)

-- ============================================================================
-- Suite 4a: gf / open_in_prev_tab with close_on_open_in_prev_tab = TRUE
-- ============================================================================

describe("effects symmetry – gf with close_on_open_in_prev_tab=TRUE", function()
  before_each(function()
    require("codediff").setup({
      diff = { layout = "side-by-side" },
      keymaps = {
        view = {
          quit = "q",
          open_in_prev_tab = "gf",
          close_on_open_in_prev_tab = true,
        },
      },
    })
    highlights.setup()
    left_path = vim.fn.tempname() .. "_sym_gft_left.txt"
    right_path = vim.fn.tempname() .. "_sym_gft_right.txt"
    vim.fn.writefile({ "alpha", "bravo" }, left_path)
    vim.fn.writefile({ "alpha", "BRAVO" }, right_path)
  end)
  after_each(function()
    lifecycle.cleanup_all()
    while vim.fn.tabpagenr("$") > 1 do
      pcall(vim.cmd, "tabclose!")
    end
    pcall(vim.fn.delete, left_path)
    pcall(vim.fn.delete, right_path)
  end)

  it("close_on_open_in_prev_tab=true: diff cleaned up, source buf free of maps", function()
    local host_buf = vim.api.nvim_get_current_buf()
    local host_win = vim.api.nvim_get_current_win()

    vim.wo[host_win].scrollbind = false
    vim.wo[host_win].wrap = true

    local before = snapshot({ host_buf }, { host_win })

    local tabpage, sess = open_diff(left_path, right_path)
    local orig_buf = sess.original_bufnr
    local mod_buf = sess.modified_bufnr
    local orig_win = sess.original_win

    -- Snapshot the diff buffer keymaps while open
    local n_maps_during = get_buf_keymaps(orig_buf, "n")
    assert.is_not_nil(n_maps_during["q"], "q should be set during diff")

    -- Simulate gf with close_on_open_in_prev_tab=true:
    -- open_in_prev_tab calls effects.detach_buffer then tabclose.
    -- We reproduce this directly: detach_buffer then cleanup.
    local effects = require("codediff.ui.lifecycle.effects")
    effects.detach_buffer(sess, orig_buf)
    effects.detach_buffer(sess, mod_buf)

    -- Diff buffers should now be free of codediff maps
    assert.is_nil(get_buf_keymaps(orig_buf, "n")["q"], "q should be absent on orig_buf after detach_buffer")

    -- Full cleanup + close tab
    lifecycle.cleanup(tabpage)
    close_tab(tabpage)
    vim.wait(200)

    local after = snapshot({ host_buf }, { host_win })
    assert.are.same(before.buffers[host_buf], after.buffers[host_buf], "host buffer keymaps should be restored after gf+close")
    assert.are.same(before.windows[host_win], after.windows[host_win], "host window opts should be restored after gf+close")
  end)
end)

-- ============================================================================
-- Suite 4b: gf / open_in_prev_tab with close_on_open_in_prev_tab = FALSE
-- ============================================================================

describe("effects symmetry – gf with close_on_open_in_prev_tab=FALSE (relocation)", function()
  before_each(function()
    require("codediff").setup({
      diff = { layout = "side-by-side" },
      keymaps = {
        view = {
          quit = "q",
          open_in_prev_tab = "gf",
          close_on_open_in_prev_tab = false,
        },
      },
    })
    highlights.setup()
    left_path = vim.fn.tempname() .. "_sym_gff_left.txt"
    right_path = vim.fn.tempname() .. "_sym_gff_right.txt"
    vim.fn.writefile({ "alpha", "bravo" }, left_path)
    vim.fn.writefile({ "alpha", "BRAVO" }, right_path)
  end)
  after_each(function()
    lifecycle.cleanup_all()
    while vim.fn.tabpagenr("$") > 1 do
      pcall(vim.cmd, "tabclose!")
    end
    pcall(vim.fn.delete, left_path)
    pcall(vim.fn.delete, right_path)
  end)

  it("close_on_open_in_prev_tab=false: relocated real buffer is clean after detach", function()
    local tabpage, sess = open_diff(left_path, right_path)
    local orig_buf = sess.original_bufnr

    -- Confirm codediff maps set on orig_buf
    assert.is_not_nil(get_buf_keymaps(orig_buf, "n")["q"], "q should be set on orig_buf during diff")

    -- Simulate the non-close relocation path:
    -- open_in_prev_tab calls effects.detach_buffer(sess, current_buf) explicitly
    -- (the belt-and-suspenders call in keymaps.lua:~350).
    local effects = require("codediff.ui.lifecycle.effects")
    effects.detach_buffer(sess, orig_buf)

    -- Relocated buffer must carry NO codediff buffer-local maps
    local n_after = get_buf_keymaps(orig_buf, "n")
    assert.is_nil(n_after["q"], "q should be gone from relocated buffer")
    assert.is_nil(n_after["]c"], "]c should be gone from relocated buffer")
    assert.is_nil(n_after["[c"], "[c should be gone from relocated buffer")
    assert.is_nil(n_after["dp"], "dp should be gone from relocated buffer")
    assert.is_nil(n_after["do"], "do should be gone from relocated buffer")

    -- o/x ih textobject should also be clean
    local o_after = get_buf_keymaps(orig_buf, "o")
    assert.is_nil(o_after["ih"], "ih o-mode should be gone from relocated buffer")
    local x_after = get_buf_keymaps(orig_buf, "x")
    assert.is_nil(x_after["ih"], "ih x-mode should be gone from relocated buffer")

    -- Session diff tab still open (close_on=false) — clean up
    lifecycle.cleanup(tabpage)
    close_tab(tabpage)
    vim.wait(200)
  end)

  it("close_on_open_in_prev_tab=false: SOURCE window scrollbind restored on full cleanup", function()
    -- When gf is used WITHOUT close, the diff session stays alive.
    -- When the user eventually does close (q or :tabclose), scrollbind on
    -- the original source window must be restored to the pre-diff value.
    local host_win = vim.api.nvim_get_current_win()
    local host_buf = vim.api.nvim_get_current_buf()

    vim.wo[host_win].scrollbind = false
    vim.wo[host_win].wrap = true
    local before = snapshot({ host_buf }, { host_win })

    local tabpage, sess = open_diff(left_path, right_path)

    -- Simulate detach without close (gf, no close)
    local effects = require("codediff.ui.lifecycle.effects")
    effects.detach_buffer(sess, sess.original_bufnr)

    -- Now close the diff
    lifecycle.cleanup(tabpage)
    close_tab(tabpage)
    vim.wait(200)

    local after = snapshot({ host_buf }, { host_win })
    assert.are.same(before.windows[host_win], after.windows[host_win], "source window opts should be restored even after gf (no-close) + later cleanup")
  end)
end)

-- ============================================================================
-- Suite 5: <C-w>d style (open buffer in new tab) — N/A note
-- ============================================================================
-- codediff does not bind <C-w>d. The `open_in_prev_tab` (`gf`) is the
-- "open in other tab" path. <C-w>d is a Neovim built-in (":wincmd d") that
-- creates a diff-mode split — it operates outside the codediff API surface.
-- Therefore this close path is N/A for the effects ledger symmetry suite.

-- ============================================================================
-- Suite 6: CHURN probe — N=5 open→close cycles, no state accumulation
-- ============================================================================

describe("effects symmetry – churn (N=5 open/close cycles, no accumulation)", function()
  local churn_left, churn_right

  before_each(function()
    require("codediff").setup({ diff = { layout = "side-by-side" } })
    highlights.setup()
    churn_left = vim.fn.tempname() .. "_churn_left.txt"
    churn_right = vim.fn.tempname() .. "_churn_right.txt"
    vim.fn.writefile({ "line1", "line2", "line3" }, churn_left)
    vim.fn.writefile({ "line1", "LINE2", "line3" }, churn_right)
  end)

  after_each(function()
    lifecycle.cleanup_all()
    while vim.fn.tabpagenr("$") > 1 do
      pcall(vim.cmd, "tabclose!")
    end
    pcall(vim.fn.delete, churn_left)
    pcall(vim.fn.delete, churn_right)
  end)

  it("N=5 open/close cycles: final keymap/win-opt state equals baseline (no leak)", function()
    -- Pre-seed a user map and window state to make the assertion non-trivial.
    local host_buf = vim.api.nvim_get_current_buf()
    local host_win = vim.api.nvim_get_current_win()

    vim.keymap.set("n", "q", ":echo 'churn-q'<CR>", { buffer = host_buf, noremap = true, desc = "churn-q" })
    vim.keymap.set("n", "do", ":echo 'churn-do'<CR>", { buffer = host_buf, noremap = true, desc = "churn-do" })
    vim.wo[host_win].scrollbind = false
    vim.wo[host_win].wrap = true
    vim.wo[host_win].cursorline = false
    vim.wo[host_win].list = false

    -- Baseline: captured with user maps in place, BEFORE any diff cycle.
    local baseline = snapshot({ host_buf }, { host_win })

    -- Run N cycles
    local N = 5
    for i = 1, N do
      local tabpage, _ = open_diff(churn_left, churn_right)

      -- Verify diff is genuinely open
      local sess_during = lifecycle.get_session(tabpage)
      assert.is_not_nil(sess_during, ("cycle %d: session should exist"):format(i))

      -- Close via cleanup + tabclose (the real q→tabclose path)
      lifecycle.cleanup(tabpage)
      close_tab(tabpage)

      -- Give any scheduled work time to settle
      vim.wait(150)

      -- After each cycle, check no accumulation has occurred yet
      local mid = snapshot({ host_buf }, { host_win })
      assert.are.same(baseline.windows[host_win], mid.windows[host_win], ("cycle %d: window opts should be baseline after close"):format(i))
      -- We check buffer keymaps in the final assert below; mid-cycle buffer checks
      -- would be redundant after the window check confirms no drift.
    end

    -- Final full snapshot must equal baseline
    local final = snapshot({ host_buf }, { host_win })

    assert.are.same(baseline.buffers[host_buf], final.buffers[host_buf], "buffer keymaps must equal baseline after N=" .. N .. " open/close cycles (no leak)")
    assert.are.same(baseline.windows[host_win], final.windows[host_win], "window options must equal baseline after N=" .. N .. " open/close cycles (no leak)")

    -- Cleanup user maps
    pcall(vim.keymap.del, "n", "q", { buffer = host_buf })
    pcall(vim.keymap.del, "n", "do", { buffer = host_buf })
  end)

  it("N=5 cycles: scrollbind is FALSE (never leaked) after each close", function()
    -- Targeted probe: scrollbind must never survive a close.
    -- This is the exact symptom from esmuellert/codediff.nvim#394.
    local host_win = vim.api.nvim_get_current_win()
    vim.wo[host_win].scrollbind = false

    for i = 1, 5 do
      local tabpage, _ = open_diff(churn_left, churn_right)
      lifecycle.cleanup(tabpage)
      close_tab(tabpage)
      vim.wait(150)

      assert.is_false(vim.wo[host_win].scrollbind, ("cycle %d: scrollbind must be FALSE after close"):format(i))
    end
  end)
end)
