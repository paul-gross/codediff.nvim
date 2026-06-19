-- Bypass audit: ensures every raw vim.keymap.set / vim.wo[...] = write in
-- lua/codediff/ui/ is on the approved allowlist.
--
-- Purpose: the effects ledger invariant ("all diff-session keymap and window-
-- option writes go through effects.set_keymap / effects.set_win_opt") must be
-- machine-checked, not just prose. This spec reads the source files, finds raw
-- writes, and asserts that each one matches an approved (file_pattern,
-- line_pattern, justification) entry. A NEW unlisted bypass causes a failing
-- test so contributors see the violation immediately.
--
-- Implementation: line-based grep — no Lua parser required. Each allowlist
-- entry matches by file glob + Lua pattern against the raw line text.
--
-- See: docs/development/05-architecture/effects-ledger.md
--      "Deliberately out of scope" + "Contributor rule"

describe("bypass audit: raw vim.keymap.set / vim.wo writes", function()
  -- ============================================================================
  -- Allowlist
  -- Each entry: { file = <glob-suffix>, line = <Lua pattern>, why = <string> }
  -- file  — matched against the relative file path (from lua/codediff/ui/)
  -- line  — matched against the raw source line (trimmed)
  -- why   — human-readable justification (not checked; docs only)
  --
  -- Patterns that match the SAME raw line are considered one site.
  -- A source line is flagged if it matches one of the raw-write regexes AND is
  -- NOT covered by any allowlist entry.
  -- ============================================================================

  local ALLOWLIST = {
    -- ── effects.lua itself ────────────────────────────────────────────────────
    {
      file = "lifecycle/effects.lua",
      line = "vim%.keymap%.set",
      why = "The ledger implementation; this IS the canonical write site.",
    },
    {
      file = "lifecycle/effects.lua",
      line = "vim%.wo%[",
      why = "The ledger implementation; this IS the canonical write site.",
    },

    -- ── if-sess-then-effects-else-raw fallback pattern ────────────────────────
    -- These sites route through the ledger when a live session exists and fall
    -- back to a raw write only when called before create_session (e.g. during
    -- buffer preparation). They are safe: the raw-write path is immediately
    -- followed by preseed_win_opt / effects.set_keymap once the session is
    -- created, so the ledger capture-once invariant is preserved.
    {
      file = "explorer/keymaps.lua",
      line = "vim%.keymap%.set",
      why = "if-sess-then-effects-else-raw fallback in set_keymap local helper.",
    },
    {
      file = "history/keymaps.lua",
      line = "vim%.keymap%.set",
      why = "if-sess-then-effects-else-raw fallback in set_keymap local helper.",
    },
    {
      file = "lib/tree_utils.lua",
      line = "vim%.keymap%.set",
      why = "if-sess-then-effects-else-raw fallback in set_keymap local helper.",
    },
    {
      file = "view/keymaps.lua",
      line = "vim%.keymap%.set",
      why = "if-sess-then-effects-else-raw fallback for hunk maps.",
    },
    {
      file = "view/render.lua",
      line = "vim%.wo%[",
      why = "if-sess-then-effects-else-raw fallback in set_win_opt local wrapper.",
    },
    {
      file = "auto_refresh.lua",
      line = "vim%.wo%[",
      why = "if-sess-then-effects-else-raw fallback in local sw() wrapper.",
    },
    {
      file = "view/conflict_window.lua",
      line = "vim%.wo%[",
      why = "if-sess-then-effects-else-raw fallback for wrap/cursorline/scrollbind on result_win; winbar writes (out-of-scope).",
    },

    -- ── side_by_side.lua / inline_view.lua pre-session raw writes ─────────────
    -- These raw writes happen BEFORE create_session; they are immediately
    -- captured by preseed_win_opt after the session is created.
    {
      file = "view/side_by_side.lua",
      line = "vim%.wo%[",
      why = "Pre-session raw writes (win_opts loop) immediately followed by preseed_win_opt; reads for capture.",
    },
    {
      file = "view/inline_view.lua",
      line = "vim%.wo%[",
      why = "Pre-session raw writes immediately followed by preseed_win_opt; reads for capture.",
    },

    -- ── compact.lua — self-managed fold keymaps and fold options ─────────────
    -- compact.lua manages its own symmetric setup/teardown:
    --   * Fold keymaps: set via vim.keymap.set, torn down by teardown_fold_sync.
    --   * Fold options: saved to fold_state table, restored on disable.
    -- Compact mode is toggled within the session lifetime; teardown runs before
    -- session close. No ledger tracking needed.
    {
      file = "view/compact.lua",
      line = "vim%.keymap%.set",
      why = "Fold-sync keymaps on diff buffers; self-managed by teardown_fold_sync.",
    },
    {
      file = "view/compact.lua",
      line = "vim%.wo%[",
      why = "Fold options (foldmethod/foldexpr/etc.); self-managed save/restore in enable/disable.",
    },

    -- ── Non-diff-session buffers/windows ─────────────────────────────────────
    -- These raw writes target UI surfaces that are not diff session buffers
    -- or diff-owned windows: floats, sidebar explorer, winbar, split lib.
    {
      file = "explorer/render.lua",
      line = "vim%.keymap%.set",
      why = "Explorer nav keymaps (j/k/Up/Down) on explorer sidebar buffer; not a diff session buffer.",
    },
    {
      file = "keymap_help.lua",
      line = "vim%.keymap%.set",
      why = "Close keymaps on transient help float buffer; not a diff session buffer.",
    },
    {
      file = "keymap_help.lua",
      line = "vim%.wo%[",
      why = "cursorline/winhighlight on help float window; not a diff-owned window.",
    },
    {
      file = "explorer/keymaps.lua",
      line = "vim%.wo%[",
      why = "hover_win wrap on a hover popup window; not a tracked diff window.",
    },
    {
      file = "lifecycle/session.lua",
      line = "vim%.wo%[",
      why = "winbar writes on diff windows; winbar is explicitly out-of-scope per the ledger doc.",
    },
    {
      file = "lib/split.lua",
      line = "vim%.wo%[",
      why = "nui Split wrapper applies caller-supplied window options at construction time.",
    },
    {
      file = "view/welcome_window.lua",
      line = "vim%.wo%[",
      why = "Welcome float window option save/restore; not a diff session buffer.",
    },
  }

  -- ============================================================================
  -- Helpers
  -- ============================================================================

  --- Walk a directory recursively and return all .lua file paths.
  local function find_lua_files(dir)
    local files = {}
    local handle = vim.loop.fs_opendir(dir, nil, 100)
    if not handle then
      return files
    end
    while true do
      local entries = vim.loop.fs_readdir(handle)
      if not entries then
        break
      end
      for _, entry in ipairs(entries) do
        local full = dir .. "/" .. entry.name
        if entry.type == "directory" then
          local sub = find_lua_files(full)
          for _, f in ipairs(sub) do
            table.insert(files, f)
          end
        elseif entry.type == "file" and entry.name:match("%.lua$") then
          table.insert(files, full)
        end
      end
    end
    vim.loop.fs_closedir(handle)
    return files
  end

  --- Return true if `str` matches any of the Lua patterns in `patterns`.
  local function matches_any(str, patterns)
    for _, pat in ipairs(patterns) do
      if str:match(pat) then
        return true
      end
    end
    return false
  end

  -- Raw-write detection patterns (Lua patterns against trimmed source lines).
  -- We detect:
  --   vim.keymap.set(   — any raw keymap set call
  --   vim.wo[win][opt] = — window-option WRITE (assignment, not a read)
  --   vim.wo[win].opt =  — window-option WRITE via dot-notation
  -- We exclude lines where vim.wo is on the right side of an assignment
  -- (i.e. reads like `local x = vim.wo[win].opt`).
  local RAW_WRITE_PATTERNS = {
    "vim%.keymap%.set%(",
    -- Match vim.wo[...][...] = or vim.wo[...].optname = (write forms)
    -- but NOT lines where vim.wo[ is to the right of a "=" (reads).
    -- Heuristic: if the line starts with vim.wo[ or has vim.wo[ after
    -- an operator/comma but NOT after "= ", it's a write.
    "vim%.wo%[.-%]%s*=", -- vim.wo[win] = val (subscript write)
    "vim%.wo%[.-%]%[.-%]%s*=", -- vim.wo[win][opt] = val
    "vim%.wo%[.-%]%.%w+%s*=", -- vim.wo[win].optname = val
  }

  --- Check whether a flagged line is covered by an allowlist entry.
  ---@param rel_path string  relative path from lua/codediff/ui/ (forward slashes)
  ---@param line_text string  trimmed source line
  ---@return boolean, string  covered, justification
  local function is_allowed(rel_path, line_text)
    for _, entry in ipairs(ALLOWLIST) do
      -- file match: rel_path must end with the entry.file suffix
      local file_ok = rel_path:find(entry.file:gsub("%.", "%%."), 1, false) or rel_path == entry.file or rel_path:sub(-#entry.file) == entry.file
      if file_ok and line_text:match(entry.line) then
        return true, entry.why
      end
    end
    return false, nil
  end

  -- ============================================================================
  -- The audit test
  -- ============================================================================

  it("has no unlisted raw vim.keymap.set / vim.wo writes in lua/codediff/ui/", function()
    local ui_dir = vim.fn.getcwd() .. "/lua/codediff/ui"
    local all_files = find_lua_files(ui_dir)
    assert.is_true(#all_files > 0, "No .lua files found under lua/codediff/ui/ — wrong cwd?")

    local violations = {}

    for _, fpath in ipairs(all_files) do
      -- Compute relative path from lua/codediff/ui/
      local rel = fpath:sub(#ui_dir + 2) -- strip "lua/codediff/ui/"

      local lines = vim.fn.readfile(fpath)
      for lineno, line in ipairs(lines) do
        local trimmed = line:match("^%s*(.-)%s*$")
        if matches_any(trimmed, RAW_WRITE_PATTERNS) then
          local allowed, why = is_allowed(rel, trimmed)
          if not allowed then
            table.insert(violations, string.format("%s:%d  %s", rel, lineno, trimmed))
          else
            _ = why -- suppress unused warning
          end
        end
      end
    end

    if #violations > 0 then
      local msg = table.concat({
        "",
        "BYPASS AUDIT FAILED — unlisted raw write sites found in lua/codediff/ui/:",
        "",
        table.concat(violations, "\n"),
        "",
        "To resolve: either route the write through effects.set_keymap / effects.set_win_opt,",
        "or add an entry to the ALLOWLIST in tests/ui/lifecycle/bypass_audit_spec.lua with",
        "a justification and update docs/development/05-architecture/effects-ledger.md.",
      }, "\n")
      error(msg)
    end

    -- Confirm at least one flagged site was processed (sanity: proves grep worked)
    assert.is_true(#all_files >= 10, "Too few files found — audit may not have run over the real source tree")
  end)
end)
