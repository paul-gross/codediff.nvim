# Git Status Explorer Mode

## Overview

The CodeDiff explorer mode provides a VSCode-like interface for viewing git changes with a left sidebar showing all modified files and a side-by-side diff view.

## Architecture

### Components

1. **Git Status API** (`lua/vscode-diff/git.lua`)
   - `get_status(git_root, callback)`: Async function to retrieve git status
   - Returns files grouped by staged/unstaged status
   - `get_diff_revision(revision, git_root, callback)`: Async function to get diff against a specific revision
   - Follows the async pattern of other git operations

2. **Explorer UI** (`lua/vscode-diff/render/explorer.lua`)
   - Built with nui.nvim Tree and Split components
   - Displays files in collapsible groups
   - Shows file icons, status symbols, and file counts

3. **Explorer Mode Handler** (`lua/vscode-diff/commands.lua`)
   - Integrated into `:CodeDiff` command
   - Creates tab with explorer + diff panes
   - Handles file selection and diff updates

### User Flow

#### Current Changes (`:CodeDiff`)
1. User runs `:CodeDiff` in a git repository
2. Git status is retrieved asynchronously
3. New tab opens with:
   - Left sidebar (25% width): Explorer with file list
   - Right panes (75% width): Side-by-side diff view
4. First file is automatically selected and displayed
5. Clicking any file in explorer updates the diff view

#### Revision Comparison (`:CodeDiff <revision>`)
1. User runs `:CodeDiff HEAD~5` (or any revision) in a git repository
2. Git diff between working tree and specified revision is retrieved
3. New tab opens with explorer showing all changed files
4. Files are compared against the specified revision instead of HEAD
5. Useful for reviewing all changes since a specific commit, branch, or tag

## Features

### Explorer Sidebar

- **Grouped Display**: Files organized into "Changes" and "Staged Changes"
- **File Counts**: Each group header shows the number of files (e.g., "Changes (3)")
- **File Information**: Each file shows:
  - Icon (from nvim-web-devicons if available)
  - File path (truncated if > 40 chars)
  - Status symbol (M/A/D/??) with appropriate color
- **Collapsible Groups**: Click group headers to expand/collapse
- **Navigation**: Use arrow keys or j/k to move, Enter to select

### Diff View

- **Automatic Updates**: Selecting a file instantly updates both diff panes
- **Virtual Files**: HEAD revision shown as virtual buffer
- **Working Directory**: Current file shown as real buffer
- **Filetype Detection**: Syntax highlighting based on file extension
- **Scrollbind**: Both panes synchronized for easy comparison

### Status Symbols

- `M` (Modified): File has changes - Yellow/Warning color
- `A` (Added): New file - Green/Ok color
- `D` (Deleted): File deleted - Red/Error color
- `??` (Untracked): New untracked file - Blue/Info color

## Implementation Details

### Git Status Parsing

The `get_status` function parses `git status --porcelain` output:
```
XY path
```
Where:
- X = index status (staged)
- Y = worktree status (unstaged)
- path = file path relative to git root

Files can appear in both staged and unstaged if they have changes in both areas.

### Explorer Layout

```
┌─────────────────┬──────────────────────────────┐
│ Explorer (25%)  │ Diff View (75%)              │
│                 ├──────────────┬───────────────┤
│  Changes (3)   │  Original    │   Modified    │
│   file1.lua  M  │  (HEAD)      │   (WORKING)   │
│   file2.lua  A  │              │               │
│   file3.lua  ?? │              │               │
│                 │              │               │
│  Staged (1)    │              │               │
│   file4.lua  M  │              │               │
│                 │              │               │
└─────────────────┴──────────────┴───────────────┘
```

### File Selection Flow

1. User clicks file in explorer (or presses Enter)
2. `on_file_select(file_data)` callback triggered
3. Resolve base revision (HEAD or custom revision) to commit hash
4. Fetch file content from the specified commit
5. Read current working directory file
6. Call `view.update(tabpage, session_config)`
7. Diff is recomputed and displayed

### Revision Support

The explorer supports two modes:

**Status Mode (`:CodeDiff`):**
- Shows changes against HEAD
- Files grouped by "Changes" (unstaged) and "Staged Changes" (staged)
- Handles staged vs unstaged comparison logic

**Revision Mode (`:CodeDiff <revision>`):**
- Simple comparison: WORKING vs specified revision
- Single "Changes" group showing all different files
- No staged/unstaged complexity
- Examples:
  - `:CodeDiff HEAD~5` - Compare working tree vs 5 commits ago
  - `:CodeDiff main` - Compare working tree vs main branch
  - `:CodeDiff abc123` - Compare working tree vs specific commit

### Session Management

Explorer mode uses `mode = "explorer"` in session config:
- Initial session created with empty temp files
- Session updated when files are selected
- Lifecycle tracks git_root, revisions, and paths
- Auto-refresh enabled for working directory buffer

## Keybindings (Explorer)

- `<CR>`: Select file or toggle group
- `<2-LeftMouse>`: Select file (double-click)
- `q`: Close explorer

## Testing

Comprehensive tests verify:
- ✓ Git status detection and parsing
- ✓ Explorer window creation (left sidebar)
- ✓ Window layout (3 windows total)
- ✓ Grouped file display
- ✓ File count display
- ✓ Status symbols and colors
- ✓ Auto-select first file
- ✓ Side-by-side diff rendering
- ✓ Filetype detection
- ✓ Scrollbind synchronization

## Multi-Repo Explorer Sessions

The explorer supports a multi-repo mode that aggregates changed files across N
repositories into a single session.

### Entry points

**`:CodeDiff repos`** — each argument is a `root:base..target` token:

```vim
:CodeDiff repos ~/project-a:main..HEAD ~/project-b:dev..HEAD
```

**`require("codediff").diff_repos(specs, opts)`** — Lua API:

```lua
require("codediff").diff_repos({
  { root = "~/project-a", base = "main", target = "HEAD" },
  { root = "~/project-b", base = "v1.0", target = "HEAD", label = "backend" },
})
```

Each spec accepts `root`, `base`, `target` (required) and `label` (optional;
defaults to directory basename). Positional `{ root, base, target }` is also
accepted. Invalid or non-git roots emit a per-repo warning without aborting.

**`require("codediff").diff_repos_uncommitted(roots, opts)`** — the working-tree
(dirty) counterpart:

```lua
require("codediff").diff_repos_uncommitted({
  "~/project-a",
  { root = "~/project-b", label = "backend" },
})
```

Each root is a string path or `{ root, label? }` (positional `{ root }` also
accepted). Instead of a `base..target` revision diff per repo, this fans out
`git.get_status` across the roots and merges every repo's working-tree status —
preserving all three buckets (staged / unstaged / conflicts; untracked lands in
unstaged as `??`). Repos with no dirty files contribute nothing and are omitted;
invalid roots emit a per-repo warning without aborting.

### Session shape

Multi-repo sessions set `explorer.multi_repo = true` and `explorer.git_root = nil`
(same as dir mode but distinguished by the `multi_repo` flag). A
`explorer.multi_repo_mode` discriminator (`"committed"` | `"uncommitted"`)
records which aggregation built the session, so `refresh.lua` re-runs the
matching one (`aggregate` vs `aggregate_uncommitted`) — auto-refresh stays
BufEnter-only for multi-repo. Committed entries carry `git_root`,
`base_revision`, `target_revision`, and `repo_label`; uncommitted entries carry
`git_root` and `repo_label` only (the absence of revisions selects the
working-tree path in `on_file_select`, mirroring a single-repo dirty session).

### Per-entry root resolution

`on_file_select` in `render.lua` reads `file_data.git_root`, `file_data.base_revision`,
and `file_data.target_revision` in preference to the session-level scalars.
Single-repo sessions carry no per-entry overrides and fall back to the
session scalar — byte-identical behaviour to before.

Identity keys are `(git_root, path, group)` (was `(path, group)`), handled in
`actions.lua` (`navigate_next/prev`, `find_node_line`) and `refresh.lua`
re-select. This prevents same-relpath collisions across repos.

### View mode: `"repo"`

Multi-repo sessions introduce a third view mode (`view_mode = "repo"`) that
partitions the file list by `repo_label` and renders one collapsible group
node per repo, with a normal folder tree inside.

The `toggle_view_mode` (`i`) cycle is:
- **Single-repo** — `list → tree → list` (2-state)
- **Multi-repo** — `list → tree → repo → list` (3-state)

This is implemented in `actions.lua:toggle_view_mode` gated on `explorer.multi_repo`,
and in `tree.lua:create_tree_data` for the `"repo"` branch.

### Flat list repo labels

In `list` and `tree` modes, `nodes.lua` appends `(repo_label)` to each file
row when `file_data.repo_label` is present. Single-repo sessions omit the label.

### Stage-all fan-out

`stage_all` / `unstage_all` call `get_all_git_roots(explorer)` which derives
distinct roots from `explorer.repos` (preferred) or the status_result entries
(fallback), then issues a git operation per root. No atomic cross-repo staging.

### Auto-refresh

Multi-repo sessions use BufEnter focus events only; no per-repo `.git` directory
watcher is installed (v1 limit, deferred as a follow-up).

## Future Enhancements

Possible improvements:
- Stage/unstage files from explorer
- Refresh on file system changes
- Filter by file type or status
- Search/filter files
- Keyboard shortcuts for common git operations
- Support for merge conflicts
- Integration with git blame
- Per-repo `.git` watcher for multi-repo auto-refresh (v2)
