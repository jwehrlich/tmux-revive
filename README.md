# tmux-revive

A tmux plugin for saving, restoring, and templating your tmux workspace. Survive crashes, reboots, and context switches — your sessions come back exactly as you left them.

## Features

- **Save & Restore** — snapshots of all sessions, windows, panes, names, layout, and cwd
- **Templates** — YAML-defined workspaces with trusted commands, variables, per-host overrides
- **tmux-revive picker** — fzf-based interactive picker for managing sessions, snapshots, and templates
- **Autosave** — periodic background saves with configurable interval
- **Neovim integration** — restores file-backed tabs, windows, cwd, and cursor positions
- **Startup restore** — prompt or auto-restore when tmux starts
- **Profiles** — named restore configurations for different workflows
- **Export/Import** — portable snapshot and template bundles for sharing across machines

Restore is intentionally conservative — it does not try to blindly restart every process.

## Requirements

- tmux 3.0+
- bash 4.0+
- [fzf](https://github.com/junegunn/fzf) — interactive picker UI
- [jq](https://github.com/jqlang/jq) — snapshot JSON processing
- [yq](https://github.com/mikefarah/yq) — template YAML processing
- (optional) [neovim](https://neovim.io/) — for nvim session restore

## Installation

### With [TPM](https://github.com/tmux-plugins/tpm) (recommended)

Add to your `.tmux.conf`:

```tmux
set -g @plugin 'jwehrlich/tmux-revive'
```

Then press `prefix + I` to install.

### Manual

Clone the repo:

```sh
git clone https://github.com/jwehrlich/tmux-revive.git ~/.tmux/plugins/tmux-revive
```

Add to your `.tmux.conf`:

```tmux
run-shell ~/.tmux/plugins/tmux-revive/revive.tmux
```

Reload tmux:

```tmux
prefix + r
```

## Configuration

Add any of these to `.tmux.conf` before the plugin is loaded:

```tmux
# Keybindings (defaults shown)
set -g @tmux-revive-save-key 'S'
set -g @tmux-revive-restore-key 'R'
set -g @tmux-revive-manage-key 'm'

# Data directory (default: ~/.tmux/data or ~/.config/tmux/data)
# set -g @tmux-revive-data-dir '~/.tmux/data'

# Autosave
set -g @tmux-revive-autosave 'on'
set -g @tmux-revive-autosave-interval '900'

# Startup restore: 'prompt', 'auto', or 'off'
set -g @tmux-revive-startup-restore 'prompt'

# Snapshot retention
set -g @tmux-revive-retention-enabled 'on'
set -g @tmux-revive-retention-auto-count '20'
set -g @tmux-revive-retention-manual-count '60'
set -g @tmux-revive-retention-auto-age-days '14'
set -g @tmux-revive-retention-manual-age-days '90'
```

### Default paths

| Path | Purpose |
|------|---------|
| `~/.tmux/data` | State root (or `~/.config/tmux/data` for XDG layouts) |
| `~/.tmux/data/snapshots/<hostname>/` | Snapshots |
| `~/.tmux/data/templates/` | Templates |
| `~/.tmux/data/runtime/` | Runtime files |

Override the state root with `@tmux-revive-data-dir` in `.tmux.conf` or
`TMUX_REVIVE_STATE_ROOT` environment variable.

> **Migration note:** If you have existing data in `~/.tmux/tmp/sessions`, the
> plugin will automatically copy it to the new data directory on first load.

For deeper details, see:
- [workflow.md](workflow.md)
- [known-limitations.md](known-limitations.md)

## Daily Commands

Manual save:

```tmux
prefix + S
```

Manual restore of the latest snapshot:

```tmux
prefix + R
```

Enter manage mode:

```tmux
prefix + m
```

From manage mode:
- `m`: open the fuzzy picker
- `t`: open tmux `choose-tree`
- `r`: open the saved-session chooser
- `b`: browse saved snapshots
- `l`: set the current session label
- `s`: save
- `R`: restore latest
- `?`: show the manage menu
- `q` or `Escape`: leave manage mode

The fuzzy picker now shows:
- current live session first
- other live sessions next
- saved sessions from the default snapshot source afterward

Saved rows in the picker are resume-only in the default view.

### tmux-revive keybindings

Press `?` inside the picker to show the full cheat sheet. Quick reference:

| Key | Action |
|-----|--------|
| `Enter` | Jump to session/window/pane; action menu on snapshots/templates |
| `Esc` | Close picker |
| `Ctrl-b` | Toggle snapshots view |
| `Ctrl-e` | Toggle templates view |
| `Ctrl-a` | Restore all sessions from snapshot |
| `Ctrl-t` | Create new session |
| `Ctrl-r` | Rename session |
| `Ctrl-l` | Set session label |
| `Ctrl-d` | Delete session, snapshot, or template |
| `Ctrl-w` | Create new window |
| `Ctrl-p` | Create new pane |
| `?` | Show help cheat sheet |

#### Snapshot action menu

Press `Enter` on a snapshot row (toggle snapshots with `Ctrl-b` first):

- **Drill In** — browse individual sessions inside the snapshot
- **Restore** — restore all sessions defined in that snapshot
- **Export** — export the snapshot as a portable `.tar.gz` bundle
- **Delete** — remove the snapshot directory (with confirmation)
- **Convert to Template** — create a YAML template from the snapshot

#### Template action menu

Press `Enter` on a template row (toggle templates with `Ctrl-e` first):

- **Launch** — apply the template (creates all sessions)
- **Edit** — open in `$EDITOR` with validation on save
- **Delete** — remove with confirmation
- **Export** — export the template as a portable `.tar.gz` bundle
- **Rename** — rename the template (updates both filename and `name:` field)
- **Duplicate** — copy to a new name

## Save / Restore / Resume

List saved sessions from the latest snapshot:

```sh
restore-state.sh --list
```

Default columns:
- `SESSION_GUID`
- `SESSION_NAME`
- `LAST_UPDATED`

Restore the latest snapshot:

```sh
restore-state.sh --yes
```

Preview a restore plan without changing tmux:

```sh
restore-state.sh --preview
restore-state.sh --manifest /path/to/manifest.json --preview
restore-state.sh --session-name work --preview
```

The preview now includes advisory health warnings for issues such as:
- missing pane cwd paths
- missing `tail -f` targets
- missing Neovim restore files
- snapshot host mismatch / legacy compatibility mode

Show the latest restore report explicitly:

```sh
show-restore-report.sh
```

The restore report includes the same health warnings section so likely problems are visible after restore as well.

Inspect or apply snapshot retention manually:

```sh
prune-snapshots.sh --dry-run --print-actions
prune-snapshots.sh
```

Restore one saved session by label:

```sh
restore-state.sh --session-name work --yes
```

Restore one saved session by GUID:

```sh
restore-state.sh --session-guid 123e4567-e89b-12d3-a456-426614174000 --yes
```

Restore and attach from a normal shell:

```sh
restore-state.sh --session-name work --attach --yes
```

Resume one saved session with the convenience wrapper:

```sh
resume-session.sh --list
resume-session.sh work
resume-session.sh 123e4567-e89b-12d3-a456-426614174000
```

The saved-session chooser now shows richer metadata for each saved session:
- snapshot timestamp
- snapshot reason
- short GUID
- first few window names
- whether that saved session is already live

Archived saved sessions are hidden from default choosers. To include them explicitly:

```sh
choose-saved-session.sh --manifest /path/to/manifest.json --include-archived
```

Browse snapshots and pick an older one interactively:

```sh
choose-snapshot.sh --yes
```

Imported snapshots are hidden from the default browser view. To include them explicitly:

```sh
choose-snapshot.sh --yes --include-imported
```

Snapshot browser keys:
- `Enter`: choose a snapshot, then choose one saved session from it
- `Ctrl-a`: restore all sessions from the selected snapshot
- the right-side preview pane shows the restore plan for the highlighted snapshot

Export or import snapshot bundles:

```sh
# Export the latest snapshot
export-snapshot.sh --latest --output /tmp/latest-snapshot.tar.gz

# Export a specific snapshot by manifest path
export-snapshot.sh --manifest /path/to/manifest.json --output /tmp/work-snapshot.tar.gz

# Import a snapshot bundle
import-snapshot.sh --bundle /tmp/work-snapshot.tar.gz
```

You can also export/import snapshots from the picker:

1. Press `Ctrl-b` to toggle to the snapshots view
2. Press `Enter` on any snapshot
3. Select **Export** from the action menu

The export creates a self-contained `.tar.gz` archive that can be shared and imported on another machine.

Imported snapshots:
- preserve original source metadata
- are tagged locally as imported
- are hidden from default choosers and startup flows unless you opt in explicitly

Archive or unarchive a saved session by GUID:

```sh
archive-session.sh --session-guid 123e4567-e89b-12d3-a456-426614174000
archive-session.sh --session-guid 123e4567-e89b-12d3-a456-426614174000 --unarchive
archive-session.sh --session-guid 123e4567-e89b-12d3-a456-426614174000 --status
```

Archived sessions:
- are stored in a durable `session-index.json`, not in snapshot manifests
- are hidden from startup prompts by default
- are hidden from default saved-session choosers and tmux-revive saved rows by default

Attach behavior:
- outside tmux, `--attach` attaches only the current terminal window
- inside tmux, restore switches only the current tmux client
- existing live sessions are skipped, never overwritten
- when a tmux client is available, restore also opens a post-restore report popup

Built-in help:

```sh
restore-state.sh --help
resume-session.sh --help
```

## Templates

Templates are intentionally authored workspace definitions written in YAML. Unlike snapshots (which capture live state and use a conservative command allowlist), templates **trust all commands** — every `command:` field runs unconditionally on apply.

Templates live at `~/.tmux/data/templates/<name>.yaml`.

### Template format

```yaml
name: web-dev
description: Full-stack web development workspace
updated_at: "2026-03-26T00:00:00Z"

variables:
  project_root:
    prompt: "Project root directory"
    default: ~/src/myproject

sessions:
  - name: frontend
    windows:
      - name: editor
        layout: main-vertical
        panes:
          - cwd: "{{project_root}}/frontend"
            command: nvim .
          - cwd: "{{project_root}}/frontend"
            command: npm run dev
      - name: shell
        panes:
          - cwd: "{{project_root}}/frontend"

  - name: backend
    windows:
      - name: server
        panes:
          - cwd: "{{project_root}}/backend"
            command: cargo run
          - cwd: "{{project_root}}/backend"
```

Supported pane fields: `cwd`, `command`, `env` (key-value map).

Layout can be any tmux built-in layout name (`even-horizontal`, `even-vertical`, `main-horizontal`, `main-vertical`, `tiled`).

Use bare `~` or `~/path` for home-relative paths. Panes without `cwd` default to `$HOME`.

### Per-host overrides

Templates can include host-specific overrides that merge on top of the base definition:

```yaml
overrides:
  my-work-laptop:
    sessions:
      - name: frontend
        windows:
          - name: editor
            panes:
              - cwd: /work/custom/path
```

Overrides match by session name → window name → pane index (positional). Only specified fields are overwritten; everything else inherits from the base.

### Applying a template

Preview what would be created:

```sh
apply-template.sh --name web-dev --dry-run
```

Apply the template (creates sessions immediately):

```sh
apply-template.sh --name web-dev
```

Apply and attach to the first session:

```sh
apply-template.sh --name web-dev --attach
```

Apply with variable overrides (skips interactive prompts for those variables):

```sh
apply-template.sh --name web-dev --var project_root=~/work/client
apply-template.sh --name web-dev --var project_root=~/work --var branch=develop
```

Apply non-interactively (uses all defaults, no prompts):

```sh
apply-template.sh --name web-dev --no-prompt
```

If a session name already exists, it is automatically renamed with a `-2` suffix (incrementing: `-3`, `-4`, etc.).

### Collision policy

When applying a template, session names that collide with existing live tmux sessions are automatically suffixed:

- `frontend` → `frontend-2` (first collision)
- `frontend-2` → `frontend-3` (already suffixed — increment)
- `frontend-99` → `frontend-100`

This happens transparently. The restore log and dry-run output show the final names used. Collision handling applies to both `apply-template.sh` and `restore-state.sh` (template mode).

### Template variables

Templates can declare variables with prompts and default values. When applying, users are prompted for each variable (or defaults are used with `--no-prompt`).

```yaml
variables:
  project_dir:
    prompt: "Project directory"
    default: ~/src/myproject
  branch:
    prompt: "Git branch to checkout"
    default: main
```

Use `{{variable_name}}` in `cwd` and `command` fields:

```yaml
panes:
  - cwd: "{{project_dir}}"
    command: "git checkout {{branch}} && nvim ."
```

Variables are expanded after `~` and `$USER`/`$TMUX_REVIVE_TPL_*` expansion. Unexpanded `{{...}}` placeholders cause an error.

### Converting snapshots to templates

From the picker (`Ctrl-b` to view snapshots), press Enter on a snapshot to get the action menu. Select **Convert to Template** to create a YAML template from the snapshot. You'll be prompted for a template name and optionally offered to open it for editing (to replace raw layout strings with named layouts).

See [Snapshot action menu](#snapshot-action-menu) for all available snapshot actions.

From the command line:

```sh
template-create.sh --name from-snap --from-snapshot /path/to/manifest.json
```

### Validating a template

Check a template for structural errors before applying:

```sh
template-validate.sh --name web-dev
template-validate.sh --file /path/to/template.yaml
template-validate.sh --name web-dev --quiet
```

Validation checks: YAML parseability, required fields (`name`, `sessions`, window `name`, non-empty `panes`), variable schema (each must have `prompt`), and warns on nonexistent `cwd` paths and undefined `{{var}}` references.

### Creating templates

Create a blank scaffold template (with examples and comments):

```sh
template-create.sh --name my-workspace --blank
template-create.sh --name my-workspace --blank --edit  # opens in $EDITOR
```

Create a template from a saved snapshot:

```sh
template-create.sh --name from-snap --from-snapshot /path/to/manifest.json
```

Save the current live session as a template:

```sh
template-save.sh --name my-workspace
template-save.sh --name fullstack --sessions frontend,backend
template-save.sh --name dev --description "Dev environment"
```

Or edit templates directly as plain YAML:

```sh
$EDITOR ~/.tmux/data/templates/my-workspace.yaml
```

### Listing templates

```sh
template-list.sh
template-list.sh --json
```

### Editing templates

Open a template in `$EDITOR` with validation on save:

```sh
template-edit.sh --name web-dev
```

The editor re-opens if validation fails, letting you fix errors. The `updated_at` field is automatically updated on successful edits. If no changes are made, the script exits cleanly.

### Deleting templates

```sh
template-delete.sh --name old-workspace        # prompts for confirmation
template-delete.sh --name old-workspace --yes  # skip confirmation
```

### Templates in the picker

Templates are integrated into the picker (`prefix+m`). Press `Ctrl-e` to toggle the templates view.

When you select a template and press `Enter`, an action menu appears:

- **Launch** — apply the template (creates all sessions)
- **Edit** — open in `$EDITOR` with validation on save
- **Delete** — remove with confirmation
- **Export** — export as a portable `.tar.gz` bundle
- **Rename** — rename the template (updates filename and `name:` field)
- **Duplicate** — copy the template to a new name

Press `Ctrl-d` on a template row to delete it directly (with confirmation).

Press `Esc` on the action menu to go back to the picker. See [tmux-revive keybindings](#tmux-revive-keybindings) for the full reference.

To show templates on picker launch:

```sh
pick.sh --show-templates
```

The preview pane shows the full YAML content when a template row is selected.

### Environment variables

Panes can set environment variables that are passed to the command:

```yaml
panes:
  - cwd: ~/src/app
    command: npm run dev
    env:
      NODE_ENV: development
      PORT: "3000"
```

### Portable cwd variables

Template `cwd` fields support `$USER` and any `$TMUX_REVIVE_TPL_*` environment variable for portability across machines:

```yaml
panes:
  - cwd: /home/$USER/projects
  - cwd: $TMUX_REVIVE_TPL_PROJECT
```

Only `$USER` and variables with the `TMUX_REVIVE_TPL_` prefix are expanded (to avoid accidentally leaking sensitive vars like `$AWS_SECRET_KEY`).

### Exporting and importing templates

Export a template as a portable `.tar.gz` bundle:

```sh
template-export.sh --name web-dev
template-export.sh --name web-dev --output ~/shared/web-dev.tar.gz
```

Import a template from a bundle:

```sh
template-import.sh web-dev.tmux-template.tar.gz
template-import.sh web-dev.tar.gz --name my-copy    # rename on import
template-import.sh web-dev.tar.gz --force           # overwrite existing
```

## Restore Profiles

Restore profiles live in [`profiles/`](profiles/) and are JSON files.

Built-in profiles:
- `safe`
- `all`

Current v1 profile knobs:
- `attach`
- `preview`
- `include_archived`
- `startup_mode`

Precedence:
1. explicit CLI flags
2. selected profile
3. tmux global options
4. built-in defaults

Use a profile directly:

```sh
restore-state.sh --profile safe --session-name work --yes
restore-state.sh --profile all --session-name work --yes
resume-session.sh --profile all work
choose-snapshot.sh --profile safe --yes
choose-saved-session.sh --manifest /path/to/manifest.json --profile all
```

Set a default profile for tmux-driven startup and chooser flows:

```tmux
set -g @tmux-revive-default-profile safe
```

Useful overrides:

```sh
restore-state.sh --profile safe --no-preview --session-name work --yes
choose-saved-session.sh --profile all --hide-archived --manifest /path/to/manifest.json
```

## Startup Restore

Startup restore is controlled by the tmux option:

```tmux
set -g @tmux-revive-startup-restore prompt
```

Supported modes:
- `prompt`
- `auto`
- `off`

If a default restore profile is configured and includes `startup_mode`, that profile value overrides the tmux startup option.

Recommended default:
- use `prompt` unless you explicitly want automatic restore on attach

Behavior notes:
- startup restore is conservative and skips live-session collisions
- in `prompt` mode without a real client TTY, the prompt can still appear later on a real attach
- the same prompt flow is also used when a new tmux session is created and saved sessions are restorable
- prompt actions now support both attach and no-attach flows:
  - restore all and attach
  - restore all without attaching
  - choose one session and attach
  - choose one session without attaching
  - dismiss
- if a new blank session was created only to reach the prompt flow, choosing an attach action replaces that transient session instead of leaving it behind
- startup `auto` mode also reuses the same restore report popup when a client tty is available

## Session Identity Model

Each saved session has:
- `session_guid`: durable identity used for reliable restore targeting
- `session_name`: human-readable label shown to the user

At runtime, tmux may also use a distinct live tmux session name when needed for uniqueness.

Practical rule:
- use the label for readability
- use the GUID when you want an exact selector

Set or update the current session label:

```tmux
prefix + m
l
```

or:

```sh
set-session-label.sh
```

## Pane Restore Behavior

Non-Neovim panes restore conservatively:
- approved restart commands auto-run quietly
- exact unapproved running commands are preloaded at the prompt
- panes with no exact captured running command restore transcript context only
- panes remain visually quiet; tmux-revive does not inject explanatory banners into pane output

Current transcript behavior:
- snapshots replay the last `500` captured pane lines

Current shell behavior:
- restored `zsh` and `bash` panes load normal shared shell history
- tmux-revive does not maintain per-pane shell history stores

Neovim panes:
- relaunch `nvim`
- restore file-backed tabs/windows, cwd, current tab/window, and cursor positions for supported clean sessions
- do not restore non-file buffers, terminal buffers, quickfix/location lists, or dirty buffers

Approved auto-restart commands are intentionally conservative. Today that includes command families such as:
- `tail -f` / `tail -F`
- `make ...`
- `just ...`
- `npm run ...`
- `pnpm run ...`
- `yarn run ...`
- `uv run ...`
- `cargo run ...`
- `go run ...`
- `docker compose up ...`
- `python -m http.server`

For exact current matching behavior, see [`state-common.sh`](lib/state-common.sh).

Pane metadata helpers:

```sh
pane-meta.sh show
pane-meta.sh exclude-transcript on
pane-meta.sh set-command-preview 'npm run dev'
pane-meta.sh set-restart-command 'make -f /path/to/Makefile restart-proof'
```

## Hooks And Advanced Configuration

Hook options:

```tmux
set -g @tmux-revive-pre-save-hook '...'
set -g @tmux-revive-post-save-hook '...'
set -g @tmux-revive-pre-restore-hook '...'
set -g @tmux-revive-post-restore-hook '...'
```

Startup and autosave options:

```tmux
set -g @tmux-revive-startup-restore prompt
set -g @tmux-revive-autosave on
set -g @tmux-revive-autosave-interval 900
set -g @tmux-revive-save-lock-timeout 120
```

Shell-driven hook fallback example:

```sh
TMUX_REVIVE_PRE_RESTORE_HOOK='printf "%s\n" "$TMUX_REVIVE_HOOK_SELECTOR_NAME" >> /tmp/tmux-restore.log' \
restore-state.sh --session-name work --yes
```

For the full hook variable set and operational details, see [`workflow.md`](workflow.md).

## Troubleshooting

Latest restore log:

```sh
cat ~/.tmux/data/runtime/logs/latest-restore.log
```

Latest restore report:

```sh
show-restore-report.sh
```

List saved sessions:

```sh
restore-state.sh --list
```

Run the full regression suite:

```sh
tests/test_restore_stack.sh all
```

Run a focused mixed restore scenario:

```sh
tests/test_restore_stack.sh mixed-session
```

Run the template test suite:

```sh
bats tests/templates.bats
```

> **Warning:** Never run `tmux kill-server` or tmux-revive scripts against
> the default socket outside the test harness — this will kill your live
> session. The harness isolates each test on a dedicated socket via `-L`.
> For manual testing, use `tmux -L test-socket`.

If restore does not behave as expected:
- take a fresh save before retesting, especially after restore logic changes
- check the latest restore log
- verify whether the pane command is actually in the approved auto-restart set
- verify whether the saved cwd or target file still exists

tmux-revive checks for `fzf`, `jq`, and `yq` on startup and will error if any are missing. If `yq` is missing, template previews show a yellow warning instead of silently displaying blank content.

## Limitations

Important current limits:
- grouped tmux sessions are restored (leaders normally, followers linked via `new-session -t`)
- existing live sessions are skipped rather than overwritten
- restored windows intentionally keep `automatic-rename` disabled so saved names remain stable
- Neovim restore is still limited to supported clean file-backed sessions; split-orientation fidelity remains future work
- a real day-to-day Neovim restore smoke pass is still useful after major restore changes
- old pre-GUID snapshots still restore in compatibility mode

See [`known-limitations.md`](known-limitations.md) for the full list.
