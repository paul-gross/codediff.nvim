# Effects Ledger

**Module**: `lua/codediff/ui/lifecycle/effects.lua`
**Introduced**: Phase 1-6 of the effects-ledger feature branch (2026-06-17)
**Related issue**: esmuellert/codediff.nvim#394

---

## Problem

Before this abstraction, codediff wrote buffer-local keymaps and window options without capturing the prior state. On cleanup:

- `scrollbind` (set in render.lua, conflict_window.lua, auto_refresh.lua, state.lua) was never restored. After several open/close cycles, every window in the user's session accumulated `scrollbind=true` permanently.
- `wrap` was written at approximately 8 call sites with no restore.
- `clear_tab_keymaps` (the old cleanup path) only deleted `config.keymaps.view` keys in `n` mode, on tracked buffers only. It missed `{o,x}` textobject maps (`ih`), all conflict/explorer/history maps, and had no `maparg`/`mapset` cycle — so user maps (`do`, `dp`, custom `q`) were silently deleted without restoration.
- `open_in_prev_tab` (gf) relocated a real file buffer into another tab; that buffer kept all its codediff maps and the source window kept scrollbind.
- `update_buffers` (file-switch in explorer/history mode) re-pointed `bufnr` fields without detaching keymaps from the old buffers.

---

## Design: capture-before-set, replay-on-restore

The ledger operates on per-session fields:

```lua
sess.effects = { keymaps = {}, win_opts = {} }
sess.effects_epoch  -- monotonic integer, unique per session
```

These are initialized inside `session.create_session`. They are not positional parameters.

### Keymap entries

**Data model**: `sess.effects.keymaps[bufnr][mode][canon_lhs]`

Each entry:
```lua
{ mode = string, lhs = string, prev = maparg_dict_or_nil, owned = true }
```

- `canon_lhs` — the lhs resolved through `vim.api.nvim_replace_termcodes(lhs, true, true, true)` at set-time. This expansion is stable across `mapleader`/`maplocalleader` changes and matches the key Neovim uses internally, so both the ledger lookup and the `vim.keymap.del` call operate on the same string.
- `prev` — the `vim.fn.maparg(key, mode, false, true)` dict captured **before the first write**, in **buffer context** via `nvim_buf_call`. Buffer context is required: without it, `maparg` returns global maps instead of buffer-local ones for lhs values that exist in both scopes.
- **First-capture wins**: if `set_keymap` is called again for the same `(bufnr, mode, canon_lhs)`, the `prev` is NOT overwritten. Only the rhs is updated (the keymap is re-applied). This guarantees the user's original map survives multiple codediff write cycles (critical for `do`/`dp` in conflict mode which were historically clobbered).

### Window-option entries

**Data model**: `sess.effects.win_opts[win][option]`

Each entry:
```lua
{ win = number, option = string, prev = any, epoch = number }
```

- `prev` — value of `vim.wo[win][option]` before the first codediff write.
- `epoch` — copied from `sess.effects_epoch` at capture time; also stamped on the window via `vim.w[win].codediff_effects_epoch`.
- **Epoch guard**: `restore_window` checks `vim.w[win].codediff_effects_epoch == sess.effects_epoch` before writing back. This prevents restoring stale state when a window handle has been recycled by Neovim between session open and session close.
- **First-capture wins**: same invariant as keymaps.

---

## API

All public functions are in `lua/codediff/ui/lifecycle/effects.lua` and re-exported from `lua/codediff/ui/lifecycle/init.lua`.

| Function | Purpose |
|----------|---------|
| `set_keymap(sess, mode, lhs, rhs, opts)` | Set a buffer-local keymap (opts.buffer required); captures prior map first |
| `set_win_opt(sess, win, option, value)` | Set a window option; captures prior value first |
| `preseed_win_opt(sess, win, option, user_prev, current_value)` | Seed the ledger with a known prior value when the raw write happened before `create_session` (used by `side_by_side.lua` and `inline_view.lua`) |
| `restore_buffer(sess, bufnr)` | Delete codediff keymap; mapset prior if one was captured; drop ledger entries |
| `restore_window(sess, win)` | Write back prior window opts if epoch matches; drop entries |
| `restore_keymaps(sess)` | Call `restore_buffer` for every bufnr in the ledger |
| `restore_window_opts(sess)` | Call `restore_window` for every win in the ledger |
| `restore_all(sess)` | `restore_keymaps` + `restore_window_opts` |
| `detach_buffer(sess, bufnr)` | Alias for `restore_buffer`; used when detaching a buffer (file-switch, gf relocation) |
| `describe(sess)` | Read-only snapshot: returns `{ keymaps = [...], win_opts = [...] }` listing every owned `(bufnr, mode, lhs, has_prev)` keymap entry and every owned `(win, option, prev, epoch)` window-option entry. Does not modify state. Useful for live-session leak debugging and test assertions. |

### multi-mode fan-out

`set_keymap` accepts `mode` as a string or a list of strings. A list fans out to one call per mode, producing independent ledger entries — which is what `{o, x}` `ih` textobject maps require.

---

## Owned window options

The ledger owns exactly these four window options:

| Option | Set by |
|--------|--------|
| `scrollbind` | `render.lua` (live writes via `establish_scrollbind` + `set_render_window_opts`), `side_by_side.lua` (preseed on all 3 create branches: placeholder, conflict, normal), `state.lua` (auto_refresh resync), `auto_refresh.lua` (resync via local `sw` wrapper), `conflict_window.lua` (result window), `keymaps.lua` (transient disable during `go-to-hunk` scroll) |
| `wrap` | `render.lua` (live writes via `set_render_window_opts`), `side_by_side.lua` (preseed win_opts: cursorline/wrap/list), `inline_view.lua` (preseed), `state.lua` (auto_refresh resync), `session.lua` (BufWinEnter re-apply), `conflict_window.lua` (result window) |
| `cursorline` | `side_by_side.lua` (preseed win_opts: cursorline/wrap/list), `inline_view.lua` (preseed), `conflict_window.lua` (result window) |
| `list` | `side_by_side.lua` (preseed win_opts: cursorline/wrap/list) |

**Deliberately out of scope** (already symmetric or self-owning):
- `compact.lua` fold options (`foldmethod`, `foldexpr`, etc.) — compact.lua already has correct symmetric save/restore (`saved_fold_state`/restore in `enable`/`disable`) and is not leaking.
- `compact.lua` fold keymaps (`za`, `zR`, `zM`, `zo`, `zc`, etc.) — set via raw `vim.keymap.set` on `session.original_bufnr`/`modified_bufnr` and torn down by `teardown_fold_sync` which calls `vim.keymap.del` for each key. Compact mode is toggled on/off within the session lifetime and its keymaps are removed before session close; they do not need to be ledger-tracked because they are fully self-managed with their own symmetric teardown.
- `explorer/render.lua` nav keymaps (`j`, `k`, `<Down>`, `<Up>` on the explorer split buffer) — set via raw `vim.keymap.set` on the explorer UI buffer, not on a diff session buffer. The buffer's lifetime is coterminous with the explorer window.
- `keymap_help.lua` float keymaps (`q`, `<Esc>`, `g?` on the help float buffer) — set via raw `vim.keymap.set` on a transient float buffer that is destroyed on close; not a diff session buffer.
- LSP `didOpen`/`didClose` — owned by `semantic_tokens.lua`, which records exact URI + client per buffer and closes precisely what was opened.
- Highlight namespaces — owned by `state.lua` via `clear_buffer_highlights`.
- `winbar` — set to `""` via raw `vim.wo[win].winbar` in `session.lua`; a follow-up migration can route this through the ledger if winbar customization becomes an issue.

---

## Lifecycle integration

### cleanup_diff (every close path)

`cleanup.lua:cleanup_diff` calls:

```lua
accessors.clear_tab_keymaps(tabpage)   -- restore_keymaps via ledger
effects.restore_window_opts(diff)       -- restore_window for every win
```

This is the common exit for `q`, `:tabclose`, `WinClosed`, and `TabClosed`.

### TabLeave (tab switch while diff is alive)

`session.lua` TabLeave autocmd calls `accessors.clear_tab_keymaps(tabpage)` — keymaps only, no window opts (session stays alive; scrollbind must remain).

### update_buffers (file-switch in explorer/history mode)

`accessors.update_buffers` calls `effects.detach_buffer(sess, old_bufnr)` for each outgoing bufnr. The new bufnrs then get fresh ledger entries when keymaps are re-applied by `setup_all_keymaps`.

Note: the `sess.updating` guard checked in the BufWinLeave hook (point 2 below) is set and cleared by the **view layer** — `side_by_side.lua` and `inline_view.lua` bracket their `compute_and_render` calls with `sess.updating = true` / `sess.updating = false`. The `accessors.update_buffers` function itself does not set this guard; it relies on the surrounding render call having already set it.

### BufWinLeave hook (per-diff-buffer)

`session.create_session` registers a `BufWinLeave` autocmd on each diff buffer. Three guards prevent premature teardown:

1. **active_diffs[tabpage] exists** — no-op after full cleanup avoids double-restore.
2. **`sess.updating == false`** — skipped if a file-switch render is in progress; `update_buffers` handles the detach when the new bufnrs are in place.
3. **Scheduled visibility check** — `vim.schedule` post-event: if the buffer is still displayed in any of the session's diff windows (inter-pane `<C-w>w`, layout reshuffle), it did not truly leave. Only detach when the buffer is absent from all tracked windows.

New buffers added by `update_buffers` (file-switch) are registered via `M.register_buf_win_leave` using the stored `sess._tab_augroup`.

### open_in_prev_tab / gf with `close_on_open_in_prev_tab=false`

When a real buffer is relocated into another tab via `nvim_win_set_buf`, `keymaps.lua:open_in_prev_tab` calls `effects.detach_buffer(sess, current_buf)` explicitly as a belt-and-suspenders measure (the BufWinLeave hook also fires, but the explicit call is synchronous and races ahead of the scheduled hook).

---

## LHS canonicalization

`nvim_replace_termcodes(lhs, true, true, true)` is called once at `set_keymap` time. This:

- Expands `<leader>`, `<localleader>`, `<CR>`, `<Esc>`, etc. to their internal byte sequences.
- Makes the ledger key stable regardless of when/whether `mapleader` changes.
- Matches the form Neovim uses as the storage key in its keymap tables, so `vim.keymap.del(mode, canon_lhs, { buffer = bufnr })` operates on the same resolved string and never silently fails to delete.

---

## Contributor rule

**All buffer-local keymaps and diff-owned window options on diff session buffers/windows MUST go through `effects.set_keymap` / `effects.set_win_opt` — never raw `vim.keymap.set` / `vim.wo`.**

The reason: raw writes bypass the capture step. If no prior state is captured, there is nothing to restore, and the old value is lost permanently.

The four bypass sites that existed before this feature (conflict keymaps, explorer keymaps, history keymaps, inline hunk/`ih` o/x maps) were migrated to route through `effects.set_keymap` in Phase 4. The remaining raw sites are all covered by the "Deliberately out of scope" carve-outs in the table above — each has a documented justification. Do not introduce new bypasses without adding an entry to that table. The bypass audit spec (`tests/ui/lifecycle/bypass_audit_spec.lua`) enforces this: any unlisted raw write site in `lua/codediff/ui/` fails the suite. See that spec's allowlist for the current approved set.

---

## Test coverage

| Spec file | What it probes |
|-----------|----------------|
| `tests/ui/lifecycle/bypass_audit_spec.lua` | Static audit: greps `lua/codediff/ui/` for raw `vim.keymap.set` / `vim.wo[...]=` writes and asserts every one matches the approved allowlist; fails on any NEW unlisted bypass |
| `tests/ui/lifecycle/effects_spec.lua` | Ledger unit: keymap capture/restore, win-opt capture-once, multi-mode, idempotent restore, detach alias, `describe` snapshot |
| `tests/ui/lifecycle/keymap_ledger_spec.lua` | Integration: keymaps set after `view.create`, cleared after `lifecycle.cleanup`, user `q` restored, `ih` o/x removed |
| `tests/ui/lifecycle/win_symmetry_spec.lua` | Window-opt symmetry: scrollbind/wrap/cursorline/list restored after cleanup; TabLeave does NOT restore win opts; `preseed_win_opt` capture-once |
| `tests/ui/conflict/diffget_diffput_spec.lua` | Conflict do/dp: user `do` map captured and restored (not clobbered) |
| `tests/ui/lifecycle/drift_relocation_spec.lua` | File-switch (crit 4): stale buffer cleaned, new buffer mapped; gf relocation (crit 5): `detach_buffer` removes all maps; BufWinLeave guards (no premature strip) |
| `tests/ui/lifecycle/effects_symmetry_spec.lua` | Comprehensive pre/post symmetry across all close paths + N=5 churn no-accumulation probe (see below) |

The symmetry spec (`effects_symmetry_spec.lua`) is the capstone regression: it snapshots keymaps + window opts BEFORE opening and asserts `assert.are.same(before, after)` after each close path, with a pre-seeded user `q` and `do` map so the assertion proves genuine user-state restoration rather than just "codediff state removed".
