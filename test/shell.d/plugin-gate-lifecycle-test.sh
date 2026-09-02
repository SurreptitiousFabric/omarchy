#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

SOURCE_ROOT=${OMARCHY_LIFECYCLE_SOURCE_ROOT:-$ROOT}
EXPECTATION=${OMARCHY_LIFECYCLE_EXPECTATION:-corrected}
FIXTURE_ROOT="$ROOT/test/shell.d/fixtures/plugin-gate-lifecycle"
TMPDIR=""
QS_PID=""

cleanup() {
  if [[ -n $QS_PID ]] && kill -0 "$QS_PID" 2>/dev/null; then
    kill "$QS_PID" 2>/dev/null || true
    wait "$QS_PID" 2>/dev/null || true
  fi
  if [[ -n ${OMARCHY_LIFECYCLE_EVIDENCE_DIR:-} && -n $TMPDIR && -d $TMPDIR ]]; then
    mkdir -p "$OMARCHY_LIFECYCLE_EVIDENCE_DIR"
    cp -a "$TMPDIR/." "$OMARCHY_LIFECYCLE_EVIDENCE_DIR/"
  fi
  [[ -n $TMPDIR && -d $TMPDIR ]] && rm -rf "$TMPDIR"
}
trap cleanup EXIT

require_command jq
require_command quickshell
require_command node

TMPDIR=$(mktemp -d)
chmod 0700 "$TMPDIR"
test_root="$TMPDIR/omarchy"
test_home="$TMPDIR/home"
runtime_dir="$TMPDIR/runtime"
state_dir="$test_home/.local/state"
plugin_dir="$test_home/.config/omarchy/plugins"
config_file="$test_home/.config/omarchy/shell.json"
marker="$TMPDIR/lifecycle-marker"
service_marker="$marker.service"
widget_marker="$marker.widget"
active_service_marker="$marker.active"
active_widget_marker="$marker.active-widget"
log="$TMPDIR/quickshell.log"
helper="$TMPDIR/plugin-tree"
mkdir -p "$test_root" "$test_home" "$runtime_dir" "$state_dir" "$plugin_dir" "$(dirname "$config_file")"
chmod 0700 "$runtime_dir"
cp -a "$SOURCE_ROOT/shell" "$test_root/shell"
ln -s "$SOURCE_ROOT/config" "$test_root/config"
ln -s "$SOURCE_ROOT/bin" "$test_root/bin"
cp -a "$SOURCE_ROOT/native" "$test_root/native"
mv "$test_root/native/plugin-transaction/shell-gate" "$test_root/native/plugin-transaction/shell-gate.real"
cp "$FIXTURE_ROOT/shell-gate-wrapper" "$test_root/native/plugin-transaction/shell-gate"
chmod 0755 "$test_root/native/plugin-transaction/shell-gate"

if [[ $EXPECTATION == broken-token-guards ]]; then
  OMARCHY_LIFECYCLE_DISABLE_TOKEN_GUARDS=1 mise exec -- node "$FIXTURE_ROOT/instrument-copy.mjs" "$test_root/shell/shell.qml"
elif [[ $EXPECTATION == broken-screen-accounting ]]; then
  OMARCHY_LIFECYCLE_FORGET_SCREEN_LOADERS=1 mise exec -- node "$FIXTURE_ROOT/instrument-copy.mjs" "$test_root/shell/shell.qml"
elif [[ $EXPECTATION == broken-current-generation ]]; then
  OMARCHY_LIFECYCLE_DISABLE_GENERATION_GUARDS=1 mise exec -- node "$FIXTURE_ROOT/instrument-copy.mjs" "$test_root/shell/shell.qml"
elif [[ $EXPECTATION == duplicate-screen-loader ]]; then
  OMARCHY_LIFECYCLE_DUPLICATE_SCREEN_LOADER=1 mise exec -- node "$FIXTURE_ROOT/instrument-copy.mjs" "$test_root/shell/shell.qml"
else
  mise exec -- node "$FIXTURE_ROOT/instrument-copy.mjs" "$test_root/shell/shell.qml"
fi
mise exec -- clang -std=c17 -Wall -Wextra -Werror -Wconversion -Wshadow -O2 \
  "$SOURCE_ROOT/native/plugin-transaction/plugin-tree.c" -o "$helper"

service_id=acme.lifecycle-service
active_service_id=acme.lifecycle-active-service
widget_id=acme.lifecycle-widget
active_widget_id=acme.lifecycle-active-widget
selected_bar_id=acme.lifecycle-selected-bar
for plugin in "$service_id" "$active_service_id" "$widget_id" "$active_widget_id" "$selected_bar_id"; do
  live="$plugin_dir/$plugin"
  candidate="$TMPDIR/candidate-$plugin"
  mkdir -p "$live" "$candidate"
  if [[ $plugin == "$active_service_id" ]]; then
    cp "$FIXTURE_ROOT/ActiveService.qml" "$live/Service.qml"
    jq --arg id "$plugin" '.id=$id | .kinds=["service"] | .entryPoints={service:"Service.qml"}' \
      "$FIXTURE_ROOT/manifest.json" >"$live/manifest.json"
  elif [[ $plugin == "$service_id" ]]; then
    cp "$FIXTURE_ROOT/Service.qml" "$live/Service.qml"
    jq --arg id "$plugin" '.id=$id | .kinds=["service"] | .entryPoints={service:"Service.qml"}' \
      "$FIXTURE_ROOT/manifest.json" >"$live/manifest.json"
  elif [[ $plugin == "$widget_id" ]]; then
    cp "$FIXTURE_ROOT/BarWidget.qml" "$live/BarWidget.qml"
    jq --arg id "$plugin" '.id=$id | .kinds=["bar-widget"] | .entryPoints={barWidget:"BarWidget.qml"}' \
      "$FIXTURE_ROOT/manifest.json" >"$live/manifest.json"
  elif [[ $plugin == "$active_widget_id" ]]; then
    cp "$FIXTURE_ROOT/ActiveBarWidget.qml" "$live/BarWidget.qml"
    jq --arg id "$plugin" '.id=$id | .kinds=["bar-widget"] | .entryPoints={barWidget:"BarWidget.qml"}' \
      "$FIXTURE_ROOT/manifest.json" >"$live/manifest.json"
  else
    cp "$FIXTURE_ROOT/SelectedBar.qml" "$live/SelectedBar.qml"
    jq --arg id "$plugin" '.id=$id | .kinds=["bar"] | .entryPoints={bar:"SelectedBar.qml"}' \
      "$FIXTURE_ROOT/manifest.json" >"$live/manifest.json"
  fi
  cp -a "$live/." "$candidate/"
done

jq -n --arg service "$service_id" --arg widget "$widget_id" '{
  version:1,
  bar:{layout:{left:[],center:[{id:$widget}],right:[]}},
  plugins:[{id:$service}]
}' >"$config_file"
jq --arg plugin "$active_service_id" '.plugins += [{id:$plugin}]' "$config_file" >"$config_file.next"
mv "$config_file.next" "$config_file"
jq --arg plugin "$active_widget_id" '.bar.layout.center += [{id:$plugin}]' "$config_file" >"$config_file.next"
mv "$config_file.next" "$config_file"

projection_digest() {
  local plugin=$1
  ROOT="$SOURCE_ROOT" CONFIG="$config_file" PLUGIN="$plugin" mise exec -- node <<'JS'
const crypto = require('crypto')
const fs = require('fs')
const vm = require('vm')
const source = fs.readFileSync(process.env.ROOT + '/shell/services/PluginReferenceProjection.js', 'utf8').replace(/^\.pragma library\n/, '')
const scope = {}
vm.runInNewContext(source + '\nthis.api={canonicalBytes};', scope)
const config = JSON.parse(fs.readFileSync(process.env.CONFIG, 'utf8'))
const bytes = scope.api.canonicalBytes(config, process.env.PLUGIN)
process.stdout.write('sha256:' + crypto.createHash('sha256').update(Buffer.from(bytes)).digest('hex'))
JS
}

stage_operation() {
  local operation=$1 plugin=$2
  local source="$TMPDIR/candidate-$plugin" destination="$plugin_dir/$plugin"
  local identity projection raw
  identity=$("$helper" identity "$source")
  projection=$(projection_digest "$plugin")
  raw=sha256:$(sha256sum "$config_file" | cut -d' ' -f1)
  HOME="$test_home" XDG_STATE_HOME="$state_dir" OMARCHY_PATH="$SOURCE_ROOT" \
    OMARCHY_PLUGIN_TREE_HELPER="$helper" OMARCHY_PLUGIN_VALIDATOR="$SOURCE_ROOT/bin/omarchy-plugin-validate" \
    OMARCHY_PLUGIN_CANDIDATE_STORE="$state_dir/omarchy/plugin-candidates-v1" \
    OMARCHY_PLUGIN_TRANSACTION_STATE="$state_dir/omarchy/plugin-transactions-v1" \
    OMARCHY_PLUGIN_DISCOVERY_DIR="$plugin_dir" OMARCHY_PLUGIN_OPERATION_KIND=update \
    OMARCHY_PLUGIN_SOURCE_KIND=directory OMARCHY_PLUGIN_CALLER_CANDIDATE_IDENTITY="$identity" \
    OMARCHY_PLUGIN_EXPECTED_ACTIVE_STATE=present OMARCHY_PLUGIN_EXPECTED_ACTIVE_IDENTITY="$identity" \
    OMARCHY_PLUGIN_EXPECTED_CONFIG_SOURCE_KIND=user OMARCHY_PLUGIN_EXPECTED_CONFIG_SOURCE_IDENTITY="$config_file" \
    OMARCHY_PLUGIN_EXPECTED_REFERENCE_PROJECTION="$projection" OMARCHY_PLUGIN_EXPECTED_REFERENCE_STATE=referenced \
    OMARCHY_PLUGIN_REFERENCE_POLICY=preserve-observed OMARCHY_PLUGIN_STAGE_OBSERVATION_SOURCE=test-injected-o5 \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_RAW_SHA256="$raw" OMARCHY_PLUGIN_STAGE_OBSERVATION_REFERENCE_PROJECTION="$projection" \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_REFERENCE_STATE=referenced OMARCHY_PLUGIN_DESTINATION="$destination" \
    "$SOURCE_ROOT/native/plugin-transaction/stage-candidate" "$operation" "$plugin" "$source" \
    <<<'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' >/dev/null
}

service_operation=61000000-0000-4000-8000-000000000001
widget_operation=61000000-0000-4000-8000-000000000002
active_service_operation=61000000-0000-4000-8000-000000000003
selected_bar_operation=61000000-0000-4000-8000-000000000004
active_widget_operation=61000000-0000-4000-8000-000000000005
stage_operation "$service_operation" "$service_id"
stage_operation "$widget_operation" "$widget_id"
stage_operation "$active_service_operation" "$active_service_id"
stage_operation "$selected_bar_operation" "$selected_bar_id"
stage_operation "$active_widget_operation" "$active_widget_id"

selected_bar_source="$plugin_dir/$selected_bar_id/SelectedBar.qml"
{
  printf 'import QtQuick\n'
  printf '//'
  head -c 4194304 /dev/zero | tr '\0' x
  printf '\nItem {}\n'
} >"$selected_bar_source"

export HOME="$test_home"
export XDG_CONFIG_HOME="$test_home/.config"
export XDG_CACHE_HOME="$test_home/.cache"
export XDG_STATE_HOME="$state_dir"
export XDG_RUNTIME_DIR="$runtime_dir"
export OMARCHY_PATH="$test_root"
export OMARCHY_PLUGIN_TREE_HELPER="$helper"
export OMARCHY_PLUGIN_TRANSACTION_STATE="$state_dir/omarchy/plugin-transactions-v1"
export OMARCHY_GATE_LIFECYCLE_MARKER="$marker"
export OMARCHY_LIFECYCLE_REAL_GATE="$test_root/native/plugin-transaction/shell-gate.real"
export OMARCHY_LIFECYCLE_HOLD_PROJECTION="$TMPDIR/hold-projection"
export OMARCHY_LIFECYCLE_PROJECTION_READY="$TMPDIR/projection-ready"
export OMARCHY_LIFECYCLE_PROJECTION_RESUME="$TMPDIR/projection-resume"
export OMARCHY_LIFECYCLE_HOLD_AUTHORIZE_BEFORE="$TMPDIR/hold-authorize-before"
export OMARCHY_LIFECYCLE_AUTHORIZE_BEFORE_READY="$TMPDIR/authorize-before-ready"
export OMARCHY_LIFECYCLE_AUTHORIZE_BEFORE_RESUME="$TMPDIR/authorize-before-resume"
export OMARCHY_LIFECYCLE_HOLD_AUTHORIZE_AFTER="$TMPDIR/hold-authorize-after"
export OMARCHY_LIFECYCLE_AUTHORIZE_AFTER_READY="$TMPDIR/authorize-after-ready"
export OMARCHY_LIFECYCLE_AUTHORIZE_AFTER_RESUME="$TMPDIR/authorize-after-resume"
mkfifo "$OMARCHY_LIFECYCLE_PROJECTION_RESUME" "$OMARCHY_LIFECYCLE_AUTHORIZE_BEFORE_RESUME" "$OMARCHY_LIFECYCLE_AUTHORIZE_AFTER_RESUME"
export QT_QPA_PLATFORM=offscreen
export WAYLAND_DISPLAY=
export HYPRLAND_INSTANCE_SIGNATURE=

quickshell -p "$test_root/shell" --no-color >"$log" 2>&1 &
QS_PID=$!

shell_ipc() { "$SOURCE_ROOT/bin/omarchy-shell" "$@"; }
state() { shell_ipc shell testLifecycleState "$1"; }
transaction_status() { shell_ipc shell transactionPluginState "$1" | jq -r .status; }
marker_count() {
  local path=$1 needle=$2
  [[ -f $path ]] || { printf '0\n'; return; }
  awk -v needle="$needle" '{ total += gsub(needle, "") } END { print total + 0 }' "$path"
}

wait_for() {
  local description=$1 command=$2
  for _ in {1..100}; do
    if eval "$command"; then return 0; fi
    kill -0 "$QS_PID" 2>/dev/null || { sed -n '1,240p' "$log" >&2; fail "$description"; }
    sleep 0.02
  done
  for operation in "$service_operation" "$widget_operation"; do
    printf 'transaction %s: ' "$operation" >&2
    transaction_status "$operation" >&2 2>/dev/null || printf 'unavailable\n' >&2
  done
  for plugin in "$service_id" "$widget_id"; do
    printf 'lifecycle %s: ' "$plugin" >&2
    state "$plugin" >&2 2>/dev/null || printf 'unavailable\n' >&2
  done
  sed -n '1,240p' "$log" >&2
  fail "$description"
}

wait_for "isolated offscreen shell accepts IPC" '[[ $(shell_ipc shell ping 2>/dev/null || true) == ok ]]'
wait_for "real service completion reaches deterministic barrier" '(( $(state "$service_id" 2>/dev/null | jq -r .deferredService || echo 0) >= 1 ))'
wait_for "real widget completion reaches deterministic barrier" '(( $(state "$widget_id" 2>/dev/null | jq -r .deferredWidget || echo 0) >= 1 ))'
wait_for "active-service completion reaches deterministic barrier" '(( $(state "$active_service_id" 2>/dev/null | jq -r .deferredService || echo 0) >= 1 ))'
wait_for "active-widget completion reaches deterministic barrier" '(( $(state "$active_widget_id" 2>/dev/null | jq -r .deferredWidget || echo 0) >= 1 ))'
shell_ipc shell testResumeDeferredService "$active_service_id" 0 >/dev/null
wait_for "active-service object is created" '[[ $(state "$active_service_id" 2>/dev/null | jq -r .serviceActive || true) == true ]]'
shell_ipc shell testResumeDeferredWidget "$active_widget_id" 0 >/dev/null
wait_for "active widget registers and creates two screen items" '[[ $(state "$active_widget_id" 2>/dev/null | jq -r "(.widgetRegistered and .screenItems == 2)" || true) == true ]]'

shell_ipc shell gateTransactionPlugin "$service_operation" "$service_id" >/dev/null
if [[ $EXPECTATION == published-vulnerable ]]; then
  wait_for "published service unload acknowledges invisible pending callback" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == gate-installed-unload-acknowledged ]]'
  pass "published head reproduces invisible pending service acknowledgement"
  pass "published-head control stops before its independent projection-output defect"
  exit 0
else
  wait_for "corrected service pending load withholds acknowledgement" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == unload-incomplete ]]'
  [[ $(state "$service_id" | jq -r .pendingService) == true ]] || fail "corrected shell records pending service ownership"
  pass "pending service ownership withholds unload acknowledgement"
fi

shell_ipc shell testReleaseUnload "$service_id" >/dev/null
wait_for "service unload eventually acknowledges after invalidation" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == gate-installed-unload-acknowledged ]]'

shell_ipc shell rescanGatedPlugin "$service_operation" "$service_id" >/dev/null
wait_for "service gated rescan completes" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == gated-rescan-complete ]]'
if [[ $EXPECTATION == published-vulnerable ]]; then
  shell_ipc shell releaseTransactionPlugin "$service_operation" "$service_id" >/dev/null
  wait_for "service conditional release completes" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == released ]]'
else
  gated_generation=$(state "$service_id" | jq -r .gate.generation)
  [[ $(shell_ipc shell testOrdinaryRescan) == started ]] || fail "ordinary generation-advance scan did not start"
  wait_for "ordinary rescan advances current registry generation" '(( $(state "$service_id" 2>/dev/null | jq -r .registryGeneration || echo 0) > gated_generation ))'
  shell_ipc shell releaseTransactionPlugin "$service_operation" "$service_id" >/dev/null
  if [[ $EXPECTATION == broken-current-generation ]]; then
    wait_for "negative control releases against a stale registry generation" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == released ]]'
    pass "generation-guard negative control reproduces stale release"
    exit 0
  fi
  wait_for "stale generation retains service gate before projection" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == release-retained ]]'
  [[ $(state "$service_id" | jq -r .gate.state) == RESCAN_ACKNOWLEDGED ]] || fail "stale pre-projection generation removed the gate"
  pass "current registry generation is required before release comparison"

  shell_ipc shell rescanGatedPlugin "$service_operation" "$service_id" >/dev/null
  wait_for "fresh service gated rescan replaces stale generation" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == gated-rescan-complete && $(state "$service_id" 2>/dev/null | jq -r ".gate.generation == .registryGeneration") == true ]]'

  : >"$OMARCHY_LIFECYCLE_HOLD_PROJECTION"
  shell_ipc shell releaseTransactionPlugin "$service_operation" "$service_id" >/dev/null
  wait_for "projection completion reaches deterministic barrier" '[[ -e $OMARCHY_LIFECYCLE_PROJECTION_READY ]]'
  shell_ipc shell testBumpConfigurationEpoch >/dev/null
  printf 'resume\n' >"$OMARCHY_LIFECYCLE_PROJECTION_RESUME"
  rm -f "$OMARCHY_LIFECYCLE_HOLD_PROJECTION" "$OMARCHY_LIFECYCLE_PROJECTION_READY"
  wait_for "configuration epoch change during projection retains gate" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == release-precondition-mismatch ]]'
  [[ $(state "$service_id" | jq -r .gate.state) == RESCAN_ACKNOWLEDGED ]] || fail "projection-epoch mismatch removed the gate"
  pass "configuration epoch remains bound through projection completion"

  : >"$OMARCHY_LIFECYCLE_HOLD_AUTHORIZE_BEFORE"
  shell_ipc shell releaseTransactionPlugin "$service_operation" "$service_id" >/dev/null
  wait_for "native authorization reaches pre-call barrier" '[[ -e $OMARCHY_LIFECYCLE_AUTHORIZE_BEFORE_READY ]]'
  shell_ipc shell testBumpConfigurationEpoch >/dev/null
  printf 'resume\n' >"$OMARCHY_LIFECYCLE_AUTHORIZE_BEFORE_RESUME"
  rm -f "$OMARCHY_LIFECYCLE_HOLD_AUTHORIZE_BEFORE" "$OMARCHY_LIFECYCLE_AUTHORIZE_BEFORE_READY"
  wait_for "post-projection epoch change returns durable gate to unload-acknowledged" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == release-retained && $(state "$service_id" 2>/dev/null | jq -r .gate.state) == UNLOAD_ACKNOWLEDGED ]]'
  pass "post-projection authority change is recoverably fail closed"

  shell_ipc shell rescanGatedPlugin "$service_operation" "$service_id" >/dev/null
  wait_for "service rescan completes after retained authorization" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == gated-rescan-complete ]]'
  gated_generation=$(state "$service_id" | jq -r .gate.generation)
  : >"$OMARCHY_LIFECYCLE_HOLD_AUTHORIZE_AFTER"
  shell_ipc shell releaseTransactionPlugin "$service_operation" "$service_id" >/dev/null
  wait_for "native release authorization reaches post-write barrier" '[[ -e $OMARCHY_LIFECYCLE_AUTHORIZE_AFTER_READY ]]'
  [[ $(shell_ipc shell testOrdinaryRescan) == started ]] || fail "post-authorization generation scan did not start"
  wait_for "registry generation advances after native authorization" '(( $(state "$service_id" 2>/dev/null | jq -r .registryGeneration || echo 0) > gated_generation ))'
  printf 'resume\n' >"$OMARCHY_LIFECYCLE_AUTHORIZE_AFTER_RESUME"
  rm -f "$OMARCHY_LIFECYCLE_HOLD_AUTHORIZE_AFTER" "$OMARCHY_LIFECYCLE_AUTHORIZE_AFTER_READY"
  wait_for "post-authorization generation change restores blocking rescan state" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == release-retained && $(state "$service_id" 2>/dev/null | jq -r .gate.state) == UNLOAD_ACKNOWLEDGED ]]'
  pass "post-native generation change cannot publish eligibility"

  shell_ipc shell rescanGatedPlugin "$service_operation" "$service_id" >/dev/null
  wait_for "final service gated rescan completes" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == gated-rescan-complete ]]'
  shell_ipc shell releaseTransactionPlugin "$service_operation" "$service_id" >/dev/null
  wait_for "service conditional release completes" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == released ]]'
fi
wait_for "post-release service load reaches a newer barrier" '(( $(state "$service_id" 2>/dev/null | jq -r .deferredService || echo 0) >= 2 ))'
shell_ipc shell testResumeDeferredService "$service_id" 0 >/dev/null

if [[ $EXPECTATION == broken-token-guards ]]; then
  wait_for "negative-control stale service callback creates object after release" '[[ -f $service_marker && $(cat "$service_marker") == *created* ]]'
  pass "token-guard negative control reproduces stale service completion"
else
  [[ ! -e $service_marker ]] || fail "stale corrected service callback created an object"
  lifecycle=$(state "$service_id")
  [[ $(jq -r .serviceActive <<<"$lifecycle") == false && $(jq -r .pendingService <<<"$lifecycle") == true ]] ||
    fail "stale service callback preserves the newer pending owner"
  pass "invalidated service callback cannot publish or replace newer ownership"
fi

shell_ipc shell testHoldNextUnload >/dev/null
shell_ipc shell gateTransactionPlugin "$widget_operation" "$widget_id" >/dev/null
wait_for "widget pending load withholds unload acknowledgement" '[[ $(transaction_status "$widget_operation" 2>/dev/null || true) == unload-incomplete ]]'
shell_ipc shell testReleaseUnload "$widget_id" >/dev/null
wait_for "widget unload acknowledges after invalidation" '[[ $(transaction_status "$widget_operation" 2>/dev/null || true) == gate-installed-unload-acknowledged ]]'
shell_ipc shell rescanGatedPlugin "$widget_operation" "$widget_id" >/dev/null
wait_for "widget gated rescan completes" '[[ $(transaction_status "$widget_operation" 2>/dev/null || true) == gated-rescan-complete ]]'
shell_ipc shell releaseTransactionPlugin "$widget_operation" "$widget_id" >/dev/null
wait_for "widget release completes" '[[ $(transaction_status "$widget_operation" 2>/dev/null || true) == released ]]'
wait_for "post-release widget load reaches newer barrier" '(( $(state "$widget_id" 2>/dev/null | jq -r .deferredWidget || echo 0) >= 2 ))'
shell_ipc shell testResumeDeferredWidget "$widget_id" 0 >/dev/null

if [[ $EXPECTATION == broken-token-guards ]]; then
  wait_for "negative-control stale widget callback registers" '[[ $(state "$widget_id" 2>/dev/null | jq -r .widgetRegistered || true) == true ]]'
  wait_for "negative-control stale widget callback creates both screen items" '[[ $(state "$widget_id" 2>/dev/null | jq -r .screenItems || echo 0) == 2 ]]'
  pass "token-guard negative control reproduces stale widget registration"
else
  lifecycle=$(state "$widget_id")
  [[ $(jq -r .widgetRegistered <<<"$lifecycle") == false && $(jq -r .screenItems <<<"$lifecycle") == 0 ]] ||
    fail "stale corrected widget callback registered or instantiated"
  [[ $(jq -r .pendingWidget <<<"$lifecycle") == true ]] || fail "stale widget callback replaced newer ownership"
  pass "invalidated widget callback cannot register or instantiate per-screen owners"

  shell_ipc shell testResumeDeferredWidget "$widget_id" 1 >/dev/null
  wait_for "legitimate widget generation registers" '[[ $(state "$widget_id" 2>/dev/null | jq -r .widgetRegistered || true) == true ]]'
  if [[ $EXPECTATION == duplicate-screen-loader ]]; then
    wait_for "duplicate-screen negative control creates a third same-generation item" '[[ $(state "$widget_id" 2>/dev/null | jq -r .screenItems || echo 0) == 3 ]]'
    wait_for "duplicate-screen negative control runs all three QML objects" '[[ $(marker_count "$widget_marker" created) == 3 ]]'
    duplicate_warnings=$(grep -F 'another handler is registered for target acme.lifecycle_fixture/1' "$log" | wc -l)
    (( duplicate_warnings == 2 )) || fail "duplicate-screen control expected two collisions, saw $duplicate_warnings"
    pass "actual QML duplicate-screen control detects one extra same-generation load"
    exit 0
  fi
  wait_for "legitimate widget generation creates two screen items" '[[ $(state "$widget_id" 2>/dev/null | jq -r .screenItems || echo 0) == 2 ]]'
  shell_ipc shell testUnloadNow "$widget_id" >/dev/null
  wait_for "both per-screen widget items are destroyed" '[[ $(state "$widget_id" 2>/dev/null | jq -r .screenItems || echo 2) == 0 ]]'
  wait_for "both per-screen fixture IPC owners report destruction" '[[ $(marker_count "$widget_marker" destroyed) == 2 ]]'
  wait_for "fixture IPC target is released after per-screen destruction" '! shell_ipc acme.lifecycle_fixture/1 ping >/dev/null 2>&1'
  pass "first valid widget generation releases both per-screen IPC owners"

  for generation in 2 3; do
    callback_index=$generation
    shell_ipc shell testSyncWidgets >/dev/null
    wait_for "valid widget generation $generation reaches its completion barrier" "(( \$(state \"$widget_id\" 2>/dev/null | jq -r .deferredWidget || echo 0) > $callback_index ))"
    shell_ipc shell testResumeDeferredWidget "$widget_id" "$callback_index" >/dev/null
    wait_for "valid widget generation $generation creates two screen items" '[[ $(state "$widget_id" 2>/dev/null | jq -r .screenItems || echo 0) == 2 ]]'
    wait_for "valid widget generation $generation evaluates exactly twice" "[[ \$(marker_count \"$widget_marker\" created) == $((generation * 2)) ]]"
    shell_ipc shell testUnloadNow "$widget_id" >/dev/null
    wait_for "valid widget generation $generation destroys both screen items" '[[ $(state "$widget_id" 2>/dev/null | jq -r .screenItems || echo 2) == 0 ]]'
    wait_for "valid widget generation $generation releases its IPC target" '! shell_ipc acme.lifecycle_fixture/1 ping >/dev/null 2>&1'
  done
  wait_for "three valid widget generations report six destruction events" '[[ $(marker_count "$widget_marker" destroyed) == 6 ]]'
  pass "three sequential valid widget generations are isolated and evaluated independently"

  shell_ipc shell testHoldNextUnload >/dev/null
  shell_ipc shell gateTransactionPlugin "$active_service_operation" "$active_service_id" >/dev/null
  wait_for "active service withholds unload acknowledgement" '[[ $(transaction_status "$active_service_operation" 2>/dev/null || true) == unload-incomplete ]]'
  [[ $(state "$active_service_id" | jq -r .serviceOwnerActive) == true ]] || fail "active service owner vanished before unload"
  shell_ipc shell testReleaseUnload "$active_service_id" >/dev/null
  wait_for "active service owner destruction is acknowledged" '[[ $(transaction_status "$active_service_operation" 2>/dev/null || true) == gate-installed-unload-acknowledged ]]'
  lifecycle=$(state "$active_service_id")
  [[ $(jq -r .serviceActive <<<"$lifecycle") == false && $(jq -r .serviceOwnerActive <<<"$lifecycle") == false ]] ||
    fail "service unload acknowledged while active ownership remained"
  wait_for "active service reports object destruction" '[[ $(marker_count "$active_service_marker" destroyed) == 1 ]]'
  pass "active service destruction precedes unload acknowledgement"

  shell_ipc shell testHoldNextUnload >/dev/null
  shell_ipc shell gateTransactionPlugin "$active_widget_operation" "$active_widget_id" >/dev/null
  wait_for "per-screen widget destruction permits unload acknowledgement" '[[ $(transaction_status "$active_widget_operation" 2>/dev/null || true) == gate-installed-unload-acknowledged ]]'
  if [[ $EXPECTATION == broken-screen-accounting ]]; then
    [[ $(state "$active_widget_id" | jq -r .screenItems) == 2 ]] || fail "screen-accounting negative control did not retain both items"
    pass "screen-accounting negative control reproduces acknowledgement with retained items"
    exit 0
  fi
  [[ $(state "$active_widget_id" | jq -r .screenItems) == 0 ]] || fail "widget unload acknowledged with a retained per-screen item"
  wait_for "active widget reports both destruction events" '[[ $(marker_count "$active_widget_marker" destroyed) == 2 ]]'
  wait_for "active-widget IPC target is released" '! shell_ipc acme.lifecycle_active_fixture/2 ping >/dev/null 2>&1'
  pass "per-screen Loader and IPC teardown precedes gate acknowledgement"

  shell_ipc shell testHoldNextUnload >/dev/null
  shell_ipc shell testSelectBar "$selected_bar_operation" "$selected_bar_id" >/dev/null
  wait_for "selected third-party bar reports Loader.Loading and requests its real gate" '[[ $(state "$selected_bar_id" 2>/dev/null | jq -r "(.selectedBarSawLoading and .selectedBarGateRequested)" || true) == true ]]'
  wait_for "selected bar Loading state is cancelled before acknowledgement" '[[ $(transaction_status "$selected_bar_operation" 2>/dev/null || true) == gate-installed-unload-acknowledged ]]'
  lifecycle=$(state "$selected_bar_id")
  [[ $(jq -r .selectedBarActive <<<"$lifecycle") == false
    && $(jq -r .selectedBarLoading <<<"$lifecycle") == false
    && $(jq -r .selectedBarItem <<<"$lifecycle") == false
    && -z $(jq -r .selectedBarSource <<<"$lifecycle") ]] || fail "selected bar remained retained after gate acknowledgement"
  pass "actual pluginBarLoader cancellation is acknowledged only after Loading clears"

  first_shell_instance=$(state "$service_id" | jq -r .shellInstance)
  [[ $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/gates/$service_id.gate") == RELEASE_AUTHORIZED ]] ||
    fail "successful release did not leave a conservative restart record"
  kill "$QS_PID"
  wait "$QS_PID" || true
  QS_PID=""
  quickshell -p "$test_root/shell" --no-color >>"$log" 2>&1 &
  QS_PID=$!
  wait_for "restarted isolated shell accepts IPC" '[[ $(shell_ipc shell ping 2>/dev/null || true) == ok ]]'
  wait_for "restart inventory becomes authoritative" '[[ $(state "$service_id" 2>/dev/null | jq -r .inventoryReady || true) == true ]]'
  wait_for "release-authorized restart returns to blocking unload state" '[[ $(state "$service_id" 2>/dev/null | jq -r .gate.state || true) == UNLOAD_ACKNOWLEDGED ]]'
  second_shell_instance=$(state "$service_id" | jq -r .shellInstance)
  [[ -n $first_shell_instance && -n $second_shell_instance && $first_shell_instance != "$second_shell_instance" ]] ||
    fail "shell restart reused its opaque instance identity"
  [[ ! -e $service_marker ]] || fail "restart loaded the conservatively re-gated service"
  pass "fresh shell instance reconciles release authorization to a durable blocking gate"
fi

[[ ${WAYLAND_DISPLAY:-} == "" && ${HYPRLAND_INSTANCE_SIGNATURE:-} == "" ]] || fail "lifecycle test stayed off the live desktop"
pass "plugin gate lifecycle ran in an isolated offscreen Quickshell"
