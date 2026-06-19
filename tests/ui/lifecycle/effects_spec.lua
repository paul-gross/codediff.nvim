-- Tests for the effects ledger (lua/codediff/ui/lifecycle/effects.lua).
-- Uses minimal fake sessions — no real diff open required.
-- All tests run headlessly via plenary.

local effects = require("codediff.ui.lifecycle.effects")

-- Build a minimal fake session with an effects ledger (mirrors create_session output).
local _epoch_counter = 0
local function make_sess()
  _epoch_counter = _epoch_counter + 1
  return {
    effects = { keymaps = {}, win_opts = {} },
    effects_epoch = _epoch_counter,
  }
end

-- ============================================================================
-- Helpers
-- ============================================================================

--- Return the maparg dict for lhs/mode on bufnr, or nil if empty.
local function get_bufmap(bufnr, mode, lhs)
  local dict
  vim.api.nvim_buf_call(bufnr, function()
    dict = vim.fn.maparg(lhs, mode, false, true)
  end)
  if next(dict) == nil then
    return nil
  end
  return dict
end

-- ============================================================================
-- Keymap tests
-- ============================================================================

describe("effects ledger – keymaps", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("set_keymap with no prior map: restore_buffer DELETES the map", function()
    local sess = make_sess()
    local lhs = "<Leader>zx"

    -- Pre-condition: no prior map
    assert.is_nil(get_bufmap(buf, "n", lhs), "should be no prior map before test")

    effects.set_keymap(sess, "n", lhs, function() end, { buffer = buf, noremap = true, silent = true })

    -- Confirm map was set
    assert.is_not_nil(get_bufmap(buf, "n", lhs), "keymap should be set")

    effects.restore_buffer(sess, buf)

    -- Map should be gone
    assert.is_nil(get_bufmap(buf, "n", lhs), "keymap should be deleted after restore")
  end)

  it("set_keymap over existing user map: restore_buffer restores the original map", function()
    local sess = make_sess()
    local lhs = "q"
    local user_rhs = ":echo 'user-q'<CR>"

    -- Seed a buffer-local user map
    vim.keymap.set("n", lhs, user_rhs, { buffer = buf, noremap = true })

    local before = get_bufmap(buf, "n", lhs)
    assert.is_not_nil(before, "user map should be set before codediff")

    effects.set_keymap(sess, "n", lhs, function() end, { buffer = buf, noremap = true, silent = true })

    -- Confirm codediff map is in place (rhs differs)
    local during = get_bufmap(buf, "n", lhs)
    assert.is_not_nil(during, "codediff map should be set")

    effects.restore_buffer(sess, buf)

    local after = get_bufmap(buf, "n", lhs)
    assert.is_not_nil(after, "original user map should be restored")
    assert.equal(before.lhs, after.lhs, "lhs should match")
    -- rhs or callback — both are accessible via the maparg dict
    assert.equal(before.rhs, after.rhs, "rhs should match original")
  end)

  it("capture-once: second set_keymap does not overwrite captured prev", function()
    local sess = make_sess()
    local lhs = "<Leader>zz"
    local user_rhs = ":echo 'user-zz'<CR>"

    -- Seed a buffer-local user map
    vim.keymap.set("n", lhs, user_rhs, { buffer = buf, noremap = true })
    local before = get_bufmap(buf, "n", lhs)

    -- First codediff set: captures the user map as prev
    effects.set_keymap(sess, "n", lhs, function() end, { buffer = buf, noremap = true, silent = true })
    -- Second codediff set: must NOT change the captured prev
    effects.set_keymap(sess, "n", lhs, function() end, { buffer = buf, noremap = true, silent = true })

    effects.restore_buffer(sess, buf)

    local after = get_bufmap(buf, "n", lhs)
    assert.is_not_nil(after, "user map should be restored after capture-once")
    assert.equal(before.rhs, after.rhs, "rhs should be the original user rhs, not an intermediate")
  end)

  it("multi-mode {o,x}: two ledger entries, both restored", function()
    local sess = make_sess()
    local lhs = "ih"

    -- Pre-condition: no prior maps in either mode
    assert.is_nil(get_bufmap(buf, "o", lhs))
    assert.is_nil(get_bufmap(buf, "x", lhs))

    effects.set_keymap(sess, { "o", "x" }, lhs, function() end, { buffer = buf, noremap = true, silent = true })

    assert.is_not_nil(get_bufmap(buf, "o", lhs), "o-mode map should be set")
    assert.is_not_nil(get_bufmap(buf, "x", lhs), "x-mode map should be set")

    effects.restore_buffer(sess, buf)

    assert.is_nil(get_bufmap(buf, "o", lhs), "o-mode map should be deleted after restore")
    assert.is_nil(get_bufmap(buf, "x", lhs), "x-mode map should be deleted after restore")
  end)

  it("restore_buffer is idempotent (second call is a no-op, does not error)", function()
    local sess = make_sess()
    local lhs = "<Leader>zy"

    effects.set_keymap(sess, "n", lhs, function() end, { buffer = buf, noremap = true, silent = true })
    effects.restore_buffer(sess, buf)

    local ok = pcall(effects.restore_buffer, sess, buf)
    assert.is_true(ok, "second restore_buffer should not error")
  end)

  it("detach_buffer is an alias for restore_buffer", function()
    local sess = make_sess()
    local lhs = "<Leader>zd"

    effects.set_keymap(sess, "n", lhs, function() end, { buffer = buf, noremap = true, silent = true })
    assert.is_not_nil(get_bufmap(buf, "n", lhs))

    effects.detach_buffer(sess, buf)
    assert.is_nil(get_bufmap(buf, "n", lhs), "map should be removed via detach_buffer")
  end)

  it("restore_keymaps restores all buffers in the ledger", function()
    local sess = make_sess()
    local buf2 = vim.api.nvim_create_buf(false, true)
    local lhs = "<Leader>zm"

    effects.set_keymap(sess, "n", lhs, function() end, { buffer = buf, noremap = true, silent = true })
    effects.set_keymap(sess, "n", lhs, function() end, { buffer = buf2, noremap = true, silent = true })

    effects.restore_keymaps(sess)

    assert.is_nil(get_bufmap(buf, "n", lhs), "buf map should be gone")
    assert.is_nil(get_bufmap(buf2, "n", lhs), "buf2 map should be gone")

    if vim.api.nvim_buf_is_valid(buf2) then
      vim.api.nvim_buf_delete(buf2, { force = true })
    end
  end)
end)

-- ============================================================================
-- Window option tests
-- ============================================================================

describe("effects ledger – window options", function()
  local win, buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    -- Use the current window (always valid in headless test)
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("set_win_opt captures prior value and restore_window writes it back", function()
    local sess = make_sess()

    local original_wrap = vim.wo[win].wrap

    -- Set wrap to opposite of current
    effects.set_win_opt(sess, win, "wrap", not original_wrap)
    assert.equal(not original_wrap, vim.wo[win].wrap, "wrap should be toggled")

    effects.restore_window(sess, win)
    assert.equal(original_wrap, vim.wo[win].wrap, "wrap should be restored to original value")
  end)

  it("set_win_opt capture-once: second call does NOT overwrite the captured prev", function()
    local sess = make_sess()

    local original_wrap = vim.wo[win].wrap

    -- First write: captures original_wrap
    effects.set_win_opt(sess, win, "wrap", not original_wrap)
    -- Second write: must not change the captured prev
    effects.set_win_opt(sess, win, "wrap", original_wrap)

    -- Manually corrupt: if prev was overwritten by the second call it would now
    -- be "not original_wrap" and restore would write that back.
    effects.restore_window(sess, win)

    assert.equal(original_wrap, vim.wo[win].wrap, "wrap should be the original value after restore, not the intermediate")
  end)

  it("restore_window_opts restores all windows in the ledger", function()
    local sess = make_sess()
    -- Only one window available in headless; exercise the loop path
    local original_wrap = vim.wo[win].wrap
    effects.set_win_opt(sess, win, "wrap", not original_wrap)

    effects.restore_window_opts(sess)

    assert.equal(original_wrap, vim.wo[win].wrap, "wrap should be restored via restore_window_opts")
  end)

  it("restore_all restores both keymaps and window options", function()
    local sess = make_sess()
    local lhs = "<Leader>za"
    local original_wrap = vim.wo[win].wrap

    effects.set_keymap(sess, "n", lhs, function() end, { buffer = buf, noremap = true, silent = true })
    effects.set_win_opt(sess, win, "wrap", not original_wrap)

    effects.restore_all(sess)

    assert.is_nil(get_bufmap(buf, "n", lhs), "keymap should be removed after restore_all")
    assert.equal(original_wrap, vim.wo[win].wrap, "wrap should be restored after restore_all")
  end)

  it("describe returns correct keymap and win_opt entries", function()
    local sess = make_sess()
    local lhs = "<Leader>zd"

    -- Start empty
    local d0 = effects.describe(sess)
    assert.equal(0, #d0.keymaps, "no keymaps initially")
    assert.equal(0, #d0.win_opts, "no win_opts initially")

    -- Add a keymap (no prior map exists)
    effects.set_keymap(sess, "n", lhs, function() end, { buffer = buf, noremap = true, silent = true })

    -- Add a window option
    local original_wrap = vim.wo[win].wrap
    effects.set_win_opt(sess, win, "wrap", not original_wrap)

    local d1 = effects.describe(sess)
    assert.equal(1, #d1.keymaps, "one keymap entry")
    assert.equal(1, #d1.win_opts, "one win_opt entry")

    -- Keymap entry shape
    local km = d1.keymaps[1]
    assert.equal(buf, km.bufnr, "keymap bufnr matches")
    assert.equal("n", km.mode, "keymap mode is n")
    assert.is_false(km.has_prev, "no prior map exists")

    -- Win opt entry shape
    local wo = d1.win_opts[1]
    assert.equal(win, wo.win, "win_opt win matches")
    assert.equal("wrap", wo.option, "win_opt option is wrap")
    assert.equal(original_wrap, wo.prev, "win_opt prev is the user's original value")
    assert.equal(sess.effects_epoch, wo.epoch, "win_opt epoch matches session epoch")

    -- Cleanup
    effects.restore_all(sess)
  end)

  it("restore_window skips if epoch does not match (recycled winid guard)", function()
    local sess = make_sess()
    local original_wrap = vim.wo[win].wrap

    effects.set_win_opt(sess, win, "wrap", not original_wrap)

    -- Simulate winid recycle by bumping the window var to a different epoch
    vim.w[win].codediff_effects_epoch = sess.effects_epoch + 999

    -- restore_window should see the epoch mismatch and skip the write-back
    effects.restore_window(sess, win)

    -- Value should NOT have been restored (the recycled guard prevented it)
    assert.equal(not original_wrap, vim.wo[win].wrap, "wrap should remain changed (epoch mismatch skipped restore)")

    -- Cleanup: restore manually so test teardown is clean
    vim.wo[win].wrap = original_wrap
  end)
end)
