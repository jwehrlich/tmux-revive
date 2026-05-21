# tmux send_to_nvim

`Ctrl-Click` a visible `path[:line[:col]]` in a tmux pane and open it in the most recently active Neovim pane for the same tmux session.

## What It Does

- tmux captures the click location from the source pane
- the helper extracts the nearest file-like token
- relative paths are resolved against the source pane cwd and repo root
- the target Neovim instance is chosen from the tmux-session registry
- the file is opened in Neovim with `:tab drop`
- tmux reveals the target pane if needed

## Files

- [`plan.md`](/home/jwehrlich/.dev_setup/tmux/send_to_nvim/plan.md): design notes and implementation plan
- [`open_clicked_path.sh`](/home/jwehrlich/.dev_setup/tmux/send_to_nvim/open_clicked_path.sh): tmux click handler
- [`extract_paths.sh`](/home/jwehrlich/.dev_setup/tmux/send_to_nvim/extract_paths.sh): path-token extraction helper
- [`probe_nvim_server.sh`](/home/jwehrlich/.dev_setup/tmux/send_to_nvim/probe_nvim_server.sh): bounded Neovim liveness probe
- [`register_nvim_instance.sh`](/home/jwehrlich/.dev_setup/tmux/send_to_nvim/register_nvim_instance.sh): write registry entry for a live Neovim pane
- [`unregister_nvim_instance.sh`](/home/jwehrlich/.dev_setup/tmux/send_to_nvim/unregister_nvim_instance.sh): remove registry entry on exit
- [`core/send_to_nvim.lua`](/home/jwehrlich/.dev_setup/nvim/lua/core/send_to_nvim.lua): Neovim registration and remote-open handler

## Runtime Requirements

- tmux with mouse support enabled
- Ghostty forwarding `Ctrl-Click` to tmux
- Neovim started normally as `nvim`
- `jq`, `perl`, `git`, `tmux`, and `nvim` available in `PATH`

## Usage

1. Reload tmux with `prefix + r`
2. Start or restart the Neovim pane you want to target
3. In another tmux pane, `Ctrl-Click` a visible file target such as:
   - `README.md`
   - `frontend/package.json`
   - `backend/app.py:42`
   - `/abs/path/file.rs:10:3`

## How Target Selection Works

- registry state is stored under `~/.tmux/tmp/sessions/<tmux-session-id>/`
- each live Neovim UI instance writes one registry file
- candidates are sorted by `last_active_epoch`
- the first candidate with a live tmux pane and a live Neovim server wins
- if the chosen pane is not already active for the initiating tmux client, tmux switches that client to the target pane

## Path Rules

- only absolute paths are sent to Neovim
- relative paths are resolved on the tmux side before dispatch
- resolution order is:
  - absolute path
  - `~/...`
  - source pane cwd
  - source repo root
  - source repo root with leading repo-name stripped

## Failure Modes

- no file-like token at click location: tmux status message
- malformed suffix like `file.rs:abc`: tmux status message
- resolved path does not exist: tmux status message
- no active Neovim target for the tmux session: tmux popup

## Debugging

Check registry entries:

```sh
find ~/.tmux/tmp/sessions -maxdepth 3 -type f -name '*.json' -print -exec jq . {} \;
```

Check whether the registered Neovim server responds:

```sh
nvim --server /path/to/socket --remote-expr '1'
```

Check tmux panes and pane cwd values:

```sh
tmux list-panes -a -F '#{pane_id}\t#{pane_current_command}\t#{pane_current_path}\t#{session_id}\t#{window_id}'
```

## Current Caveats

- bare filename matching is intentionally permissive right now and may still need tuning
- click extraction on wrapped terminal lines is best-effort
- Neovim post-open ftplugin/autocmd errors can still affect user experience even when the file opens successfully
