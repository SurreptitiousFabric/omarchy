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
cp -a "$STORE/$operation/candidate" "$PLUGIN_DIR/$plugin"
gate acknowledge-rescan "$operation" "$plugin" shell-one 1 >/dev/null
[[ $(jq -r '.state + ":" + .rescan.shellInstance + ":" + (.rescan.generation|tostring)' "$gate_file") == RESCAN_ACKNOWLEDGED:shell-one:1 ]]
gate authorize-release "$operation" "$plugin" shell-one 1 7 user "$HOME_DIR/.config/omarchy/shell.json" \
  sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432 unreferenced >/dev/null
[[ $(jq -r .state "$gate_file") == RELEASE_AUTHORIZED ]]
restart=$(gate inventory)
[[ $(jq -r '.gates[0].record.state' <<<"$restart") == RELEASE_AUTHORIZED ]]
printf 'ok - tree-bound rescan and release evidence remain blocking after restart\n'

baseline=$(sha256sum "$gate_file")
if gate acknowledge-rescan "$operation" "$plugin" other-shell 2 >/dev/null 2>&1; then
  printf 'not ok - stale rescan replaced gate\n' >&2; exit 1
fi
[[ $(sha256sum "$gate_file") == "$baseline" ]]
printf 'ok - conflicting transition preserves authoritative gate\n'

chmod 0644 "$gate_file"
invalid_inventory=$(gate inventory)
[[ $(jq -r '.status + ":" + (.gates[0].valid|tostring)' <<<"$invalid_inventory") == ok:false ]]
chmod 0600 "$gate_file"
printf x >"$STATE/gates/unknown"
global_inventory=$(gate inventory)
[[ $(jq -r .status <<<"$global_inventory") == global-unreadable ]]
printf 'ok - identifiable corruption is plugin-scoped and unknown inventory fails globally closed\n'

[[ ! -e $HOME_DIR/.config/omarchy/shell.json ]]
[[ -d $PLUGIN_DIR/$plugin ]]
printf 'ok - gate lifecycle did not edit configuration or publish a candidate\n'
