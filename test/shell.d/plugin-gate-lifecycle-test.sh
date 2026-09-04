#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

SOURCE_ROOT=${OMARCHY_LIFECYCLE_SOURCE_ROOT:-$ROOT}
EXPECTATION=${OMARCHY_LIFECYCLE_EXPECTATION:-corrected}
FIXTURE_ROOT="$ROOT/test/shell.d/fixtures/plugin-gate-lifecycle"
TMPDIR=""
QS_PID=""

cleanup() {
  if [[ -n ${REPLAY_OWNER_PID:-} ]] && kill -0 "$REPLAY_OWNER_PID" 2>/dev/null; then
    if declare -F kill_process_tree >/dev/null 2>&1; then
      kill_process_tree "$REPLAY_OWNER_PID" || true
    else
      kill "$REPLAY_OWNER_PID" 2>/dev/null || true
    fi
    wait "$REPLAY_OWNER_PID" 2>/dev/null || true
  fi
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
NODE_BIN=$(mise which node)

TMPDIR=$(mktemp -d)
REPLAY_OWNER_PID=""
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
# The O-8 terminal handoff mode invokes the production transaction wrapper.
# Give it a copied package root so package-relative helpers and shell IPC target
# the same isolated offscreen shell as this harness.
if [[ $EXPECTATION == o8-terminal-reviewed || $EXPECTATION == o8-terminal-corrected || $EXPECTATION == o8-terminal-receipt-failure || $EXPECTATION == o8-dispatch-replay || $EXPECTATION == o8-rollback || $EXPECTATION == o8-load-gated-authority ]]; then
  rm "$test_root/bin"
  mkdir "$test_root/bin"
  cp "$SOURCE_ROOT/bin/omarchy-plugin-transaction" "$SOURCE_ROOT/bin/omarchy-shell" \
    "$SOURCE_ROOT/bin/omarchy-plugin-validate" "$test_root/bin/"
  cp "$FIXTURE_ROOT/omarchy-shell-any-display" "$test_root/bin/omarchy-shell"
  chmod 0755 "$test_root/bin/omarchy-shell"
fi
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
elif [[ $EXPECTATION == o8-terminal-reviewed ]]; then
  OMARCHY_LIFECYCLE_BREAK_TERMINAL_HANDOFF=1 mise exec -- node "$FIXTURE_ROOT/instrument-copy.mjs" "$test_root/shell/shell.qml"
else
  mise exec -- node "$FIXTURE_ROOT/instrument-copy.mjs" "$test_root/shell/shell.qml"
fi
mise exec -- clang -std=c17 -Wall -Wextra -Werror -Wconversion -Wshadow -O2 \
  -DOMARCHY_PLUGIN_TREE_TEST_HOOKS \
  "$SOURCE_ROOT/native/plugin-transaction/plugin-tree.c" -o "$helper"
if [[ $EXPECTATION == o8-terminal-reviewed || $EXPECTATION == o8-terminal-corrected || $EXPECTATION == o8-terminal-receipt-failure || $EXPECTATION == o8-dispatch-replay || $EXPECTATION == o8-rollback || $EXPECTATION == o8-load-gated-authority ]]; then
  cp "$helper" "$test_root/native/plugin-transaction/plugin-tree"
fi
if [[ $EXPECTATION == o8-load-gated-authority ]]; then
  mv "$test_root/native/plugin-transaction/plugin-tree" "$test_root/native/plugin-transaction/plugin-tree.real"
  cat >"$test_root/native/plugin-transaction/plugin-tree" <<'SH'
#!/bin/bash
set -euo pipefail
tmp_root=$(cd "$(dirname "$0")/../../.." && pwd)
hold="$tmp_root/runtime/omarchy-o8-load-gated/hold-before-namespace"
ready="$tmp_root/runtime/omarchy-o8-load-gated/namespace-ready"
resume="$tmp_root/runtime/omarchy-o8-load-gated/namespace-resume"
if [[ ${1:-} == namespace-mutate && -e "$hold" ]]; then
  : >"$ready"
  IFS= read -r _ <"$resume"
fi
exec "${0}.real" "$@"
SH
  chmod 0755 "$test_root/native/plugin-transaction/plugin-tree"
fi

service_id=acme.lifecycle-service
active_service_id=acme.lifecycle-active-service
widget_id=acme.lifecycle-widget
active_widget_id=acme.lifecycle-active-widget
selected_bar_id=acme.lifecycle-selected-bar
indeterminate_id=acme.lifecycle-indeterminate
o8_terminal_id=acme.lifecycle-o8-terminal
o8_replay_live_id=acme.lifecycle-o8-replay-live
o8_replay_rescan_id=acme.lifecycle-o8-replay-rescan
o8_replay_release_id=acme.lifecycle-o8-replay-release
o8_load_id=acme.lifecycle-o8-load-gated
for plugin in "$service_id" "$active_service_id" "$widget_id" "$active_widget_id" "$selected_bar_id" "$indeterminate_id" "$o8_terminal_id"; do
  live="$plugin_dir/$plugin"
  candidate="$TMPDIR/candidate-$plugin"
  mkdir -p "$live" "$candidate"
  if [[ $plugin == "$active_service_id" ]]; then
    cp "$FIXTURE_ROOT/ActiveService.qml" "$live/Service.qml"
    jq --arg id "$plugin" '.id=$id | .kinds=["service"] | .entryPoints={service:"Service.qml"}' \
      "$FIXTURE_ROOT/manifest.json" >"$live/manifest.json"
  elif [[ $plugin == "$service_id" || $plugin == "$indeterminate_id" || $plugin == "$o8_terminal_id" ]]; then
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

# Fresh-process dispatch cases use inert install candidates outside discovery.
# They are intentionally not inserted into the live-plugin fixture above, so
# the authoritative shell observation reports exact absence for each case.
for plugin in "$o8_replay_live_id" "$o8_replay_rescan_id" "$o8_replay_release_id"; do
  candidate="$TMPDIR/candidate-$plugin"
  mkdir -p "$candidate"
  cp "$FIXTURE_ROOT/Service.qml" "$candidate/Service.qml"
  jq --arg id "$plugin" '.id=$id | .kinds=["service"] | .entryPoints={service:"Service.qml"}' \
    "$FIXTURE_ROOT/manifest.json" >"$candidate/manifest.json"
done

# This operation is a fresh install: retain the source outside discovery while
# the active destination is absent.  The ordinary lifecycle cases keep their
# pre-existing active fixtures.
if [[ $EXPECTATION == o8-terminal-reviewed || $EXPECTATION == o8-terminal-corrected || $EXPECTATION == o8-terminal-receipt-failure || $EXPECTATION == o8-dispatch-replay || $EXPECTATION == o8-rollback || $EXPECTATION == o8-load-gated-authority ]]; then
  rm -rf "$plugin_dir/$o8_terminal_id"
fi

jq -n --arg service "$service_id" --arg widget "$widget_id" '{
  version:1,
  bar:{layout:{left:[],center:[{id:$widget}],right:[]}},
  plugins:[{id:$service}]
}' >"$config_file"
jq --arg plugin "$active_service_id" '.plugins += [{id:$plugin}]' "$config_file" >"$config_file.next"
mv "$config_file.next" "$config_file"
jq --arg plugin "$active_widget_id" '.bar.layout.center += [{id:$plugin}]' "$config_file" >"$config_file.next"
mv "$config_file.next" "$config_file"
initial_config="$TMPDIR/initial-shell.json"
cp "$config_file" "$initial_config"
unrelated_config="$TMPDIR/unrelated-shell.json"
jq '.bar.floating = true' "$initial_config" >"$unrelated_config"

projection_digest() {
  local plugin=$1
  ROOT="$SOURCE_ROOT" CONFIG="$config_file" PLUGIN="$plugin" "$NODE_BIN" <<'JS'
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
    OMARCHY_PLUGIN_EXPECTED_CONFIG_SOURCE_KIND=user OMARCHY_PLUGIN_EXPECTED_CONFIG_SOURCE_IDENTITY=omarchy-shell-config:user:v1 \
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
indeterminate_operation=61000000-0000-4000-8000-000000000006
stage_operation "$service_operation" "$service_id"
stage_operation "$widget_operation" "$widget_id"
stage_operation "$active_service_operation" "$active_service_id"
stage_operation "$selected_bar_operation" "$selected_bar_id"
stage_operation "$active_widget_operation" "$active_widget_id"
stage_operation "$indeterminate_operation" "$indeterminate_id"
initial_service_projection=$(projection_digest "$service_id")

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
export OMARCHY_LIFECYCLE_HOLD_TERMINAL_RECEIPT="$TMPDIR/hold-terminal-receipt"
export OMARCHY_LIFECYCLE_TERMINAL_RECEIPT_READY="$TMPDIR/terminal-receipt-ready"
export OMARCHY_LIFECYCLE_TERMINAL_RECEIPT_RESUME="$TMPDIR/terminal-receipt-resume"
if [[ $EXPECTATION == o8-terminal-receipt-failure ]]; then
  export OMARCHY_LIFECYCLE_FAIL_TERMINAL_RECEIPT=1
fi
export OMARCHY_LIFECYCLE_HOLD_SCAN="$TMPDIR/hold-scan"
export OMARCHY_LIFECYCLE_SCAN_READY="$TMPDIR/scan-ready"
export OMARCHY_LIFECYCLE_SCAN_RESUME="$TMPDIR/scan-resume"
export OMARCHY_LIFECYCLE_HOLD_BEFORE_RESCAN=0
replay_runtime="$runtime_dir/omarchy-o8-replay"
mkdir -p "$replay_runtime"
export OMARCHY_LIFECYCLE_HOLD_BEFORE_RESCAN="$replay_runtime/hold-before-rescan"
export OMARCHY_LIFECYCLE_BEFORE_RESCAN_READY="$replay_runtime/before-rescan-ready"
export OMARCHY_LIFECYCLE_BEFORE_RESCAN_RESUME="$replay_runtime/before-rescan-resume"
export OMARCHY_LIFECYCLE_HOLD_AFTER_RESCAN=0
export OMARCHY_LIFECYCLE_AFTER_RESCAN_READY="$replay_runtime/after-rescan-ready"
export OMARCHY_LIFECYCLE_AFTER_RESCAN_RESUME="$replay_runtime/after-rescan-resume"
export OMARCHY_LIFECYCLE_HOLD_BEFORE_RELEASE=0
export OMARCHY_LIFECYCLE_BEFORE_RELEASE_READY="$replay_runtime/before-release-ready"
export OMARCHY_LIFECYCLE_BEFORE_RELEASE_RESUME="$replay_runtime/before-release-resume"
export OMARCHY_LIFECYCLE_REPLAY_OPERATION=
export OMARCHY_LIFECYCLE_REPLAY_PLUGIN=
export OMARCHY_LIFECYCLE_INDETERMINATE_OPERATION="$indeterminate_operation"
export OMARCHY_LIFECYCLE_INJECT_INSTALL_PARENT_FSYNC="$TMPDIR/inject-install-parent-fsync"
export OMARCHY_LIFECYCLE_FAIL_GATED_RESCAN="$runtime_dir/omarchy-fail-gated-rescan"
export OMARCHY_LIFECYCLE_FAIL_TERMINAL_RECEIPT_MARKER="$runtime_dir/omarchy-fail-terminal-receipt"
mkfifo "$OMARCHY_LIFECYCLE_PROJECTION_RESUME" "$OMARCHY_LIFECYCLE_AUTHORIZE_BEFORE_RESUME" \
  "$OMARCHY_LIFECYCLE_AUTHORIZE_AFTER_RESUME" "$OMARCHY_LIFECYCLE_TERMINAL_RECEIPT_RESUME" \
  "$OMARCHY_LIFECYCLE_SCAN_RESUME"
mkfifo "$OMARCHY_LIFECYCLE_BEFORE_RESCAN_RESUME" "$OMARCHY_LIFECYCLE_AFTER_RESCAN_RESUME" \
  "$OMARCHY_LIFECYCLE_BEFORE_RELEASE_RESUME"
export QT_QPA_PLATFORM=offscreen
if [[ $EXPECTATION == o8-terminal-reviewed || $EXPECTATION == o8-terminal-corrected || $EXPECTATION == o8-terminal-receipt-failure || $EXPECTATION == o8-dispatch-replay || $EXPECTATION == o8-rollback || $EXPECTATION == o8-load-gated-authority ]]; then
  # The production wrapper forwards WAYLAND_DISPLAY (but not DISPLAY) to qs;
  # retain the isolated harness's display identity so its real QML process is
  # discoverable without contacting the desktop shell.
  export WAYLAND_DISPLAY=${OMARCHY_TEST_WAYLAND_DISPLAY:-wayland-1}
else
  export WAYLAND_DISPLAY=
fi
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
  # Quickshell startup and the real QML action-process callbacks can be
  # delayed when this fixture runs after the complete shell aggregate.  Keep
  # one explicit bounded deadline while retaining deterministic FIFO barriers
  # as the ordering proof.
  for _ in {1..500}; do
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
wait_for "production transaction observation reaches ready authoritative inventory" \
  '[[ $(shell_ipc shell transactionStageObservation "$service_id" 2>/dev/null | jq -r .valid || true) == true ]]'
stage_observation=$(shell_ipc shell transactionStageObservation "$service_id")
jq -e --arg plugin "$service_id" --arg discovery "$plugin_dir" \
    --arg state "$state_dir/omarchy/plugin-transactions-v1" '
  .schema == "omarchy-plugin-stage-observation/v1"
  and .status == "observed"
  and .pluginId == $plugin
  and .configurationSource == {kind:"user",identity:"omarchy-shell-config:user:v1"}
  and .referenceState == "referenced"
  and .activeDiscovery == {state:"present",sourceDirectory:($discovery + "/" + $plugin)}
  and .discoveryDirectory == $discovery
  and .transactionStateRoot == $state
' <<<"$stage_observation" >/dev/null || fail "production transaction observation did not expose exact O-6 authority"
observed_raw=$(jq -r .rawBase64 <<<"$stage_observation" | base64 -d | sha256sum | cut -d' ' -f1)
expected_raw=$(sha256sum "$config_file" | cut -d' ' -f1)
[[ $observed_raw == "$expected_raw" ]] || fail "production transaction observation raw bytes differ from accepted configuration"
observed_projection=sha256:$(jq -r .referenceProjectionBase64 <<<"$stage_observation" | base64 -d | sha256sum | cut -d' ' -f1)
[[ $observed_projection == "$initial_service_projection" ]] || fail "production transaction observation bypassed canonical projection"
pass "production stage observation uses the live accepted O-6 snapshot and canonical projection"

if [[ $EXPECTATION == o8-load-gated-authority ]]; then
  # Drive a real install through the production stage/commit route until its
  # durable LOAD_GATED image, then kill the coordinator before native exposure.
  # The next coordinator must obtain a fresh O-6 observation before it can
  # promote or mutate the namespace.
  o8_load_operation=63000000-0000-4000-8000-000000000010
  kill_process_tree() {
    local parent=$1 child
    for child in $(pgrep -P "$parent" 2>/dev/null || true); do
      kill_process_tree "$child"
    done
    kill "$parent" 2>/dev/null || true
  }
  o8_load_source="$TMPDIR/candidate-$o8_load_id"
  mkdir -p "$o8_load_source"
  cp "$FIXTURE_ROOT/Service.qml" "$o8_load_source/Service.qml"
  jq --arg id "$o8_load_id" '.id=$id | .kinds=["service"] | .entryPoints={service:"Service.qml"}' \
    "$FIXTURE_ROOT/manifest.json" >"$o8_load_source/manifest.json"
  o8_load_identity=$($helper identity "$o8_load_source")
  o8_load_projection=sha256:$(jq -r .referenceProjectionBase64 <<<"$(shell_ipc shell transactionStageObservation "$o8_load_id")" | base64 -d | sha256sum | cut -d' ' -f1)
  o8_load_token=QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE
  o8_load_request=$(jq -cn --arg operationId "$o8_load_operation" --arg token "$o8_load_token" \
    --arg pluginId "$o8_load_id" --arg source "$o8_load_source" \
    --arg digest "sha256:${o8_load_identity#omarchy-runtime-tree-sha256-v1:}" \
    --arg projection "$o8_load_projection" '{protocol:"legacy-schema-v1-transaction/v1",action:"stage",
      operationId:$operationId,operationToken:$token,operation:"install",pluginId:$pluginId,
      source:{kind:"directory",path:$source},candidateTree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$digest},
      expectedActive:{state:"absent"},expectedConfiguration:{source:{kind:"user",identity:"omarchy-shell-config:user:v1"},
      referenceProjectionSha256:$projection,referenceState:"unreferenced",referencePolicy:"require-unreferenced"}}')
  printf '%s' "$o8_load_request" | "$test_root/bin/omarchy-plugin-transaction" >/dev/null ||
    fail "LOAD_GATED authority stage was not accepted"
  load_runtime="$runtime_dir/omarchy-o8-load-gated"
  mkdir -p "$load_runtime"
  : >"$load_runtime/hold-before-namespace"
  rm -f "$load_runtime/namespace-ready" "$load_runtime/namespace-resume"
  mkfifo "$load_runtime/namespace-resume"
  o8_load_commit=$(jq -cn --arg operationId "$o8_load_operation" --arg token "$o8_load_token" \
    '{protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$operationId,operationToken:$token}')
  set +e
  printf '%s' "$o8_load_commit" | "$test_root/bin/omarchy-plugin-transaction" >"$TMPDIR/load-owner-result" 2>"$TMPDIR/load-owner-error" &
  load_owner=$!
  REPLAY_OWNER_PID=$load_owner
  set -e
  wait_for "LOAD_GATED namespace barrier" \
    '[[ -e $load_runtime/namespace-ready && $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/journals/$o8_load_operation.journal" 2>/dev/null || true) == LOAD_GATED ]] && kill -0 "$load_owner" 2>/dev/null'
  [[ $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/gates/$o8_load_id.gate") == UNLOAD_ACKNOWLEDGED ]] ||
    fail "LOAD_GATED image did not retain UNLOAD_ACKNOWLEDGED gate"
  [[ ! -e "$plugin_dir/$o8_load_id" && -d "$state_dir/omarchy/plugin-candidates-v1/$o8_load_operation/candidate" ]] ||
    fail "LOAD_GATED image was not inert"
  kill_process_tree "$load_owner"
  wait "$load_owner" 2>/dev/null || true
  REPLAY_OWNER_PID=""
  [[ $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/journals/$o8_load_operation.journal") == LOAD_GATED ]] ||
    fail "coordinator did not die at LOAD_GATED"
  rm -f "$load_runtime/hold-before-namespace" "$load_runtime/namespace-ready"
  rm -f "$load_runtime/namespace-resume"
  printf '%s\n' resume >"$load_runtime/namespace-resume" 2>/dev/null || true
  # A fresh coordinator with unchanged authority must reconcile and perform
  # exactly one forward mutation before continuing through the real shell.
  set +e
  printf '%s' "$o8_load_commit" | "$test_root/bin/omarchy-plugin-transaction" >"$TMPDIR/load-fresh-result" 2>"$TMPDIR/load-fresh-error"
  load_status=$?
  set -e
  (( load_status == 0 )) || { sed -n '1,120p' "$TMPDIR/load-fresh-error" >&2; cat "$TMPDIR/load-fresh-result" >&2; fail "fresh LOAD_GATED replay failed"; }
  jq -e --arg op "$o8_load_operation" '.operationId==$op and .state=="COMMITTED" and .status=="committed"' \
    "$TMPDIR/load-fresh-result" >/dev/null || fail "fresh unchanged LOAD_GATED replay did not commit"
  [[ -d "$plugin_dir/$o8_load_id" && $($helper identity "$plugin_dir/$o8_load_id") == "$o8_load_identity" ]] ||
    fail "fresh LOAD_GATED replay did not expose the exact candidate"
  pass "real-QML fresh LOAD_GATED replay obtains fresh authority and performs one forward mutation"

  # A second fresh LOAD_GATED image with an independently changed candidate
  # must remain gated and enter the documented post-gate recovery result.
  o8_load2_id=acme.lifecycle-o8-load-gated-changed
  o8_load2_operation=63000000-0000-4000-8000-000000000011
  o8_load2_source="$TMPDIR/candidate-$o8_load2_id"
  mkdir -p "$o8_load2_source"
  cp "$FIXTURE_ROOT/Service.qml" "$o8_load2_source/Service.qml"
  jq --arg id "$o8_load2_id" '.id=$id | .kinds=["service"] | .entryPoints={service:"Service.qml"}' \
    "$FIXTURE_ROOT/manifest.json" >"$o8_load2_source/manifest.json"
  o8_load2_identity=$($helper identity "$o8_load2_source")
  o8_load2_projection=$o8_load_projection
  o8_load2_token=QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI
  o8_load2_request=$(jq -cn --arg operationId "$o8_load2_operation" --arg token "$o8_load2_token" \
    --arg pluginId "$o8_load2_id" --arg source "$o8_load2_source" \
    --arg digest "sha256:${o8_load2_identity#omarchy-runtime-tree-sha256-v1:}" \
    --arg projection "$o8_load2_projection" '{protocol:"legacy-schema-v1-transaction/v1",action:"stage",
      operationId:$operationId,operationToken:$token,operation:"install",pluginId:$pluginId,
      source:{kind:"directory",path:$source},candidateTree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$digest},
      expectedActive:{state:"absent"},expectedConfiguration:{source:{kind:"user",identity:"omarchy-shell-config:user:v1"},
      referenceProjectionSha256:$projection,referenceState:"unreferenced",referencePolicy:"require-unreferenced"}}')
  printf '%s' "$o8_load2_request" | "$test_root/bin/omarchy-plugin-transaction" >/dev/null ||
    fail "changed-candidate LOAD_GATED stage was not accepted"
  : >"$load_runtime/hold-before-namespace"
  rm -f "$load_runtime/namespace-ready" "$load_runtime/namespace-resume"
  mkfifo "$load_runtime/namespace-resume"
  o8_load2_commit=$(jq -cn --arg operationId "$o8_load2_operation" --arg token "$o8_load2_token" \
    '{protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$operationId,operationToken:$token}')
  printf '%s' "$o8_load2_commit" | "$test_root/bin/omarchy-plugin-transaction" >"$TMPDIR/load2-owner-result" 2>"$TMPDIR/load2-owner-error" &
  load2_owner=$!
  REPLAY_OWNER_PID=$load2_owner
  wait_for "changed-candidate LOAD_GATED namespace barrier" \
    '[[ -e $load_runtime/namespace-ready && $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/journals/$o8_load2_operation.journal" 2>/dev/null || true) == LOAD_GATED ]] && kill -0 "$load2_owner" 2>/dev/null'
  kill_process_tree "$load2_owner"
  wait "$load2_owner" 2>/dev/null || true
  REPLAY_OWNER_PID=""
  printf '\nchanged-after-gate\n' >>"$state_dir/omarchy/plugin-candidates-v1/$o8_load2_operation/candidate/Service.qml"
  rm -f "$load_runtime/hold-before-namespace" "$load_runtime/namespace-ready" "$load_runtime/namespace-resume"
  set +e
  printf '%s' "$o8_load2_commit" | "$test_root/bin/omarchy-plugin-transaction" >"$TMPDIR/load2-fresh-result" 2>"$TMPDIR/load2-fresh-error"
  load2_status=$?
  set -e
  (( load2_status != 0 )) || fail "changed candidate falsely completed from LOAD_GATED"
  jq -e --arg op "$o8_load2_operation" '.operationId==$op and .state=="RECOVERY_REQUIRED" and .status=="indeterminate"' \
    "$TMPDIR/load2-fresh-result" >/dev/null || fail "changed candidate did not produce post-gate recovery result"
  # Gate B public-result authority is state-true: a recovery response must
  # retain the complete operation dimensions rather than collapsing to the
  # small generic error envelope.  This literal vector is independent of the
  # production jq response filter and is deliberately checked before any
  # broader matrix is attempted.
  jq -e --arg op "$o8_load2_operation" --arg plugin "$o8_load2_id" --arg reason "pre-exposure-stale-candidate" \
    '(.protocol == "legacy-schema-v1-transaction/v1")
     and (.action == "commit")
     and (.operationId == $op)
     and (.pluginId == $plugin)
     and (.state == "RECOVERY_REQUIRED")
     and (.status == "indeterminate")
     and (.reason == $reason)
     and (.operation == "install")
     and (.candidateTree.algorithm == "omarchy-runtime-tree-sha256-v1")
     and (.candidateTree.digest | type == "string")
     and (.previousTree.state == "absent")
     and (.observedActive == null)
     and (.filesystem.live == null)
     and (.filesystem.previous.state == "absent")
     and (.observedConfiguration.source.kind == "user")
     and (.configuration.before.source.kind == "user")
     and (.configuration.after == null)
     and (.registry.state == "not-requested")
     and (.release.outcome == "not-requested")
     and (.eligibility.durableOutcome == "indeterminate")
     and (.eligibility.currentShell == "not-observed")
     and (.rollback.state == "not-applicable")
     and (.recovery.state == "required")
     and (.recovery.reason == $reason)' \
    "$TMPDIR/load2-fresh-result" >/dev/null || fail "RECOVERY_REQUIRED response omitted state-true public dimensions"
  [[ ! -e "$plugin_dir/$o8_load2_id" ]] || fail "changed candidate was exposed"
  [[ $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/gates/$o8_load2_id.gate") == UNLOAD_ACKNOWLEDGED ]] ||
    fail "changed candidate lost its blocking gate"
  pass "real-QML fresh LOAD_GATED candidate change is fail-closed without mutation"
  exit 0
fi

if [[ $EXPECTATION == o8-dispatch-replay ]]; then
  declare -A replay_tokens replay_operations
  replay_operations[live]=63000000-0000-4000-8000-000000000001
  replay_operations[rescan]=63000000-0000-4000-8000-000000000002
  replay_operations[release]=63000000-0000-4000-8000-000000000003
  replay_tokens[live]=QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE
  replay_tokens[rescan]=QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI
  replay_tokens[release]=Q0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0M

  kill_process_tree() {
    local parent=$1 child
    for child in $(pgrep -P "$parent" 2>/dev/null || true); do
      kill_process_tree "$child"
    done
    kill "$parent" 2>/dev/null || true
  }

  stage_replay_install() {
    local phase=$1 plugin=$2 operation=${replay_operations[$1]} token=${replay_tokens[$1]}
    local source="$TMPDIR/candidate-$plugin" identity projection digest request
    identity=$($helper identity "$source")
    projection=$(jq -r .referenceProjectionBase64 <<<"$(shell_ipc shell transactionStageObservation "$plugin")" | base64 -d | sha256sum | cut -d' ' -f1)
    digest="sha256:${identity#omarchy-runtime-tree-sha256-v1:}"
    request=$(jq -cn --arg operationId "$operation" --arg token "$token" \
      --arg pluginId "$plugin" --arg source "$source" --arg digest "$digest" --arg projection "sha256:$projection" \
      '{protocol:"legacy-schema-v1-transaction/v1",action:"stage",operationId:$operationId,operationToken:$token,
        operation:"install",pluginId:$pluginId,source:{kind:"directory",path:$source},
        candidateTree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$digest},
        expectedActive:{state:"absent"},expectedConfiguration:{source:{kind:"user",identity:"omarchy-shell-config:user:v1"},
        referenceProjectionSha256:$projection,referenceState:"unreferenced",referencePolicy:"require-unreferenced"}}')
    printf '%s' "$request" | "$test_root/bin/omarchy-plugin-transaction" >"$TMPDIR/$phase-stage-result" ||
      fail "$phase replay stage did not create an inert operation"
    jq -e --arg op "$operation" --arg plugin "$plugin" \
      '.operationId==$op and .pluginId==$plugin and .state=="STAGED"' \
      "$TMPDIR/$phase-stage-result" >/dev/null || fail "$phase replay stage result was not STAGED"
  }

  fresh_commit_replay() {
    local phase=$1 plugin=$2 operation=${replay_operations[$1]} token=${replay_tokens[$1]}
    local request result status
    request=$(jq -cn --arg operationId "$operation" --arg token "$token" \
      '{protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$operationId,operationToken:$token}')
    set +e
    result=$(printf '%s' "$request" | "$test_root/bin/omarchy-plugin-transaction" 2>"$TMPDIR/$phase-fresh-error")
    status=$?
    set -e
    if (( status != 0 )); then
      sed -n '1,120p' "$TMPDIR/$phase-fresh-error" >&2
      jq -c '{state,operationBindingSha256,namespaceIntent,rescan,release}' "$state_dir/omarchy/plugin-transactions-v1/journals/$operation.journal" >&2 2>/dev/null || true
      jq -c '{state,operationBindingSha256,expected,rescan,release}' "$state_dir/omarchy/plugin-transactions-v1/gates/$plugin.gate" >&2 2>/dev/null || true
      printf 'fresh-shell-state: ' >&2
      shell_ipc shell testLifecycleState "$plugin" >&2 || true
      fail "$phase fresh commit replay failed"
    fi
    jq -e --arg op "$operation" --arg plugin "$plugin" \
      '.operationId==$op and .pluginId==$plugin and .state=="COMMITTED" and .status=="committed" and .eligibility.durableOutcome=="authorized"' \
      <<<"$result" >/dev/null || fail "$phase fresh replay did not produce a released COMMITTED result"
    [[ $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/journals/$operation.journal") == COMMITTED ]] ||
      fail "$phase fresh replay did not durably reach COMMITTED"
    pass "$phase replay resumes from the durable state in a fresh coordinator"
  }

  [[ $(shell_ipc shell testStopLocalPluginWatcher) == stopping ]] || fail "replay watcher stop was not requested"
  wait_for "replay watcher stops" '[[ $(state "$service_id" 2>/dev/null | jq -r .pluginWatcherRunning || true) == false ]]'

  stage_replay_install live "$o8_replay_live_id"
  export OMARCHY_LIFECYCLE_REPLAY_OPERATION="${replay_operations[live]}"
  export OMARCHY_LIFECYCLE_REPLAY_PLUGIN="$o8_replay_live_id"
  printf '%s' "${replay_operations[live]}" >"$replay_runtime/operation"
  printf '%s' "$o8_replay_live_id" >"$replay_runtime/plugin"
  : >"$OMARCHY_LIFECYCLE_HOLD_BEFORE_RESCAN"
  rm -f "$OMARCHY_LIFECYCLE_BEFORE_RESCAN_READY"
  set +e
  printf '%s' "$(jq -cn --arg operationId "${replay_operations[live]}" --arg token "${replay_tokens[live]}" '{protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$operationId,operationToken:$token}')" |
    "$test_root/bin/omarchy-plugin-transaction" >"$TMPDIR/live-owner-result" 2>"$TMPDIR/live-owner-error" &
  owner_pid=$!
  REPLAY_OWNER_PID=$owner_pid
  set -e
  wait_for "LIVE_TREE_EXCHANGED replay barrier" '[[ -e $OMARCHY_LIFECYCLE_BEFORE_RESCAN_READY && $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/journals/${replay_operations[live]}.journal" 2>/dev/null || true) == LIVE_TREE_EXCHANGED ]] && kill -0 "$owner_pid" 2>/dev/null'
  [[ $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/gates/$o8_replay_live_id.gate") == UNLOAD_ACKNOWLEDGED ]] || fail "LIVE_TREE_EXCHANGED did not retain UNLOAD_ACKNOWLEDGED gate"
  kill_process_tree "$owner_pid"
  wait "$owner_pid" 2>/dev/null || true
  REPLAY_OWNER_PID=""
  rm -f "$OMARCHY_LIFECYCLE_HOLD_BEFORE_RESCAN" "$replay_runtime/operation" "$replay_runtime/plugin"
  rm -f "$OMARCHY_LIFECYCLE_BEFORE_RESCAN_READY"
  fresh_commit_replay live "$o8_replay_live_id"

  stage_replay_install rescan "$o8_replay_rescan_id"
  export OMARCHY_LIFECYCLE_REPLAY_OPERATION="${replay_operations[rescan]}"
  export OMARCHY_LIFECYCLE_REPLAY_PLUGIN="$o8_replay_rescan_id"
  printf '%s' "${replay_operations[rescan]}" >"$replay_runtime/operation"
  printf '%s' "$o8_replay_rescan_id" >"$replay_runtime/plugin"
  : >"$replay_runtime/hold-after-rescan"
  rm -f "$OMARCHY_LIFECYCLE_AFTER_RESCAN_READY"
  set +e
  printf '%s' "$(jq -cn --arg operationId "${replay_operations[rescan]}" --arg token "${replay_tokens[rescan]}" '{protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$operationId,operationToken:$token}')" |
    "$test_root/bin/omarchy-plugin-transaction" >"$TMPDIR/rescan-owner-result" 2>"$TMPDIR/rescan-owner-error" &
  owner_pid=$!
  REPLAY_OWNER_PID=$owner_pid
  set -e
  wait_for "GATED_RESCAN_COMPLETED replay barrier" '[[ -e $OMARCHY_LIFECYCLE_AFTER_RESCAN_READY && $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/journals/${replay_operations[rescan]}.journal" 2>/dev/null || true) == GATED_RESCAN_COMPLETED ]] && kill -0 "$owner_pid" 2>/dev/null'
  [[ $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/gates/$o8_replay_rescan_id.gate") == RESCAN_ACKNOWLEDGED ]] || fail "GATED_RESCAN_COMPLETED did not retain RESCAN_ACKNOWLEDGED gate"
  kill_process_tree "$owner_pid"
  wait "$owner_pid" 2>/dev/null || true
  REPLAY_OWNER_PID=""
  rm -f "$replay_runtime/hold-after-rescan" "$replay_runtime/operation" "$replay_runtime/plugin"
  rm -f "$OMARCHY_LIFECYCLE_AFTER_RESCAN_READY"
  fresh_commit_replay rescan "$o8_replay_rescan_id"

  stage_replay_install release "$o8_replay_release_id"
  export OMARCHY_LIFECYCLE_REPLAY_OPERATION="${replay_operations[release]}"
  export OMARCHY_LIFECYCLE_REPLAY_PLUGIN="$o8_replay_release_id"
  printf '%s' "${replay_operations[release]}" >"$replay_runtime/operation"
  printf '%s' "$o8_replay_release_id" >"$replay_runtime/plugin"
  : >"$replay_runtime/hold-before-release"
  rm -f "$OMARCHY_LIFECYCLE_BEFORE_RELEASE_READY"
  set +e
  printf '%s' "$(jq -cn --arg operationId "${replay_operations[release]}" --arg token "${replay_tokens[release]}" '{protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$operationId,operationToken:$token}')" |
    "$test_root/bin/omarchy-plugin-transaction" >"$TMPDIR/release-owner-result" 2>"$TMPDIR/release-owner-error" &
  owner_pid=$!
  REPLAY_OWNER_PID=$owner_pid
  set -e
  wait_for "RELEASE_PENDING replay barrier" '[[ -e $OMARCHY_LIFECYCLE_BEFORE_RELEASE_READY && $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/journals/${replay_operations[release]}.journal" 2>/dev/null || true) == RELEASE_PENDING ]] && kill -0 "$owner_pid" 2>/dev/null'
  [[ $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/gates/$o8_replay_release_id.gate") == RESCAN_ACKNOWLEDGED ]] || fail "RELEASE_PENDING did not retain RESCAN_ACKNOWLEDGED gate before release IPC"
  kill_process_tree "$owner_pid"
  wait "$owner_pid" 2>/dev/null || true
  REPLAY_OWNER_PID=""
  rm -f "$replay_runtime/hold-before-release" "$replay_runtime/operation" "$replay_runtime/plugin"
  rm -f "$OMARCHY_LIFECYCLE_BEFORE_RELEASE_READY"
  fresh_commit_replay release "$o8_replay_release_id"
  # A second newly started coordinator exercises terminal COMMITTED replay
  # and current-shell terminal-pair reconciliation without repeating release,
  # receipt, rescan, or namespace work.
  fresh_commit_replay release "$o8_replay_release_id"
  exit 0
fi

if [[ $EXPECTATION == o8-rollback ]]; then
  # Materialize the prior update target before the rollback scenario starts.
  # The real shell intentionally defers this service's completion so the
  # later update gate can prove actual unload acknowledgement.
  shell_ipc shell testResumeDeferredService "$active_service_id" 0 >/dev/null
  wait_for "real QML update target becomes active" '[[ $(state "$active_service_id" 2>/dev/null | jq -r .serviceActive || true) == true ]]'

  o8_source="$TMPDIR/candidate-$o8_terminal_id"
  o8_operation=62000000-0000-4000-8000-000000000004
  o8_identity=$($helper identity "$o8_source")
  o8_projection=sha256:$(jq -r .referenceProjectionBase64 <<<"$(shell_ipc shell transactionStageObservation "$o8_terminal_id")" | base64 -d | sha256sum | cut -d' ' -f1)
  o8_token=$(head -c 32 /dev/urandom | base64 -w0 | tr '+/' '-_' | tr -d '=')
  o8_request=$(jq -cn --arg operationId "$o8_operation" --arg token "$o8_token" \
    --arg pluginId "$o8_terminal_id" --arg source "$o8_source" \
    --arg digest "sha256:${o8_identity#omarchy-runtime-tree-sha256-v1:}" \
    --arg projection "$o8_projection" '{protocol:"legacy-schema-v1-transaction/v1",action:"stage",
      operationId:$operationId,operationToken:$token,operation:"install",pluginId:$pluginId,
      source:{kind:"directory",path:$source},candidateTree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$digest},
      expectedActive:{state:"absent"},expectedConfiguration:{source:{kind:"user",identity:"omarchy-shell-config:user:v1"},
      referenceProjectionSha256:$projection,referenceState:"unreferenced",referencePolicy:"require-unreferenced"}}')
  printf '%s' "$o8_request" | "$test_root/bin/omarchy-plugin-transaction" >/dev/null ||
    fail "real QML install rollback stage was not accepted"
  [[ $(shell_ipc shell testStopLocalPluginWatcher) == stopping ]] ||
    fail "real QML rollback harness could not stop the ordinary watcher"
  : >"$OMARCHY_LIFECYCLE_FAIL_GATED_RESCAN"
  o8_commit=$(jq -cn --arg operationId "$o8_operation" --arg token "$o8_token" \
    '{protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$operationId,operationToken:$token}')
  set +e
  printf '%s' "$o8_commit" | "$test_root/bin/omarchy-plugin-transaction" >"$TMPDIR/o8-rollback-install-result" 2>"$TMPDIR/o8-rollback-install-error"
  o8_commit_status=$?
  set -e
  (( o8_commit_status == 0 )) || { sed -n '1,160p' "$TMPDIR/o8-rollback-install-error" >&2; cat "$TMPDIR/o8-rollback-install-result" >&2; fail "real QML install rollback did not complete"; }
  jq -e --arg operation "$o8_operation" \
    '.action=="commit" and .operationId==$operation and .state=="ROLLED_BACK" and .status=="rolled-back" and .eligibility.durableOutcome=="restored"' \
    "$TMPDIR/o8-rollback-install-result" >/dev/null || fail "install rollback result was not state-true"
  [[ ! -e "$plugin_dir/$o8_terminal_id" && -d "$state_dir/omarchy/plugin-candidates-v1/$o8_operation/candidate" ]] ||
    fail "install rollback did not restore exact absence and retain candidate"
  [[ ! -e "$marker.service" ]] || fail "install rollback evaluated the candidate entry point"
  [[ $(state "$o8_terminal_id" | jq -r .directUrl) == "" ]] || fail "install rollback left current shell eligibility released"
  pass "actual QML install rollback restores absence, retains candidate, and never evaluates it"

  update_operation=62000000-0000-4000-8000-000000000005
  update_candidate="$TMPDIR/o8-update-candidate"
  mkdir -p "$update_candidate"
  cp "$FIXTURE_ROOT/Service.qml" "$update_candidate/Service.qml"
  jq --arg id "$active_service_id" '.id=$id | .kinds=["service"] | .entryPoints={service:"Service.qml"}' \
    "$FIXTURE_ROOT/manifest.json" >"$update_candidate/manifest.json"
  update_identity=$($helper identity "$update_candidate")
  update_active_identity=$($helper identity "$plugin_dir/$active_service_id")
  update_projection=sha256:$(jq -r .referenceProjectionBase64 <<<"$(shell_ipc shell transactionStageObservation "$active_service_id")" | base64 -d | sha256sum | cut -d' ' -f1)
  update_token=$(head -c 32 /dev/urandom | base64 -w0 | tr '+/' '-_' | tr -d '=')
  update_request=$(jq -cn --arg operationId "$update_operation" --arg token "$update_token" \
    --arg pluginId "$active_service_id" --arg source "$update_candidate" \
    --arg digest "sha256:${update_identity#omarchy-runtime-tree-sha256-v1:}" \
    --arg active "sha256:${update_active_identity#omarchy-runtime-tree-sha256-v1:}" --arg projection "$update_projection" \
    '{protocol:"legacy-schema-v1-transaction/v1",action:"stage",operationId:$operationId,operationToken:$token,
      operation:"update",pluginId:$pluginId,source:{kind:"directory",path:$source},candidateTree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$digest},
      expectedActive:{state:"present",tree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$active}},
      expectedConfiguration:{source:{kind:"user",identity:"omarchy-shell-config:user:v1"},referenceProjectionSha256:$projection,
      referenceState:"referenced",referencePolicy:"preserve-observed"}}')
  printf '%s' "$update_request" | "$test_root/bin/omarchy-plugin-transaction" >/dev/null ||
    fail "real QML update rollback stage was not accepted"
  : >"$OMARCHY_LIFECYCLE_FAIL_GATED_RESCAN"
  update_commit=$(jq -cn --arg operationId "$update_operation" --arg token "$update_token" \
    '{protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$operationId,operationToken:$token}')
  set +e
  printf '%s' "$update_commit" | "$test_root/bin/omarchy-plugin-transaction" >"$TMPDIR/o8-rollback-update-result" 2>"$TMPDIR/o8-rollback-update-error"
  update_status=$?
  set -e
  (( update_status == 0 )) || { sed -n '1,160p' "$TMPDIR/o8-rollback-update-error" >&2; cat "$TMPDIR/o8-rollback-update-result" >&2; fail "real QML update rollback did not complete"; }
  if [[ $(jq -r .state "$TMPDIR/o8-rollback-update-result") != ROLLED_BACK ]]; then
    [[ $(shell_ipc shell testReleaseUnload "$active_service_id") == ok ]] ||
      fail "real QML rollback harness could not release the held prior service"
    wait_for "real QML update unload acknowledgement" \
      '[[ $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/gates/$active_service_id.gate" 2>/dev/null || true) == UNLOAD_ACKNOWLEDGED ]]'
    printf '%s' "$update_commit" | "$test_root/bin/omarchy-plugin-transaction" >"$TMPDIR/o8-rollback-update-result" 2>"$TMPDIR/o8-rollback-update-error" || {
      sed -n '1,160p' "$TMPDIR/o8-rollback-update-error" >&2; cat "$TMPDIR/o8-rollback-update-result" >&2; fail "real QML update rollback retry did not complete";
    }
  fi
  jq -e --arg operation "$update_operation" \
    '.action=="commit" and .operationId==$operation and .state=="ROLLED_BACK" and .status=="rolled-back" and .eligibility.durableOutcome=="restored"' \
    "$TMPDIR/o8-rollback-update-result" >/dev/null || fail "update rollback result was not state-true"
  [[ -d "$plugin_dir/$active_service_id" && $($helper identity "$plugin_dir/$active_service_id") == "$update_active_identity" ]] ||
    fail "update rollback did not restore the prior tree"
  [[ -d "$state_dir/omarchy/plugin-candidates-v1/$update_operation/candidate" && $($helper identity "$state_dir/omarchy/plugin-candidates-v1/$update_operation/candidate") == "$update_identity" ]] ||
    fail "update rollback did not retain the candidate"
  [[ ! -e "$marker.service" ]] || fail "update rollback evaluated the candidate entry point"
  pass "actual QML update rollback restores basename-independent prior tree and retains candidate"

  # A real QML rollback-release receipt failure must retain blocking authority
  # and stop before the terminal journal handoff.
  failed_operation=62000000-0000-4000-8000-000000000006
  failed_source="$TMPDIR/o8-failed-rollback-candidate"
  mkdir -p "$failed_source"
  cp "$FIXTURE_ROOT/Service.qml" "$failed_source/Service.qml"
  jq --arg id "$o8_terminal_id" '.id=$id | .kinds=["service"] | .entryPoints={service:"Service.qml"}' \
    "$FIXTURE_ROOT/manifest.json" >"$failed_source/manifest.json"
  failed_identity=$($helper identity "$failed_source")
  failed_projection=sha256:$(jq -r .referenceProjectionBase64 <<<"$(shell_ipc shell transactionStageObservation "$o8_terminal_id")" | base64 -d | sha256sum | cut -d' ' -f1)
  failed_token=$(head -c 32 /dev/urandom | base64 -w0 | tr '+/' '-_' | tr -d '=')
  failed_request=$(jq -cn --arg operationId "$failed_operation" --arg token "$failed_token" \
    --arg pluginId "$o8_terminal_id" --arg source "$failed_source" \
    --arg digest "sha256:${failed_identity#omarchy-runtime-tree-sha256-v1:}" \
    --arg projection "$failed_projection" '{protocol:"legacy-schema-v1-transaction/v1",action:"stage",
      operationId:$operationId,operationToken:$token,operation:"install",pluginId:$pluginId,
      source:{kind:"directory",path:$source},candidateTree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$digest},
      expectedActive:{state:"absent"},expectedConfiguration:{source:{kind:"user",identity:"omarchy-shell-config:user:v1"},
      referenceProjectionSha256:$projection,referenceState:"unreferenced",referencePolicy:"require-unreferenced"}}')
  printf '%s' "$failed_request" | "$test_root/bin/omarchy-plugin-transaction" >/dev/null ||
    fail "real QML fail-closed rollback stage was not accepted"
  : >"$OMARCHY_LIFECYCLE_FAIL_GATED_RESCAN"
  : >"$OMARCHY_LIFECYCLE_FAIL_TERMINAL_RECEIPT_MARKER"
  failed_commit=$(jq -cn --arg operationId "$failed_operation" --arg token "$failed_token" \
    '{protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$operationId,operationToken:$token}')
  set +e
  printf '%s' "$failed_commit" | "$test_root/bin/omarchy-plugin-transaction" >"$TMPDIR/o8-rollback-failure-result" 2>"$TMPDIR/o8-rollback-failure-error"
  failed_status=$?
  set -e
  rm -f "$OMARCHY_LIFECYCLE_FAIL_TERMINAL_RECEIPT_MARKER"
  (( failed_status != 0 )) || fail "rollback receipt failure falsely completed"
  [[ $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/journals/$failed_operation.journal") == ROLLBACK_STARTED ]] ||
    fail "rollback receipt failure did not retain the rollback journal"
  failed_gate_state=$(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/gates/$o8_terminal_id.gate")
  [[ $failed_gate_state == GATED || $failed_gate_state == UNLOAD_ACKNOWLEDGED || $failed_gate_state == RESCAN_ACKNOWLEDGED ]] ||
    fail "rollback receipt failure did not retain a blocking gate (state=$failed_gate_state)"
  [[ ! -e "$plugin_dir/$o8_terminal_id" && ! -e "$marker.service" ]] ||
    fail "failed rollback released or evaluated the candidate"
  pass "actual QML rollback receipt failure remains gated and nonterminal"
  exit 0
fi

if [[ $EXPECTATION == o8-terminal-reviewed || $EXPECTATION == o8-terminal-corrected || $EXPECTATION == o8-terminal-receipt-failure ]]; then
  o8_source="$TMPDIR/candidate-$o8_terminal_id"
  o8_operation=62000000-0000-4000-8000-000000000001
  o8_identity=$($helper identity "$o8_source")
  o8_projection=sha256:$(jq -r .referenceProjectionBase64 <<<"$(shell_ipc shell transactionStageObservation "$o8_terminal_id")" | base64 -d | sha256sum | cut -d' ' -f1)
  o8_token=$(head -c 32 /dev/urandom | base64 -w0 | tr '+/' '-_' | tr -d '=')
  o8_request=$(jq -cn --arg operationId "$o8_operation" --arg token "$o8_token" \
    --arg pluginId "$o8_terminal_id" --arg source "$o8_source" \
    --arg digest "sha256:${o8_identity#omarchy-runtime-tree-sha256-v1:}" \
    --arg projection "$o8_projection" '{protocol:"legacy-schema-v1-transaction/v1",action:"stage",
      operationId:$operationId,operationToken:$token,operation:"install",pluginId:$pluginId,
      source:{kind:"directory",path:$source},candidateTree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$digest},
      expectedActive:{state:"absent"},expectedConfiguration:{source:{kind:"user",identity:"omarchy-shell-config:user:v1"},
      referenceProjectionSha256:$projection,referenceState:"unreferenced",referencePolicy:"require-unreferenced"}}')
  if ! printf '%s' "$o8_request" | "$test_root/bin/omarchy-plugin-transaction" >/dev/null; then
    fail "real O-8 stage did not accept the authoritative absent observation"
  fi
  [[ $(shell_ipc shell testReleaseUnload "$o8_terminal_id") == ok ]] ||
    fail "real QML harness could not release its deterministic unload barrier"
  [[ $(shell_ipc shell testStopLocalPluginWatcher) == stopping ]] ||
    fail "real QML harness could not stop the ordinary watcher before gated rescan"
  : >"$OMARCHY_LIFECYCLE_HOLD_AUTHORIZE_AFTER"
  o8_commit=$(jq -cn --arg operationId "$o8_operation" --arg token "$o8_token" \
    '{protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$operationId,operationToken:$token}')
  set +e
  printf '%s' "$o8_commit" | "$test_root/bin/omarchy-plugin-transaction" \
    >"$TMPDIR/o8-commit-result" 2>"$TMPDIR/o8-commit-error" &
  o8_commit_pid=$!
  set -e
  wait_for "real QML release reaches post-authorization barrier" '[[ -e $OMARCHY_LIFECYCLE_AUTHORIZE_AFTER_READY ]]'
  [[ $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/gates/$o8_terminal_id.gate") == RELEASE_AUTHORIZED ]] ||
    fail "native release did not durably produce RELEASE_AUTHORIZED"
    if [[ $EXPECTATION == o8-terminal-reviewed ]]; then
    o8_state=$(state "$o8_terminal_id")
    [[ $(jq -r .gate.state <<<"$o8_state") == RESCAN_ACKNOWLEDGED ]] ||
      fail "reviewed QML unexpectedly stored RELEASE_AUTHORIZED before the negative control"
    [[ $(jq -r .status <<<"$o8_state") != *terminal* ]] ||
      fail "reviewed QML reported a terminal acknowledgement despite the refused receipt"
    pass "reviewed head reproduces the real QML RELEASE_AUTHORIZED storage defect"
    printf 'resume\n' >"$OMARCHY_LIFECYCLE_AUTHORIZE_AFTER_RESUME"
    rm -f "$OMARCHY_LIFECYCLE_HOLD_AUTHORIZE_AFTER" "$OMARCHY_LIFECYCLE_AUTHORIZE_AFTER_READY"
    set +e
    wait "$o8_commit_pid"
    o8_commit_status=$?
    set -e
    (( o8_commit_status != 0 )) || fail "reviewed head falsely completed commit after terminal receipt refusal"
    [[ $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/gates/$o8_terminal_id.gate") == RELEASE_AUTHORIZED ]] ||
      fail "failed reviewed terminal receipt did not retain durable release authority"
    pass "real QML terminal receipt refusal prevents a false committed result"
  elif [[ $EXPECTATION == o8-terminal-receipt-failure ]]; then
    # The helper has durably written TERMINAL_RECEIPT, but the real QML action
    # receives a failure after publication.  QML must synchronously restore a
    # blocking authority and wait for lifecycle quiescence before the
    # coordinator can make any rollback or terminal-journal decision.
    printf 'resume\n' >"$OMARCHY_LIFECYCLE_AUTHORIZE_AFTER_RESUME"
    rm -f "$OMARCHY_LIFECYCLE_HOLD_AUTHORIZE_AFTER" "$OMARCHY_LIFECYCLE_AUTHORIZE_AFTER_READY"
    wait_for "receipt failure reaches the real QML callback" '[[ $(transaction_status "$o8_operation" 2>/dev/null || true) == terminal-receipt-indeterminate ]]'
    wait_for "receipt failure restores a blocking durable gate" '[[ $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/gates/$o8_terminal_id.gate" 2>/dev/null || true) == GATED ]]'
    [[ $(state "$o8_terminal_id" | jq -r .directUrl) == "" ]] ||
      fail "receipt failure left the candidate eligible in the current shell"
    [[ $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/journals/$o8_operation.journal") == RELEASE_PENDING ]] ||
      fail "receipt failure advanced the terminal journal"
    [[ -d "$plugin_dir/$o8_terminal_id" && ! -L "$plugin_dir/$o8_terminal_id" ]] ||
      fail "receipt failure changed the exposed namespace before re-gating"
    [[ $($helper identity "$plugin_dir/$o8_terminal_id") == "$o8_identity" ]] ||
      fail "receipt failure changed the exposed candidate before re-gating"
    set +e
    wait "$o8_commit_pid"
    o8_commit_status=$?
    set -e
    (( o8_commit_status != 0 )) || fail "receipt failure falsely completed commit"
    pass "real QML receipt failure re-gates before any rollback or COMMITTED state"
  else
    # The helper is still paused before QML handles RELEASE_AUTHORIZED.  The
    # blocking map must therefore remain authoritative until the callback runs.
    pre_release_state=$(state "$o8_terminal_id")
    [[ $(jq -r .gate.state <<<"$pre_release_state") == RESCAN_ACKNOWLEDGED ]] ||
      fail "QML released the plugin before handling RELEASE_AUTHORIZED" "$pre_release_state"
    # Hold the terminal helper after it has durably written TERMINAL_RECEIPT,
    # so the coordinator cannot race past the QML publication checkpoint.
    : >"$OMARCHY_LIFECYCLE_HOLD_TERMINAL_RECEIPT"
    printf 'resume\n' >"$OMARCHY_LIFECYCLE_AUTHORIZE_AFTER_RESUME"
    rm -f "$OMARCHY_LIFECYCLE_HOLD_AUTHORIZE_AFTER" "$OMARCHY_LIFECYCLE_AUTHORIZE_AFTER_READY"
    wait_for "QML publishes eligibility before requesting terminal receipt" \
      '[[ -e $OMARCHY_LIFECYCLE_TERMINAL_RECEIPT_READY ]]'
    corrected_state=$(state "$o8_terminal_id")
    [[ $(jq -r .gate <<<"$corrected_state") == null ]] ||
      fail "corrected QML retained a blocking gate after eligibility publication" "$corrected_state"
    corrected_status=$(jq -r --arg operation "$o8_operation" '.results[$operation].status' <<<"$corrected_state")
    [[ $corrected_status == terminal-receipt-pending ]] ||
      fail "corrected QML did not wait on the durable terminal receipt (status=$corrected_status)" "$corrected_state"
    [[ $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/gates/$o8_terminal_id.gate") == TERMINAL_RECEIPT ]] ||
      fail "terminal receipt was not durable after eligibility publication"
    pass "real QML publishes eligibility before durable terminal receipt"
    printf 'resume\n' >"$OMARCHY_LIFECYCLE_TERMINAL_RECEIPT_RESUME"
    rm -f "$OMARCHY_LIFECYCLE_HOLD_TERMINAL_RECEIPT" "$OMARCHY_LIFECYCLE_TERMINAL_RECEIPT_READY"
    wait_for "coordinator commits only after terminal receipt acknowledgement" \
      '[[ $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/journals/$o8_operation.journal" 2>/dev/null || true) == COMMITTED ]]'
    [[ $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/journals/$o8_operation.journal") == COMMITTED ]] ||
      fail "coordinator wrote no final COMMITTED journal after terminal acknowledgement"
    pass "real QML terminal handoff completes before COMMITTED"
  fi
  exit 0
fi
wait_for "real service completion reaches deterministic barrier" '(( $(state "$service_id" 2>/dev/null | jq -r .deferredService || echo 0) >= 1 ))'
wait_for "real widget completion reaches deterministic barrier" '(( $(state "$widget_id" 2>/dev/null | jq -r .deferredWidget || echo 0) >= 1 ))'
wait_for "active-service completion reaches deterministic barrier" '(( $(state "$active_service_id" 2>/dev/null | jq -r .deferredService || echo 0) >= 1 ))'
wait_for "active-widget completion reaches deterministic barrier" '(( $(state "$active_widget_id" 2>/dev/null | jq -r .deferredWidget || echo 0) >= 1 ))'
if [[ $EXPECTATION != reviewed-authority-vulnerable ]]; then
  initial_epoch=$(state "$service_id" | jq -r .configurationEpoch)
  initial_config_sha=$(sha256sum "$config_file")
  unrelated_config_b64=$(base64 -w0 "$unrelated_config")
  chmod 0500 "$(dirname "$config_file")"
  [[ $(shell_ipc shell testPersistConfigBase64 "$unrelated_config_b64") == failed ]] || fail "isolated configuration write failure was not reported"
  chmod 0700 "$(dirname "$config_file")"
  [[ $(state "$service_id" | jq -r .configurationEpoch) == "$initial_epoch" ]] || fail "failed write advanced configuration authority"
  [[ $(sha256sum "$config_file") == "$initial_config_sha" ]] || fail "failed atomic write changed shell.json"
  jq -e '.shellConfig == .acceptedConfig and (.shellConfig.bar.floating == null)' <<<"$(state "$service_id")" >/dev/null ||
    fail "failed write split loader and release authority"
  pass "failed programmatic write retains one prior accepted snapshot"

  wait_for "indeterminate fixture is initially resolvable" '[[ $(state "$indeterminate_id" 2>/dev/null | jq -r .directUrl || true) == file:* ]]'
  : >"$OMARCHY_LIFECYCLE_INJECT_INSTALL_PARENT_FSYNC"
  shell_ipc shell gateTransactionPlugin "$indeterminate_operation" "$indeterminate_id" >/dev/null
  wait_for "install parent-fsync ambiguity blocks the affected plugin in memory" '[[ $(transaction_status "$indeterminate_operation" 2>/dev/null || true) == gate-operation-failed && $(state "$indeterminate_id" 2>/dev/null | jq -r .directUrl) == "" ]]'
  [[ $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/gates/$indeterminate_id.gate") == GATED ]] ||
    fail "indeterminate install did not retain its visible durable gate evidence"
  shell_ipc shell gateTransactionPlugin "$indeterminate_operation" "$indeterminate_id" >/dev/null
  wait_for "same-shell retry synchronizes and reconstructs indeterminate gate" '[[ $(transaction_status "$indeterminate_operation" 2>/dev/null || true) == gate-installed-unload-acknowledged && $(state "$indeterminate_id" 2>/dev/null | jq -r ".gate.valid == true and .gate.state == \"UNLOAD_ACKNOWLEDGED\" and .directUrl == \"\"") == true ]]'
  pass "same-shell gate-indeterminate result remains blocked through exact reconciliation"
fi
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
  if [[ $EXPECTATION != reviewed-authority-vulnerable ]]; then
    shell_ipc shell gateTransactionPlugin "$service_operation" "$service_id" >/dev/null
    wait_for "GATED replay remains blocked on pending service ownership" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == unload-incomplete && $(state "$service_id" 2>/dev/null | jq -r .gate.state) == GATED ]]'
    pass "GATED replay reconstructs durable authority without guessing"
  fi
fi

shell_ipc shell testReleaseUnload "$service_id" >/dev/null
wait_for "service unload eventually acknowledges after invalidation" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == gate-installed-unload-acknowledged ]]'
if [[ $EXPECTATION != reviewed-authority-vulnerable ]]; then
  shell_ipc shell gateTransactionPlugin "$service_operation" "$service_id" >/dev/null
  wait_for "UNLOAD_ACKNOWLEDGED replay remains exact" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == gate-installed-unload-acknowledged && $(state "$service_id" 2>/dev/null | jq -r .gate.state) == UNLOAD_ACKNOWLEDGED ]]'

  duplicate_source="$plugin_dir/acme.lifecycle-duplicate-source"
  before_duplicate_generation=$(state "$service_id" | jq -r .registryGeneration)
  [[ $(shell_ipc shell testStopLocalPluginWatcher) == stopping ]] || fail "test-copy plugin watcher stop was not requested"
  wait_for "test-copy plugin watcher stops" '[[ $(state "$service_id" 2>/dev/null | jq -r .pluginWatcherRunning || true) == false ]]'
  cp -a "$plugin_dir/$service_id" "$duplicate_source"
  [[ $(shell_ipc shell testOrdinaryRescan) == started ]] || fail "duplicate-source ordinary scan did not start"
  wait_for "duplicate-source ordinary scan completes" '(( $(state "$service_id" 2>/dev/null | jq -r .registryGeneration || echo 0) > before_duplicate_generation )) && [[ $(state "$service_id" 2>/dev/null | jq -r .registryScanning || true) == false ]]'
  duplicate_stage_observation=$(shell_ipc shell transactionStageObservation "$service_id")
  jq -e '.valid == false and .status == "registry-target-ambiguous"' \
    <<<"$duplicate_stage_observation" >/dev/null || fail "stage observation accepted an ambiguous active plugin ID"
  shell_ipc shell rescanGatedPlugin "$service_operation" "$service_id" >/dev/null
  wait_for "duplicate source fails operation-bound discovery" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == gated-rescan-failed ]]'
  [[ $(state "$service_id" | jq -r '.gate.state + ":" + .directUrl') == UNLOAD_ACKNOWLEDGED: ]] ||
    fail "duplicate manifest source changed gate or exposed a Loader URL"
  [[ $(jq -r .state "$state_dir/omarchy/plugin-transactions-v1/gates/$service_id.gate") == UNLOAD_ACKNOWLEDGED ]] ||
    fail "duplicate manifest source changed the durable gate"
  before_duplicate_removal_generation=$(state "$service_id" | jq -r .registryGeneration)
  find "$duplicate_source" -mindepth 1 -delete
  rmdir "$duplicate_source"
  [[ $(shell_ipc shell testOrdinaryRescan) == started ]] || fail "duplicate-removal ordinary scan did not start"
  wait_for "duplicate-removal ordinary scan completes" '(( $(state "$service_id" 2>/dev/null | jq -r .registryGeneration || echo 0) > before_duplicate_removal_generation )) && [[ $(state "$service_id" 2>/dev/null | jq -r .registryScanning || true) == false ]]'
  pass "duplicate registry source remains non-loadable and cannot acknowledge gated discovery"
  pass "stage observation rejects ambiguous active plugin discovery"
fi

shell_ipc shell rescanGatedPlugin "$service_operation" "$service_id" >/dev/null
wait_for "service gated rescan completes" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == gated-rescan-complete ]]'
if [[ $EXPECTATION == reviewed-authority-vulnerable ]]; then
  : >"$OMARCHY_LIFECYCLE_HOLD_PROJECTION"
  before_mutation_epoch=$(state "$service_id" | jq -r .configurationEpoch)
  shell_ipc shell releaseTransactionPlugin "$service_operation" "$service_id" >/dev/null
  wait_for "reviewed projection reaches deterministic barrier" '[[ -e $OMARCHY_LIFECYCLE_PROJECTION_READY ]]'
  [[ $(shell_ipc shell setPluginEnabled "$service_id" false) == ok ]] || fail "reviewed-head configuration mutation failed"
  mutation_state=$(state "$service_id")
  printf 'resume\n' >"$OMARCHY_LIFECYCLE_PROJECTION_RESUME"
  [[ $(jq -r .splitSnapshotObserved <<<"$mutation_state") == true ]] ||
    fail "reviewed head did not reproduce the split configuration snapshot"
  [[ $(jq -r .splitSnapshotEpoch <<<"$mutation_state") == "$before_mutation_epoch" ]] ||
    fail "reviewed split window was not observed at the old release epoch"
  pass "reviewed head reproduces the programmatic split-snapshot window"
  exit 0
elif [[ $EXPECTATION == published-vulnerable ]]; then
  shell_ipc shell releaseTransactionPlugin "$service_operation" "$service_id" >/dev/null
  wait_for "service conditional release completes" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == released ]]'
else
  gated_generation=$(state "$service_id" | jq -r .gate.generation)
  gated_scan_epoch=$(state "$service_id" | jq -r .gate.scanEpoch)
  shell_ipc shell gateTransactionPlugin "$service_operation" "$service_id" >/dev/null
  wait_for "RESCAN_ACKNOWLEDGED replay preserves exact authority" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == gated-rescan-complete && $(state "$service_id" 2>/dev/null | jq -r ".gate.state == \"RESCAN_ACKNOWLEDGED\" and .gate.generation == $gated_generation and .gate.scanEpoch == $gated_scan_epoch") == true ]]'
  : >"$OMARCHY_LIFECYCLE_HOLD_SCAN"
  [[ $(shell_ipc shell testOrdinaryRescan) == started ]] || fail "ordinary generation-advance scan did not start"
  wait_for "ordinary scan reaches deterministic in-progress barrier" '[[ -e $OMARCHY_LIFECYCLE_SCAN_READY ]]'
  scan_pending_state=$(state "$service_id")
  [[ $(jq -r .registryScanning <<<"$scan_pending_state") == true ]] || fail "held ordinary scan was not authoritative in-progress state"
  [[ $(jq -r .registryGeneration <<<"$scan_pending_state") == "$gated_generation" ]] || fail "held scan unexpectedly completed"
  (( $(jq -r .scanEpoch <<<"$scan_pending_state") > gated_scan_epoch )) || fail "scan start did not invalidate the gated scan epoch"
  shell_ipc shell releaseTransactionPlugin "$service_operation" "$service_id" >/dev/null
  if [[ $EXPECTATION == broken-current-generation ]]; then
    wait_for "negative control releases against a stale registry generation" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == released ]]'
    pass "generation-guard negative control reproduces stale release"
    exit 0
  fi
  wait_for "stale generation retains service gate before projection" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == release-retained && $(state "$service_id" 2>/dev/null | jq -r .gate.state) == UNLOAD_ACKNOWLEDGED ]]'
  printf 'resume\n' >"$OMARCHY_LIFECYCLE_SCAN_RESUME"
  rm -f "$OMARCHY_LIFECYCLE_HOLD_SCAN" "$OMARCHY_LIFECYCLE_SCAN_READY"
  wait_for "ordinary rescan advances current registry generation" '(( $(state "$service_id" 2>/dev/null | jq -r .registryGeneration || echo 0) > gated_generation ))'
  pass "scan-in-progress state and current generation are required before release comparison"

  shell_ipc shell rescanGatedPlugin "$service_operation" "$service_id" >/dev/null
  wait_for "fresh service gated rescan replaces stale generation" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == gated-rescan-complete && $(state "$service_id" 2>/dev/null | jq -r ".gate.generation == .registryGeneration") == true ]]'

  : >"$OMARCHY_LIFECYCLE_HOLD_PROJECTION"
  before_mutation_epoch=$(state "$service_id" | jq -r .configurationEpoch)
  shell_ipc shell releaseTransactionPlugin "$service_operation" "$service_id" >/dev/null
  wait_for "projection completion reaches deterministic barrier" '[[ -e $OMARCHY_LIFECYCLE_PROJECTION_READY ]]'
  [[ $(shell_ipc shell setPluginEnabled "$service_id" false) == ok ]] || fail "real plugin configuration mutation failed"
  mutation_state=$(state "$service_id")
  printf 'resume\n' >"$OMARCHY_LIFECYCLE_PROJECTION_RESUME"
  rm -f "$OMARCHY_LIFECYCLE_HOLD_PROJECTION" "$OMARCHY_LIFECYCLE_PROJECTION_READY"
  [[ $(jq -r .splitSnapshotObserved <<<"$mutation_state") == false ]] ||
    fail "programmatic mutation exposed split loader/release snapshots"
  jq -e '.shellConfig == .acceptedConfig' <<<"$mutation_state" >/dev/null ||
    fail "programmatic mutation did not publish one accepted configuration"
  (( $(jq -r .configurationEpoch <<<"$mutation_state") > before_mutation_epoch )) ||
    fail "programmatic mutation did not advance the accepted epoch synchronously"
  [[ $(jq -r .acceptedSourceIdentity <<<"$mutation_state") == omarchy-shell-config:user:v1 ]] ||
    fail "programmatic mutation published the wrong source identity"
  [[ $(jq -r .acceptedRawText <<<"$mutation_state") == "$(<"$config_file")" ]] ||
    fail "written shell.json and accepted raw snapshot differ"
  wait_for "configuration epoch change during projection retains gate" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == release-precondition-mismatch ]]'
  [[ $(state "$service_id" | jq -r .gate.state) == RESCAN_ACKNOWLEDGED ]] || fail "projection-epoch mismatch removed the gate"
  pass "real programmatic mutation atomically advances loader and release authority"

  initial_config_b64=$(base64 -w0 "$initial_config")
  unrelated_config_b64=$(base64 -w0 "$unrelated_config")
  [[ $(shell_ipc shell testPersistConfigBase64 "$initial_config_b64") == ok ]] || fail "initial configuration restoration failed"
  wait_for "restored configuration is accepted" '[[ $(state "$service_id" 2>/dev/null | jq -r ".shellConfig == .acceptedConfig and (.shellConfig.plugins[0].id == \"$service_id\")" || true) == true ]]'

  : >"$OMARCHY_LIFECYCLE_HOLD_AUTHORIZE_BEFORE"
  before_authorize_epoch=$(state "$service_id" | jq -r .configurationEpoch)
  shell_ipc shell releaseTransactionPlugin "$service_operation" "$service_id" >/dev/null
  wait_for "native authorization reaches pre-call barrier" '[[ -e $OMARCHY_LIFECYCLE_AUTHORIZE_BEFORE_READY ]]'
  [[ $(shell_ipc shell testPersistConfigBase64 "$unrelated_config_b64") == ok ]] || fail "pre-authorization configuration mutation failed"
  (( $(state "$service_id" | jq -r .configurationEpoch) > before_authorize_epoch )) ||
    fail "pre-authorization mutation did not synchronously advance the epoch"
  [[ $(projection_digest "$service_id") == "$initial_service_projection" ]] ||
    fail "unrelated configuration mutation changed the plugin projection"
  printf 'resume\n' >"$OMARCHY_LIFECYCLE_AUTHORIZE_BEFORE_RESUME"
  rm -f "$OMARCHY_LIFECYCLE_HOLD_AUTHORIZE_BEFORE" "$OMARCHY_LIFECYCLE_AUTHORIZE_BEFORE_READY"
  wait_for "post-projection epoch change returns durable gate to unload-acknowledged" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == release-retained && $(state "$service_id" 2>/dev/null | jq -r .gate.state) == UNLOAD_ACKNOWLEDGED ]]'
  pass "real unrelated mutation before native authorization is recoverably fail closed"

  [[ $(shell_ipc shell testPersistConfigBase64 "$initial_config_b64") == ok ]] || fail "pre-authorization test restoration failed"
  wait_for "pre-authorization test restoration is accepted" '[[ $(state "$service_id" 2>/dev/null | jq -r ".shellConfig == .acceptedConfig and (.shellConfig.bar.floating == null)" || true) == true ]]'

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
  wait_for "service gated rescan completes before post-native configuration test" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == gated-rescan-complete ]]'
  : >"$OMARCHY_LIFECYCLE_HOLD_AUTHORIZE_AFTER"
  before_post_native_epoch=$(state "$service_id" | jq -r .configurationEpoch)
  shell_ipc shell releaseTransactionPlugin "$service_operation" "$service_id" >/dev/null
  wait_for "second native release authorization reaches post-write barrier" '[[ -e $OMARCHY_LIFECYCLE_AUTHORIZE_AFTER_READY ]]'
  [[ $(shell_ipc shell testPersistConfigBase64 "$unrelated_config_b64") == ok ]] || fail "post-authorization configuration mutation failed"
  (( $(state "$service_id" | jq -r .configurationEpoch) > before_post_native_epoch )) ||
    fail "post-authorization mutation did not synchronously advance the epoch"
  printf 'resume\n' >"$OMARCHY_LIFECYCLE_AUTHORIZE_AFTER_RESUME"
  rm -f "$OMARCHY_LIFECYCLE_HOLD_AUTHORIZE_AFTER" "$OMARCHY_LIFECYCLE_AUTHORIZE_AFTER_READY"
  wait_for "post-authorization configuration change restores blocking rescan state" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == release-retained && $(state "$service_id" 2>/dev/null | jq -r .gate.state) == UNLOAD_ACKNOWLEDGED ]]'
  pass "real configuration mutation after native authorization cannot publish eligibility"

  [[ $(shell_ipc shell testPersistConfigBase64 "$initial_config_b64") == ok ]] || fail "post-authorization test restoration failed"
  wait_for "post-authorization test restoration is accepted" '[[ $(state "$service_id" 2>/dev/null | jq -r ".shellConfig == .acceptedConfig and (.shellConfig.bar.floating == null)" || true) == true ]]'
  shell_ipc shell rescanGatedPlugin "$service_operation" "$service_id" >/dev/null
  wait_for "final service gated rescan completes" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == gated-rescan-complete ]]'
  shell_ipc shell releaseTransactionPlugin "$service_operation" "$service_id" >/dev/null
  wait_for "service conditional release completes" '[[ $(transaction_status "$service_operation" 2>/dev/null || true) == released ]]'
fi
[[ $(state "$service_id" | jq -r .directUrl) == "file://$plugin_dir/$service_id/Service.qml" ]] ||
  fail "released service URL did not resolve beneath the exact verified destination"
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
