# tmux-revive Known Limitations

## Restore Scope

- tmux restores sessions, windows, panes, names, titles, cwd, and layout, but it does not provide generic process resurrection.
- `restart-command` only auto-runs a conservative allowlist of explicit commands.
- exact unapproved running commands are preloaded at the prompt and are never auto-executed.
- panes without an exact captured running command restore as transcript-plus-shell only.
- grouped tmux sessions are restored: leaders restore normally, followers are linked via `new-session -t <leader>`. Issues are reported if a leader session is missing.

## Neovim Scope

- v1 restores file-backed tabs/windows, cwd, current tab/window, and cursor positions.
- non-file buffers are not restored.
- terminal buffers are not restored.
- quickfix and location lists are saved and restored (capped at 500 quickfix / 200 loclist entries per window to avoid snapshot bloat). Lists exceeding the cap are truncated.
- dirty buffer content is now saved to recovery files during snapshot. On restore, use `:DiffRecovered` to open diff views comparing the on-disk file with the recovered unsaved content.
- split-orientation/layout fidelity is now restored from saved layout trees (horizontal vs vertical splits). Legacy snapshots without layout data fall back to vsplit-all.
- richer Neovim fidelity beyond supported clean file-backed sessions still stays future scope.

## Startup and Autosave

- startup restore is conservative and skips live-session collisions rather than overwriting them.
- on tmux 3.2+, autosave uses a self-rescheduling `run-shell -d` timer that is immune to status-right overwrites. On older tmux versions, autosave is driven by the statusline tick, so replacing the status-right command path can affect cadence. **If a theme plugin overwrites `status-right` on tmux < 3.2, autosave will stop silently.** Ensure tmux-revive's `autosave-tick.sh` call remains in `status-right` after all theme plugins have loaded when using the legacy fallback.
- autosave is configurable, but the default assumes tmux status updates continue to run normally.
- save lock recovery checks whether the lock-holding PID is still alive and falls back to a timeout; if a still-live save process is legitimately slow, an overly aggressive timeout could allow a second save attempt.
- restored windows intentionally keep `automatic-rename` disabled so saved names remain stable.

## Test Coverage

- the committed regression suite covers the tmux restore stack, tmux-triggered Neovim relaunch, and direct Neovim snapshot/restore semantics.
- the regression suite now also covers save/restore hooks, stale save-lock recovery, and the isolated three-window mixed restore scenario.
- the regression suite also covers idempotent restore, partial live-session restore, bounded pane history capture, startup prompt behavior without a TTY, stable restored window names, grouped-session restore, special character handling, pane split failure, retention boundary values, and export/import error paths.
- a manual interactive tmux client smoke pass is still useful for confidence, but it is no longer the only way to validate the Neovim restore path.

## Hook Model

- hook commands are best-effort and intentionally do not fail save or restore if the hook exits non-zero.
- restore hooks triggered from a plain shell may need env-based hook configuration instead of tmux global options, because there may be no live tmux server yet when the hook is evaluated.

## Operational Notes

- old snapshots created before the GUID migration still restore in compatibility mode and may require legacy selectors.
- tmux session labels are the user-facing identifiers; tmux session ids are debug-level metadata only.
- if restored pane cwd paths no longer exist, tmux-revive warns but still recreates the pane.
- restored `zsh` and `bash` panes load the normal shared shell history file, but tmux-revive does not maintain separate per-pane history stores.
