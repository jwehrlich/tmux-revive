# tmux-revive Workflow

## Daily Use

Reload tmux config after changing bindings or options:

```tmux
prefix + r
```

Save the current snapshot manually:

```tmux
prefix + S
```

Restore the latest snapshot manually:

```tmux
prefix + R
```

Resume one saved session interactively:

```tmux
prefix + m
r
```

The chooser shows:

- snapshot timestamp
- snapshot reason
- short GUID
- first few window names
- whether the saved session is already live

The main `Revive` picker now also includes saved sessions from the default snapshot source after the live-session sections. In the default view, those saved rows are resume-only.

Archived saved sessions are hidden from the default saved-session chooser and default `Revive` saved rows. You can include them explicitly in the chooser with:

```sh
choose-saved-session.sh --manifest /path/to/manifest.json --include-archived
```

Browse snapshots interactively:

```tmux
prefix + m
b
```

List saved sessions from the latest snapshot:

```sh
restore-state.sh --list
```

The default list shows only the latest snapshot and prints:

- `SESSION_GUID`
- `SESSION_NAME`
- `LAST_UPDATED`

Resume by GUID or human-readable label:

```sh
resume-session.sh <session-guid>
resume-session.sh <session-label>
```

Browse snapshots from the shell:

```sh
choose-snapshot.sh --yes
```

Include imported snapshots explicitly:

```sh
choose-snapshot.sh --yes --include-imported
```

Snapshot browser actions:

- `Enter`: choose a snapshot, then choose one saved session from it
- `Ctrl-a`: restore all sessions from the selected snapshot
- the preview pane shows the restore plan for the highlighted snapshot
- imported snapshots are hidden in the default view unless `--include-imported` is used

Export or import one snapshot bundle:

```sh
export-snapshot.sh --manifest /path/to/manifest.json --output /tmp/work-snapshot.tar.gz
import-snapshot.sh --bundle /tmp/work-snapshot.tar.gz
```

Preview a restore plan before changing tmux:

```sh
restore-state.sh --preview
restore-state.sh --session-name work --preview
```

The preview now includes advisory health warnings for:

- missing pane cwd paths
- missing `tail -f` targets
- missing Neovim restore files
- snapshot host mismatch or legacy compatibility mode

Show the latest restore report explicitly:

```sh
show-restore-report.sh
```

The restore report reuses the same warning model, so the same health issues remain visible after restore.

Inspect or apply snapshot retention manually:

```sh
prune-snapshots.sh --dry-run --print-actions
prune-snapshots.sh
```

Show script help:

```sh
restore-state.sh --help
resume-session.sh --help
```

Attach semantics:

- shell-driven `--attach` only attaches the current terminal window
- restore invoked from inside tmux only switches the current tmux client
- when a tmux client is available, restore also opens a post-restore report popup

## Restore Profiles

Profiles live in [`profiles/`](profiles/). Built-in examples:

- `safe`
- `all`

Current profile knobs:

- `attach`
- `preview`
- `include_archived`
- `startup_mode`

Precedence:

1. explicit CLI flags
2. selected profile
3. tmux global options
4. built-in defaults

Use a profile explicitly:

```sh
restore-state.sh --profile safe --session-name work --yes
resume-session.sh --profile all work
choose-saved-session.sh --profile all --manifest /path/to/manifest.json
```

Override a previewing or archived-including profile:

```sh
restore-state.sh --profile safe --no-preview --session-name work --yes
choose-saved-session.sh --profile all --hide-archived --manifest /path/to/manifest.json
```

Set the default profile for tmux-driven flows:

```tmux
set -g @tmux-revive-default-profile all
```

## Session Labels

Keep the tmux session name as the runtime identifier and use the label for readability.

Set or change the human-readable label:

```tmux
prefix + m
l
```

or:

```sh
set-session-label.sh
```

## Startup Restore

The startup policy is controlled by:

```tmux
set -g @tmux-revive-startup-restore prompt
```

Supported values:

- `prompt`
- `auto`
- `off`

If the default restore profile sets `startup_mode`, that profile value wins over the tmux startup option.

Typical choices:

- use `prompt` as the default safe mode
- use `auto` only when you want tmux startup to restore immediately from the latest snapshot
- use `off` while debugging or when you want startup to stay empty
- in `prompt` mode without a client TTY, tmux-revive leaves the prompt state untouched so the popup can still appear later on a real attach
- in `auto` mode with a client TTY, tmux-revive shows the same post-restore report popup after restore completes

Prompt behavior:

- the same restore prompt model is used for:
  - fresh tmux startup
  - creating a new tmux session while restorable saved sessions exist
- prompt actions support:
  - restore all and attach
  - restore all without attaching
  - choose one session and attach
  - choose one session without attaching
  - dismiss
- if the prompt is reached from a temporary blank session and you choose an attach action, tmux-revive replaces that transient session instead of leaving it behind
- archived sessions are excluded from startup prompts by default

Archive or unarchive one saved session:

```sh
archive-session.sh --session-guid 123e4567-e89b-12d3-a456-426614174000
archive-session.sh --session-guid 123e4567-e89b-12d3-a456-426614174000 --unarchive
```

## Neovim Fidelity

Neovim restore now preserves, for supported clean file-backed sessions:

- tabs
- current tab/current window
- file-backed windows with best-effort tab/current-window restore
- cwd
- cursor positions

It still does not restore split-orientation fidelity, unsupported buffer types such as terminal, quickfix, location-list, or dirty unsaved buffers.

## Hooks

`tmux-revive` now supports best-effort save/restore hooks inspired by `tmux-resurrect`.

tmux options:

```tmux
set -g @tmux-revive-pre-save-hook '...'
set -g @tmux-revive-post-save-hook '...'
set -g @tmux-revive-pre-restore-hook '...'
set -g @tmux-revive-post-restore-hook '...'
```

The hook command runs through `sh -c` and receives environment variables describing the event.

Common variables:

- `TMUX_REVIVE_HOOK_EVENT`
- `TMUX_REVIVE_HOOK_MANIFEST_PATH`

Save hook variables:

- `TMUX_REVIVE_HOOK_REASON`
- `TMUX_REVIVE_HOOK_AUTO`
- `TMUX_REVIVE_HOOK_RUNTIME_DIR`
- `TMUX_REVIVE_HOOK_SNAPSHOT_DIR`

Restore hook variables:

- `TMUX_REVIVE_HOOK_SELECTOR_GUID`
- `TMUX_REVIVE_HOOK_SELECTOR_ID`
- `TMUX_REVIVE_HOOK_SELECTOR_NAME`
- `TMUX_REVIVE_HOOK_ATTACH_TARGET`
- `TMUX_REVIVE_HOOK_RESTORED_COUNT`
- `TMUX_REVIVE_HOOK_RESTORE_LOG`
- `TMUX_REVIVE_HOOK_RESTORE_REPORT`

Example:

```tmux
set -g @tmux-revive-post-restore-hook 'printf "%s %s\n" "$TMUX_REVIVE_HOOK_EVENT" "$TMUX_REVIVE_HOOK_ATTACH_TARGET" >> ~/.tmux-revive-hook.log'
```

Shell-driven restore can also use env fallbacks without touching tmux global options:

```sh
TMUX_REVIVE_PRE_RESTORE_HOOK='printf "%s\n" "$TMUX_REVIVE_HOOK_SELECTOR_NAME" >> /tmp/tmux-restore.log' \
restore-state.sh --session-name work --yes
```

## Save Lock Recovery

Saves use a runtime lock under the tmux-revive state root. If a prior save crashed, the next save can recover a stale lock automatically.

Control the stale-lock timeout with:

```tmux
set -g @tmux-revive-save-lock-timeout 120
```

The value is in seconds. The default is `120`.

## Pane Metadata

Exclude a pane transcript from snapshots:

```sh
pane-meta.sh exclude-transcript on
```

Mark a pane as preview-only:

```sh
pane-meta.sh set-command-preview 'npm run dev'
```

Mark a pane for explicit restart-command restore:

```sh
pane-meta.sh set-restart-command 'make -f /path/to/Makefile restart-proof'
```

Inspect saved pane metadata:

```sh
pane-meta.sh show
```

## Pane Restore UX

Non-Neovim panes restore conservatively:

- approved restart commands auto-run quietly
- exact unapproved running commands are preloaded at the prompt without extra banner text
- panes with no exact running command restore only the bounded transcript context and a clean prompt
- restored `zsh` and `bash` panes load the normal shared shell history file, not a per-pane private history

Current transcript behavior:

- snapshots replay the last 500 captured pane lines
- restored panes stay visually quiet; tmux-revive does not inject explanatory restore banners into the pane body

## Restore Constraints

- grouped tmux sessions are skipped and reported as unsupported in v1
- restored window names are kept stable by leaving `automatic-rename` disabled on restored windows
- existing live sessions are always skipped rather than overwritten

## Validation Loop

When changing restore behavior, use this loop:

1. reload tmux config
2. save a fresh snapshot
3. restore by session label or GUID in an isolated test case
4. verify tmux structure, Neovim file state, transcript behavior, and collision handling

> **Warning:** Never run `tmux kill-server`, `save-state.sh`, or
> `restore-state.sh` against the default tmux socket — this will kill your
> live session. The test harness isolates each case on a dedicated socket
> via `-L`. If testing manually outside the harness, always use
> `tmux -L test-socket` to target a separate server.

Run the committed regression harness:

```sh
tests/test_restore_stack.sh all
```

Run focused suites:

```sh
tests/test_restore_stack.sh startup
tests/test_restore_stack.sh autosave
tests/test_restore_stack.sh nvim
tests/test_restore_stack.sh nvim-tmux-restore
tests/test_restore_stack.sh mixed-session
tests/test_restore_stack.sh hooks
tests/test_restore_stack.sh stale-lock
tests/test_restore_stack.sh idempotent
tests/test_restore_stack.sh partial-live
tests/test_restore_stack.sh window-names
tests/test_restore_stack.sh bounded-history
tests/test_restore_stack.sh startup-prompt-no-tty
tests/test_restore_stack.sh grouped-sessions
```
