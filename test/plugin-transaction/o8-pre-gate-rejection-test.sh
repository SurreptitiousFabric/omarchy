#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/interface-test-lib.sh"

ROOT=$(interface_test_root)
TEST_ROOT=$(mktemp -d)
trap 'find "$TEST_ROOT" -mindepth 1 -delete; rmdir "$TEST_ROOT"' EXIT
INSTALL_ROOT="$TEST_ROOT/install/share/omarchy"
HOME_DIR="$TEST_ROOT/home"
STATE_HOME="$TEST_ROOT/state"
DISCOVERY="$HOME_DIR/.config/omarchy/plugins"
TOKEN=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
PROJECTION=sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432
RAW_BASE64=$(printf '%s\n' '{"version":1,"plugins":[]}' | base64 -w0)

build_interface_install "$ROOT" "$INSTALL_ROOT"
mkdir -p "$HOME_DIR" "$DISCOVERY"
initialize_transaction_state "$STATE_HOME/omarchy/plugin-transactions-v1"

cat >"$INSTALL_ROOT/bin/omarchy-shell" <<'SH'
#!/bin/bash
set -euo pipefail
case "$2" in
  transactionStageObservation)
    if [[ -f "$HOME/.o8-mutate-candidate" ]]; then
      candidate=$(<"$HOME/.o8-mutate-candidate")
      printf '\nlocked-recheck-mutation\n' >>"$candidate/Service.qml"
      rm -f -- "$HOME/.o8-mutate-candidate"
    fi
    jq --arg plugin "$3" '.pluginId=$plugin' "$HOME/.o8-observation.json"
    ;;
  gateTransactionPlugin|rescanGatedPlugin|releaseTransactionPlugin|rollbackTransactionPlugin|rescanRollbackPlugin|retainTransactionPlugin|transactionTerminalReceipt|transactionTerminalReconcile)
    exit 70
    ;;
  transactionPluginState)
    jq -cn --arg operation "$3" '{operationId:$operation,status:"unknown"}'
    ;;
  *) exit 64 ;;
esac
SH
chmod 0755 "$INSTALL_ROOT/bin/omarchy-shell"

export HOME="$HOME_DIR"
export XDG_STATE_HOME="$STATE_HOME"
export OMARCHY_PATH="$INSTALL_ROOT"

write_observation() {
  local plugin=$1 config_kind=$2 config_identity=$3 reference_state=$4
  local active_state=${5:-absent} active_source=${6:-}
  jq -cnS --arg plugin "$plugin" --arg config_kind "$config_kind" \
    --arg config_identity "$config_identity" --arg reference_state "$reference_state" \
    --arg raw "$RAW_BASE64" --arg projection "b21hcmNoeS1zY2hlbWEtdjEtcmVmZXJlbmNlLXByb2plY3Rpb24vdjEA" \
    --arg discovery "$DISCOVERY" --arg state_root "$STATE_HOME/omarchy/plugin-transactions-v1" \
    --arg active_state "$active_state" --arg active_source "$active_source" '
    {valid:true,status:"observed",schema:"omarchy-plugin-stage-observation/v1",pluginId:$plugin,
     configurationEpoch:1,configurationSource:{kind:$config_kind,identity:$config_identity},rawBase64:$raw,
     referenceProjectionBase64:$projection,referenceState:$reference_state,
     discoveryDirectory:$discovery,transactionStateRoot:$state_root,
     activeDiscovery:(if $active_state == "present" then {state:"present",sourceDirectory:$active_source} else {state:"absent"} end)}' \
    >"$HOME_DIR/.o8-observation.json"
}

stage_request() {
  local operation=$1 plugin=$2 source=$3 identity=$4 kind=$5 active_identity=$6 \
    config_kind=$7 config_identity=$8 expected_projection=$9 expected_state=${10} policy=${11}
  jq -cn --arg operation_id "$operation" --arg token "$TOKEN" --arg plugin "$plugin" \
    --arg source "$source" --arg identity "$identity" --arg kind "$kind" \
    --arg active "$active_identity" --arg config_kind "$config_kind" \
    --arg config_identity "$config_identity" --arg projection "$expected_projection" \
    --arg expected_state "$expected_state" --arg policy "$policy" '
    {protocol:"legacy-schema-v1-transaction/v1",action:"stage",operationId:$operation_id,
     operationToken:$token,operation:(if $kind == "install" then "install" else "update" end),pluginId:$plugin,
     source:{kind:"directory",path:$source},
     candidateTree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:("sha256:"+($identity|sub("^omarchy-runtime-tree-sha256-v1:";"")))},
    expectedActive:(if $kind == "install" then {state:"absent"} else {state:"present",tree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:("sha256:"+($active|sub("^omarchy-runtime-tree-sha256-v1:";"")))}} end),
     expectedConfiguration:{source:{kind:$config_kind,identity:$config_identity},referenceProjectionSha256:$projection,
       referenceState:$expected_state,referencePolicy:$policy}}'
}

commit_request() {
  jq -cn --arg operation_id "$1" --arg token "$TOKEN" \
    '{protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$operation_id,operationToken:$token}'
}

status_request() {
  jq -cn --arg operation_id "$1" \
    '{protocol:"legacy-schema-v1-transaction/v1",action:"status",operationId:$operation_id}'
}

assert_rejected() {
  local operation=$1 plugin=$2 expected_reason=$3 candidate_path=$4 destination=$5
  local candidate_mode=${6:-present} destination_mode=${7:-absent}
  local result status retry status_result journal_path journal_sha abort_status abort_result
  local request
  request=$(commit_request "$operation")
  set +e
  result=$(printf '%s' "$request" | "$INSTALL_ROOT/bin/omarchy-plugin-transaction" 2>"$TEST_ROOT/$operation.stderr")
  status=$?
  set -e
  (( status == 0 )) || { printf '%s\n' "$result" >&2; cat "$TEST_ROOT/$operation.stderr" >&2; return 1; }
  jq -e --arg operation "$operation" --arg plugin "$plugin" --arg reason "$expected_reason" '
    .action=="commit" and .operationId==$operation and .pluginId==$plugin
    and .state=="REJECTED" and .status=="rejected" and .reason==$reason
    and .eligibility.durableOutcome=="not-gated" and .eligibility.currentShell=="not-observed"' \
    <<<"$result" >/dev/null
  journal_path="$STATE_HOME/omarchy/plugin-transactions-v1/journals/$operation.journal"
  jq -e --arg operation "$operation" --arg plugin "$plugin" --arg reason "$expected_reason" '
    .schema=="omarchy-plugin-transaction-journal/v2" and .operationId==$operation and .pluginId==$plugin
    and .state=="REJECTED" and .reason==$reason and .gate=="not-established"
    and .namespaceIntent.state=="none" and .rollback=="not-applicable"
    and .rollbackEvidence.state=="not-started" and .rollbackEvidence.outcome=="not-applicable"
    and .terminalReceipt.state=="not-requested" and .preExposureEvidence==null' \
    "$journal_path" >/dev/null
  [[ ! -e "$STATE_HOME/omarchy/plugin-transactions-v1/gates/$plugin.gate" ]]
  journal_sha=$(sha256sum "$journal_path")
  status_result=$(printf '%s' "$(status_request "$operation")" | "$INSTALL_ROOT/bin/omarchy-plugin-transaction")
  jq -e --arg operation "$operation" --arg plugin "$plugin" --arg reason "$expected_reason" '
    .action=="status" and .operationId==$operation and .pluginId==$plugin
    and .state=="REJECTED" and .status=="rejected" and .reason==$reason' \
    <<<"$status_result" >/dev/null
  retry=$(printf '%s' "$request" | "$INSTALL_ROOT/bin/omarchy-plugin-transaction")
  [[ $(jq -cS . <<<"$retry") == $(jq -cS . <<<"$result") ]]
  set +e
  abort_result=$(jq -cn --arg operation_id "$operation" --arg token "$TOKEN" \
    '{protocol:"legacy-schema-v1-transaction/v1",action:"abort",operationId:$operation_id,operationToken:$token}' |
    "$INSTALL_ROOT/bin/omarchy-plugin-transaction" 2>/dev/null)
  abort_status=$?
  set -e
  (( abort_status != 0 )) || { printf 'abort unexpectedly accepted REJECTED: %s\n' "$abort_result" >&2; return 1; }
  [[ $(sha256sum "$journal_path") == "$journal_sha" ]]
  if [[ $candidate_mode == absent ]]; then
    [[ ! -e "$candidate_path" ]]
  else
    [[ -d "$candidate_path" && ! -L "$candidate_path" ]]
  fi
  if [[ $destination_mode == absent ]]; then
    [[ ! -e "$destination" ]]
  else
    [[ -e "$destination" && ! -L "$destination" ]]
  fi
}

run_install_case() {
  local suffix=$1 expected_reason=$2 mutation=$3
  local operation="84000000-0000-4000-8000-0000000000$suffix"
  local plugin="acme.o8.reject-$suffix" source="$TEST_ROOT/source-$suffix" identity destination
  mkdir -p "$source"
  make_interface_plugin "$ROOT" "$source" "$plugin"
  identity=$("$INSTALL_ROOT/native/plugin-transaction/plugin-tree" identity "$source")
  destination="$DISCOVERY/$plugin"
  write_observation "$plugin" user omarchy-shell-config:user:v1 unreferenced
  local request
  request=$(stage_request "$operation" "$plugin" "$source" "$identity" install "" user \
    omarchy-shell-config:user:v1 "$PROJECTION" unreferenced require-unreferenced)
  jq -e '.operation=="install"' <<<"$request" >/dev/null
  printf '%s' "$request" | "$INSTALL_ROOT/bin/omarchy-plugin-transaction" >/dev/null
  [[ $(jq -r .state "$STATE_HOME/omarchy/plugin-transactions-v1/journals/$operation.journal") == STAGED ]]
  case "$mutation" in
    candidate)
      rm -rf -- "$STATE_HOME/omarchy/plugin-candidates-v1/$operation/candidate"
      ;;
    candidate-locked)
      printf '%s\n' "$STATE_HOME/omarchy/plugin-candidates-v1/$operation/candidate" >"$HOME_DIR/.o8-mutate-candidate"
      ;;
    active)
      printf 'occupied\n' >"$destination"
      ;;
    config)
      jq '.configurationSource={kind:"default",identity:"omarchy-shell-config:packaged-default:v1"}' \
        "$HOME_DIR/.o8-observation.json" >"$HOME_DIR/.o8-observation.next"
      mv "$HOME_DIR/.o8-observation.next" "$HOME_DIR/.o8-observation.json"
      ;;
    projection)
      jq '.referenceProjectionBase64=("different-projection"|@base64)' \
        "$HOME_DIR/.o8-observation.json" >"$HOME_DIR/.o8-observation.next"
      mv "$HOME_DIR/.o8-observation.next" "$HOME_DIR/.o8-observation.json"
      ;;
    reference)
      jq '.referenceState="referenced"' "$HOME_DIR/.o8-observation.json" >"$HOME_DIR/.o8-observation.next"
      mv "$HOME_DIR/.o8-observation.next" "$HOME_DIR/.o8-observation.json"
      ;;
    *) printf 'unknown mutation %s\n' "$mutation" >&2; return 1 ;;
  esac
  local candidate_mode=present destination_mode=absent
  [[ $mutation == candidate ]] && candidate_mode=absent
  [[ $mutation == active ]] && destination_mode=present
  assert_rejected "$operation" "$plugin" "$expected_reason" \
    "$STATE_HOME/omarchy/plugin-candidates-v1/$operation/candidate" "$destination" \
    "$candidate_mode" "$destination_mode"
  printf 'ok - O-8 commit pre-gate %s is durable REJECTED and exact replay is stable\n' "$expected_reason"
}

run_update_case() {
  local suffix=$1 expected_reason=$2 registry=$3
  local operation="84000000-0000-4000-8000-0000000000$suffix"
  local plugin="acme.o8.reject-update-$suffix" source="$TEST_ROOT/update-source-$suffix"
  local active="$DISCOVERY/$plugin"
  local identity active_identity request
  mkdir -p "$source" "$active"
  make_interface_plugin "$ROOT" "$source" "$plugin"
  make_interface_plugin "$ROOT" "$active" "$plugin"
  identity=$("$INSTALL_ROOT/native/plugin-transaction/plugin-tree" identity "$source")
  active_identity=$("$INSTALL_ROOT/native/plugin-transaction/plugin-tree" identity "$active")
  write_observation "$plugin" user omarchy-shell-config:user:v1 unreferenced present "$active"
  request=$(stage_request "$operation" "$plugin" "$source" "$identity" update "$active_identity" user \
    omarchy-shell-config:user:v1 "$PROJECTION" unreferenced preserve-observed)
  printf '%s' "$request" | "$INSTALL_ROOT/bin/omarchy-plugin-transaction" >/dev/null
  [[ $(jq -r .state "$STATE_HOME/omarchy/plugin-transactions-v1/journals/$operation.journal") == STAGED ]]
  if [[ $registry == true ]]; then
    local wrong="$DISCOVERY/wrong-source-$suffix"
    mkdir -p "$wrong"
    jq --arg wrong "$wrong" '.activeDiscovery={state:"present",sourceDirectory:$wrong}' \
      "$HOME_DIR/.o8-observation.json" >"$HOME_DIR/.o8-observation.next"
  else
    jq '.referenceState="referenced"' "$HOME_DIR/.o8-observation.json" >"$HOME_DIR/.o8-observation.next"
  fi
  mv "$HOME_DIR/.o8-observation.next" "$HOME_DIR/.o8-observation.json"
  assert_rejected "$operation" "$plugin" "$expected_reason" \
    "$STATE_HOME/omarchy/plugin-candidates-v1/$operation/candidate" "$active" present present
  printf 'ok - O-8 commit pre-gate %s is durable REJECTED and exact replay is stable\n' "$expected_reason"
}

run_install_case 01 stale-candidate candidate
run_install_case 02 stale-candidate candidate-locked
run_install_case 03 stale-active-tree active
run_install_case 04 stale-configuration-source config
run_install_case 05 stale-reference-projection projection
run_install_case 06 require-unreferenced-violation reference
run_update_case 07 stale-reference-state false
run_update_case 08 registry-source-ambiguous true

printf 'ok - all O-8 pre-gate typed rejection cases use independent literal reasons\n'
