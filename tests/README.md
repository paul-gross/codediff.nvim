# Test Suite

Integration tests for codediff.nvim using [plenary.nvim](https://github.com/nvim-lua/plenary.nvim).

## Test Coverage

### ✅ FFI Integration (ffi_integration_spec.lua)
C ↔ Lua boundary validation:
- Data structure conversion
- Memory management (no leaks)
- Edge cases (empty diffs, large files)

**10 tests**

### ✅ Git Integration (git_integration_spec.lua)
Git operations and async handling:
- Repository detection
- Async callbacks
- Error handling for invalid revisions
- Path calculation
- LRU cache validation

**9 tests**

### ✅ Installer (installer_spec.lua)
Automatic binary installation and version management:
- Module API validation
- VERSION loading from version.lua
- Library path construction
- Version detection from filenames
- Update necessity logic
- Platform-specific extension handling

**10 tests**

### ✅ Auto-scroll (autoscroll_spec.lua)
Diff view scrolling behavior:
- Scroll to first change
- Window centering
- Scroll sync activation

**5 tests**

### ✅ Semantic Tokens (render/semantic_tokens_spec.lua)
LSP integration and rendering:
- Module compatibility checks
- Virtual file URL handling
- Namespace management

**12 tests**

## Running Tests

### All tests:
```bash
./tests/run_plenary_tests.sh
```

### Individual spec:
```bash
nvim --headless --noplugin -u tests/init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests/ffi_integration_spec.lua')"
```

## Test Philosophy

Focus on **integration points** that C tests cannot validate:
- FFI boundary integrity
- Lua async operations
- System integration (git)
- UI behavior (scrolling, rendering)

**Total: 46 tests** across 5 spec files using industry-standard plenary.nvim framework.

### ✅ Effects Ledger (lifecycle/effects_spec.lua, keymap_ledger_spec.lua, win_symmetry_spec.lua, drift_relocation_spec.lua, conflict/diffget_diffput_spec.lua, lifecycle/effects_symmetry_spec.lua)

Session-scoped reversible effects ledger (`lua/codediff/ui/lifecycle/effects.lua`) — captures prior state before every buffer-local keymap and window-option write, replays on restore:

- **effects_spec.lua** — unit: keymap capture/restore (with/without prior map), capture-once invariant, multi-mode fan-out, idempotent restore, detach alias; window-opt capture/restore, epoch-guard skip
- **keymap_ledger_spec.lua** — integration: keymaps present after `view.create`, absent after `lifecycle.cleanup`, user `q` map captured and restored, `ih` o/x textobject maps removed after cleanup, `clear_tab_keymaps` leaves window opts untouched
- **win_symmetry_spec.lua** — window-opt symmetry: scrollbind/wrap/cursorline/list restored after cleanup; TabLeave does NOT restore win opts; `preseed_win_opt` capture-once
- **diffget_diffput_spec.lua** — conflict mode: user `do`/`dp` maps captured and restored (not clobbered)
- **drift_relocation_spec.lua** — file-switch drift (stale buffer cleaned, new buffer mapped); gf relocation (detach_buffer removes all maps); BufWinLeave guards (no premature strip on inter-pane focus change)
- **effects_symmetry_spec.lua** — comprehensive pre/post symmetry regression: snapshots keymaps + window opts BEFORE opening, asserts `same(before, after)` after each close path (`q`, `:tabclose`, `WinClosed`, gf `close=true`, gf `close=false`); N=5 churn no-accumulation probe (reproduces esmuellert/codediff.nvim#394 scrollbind leak symptom)

## What's NOT Covered

❌ **Diff algorithm** - Validated by C tests in `c-diff-core/tests/` (3,490 lines)
❌ **Visual correctness** - Manual testing required
