#!/bin/bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'find "$TEST_ROOT" -mindepth 1 -delete; rmdir "$TEST_ROOT"' EXIT

HELPER="$TEST_ROOT/plugin-tree"
STAGE="$ROOT/native/plugin-transaction/stage-candidate"
GATE="$ROOT/native/plugin-transaction/shell-gate"
TOKEN=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
SANITIZER_FLAGS=${OMARCHY_PLUGIN_TREE_SANITIZER_FLAGS:-}
read -r -a sanitizer_flags <<<"$SANITIZER_FLAGS"
if [[ -n $SANITIZER_FLAGS ]]; then
  export ASAN_OPTIONS="${ASAN_OPTIONS:+$ASAN_OPTIONS:}halt_on_error=1"
  export UBSAN_OPTIONS="${UBSAN_OPTIONS:+$UBSAN_OPTIONS:}halt_on_error=1"
fi
mise exec -- clang -std=c17 -Wall -Wextra -Werror -Wconversion -Wshadow -O2 \
  -DOMARCHY_PLUGIN_TREE_TEST_HOOKS "${sanitizer_flags[@]}" \
  "$ROOT/native/plugin-transaction/plugin-tree.c" -o "$HELPER"

case_number=0

make_plugin() {
  local destination=$1 plugin=$2
  mkdir -p "$destination"
  cp "$ROOT/test/shell.d/fixtures/plugin-load-race/Service.qml" "$destination/Service.qml"
  jq --arg id "$plugin" '.id=$id' \
    "$ROOT/test/shell.d/fixtures/plugin-load-race/manifest.json" >"$destination/manifest.json"
}

stage_case() {
  local identity
  identity=$("$HELPER" identity "$CASE_SOURCE")
  HOME="$CASE_HOME" OMARCHY_PATH="$ROOT" OMARCHY_PLUGIN_TREE_HELPER="$HELPER" \
    OMARCHY_PLUGIN_VALIDATOR="$ROOT/bin/omarchy-plugin-validate" \
    OMARCHY_PLUGIN_CANDIDATE_STORE="$CASE_STORE" \
    OMARCHY_PLUGIN_TRANSACTION_STATE="$CASE_STATE" \
    OMARCHY_PLUGIN_OPERATION_KIND=install OMARCHY_PLUGIN_SOURCE_KIND=directory \
    OMARCHY_PLUGIN_CALLER_CANDIDATE_IDENTITY="$identity" \
    OMARCHY_PLUGIN_EXPECTED_ACTIVE_STATE=absent OMARCHY_PLUGIN_EXPECTED_ACTIVE_IDENTITY= \
    OMARCHY_PLUGIN_EXPECTED_CONFIG_SOURCE_KIND=user \
    OMARCHY_PLUGIN_EXPECTED_CONFIG_SOURCE_IDENTITY="$CASE_HOME/.config/omarchy/shell.json" \
    OMARCHY_PLUGIN_EXPECTED_REFERENCE_PROJECTION=sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432 \
    OMARCHY_PLUGIN_EXPECTED_REFERENCE_STATE=unreferenced \
    OMARCHY_PLUGIN_REFERENCE_POLICY=require-unreferenced \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_SOURCE=test-injected-o5 \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_RAW_SHA256=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_REFERENCE_PROJECTION=sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432 \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_REFERENCE_STATE=unreferenced \
    OMARCHY_PLUGIN_DESTINATION="$CASE_DESTINATION" \
    "$STAGE" "$CASE_OPERATION" "$CASE_PLUGIN" "$CASE_SOURCE" \
    <<<"$TOKEN" >/dev/null
}

gate_case() {
  HOME="$CASE_HOME" OMARCHY_PATH="$ROOT" OMARCHY_PLUGIN_TREE_HELPER="$HELPER" \
    OMARCHY_PLUGIN_CANDIDATE_STORE="$CASE_STORE" \
    OMARCHY_PLUGIN_TRANSACTION_STATE="$CASE_STATE" \
    "$GATE" "$@"
}

prepare_case() {
  local target=$1
  case_number=$((case_number + 1))
  CASE_ROOT="$TEST_ROOT/case-$case_number"
  CASE_HOME="$CASE_ROOT/home"
  CASE_STORE="$CASE_ROOT/candidates"
  CASE_STATE="$CASE_ROOT/transactions"
  CASE_PLUGIN_DIR="$CASE_HOME/.config/omarchy/plugins"
  CASE_PLUGIN="acme.gate-fault-$case_number"
  printf -v CASE_OPERATION '52000000-0000-4000-8000-%012d' "$case_number"
  CASE_SOURCE="$CASE_ROOT/source"
  CASE_DESTINATION="$CASE_PLUGIN_DIR/$CASE_PLUGIN"
  mkdir -p "$CASE_PLUGIN_DIR"
  make_plugin "$CASE_SOURCE" "$CASE_PLUGIN"
  stage_case

  [[ $target == install ]] && return
  gate_case install "$CASE_OPERATION" "$CASE_PLUGIN" >/dev/null
  [[ $target == unload ]] && return
  gate_case acknowledge-unload "$CASE_OPERATION" "$CASE_PLUGIN" shell-fault >/dev/null
  cp -a "$CASE_STORE/$CASE_OPERATION/candidate" "$CASE_DESTINATION"
  [[ $target == rescan ]] && return
  gate_case acknowledge-rescan "$CASE_OPERATION" "$CASE_PLUGIN" shell-fault 7 11 \
    "$CASE_DESTINATION" >/dev/null
  [[ $target == release ]] && return
  gate_case authorize-release "$CASE_OPERATION" "$CASE_PLUGIN" shell-fault 7 3 user \
    "$CASE_HOME/.config/omarchy/shell.json" \
    sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432 \
    unreferenced >/dev/null
}

target_command() {
  local target=$1
  case $target in
    install) gate_case install "$CASE_OPERATION" "$CASE_PLUGIN" ;;
    unload) gate_case acknowledge-unload "$CASE_OPERATION" "$CASE_PLUGIN" shell-fault ;;
    rescan) gate_case acknowledge-rescan "$CASE_OPERATION" "$CASE_PLUGIN" shell-fault 7 11 "$CASE_DESTINATION" ;;
    release)
      gate_case authorize-release "$CASE_OPERATION" "$CASE_PLUGIN" shell-fault 7 3 user \
        "$CASE_HOME/.config/omarchy/shell.json" \
        sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432 \
        unreferenced
      ;;
    retain) gate_case retain-release "$CASE_OPERATION" "$CASE_PLUGIN" shell-fault 7 ;;
    *) printf 'unknown target %s\n' "$target" >&2; return 64 ;;
  esac
}

state_before() {
  case $1 in
    install) printf 'absent\n' ;;
    unload) printf 'GATED\n' ;;
    rescan) printf 'UNLOAD_ACKNOWLEDGED\n' ;;
    release) printf 'RESCAN_ACKNOWLEDGED\n' ;;
    retain) printf 'RELEASE_AUTHORIZED\n' ;;
  esac
}

state_after() {
  case $1 in
    install) printf 'GATED\n' ;;
    unload|retain) printf 'UNLOAD_ACKNOWLEDGED\n' ;;
    rescan) printf 'RESCAN_ACKNOWLEDGED\n' ;;
    release) printf 'RELEASE_AUTHORIZED\n' ;;
  esac
}

transition_name() {
  case $1 in
    install) printf 'gate-install\n' ;;
    unload) printf 'gate-unload-acknowledged\n' ;;
    rescan) printf 'gate-rescan-acknowledged\n' ;;
    release) printf 'gate-release-authorized\n' ;;
    retain) printf 'gate-release-retained\n' ;;
  esac
}

authoritative_state() {
  local gate_file="$CASE_STATE/gates/$CASE_PLUGIN.gate"
  if [[ ! -e $gate_file ]]; then
    printf 'absent\n'
  else
    jq -r .state "$gate_file"
  fi
}

run_fault_case() {
  local target=$1 fault=$2 transition before after expected_visible status inventory
  prepare_case "$target"
  transition=$(transition_name "$target")
  before=$(state_before "$target")
  after=$(state_after "$target")

  set +e
  case $fault in
    before-write|after-write|after-file-sync|after-rename)
      point=${fault/before-write/before-gate-write}
      point=${point/after-write/after-gate-write}
      point=${point/after-file-sync/after-gate-file-sync}
      point=${point/after-rename/after-gate-rename}
      OMARCHY_PLUGIN_TREE_TEST_CRASH_POINT="$point:$transition" \
        target_command "$target" >"$CASE_ROOT/fault.out" 2>"$CASE_ROOT/fault.err"
      status=$?
      ;;
    file-fsync|parent-fsync)
      point=${fault/file-fsync/gate-file}
      point=${point/parent-fsync/gate-parent}
      OMARCHY_PLUGIN_TREE_TEST_FAIL_FSYNC="$point:$transition" \
        target_command "$target" >"$CASE_ROOT/fault.out" 2>"$CASE_ROOT/fault.err"
      status=$?
      ;;
    rename)
      OMARCHY_PLUGIN_TREE_TEST_FAIL_RENAME="gate-rename:$transition" \
        target_command "$target" >"$CASE_ROOT/fault.out" 2>"$CASE_ROOT/fault.err"
      status=$?
      ;;
  esac
  set -e
  (( status != 0 )) || {
    printf 'not ok - %s %s reported success before durability\n' "$target" "$fault" >&2
    exit 1
  }

  if [[ $fault == after-rename || $fault == parent-fsync ]]; then
    expected_visible=$after
  else
    expected_visible=$before
  fi
  [[ $(authoritative_state) == "$expected_visible" ]]

  inventory=$(gate_case inventory)
  [[ $(jq -r .status <<<"$inventory") == ok ]]
  if [[ $expected_visible == absent ]]; then
    [[ $(jq -r --arg plugin "$CASE_PLUGIN" '[.gates[] | select(.pluginId == $plugin)] | length' <<<"$inventory") == 0 ]]
  else
    [[ $(jq -r --arg plugin "$CASE_PLUGIN" '.gates[] | select(.pluginId == $plugin) | .record.state' <<<"$inventory") == "$expected_visible" ]]
  fi

  target_command "$target" >"$CASE_ROOT/retry.out"
  [[ $(authoritative_state) == "$after" ]]
  inventory=$(gate_case inventory)
  [[ $(jq -r --arg plugin "$CASE_PLUGIN" '.gates[] | select(.pluginId == $plugin) | .record.state' <<<"$inventory") == "$after" ]]
}

for target in install unload rescan release retain; do
  for fault in before-write after-write file-fsync after-file-sync rename after-rename parent-fsync; do
    run_fault_case "$target" "$fault"
  done
  printf 'ok - %s transition reconciles every write/fsync/rename fault in a fresh process\n' "$target"
done

printf 'ok - incomplete gate temporaries never become authoritative replay results\n'
