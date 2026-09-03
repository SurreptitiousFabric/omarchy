#!/bin/bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/interface-test-lib.sh"

ROOT=$(interface_test_root)
TEST_ROOT=$(mktemp -d)
trap 'find "$TEST_ROOT" -mindepth 1 -delete; rmdir "$TEST_ROOT"' EXIT
INSTALL_ROOT="$TEST_ROOT/install/share/omarchy"
HOME_DIR="$TEST_ROOT/home"
STATE_HOME="$TEST_ROOT/state"
STATE_ROOT="$STATE_HOME/omarchy/plugin-transactions-v1"
STORE="$STATE_HOME/omarchy/plugin-candidates-v1"
DISCOVERY="$HOME_DIR/.config/omarchy/plugins"
COMMAND="$INSTALL_ROOT/bin/omarchy-plugin-transaction"
NATIVE="$INSTALL_ROOT/native/plugin-transaction/plugin-tree"
TOKEN=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
WRONG_TOKEN=QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI
EMPTY_DIGEST=sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432
CONCURRENT_OPERATION=82000000-0000-4000-8000-000000000099

build_interface_install "$ROOT" "$INSTALL_ROOT"
initialize_transaction_state "$STATE_ROOT"
mkdir -p "$HOME_DIR" "$DISCOVERY"

mv "$NATIVE" "$NATIVE.real"
cat >"$NATIVE" <<'SH'
#!/bin/bash
set -euo pipefail
directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ ${1:-} == operation-lock && ${3:-} == 82000000-0000-4000-8000-000000000099 ]]; then
  printf 'second-waiting\n' >"$directory/concurrent-second-ready"
fi
exec "$directory/plugin-tree.real" "$@"
SH
chmod 0755 "$NATIVE"

mv "$INSTALL_ROOT/native/plugin-transaction/stage-candidate" \
  "$INSTALL_ROOT/native/plugin-transaction/stage-candidate.real"
cat >"$INSTALL_ROOT/native/plugin-transaction/stage-candidate" <<'SH'
#!/bin/bash
set +x
set -euo pipefail
real_stage=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/stage-candidate.real
token=
IFS= read -r token
printf '%s\0' "$@" >"$HOME/.o7-stage-argv"
env -0 | sort -z >"$HOME/.o7-stage-environment"
printf '%s' "$token" | sha256sum | cut -d' ' -f1 >"$HOME/.o7-stage-stdin-sha256"
printf '%s\n' "${#token}" >"$HOME/.o7-stage-stdin-length"
if [[ ${1:-} == 82000000-0000-4000-8000-000000000099 ]]; then
  if mkdir "$HOME/.o7-concurrent-owner" 2>/dev/null; then
    export OMARCHY_PLUGIN_TREE_TEST_HOOK=before-publication
    export OMARCHY_PLUGIN_TREE_TEST_READY_FIFO="$HOME/.o7-concurrent-ready"
    export OMARCHY_PLUGIN_TREE_TEST_RESUME_FIFO="$HOME/.o7-concurrent-resume"
  fi
fi
printf '%s\n' "$token" | "$real_stage" "$@"
SH
chmod 0755 "$INSTALL_ROOT/native/plugin-transaction/stage-candidate"

cat >"$INSTALL_ROOT/bin/omarchy-shell" <<'SH'
#!/bin/bash
set -euo pipefail
[[ ${1:-} == shell && ${2:-} == transactionStageObservation && -n ${3:-} ]] || exit 64
[[ ! -e $HOME/.o7-shell-unavailable ]] || exit 1
if [[ -e $HOME/.o7-shell-malformed ]]; then
  printf '{\n'
  exit 0
fi
if [[ -e $HOME/.o7-shell-not-ready ]]; then
  printf '%s\n' '{"status":"gate-inventory-not-ready","valid":false}'
  exit 0
fi
printf '%s\n' "$2:$3" >>"$HOME/.o7-shell-calls"
jq -cS --arg plugin "$3" \
  --arg discovery "$HOME/.config/omarchy/plugins" \
  --arg state "$XDG_STATE_HOME/omarchy/plugin-transactions-v1" \
  '.pluginId=$plugin | .discoveryDirectory=$discovery | .transactionStateRoot=$state' \
  "$HOME/.o7-observation.json"
SH
chmod 0755 "$INSTALL_ROOT/bin/omarchy-shell"

projection_base64() {
  local config=$1 plugin=$2
  ROOT="$ROOT" CONFIG="$config" PLUGIN="$plugin" mise exec -- node <<'JS'
const fs = require('fs')
const vm = require('vm')
const source = fs.readFileSync(process.env.ROOT + '/shell/services/PluginReferenceProjection.js', 'utf8')
  .replace(/^\.pragma library\n/, '')
const scope = {}
vm.runInNewContext(source + '\nthis.api={canonicalBytes,base64};', scope)
const config = JSON.parse(fs.readFileSync(process.env.CONFIG, 'utf8'))
process.stdout.write(scope.api.base64(scope.api.canonicalBytes(config, process.env.PLUGIN)))
JS
}

write_config() {
  local plugin=${1:-}
  mkdir -p "$(dirname -- "$HOME_DIR/.config/omarchy/shell.json")"
  if [[ -z $plugin ]]; then
    jq -nS '{version:1,bar:{layout:{left:[],center:[],right:[]}},plugins:[]}' \
      >"$HOME_DIR/.config/omarchy/shell.json"
  else
    jq -nS --arg plugin "$plugin" \
      '{version:1,bar:{layout:{left:[],center:[],right:[]}},plugins:[{id:$plugin}]}' \
      >"$HOME_DIR/.config/omarchy/shell.json"
  fi
}

write_observation() {
  local plugin=$1 source_kind=$2 source_identity=$3 reference_state=$4
  local config="$HOME_DIR/.config/omarchy/shell.json" raw projection active
  raw=$(base64 -w0 <"$config")
  projection=$(projection_base64 "$config" "$plugin")
  if [[ -d $DISCOVERY/$plugin && ! -L $DISCOVERY/$plugin ]]; then
    active=$(jq -cnS --arg source "$DISCOVERY/$plugin" \
      '{state:"present",sourceDirectory:$source}')
  else
    active='{"state":"absent"}'
  fi
  jq -cnS --arg kind "$source_kind" --arg identity "$source_identity" \
    --arg raw "$raw" --arg projection "$projection" --arg state "$reference_state" \
    --argjson active "$active" '
    {valid:true,status:"observed",schema:"omarchy-plugin-stage-observation/v1",pluginId:"pending",
     configurationSource:{kind:$kind,identity:$identity},rawBase64:$raw,
     referenceProjectionBase64:$projection,referenceState:$state,activeDiscovery:$active,
     discoveryDirectory:"pending",transactionStateRoot:"pending"}' \
    >"$HOME_DIR/.o7-observation.json"
}

projection_digest() {
  local plugin=$1
  local encoded
  encoded=$(projection_base64 "$HOME_DIR/.config/omarchy/shell.json" "$plugin")
  printf 'sha256:'
  printf '%s' "$encoded" | base64 -d | sha256sum | cut -d' ' -f1
}

stage_request() {
  local operation_id=$1 token=$2 operation=$3 plugin=$4 source=$5 candidate=$6
  local active_state=$7 active=${8:-} config_kind=$9 config_identity=${10}
  local projection=${11} reference_state=${12} policy=${13}
  jq -cnS --arg protocol legacy-schema-v1-transaction/v1 --arg operationId "$operation_id" \
    --arg token "$token" --arg operation "$operation" --arg plugin "$plugin" \
    --arg source "$source" --arg candidate "$candidate" --arg activeState "$active_state" \
    --arg active "$active" --arg configKind "$config_kind" --arg configIdentity "$config_identity" \
    --arg projection "$projection" --arg referenceState "$reference_state" --arg policy "$policy" '
    {protocol:$protocol,action:"stage",operationId:$operationId,operationToken:$token,
     operation:$operation,pluginId:$plugin,source:{kind:"directory",path:$source},
     candidateTree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:("sha256:" + ($candidate | sub("^omarchy-runtime-tree-sha256-v1:";"")))},
     expectedActive:(if $activeState == "absent" then {state:"absent"}
       else {state:"present",tree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:("sha256:" + ($active | sub("^omarchy-runtime-tree-sha256-v1:";"")))}} end),
     expectedConfiguration:{source:{kind:$configKind,identity:$configIdentity},
       referenceProjectionSha256:$projection,referenceState:$referenceState,referencePolicy:$policy}}'
}

invoke() {
  HOME="$HOME_DIR" XDG_STATE_HOME="$STATE_HOME" "$COMMAND"
}

expect_stage_reason() {
  local operation=$1 reason=$2 request=$3 output status
  set +e
  output=$(printf '%s' "$request" | invoke 2>"$TEST_ROOT/$operation.err")
  status=$?
  set -e
  jq -e --arg reason "$reason" '.action == "stage" and .reason == $reason' <<<"$output" >/dev/null || {
    printf 'unexpected stage result for %s (exit %s): %s\n' "$operation" "$status" "$output" >&2
    exit 1
  }
  [[ ! -e $STATE_ROOT/journals/$operation.journal ]] || {
    printf 'unexpected journal for rejected operation %s\n' "$operation" >&2
    exit 1
  }
  (( status == 0 || status == 4 )) || {
    printf 'unexpected exit %s for rejected operation %s\n' "$status" "$operation" >&2
    exit 1
  }
}

write_config
install_plugin=acme.o7-stage
install_source="$TEST_ROOT/install-source"
make_interface_plugin "$ROOT" "$install_source" "$install_plugin"
install_identity=$("$NATIVE" identity "$install_source")
write_observation "$install_plugin" user omarchy-shell-config:user:v1 unreferenced
install_projection=$(projection_digest "$install_plugin")
[[ $install_projection == "$EMPTY_DIGEST" ]]
install_operation=82000000-0000-4000-8000-000000000001
install_request=$(stage_request "$install_operation" "$TOKEN" install "$install_plugin" \
  "$install_source" "$install_identity" absent '' user omarchy-shell-config:user:v1 \
  "$install_projection" unreferenced require-unreferenced)
config_before=$(sha256sum "$HOME_DIR/.config/omarchy/shell.json")
install_output=$(printf '%s' "$install_request" |
  OMARCHY_PATH=/attacker OMARCHY_PLUGIN_TREE_HELPER=/attacker/tree \
  OMARCHY_PLUGIN_VALIDATOR=/attacker/validator \
  OMARCHY_PLUGIN_JOURNAL_VALIDATOR=/attacker/journal \
  OMARCHY_PLUGIN_CANDIDATE_STORE="$TEST_ROOT/attacker-store" \
  OMARCHY_PLUGIN_TRANSACTION_STATE="$TEST_ROOT/attacker-state" \
  OMARCHY_PLUGIN_DISCOVERY_DIR="$TEST_ROOT/attacker-discovery" \
  invoke 2>"$TEST_ROOT/install.err")
jq -e --arg plugin "$install_plugin" --arg digest "sha256:${install_identity##*:}" '
  .protocol == "legacy-schema-v1-transaction/v1" and .action == "stage"
  and .pluginId == $plugin and .state == "STAGED" and .status == "ok"
  and .candidateTree == {algorithm:"omarchy-runtime-tree-sha256-v1",digest:$digest}
  and .observedActive == {state:"absent"}
  and .observedConfiguration.source == {kind:"user",identity:"omarchy-shell-config:user:v1"}
  and .observedConfiguration.referenceProjectionSha256 == "sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432"
  and .observedConfiguration.referenceState == "unreferenced"' <<<"$install_output" >/dev/null
journal="$STATE_ROOT/journals/$install_operation.journal"
jq -e '.state == "STAGED" and .normalizedRequest.facts.stageObservation.provenance == "shell-authoritative-o7"
  and .gate == "not-established" and .registry == "not-requested" and .rollback == "not-applicable"' \
  "$journal" >/dev/null
[[ $(jq -r .normalizedRequest.facts.destination "$journal") == "$DISCOVERY/$install_plugin" ]]
[[ ! -e $DISCOVERY/$install_plugin && ! -e $TEST_ROOT/attacker-store &&
    ! -e $TEST_ROOT/attacker-state && ! -e $TEST_ROOT/attacker-discovery ]]
[[ $(sha256sum "$HOME_DIR/.config/omarchy/shell.json") == "$config_before" ]]
[[ $(<"$HOME_DIR/.o7-stage-stdin-length") == 43 ]]
expected_token_sha=$(printf '%s' "$TOKEN" | sha256sum | cut -d' ' -f1)
[[ $(<"$HOME_DIR/.o7-stage-stdin-sha256") == "$expected_token_sha" ]]
token_absent_from_stage_channels() {
  ! grep -aF "$TOKEN" "$HOME_DIR/.o7-stage-argv" "$HOME_DIR/.o7-stage-environment" \
    "$journal" "$STORE/$install_operation/result.json" "$TEST_ROOT/install.err" >/dev/null
}
token_absent_from_stage_channels
! find "$TEST_ROOT" -type f -not -path '*/stage-interface-test.sh' -exec grep -aFl "$TOKEN" {} + | grep -q .
grep -azF "OMARCHY_PLUGIN_TREE_HELPER=$NATIVE" "$HOME_DIR/.o7-stage-environment" >/dev/null
! grep -azF /attacker "$HOME_DIR/.o7-stage-environment" >/dev/null
[[ $(<"$HOME_DIR/.o7-shell-calls") == "transactionStageObservation:$install_plugin" ]]
printf 'ok - authoritative install stages inertly with token only on private stdin\n'
printf 'ok - destination and implementation authorities ignore caller overrides\n'

candidate_inode=$(stat -c '%d:%i' "$STORE/$install_operation/candidate")
journal_sha=$(sha256sum "$journal")
find "$install_source" -depth -delete
: >"$HOME_DIR/.o7-shell-unavailable"
replay_output=$(printf '%s' "$install_request" | invoke 2>"$TEST_ROOT/replay.err")
[[ $replay_output == "$install_output" ]]
[[ $(stat -c '%d:%i' "$STORE/$install_operation/candidate") == "$candidate_inode" ]]
[[ $(sha256sum "$journal") == "$journal_sha" ]]
printf 'ok - exact replay needs neither external source nor shell authority\n'

conflict_request=$(jq -c '.expectedConfiguration.source.identity="different-opaque-identity"' <<<"$install_request")
set +e
conflict_output=$(printf '%s' "$conflict_request" | invoke 2>"$TEST_ROOT/conflict.err")
conflict_status=$?
wrong_output=$(printf '%s' "$conflict_request" | jq -c --arg token "$WRONG_TOKEN" '.operationToken=$token' |
  invoke 2>"$TEST_ROOT/wrong.err")
wrong_status=$?
set -e
[[ $conflict_status == 3 && $wrong_status == 3 ]]
jq -e '.reason == "operation-id-conflict"' <<<"$conflict_output" >/dev/null
jq -e '.reason == "invalid-operation-token"' <<<"$wrong_output" >/dev/null
[[ $(sha256sum "$journal") == "$journal_sha" &&
    $(stat -c '%d:%i' "$STORE/$install_operation/candidate") == "$candidate_inode" ]]
! grep -aF "$TOKEN" "$TEST_ROOT/conflict.err" "$TEST_ROOT/wrong.err" >/dev/null
rm "$HOME_DIR/.o7-shell-unavailable"
printf 'ok - capability precedes immutable-request conflict without changing evidence\n'

cp "$HOME_DIR/.o7-stage-argv" "$TEST_ROOT/clean-argv"
printf '%s\0' "$TOKEN" >>"$HOME_DIR/.o7-stage-argv"
if token_absent_from_stage_channels; then
  printf 'not ok - argv token negative control did not trip\n' >&2
  exit 1
fi
mv "$TEST_ROOT/clean-argv" "$HOME_DIR/.o7-stage-argv"
cp "$HOME_DIR/.o7-stage-environment" "$TEST_ROOT/clean-environment"
printf 'OPERATION_TOKEN=%s\0' "$TOKEN" >>"$HOME_DIR/.o7-stage-environment"
if token_absent_from_stage_channels; then
  printf 'not ok - environment token negative control did not trip\n' >&2
  exit 1
fi
mv "$TEST_ROOT/clean-environment" "$HOME_DIR/.o7-stage-environment"
polluted="$TEST_ROOT/polluted-capture"
printf '%s\n' "$TOKEN" >"$polluted"
if ! find "$TEST_ROOT" -type f -not -path '*/stage-interface-test.sh' -exec grep -aFl "$TOKEN" {} + | grep -q .; then
  printf 'not ok - retained-file token negative control did not trip\n' >&2
  exit 1
fi
rm "$polluted"
printf 'ok - argv, environment and retained-file token negative controls trip secrecy checks\n'

fresh_source="$TEST_ROOT/fresh-source"
make_interface_plugin "$ROOT" "$fresh_source" acme.o7-stale
fresh_identity=$("$NATIVE" identity "$fresh_source")
write_config
write_observation acme.o7-stale user omarchy-shell-config:user:v1 unreferenced
fresh_projection=$(projection_digest acme.o7-stale)

stale_candidate_request=$(stage_request 82000000-0000-4000-8000-000000000010 "$TOKEN" install acme.o7-stale \
  "$fresh_source" omarchy-runtime-tree-sha256-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  absent '' user omarchy-shell-config:user:v1 "$fresh_projection" unreferenced require-unreferenced)
expect_stage_reason 82000000-0000-4000-8000-000000000010 stale-candidate "$stale_candidate_request"

for kind in file directory symlink; do
  suffix=${kind/file/11}; suffix=${suffix/directory/12}; suffix=${suffix/symlink/13}
  plugin=acme.o7-active-$kind
  destination="$DISCOVERY/$plugin"
  case $kind in
    file) printf x >"$destination" ;;
    directory) mkdir "$destination" ;;
    symlink) ln -s "$fresh_source" "$destination" ;;
  esac
  write_observation "$plugin" user omarchy-shell-config:user:v1 unreferenced
  projection=$(projection_digest "$plugin")
  request=$(stage_request "82000000-0000-4000-8000-0000000000$suffix" "$TOKEN" install "$plugin" \
    "$fresh_source" "$fresh_identity" absent '' user omarchy-shell-config:user:v1 \
    "$projection" unreferenced require-unreferenced)
  expect_stage_reason "82000000-0000-4000-8000-0000000000$suffix" stale-active-tree "$request"
  if [[ -d $destination && ! -L $destination ]]; then rmdir "$destination"; else rm "$destination"; fi
done
printf 'ok - file, directory and symlink all contradict expected absence\n'

sibling_active="$DISCOVERY/noncanonical-source-name"
make_interface_plugin "$ROOT" "$sibling_active" acme.o7-stale
write_observation acme.o7-stale user omarchy-shell-config:user:v1 unreferenced
jq --arg source "$sibling_active" \
  '.activeDiscovery={state:"present",sourceDirectory:$source}' \
  "$HOME_DIR/.o7-observation.json" >"$HOME_DIR/.o7-observation.next"
mv "$HOME_DIR/.o7-observation.next" "$HOME_DIR/.o7-observation.json"
sibling_active_request=$(stage_request 82000000-0000-4000-8000-000000000024 "$TOKEN" install acme.o7-stale \
  "$fresh_source" "$fresh_identity" absent '' user omarchy-shell-config:user:v1 \
  "$fresh_projection" unreferenced require-unreferenced)
expect_stage_reason 82000000-0000-4000-8000-000000000024 stale-active-tree "$sibling_active_request"
find "$sibling_active" -depth -delete
printf 'ok - registry-selected active source cannot hide behind a noncanonical directory name\n'

write_observation acme.o7-stale default omarchy-shell-config:packaged-default:v1 unreferenced
request=$(stage_request 82000000-0000-4000-8000-000000000014 "$TOKEN" install acme.o7-stale \
  "$fresh_source" "$fresh_identity" absent '' user omarchy-shell-config:user:v1 \
  "$fresh_projection" unreferenced require-unreferenced)
expect_stage_reason 82000000-0000-4000-8000-000000000014 stale-configuration-source "$request"

write_observation acme.o7-stale user omarchy-shell-config:user:v1 unreferenced
jq --arg projection "$(printf different-projection | base64 -w0)" \
  '.referenceProjectionBase64=$projection' "$HOME_DIR/.o7-observation.json" \
  >"$HOME_DIR/.o7-observation.next"
mv "$HOME_DIR/.o7-observation.next" "$HOME_DIR/.o7-observation.json"
request=$(stage_request 82000000-0000-4000-8000-000000000015 "$TOKEN" install acme.o7-stale \
  "$fresh_source" "$fresh_identity" absent '' user omarchy-shell-config:user:v1 \
  "$EMPTY_DIGEST" unreferenced require-unreferenced)
expect_stage_reason 82000000-0000-4000-8000-000000000015 stale-reference-projection "$request"

write_config acme.o7-stale
write_observation acme.o7-stale user omarchy-shell-config:user:v1 referenced
request=$(stage_request 82000000-0000-4000-8000-000000000016 "$TOKEN" install acme.o7-stale \
  "$fresh_source" "$fresh_identity" absent '' user omarchy-shell-config:user:v1 \
  "$EMPTY_DIGEST" unreferenced require-unreferenced)
expect_stage_reason 82000000-0000-4000-8000-000000000016 require-unreferenced-violation "$request"
printf 'ok - configuration source, projection, state and require-unreferenced are authoritative\n'

write_config
write_observation acme.o7-stale user omarchy-shell-config:user:v1 unreferenced
: >"$HOME_DIR/.o7-shell-unavailable"
request=$(stage_request 82000000-0000-4000-8000-000000000017 "$TOKEN" install acme.o7-stale \
  "$fresh_source" "$fresh_identity" absent '' user omarchy-shell-config:user:v1 \
  "$EMPTY_DIGEST" unreferenced require-unreferenced)
expect_stage_reason 82000000-0000-4000-8000-000000000017 shell-authority-unavailable "$request"
rm "$HOME_DIR/.o7-shell-unavailable"
: >"$HOME_DIR/.o7-shell-not-ready"
expect_stage_reason 82000000-0000-4000-8000-000000000018 shell-authority-not-ready \
  "$(jq -c '.operationId="82000000-0000-4000-8000-000000000018"' <<<"$request")"
rm "$HOME_DIR/.o7-shell-not-ready"
: >"$HOME_DIR/.o7-shell-malformed"
expect_stage_reason 82000000-0000-4000-8000-000000000019 malformed-shell-observation \
  "$(jq -c '.operationId="82000000-0000-4000-8000-000000000019"' <<<"$request")"
rm "$HOME_DIR/.o7-shell-malformed"
printf 'ok - unavailable, unready and malformed shell authority create no operation\n'

write_observation acme.o7-stale default omarchy-shell-config:packaged-default:v1 unreferenced
set +e
caller_observation_output=$(printf '%s' "$(jq -c '.operationId="82000000-0000-4000-8000-000000000020"' <<<"$request")" |
  OMARCHY_PLUGIN_STAGE_OBSERVATION_SOURCE=caller \
  OMARCHY_PLUGIN_EXPECTED_CONFIG_SOURCE_KIND=user \
  OMARCHY_PLUGIN_EXPECTED_CONFIG_SOURCE_IDENTITY=omarchy-shell-config:user:v1 \
  invoke 2>/dev/null)
caller_observation_status=$?
set -e
[[ $caller_observation_status == 0 ]]
jq -e '.reason == "stale-configuration-source"' <<<"$caller_observation_output" >/dev/null
[[ ! -e $STATE_ROOT/journals/82000000-0000-4000-8000-000000000020.journal ]]
printf 'ok - caller observation cannot replace the shell snapshot\n'

update_plugin=acme.o7-update
active_source="$DISCOVERY/$update_plugin"
candidate_source="$TEST_ROOT/update-candidate"
make_interface_plugin "$ROOT" "$active_source" "$update_plugin"
make_interface_plugin "$ROOT" "$candidate_source" "$update_plugin"
printf 'candidate-v2\n' >>"$candidate_source/Service.qml"
active_identity=$("$NATIVE" identity "$active_source")
candidate_identity=$("$NATIVE" identity "$candidate_source")
write_config "$update_plugin"
write_observation "$update_plugin" user omarchy-shell-config:user:v1 referenced
update_projection=$(projection_digest "$update_plugin")
stale_active_request=$(stage_request 82000000-0000-4000-8000-000000000021 "$TOKEN" update "$update_plugin" \
  "$candidate_source" "$candidate_identity" present \
  omarchy-runtime-tree-sha256-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  user omarchy-shell-config:user:v1 "$update_projection" referenced preserve-observed)
expect_stage_reason 82000000-0000-4000-8000-000000000021 stale-active-tree "$stale_active_request"

stale_reference_request=$(stage_request 82000000-0000-4000-8000-000000000023 "$TOKEN" update "$update_plugin" \
  "$candidate_source" "$candidate_identity" present "$active_identity" \
  user omarchy-shell-config:user:v1 "$update_projection" unreferenced preserve-observed)
expect_stage_reason 82000000-0000-4000-8000-000000000023 stale-reference-state "$stale_reference_request"

update_operation=82000000-0000-4000-8000-000000000022
update_request=$(stage_request "$update_operation" "$TOKEN" update "$update_plugin" \
  "$candidate_source" "$candidate_identity" present "$active_identity" \
  user omarchy-shell-config:user:v1 "$update_projection" referenced preserve-observed)
active_before=$("$NATIVE" identity "$active_source")
config_before=$(sha256sum "$HOME_DIR/.config/omarchy/shell.json")
update_output=$(printf '%s' "$update_request" | invoke 2>"$TEST_ROOT/update.err")
jq -e --arg active "sha256:${active_identity##*:}" --arg candidate "sha256:${candidate_identity##*:}" '
  .state == "STAGED" and .candidateTree.digest == $candidate
  and .observedActive == {state:"present",tree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$active}}
  and .observedConfiguration.referenceState == "referenced"' <<<"$update_output" >/dev/null
[[ $("$NATIVE" identity "$active_source") == "$active_before" ]]
[[ $(sha256sum "$HOME_DIR/.config/omarchy/shell.json") == "$config_before" ]]
[[ ! -e $STATE_ROOT/gates/$update_plugin.gate ]]
printf 'ok - authoritative update observes exact active tree and remains inert\n'

concurrent_plugin=acme.o7-concurrent
concurrent_source="$TEST_ROOT/concurrent-source"
make_interface_plugin "$ROOT" "$concurrent_source" "$concurrent_plugin"
concurrent_identity=$("$NATIVE" identity "$concurrent_source")
write_config
write_observation "$concurrent_plugin" user omarchy-shell-config:user:v1 unreferenced
concurrent_request=$(stage_request "$CONCURRENT_OPERATION" "$TOKEN" install "$concurrent_plugin" \
  "$concurrent_source" "$concurrent_identity" absent '' user omarchy-shell-config:user:v1 \
  "$EMPTY_DIGEST" unreferenced require-unreferenced)
mkfifo "$HOME_DIR/.o7-concurrent-ready" "$HOME_DIR/.o7-concurrent-resume" \
  "$(dirname -- "$NATIVE")/concurrent-second-ready"
printf '%s' "$concurrent_request" | invoke >"$TEST_ROOT/concurrent-a.out" 2>"$TEST_ROOT/concurrent-a.err" &
concurrent_a=$!
[[ $(timeout 5 cat "$HOME_DIR/.o7-concurrent-ready") == before-publication ]]
printf '%s' "$concurrent_request" | invoke >"$TEST_ROOT/concurrent-b.out" 2>"$TEST_ROOT/concurrent-b.err" &
concurrent_b=$!
[[ $(timeout 5 cat "$(dirname -- "$NATIVE")/concurrent-second-ready") == second-waiting ]]
kill -0 "$concurrent_b"
[[ ! -s $TEST_ROOT/concurrent-b.out ]]
if flock -n "$STATE_ROOT/locks/operations/$CONCURRENT_OPERATION.lock" true; then
  printf 'not ok - stage did not hold the operation lock at its deterministic barrier\n' >&2
  exit 1
fi
printf 'resume\n' >"$HOME_DIR/.o7-concurrent-resume"
wait "$concurrent_a"
wait "$concurrent_b"
cmp "$TEST_ROOT/concurrent-a.out" "$TEST_ROOT/concurrent-b.out"
[[ $(jq -r .state "$STATE_ROOT/journals/$CONCURRENT_OPERATION.journal") == STAGED ]]
[[ $(find "$STORE/$CONCURRENT_OPERATION" -maxdepth 1 -type d -name candidate | wc -l) == 1 ]]
printf 'ok - deterministic concurrent exact stages join one durable result\n'

[[ ! -e $STATE_ROOT/gates/$install_plugin.gate && ! -e $STATE_ROOT/gates/$concurrent_plugin.gate ]]
[[ ! -e $DISCOVERY/$install_plugin && ! -e $DISCOVERY/$concurrent_plugin ]]
printf 'ok - stage performs no gate, rescan, configuration mutation or plugin execution\n'
