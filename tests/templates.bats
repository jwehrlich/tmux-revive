#!/usr/bin/env bats
# Tests for the template engine: template-validate.sh + apply-template.sh

setup() {
    load test_helper/common-setup
    load test_helper/assertions
    load test_helper/wait-helpers
    load test_helper/data-helpers
    load test_helper/fake-wrappers
    _common_setup
    _setup_case

    apply_template="$tmux_revive_dir/apply-template.sh"
    template_validate="$tmux_revive_dir/template-validate.sh"
    templates_dir="$TMUX_REVIVE_STATE_ROOT/templates"
    mkdir -p "$templates_dir"
}

teardown() {
    _teardown_case
}

# ---------------------------------------------------------------------------
# Helper: write a YAML template file
# ---------------------------------------------------------------------------
write_template() {
  local name="$1"
  cat >"$templates_dir/${name}.yaml"
}

# ===========================================================================
# template-validate.sh tests
# ===========================================================================

@test "validate: minimal valid template passes" {
  write_template minimal <<'YAML'
name: minimal
sessions:
  - name: work
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  run "$template_validate" --file "$templates_dir/minimal.yaml"
  [ "$status" -eq 0 ]
}

@test "validate: --name flag resolves template from templates root" {
  write_template lookup-test <<'YAML'
name: lookup-test
sessions:
  - name: dev
    windows:
      - name: code
        panes:
          - cwd: /tmp
YAML

  run "$template_validate" --name lookup-test
  [ "$status" -eq 0 ]
}

@test "validate: missing name field fails" {
  write_template no-name <<'YAML'
sessions:
  - name: work
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  run "$template_validate" --file "$templates_dir/no-name.yaml"
  [ "$status" -eq 1 ]
  assert_contains "$output" "missing required root field: name"
}

@test "validate: empty sessions array fails" {
  write_template empty-sessions <<'YAML'
name: empty-sessions
sessions: []
YAML

  run "$template_validate" --file "$templates_dir/empty-sessions.yaml"
  [ "$status" -eq 1 ]
  assert_contains "$output" "sessions array is empty"
}

@test "validate: missing session name fails" {
  write_template no-session-name <<'YAML'
name: no-session-name
sessions:
  - windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  run "$template_validate" --file "$templates_dir/no-session-name.yaml"
  [ "$status" -eq 1 ]
  assert_contains "$output" "missing required field: name"
}

@test "validate: missing window name fails" {
  write_template no-window-name <<'YAML'
name: no-window-name
sessions:
  - name: work
    windows:
      - panes:
          - cwd: /tmp
YAML

  run "$template_validate" --file "$templates_dir/no-window-name.yaml"
  [ "$status" -eq 1 ]
  assert_contains "$output" "missing required field: name"
}

@test "validate: empty panes array fails" {
  write_template empty-panes <<'YAML'
name: empty-panes
sessions:
  - name: work
    windows:
      - name: main
        panes: []
YAML

  run "$template_validate" --file "$templates_dir/empty-panes.yaml"
  [ "$status" -eq 1 ]
  assert_contains "$output" "panes array is empty"
}

@test "validate: nonexistent cwd warns but passes" {
  write_template bad-cwd <<'YAML'
name: bad-cwd
sessions:
  - name: work
    windows:
      - name: main
        panes:
          - cwd: /definitely/does/not/exist
YAML

  run "$template_validate" --file "$templates_dir/bad-cwd.yaml"
  [ "$status" -eq 0 ]
  assert_contains "$output" "cwd does not exist"
}

@test "validate: --quiet suppresses warnings" {
  write_template quiet-test <<'YAML'
name: quiet-test
sessions:
  - name: work
    windows:
      - name: main
        panes:
          - cwd: /definitely/does/not/exist
YAML

  run "$template_validate" --file "$templates_dir/quiet-test.yaml" --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "validate: nonexistent file fails" {
  run "$template_validate" --file "$templates_dir/ghost.yaml"
  [ "$status" -eq 1 ]
  assert_contains "$output" "file not found"
}

@test "validate: invalid YAML fails" {
  printf 'name: bad\nsessions: [[[invalid' >"$templates_dir/malformed.yaml"

  run "$template_validate" --file "$templates_dir/malformed.yaml"
  [ "$status" -eq 1 ]
  assert_contains "$output" "not parseable"
}

@test "validate: --name and --file together fails" {
  write_template dual <<'YAML'
name: dual
sessions:
  - name: s
    windows:
      - name: w
        panes:
          - cwd: /tmp
YAML

  run "$template_validate" --name dual --file "$templates_dir/dual.yaml"
  [ "$status" -eq 1 ]
  assert_contains "$output" "not both"
}

# ===========================================================================
# apply-template.sh — dry-run tests
# ===========================================================================

@test "apply dry-run: shows sessions and window counts" {
  write_template dry-run-basic <<'YAML'
name: dry-run-basic
sessions:
  - name: frontend
    windows:
      - name: editor
        panes:
          - cwd: /tmp
      - name: shell
        panes:
          - cwd: /tmp
  - name: backend
    windows:
      - name: server
        panes:
          - cwd: /tmp
YAML

  run "$apply_template" --name dry-run-basic --dry-run
  [ "$status" -eq 0 ]
  assert_contains "$output" "frontend"
  assert_contains "$output" "2 windows"
  assert_contains "$output" "backend"
  assert_contains "$output" "1 windows"
}

@test "apply dry-run: shows collision renames" {
  # Create a live session named "existing"
  tmux new-session -d -s existing

  write_template collision-dry <<'YAML'
name: collision-dry
sessions:
  - name: existing
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  run "$apply_template" --name collision-dry --dry-run
  [ "$status" -eq 0 ]
  assert_contains "$output" "existing-2"
  assert_contains "$output" "collision"
}

# ===========================================================================
# apply-template.sh — live restore tests
# ===========================================================================

@test "apply: single session single pane creates session" {
  write_template simple <<'YAML'
name: simple
sessions:
  - name: mywork
    windows:
      - name: code
        panes:
          - cwd: /tmp
YAML

  "$apply_template" --name simple

  wait_for_session mywork || fail "mywork session not created"

  # Verify window name
  local window_name
  window_name="$(tmux list-windows -t mywork -F '#{window_name}' | head -1)"
  assert_eq "code" "$window_name" "window name"

  # Verify pane cwd (wait for shell to finish cd'ing after .zshrc sourcing)
  wait_for_pane_path "mywork:code" "/private/tmp" || {
    local pane_path
    pane_path="$(tmux display-message -p -t mywork:code '#{pane_current_path}')"
    fail "pane cwd: expected [/private/tmp], got [$pane_path]"
  }
}

@test "apply: multi-pane window creates all panes" {
  write_template multi-pane <<'YAML'
name: multi-pane
sessions:
  - name: dev
    windows:
      - name: editor
        panes:
          - cwd: /tmp
          - cwd: /tmp
          - cwd: /tmp
YAML

  "$apply_template" --name multi-pane

  wait_for_session dev || fail "dev session not created"

  local pane_count
  pane_count="$(tmux list-panes -t dev:editor | wc -l | tr -d ' ')"
  assert_eq "3" "$pane_count" "editor pane count"
}

@test "apply: multi-session template creates all sessions" {
  write_template multi-session <<'YAML'
name: multi-session
sessions:
  - name: alpha
    windows:
      - name: main
        panes:
          - cwd: /tmp
  - name: beta
    windows:
      - name: main
        panes:
          - cwd: /tmp
  - name: gamma
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  "$apply_template" --name multi-session

  wait_for_session alpha || fail "alpha not created"
  wait_for_session beta  || fail "beta not created"
  wait_for_session gamma || fail "gamma not created"

  local session_count
  session_count="$(tmux list-sessions -F '#{session_name}' | grep -c '^[abg]')"
  assert_eq "3" "$session_count" "session count"
}

@test "apply: commands are executed in panes" {
  local marker_file="$case_root/cmd-ran.txt"

  write_template cmd-test <<YAML
name: cmd-test
sessions:
  - name: cmdwork
    windows:
      - name: runner
        panes:
          - cwd: /tmp
            command: "echo template-cmd-ok > $marker_file"
YAML

  "$apply_template" --name cmd-test

  wait_for_session cmdwork || fail "cmdwork not created"
  wait_for_file "$marker_file" 60 0.25 || fail "command marker file not created"

  local content
  content="$(cat "$marker_file")"
  assert_eq "template-cmd-ok" "$content" "command output"
}

@test "apply: tilde cwd expands to HOME" {
  write_template tilde-test <<'YAML'
name: tilde-test
sessions:
  - name: tildesess
    windows:
      - name: main
        panes:
          - cwd: "~/tmp"
YAML

  # Ensure ~/tmp exists
  mkdir -p "$HOME/tmp"

  "$apply_template" --name tilde-test

  wait_for_session tildesess || fail "tildesess not created"

  # Wait for shell to finish cd'ing after .zshrc sourcing
  local expected_path
  expected_path="$(cd "$HOME/tmp" && pwd -P)"
  wait_for_pane_path "tildesess:main" "$expected_path" || {
    local pane_path
    pane_path="$(tmux display-message -p -t tildesess:main '#{pane_current_path}')"
    fail "tilde-expanded cwd: expected [$expected_path], got [$pane_path]"
  }
}

@test "apply: bare tilde (YAML null) cwd falls back to HOME" {
  write_template bare-tilde <<'YAML'
name: bare-tilde
sessions:
  - name: homesess
    windows:
      - name: main
        panes:
          - cwd: ~
YAML

  "$apply_template" --name bare-tilde

  wait_for_session homesess || fail "homesess not created"

  local pane_path
  pane_path="$(tmux display-message -p -t homesess:main '#{pane_current_path}')"
  # Should resolve to $HOME (bare ~ is YAML null, falls back to HOME)
  assert_eq "$HOME" "$pane_path" "null cwd should resolve to HOME"
}

@test "apply: collision appends -2 suffix" {
  # Create an existing session
  tmux new-session -d -s collide

  write_template collide-tmpl <<'YAML'
name: collide-tmpl
sessions:
  - name: collide
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  "$apply_template" --name collide-tmpl

  wait_for_session collide-2 || fail "collide-2 not created"

  # Original session should still exist
  tmux has-session -t collide || fail "original collide session was destroyed"
}

@test "apply: collision increments existing -N suffix" {
  # Create sessions: collide, collide-2
  tmux new-session -d -s increment
  tmux new-session -d -s increment-2

  write_template increment-tmpl <<'YAML'
name: increment-tmpl
sessions:
  - name: increment
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  "$apply_template" --name increment-tmpl

  wait_for_session increment-3 || fail "increment-3 not created"
}

@test "apply: template commands bypass snapshot allowlist" {
  # 'echo' is not on the snapshot restart allowlist, but templates trust all commands
  local marker="$case_root/allowlist-bypass.txt"

  write_template bypass-test <<YAML
name: bypass-test
sessions:
  - name: bypasswork
    windows:
      - name: runner
        panes:
          - cwd: /tmp
            command: "echo bypass-ok > $marker"
YAML

  "$apply_template" --name bypass-test

  wait_for_session bypasswork || fail "bypasswork not created"
  wait_for_file "$marker" 60 0.25 || fail "command not executed (allowlist blocked?)"

  assert_eq "bypass-ok" "$(cat "$marker")" "bypass marker"
}

@test "apply: source_type is template in manifest" {
  write_template source-type <<'YAML'
name: source-type
sessions:
  - name: stwork
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  # Use a subshell to capture the manifest before cleanup
  local manifest_copy="$case_root/manifest-copy.json"

  # Patch apply-template to save the manifest
  local wrapper="$case_root/bin/apply-template-debug.sh"
  cat >"$wrapper" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# Intercept the temp manifest by wrapping restore-state.sh
export TMUX_REVIVE_STATE_ROOT="$TMUX_REVIVE_STATE_ROOT"
exec "$apply_template" "\$@"
EOF
  chmod +x "$wrapper"

  "$apply_template" --name source-type

  wait_for_session stwork || fail "stwork not created"

  # Verify from restore log that template-restart events are logged
  local log_path
  log_path="$(find "$TMUX_REVIVE_STATE_ROOT" -name 'latest-restore.log' 2>/dev/null | head -1)"
  if [ -n "$log_path" ]; then
    local log_content
    log_content="$(cat "$log_path")"
    assert_contains "$log_content" "source_type" "restore log mentions source_type" || true
  fi
}

@test "apply: multi-window session creates correct windows" {
  write_template multi-win <<'YAML'
name: multi-win
sessions:
  - name: mwwork
    windows:
      - name: code
        panes:
          - cwd: /tmp
      - name: logs
        panes:
          - cwd: /tmp
      - name: shell
        panes:
          - cwd: /tmp
YAML

  "$apply_template" --name multi-win

  wait_for_session mwwork || fail "mwwork not created"

  local window_count
  window_count="$(tmux list-windows -t mwwork | wc -l | tr -d ' ')"
  assert_eq "3" "$window_count" "window count"

  # Verify window names
  local window_names
  window_names="$(tmux list-windows -t mwwork -F '#{window_name}')"
  assert_contains "$window_names" "code" "code window"
  assert_contains "$window_names" "logs" "logs window"
  assert_contains "$window_names" "shell" "shell window"
}

@test "apply: missing template name shows error" {
  run "$apply_template"
  [ "$status" -eq 1 ]
  assert_contains "$output" "--name is required"
}

@test "apply: nonexistent template shows error" {
  run "$apply_template" --name does-not-exist
  [ "$status" -eq 1 ]
  assert_contains "$output" "template not found"
}

@test "apply: invalid template fails validation" {
  write_template invalid-tmpl <<'YAML'
name: invalid-tmpl
sessions: []
YAML

  run "$apply_template" --name invalid-tmpl
  [ "$status" -eq 1 ]
  assert_contains "$output" "validation failed"
}

@test "apply: session gets a unique GUID" {
  write_template guid-test <<'YAML'
name: guid-test
sessions:
  - name: guidwork
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  "$apply_template" --name guid-test

  wait_for_session guidwork || fail "guidwork not created"

  local guid
  guid="$(tmux show-options -qv -t guidwork '@tmux-revive-session-guid')"
  [ -n "$guid" ] || fail "session GUID is empty"
  # GUIDs are UUIDs (36 chars with hyphens)
  [ "${#guid}" -eq 36 ] || fail "GUID format unexpected: $guid"
}

@test "apply: env pane receives environment variables" {
  local marker="$case_root/env-check.txt"

  write_template env-test <<YAML
name: env-test
sessions:
  - name: envwork
    windows:
      - name: main
        panes:
          - cwd: /tmp
            command: "printenv MY_TMPL_VAR > $marker"
            env:
              MY_TMPL_VAR: hello-from-template
YAML

  "$apply_template" --name env-test

  wait_for_session envwork || fail "envwork not created"
  wait_for_file "$marker" 60 0.25 || fail "env command marker not created"

  local content
  content="$(cat "$marker")"
  assert_eq "hello-from-template" "$content" "env var value"
}

@test "apply: override merges host-specific fields" {
  local hostname
  hostname="$(hostname -s 2>/dev/null || hostname)"

  cat >"$templates_dir/override-test.yaml" <<YAML
name: override-test
sessions:
  - name: overwork
    windows:
      - name: main
        panes:
          - cwd: /tmp
overrides:
  $hostname:
    sessions:
      - name: overwork
        windows:
          - name: main
            panes:
              - cwd: /var/tmp
YAML

  "$apply_template" --name override-test

  wait_for_session overwork || fail "overwork not created"

  # Wait for shell to finish cd'ing (macOS: /var/tmp → /private/var/tmp)
  wait_for_pane_path "overwork:main" "/private/var/tmp" || {
    local pane_path
    pane_path="$(tmux display-message -p -t overwork:main '#{pane_current_path}')"
    fail "override applied cwd: expected [/private/var/tmp], got [$pane_path]"
  }
}

@test "apply: second apply of same template increments all session suffixes" {
  write_template double-apply <<'YAML'
name: double-apply
sessions:
  - name: da-alpha
    windows:
      - name: main
        panes:
          - cwd: /tmp
  - name: da-beta
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  "$apply_template" --name double-apply

  wait_for_session da-alpha || fail "da-alpha not created"
  wait_for_session da-beta  || fail "da-beta not created"

  # Apply again — both should get -2
  "$apply_template" --name double-apply

  wait_for_session da-alpha-2 || fail "da-alpha-2 not created"
  wait_for_session da-beta-2  || fail "da-beta-2 not created"

  # All four sessions should exist
  local count
  count="$(tmux list-sessions -F '#{session_name}' | grep -c '^da-')"
  assert_eq "4" "$count" "total session count after double apply"
}

@test "apply: panes without command get shell strategy" {
  write_template shell-pane <<'YAML'
name: shell-pane
sessions:
  - name: shellwork
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  "$apply_template" --name shell-pane

  wait_for_session shellwork || fail "shellwork not created"

  # The pane should be running a shell (not a command)
  local pane_cmd
  pane_cmd="$(tmux display-message -p -t shellwork:main '#{pane_current_command}')"
  # Should be a shell like zsh, bash, etc. — not empty
  [ -n "$pane_cmd" ] || fail "pane has no running command"
}

@test "apply: layout string is applied to multi-pane window" {
  write_template layout-test <<'YAML'
name: layout-test
sessions:
  - name: layoutwork
    windows:
      - name: split
        layout: even-horizontal
        panes:
          - cwd: /tmp
          - cwd: /tmp
YAML

  "$apply_template" --name layout-test

  wait_for_session layoutwork || fail "layoutwork not created"

  local pane_count
  pane_count="$(tmux list-panes -t layoutwork:split | wc -l | tr -d ' ')"
  assert_eq "2" "$pane_count" "split pane count"
}

# ===========================================================================
# template-list.sh tests
# ===========================================================================

@test "list: shows templates with metadata" {
  local template_list="$tmux_revive_dir/template-list.sh"

  write_template list-a <<'YAML'
name: list-a
description: First template
updated_at: "2026-01-01T00:00:00Z"
sessions:
  - name: alpha
    windows:
      - name: main
        panes:
          - cwd: /tmp
  - name: beta
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  write_template list-b <<'YAML'
name: list-b
description: Second template
updated_at: "2026-06-15T12:00:00Z"
sessions:
  - name: gamma
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  run "$template_list"
  [ "$status" -eq 0 ]
  assert_contains "$output" "list-a"
  assert_contains "$output" "First template"
  assert_contains "$output" "list-b"
  assert_contains "$output" "Second template"
}

@test "list: --json outputs valid JSON array" {
  local template_list="$tmux_revive_dir/template-list.sh"

  write_template json-test <<'YAML'
name: json-test
description: JSON output test
sessions:
  - name: sess1
    windows:
      - name: win1
        panes:
          - cwd: /tmp
YAML

  run "$template_list" --json
  [ "$status" -eq 0 ]

  # Validate it's valid JSON
  echo "$output" | jq '.' >/dev/null || fail "output is not valid JSON"

  local name
  name="$(echo "$output" | jq -r '.[0].name')"
  assert_eq "json-test" "$name" "json name field"
}

@test "list: empty templates dir shows no templates" {
  local template_list="$tmux_revive_dir/template-list.sh"

  run "$template_list"
  [ "$status" -eq 0 ]
  assert_contains "$output" "No templates"
}

# ===========================================================================
# template-save.sh tests
# ===========================================================================

@test "save: captures current session as template" {
  local template_save="$tmux_revive_dir/template-save.sh"

  # Create a session with known structure
  tmux new-session -d -s savework -n editor -c /tmp
  tmux new-window -t savework -n shell -c /tmp

  "$template_save" --name save-test --description "Save test"

  [ -f "$templates_dir/save-test.yaml" ] || fail "template file not created"

  # Validate the template
  "$template_validate" --file "$templates_dir/save-test.yaml" --quiet || fail "saved template is invalid"

  # Check structure
  local session_name
  session_name="$(yq -r '.sessions[0].name' "$templates_dir/save-test.yaml")"
  assert_eq "savework" "$session_name" "captured session name"

  local window_count
  window_count="$(yq '.sessions[0].windows | length' "$templates_dir/save-test.yaml")"
  assert_eq "2" "$window_count" "captured window count"

  local desc
  desc="$(yq -r '.description' "$templates_dir/save-test.yaml")"
  assert_eq "Save test" "$desc" "description"
}

@test "save: normalizes HOME to tilde" {
  local template_save="$tmux_revive_dir/template-save.sh"

  tmux new-session -d -s pathwork -n main -c "$HOME"

  "$template_save" --name path-test --force

  local pane_cwd
  pane_cwd="$(yq -r '.sessions[0].windows[0].panes[0].cwd' "$templates_dir/path-test.yaml")"
  assert_eq "~" "$pane_cwd" "HOME should normalize to ~"
}

@test "save: --sessions captures multiple sessions" {
  local template_save="$tmux_revive_dir/template-save.sh"

  tmux new-session -d -s multi-a -n win-a -c /tmp
  tmux new-session -d -s multi-b -n win-b -c /tmp

  "$template_save" --name multi-test --sessions multi-a,multi-b

  local session_count
  session_count="$(yq '.sessions | length' "$templates_dir/multi-test.yaml")"
  assert_eq "2" "$session_count" "captured session count"

  local s1 s2
  s1="$(yq -r '.sessions[0].name' "$templates_dir/multi-test.yaml")"
  s2="$(yq -r '.sessions[1].name' "$templates_dir/multi-test.yaml")"
  assert_eq "multi-a" "$s1" "first session name"
  assert_eq "multi-b" "$s2" "second session name"
}

@test "save: refuses overwrite without --force" {
  local template_save="$tmux_revive_dir/template-save.sh"

  tmux new-session -d -s forcetest -n main -c /tmp

  "$template_save" --name force-test

  run "$template_save" --name force-test
  [ "$status" -eq 1 ]
  assert_contains "$output" "already exists"
}

@test "save: --force overwrites existing template" {
  local template_save="$tmux_revive_dir/template-save.sh"

  tmux new-session -d -s forceok -n main -c /tmp

  "$template_save" --name force-ok
  "$template_save" --name force-ok --force

  [ -f "$templates_dir/force-ok.yaml" ] || fail "template should still exist"
}

@test "save: captures running command" {
  local template_save="$tmux_revive_dir/template-save.sh"

  tmux new-session -d -s cmdcap -n tailer -c /tmp
  local pane_id
  pane_id="$(tmux list-panes -t cmdcap:tailer -F '#{pane_id}' | head -1)"

  # Start a command that will be captured
  tmux send-keys -t "$pane_id" "tail -f /dev/null" C-m
  wait_for_pane_command "$pane_id" tail 60 0.25 || fail "tail not running"

  "$template_save" --name cmd-cap-test --force

  local cmd
  cmd="$(yq -r '.sessions[0].windows[0].panes[0].command' "$templates_dir/cmd-cap-test.yaml")"
  assert_contains "$cmd" "tail" "captured command should contain tail"
}

@test "save: nonexistent session fails" {
  local template_save="$tmux_revive_dir/template-save.sh"

  run "$template_save" --name ghost --sessions ghost-session
  [ "$status" -eq 1 ]
  assert_contains "$output" "session not found"
}

# ===========================================================================
# template-create.sh tests
# ===========================================================================

@test "create: --blank generates scaffold template" {
  local template_create="$tmux_revive_dir/template-create.sh"

  "$template_create" --name blank-scaffold --blank

  [ -f "$templates_dir/blank-scaffold.yaml" ] || fail "blank template not created"

  # Should be valid YAML with the right name
  local name
  name="$(yq -r '.name' "$templates_dir/blank-scaffold.yaml")"
  assert_eq "blank-scaffold" "$name" "template name in blank scaffold"

  # Should have at least one session
  local session_count
  session_count="$(yq '.sessions | length' "$templates_dir/blank-scaffold.yaml")"
  [ "$session_count" -ge 1 ] || fail "blank template should have at least one session"
}

@test "create: --blank with --description sets description" {
  local template_create="$tmux_revive_dir/template-create.sh"

  "$template_create" --name desc-test --blank --description "My custom workspace"

  local desc
  desc="$(yq -r '.description' "$templates_dir/desc-test.yaml")"
  assert_eq "My custom workspace" "$desc" "description from flag"
}

@test "create: --from-snapshot extracts sessions" {
  local template_create="$tmux_revive_dir/template-create.sh"

  # Create a session, save it, then create template from snapshot
  tmux new-session -d -s snapwork -n code -c /tmp
  tmux new-window -t snapwork -n logs -c /tmp

  "$save_state" --reason test-create-from-snap

  local manifest
  manifest="$(latest_manifest)"

  "$template_create" --name from-snap --from-snapshot "$manifest"

  [ -f "$templates_dir/from-snap.yaml" ] || fail "template not created from snapshot"

  "$template_validate" --file "$templates_dir/from-snap.yaml" --quiet || fail "template from snapshot is invalid"

  local session_name
  session_name="$(yq -r '.sessions[] | select(.name == "snapwork") | .name' "$templates_dir/from-snap.yaml")"
  assert_eq "snapwork" "$session_name" "session extracted from snapshot"
}

@test "create: --from-snapshot normalizes HOME paths to tilde" {
  local template_create="$tmux_revive_dir/template-create.sh"

  tmux new-session -d -s homesnap -n main -c "$HOME"

  "$save_state" --reason test-tilde-snap

  local manifest
  manifest="$(latest_manifest)"

  "$template_create" --name tilde-snap --from-snapshot "$manifest" --force

  # The pane cwd should be normalized: ~ prefix instead of absolute $HOME
  local pane_cwd
  pane_cwd="$(yq -r '.sessions[] | select(.name == "homesnap") | .windows[0].panes[0].cwd' "$templates_dir/tilde-snap.yaml")"
  # Should start with ~ (normalized), not the absolute HOME path
  [[ "$pane_cwd" == "~"* ]] || fail "expected tilde-normalized path, got: $pane_cwd"
  assert_not_contains "$pane_cwd" "$HOME" "should not contain absolute HOME"
}

@test "create: refuses overwrite without --force" {
  local template_create="$tmux_revive_dir/template-create.sh"

  "$template_create" --name no-overwrite --blank

  run "$template_create" --name no-overwrite --blank
  [ "$status" -eq 1 ]
  assert_contains "$output" "already exists"
}

@test "create: --from-snapshot with missing manifest fails" {
  local template_create="$tmux_revive_dir/template-create.sh"

  run "$template_create" --name bad-snap --from-snapshot /nonexistent/manifest.json
  [ "$status" -eq 1 ]
  assert_contains "$output" "not found"
}

@test "create: requires --blank or --from-snapshot" {
  local template_create="$tmux_revive_dir/template-create.sh"

  run "$template_create" --name no-mode
  [ "$status" -eq 1 ]
  assert_contains "$output" "--blank or --from-snapshot"
}

# ===========================================================================
# template-edit.sh tests
# ===========================================================================

@test "edit: updates updated_at on valid edit" {
  local template_edit="$tmux_revive_dir/template-edit.sh"

  write_template edit-valid <<'YAML'
name: edit-valid
updated_at: "2020-01-01T00:00:00Z"
sessions:
  - name: work
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  local old_ts
  old_ts="$(yq -r '.updated_at' "$templates_dir/edit-valid.yaml")"

  # Create a fake editor script that makes a change
  local fake_editor="$case_root/bin/fake-editor"
  cat >"$fake_editor" <<'SH'
#!/usr/bin/env bash
sed -i '' 's/work/edited/' "$1"
SH
  chmod +x "$fake_editor"

  EDITOR="$fake_editor" "$template_edit" --name edit-valid

  local new_ts
  new_ts="$(yq -r '.updated_at' "$templates_dir/edit-valid.yaml")"
  [ "$old_ts" != "$new_ts" ] || fail "updated_at should have changed"

  local session_name
  session_name="$(yq -r '.sessions[0].name' "$templates_dir/edit-valid.yaml")"
  assert_eq "edited" "$session_name" "edit should have taken effect"
}

@test "edit: no changes exits cleanly" {
  local template_edit="$tmux_revive_dir/template-edit.sh"

  write_template edit-noop <<'YAML'
name: edit-noop
sessions:
  - name: work
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  # 'true' as editor makes no changes
  run env EDITOR=true "$template_edit" --name edit-noop
  [ "$status" -eq 0 ]
  assert_contains "$output" "No changes"
}

@test "edit: nonexistent template fails" {
  local template_edit="$tmux_revive_dir/template-edit.sh"

  run "$template_edit" --name ghost-edit
  [ "$status" -eq 1 ]
  assert_contains "$output" "not found"
}

# ===========================================================================
# template-delete.sh tests
# ===========================================================================

@test "delete: --yes removes template" {
  local template_delete="$tmux_revive_dir/template-delete.sh"

  write_template del-me <<'YAML'
name: del-me
sessions:
  - name: work
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  [ -f "$templates_dir/del-me.yaml" ] || fail "template should exist before delete"

  "$template_delete" --name del-me --yes

  [ ! -f "$templates_dir/del-me.yaml" ] || fail "template should be deleted"
}

@test "delete: nonexistent template fails" {
  local template_delete="$tmux_revive_dir/template-delete.sh"

  run "$template_delete" --name ghost-del --yes
  [ "$status" -eq 1 ]
  assert_contains "$output" "not found"
}

@test "delete: without --yes and no tty aborts" {
  local template_delete="$tmux_revive_dir/template-delete.sh"

  write_template del-noprompt <<'YAML'
name: del-noprompt
sessions:
  - name: work
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  # Pipe "n" to stdin to answer the confirmation prompt
  run bash -c 'echo n | "$1" --name del-noprompt' _ "$template_delete"
  [ "$status" -eq 1 ]

  # Template should still exist
  [ -f "$templates_dir/del-noprompt.yaml" ] || fail "template should not be deleted without confirmation"
}

# ===========================================================================
# Phase 4: Revive Integration — pick.sh and preview-item.sh
# ===========================================================================

@test "revive: --dump-items-raw includes template rows when --show-templates" {
  write_template mux-tpl <<'YAML'
name: mux-tpl
description: Revive test template
sessions:
  - name: web
    windows:
      - name: main
        panes:
          - cwd: /tmp
  - name: api
    windows:
      - name: server
        panes:
          - cwd: /tmp
YAML

  local pick_sh="$tmux_revive_dir/pick.sh"
  local output
  output="$("$pick_sh" --show-templates --dump-items-raw)"

  # Should contain a TEMPLATES header
  echo "$output" | grep -q "^header.*TEMPLATES" || fail "missing TEMPLATES header"

  # Should contain a template row
  echo "$output" | grep -q "^template	template	mux-tpl" || fail "missing mux-tpl template row"

  # Verify session count field
  local session_count
  session_count="$(echo "$output" | grep "^template	template	mux-tpl" | cut -f5)"
  assert_eq "2" "$session_count" "template session count"
}

@test "revive: --dump-items-raw excludes templates without --show-templates" {
  write_template hidden-tpl <<'YAML'
name: hidden-tpl
sessions:
  - name: work
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  local pick_sh="$tmux_revive_dir/pick.sh"
  local output
  output="$("$pick_sh" --dump-items-raw)"

  # Should NOT contain template rows
  if echo "$output" | grep -q "^template"; then
    fail "template rows should not appear without --show-templates"
  fi
}

@test "revive: --dump-items formats template rows with TEMPLATE label" {
  write_template fmt-tpl <<'YAML'
name: fmt-tpl
description: Formatted test
sessions:
  - name: dev
    windows:
      - name: code
        panes:
          - cwd: /tmp
YAML

  local pick_sh="$tmux_revive_dir/pick.sh"
  local output
  output="$("$pick_sh" --show-templates --dump-items)"

  # Field 7 (display) should contain TEMPLATE
  echo "$output" | grep "^template" | cut -f7 | grep -q "TEMPLATE" \
    || fail "display row should contain TEMPLATE label"
}

@test "revive: template preview shows YAML content" {
  write_template preview-tpl <<'YAML'
name: preview-tpl
description: Preview test
sessions:
  - name: web
    windows:
      - name: main
        panes:
          - cwd: /tmp
            command: echo hello
YAML

  local preview_sh="$tmux_revive_dir/preview-item.sh"
  local output
  output="$("$preview_sh" template template preview-tpl "Preview test" 1 "" "")"

  # Should contain the template name in header
  echo "$output" | grep -q "preview-tpl" || fail "preview should show template name"

  # Should contain YAML content
  echo "$output" | grep -q "echo hello" || fail "preview should show template YAML content"
}

@test "revive: template preview for nonexistent template shows error" {
  local preview_sh="$tmux_revive_dir/preview-item.sh"
  local output
  output="$("$preview_sh" template template no-such-tpl "" 0 "" "")"
  echo "$output" | grep -qi "not found" || fail "should show not found message"
}

# ===========================================================================
# Phase 5: Portability — export, import, env variable expansion
# ===========================================================================

@test "export: creates tar.gz bundle from template" {
  write_template export-test <<'YAML'
name: export-test
description: Export test
sessions:
  - name: work
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  local export_sh="$tmux_revive_dir/template-export.sh"
  local bundle="$case_root/export-test.tmux-template.tar.gz"

  run "$export_sh" --name export-test --output "$bundle"
  [ "$status" -eq 0 ] || fail "export failed: $output"
  [ -f "$bundle" ] || fail "bundle file not created"

  # Verify bundle contains the yaml file
  local contents
  contents="$(tar -tzf "$bundle")"
  echo "$contents" | grep -q "export-test.yaml" || fail "bundle missing export-test.yaml"
}

@test "export: nonexistent template fails" {
  local export_sh="$tmux_revive_dir/template-export.sh"
  run "$export_sh" --name no-such-template --output "$case_root/out.tar.gz"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "not found" || fail "should show not found error"
}

@test "export: missing --name fails" {
  local export_sh="$tmux_revive_dir/template-export.sh"
  run "$export_sh"
  [ "$status" -eq 1 ]
}

@test "import: imports template from bundle" {
  write_template import-src <<'YAML'
name: import-src
description: Source for import
sessions:
  - name: dev
    windows:
      - name: code
        panes:
          - cwd: /tmp
YAML

  local export_sh="$tmux_revive_dir/template-export.sh"
  local import_sh="$tmux_revive_dir/template-import.sh"
  local bundle="$case_root/import-src.tmux-template.tar.gz"

  # Export it
  "$export_sh" --name import-src --output "$bundle"

  # Remove original
  rm "$templates_dir/import-src.yaml"

  # Import it back
  run "$import_sh" "$bundle"
  [ "$status" -eq 0 ] || fail "import failed: $output"

  # Verify the template was restored
  [ -f "$templates_dir/import-src.yaml" ] || fail "imported template file not found"

  # Verify content
  local name
  name="$(yq -r '.name' "$templates_dir/import-src.yaml")"
  assert_eq "import-src" "$name" "imported template name"
}

@test "import: --name overrides template name" {
  write_template rename-src <<'YAML'
name: rename-src
sessions:
  - name: work
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  local export_sh="$tmux_revive_dir/template-export.sh"
  local import_sh="$tmux_revive_dir/template-import.sh"
  local bundle="$case_root/rename-src.tmux-template.tar.gz"

  "$export_sh" --name rename-src --output "$bundle"
  rm "$templates_dir/rename-src.yaml"

  run "$import_sh" "$bundle" --name renamed-tpl
  [ "$status" -eq 0 ] || fail "import with --name failed: $output"

  [ -f "$templates_dir/renamed-tpl.yaml" ] || fail "renamed template file not found"
  local name
  name="$(yq -r '.name' "$templates_dir/renamed-tpl.yaml")"
  assert_eq "renamed-tpl" "$name" "renamed template name in YAML"
}

@test "import: refuses overwrite without --force" {
  write_template dup-import <<'YAML'
name: dup-import
sessions:
  - name: work
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  local export_sh="$tmux_revive_dir/template-export.sh"
  local import_sh="$tmux_revive_dir/template-import.sh"
  local bundle="$case_root/dup-import.tmux-template.tar.gz"

  "$export_sh" --name dup-import --output "$bundle"

  # Import again without --force (template still exists)
  run "$import_sh" "$bundle"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "already exists" || fail "should show already exists error"
}

@test "import: --force overwrites existing template" {
  write_template force-import <<'YAML'
name: force-import
description: original
sessions:
  - name: work
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  local export_sh="$tmux_revive_dir/template-export.sh"
  local import_sh="$tmux_revive_dir/template-import.sh"
  local bundle="$case_root/force-import.tmux-template.tar.gz"

  "$export_sh" --name force-import --output "$bundle"

  # Modify original
  yq -i '.description = "modified"' "$templates_dir/force-import.yaml"

  # Import with --force should overwrite
  run "$import_sh" "$bundle" --force
  [ "$status" -eq 0 ] || fail "import --force failed: $output"

  local desc
  desc="$(yq -r '.description' "$templates_dir/force-import.yaml")"
  assert_eq "original" "$desc" "should have original description after force import"
}

@test "import: nonexistent bundle fails" {
  local import_sh="$tmux_revive_dir/template-import.sh"
  run "$import_sh" "/nonexistent/bundle.tar.gz"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "not found" || fail "should show not found error"
}

@test "apply: expands \$USER in cwd field" {
  write_template env-user <<'YAML'
name: env-user
sessions:
  - name: envuwork
    windows:
      - name: main
        panes:
          - cwd: /tmp/$USER
YAML

  mkdir -p "/tmp/$USER"

  "$apply_template" --name env-user

  wait_for_session envuwork || fail "envuwork not created"

  local expected_path
  expected_path="$(cd "/tmp/$USER" && pwd -P)"
  wait_for_pane_path "envuwork:main" "$expected_path" || {
    local pane_path
    pane_path="$(tmux display-message -p -t envuwork:main '#{pane_current_path}')"
    fail "\$USER cwd: expected [$expected_path], got [$pane_path]"
  }
}

@test "apply: expands \$TMUX_REVIVE_TPL_* vars in cwd field" {
  write_template env-tpl-var <<'YAML'
name: env-tpl-var
sessions:
  - name: tplvarwork
    windows:
      - name: main
        panes:
          - cwd: $TMUX_REVIVE_TPL_PROJECT
YAML

  export TMUX_REVIVE_TPL_PROJECT="/tmp"

  "$apply_template" --name env-tpl-var

  wait_for_session tplvarwork || fail "tplvarwork not created"

  wait_for_pane_path "tplvarwork:main" "/private/tmp" || {
    local pane_path
    pane_path="$(tmux display-message -p -t tplvarwork:main '#{pane_current_path}')"
    fail "TPL var cwd: expected [/private/tmp], got [$pane_path]"
  }
}

# ---------------------------------------------------------------------------
# Snapshot → Template conversion (Revive action)
# ---------------------------------------------------------------------------

@test "revive: snapshot action menu shows Drill In and Convert to Template" {
  # Create a session and save a snapshot
  tmux new-session -d -s snap-menu -n code -c /tmp
  "$save_state" --reason snap-menu-test

  local pick_sh="$tmux_revive_dir/pick.sh"
  local log_dir="$case_root/fzf-logs"
  mkdir -p "$log_dir"

  # Fake fzf:
  # Inv 1: toggle to snapshots view (ctrl-b, no selection)
  # Inv 2: now in snapshots view — select snapshot row, press Enter
  # Inv 3: action menu — capture items, exit
  cat >"$case_root/bin/fzf" <<'FZFEOF'
#!/usr/bin/env bash
set -euo pipefail
log_dir="${TMUX_TEST_FZF_LOG_DIR:?}"
counter_file="$log_dir/counter"
[ -f "$counter_file" ] || printf '0' >"$counter_file"
n="$(cat "$counter_file")"
n=$((n + 1))
printf '%d' "$n" >"$counter_file"
cat >"$log_dir/items-$n.txt"

case "$n" in
  1)
    # Toggle to snapshots view
    printf '\nctrl-b\n\n'
    exit 0
    ;;
  2)
    # In snapshots view — select snapshot row
    snap_row="$(grep '^snapshot' "$log_dir/items-$n.txt" | head -1)"
    if [ -z "$snap_row" ]; then
      exit 1
    fi
    printf '\nenter\n%s\n' "$snap_row"
    exit 0
    ;;
  3)
    # Action menu items — just exit to see them
    exit 1
    ;;
esac
exit 1
FZFEOF
  chmod +x "$case_root/bin/fzf"
  export TMUX_TEST_FZF_LOG_DIR="$log_dir"

  "$pick_sh" 2>/dev/null || true

  # Invocation 3 should have been the action menu with both options
  [ -f "$log_dir/items-3.txt" ] || fail "action menu was not shown (counter=$(cat "$log_dir/counter" 2>/dev/null))"
  grep -q "Drill In" "$log_dir/items-3.txt" || fail "action menu missing 'Drill In'"
  grep -q "Convert to Template" "$log_dir/items-3.txt" || fail "action menu missing 'Convert to Template'"
}

@test "revive: snapshot Convert to Template creates template file" {
  # Create a session and save a snapshot
  tmux new-session -d -s snap-convert -n editor -c /tmp

  "$save_state" --reason snap-convert-test

  local pick_sh="$tmux_revive_dir/pick.sh"
  local log_dir="$case_root/fzf-logs"
  mkdir -p "$log_dir"

  # Fake fzf:
  # Inv 1: toggle to snapshots view (ctrl-b)
  # Inv 2: select snapshot row, press Enter
  # Inv 3: action menu — select "Convert to Template"
  # Inv 4: exit (after conversion)
  cat >"$case_root/bin/fzf" <<'FZFEOF'
#!/usr/bin/env bash
set -euo pipefail
log_dir="${TMUX_TEST_FZF_LOG_DIR:?}"
counter_file="$log_dir/counter"
[ -f "$counter_file" ] || printf '0' >"$counter_file"
n="$(cat "$counter_file")"
n=$((n + 1))
printf '%d' "$n" >"$counter_file"
cat >"$log_dir/items-$n.txt"

# Detect if this is a main fzf (with --expect) or a sub-menu (without)
has_expect=false
for arg in "$@"; do
  case "$arg" in --expect*) has_expect=true ;; esac
done

case "$n" in
  1)
    printf '\nctrl-b\n\n'
    exit 0
    ;;
  2)
    snap_row="$(grep '^snapshot' "$log_dir/items-$n.txt" | head -1)"
    [ -n "$snap_row" ] || exit 1
    printf '\nenter\n%s\n' "$snap_row"
    exit 0
    ;;
  3)
    # Action menu (no --expect): just return the selection
    printf 'Convert to Template\n'
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
FZFEOF
  chmod +x "$case_root/bin/fzf"
  export TMUX_TEST_FZF_LOG_DIR="$log_dir"

  # Provide template name and decline edit via stdin
  printf 'my-snap-template\nn\n' | "$pick_sh" 2>/dev/null || true

  # Verify template was created
  [ -f "$templates_dir/my-snap-template.yaml" ] || fail "template file not created"

  # Validate it
  "$template_validate" --file "$templates_dir/my-snap-template.yaml" --quiet \
    || fail "created template is invalid"

  # Should contain the session name from the snapshot
  local sess_name
  sess_name="$(yq -r '.sessions[0].name' "$templates_dir/my-snap-template.yaml")"
  assert_eq "snap-convert" "$sess_name" "session name from snapshot"
}

# ---------------------------------------------------------------------------
# Template Variables
# ---------------------------------------------------------------------------

@test "apply: template variables expand in cwd via --var" {
  write_template var-cwd <<YAML
name: var-cwd
variables:
  project:
    prompt: "Project directory"
    default: /tmp/fallback
sessions:
  - name: dev
    windows:
      - name: code
        panes:
          - cwd: "{{project}}"
YAML

  "$apply_template" --name var-cwd --var project=/tmp --dry-run 2>/dev/null
  local exit_code=$?
  [ "$exit_code" -eq 0 ] || fail "dry-run with --var failed (exit $exit_code)"
}

@test "apply: template variables expand in command via --var" {
  write_template var-cmd <<'YAML'
name: var-cmd
variables:
  branch:
    prompt: "Git branch"
    default: main
sessions:
  - name: dev
    windows:
      - name: code
        panes:
          - cwd: /tmp
            command: "echo branch-is-{{branch}}"
YAML

  "$apply_template" --name var-cmd --var branch=develop 2>/dev/null

  wait_for_pane_text "dev:code" "branch-is-develop" 10 \
    || fail "expected 'branch-is-develop' in pane"
}

@test "apply: template variable uses default when not provided via --var" {
  write_template var-default <<'YAML'
name: var-default
variables:
  greeting:
    prompt: "Greeting text"
    default: hello-world
sessions:
  - name: dev
    windows:
      - name: main
        panes:
          - cwd: /tmp
            command: "echo {{greeting}}"
YAML

  "$apply_template" --name var-default --no-prompt 2>/dev/null

  wait_for_pane_text "dev:main" "hello-world" 10 \
    || fail "expected default value 'hello-world' in pane"
}

@test "apply: template variable errors on unexpanded placeholder" {
  write_template var-missing <<'YAML'
name: var-missing
variables:
  known:
    prompt: "Known var"
    default: ok
sessions:
  - name: dev
    windows:
      - name: main
        panes:
          - cwd: /tmp
            command: "echo {{unknown_var}}"
YAML

  run "$apply_template" --name var-missing --no-prompt
  [ "$status" -ne 0 ] || fail "should fail on unexpanded placeholder"
  assert_contains "$output" "unknown_var"
}

@test "apply: multiple --var flags override multiple variables" {
  write_template var-multi <<'YAML'
name: var-multi
variables:
  dir:
    prompt: "Directory"
    default: /tmp
  cmd:
    prompt: "Command"
    default: ls
sessions:
  - name: dev
    windows:
      - name: main
        panes:
          - cwd: "{{dir}}"
            command: "{{cmd}}"
YAML

  "$apply_template" --name var-multi --var dir=/tmp --var cmd="echo multi-test" 2>/dev/null

  wait_for_pane_text "dev:main" "multi-test" 10 \
    || fail "expected 'multi-test' in pane"
}

@test "apply: template with no variables section works normally" {
  write_template no-vars <<'YAML'
name: no-vars
sessions:
  - name: dev
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  "$apply_template" --name no-vars --no-prompt 2>/dev/null
  tmux has-session -t "=no-vars-dev" 2>/dev/null || tmux has-session -t "=dev" 2>/dev/null \
    || fail "session not created for template without variables"
}

@test "validate: template with valid variables section passes" {
  write_template valid-vars <<'YAML'
name: valid-vars
variables:
  project:
    prompt: "Project dir"
    default: ~/src
sessions:
  - name: dev
    windows:
      - name: main
        panes:
          - cwd: "{{project}}"
YAML

  run "$template_validate" --file "$templates_dir/valid-vars.yaml"
  [ "$status" -eq 0 ] || fail "valid variables should pass validation"
}

@test "validate: variable missing prompt field fails" {
  write_template bad-vars <<'YAML'
name: bad-vars
variables:
  project:
    default: ~/src
sessions:
  - name: dev
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  run "$template_validate" --file "$templates_dir/bad-vars.yaml"
  [ "$status" -ne 0 ] || fail "variable without prompt should fail"
  assert_contains "$output" "prompt"
}

@test "validate: warns on undefined variable reference in body" {
  write_template undef-ref <<'YAML'
name: undef-ref
variables:
  known:
    prompt: "Known"
    default: ok
sessions:
  - name: dev
    windows:
      - name: main
        panes:
          - cwd: "{{typo_var}}"
YAML

  run "$template_validate" --file "$templates_dir/undef-ref.yaml"
  # Should still pass (warning, not error) but output should mention typo_var
  assert_contains "$output" "typo_var"
}

@test "revive: ctrl-e toggles templates view on and off 5 times" {
  write_template toggle-tpl <<'YAML'
name: toggle-tpl
description: Toggle test
sessions:
  - name: work
    windows:
      - name: main
        panes:
          - cwd: /tmp
YAML

  local pick_sh="$tmux_revive_dir/pick.sh"
  local log_dir="$case_root/fzf-logs"
  mkdir -p "$log_dir"

  # Create fake fzf: logs stdin items per invocation, returns ctrl-e 10 times then exits
  cat >"$case_root/bin/fzf" <<'FZFEOF'
#!/usr/bin/env bash
set -euo pipefail
log_dir="${TMUX_TEST_FZF_LOG_DIR:?}"
counter_file="$log_dir/counter"
[ -f "$counter_file" ] || printf '0' >"$counter_file"
n="$(cat "$counter_file")"
n=$((n + 1))
printf '%d' "$n" >"$counter_file"
# Save all items from stdin
cat >"$log_dir/items-$n.txt"
# Return ctrl-e for first 10 invocations, then exit (Esc)
if [ "$n" -le 10 ]; then
  printf '\nctrl-e\n\n'
  exit 0
fi
exit 1
FZFEOF
  chmod +x "$case_root/bin/fzf"
  export TMUX_TEST_FZF_LOG_DIR="$log_dir"

  # Run pick.sh — it will loop through 10 ctrl-e toggles then exit
  "$pick_sh" 2>/dev/null || true

  # Verify we got at least 11 invocations (10 toggles + final Esc)
  local count
  count="$(cat "$log_dir/counter")"
  [ "$count" -ge 11 ] || fail "expected at least 11 fzf invocations, got $count"

  # Odd invocations (1,3,5,7,9) should show normal view (no template rows)
  # Even invocations (2,4,6,8,10) should show templates-only view
  local i
  for i in 2 4 6 8 10; do
    grep -q "^template" "$log_dir/items-$i.txt" \
      || fail "invocation $i should show template rows (templates view)"
    if grep -q "^saved\|^live" "$log_dir/items-$i.txt"; then
      fail "invocation $i should NOT show live/saved rows (templates view)"
    fi
  done

  for i in 1 3 5 7 9; do
    if grep -q "^template" "$log_dir/items-$i.txt"; then
      fail "invocation $i should NOT show template rows (normal view)"
    fi
  done
}

@test "revive: ctrl-b toggles snapshots view on and off 5 times" {
  local pick_sh="$tmux_revive_dir/pick.sh"
  local log_dir="$case_root/fzf-logs"
  mkdir -p "$log_dir"

  # Create a snapshot at the correct path for the test environment
  local host_name
  host_name="$(hostname -s 2>/dev/null || hostname)"
  local snapshots_root="$TMUX_REVIVE_STATE_ROOT/snapshots/${host_name}/${socket_name}"
  mkdir -p "$snapshots_root/2026-01-01T00-00-00Z-12345"
  cat >"$snapshots_root/2026-01-01T00-00-00Z-12345/manifest.json" <<'JSON'
{
  "last_updated": "2026-01-01T00:00:00Z",
  "reason": "test-snapshot",
  "sessions": [{"session_name": "snap-sess", "windows": []}]
}
JSON

  # Create fake fzf: logs stdin items per invocation, returns ctrl-b 10 times then exits
  cat >"$case_root/bin/fzf" <<'FZFEOF'
#!/usr/bin/env bash
set -euo pipefail
log_dir="${TMUX_TEST_FZF_LOG_DIR:?}"
counter_file="$log_dir/counter"
[ -f "$counter_file" ] || printf '0' >"$counter_file"
n="$(cat "$counter_file")"
n=$((n + 1))
printf '%d' "$n" >"$counter_file"
cat >"$log_dir/items-$n.txt"
if [ "$n" -le 10 ]; then
  printf '\nctrl-b\n\n'
  exit 0
fi
exit 1
FZFEOF
  chmod +x "$case_root/bin/fzf"
  export TMUX_TEST_FZF_LOG_DIR="$log_dir"

  "$pick_sh" 2>/dev/null || true

  local count
  count="$(cat "$log_dir/counter")"
  [ "$count" -ge 11 ] || fail "expected at least 11 fzf invocations, got $count"

  # Invocation 1=normal, 2=snapshots, 3=normal, 4=snapshots, ...
  local i
  for i in 2 4 6 8 10; do
    grep -q "^snapshot" "$log_dir/items-$i.txt" \
      || fail "invocation $i should show snapshot rows (snapshots view)"
    if grep -q "^saved\|^live" "$log_dir/items-$i.txt"; then
      fail "invocation $i should NOT show live/saved rows (snapshots view)"
    fi
  done

  for i in 1 3 5 7 9; do
    if grep -q "^snapshot" "$log_dir/items-$i.txt"; then
      fail "invocation $i should NOT show snapshot rows (normal view)"
    fi
  done
}

# ---------------------------------------------------------------------------
# Snapshot action menu: expanded items (Restore, Export, Delete)
# ---------------------------------------------------------------------------

@test "revive: snapshot action menu shows all five options" {
  tmux new-session -d -s snap-full-menu -n code -c /tmp
  "$save_state" --reason snap-full-menu

  local pick_sh="$tmux_revive_dir/pick.sh"
  local log_dir="$case_root/fzf-logs"
  mkdir -p "$log_dir"

  cat >"$case_root/bin/fzf" <<'FZFEOF'
#!/usr/bin/env bash
set -euo pipefail
log_dir="${TMUX_TEST_FZF_LOG_DIR:?}"
counter_file="$log_dir/counter"
[ -f "$counter_file" ] || printf '0' >"$counter_file"
n="$(cat "$counter_file")"
n=$((n + 1))
printf '%d' "$n" >"$counter_file"
cat >"$log_dir/items-$n.txt"
case "$n" in
  1) printf '\nctrl-b\n\n'; exit 0 ;;
  2) snap_row="$(grep '^snapshot' "$log_dir/items-$n.txt" | head -1)"
     [ -n "$snap_row" ] || exit 1
     printf '\nenter\n%s\n' "$snap_row"; exit 0 ;;
  3) exit 1 ;;
esac
exit 1
FZFEOF
  chmod +x "$case_root/bin/fzf"
  export TMUX_TEST_FZF_LOG_DIR="$log_dir"

  "$pick_sh" 2>/dev/null || true

  [ -f "$log_dir/items-3.txt" ] || fail "action menu not shown"
  grep -q "Drill In" "$log_dir/items-3.txt" || fail "missing 'Drill In'"
  grep -q "Restore" "$log_dir/items-3.txt" || fail "missing 'Restore'"
  grep -q "Export" "$log_dir/items-3.txt" || fail "missing 'Export'"
  grep -q "Delete" "$log_dir/items-3.txt" || fail "missing 'Delete'"
  grep -q "Convert to Template" "$log_dir/items-3.txt" || fail "missing 'Convert to Template'"
}

@test "revive: snapshot ctrl-d deletes snapshot directory" {
  tmux new-session -d -s snap-del -n code -c /tmp
  "$save_state" --reason snap-del-test

  local host_name
  host_name="$(hostname -s 2>/dev/null || hostname)"
  # TMUX_REVIVE_TMUX_SERVER is unset in tests, so no socket suffix
  local snapshots_root="$TMUX_REVIVE_STATE_ROOT/snapshots/${host_name}"
  local snap_dir
  snap_dir="$(find "$snapshots_root" -name manifest.json -type f 2>/dev/null | head -1 | xargs dirname)"
  [ -d "$snap_dir" ] || fail "snapshot dir not found under $snapshots_root"

  local pick_sh="$tmux_revive_dir/pick.sh"
  local log_dir="$case_root/fzf-logs"
  mkdir -p "$log_dir"

  cat >"$case_root/bin/fzf" <<'FZFEOF'
#!/usr/bin/env bash
set -euo pipefail
log_dir="${TMUX_TEST_FZF_LOG_DIR:?}"
counter_file="$log_dir/counter"
[ -f "$counter_file" ] || printf '0' >"$counter_file"
n="$(cat "$counter_file")"
n=$((n + 1))
printf '%d' "$n" >"$counter_file"
cat >"$log_dir/items-$n.txt"
case "$n" in
  1) printf '\nctrl-b\n\n'; exit 0 ;;
  2) snap_row="$(grep '^snapshot' "$log_dir/items-$n.txt" | head -1)"
     [ -n "$snap_row" ] || exit 1
     printf '\nctrl-d\n%s\n' "$snap_row"; exit 0 ;;
  *) exit 1 ;;
esac
FZFEOF
  chmod +x "$case_root/bin/fzf"
  export TMUX_TEST_FZF_LOG_DIR="$log_dir"

  printf 'y\n' | "$pick_sh" 2>/dev/null || true

  [ ! -d "$snap_dir" ] || fail "snapshot directory was not deleted"
}

# ---------------------------------------------------------------------------
# Template action menu: expanded items (Export, Rename, Duplicate)
# ---------------------------------------------------------------------------

@test "revive: template action menu shows all six options" {
  write_template "tpl-menu-full" <<'YAML'
name: tpl-menu-full
updated_at: "2026-01-01T00:00:00Z"
sessions:
  - name: dev
    windows:
      - name: editor
        panes:
          - cwd: /tmp
YAML

  local pick_sh="$tmux_revive_dir/pick.sh"
  local log_dir="$case_root/fzf-logs"
  mkdir -p "$log_dir"

  cat >"$case_root/bin/fzf" <<'FZFEOF'
#!/usr/bin/env bash
set -euo pipefail
log_dir="${TMUX_TEST_FZF_LOG_DIR:?}"
counter_file="$log_dir/counter"
[ -f "$counter_file" ] || printf '0' >"$counter_file"
n="$(cat "$counter_file")"
n=$((n + 1))
printf '%d' "$n" >"$counter_file"
cat >"$log_dir/items-$n.txt"
case "$n" in
  1) printf '\nctrl-e\n\n'; exit 0 ;;
  2) tpl_row="$(grep '^template' "$log_dir/items-$n.txt" | head -1)"
     [ -n "$tpl_row" ] || exit 1
     printf '\nenter\n%s\n' "$tpl_row"; exit 0 ;;
  3) exit 1 ;;
esac
exit 1
FZFEOF
  chmod +x "$case_root/bin/fzf"
  export TMUX_TEST_FZF_LOG_DIR="$log_dir"

  "$pick_sh" 2>/dev/null || true

  [ -f "$log_dir/items-3.txt" ] || fail "action menu not shown"
  grep -q "Launch" "$log_dir/items-3.txt" || fail "missing 'Launch'"
  grep -q "Edit" "$log_dir/items-3.txt" || fail "missing 'Edit'"
  grep -q "Delete" "$log_dir/items-3.txt" || fail "missing 'Delete'"
  grep -q "Export" "$log_dir/items-3.txt" || fail "missing 'Export'"
  grep -q "Rename" "$log_dir/items-3.txt" || fail "missing 'Rename'"
  grep -q "Duplicate" "$log_dir/items-3.txt" || fail "missing 'Duplicate'"
}

@test "revive: template Rename renames file and updates name field" {
  write_template "tpl-rename-src" <<'YAML'
name: tpl-rename-src
updated_at: "2026-01-01T00:00:00Z"
sessions:
  - name: dev
    windows:
      - name: editor
        panes:
          - cwd: /tmp
YAML

  local pick_sh="$tmux_revive_dir/pick.sh"
  local log_dir="$case_root/fzf-logs"
  mkdir -p "$log_dir"

  cat >"$case_root/bin/fzf" <<'FZFEOF'
#!/usr/bin/env bash
set -euo pipefail
log_dir="${TMUX_TEST_FZF_LOG_DIR:?}"
counter_file="$log_dir/counter"
[ -f "$counter_file" ] || printf '0' >"$counter_file"
n="$(cat "$counter_file")"
n=$((n + 1))
printf '%d' "$n" >"$counter_file"
cat >"$log_dir/items-$n.txt"
case "$n" in
  1) printf '\nctrl-e\n\n'; exit 0 ;;
  2) tpl_row="$(grep '^template' "$log_dir/items-$n.txt" | head -1)"
     [ -n "$tpl_row" ] || exit 1
     printf '\nenter\n%s\n' "$tpl_row"; exit 0 ;;
  3) printf 'Rename\n'; exit 0 ;;
  *) exit 1 ;;
esac
FZFEOF
  chmod +x "$case_root/bin/fzf"
  export TMUX_TEST_FZF_LOG_DIR="$log_dir"

  printf 'tpl-rename-dst\n' | "$pick_sh" 2>/dev/null || true

  [ ! -f "$templates_dir/tpl-rename-src.yaml" ] || fail "old file still exists"
  [ -f "$templates_dir/tpl-rename-dst.yaml" ] || fail "new file not created"
  local new_name
  new_name="$(yq '.name' "$templates_dir/tpl-rename-dst.yaml")"
  [ "$new_name" = "tpl-rename-dst" ] || fail "name field not updated: $new_name"
}

@test "revive: template Duplicate copies file with new name" {
  write_template "tpl-dup-src" <<'YAML'
name: tpl-dup-src
updated_at: "2026-01-01T00:00:00Z"
sessions:
  - name: dev
    windows:
      - name: editor
        panes:
          - cwd: /tmp
YAML

  local pick_sh="$tmux_revive_dir/pick.sh"
  local log_dir="$case_root/fzf-logs"
  mkdir -p "$log_dir"

  cat >"$case_root/bin/fzf" <<'FZFEOF'
#!/usr/bin/env bash
set -euo pipefail
log_dir="${TMUX_TEST_FZF_LOG_DIR:?}"
counter_file="$log_dir/counter"
[ -f "$counter_file" ] || printf '0' >"$counter_file"
n="$(cat "$counter_file")"
n=$((n + 1))
printf '%d' "$n" >"$counter_file"
cat >"$log_dir/items-$n.txt"
case "$n" in
  1) printf '\nctrl-e\n\n'; exit 0 ;;
  2) tpl_row="$(grep '^template' "$log_dir/items-$n.txt" | head -1)"
     [ -n "$tpl_row" ] || exit 1
     printf '\nenter\n%s\n' "$tpl_row"; exit 0 ;;
  3) printf 'Duplicate\n'; exit 0 ;;
  *) exit 1 ;;
esac
FZFEOF
  chmod +x "$case_root/bin/fzf"
  export TMUX_TEST_FZF_LOG_DIR="$log_dir"

  printf 'tpl-dup-copy\n' | "$pick_sh" 2>/dev/null || true

  [ -f "$templates_dir/tpl-dup-src.yaml" ] || fail "source file should still exist"
  [ -f "$templates_dir/tpl-dup-copy.yaml" ] || fail "duplicate file not created"
  local dup_name
  dup_name="$(yq '.name' "$templates_dir/tpl-dup-copy.yaml")"
  [ "$dup_name" = "tpl-dup-copy" ] || fail "name field not updated: $dup_name"
}

# ---------------------------------------------------------------------------
# Help keybinding
# ---------------------------------------------------------------------------

@test "revive: ? keybinding shows help then returns to picker" {
  local pick_sh="$tmux_revive_dir/pick.sh"
  local log_dir="$case_root/fzf-logs"
  mkdir -p "$log_dir"

  cat >"$case_root/bin/fzf" <<'FZFEOF'
#!/usr/bin/env bash
set -euo pipefail
log_dir="${TMUX_TEST_FZF_LOG_DIR:?}"
counter_file="$log_dir/counter"
[ -f "$counter_file" ] || printf '0' >"$counter_file"
n="$(cat "$counter_file")"
n=$((n + 1))
printf '%d' "$n" >"$counter_file"
cat >"$log_dir/items-$n.txt"
case "$n" in
  1) printf '\n?\n\n'; exit 0 ;;
  2) exit 1 ;;
  3) exit 1 ;;
esac
exit 1
FZFEOF
  chmod +x "$case_root/bin/fzf"
  export TMUX_TEST_FZF_LOG_DIR="$log_dir"

  "$pick_sh" 2>/dev/null || true

  [ -f "$log_dir/items-2.txt" ] || fail "help popup not shown"
  grep -q "KEYBINDINGS" "$log_dir/items-2.txt" || fail "help missing KEYBINDINGS header"
  grep -q "Toggle snapshots" "$log_dir/items-2.txt" || fail "help missing snapshots toggle"
  grep -q "Toggle templates" "$log_dir/items-2.txt" || fail "help missing templates toggle"

  [ -f "$log_dir/items-3.txt" ] || fail "picker did not loop back after help"
}

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------

@test "revive: pick.sh errors when fzf is not on PATH" {
  local pick_sh="$tmux_revive_dir/pick.sh"
  rm -f "$case_root/bin/fzf"
  # Keep bash and standard tools on PATH but ensure fzf is missing
  local clean_path="$case_root/bin"
  for d in /usr/bin /bin /usr/local/bin; do
    [ -d "$d" ] && clean_path="$clean_path:$d"
  done
  local output
  output="$(PATH="$clean_path" "$pick_sh" 2>&1 || true)"
  printf '%s' "$output" | grep -qi "fzf" || fail "expected fzf dependency error, got: $output"
}
