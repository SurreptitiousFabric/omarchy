#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

fixture="$ROOT/test/shell.d/fixtures/plugin-load-race"
stub_bin="$test_tmp/bin"
events="$test_tmp/events"
mkdir -p "$stub_bin"

cat >"$stub_bin/git" <<'SH'
#!/bin/bash

set -euo pipefail

case "$*" in
  *" fetch --quiet origin HEAD")
    exit 0
    ;;
  *" rev-parse HEAD")
    printf '%s\n' old-revision
    ;;
  *" rev-parse FETCH_HEAD")
    printf '%s\n' candidate-revision
    ;;
  *" merge --ff-only FETCH_HEAD")
    plugin_dir="$2"
    cp "$RACE_FIXTURE/manifest.json" "$plugin_dir/manifest.json"
    cp "$RACE_FIXTURE/Service.qml" "$plugin_dir/Service.qml"
    printf '%s\n' candidate-exposed-in-live-directory >>"$RACE_EVENTS"
    for _ in {1..100}; do
      [[ -e $RACE_OBSERVER_DONE ]] && exit 0
      sleep 0.01
    done
    printf '%s\n' watcher-timeout >>"$RACE_EVENTS"
    exit 1
    ;;
  *" reset --hard ORIG_HEAD")
    printf '%s\n' rollback >>"$RACE_EVENTS"
    ;;
  clone\ --*)
    destination="${@: -1}"
    mkdir -p "$destination"
    cp "$RACE_FIXTURE/manifest.json" "$destination/manifest.json"
    cp "$RACE_FIXTURE/Service.qml" "$destination/Service.qml"
    ;;
  *)
    printf 'unexpected git invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
SH

cat >"$stub_bin/omarchy-plugin-validate" <<'SH'
#!/bin/bash

set -euo pipefail

printf 'validation-start:%s\n' "$1" >>"$RACE_EVENTS"
"$ROOT/bin/omarchy-plugin-validate" "$1"
printf 'validation-finished:%s\n' "$1" >>"$RACE_EVENTS"
SH

cat >"$stub_bin/omarchy-shell" <<'SH'
#!/bin/bash

set -euo pipefail

for _ in {1..100}; do
  [[ -e $RACE_OBSERVER_DONE ]] && break
  sleep 0.01
done
printf 'explicit-rescan:%s\n' "$*" >>"$RACE_EVENTS"
SH

cat >"$stub_bin/omarchy-git-url-check" <<'SH'
#!/bin/bash
exit 0
SH

cat >"$stub_bin/omarchy-plugin-catalog" <<'SH'
#!/bin/bash
printf '[]\n'
SH

chmod +x "$stub_bin"/*

event_line() {
  local pattern="$1"
  rg -n -m 1 "$pattern" "$events" | cut -d: -f1
}

observe_candidate() {
  local candidate_file="$1"
  local done_file="$2"

  for _ in {1..100}; do
    if [[ -f $candidate_file ]] && rg -q 'candidate-v2' "$candidate_file"; then
      printf '%s\n' watcher-observed-candidate-entry-point >>"$events"
      : >"$done_file"
      return 0
    fi
    sleep 0.01
  done
  return 1
}

run_update_window() {
  local home="$test_tmp/update-home"
  local plugin_dir="$home/.config/omarchy/plugins/acme.race-marker"
  local observer_done="$test_tmp/update-observer-done"

  : >"$events"
  mkdir -p "$plugin_dir/.git"
  printf '%s\n' old-entry-point >"$plugin_dir/Service.qml"
  cp "$fixture/manifest.json" "$plugin_dir/manifest.json"
  jq '.version = "1.0.0"' "$plugin_dir/manifest.json" >"$plugin_dir/manifest.json.tmp"
  mv "$plugin_dir/manifest.json.tmp" "$plugin_dir/manifest.json"

  observe_candidate "$plugin_dir/Service.qml" "$observer_done" &
  local observer_pid=$!

  HOME="$home" PATH="$stub_bin:$PATH" ROOT="$ROOT" RACE_FIXTURE="$fixture" \
    RACE_EVENTS="$events" RACE_OBSERVER_DONE="$observer_done" \
    "$ROOT/bin/omarchy-plugin-update" acme.race-marker --yes >/dev/null
  wait "$observer_pid"

  local exposed_line observed_line validation_line rescan_line
  exposed_line=$(event_line '^candidate-exposed-in-live-directory$')
  observed_line=$(event_line '^watcher-observed-candidate-entry-point$')
  validation_line=$(event_line '^validation-start:')
  rescan_line=$(event_line '^explicit-rescan:')

  (( exposed_line < observed_line && observed_line < validation_line && validation_line < rescan_line )) ||
    fail "live update candidate can be observed before validation" "$(cat "$events")"
  pass "live update candidate can be observed before validation"
}

run_install_reference_window() {
  local home="$test_tmp/install-home"
  local plugin_dir="$home/.config/omarchy/plugins/acme.race-marker"
  local observer_done="$test_tmp/install-observer-done"
  local config="$home/.config/omarchy/shell.json"

  : >"$events"
  mkdir -p "$(dirname -- "$config")"
  printf '%s\n' '{"version":1,"bar":{"layout":{"left":[],"center":[],"right":[]}},"plugins":[{"id":"acme.race-marker"}]}' >"$config"

  observe_candidate "$plugin_dir/Service.qml" "$observer_done" &
  local observer_pid=$!

  HOME="$home" PATH="$stub_bin:$PATH" ROOT="$ROOT" RACE_FIXTURE="$fixture" \
    RACE_EVENTS="$events" RACE_OBSERVER_DONE="$observer_done" \
    "$ROOT/bin/omarchy-plugin-add" https://example.test/acme.race-marker.git --yes >/dev/null
  wait "$observer_pid"

  jq -e 'any(.plugins[]; .id == "acme.race-marker")' "$config" >/dev/null ||
    fail "fresh install fixture starts referenced"
  local validation_line observed_line rescan_line
  validation_line=$(event_line '^validation-finished:.*\.add\.tmp\.')
  observed_line=$(event_line '^watcher-observed-candidate-entry-point$')
  rescan_line=$(event_line '^explicit-rescan:')

  (( validation_line < observed_line && observed_line < rescan_line )) ||
    fail "pre-referenced install becomes observable before explicit rescan" "$(cat "$events")"
  pass "pre-referenced install becomes observable before explicit rescan"
}

run_update_window
run_install_reference_window

rg -q 'Component\.onCompleted: markerProcess\.running = true' "$fixture/Service.qml" ||
  fail "race fixture records entry-point evaluation"
grep -Fq "printf '%s\\\\n' candidate-v2" "$fixture/Service.qml" ||
  fail "race fixture records a fixed harmless revision marker"
pass "race fixture records entry-point evaluation"

update_source="$ROOT/bin/omarchy-plugin-update"
registry_source="$ROOT/shell/services/PluginRegistry.qml"
shell_source="$ROOT/shell/shell.qml"

merge_line=$(rg -n -m 1 'merge --ff-only FETCH_HEAD' "$update_source" | cut -d: -f1)
validate_line=$(rg -n -m 1 'omarchy-plugin-validate "\$dir"' "$update_source" | cut -d: -f1)
explicit_rescan_line=$(rg -n -m 1 'omarchy-shell shell rescanPlugins' "$update_source" | cut -d: -f1)
(( merge_line < validate_line && validate_line < explicit_rescan_line )) ||
  fail "production update ordering retains the documented race window"

rg -q 'close_write,create,delete,move' "$registry_source" ||
  fail "plugin watcher covers live checkout mutations"
rg -q 'registry\.localPluginChanged\(pluginId\)' "$registry_source" ||
  fail "plugin watcher emits reload events"
rg -q 'onLocalPluginChanged\(pluginId\)' "$shell_source" ||
  fail "shell handles plugin watcher events"
rg -q 'localPluginReloadTimer\.restart\(\)' "$shell_source" ||
  fail "watcher events schedule independent reload"
pass "production watcher independently reloads live checkout mutations"

rg -q 'id: pluginBarLoader' "$shell_source" ||
  fail "loader inventory includes bar replacements"
rg -q 'Qt\.createComponent\(url, Component\.PreferSynchronous\)' "$shell_source" ||
  fail "loader inventory includes services"
rg -q 'function loadPluginWidget\(registryKey, url, meta\)' "$shell_source" ||
  fail "loader inventory includes bar widgets"
rg -Fq 'var panelKinds = ["panel", "overlay", "menu"]' "$shell_source" ||
  fail "loader inventory includes panels overlays and menus"
pass "loader inventory covers every third-party entry-point category"
