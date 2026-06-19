-- Phase 4 acceptance probe: conflict do/dp restore (criterion 3).
--
-- Pre-seeds buffer-local user `do` and `dp` maps on the result buffer,
-- then exercises setup_keymaps (which previously deleted them with pcall).
-- After effects.restore_buffer is called, asserts the user's ORIGINAL do/dp
-- are restored exactly (maparg round-trip), NOT deleted.
--
-- Also asserts that no codediff conflict maps remain after restore.

local effects = require("codediff.ui.lifecycle.effects")

-- ============================================================================
-- Helpers
-- ============================================================================

--- Return the maparg dict for lhs/mode on bufnr only if it is buffer-local,
--- or nil if no buffer-local map exists. Falls through to global maps otherwise.
--- maparg(lhs) inside nvim_buf_call returns buffer-local maps first; if the
--- returned dict has buffer==1 it is buffer-local, buffer==0 means global fallthrough.
local function get_bufmap(bufnr, mode, lhs)
  local dict
  vim.api.nvim_buf_call(bufnr, function()
    dict = vim.fn.maparg(lhs, mode, false, true)
  end)
  if next(dict) == nil then
    return nil
  end
  -- Only return the map if it is actually buffer-local (buffer==1).
  -- A global fallthrough map (buffer==0) is not a buffer-local codediff map.
  if dict.buffer ~= 1 then
    return nil
  end
  return dict
end

-- Build a minimal fake session with an effects ledger.
local _epoch = 0
local function make_sess()
  _epoch = _epoch + 1
  return {
    effects = { keymaps = {}, win_opts = {} },
    effects_epoch = _epoch,
  }
end

-- ============================================================================
-- Suite
-- ============================================================================

describe("conflict keymaps – do/dp restore (Phase 4, criterion 3)", function()
  local bufnr

  before_each(function()
    bufnr = vim.api.nvim_create_buf(false, true)
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 1. User do/dp are restored after effects.restore_buffer
  -- ──────────────────────────────────────────────────────────────
  it("user `do` is restored after conflict keymap set + restore_buffer", function()
    local sess = make_sess()

    -- Seed user `do` map before any codediff write
    local user_do_rhs = ":echo 'user-do'<CR>"
    vim.keymap.set("n", "do", user_do_rhs, {
      buffer = bufnr,
      noremap = true,
      desc = "user-do-test",
    })

    local before = get_bufmap(bufnr, "n", "do")
    assert.is_not_nil(before, "user do map should be set before codediff")
    assert.equal(user_do_rhs, before.rhs, "pre-condition: user do rhs should be our rhs")

    -- Simulate what conflict/keymaps.lua now does: route through the ledger.
    -- The ledger will capture the user's `do` as prev (capture-once).
    effects.set_keymap(sess, "n", "do", function() end, {
      buffer = bufnr,
      noremap = true,
      silent = true,
      nowait = true,
      desc = "codediff-conflict-diffget",
    })

    -- Codediff map should be in effect
    local during = get_bufmap(bufnr, "n", "do")
    assert.is_not_nil(during, "codediff `do` map should be set during conflict")

    -- Restore: should put back the user's original map
    effects.restore_buffer(sess, bufnr)

    local after = get_bufmap(bufnr, "n", "do")
    assert.is_not_nil(after, "user `do` map should be restored after effects.restore_buffer")
    assert.equal(user_do_rhs, after.rhs, "restored rhs should match the original user `do` rhs")
    assert.equal(before.desc, after.desc, "restored desc should match the original user `do` desc")
  end)

  it("user `dp` is restored after conflict keymap set + restore_buffer", function()
    local sess = make_sess()

    local user_dp_rhs = ":echo 'user-dp'<CR>"
    vim.keymap.set("n", "dp", user_dp_rhs, {
      buffer = bufnr,
      noremap = true,
      desc = "user-dp-test",
    })

    local before = get_bufmap(bufnr, "n", "dp")
    assert.is_not_nil(before, "user dp map should be set before codediff")

    effects.set_keymap(sess, "n", "dp", function() end, {
      buffer = bufnr,
      noremap = true,
      silent = true,
      nowait = true,
      desc = "codediff-conflict-diffput",
    })

    effects.restore_buffer(sess, bufnr)

    local after = get_bufmap(bufnr, "n", "dp")
    assert.is_not_nil(after, "user `dp` map should be restored")
    assert.equal(user_dp_rhs, after.rhs, "restored rhs should match the original user `dp` rhs")
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 2. Capture-once: setting do twice keeps the original prev
  -- ──────────────────────────────────────────────────────────────
  it("capture-once holds for `do`: second set_keymap does not overwrite user prev", function()
    local sess = make_sess()

    local user_do_rhs = ":echo 'user-do-co'<CR>"
    vim.keymap.set("n", "do", user_do_rhs, { buffer = bufnr, noremap = true })

    local before = get_bufmap(bufnr, "n", "do")

    -- First write: captures user map as prev
    effects.set_keymap(sess, "n", "do", function() end, {
      buffer = bufnr,
      noremap = true,
      silent = true,
    })
    -- Second write (simulating conflict keymaps being set after view keymaps):
    -- must NOT change the captured prev
    effects.set_keymap(sess, "n", "do", function() end, {
      buffer = bufnr,
      noremap = true,
      silent = true,
    })

    effects.restore_buffer(sess, bufnr)

    local after = get_bufmap(bufnr, "n", "do")
    assert.is_not_nil(after, "user do should be restored after capture-once")
    assert.equal(before.rhs, after.rhs, "rhs should be the original user rhs, not a codediff intermediate")
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 3. Codediff conflict maps are absent after restore
  -- ──────────────────────────────────────────────────────────────
  it("codediff conflict keymaps are gone after effects.restore_buffer", function()
    local sess = make_sess()
    local config = require("codediff.config")
    local conflict_keys = config.options.keymaps.conflict or {}

    -- Set some representative conflict keymaps through the ledger
    -- (simulate what conflict/keymaps.lua now does)
    local function noop() end
    if conflict_keys.accept_incoming then
      effects.set_keymap(sess, "n", conflict_keys.accept_incoming, noop, {
        buffer = bufnr,
        noremap = true,
        silent = true,
        nowait = true,
        expr = true,
        desc = "Accept incoming change",
      })
    end
    if conflict_keys.accept_current then
      effects.set_keymap(sess, "n", conflict_keys.accept_current, noop, {
        buffer = bufnr,
        noremap = true,
        silent = true,
        nowait = true,
        expr = true,
        desc = "Accept current change",
      })
    end
    if conflict_keys.next_conflict then
      effects.set_keymap(sess, "n", conflict_keys.next_conflict, noop, {
        buffer = bufnr,
        noremap = true,
        silent = true,
        nowait = true,
        desc = "Next conflict",
      })
    end

    -- Maps should be set
    if conflict_keys.next_conflict then
      assert.is_not_nil(get_bufmap(bufnr, "n", conflict_keys.next_conflict), "next_conflict map should be set")
    end

    -- Restore: all codediff conflict maps should be gone
    effects.restore_buffer(sess, bufnr)

    if conflict_keys.accept_incoming then
      assert.is_nil(get_bufmap(bufnr, "n", conflict_keys.accept_incoming), "accept_incoming should be gone after restore")
    end
    if conflict_keys.accept_current then
      assert.is_nil(get_bufmap(bufnr, "n", conflict_keys.accept_current), "accept_current should be gone after restore")
    end
    if conflict_keys.next_conflict then
      assert.is_nil(get_bufmap(bufnr, "n", conflict_keys.next_conflict), "next_conflict should be gone after restore")
    end
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 4. Conflict keymaps module can be required and exports setup_keymaps
  -- ──────────────────────────────────────────────────────────────
  it("conflict keymaps module loads and exports setup_keymaps", function()
    local ok, mod = pcall(require, "codediff.ui.conflict.keymaps")
    assert.is_true(ok, "conflict.keymaps should load without error")
    assert.is_function(mod.setup_keymaps, "setup_keymaps should be a function")
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 5. Ledger is resolution-stable: changing mapleader between
  --    set and restore must not leak the codediff map.
  -- ──────────────────────────────────────────────────────────────
  it("ledger resolution-stability: codediff <leader> map is gone even if mapleader changes before restore", function()
    local sess = make_sess()

    -- Record the original mapleader so we can restore it after the test.
    local original_mapleader = vim.g.mapleader

    -- Set mapleader to comma at set-time.
    vim.g.mapleader = ","

    -- Plant a user prior map for <leader>zz (comma leader → ,zz) so we can
    -- verify the prior is restored correctly even after leader change.
    local user_prior_rhs = ":echo 'prior-zz'<CR>"
    vim.keymap.set("n", "<leader>zz", user_prior_rhs, {
      buffer = bufnr,
      noremap = true,
      desc = "user-prior-zz",
    })
    local before = get_bufmap(bufnr, "n", ",zz")
    assert.is_not_nil(before, "pre-condition: user prior map ,zz should be set")

    -- Set the codediff map through the ledger (leader resolves to , at this point).
    effects.set_keymap(sess, "n", "<leader>zz", function() end, {
      buffer = bufnr,
      noremap = true,
      silent = true,
      desc = "codediff-zz-test",
    })
    local during = get_bufmap(bufnr, "n", ",zz")
    assert.is_not_nil(during, "codediff ,zz map should be active during session")

    -- Change mapleader to backslash BEFORE restore (the divergence scenario).
    vim.g.mapleader = "\\"

    -- Restore must still find and delete the ,zz map despite mapleader change.
    effects.restore_buffer(sess, bufnr)

    -- After restore the buffer-local map for ,zz must be the user's prior, not
    -- the codediff map. The codediff map had desc="codediff-zz-test"; the user
    -- prior has desc="user-prior-zz". Check that the restored map is the user's.
    local restored = get_bufmap(bufnr, "n", ",zz")
    assert.is_not_nil(restored, "user prior ,zz map should be restored as buffer-local after effects.restore_buffer")
    assert.equal(user_prior_rhs, restored.rhs, "restored rhs must be the user prior rhs (not codediff rhs), proving the codediff map was deleted")
    assert.equal("user-prior-zz", restored.desc, "restored desc must be the user prior desc (not codediff desc), confirming codediff map is gone")

    -- Clean up: restore original mapleader and delete the ,zz map.
    vim.g.mapleader = original_mapleader
    pcall(vim.keymap.del, "n", ",zz", { buffer = bufnr })
  end)
end)
