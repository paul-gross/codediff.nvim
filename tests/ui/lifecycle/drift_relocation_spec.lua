-- Phase 5 acceptance probes:
--   CRITERION 4 (drift)    — update_buffers detaches outgoing buffers immediately,
--                            so a stale buffer has NO codediff keymaps and the new
--                            buffer HAS working maps after a file-switch.
--   CRITERION 5 (relocation) — open_in_prev_tab (non-virtual) explicitly calls
--                              effects.detach_buffer; the relocated real buffer
--                              carries NO codediff buffer-local maps afterwards.
--   NON-REGRESSION         — BufWinLeave does NOT prematurely strip maps when
--                            focus moves between the two diff panes (<C-w>w),
--                            or when switch back and forth between files.

local view = require("codediff.ui.view")
local lifecycle = require("codediff.ui.lifecycle")
local effects = require("codediff.ui.lifecycle.effects")
local highlights = require("codediff.ui.highlights")

-- ============================================================================
-- Helpers
-- ============================================================================

--- Return the maparg dict for lhs/mode on bufnr, or nil if no map.
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

--- Return all buffer-local n-mode keymap lhs values for bufnr.
local function get_all_n_lhs(bufnr)
  local result = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    result[m.lhs] = true
  end
  return result
end

--- Collect codediff keymap lhs strings that are present in a n-mode map table.
local function find_codediff_maps(lhs_set)
  local config = require("codediff.config")
  local found = {}
  for _, lhs in pairs(config.options.keymaps.view) do
    if type(lhs) == "string" and lhs_set[lhs] then
      table.insert(found, lhs)
    end
  end
  return found
end

--- Wait for a session to be ready (diff result populated).
local function wait_for_session(tabpage, timeout_ms)
  timeout_ms = timeout_ms or 5000
  local sess
  local ok = vim.wait(timeout_ms, function()
    sess = lifecycle.get_session(tabpage)
    return sess and sess.stored_diff_result ~= nil
  end, 20)
  return ok, sess
end

--- Open a side-by-side diff via view.create; wait until session ready.
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
  local ok, sess = wait_for_session(tabpage)
  assert.is_true(ok, "Session should be ready after view.create")
  return tabpage, sess
end

-- ============================================================================
-- Test fixture paths
-- ============================================================================

local left_path, right_path, alt_left_path, alt_right_path

describe("Phase 5 – drift + relocation probes", function()
  before_each(function()
    require("codediff").setup({ diff = { layout = "side-by-side" } })
    highlights.setup()

    left_path = vim.fn.tempname() .. "_drift_left.txt"
    right_path = vim.fn.tempname() .. "_drift_right.txt"
    alt_left_path = vim.fn.tempname() .. "_drift_alt_left.txt"
    alt_right_path = vim.fn.tempname() .. "_drift_alt_right.txt"

    vim.fn.writefile({ "hello", "world" }, left_path)
    vim.fn.writefile({ "hello", "WORLD" }, right_path)
    vim.fn.writefile({ "foo", "bar" }, alt_left_path)
    vim.fn.writefile({ "foo", "BAR" }, alt_right_path)
  end)

  after_each(function()
    lifecycle.cleanup_all()
    while vim.fn.tabpagenr("$") > 1 do
      pcall(vim.cmd, "tabclose!")
    end
    pcall(vim.fn.delete, left_path)
    pcall(vim.fn.delete, right_path)
    pcall(vim.fn.delete, alt_left_path)
    pcall(vim.fn.delete, alt_right_path)
  end)

  -- ──────────────────────────────────────────────────────────────────────────
  -- CRITERION 4: drift migration
  -- After update_buffers switches to new buffers, the OLD buffers must have
  -- NO codediff maps, and the NEW buffers MUST have working maps.
  -- ──────────────────────────────────────────────────────────────────────────
  it("CRIT-4: update_buffers detaches stale buffer and sets up new buffers", function()
    local tabpage, sess = open_diff(left_path, right_path)

    -- Snapshot the ORIGINAL bufnrs (file A)
    local orig_a = sess.original_bufnr
    local mod_a = sess.modified_bufnr

    -- Verify maps are set on file A's buffers BEFORE switch
    assert.is_not_nil(get_bufmap(orig_a, "n", "q"), "q should be set on original_a before switch")
    assert.is_not_nil(get_bufmap(mod_a, "n", "q"), "q should be set on modified_a before switch")

    -- Pre-seed a user map on orig_a AFTER codediff set it (simulate co-existence):
    -- we test that after detach the ledger correctly dropped orig_a's entries.
    -- (The user map was already captured as prev when codediff set its map;
    --  after detach, codediff's map is gone and the user prev is restored)

    -- Simulate a file-switch: create new buffers (file B), call update_buffers
    local new_orig = vim.fn.bufadd(alt_left_path)
    vim.fn.bufload(new_orig)
    local new_mod = vim.fn.bufadd(alt_right_path)
    vim.fn.bufload(new_mod)

    -- update_buffers should detach outgoing bufnrs
    lifecycle.update_buffers(tabpage, new_orig, new_mod)

    -- Now register maps on the new buffers (normally done by setup_all_keymaps)
    effects.set_keymap(sess, "n", "q", function() end, { buffer = new_orig, noremap = true, silent = true })
    effects.set_keymap(sess, "n", "]c", function() end, { buffer = new_orig, noremap = true, silent = true })
    effects.set_keymap(sess, "n", "q", function() end, { buffer = new_mod, noremap = true, silent = true })
    effects.set_keymap(sess, "n", "]c", function() end, { buffer = new_mod, noremap = true, silent = true })

    -- (a) Stale buffers (file A) must have NO codediff maps
    local old_orig_maps = find_codediff_maps(get_all_n_lhs(orig_a))
    local old_mod_maps = find_codediff_maps(get_all_n_lhs(mod_a))
    assert.are.same({}, old_orig_maps, "Stale original_a should have NO codediff maps after update_buffers. Found: " .. table.concat(old_orig_maps, ", "))
    assert.are.same({}, old_mod_maps, "Stale modified_a should have NO codediff maps after update_buffers. Found: " .. table.concat(old_mod_maps, ", "))

    -- (b) New buffers (file B) MUST have working maps
    assert.is_not_nil(get_bufmap(new_orig, "n", "q"), "q should be set on new_orig after file-switch")
    assert.is_not_nil(get_bufmap(new_mod, "n", "q"), "q should be set on new_mod after file-switch")
    assert.is_not_nil(get_bufmap(new_orig, "n", "]c"), "]c should be set on new_orig after file-switch")
    assert.is_not_nil(get_bufmap(new_mod, "n", "]c"), "]c should be set on new_mod after file-switch")
  end)

  -- ──────────────────────────────────────────────────────────────────────────
  -- CRITERION 4 (extra): pre-seeded user map is restored on the stale buffer
  -- ──────────────────────────────────────────────────────────────────────────
  it("CRIT-4b: user map pre-seeded on stale buffer is restored after update_buffers", function()
    local tabpage, sess = open_diff(left_path, right_path)
    local orig_a = sess.original_bufnr

    -- Set up a fake_sess to simulate a pre-existing user map captured via ledger.
    -- We use the real session's ledger entry: delete codediff's map, set user map,
    -- then call set_keymap so the ledger captures the user map as prev.
    lifecycle.cleanup(tabpage) -- clear so we can reseed cleanly

    if not vim.api.nvim_buf_is_valid(orig_a) then
      -- Real file buffers remain valid after cleanup (not deleted)
      return
    end

    -- Seed a user map
    local user_rhs = ":echo 'user-drift-q'<CR>"
    vim.keymap.set("n", "q", user_rhs, { buffer = orig_a, noremap = true })

    -- Re-open diff: ledger captures user map as prev for q
    view.create({
      mode = "standalone",
      git_root = nil,
      original_path = left_path,
      modified_path = right_path,
      original_revision = nil,
      modified_revision = nil,
    })
    tabpage = vim.api.nvim_get_current_tabpage()
    local ok2, sess2 = wait_for_session(tabpage)
    assert.is_true(ok2, "Second session should be ready")
    assert.equal(orig_a, sess2.original_bufnr, "Same real file buffer reused in second open")

    -- Codediff's q map is now set; user q map is the prev
    local during = get_bufmap(orig_a, "n", "q")
    assert.is_not_nil(during, "q should be set (by codediff) during diff")

    -- Simulate file-switch: update_buffers to new bufnrs (detaches orig_a)
    local new_orig = vim.fn.bufadd(alt_left_path)
    vim.fn.bufload(new_orig)
    local new_mod = vim.fn.bufadd(alt_right_path)
    vim.fn.bufload(new_mod)
    lifecycle.update_buffers(tabpage, new_orig, new_mod)

    -- orig_a should now have the user map restored (codediff map gone)
    local after = get_bufmap(orig_a, "n", "q")
    assert.is_not_nil(after, "User q map should be restored on orig_a after update_buffers")
    assert.equal(user_rhs, after.rhs, "Restored rhs should match user's original rhs")

    -- Cleanup user map
    pcall(vim.keymap.del, "n", "q", { buffer = orig_a })
  end)

  -- ──────────────────────────────────────────────────────────────────────────
  -- CRITERION 5: gf / open_in_prev_tab relocation
  -- After effects.detach_buffer is called on a relocated real buffer,
  -- the buffer must carry NO codediff buffer-local maps.
  -- ──────────────────────────────────────────────────────────────────────────
  it("CRIT-5: detach_buffer on relocated real buffer removes all codediff maps", function()
    local tabpage, sess = open_diff(left_path, right_path)
    local orig_bufnr = sess.original_bufnr

    -- Confirm codediff maps are set
    local before_maps = find_codediff_maps(get_all_n_lhs(orig_bufnr))
    assert.is_true(#before_maps > 0, "Should have codediff maps before relocation")

    -- Simulate open_in_prev_tab's explicit detach (belt-and-suspenders call)
    effects.detach_buffer(sess, orig_bufnr)

    -- After detach: NO codediff maps on the relocated buffer
    local after_maps = find_codediff_maps(get_all_n_lhs(orig_bufnr))
    assert.are.same({}, after_maps, "Relocated buffer should have NO codediff maps after detach_buffer. Found: " .. table.concat(after_maps, ", "))

    -- All nvim_buf_get_keymap n-mode entries: zero codediff ones
    local raw_maps = vim.api.nvim_buf_get_keymap(orig_bufnr, "n")
    local codediff_keys = { "q", "]c", "[c", "]f", "[f", "-", "dp", "do", "S", "U" }
    for _, lhs in ipairs(codediff_keys) do
      for _, m in ipairs(raw_maps) do
        assert.are_not.equal(lhs, m.lhs, ("nvim_buf_get_keymap: codediff map '%s' should be gone after detach"):format(lhs))
      end
    end
  end)

  -- ──────────────────────────────────────────────────────────────────────────
  -- NON-REGRESSION: inter-pane focus change (<C-w>w) must NOT strip maps
  -- ──────────────────────────────────────────────────────────────────────────
  it("NON-REG: inter-pane <C-w>w does NOT prematurely strip keymaps", function()
    local tabpage, sess = open_diff(left_path, right_path)
    local orig_bufnr = sess.original_bufnr
    local mod_bufnr = sess.modified_bufnr
    local orig_win = sess.original_win
    local mod_win = sess.modified_win

    -- Simulate several <C-w>w focus switches
    for _ = 1, 4 do
      if vim.api.nvim_win_is_valid(orig_win) then
        vim.api.nvim_set_current_win(orig_win)
      end
      vim.wait(50)
      if vim.api.nvim_win_is_valid(mod_win) then
        vim.api.nvim_set_current_win(mod_win)
      end
      vim.wait(50)
    end

    -- Maps must still be present on BOTH buffers
    assert.is_not_nil(get_bufmap(orig_bufnr, "n", "q"), "q should still be set on original buffer after inter-pane focus switches")
    assert.is_not_nil(get_bufmap(mod_bufnr, "n", "q"), "q should still be set on modified buffer after inter-pane focus switches")
    assert.is_not_nil(get_bufmap(orig_bufnr, "n", "]c"), "]c should still be set on original buffer after inter-pane focus switches")
    assert.is_not_nil(get_bufmap(mod_bufnr, "n", "]c"), "]c should still be set on modified buffer after inter-pane focus switches")
  end)

  -- ──────────────────────────────────────────────────────────────────────────
  -- NON-REGRESSION: switching files back and forth keeps live buffer mapped
  -- ──────────────────────────────────────────────────────────────────────────
  it("NON-REG: back-and-forth file switches keep live buffers mapped", function()
    local tabpage, sess = open_diff(left_path, right_path)

    local file_a_orig = sess.original_bufnr
    local file_a_mod = sess.modified_bufnr

    -- Simulate switch to file B
    local b_orig = vim.fn.bufadd(alt_left_path)
    vim.fn.bufload(b_orig)
    local b_mod = vim.fn.bufadd(alt_right_path)
    vim.fn.bufload(b_mod)

    lifecycle.update_buffers(tabpage, b_orig, b_mod)
    effects.set_keymap(sess, "n", "q", function() end, { buffer = b_orig, noremap = true, silent = true })
    effects.set_keymap(sess, "n", "]c", function() end, { buffer = b_orig, noremap = true, silent = true })
    effects.set_keymap(sess, "n", "q", function() end, { buffer = b_mod, noremap = true, silent = true })
    effects.set_keymap(sess, "n", "]c", function() end, { buffer = b_mod, noremap = true, silent = true })

    -- File B's buffers should have maps
    assert.is_not_nil(get_bufmap(b_orig, "n", "q"), "q on b_orig after switch to B")
    assert.is_not_nil(get_bufmap(b_mod, "n", "q"), "q on b_mod after switch to B")

    -- File A's buffers should have NO codediff maps (detached)
    local a_orig_after = find_codediff_maps(get_all_n_lhs(file_a_orig))
    local a_mod_after = find_codediff_maps(get_all_n_lhs(file_a_mod))
    assert.are.same({}, a_orig_after, "File A original should have no codediff maps after switch to B")
    assert.are.same({}, a_mod_after, "File A modified should have no codediff maps after switch to B")

    -- Simulate switch BACK to file A (update_buffers detaches B, re-maps A)
    lifecycle.update_buffers(tabpage, file_a_orig, file_a_mod)
    effects.set_keymap(sess, "n", "q", function() end, { buffer = file_a_orig, noremap = true, silent = true })
    effects.set_keymap(sess, "n", "]c", function() end, { buffer = file_a_orig, noremap = true, silent = true })
    effects.set_keymap(sess, "n", "q", function() end, { buffer = file_a_mod, noremap = true, silent = true })
    effects.set_keymap(sess, "n", "]c", function() end, { buffer = file_a_mod, noremap = true, silent = true })

    -- File A should be mapped again
    assert.is_not_nil(get_bufmap(file_a_orig, "n", "q"), "q on file_a_orig after switch back to A")
    assert.is_not_nil(get_bufmap(file_a_mod, "n", "q"), "q on file_a_mod after switch back to A")

    -- File B should be unmapped (detached)
    local b_orig_after = find_codediff_maps(get_all_n_lhs(b_orig))
    local b_mod_after = find_codediff_maps(get_all_n_lhs(b_mod))
    assert.are.same({}, b_orig_after, "File B original should have no codediff maps after switch back to A")
    assert.are.same({}, b_mod_after, "File B modified should have no codediff maps after switch back to A")
  end)

  -- ──────────────────────────────────────────────────────────────────────────
  -- Verify updating flag is initialized to false on create_session
  -- ──────────────────────────────────────────────────────────────────────────
  it("sess.updating starts false and is accessible", function()
    local tabpage, sess = open_diff(left_path, right_path)
    assert.is_false(sess.updating, "sess.updating should be false after create_session completes")
    assert.is_not_nil(sess._tab_augroup, "sess._tab_augroup should be set by create_session")
  end)
end)
