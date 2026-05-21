# Send To Neovim From Tmux

## Goal

Allow a file path visible in a tmux pane running Codex or Claude Code to be opened in another tmux pane that is already running Neovim.

Preferred interaction:

- `Ctrl-Click` on a visible `path[:line]` or `path[:line[:col]]`
- tmux resolves the clicked token
- tmux finds a Neovim pane
- Neovim opens the file and jumps to the requested location

This document is a design note only. No live config changes are implied by this file.

## Why This Needs Custom Plumbing

tmux can receive mouse events, but it does not natively know how to:

- infer the file path nearest the click inside another full-screen app
- locate a different pane running Neovim
- ask that Neovim instance to open the file robustly

The design therefore has three parts:

1. A tmux mouse binding
2. A helper script that extracts the clicked file path
3. A Neovim registration hook so tmux can discover a server socket for the target pane

## Proposed Tmux Binding

File: `~/.dev_setup/.tmux.conf`

```tmux
# Ctrl-click a visible file path and open it in another pane's Neovim.
bind-key -n C-MouseUp1Pane run-shell "$HOME/.tmux/send_to_nvim/open-clicked-path.sh '#{pane_id}' '#{session_id}' '#{window_id}' '#{mouse_x}' '#{mouse_y}' '#{client_tty}'"
```

Notes:

- `Ctrl-Click` is the intended trigger.
- Ghostty is assumed to be configured to forward this modifier-click to tmux.
- We use `MouseUp` rather than `MouseDown` so the action fires after the click is completed.

## Proposed Helper Script

Source file: `~/.dev_setup/tmux/send_to_nvim/open_clicked_path.sh`
Runtime path: `~/.tmux/send_to_nvim/open-clicked-path.sh`

Runtime path policy:

- source of truth lives under `~/.dev_setup/tmux/send_to_nvim/`
- setup creates symlinks under `~/.tmux/send_to_nvim/`
- tmux executes the symlinked runtime paths under `~/.tmux/send_to_nvim/`

Responsibilities:

1. Read source pane id, session id, window id, mouse coordinates, and originating client tty from tmux
2. Capture the visible pane contents, including a wrapped-line-aware logical view
3. Reconstruct the clicked logical token from the clicked row and neighboring wrapped rows when necessary
4. Find the path token nearest the clicked column
5. Resolve the clicked path into an absolute path using the source pane's current working directory and repo-relative fallback rules
6. Parse optional `:line[:col]`
7. Validate the parsed token
8. Find the most relevant registered Neovim instance for the tmux session
9. Ask that Neovim instance to `:tab drop` the file and jump to the requested location
10. Show a tmux popup only for blocking target-editor failures; use status-line messages for low-confidence click failures

Pseudocode:

```text
read source pane id, session id, window id, mouse x, mouse y, client tty
read source pane cwd

capture the visible pane twice:
  raw view for row anchoring
  joined view using tmux capture-pane -J so wrapped lines are reconstructed

use the raw clicked row to identify the smallest path-like fragment under or nearest the click
the raw fragment rule is:
  prefer the maximal contiguous run of path-legal characters that intersects the click column
  if no run intersects the click column, choose the nearest such run on the row
  path-legal characters include letters, digits, `.`, `_`, `-`, `/`, `~`
  `:` is only part of the fragment when it is followed by digits for `:line` or `:line:col`
search the joined view for logical lines containing that fragment
for each matching logical line:
  tokenize file-like candidates
  keep only candidates whose span contains the raw fragment
normalize surviving candidates to:
  absolute_path
  or absolute_path:line
  or absolute_path:line:col
deduplicate normalized candidates
if there is exactly one unique normalized candidate:
  use it
if there are zero or multiple unique normalized candidates:
  show 5-second tmux status message
  exit

if no candidate token is recognized as any path-like target:
  show 5-second tmux status message
  exit

parse candidate token as one of:
  path
  path:line
  path:line:col

if suffix is malformed:
  show 5-second tmux status message
  exit

resolve the path in this order:
  absolute path
  home-relative path
  source-cwd-relative path if it exists
  source repo root + token if source pane is inside a git repo and that path exists
  source repo root + token-with-leading-repo-name-stripped if that path exists

determine source repo root with:
  git -C "$src_cwd" rev-parse --show-toplevel

if resolved file does not exist:
  show 5-second tmux status message
  exit

find the target Neovim instance using the tmux-session registry
validate each registry candidate by:
  checking that the tmux pane still exists
  checking that the Neovim server still responds with:
    nvim --server "$server" --remote-expr '1'
  bounding the liveness probe with a short timeout
if a registry entry fails either liveness check:
  delete that stale registry entry
  continue to the next candidate

if no live Neovim target exists:
  show tmux popup
  exit

if the chosen Neovim target is not already the active pane for the originating client:
  switch only the originating tmux client directly to the target pane

send remote command to target Neovim:
  tab drop absolute file path
  jump to line/column when present
```

## Proposed Neovim Registration Hook

File: likely `~/.dev_setup/nvim/init.lua` or a new small core module

Goal:

- make sure each Neovim instance has a server socket
- publish that socket and pane metadata into a tmux-session registry
- clear it on exit
- refresh recency when the user focuses that Neovim instance

Implementation note:

- Neovim should not construct registry paths from `TMUX` directly.
- The tmux session id should be queried from tmux using `TMUX_PANE`, then passed to a small shell helper that owns the registry format.
- The originating tmux client should be tracked from the mouse binding via `#{client_tty}` so reveal/focus behavior only affects the client that initiated the click.

Preview:

```lua
local function register_tmux_nvim_server()
  if not vim.env.TMUX_PANE then
    return
  end

  local server = vim.v.servername
  if server == nil or server == "" then
    local socket = vim.fn.stdpath("run") .. "/nvim-" .. vim.fn.getpid() .. ".sock"
    server = vim.fn.serverstart(socket)
  end

  if server == nil or server == "" then
    return
  end

  local function refresh_registry()
    vim.fn.system({
      "sh",
      "-lc",
      "$HOME/.tmux/send_to_nvim/register_nvim_instance.sh "
        .. vim.fn.shellescape(vim.env.TMUX_PANE) .. " "
        .. vim.fn.shellescape(server) .. " "
        .. vim.fn.shellescape(tostring(vim.fn.getpid())) .. " "
        .. vim.fn.shellescape(vim.fn.getcwd()),
    })
  end

  refresh_registry()

  vim.api.nvim_create_autocmd({ "FocusGained", "VimEnter", "DirChanged" }, {
    callback = refresh_registry,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    callback = function()
      vim.fn.system({
        "sh",
        "-lc",
        "$HOME/.tmux/send_to_nvim/unregister_nvim_instance.sh "
          .. vim.fn.shellescape(vim.env.TMUX_PANE) .. " "
          .. vim.fn.shellescape(tostring(vim.fn.getpid())),
      })
    end,
  })
end

register_tmux_nvim_server()
```

## Session Registry Design

Registry root:

- `~/.tmux/tmp/sessions/`

Per tmux session:

- `~/.tmux/tmp/sessions/<tmux-session-id>/`

Per Neovim instance:

- `~/.tmux/tmp/sessions/<tmux-session-id>/<pane-id>-<nvim-pid>.json`

The registry file should contain at least:

- `session_id`
- `window_id`
- `pane_id`
- `nvim_pid`
- `server`
- `cwd`
- `last_active_epoch`

Why use a registry file instead of only tmux pane options:

- multiple Neovim instances can coexist cleanly
- recency can be determined by file content and file mtime
- stale entries can be cleaned independently of tmux pane state
- the next-most-recent editor remains discoverable if the newest one disappears

Important adjustment:

- the filename alone is not enough
- each registry file must contain full metadata
- selection should use `last_active_epoch`, not only filesystem mtime
- writes should be atomic so tmux never reads a half-written file
- stale entries should be deleted as soon as liveness checks fail

## Target Selection Policy

When a click is resolved to a file, the helper should choose the target Neovim instance in this order:

1. Read all registry files for the current tmux session
2. Sort by `last_active_epoch` descending
3. For each candidate:
   - verify the tmux pane still exists using tmux pane lookup
   - verify the Neovim server still responds using `nvim --server "$server" --remote-expr '1'`
   - bound the liveness probe with a short timeout, for example 200-300ms
   - if either check fails, delete the stale registry entry and continue to the next most recent candidate
4. Use the first live candidate
5. If no live candidates remain, show a tmux popup explaining that no active Neovim session was found for the current tmux session

This matches the intended user model:

- the Neovim instance most recently used by the user should receive the open request
- if it is stale, fall back to the next most recent live instance
- if the chosen live instance is not already the active pane for the initiating client, tmux should reveal and focus that target pane before opening the file
- reveal/focus operations must be scoped to the originating tmux client only

## Liveness Probe Design

The liveness probe must never block the click action for long enough to feel broken.

Portable design:

1. Put the probe logic in a dedicated helper such as `probe_nvim_server.sh`
2. Run the Neovim probe command in the background:
   - `nvim --server "$server" --remote-expr '1'`
3. Poll the child process for completion in short intervals
4. If it does not finish within the timeout budget, kill it and treat the server as stale
5. Return success only when the probe exits successfully within the timeout

Why this design:

- it avoids relying on platform-specific `timeout` binaries
- it works on both Linux and macOS shells
- it keeps timeout behavior under our control

Recommended timeout budget:

- 250ms per candidate
- stop after the first live candidate

Probe result contract:

- success within timeout: candidate is live
- non-zero exit: candidate is stale
- timeout: candidate is stale

## Client Reveal Design

When the target Neovim pane is not already the active pane for the initiating client, the helper must reveal the correct editor to that same tmux client.

Inputs:

- `client_tty` from the tmux mouse binding
- target session id
- target window id
- target pane id

Required behavior:

1. Scope all reveal actions to the initiating client only
2. If the target pane is not already active for that client, switch that client directly to the target pane
3. Then send the Neovim remote open command

Concrete tmux command shape:

- `tmux switch-client -c "$client_tty" -t "$target_pane"`

Implementation note:

- tmux supports targeting a pane with `switch-client -t`, which changes the client to the correct session, window, and pane in one step
- if zoom-preservation matters during implementation, evaluate `switch-client -Z` as a follow-up refinement

Why this matters:

- multiple tmux clients may be attached at once
- the click action should not unexpectedly move other clients
- the user should always see the pane that actually handled the open request

## Wrapped-Line Ambiguity Rule

Wrapped-line reconstruction must fail closed.

Deterministic rule:

1. Extract the raw path-like fragment nearest the click from the unjoined row
2. Reconstruct candidate logical lines from the joined view
3. Tokenize each candidate logical line
4. Keep only tokens that contain the raw fragment
5. Normalize survivors to their final absolute target form
6. Deduplicate normalized survivors
7. If exactly one unique normalized target survives, accept it
8. Otherwise, treat the click as ambiguous and show a 5-second tmux status message

Examples of ambiguity:

- the same fragment appears in multiple joined logical lines
- multiple tokens on the same logical line contain the raw fragment and normalize to different targets
- wrapping destroys enough context that the raw fragment is too short to identify a unique token

## Error Handling UX

We should not fail silently in v1.

If no active Neovim instance can be found for the current tmux session:

- show a tmux popup
- explain that no active Neovim sessions were found
- include the current tmux session id in the message
- target the popup to the initiating tmux client only

If the clicked token is not recognized as a path at all:

- do not show a popup
- show a short message in the tmux status line
- keep the message visible for 5 seconds
- target the message to the initiating tmux client only

Example:

- `send_to_nvim: no file path detected at click location`

If the clicked token resolves to a path string but that path does not exist on disk:

- do not show a popup
- show a short message in the tmux status line
- keep the message visible for 5 seconds
- target the message to the initiating tmux client only

Example:

- `send_to_nvim: file not found: <resolved-path>`

If the clicked token has a malformed suffix, for example `file.rs:12:` or `file.rs:abc`:

- do not show a popup
- show a short message in the tmux status line
- keep the message visible for 5 seconds
- target the message to the initiating tmux client only

Example:

- `send_to_nvim: invalid file target suffix: <raw-token>`

The minimum supported grammar is:

- `path`
- `path:line`
- `path:line:col`

Anything else should be treated as invalid input and reported via the tmux status line.

Research note:

- mainstream terminal/editor integrations generally only activate recognized link formats
- valid file links usually open directly
- nonexistent file paths are typically not treated as file links at all
- low-confidence matches usually fall back to lightweight handling such as no-op, search, or a chooser
- interactive modals for malformed file suffixes do not appear to be common terminal behavior

Because of that, malformed suffixes should use the same lightweight status-line behavior as other low-confidence click misses.

## Why This Version Is Better Than `send-keys`

`send-keys` to another pane is easy but fragile:

- it depends on the target pane being in normal mode
- it can interact badly with pending commands or prompts
- file names with spaces are annoying to escape safely

The Neovim server approach is better because it talks directly to Neovim instead of pretending to type into it.

## Known Risks And Constraints

- Modifier-click support depends on the terminal, but this design assumes Ghostty is already forwarding `Ctrl-Click` correctly.
- This only works for literal visible file paths, not arbitrary UI widgets.
- The token matcher will need tuning once tested on real Codex and Claude output.
- Wrapped lines may complicate row/column mapping in some panes, so the helper should use `capture-pane -J` plus raw-row anchoring and fail closed when reconstruction is ambiguous.
- The registry writer and registry reader need to agree on format, liveness checks, and cleanup rules.

## Future Configuration Options

1. Opening behavior:
   - decided for v1: `:tab drop`
   - future option: `:drop`
   - future option: `:vsplit`

## Lessons From `tmux-fzf-open-files-nvim`

Reference:

- <https://github.com/Peter-McKinney/tmux-fzf-open-files-nvim>

What it appears to do well:

- It separates capture modes cleanly:
  - visible content in the current pane
  - full history of the current pane
  - full history across panes in the current window
- It treats file extraction as a reusable utility instead of hardwiring it to one tmux binding.
- It prefers an existing Neovim instance in the current window.
- It has a fallback path when no Neovim pane exists.
- It supports `path:line:col` inputs and multi-file selection via `fzf`.
- It has automated shell tests, which is a strong signal that the parsing logic was hard enough to warrant regression coverage.

What we should borrow:

1. Separate extraction from action.
   The click-driven helper should not own all parsing logic inline. We should factor path extraction into a standalone utility that can be tested independently and reused later.

2. Prefer same-window Neovim first.
   We are replacing this with a stronger rule: choose the most recently active Neovim instance within the current tmux session.

3. Keep a fallback when no editor exists.
   Their plugin creates a new pane when no Neovim instance is found. Our design should not do that in v1. It should show a popup explaining that no active Neovim instance was found.

4. Treat parsing as a first-class problem.
   Their project emphasizes parsing terminal output with shell tools and backs it with tests. That is a useful warning: extraction quality will determine whether this feature feels reliable or annoying.

What we should not copy directly:

1. `fzf` as the primary interaction.
   Their workflow is picker-first. Ours is click-first. We do not want a search or picker step in the normal path.

2. Opening by selecting from all matches on the line.
   Their model scans output and lets the user choose. Our click model should prefer the token nearest the click location with no extra picker in the common path.

3. Implicit "new tab" behavior by default.
   The plugin opens selections as new tabs. For our workflow, v1 is intentionally choosing `:tab drop`, but it should remain a conscious policy choice rather than an accidental default inherited from another tool.

Implementation adjustments to our current plan:

1. Add a reusable extraction utility.
   Proposed file:
   - `~/.dev_setup/tmux/send_to_nvim/extract_paths.sh`

   Responsibilities:
   - accept text on stdin
   - emit normalized `path[:line[:col]]` candidates
   - support selecting the best match near a click column
   - treat `path:line` as a first-class format, not an optional afterthought

2. Keep the click helper narrow.
   Proposed file:
   - `~/.dev_setup/tmux/send_to_nvim/open_clicked_path.sh`

   Responsibilities:
   - collect pane text and click metadata
   - call extraction utility
   - resolve target Neovim through the session registry
   - send remote open command

3. Add tests early.
   We should add small shell tests for:
   - `path`
   - `path:line`
   - `path:line:col`
   - relative path resolution
   - multiple paths on one line
   - paths adjacent to punctuation
   - wrapped/truncated-looking terminal text cases where feasible

4. Add a dedicated Neovim liveness probe helper.
   Proposed file:
   - `~/.dev_setup/tmux/send_to_nvim/probe_nvim_server.sh`

   Responsibilities:
   - run `nvim --server "$server" --remote-expr '1'`
   - bound execution with the portable timeout loop described above
   - return success only for a timely successful response
   - return failure for timeout or non-zero exit

5. Add registry writer helpers.
   Proposed files:
   - `~/.dev_setup/tmux/send_to_nvim/register_nvim_instance.sh`
   - `~/.dev_setup/tmux/send_to_nvim/unregister_nvim_instance.sh`

   Responsibilities:
   - query tmux for session and window metadata from `TMUX_PANE`
   - write or remove registry entries under `~/.tmux/tmp/sessions/<tmux-session-id>/`
   - persist `pane_id`, `window_id`, `server`, `cwd`, `nvim_pid`, and `last_active_epoch`
   - use atomic writes so readers never observe partial registry state

6. Add client-scoped feedback helpers or helper routines.
   Responsibilities:
   - show tmux popup messages only to the initiating client
   - show 5-second tmux status-line messages only to the initiating client
   - keep popup/status formatting consistent across all failure paths

Current design recommendation after reviewing the plugin:

- Keep the click-to-open design
- Factor parsing into a separate utility
- Choose the most recently active Neovim instance for the current tmux session
- Use Neovim remote server integration instead of `send-keys`
- Treat `path:line` as the minimum useful target format

## Suggested First Milestone

Implement the narrowest possible version first:

- `Ctrl-Click`
- open only existing files
- choose the most recently active live Neovim instance in the current tmux session
- use `:tab drop`
- support `path`, `path:line`, and `path:line:col`
- show a tmux popup for missing editor targets
- show 5-second tmux status messages for malformed suffixes and other low-confidence click failures

After that, refine token extraction and target-pane selection based on real usage.
