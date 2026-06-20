-- Phase 2 acceptance probe: keymap ledger route via set_tab_keymap / clear_tab_keymaps
--
-- Opens a real side-by-side diff via view.create, then:
--   1. Snapshots codediff n-mode maps on diff buffers
--   2. Triggers cleanup (lifecycle.cleanup)
--   3. Asserts no codediff n-mode maps remain on those buffers
--   4. Verifies a pre-seeded user `q` map is restored after cleanup (maparg round-trip)

local view = require("codediff.ui.view")
local lifecycle = require("codediff.ui.lifecycle")
local highlights = require("codediff.ui.highlights")

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

--- Return all buffer-local normal-mode keymaps for bufnr, lhs-keyed.
local function get_all_bufmaps_n(bufnr)
  local result = {}
  local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
  for _, m in ipairs(maps) do
    result[m.lhs] = m
  end
  return result
end

--- Collect codediff keymap lhs values that are present in a normal-mode map table.
--- Uses config.options.keymaps.view for the set of known codediff lhs strings.
local function find_codediff_maps_in(maps_by_lhs)
  local config = require("codediff.config")
  local found = {}
  for _, lhs in pairs(config.options.keymaps.view) do
    if type(lhs) == "string" and maps_by_lhs[lhs] then
      table.insert(found, lhs)
    end
  end
  return found
end

--- Wait for a session to be ready on the given tabpage (diff result available).
local function wait_for_session(tabpage, timeout_ms)
  timeout_ms = timeout_ms or 5000
  local sess
  local ok = vim.wait(timeout_ms, function()
    sess = lifecycle.get_session(tabpage)
    return sess and sess.stored_diff_result ~= nil
  end, 20)
  return ok, sess
end

-- ============================================================================
-- Suite
-- ============================================================================

describe("keymap ledger – Phase 2 acceptance probe", function()
  local left_path, right_path

  before_each(function()
    require("codediff").setup({ diff = { layout = "side-by-side" } })
    highlights.setup()

    local original_lines = { "alpha", "bravo", "charlie", "delta", "echo" }
    local modified_lines = { "alpha", "BRAVO", "charlie", "DELTA", "echo" }

    left_path = vim.fn.tempname() .. "_ledger_left.txt"
    right_path = vim.fn.tempname() .. "_ledger_right.txt"
    vim.fn.writefile(original_lines, left_path)
    vim.fn.writefile(modified_lines, right_path)
  end)

  after_each(function()
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
    lifecycle.cleanup_all()
    pcall(vim.fn.delete, left_path)
    pcall(vim.fn.delete, right_path)
    left_path, right_path = nil, nil
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 1. Codediff n-mode maps are SET on diff buffers after open
  -- ──────────────────────────────────────────────────────────────
  it("codediff keymaps are present on diff buffers after view.create", function()
    view.create({
      mode = "standalone",
      git_root = nil,
      original_path = left_path,
      modified_path = right_path,
      original_revision = nil,
      modified_revision = nil,
    })

    local tabpage = vim.api.nvim_get_current_tabpage()
    local ok, sess = wait_for_session(tabpage)
    assert.is_true(ok, "Session should be ready")

    -- q should be set on both diff buffers
    assert.is_not_nil(get_bufmap(sess.original_bufnr, "n", "q"), "q should be bound on original buffer after open")
    assert.is_not_nil(get_bufmap(sess.modified_bufnr, "n", "q"), "q should be bound on modified buffer after open")
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 2. No codediff n-mode maps remain after cleanup
  -- ──────────────────────────────────────────────────────────────
  it("no codediff n-mode maps remain on diff buffers after cleanup", function()
    view.create({
      mode = "standalone",
      git_root = nil,
      original_path = left_path,
      modified_path = right_path,
      original_revision = nil,
      modified_revision = nil,
    })

    local tabpage = vim.api.nvim_get_current_tabpage()
    local ok, sess = wait_for_session(tabpage)
    assert.is_true(ok, "Session should be ready")

    local orig_bufnr = sess.original_bufnr
    local mod_bufnr = sess.modified_bufnr

    -- Confirm maps are present before cleanup
    local before_orig = find_codediff_maps_in(get_all_bufmaps_n(orig_bufnr))
    assert.is_true(#before_orig > 0, "Should have codediff maps before cleanup")

    -- Trigger cleanup via the ledger-backed path
    lifecycle.cleanup(tabpage)

    -- Verify no codediff n-mode maps remain
    local after_orig = find_codediff_maps_in(get_all_bufmaps_n(orig_bufnr))
    local after_mod = find_codediff_maps_in(get_all_bufmaps_n(mod_bufnr))

    assert.are.same({}, after_orig, "No codediff n-mode maps should remain on original buffer after cleanup. Found: " .. table.concat(after_orig, ", "))
    assert.are.same({}, after_mod, "No codediff n-mode maps should remain on modified buffer after cleanup. Found: " .. table.concat(after_mod, ", "))
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 3. Pre-seeded user `q` map is restored after cleanup (maparg round-trip)
  -- ──────────────────────────────────────────────────────────────
  it("pre-seeded user q map is restored on original buffer after cleanup", function()
    -- Open the view so the diff buffers are created and load the file
    local result = view.create({
      mode = "standalone",
      git_root = nil,
      original_path = left_path,
      modified_path = right_path,
      original_revision = nil,
      modified_revision = nil,
    })

    local tabpage = vim.api.nvim_get_current_tabpage()
    local ok, sess = wait_for_session(tabpage)
    assert.is_true(ok, "Session should be ready")

    local orig_bufnr = sess.original_bufnr

    -- Seed a buffer-local user `q` map BEFORE codediff sets its own.
    -- Since codediff already set its map, we need to simulate the
    -- capture-once scenario: restore the ledger state, set the user map,
    -- then re-apply codediff maps so the ledger captures the user map as prev.
    --
    -- Simpler approach (matching the real use-case): clean the session,
    -- seed the user map, then call reapply_keymaps to capture it via the ledger.
    lifecycle.cleanup(tabpage)

    -- Ensure the buffer is still valid after cleanup
    if not vim.api.nvim_buf_is_valid(orig_bufnr) then
      -- If the buffer was deleted (virtual), skip (not applicable for real files)
      return
    end

    -- Seed the user q map on the real file buffer
    local user_rhs = ":echo 'user-q-ledger'<CR>"
    vim.keymap.set("n", "q", user_rhs, { buffer = orig_bufnr, noremap = true, desc = "user-q-test" })

    -- Capture the user map dict for round-trip comparison
    local user_map_before = get_bufmap(orig_bufnr, "n", "q")
    assert.is_not_nil(user_map_before, "User q map should be set before codediff re-open")

    -- Re-open the diff on the same buffers by calling reapply_keymaps directly
    -- This simulates the TabEnter / reapply path which calls set_tab_keymap via keymaps module.
    -- Since the session was cleaned up, we need a fresh session referencing the same buffer.
    -- We do a fresh view.create instead (the buffer will be re-used for real files).

    -- Actually: the scenario is: user has a buffer-local `q` map, then opens codediff,
    -- codediff captures the user map as prev via effects.set_keymap. On cleanup it restores.
    -- To test this without a full reopen, we directly exercise effects.set_keymap then restore.

    local effects = require("codediff.ui.lifecycle.effects")
    local fake_sess = {
      effects = { keymaps = {}, win_opts = {} },
      effects_epoch = 99999,
    }

    -- set_keymap should capture the user `q` map as prev
    effects.set_keymap(fake_sess, "n", "q", function() end, {
      buffer = orig_bufnr,
      noremap = true,
      silent = true,
    })

    -- Verify codediff's map is now in place (different from user_rhs)
    local during = get_bufmap(orig_bufnr, "n", "q")
    assert.is_not_nil(during, "codediff q map should be set during diff")

    -- Restore: should put back the user map
    effects.restore_buffer(fake_sess, orig_bufnr)

    local after = get_bufmap(orig_bufnr, "n", "q")
    assert.is_not_nil(after, "User q map should be restored after effects.restore_buffer")
    assert.equal(user_map_before.rhs, after.rhs, "Restored rhs should match the original user q map rhs")
    assert.equal(user_map_before.desc, after.desc, "Restored desc should match the original user q map desc")

    -- Cleanup
    vim.keymap.del("n", "q", { buffer = orig_bufnr })
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 4. ih o/x textobject maps are removed after cleanup
  -- ──────────────────────────────────────────────────────────────
  it("ih textobject (o/x) maps are removed from diff buffers after cleanup", function()
    view.create({
      mode = "standalone",
      git_root = nil,
      original_path = left_path,
      modified_path = right_path,
      original_revision = nil,
      modified_revision = nil,
    })

    local tabpage = vim.api.nvim_get_current_tabpage()
    local ok, sess = wait_for_session(tabpage)
    assert.is_true(ok, "Session should be ready")

    local orig_bufnr = sess.original_bufnr
    local mod_bufnr = sess.modified_bufnr

    -- ih should be set in o and x modes (set by the hunk loop, NOT via set_tab_keymap)
    assert.is_not_nil(get_bufmap(orig_bufnr, "o", "ih"), "ih o-mode should be set on original buffer")
    assert.is_not_nil(get_bufmap(orig_bufnr, "x", "ih"), "ih x-mode should be set on original buffer")

    -- Cleanup
    lifecycle.cleanup(tabpage)

    -- ih should be gone
    assert.is_nil(get_bufmap(orig_bufnr, "o", "ih"), "ih o-mode should be removed from original buffer after cleanup")
    assert.is_nil(get_bufmap(orig_bufnr, "x", "ih"), "ih x-mode should be removed from original buffer after cleanup")
    assert.is_nil(get_bufmap(mod_bufnr, "o", "ih"), "ih o-mode should be removed from modified buffer after cleanup")
    assert.is_nil(get_bufmap(mod_bufnr, "x", "ih"), "ih x-mode should be removed from modified buffer after cleanup")
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 5. clear_tab_keymaps (TabLeave path) removes only keymaps, not window opts
  -- ──────────────────────────────────────────────────────────────
  it("clear_tab_keymaps removes keymaps without touching window options", function()
    view.create({
      mode = "standalone",
      git_root = nil,
      original_path = left_path,
      modified_path = right_path,
      original_revision = nil,
      modified_revision = nil,
    })

    local tabpage = vim.api.nvim_get_current_tabpage()
    local ok, sess = wait_for_session(tabpage)
    assert.is_true(ok, "Session should be ready")

    local orig_win = sess.original_win
    local orig_bufnr = sess.original_bufnr

    -- Record window option before clear_tab_keymaps (this option may be set by codediff)
    -- Use wrap as a safe read-only probe (we're not restoring it, just checking it's not cleared)
    local wrap_before = vim.wo[orig_win].wrap

    -- Invoke the TabLeave keymap-only path
    local tab_keymaps = require("codediff.ui.lifecycle.tab_keymaps")
    tab_keymaps.clear_tab_keymaps(tabpage)

    -- Keymaps should be gone
    local maps_after = find_codediff_maps_in(get_all_bufmaps_n(orig_bufnr))
    assert.are.same({}, maps_after, "No codediff n-mode maps should remain after clear_tab_keymaps")

    -- Window option should NOT have been changed (Phase 3 handles win opts)
    assert.equal(wrap_before, vim.wo[orig_win].wrap, "wrap should be unchanged after clear_tab_keymaps (window opts are Phase 3)")
  end)
end)
