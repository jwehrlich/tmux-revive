# tmux-revive Changelog

## 2026-03-22 — Phase 8: Hardening, Upstream Parity, and Robustness

Comprehensive audit and hardening pass comparing tmux-revive against
tmux-resurrect and tmux-continuum. All 40 items completed. Test suite
grew from 72 to 86 tests.

### Critical Bug Fixes

- **TOCTOU race on save lock** — `mkdir` is now used as the atomic
  test-and-set after stale lock removal; two processes can no longer
  both believe they hold the lock.
- **Unquoted heredoc in AWK** — fixed shell expansion inside AWK
  heredoc that could corrupt process-tree output.
- **jq failure corrupts session index** — all jq writes now go through
  atomic tmp+mv so a jq crash never leaves a truncated file.
- **EOF infinite loop in restore popup** — added explicit EOF guard to
  the read loop so a closed stdin no longer spins.
- **Silent queued auto-save failures** — queued saves now log errors
  instead of silently swallowing them.
- **pick.sh nested read bug** — fixed fd collision when pick.sh read
  from stdin inside a while-read loop.

### High-Impact Fixes

- **Zoom state save/restore** — window zoom flag is now saved and
  restored.
- **First-load save delay guard** — first autosave after server start
  is deferred by the full interval instead of firing immediately.
- **Restore pane_field type mismatch** — pane field lookups no longer
  fail silently on type mismatches.
- **Manifest validation before restore** — restore now validates
  manifest structure before acting.
- **jq dependency check** — state-common.sh exits early with a clear
  message if jq is not installed.
- **Window automatic-rename option** — restored windows disable
  automatic-rename so saved names stay stable.
- **Save mkdir error check** — save aborts cleanly if the snapshot
  directory cannot be created.
- **Pane count mismatch fallback** — when split-window fails, restore
  records fallbacks for all affected panes and continues.
- **Export/import error checks** — both scripts now validate inputs and
  report clear errors.

### New Features

- **Grouped session support** — tmux grouped sessions (created with
  `new-session -t`) are now saved and restored. Leaders restore
  normally; followers are deferred to a second pass and linked via
  `new-session -t <leader>`.
- **Multi-server auto-restore guard** — startup restore skips
  automatically when multiple tmux servers are detected, preventing
  duplicate restores.
- **Save-on-server-exit** — `session-closed` hook triggers an auto-save
  so the last session state is always captured.
- **Configurable restartable commands** — users can extend the
  auto-restart allowlist via the tmux option
  `@tmux-revive-restartable-commands`.
- **Status line style customization** — `@tmux-revive-status-style`
  lets users style the save/auto-save status indicator.
- **Process detection fallback** — when the AWK process-tree walker
  returns empty, save falls back to `pane_current_command`.
- **Boot/system integration** — new `system/` directory with
  launchd (macOS) and systemd (Linux) enable/disable scripts for
  auto-starting tmux on login.
- **Configurable save notice duration** —
  `@tmux-revive-save-notice-duration` controls how long the status
  bar indicator stays visible.

### Robustness Improvements

- **Hostname fallback** — `hostname -s` falls back to `hostname` then
  `'unknown'` for portability.
- **Hook log directory** — hook error logging now creates the log
  directory if it doesn't exist.
- **Halt file** — placing `~/.tmux_revive_no_restore` disables startup
  restore entirely.
- **Transient session collision re-check** — after killing a transient
  session during restore, the name is re-checked before reuse.
- **stat portability** — snapshot pruning uses `stat -c` with
  `stat -f` fallback for macOS/Linux compatibility.
- **mktemp error check** — start-restored-pane.sh validates mktemp
  succeeded.
- **cd failure warning** — restored panes warn about missing cwd
  instead of silently falling back.
- **bash profile fallback** — restored bash panes try `.bash_profile`
  when `.bashrc` doesn't exist.
- **tmux option as IPC** — autosave timestamp is cached in a tmux
  global option to avoid file I/O on every status tick.
- **`tmux_revive_get_global_option` empty fallback** — fixed a bug
  where `tmux show-option -gqv` returning empty (exit 0) for unset
  options prevented the default value from being used.
- **`autosave-tick.sh` local-outside-function** — removed invalid
  `local` declarations at script top level.

### Test Coverage

86 tests covering:

- Save/restore round-trips, idempotent restore, partial restore
- Grouped session save and restore
- Snapshot browser, saved-session chooser, Revive integration
- Retention policies (count, age, AND logic, boundary values)
- Autosave policy and status line notice timing
- Neovim snapshot/restore, persistence policy, unsupported metadata
- Export/import round-trip and error paths
- Hooks, stale lock recovery, lock contention
- Special characters in session names and pane titles
- Corrupted manifest handling, empty sessions manifest
- Pane split failure graceful degradation
- Startup prompt modes, dismiss/reappear, transient session replacement
- Bounded history capture, server flag isolation

### Research

- **Alternate screen capture** — investigated `capture-pane -a` for
  alternate screen content. tmux-resurrect doesn't use it either.
  Programs using the alternate screen (vim, less, man) are already
  handled by process-tree detection and restart-command strategy.
  No benefit to adding `-a`.

---

## 2026-03-20 — Intervention Plan and Revive Restore

Comprehensive code audit (claude-intervention.md) identifying 27
issues across 7 categories. 17 items implemented, remaining deferred
to Phase 8.

### Key Changes

- Fixed Revive picker socket-path propagation
- Removed dead scripts (show-command-preview.sh, replay-transcript.sh)
- Fixed start-restored-pane.sh env-arg fallback for non-zsh/non-bash
- Fixed save-state.sh orphan cleanup and save hang recovery
- Added configurable notice duration
- Initial restore support in Revive (saved-session rows with resume)

---

## 2026-03-20 — Initial Restore in Revive

- Revive fuzzy picker now shows saved sessions from the latest
  snapshot alongside live sessions
- Saved rows trigger resume-session flow
- Current session sorts first, then other live sessions, then saved

---

## 2026-03-17 — Core Restore Stack (Phases 1–9)

Full implementation of the tmux session save/restore system built
from scratch, informed by tmux-resurrect and tmux-continuum but using
a structured JSON snapshot format.

### Phase 1–2: Foundation

- JSON-based snapshot format with sessions, windows, panes, layout
- Durable session GUIDs for reliable restore targeting
- Save and restore scripts with atomic file writes

### Phase 3: Shell History and Pane Context

- Bounded pane transcript capture (last 500 lines)
- Restored zsh/bash panes load shared shell history

### Phase 4: Command Restore

- Process-tree walking to detect running commands
- Conservative auto-restart allowlist (tail, make, npm, cargo, etc.)
- Unapproved commands preloaded at prompt, never auto-executed

### Phase 5: Neovim Integration

- Neovim session state snapshot (tabs, windows, cursor, cwd)
- Restore relaunches nvim with saved file-backed session state
- Integration with send_to_nvim.lua

### Phase 6: Startup and Profiles

- Startup restore modes: prompt, auto, off
- Named restore profiles (safe, all) with JSON config
- Profile precedence: CLI flags > profile > tmux options > defaults

### Phase 7: Snapshot Management

- Snapshot browser with fzf preview
- Saved-session chooser with rich metadata
- Export/import as portable tar.gz bundles
- Session archiving (hide from default views)
- Retention policies (count + age limits per snapshot class)

### Phase 8: Autosave

- Autosave via tmux status-line tick
- Configurable interval (`@tmux-revive-autosave-interval`)
- Status bar indicator with spinner during save

### Phase 9: Interactive Restore UX

- Restore preview plan (dry-run summary)
- Post-restore report popup with health warnings
- Startup prompt with attach/no-attach/choose/preview actions
- New-session prompt replaces transient sessions on attach

### Test Suite

72 tests covering the full restore stack, Neovim integration,
hooks, lock recovery, and interactive flows.

---

## 2026-03-10 — Revive

- Initial Revive fuzzy session picker
- tmux choose-tree integration
- Manage mode key table (prefix + m)
