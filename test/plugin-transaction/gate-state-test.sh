#!/bin/bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'find "$TEST_ROOT" -mindepth 1 -delete; rmdir "$TEST_ROOT"' EXIT
HELPER="$TEST_ROOT/plugin-tree"
STAGE="$ROOT/native/plugin-transaction/stage-candidate"
GATE="$ROOT/native/plugin-transaction/shell-gate"
STORE="$TEST_ROOT/state/plugin-candidates-v1"
STATE="$TEST_ROOT/state/plugin-transactions-v1"
HOME_DIR="$TEST_ROOT/home"
PLUGIN_DIR="$HOME_DIR/.config/omarchy/plugins"
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
mkdir -p "$PLUGIN_DIR"

make_plugin() {
  local destination=$1 plugin=${2:-acme.gate-test}
  mkdir -p "$destination"
  cp "$ROOT/test/shell.d/fixtures/plugin-load-race/Service.qml" "$destination/Service.qml"
  jq --arg id "$plugin" '.id=$id' "$ROOT/test/shell.d/fixtures/plugin-load-race/manifest.json" >"$destination/manifest.json"
}

stage() {
  local operation=$1 plugin=$2 source=$3 identity
  identity=$("$HELPER" identity "$source")
  HOME="$HOME_DIR" OMARCHY_PATH="$ROOT" OMARCHY_PLUGIN_TREE_HELPER="$HELPER" \
    OMARCHY_PLUGIN_VALIDATOR="$ROOT/bin/omarchy-plugin-validate" \
    OMARCHY_PLUGIN_CANDIDATE_STORE="$STORE" OMARCHY_PLUGIN_TRANSACTION_STATE="$STATE" \
    OMARCHY_PLUGIN_OPERATION_KIND=install OMARCHY_PLUGIN_SOURCE_KIND=directory \
    OMARCHY_PLUGIN_CALLER_CANDIDATE_IDENTITY="$identity" \
    OMARCHY_PLUGIN_EXPECTED_ACTIVE_STATE=absent OMARCHY_PLUGIN_EXPECTED_ACTIVE_IDENTITY= \
    OMARCHY_PLUGIN_EXPECTED_CONFIG_SOURCE_KIND=user \
    OMARCHY_PLUGIN_EXPECTED_CONFIG_SOURCE_IDENTITY="$HOME_DIR/.config/omarchy/shell.json" \
    OMARCHY_PLUGIN_EXPECTED_REFERENCE_PROJECTION=sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432 \
    OMARCHY_PLUGIN_EXPECTED_REFERENCE_STATE=unreferenced OMARCHY_PLUGIN_REFERENCE_POLICY=require-unreferenced \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_SOURCE=test-injected-o5 \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_RAW_SHA256=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_REFERENCE_PROJECTION=sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432 \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_REFERENCE_STATE=unreferenced \
    OMARCHY_PLUGIN_DESTINATION="$PLUGIN_DIR/$plugin" \
    "$STAGE" "$operation" "$plugin" "$source" <<<"$TOKEN" >/dev/null
}

gate() {
  HOME="$HOME_DIR" OMARCHY_PATH="$ROOT" OMARCHY_PLUGIN_TREE_HELPER="$HELPER" \
    OMARCHY_PLUGIN_CANDIDATE_STORE="$STORE" OMARCHY_PLUGIN_TRANSACTION_STATE="$STATE" \
    "$GATE" "$@"
}

operation=40000000-0000-4000-8000-000000000001
plugin=acme.gate-test
source="$TEST_ROOT/source"
make_plugin "$source" "$plugin"
stage "$operation" "$plugin" "$source"

old_umask=$(umask); umask 000
installed=$(gate install "$operation" "$plugin")
umask "$old_umask"
gate_file="$STATE/gates/$plugin.gate"
[[ $(jq -r .status <<<"$installed") == gate-installed ]]
[[ $(stat -c %a "$STATE/gates") == 700 && $(stat -c %a "$gate_file") == 600 && $(stat -c %h "$gate_file") == 1 ]]
cmp -s "$gate_file" <(jq -cS . "$gate_file")
jq -e --arg plugin_id "$plugin" -f "$ROOT/native/plugin-transaction/validate-gate.jq" "$gate_file" >/dev/null
[[ $(jq -r .state "$gate_file") == GATED ]]
printf 'ok - durable private canonical gate precedes acknowledgement\n'

inventory=$(gate inventory)
[[ $(jq -r .status <<<"$inventory") == ok && $(jq -r '.gates[0].pluginId' <<<"$inventory") == "$plugin" ]]
replayed=$(gate install "$operation" "$plugin")
[[ $(jq -r .status <<<"$replayed") == already-gated ]]
printf 'ok - fresh-process inventory restores and exact install is idempotent\n'

gate acknowledge-unload "$operation" "$plugin" shell-one >/dev/null
[[ $(jq -r .state "$gate_file") == UNLOAD_ACKNOWLEDGED ]]
unloaded_sha=$(sha256sum "$gate_file")
unloaded_replay=$(gate install "$operation" "$plugin")
[[ $(jq -r '.status + ":" + .gate.state' <<<"$unloaded_replay") == already-gated:UNLOAD_ACKNOWLEDGED ]]
[[ $(sha256sum "$gate_file") == "$unloaded_sha" ]]
cp -a "$STORE/$operation/candidate" "$PLUGIN_DIR/$plugin"
gate acknowledge-rescan "$operation" "$plugin" shell-one 1 1 "$PLUGIN_DIR/$plugin" >/dev/null
[[ $(jq -r '.state + ":" + .rescan.shellInstance + ":" + (.rescan.generation|tostring)' "$gate_file") == RESCAN_ACKNOWLEDGED:shell-one:1 ]]
rescanned_sha=$(sha256sum "$gate_file")
rescanned_replay=$(gate install "$operation" "$plugin")
[[ $(jq -r '.status + ":" + .gate.state + ":" + (.gate.rescan.generation|tostring)' <<<"$rescanned_replay") == already-gated:RESCAN_ACKNOWLEDGED:1 ]]
[[ $(sha256sum "$gate_file") == "$rescanned_sha" ]]
gate authorize-release "$operation" "$plugin" shell-one 1 7 user "$HOME_DIR/.config/omarchy/shell.json" \
  sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432 unreferenced >/dev/null
[[ $(jq -r .state "$gate_file") == RELEASE_AUTHORIZED ]]
authorized_sha=$(sha256sum "$gate_file")
authorized_replay=$(gate install "$operation" "$plugin")
[[ $(jq -r '.status + ":" + .gate.state + ":" + (.gate.release.configurationEpoch|tostring)' <<<"$authorized_replay") == already-gated:RELEASE_AUTHORIZED:7 ]]
[[ $(sha256sum "$gate_file") == "$authorized_sha" ]]
if gate authorize-release "$operation" "$plugin" shell-one 1 7 default "$HOME_DIR/.config/omarchy/shell.json" \
  sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432 unreferenced >/dev/null 2>&1; then
  printf 'not ok - authorized replay accepted a different configuration source\n' >&2; exit 1
fi
if gate authorize-release "$operation" "$plugin" shell-one 1 7 user "$HOME_DIR/.config/omarchy/shell.json" \
  sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa unreferenced >/dev/null 2>&1; then
  printf 'not ok - authorized replay accepted a different reference projection\n' >&2; exit 1
fi
[[ $(sha256sum "$gate_file") == "$authorized_sha" ]]
printf 'ok - authorized replay revalidates all supplied authority without rewriting the gate\n'
restart=$(gate inventory)
[[ $(jq -r '.gates[0].record.state' <<<"$restart") == RELEASE_AUTHORIZED ]]
printf 'ok - exact retries reconstruct every durable gate state without rewriting it\n'
printf 'ok - tree-bound rescan and release evidence remain blocking after restart\n'

baseline=$(sha256sum "$gate_file")
if gate acknowledge-rescan "$operation" "$plugin" other-shell 2 2 "$PLUGIN_DIR/$plugin" >/dev/null 2>&1; then
  printf 'not ok - stale rescan replaced gate\n' >&2; exit 1
fi
[[ $(sha256sum "$gate_file") == "$baseline" ]]
printf 'ok - conflicting transition preserves authoritative gate\n'

retained=$(gate retain-release "$operation" "$plugin" shell-one 1)
[[ $(jq -r '.status + ":" + .state' <<<"$retained") == release-retained:UNLOAD_ACKNOWLEDGED ]]
[[ $(jq -r '.state + ":" + .rescan.outcome + ":" + .release.outcome' "$gate_file") == UNLOAD_ACKNOWLEDGED:not-requested:not-requested ]]
retained_again=$(gate retain-release "$operation" "$plugin" shell-one 1)
[[ $(jq -r '.status + ":" + .state' <<<"$retained_again") == release-retained:UNLOAD_ACKNOWLEDGED ]]
printf 'ok - interrupted release returns durably and idempotently to a blocking rescan state\n'

race_plugin=acme.gate-race
race_source="$TEST_ROOT/race-source"
race_operation_a=40000000-0000-4000-8000-000000000002
race_operation_b=40000000-0000-4000-8000-000000000003
make_plugin "$race_source" "$race_plugin"
stage "$race_operation_a" "$race_plugin" "$race_source"
stage "$race_operation_b" "$race_plugin" "$race_source"
mkfifo "$TEST_ROOT/gate-race-ready" "$TEST_ROOT/gate-race-resume"
(
  set +e
  OMARCHY_PLUGIN_TREE_TEST_HOOK=after-gate-file-sync:gate-install \
  OMARCHY_PLUGIN_TREE_TEST_READY_FIFO="$TEST_ROOT/gate-race-ready" \
  OMARCHY_PLUGIN_TREE_TEST_RESUME_FIFO="$TEST_ROOT/gate-race-resume" \
    gate install "$race_operation_a" "$race_plugin" \
      >"$TEST_ROOT/gate-race-a.out" 2>"$TEST_ROOT/gate-race-a.err"
  printf '%s\n' "$?" >"$TEST_ROOT/gate-race-a.status"
) &
race_a_pid=$!
[[ $(cat "$TEST_ROOT/gate-race-ready") == after-gate-file-sync:gate-install ]]
set +e
gate install "$race_operation_b" "$race_plugin" \
  >"$TEST_ROOT/gate-race-b.out" 2>"$TEST_ROOT/gate-race-b.err"
race_b_status=$?
set -e
printf x >"$TEST_ROOT/gate-race-resume"
wait "$race_a_pid"
race_a_status=$(<"$TEST_ROOT/gate-race-a.status")
(( (race_a_status == 0 ? 1 : 0) + (race_b_status == 0 ? 1 : 0) == 1 )) || {
  printf 'not ok - different operations both published one shared plugin gate\n' >&2
  exit 1
}
if (( race_a_status == 0 )); then
  grep -qF plugin-gated-by-another-operation "$TEST_ROOT/gate-race-b.err"
else
  grep -qF plugin-gated-by-another-operation "$TEST_ROOT/gate-race-a.err"
fi
printf 'ok - canonical per-plugin lock admits exactly one operation publisher\n'

chmod 0644 "$gate_file"
invalid_inventory=$(gate inventory)
[[ $(jq -r --arg plugin "$plugin" '.status + ":" + ((.gates[] | select(.pluginId == $plugin) | .valid)|tostring)' <<<"$invalid_inventory") == ok:false ]]
chmod 0600 "$gate_file"
printf x >"$STATE/gates/unknown"
global_inventory=$(gate inventory)
[[ $(jq -r .status <<<"$global_inventory") == global-unreadable ]]
printf 'ok - identifiable corruption is plugin-scoped and unknown inventory fails globally closed\n'

[[ ! -e $HOME_DIR/.config/omarchy/shell.json ]]
[[ -d $PLUGIN_DIR/$plugin ]]
printf 'ok - gate lifecycle did not edit configuration or publish a candidate\n'
