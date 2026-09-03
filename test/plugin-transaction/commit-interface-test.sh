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
OPERATION=83000000-0000-4000-8000-000000000001
PLUGIN=acme.o8
TOKEN=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
PROJECTION=sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432

build_interface_install "$ROOT" "$INSTALL_ROOT"
cp "$ROOT/native/plugin-transaction/shell-gate" "$INSTALL_ROOT/native/plugin-transaction/"
mkdir -p "$HOME_DIR" "$DISCOVERY"
mkdir -p "$STATE_HOME/omarchy/plugin-transactions-v1"/{journals,gates,locks/operations,locks/plugins}
chmod 0700 "$STATE_HOME/omarchy/plugin-transactions-v1" "$STATE_HOME/omarchy/plugin-transactions-v1"/{journals,gates,locks,locks/operations,locks/plugins}
SOURCE="$TEST_ROOT/source"
make_interface_plugin "$ROOT" "$SOURCE" "$PLUGIN"
IDENTITY=$("$INSTALL_ROOT/native/plugin-transaction/plugin-tree" identity "$SOURCE")
RAW_BASE64=$(printf '%s\n' '{"version":1,"plugins":[]}' | base64 -w0)
jq -cnS --arg plugin "$PLUGIN" --arg raw "$RAW_BASE64" --arg discovery "$DISCOVERY" \
  --arg state "$STATE_HOME/omarchy/plugin-transactions-v1" \
  '{valid:true,status:"observed",schema:"omarchy-plugin-stage-observation/v1",pluginId:$plugin,
    configurationSource:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawBase64:$raw,
    referenceProjectionBase64:"b21hcmNoeS1zY2hlbWEtdjEtcmVmZXJlbmNlLXByb2plY3Rpb24vdjEA",
    referenceState:"unreferenced",discoveryDirectory:$discovery,transactionStateRoot:$state,
    activeDiscovery:{state:"absent"}}' >"$HOME_DIR/.o8-observation.json"

cat >"$INSTALL_ROOT/bin/omarchy-shell" <<'SH'
#!/bin/bash
set -euo pipefail
exec 2>>"$HOME/.o8-shell.err"
printf '%s\n' "method=$2" >>"$HOME/.o8-shell-calls"
helper="$OMARCHY_PATH/native/plugin-transaction/plugin-tree"
gate="$OMARCHY_PATH/native/plugin-transaction/shell-gate"
run_gate() {
  OMARCHY_PLUGIN_TREE_HELPER="$helper" \
  OMARCHY_PLUGIN_JOURNAL_VALIDATOR="$OMARCHY_PATH/native/plugin-transaction/validate-journal.jq" \
  OMARCHY_PLUGIN_GATE_VALIDATOR="$OMARCHY_PATH/native/plugin-transaction/validate-gate.jq" \
  OMARCHY_PLUGIN_TRANSACTION_STATE="$XDG_STATE_HOME/omarchy/plugin-transactions-v1" \
  "$gate" "$@" >>"$HOME/.o8-shell.err" 2>&1
}
case "$2" in
  transactionStageObservation)
    if [[ "$3" == acme.o8.update ]]; then
      jq --arg plugin "$3" --arg active "$HOME/.config/omarchy/plugins/repository-folder" \
        '.pluginId=$plugin | .activeDiscovery={state:"present",sourceDirectory:$active} | .referenceState="unreferenced"' "$HOME/.o8-observation.json"
    else
      jq --arg plugin "$3" '.pluginId=$plugin' "$HOME/.o8-observation.json"
    fi
    ;;
  gateTransactionPlugin) run_gate install "$3" "$4" >/dev/null; run_gate acknowledge-unload "$3" "$4" shell-o8 >/dev/null ;;
  rescanGatedPlugin)
    if [[ -e "$HOME/.o8-fail-next-rescan" ]]; then rm -f -- "$HOME/.o8-fail-next-rescan"; exit 70; fi
    destination=$(jq -r .expected.destination "$XDG_STATE_HOME/omarchy/plugin-transactions-v1/gates/$4.gate")
    run_gate acknowledge-rescan "$3" "$4" shell-o8 1 1 "$destination" >/dev/null ;;
  rollbackTransactionPlugin) run_gate retarget-rollback "$3" "$4" shell-o8 "$5" "$6" >/dev/null ;;
  rescanRollbackPlugin)
    rollback_destination=$(jq -r .expected.destination "$XDG_STATE_HOME/omarchy/plugin-transactions-v1/gates/$4.gate")
    run_gate acknowledge-rollback-rescan "$3" "$4" shell-o8 2 2 "$rollback_destination" >/dev/null ;;
  releaseTransactionPlugin) run_gate authorize-release "$3" "$4" shell-o8 1 1 user omarchy-shell-config:user:v1 sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432 unreferenced >/dev/null ;;
  releaseRollbackTransactionPlugin) run_gate authorize-rollback-release "$3" "$4" shell-o8 2 2 user omarchy-shell-config:user:v1 sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432 unreferenced >/dev/null ;;
  retainTransactionPlugin) run_gate retain-release "$3" "$4" shell-o8 1 >/dev/null ;;
  transactionTerminalReceipt) run_gate terminal-receipt "$3" "$4" "$5" >/dev/null ;;
  *) exit 64 ;;
esac
SH
chmod 0755 "$INSTALL_ROOT/bin/omarchy-shell"

export HOME="$HOME_DIR" XDG_STATE_HOME="$STATE_HOME" OMARCHY_PATH="$INSTALL_ROOT"
REQUEST=$(jq -cn --arg operation "$OPERATION" --arg token "$TOKEN" --arg plugin "$PLUGIN" \
  --arg source "$SOURCE" --arg identity "$IDENTITY" --arg projection "$PROJECTION" \
  '{protocol:"legacy-schema-v1-transaction/v1",action:"stage",operationId:$operation,
    operationToken:$token,operation:"install",pluginId:$plugin,source:{kind:"directory",path:$source},
    candidateTree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:("sha256:"+($identity|sub("^omarchy-runtime-tree-sha256-v1:";"")))},
    expectedActive:{state:"absent"},expectedConfiguration:{source:{kind:"user",identity:"omarchy-shell-config:user:v1"},
      referenceProjectionSha256:$projection,referenceState:"unreferenced",referencePolicy:"require-unreferenced"}}')
printf '%s' "$REQUEST" | "$INSTALL_ROOT/bin/omarchy-plugin-transaction" >/dev/null
COMMIT=$(jq -cn --arg operation "$OPERATION" --arg token "$TOKEN" \
  '{protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$operation,operationToken:$token}')
set +e
RESULT=$(printf '%s' "$COMMIT" | "$INSTALL_ROOT/bin/omarchy-plugin-transaction" 2>"$HOME_DIR/.o8-wrapper.err")
COMMIT_STATUS=$?
set -e
[[ $COMMIT_STATUS == 0 ]] || { printf '%s\n' "$RESULT"; find "$STATE_HOME" -maxdepth 8 -type f -print >&2; exit "$COMMIT_STATUS"; }
jq -e --arg operation "$OPERATION" --arg plugin "$PLUGIN" \
  '.action=="commit" and .operationId==$operation and .pluginId==$plugin and .state=="COMMITTED" and .status=="committed"' <<<"$RESULT" >/dev/null
[[ -d "$DISCOVERY/$PLUGIN" && ! -e "$STATE_HOME/omarchy/plugin-candidates-v1/$OPERATION/candidate" ]]
jq -e '.schema=="omarchy-plugin-transaction-journal/v2" and .state=="COMMITTED" and .terminalReceipt.state=="durable"' \
  "$STATE_HOME/omarchy/plugin-transactions-v1/journals/$OPERATION.journal" >/dev/null
printf 'ok - exact commit performs gated atomic fresh-install and terminal receipt handoff\n'

ROLLBACK_OPERATION=83000000-0000-4000-8000-000000000002
ROLLBACK_PLUGIN=acme.o8.rollback
ROLLBACK_SOURCE="$TEST_ROOT/rollback-source"
make_interface_plugin "$ROOT" "$ROLLBACK_SOURCE" "$ROLLBACK_PLUGIN"
ROLLBACK_IDENTITY=$("$INSTALL_ROOT/native/plugin-transaction/plugin-tree" identity "$ROLLBACK_SOURCE")
ROLLBACK_REQUEST=$(jq -cn --arg operation "$ROLLBACK_OPERATION" --arg token "$TOKEN" --arg plugin "$ROLLBACK_PLUGIN" \
  --arg source "$ROLLBACK_SOURCE" --arg identity "$ROLLBACK_IDENTITY" --arg projection "$PROJECTION" \
  '{protocol:"legacy-schema-v1-transaction/v1",action:"stage",operationId:$operation,
    operationToken:$token,operation:"install",pluginId:$plugin,source:{kind:"directory",path:$source},
    candidateTree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:("sha256:"+($identity|sub("^omarchy-runtime-tree-sha256-v1:";"")))},
    expectedActive:{state:"absent"},expectedConfiguration:{source:{kind:"user",identity:"omarchy-shell-config:user:v1"},
      referenceProjectionSha256:$projection,referenceState:"unreferenced",referencePolicy:"require-unreferenced"}}')
printf '%s' "$ROLLBACK_REQUEST" | "$INSTALL_ROOT/bin/omarchy-plugin-transaction" >/dev/null
touch "$HOME_DIR/.o8-fail-next-rescan"
ROLLBACK_COMMIT=$(jq -cn --arg operation "$ROLLBACK_OPERATION" --arg token "$TOKEN" \
  '{protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$operation,operationToken:$token}')
set +e
ROLLBACK_RESULT=$(printf '%s' "$ROLLBACK_COMMIT" | "$INSTALL_ROOT/bin/omarchy-plugin-transaction" 2>"$HOME_DIR/.o8-rollback.err")
ROLLBACK_STATUS=$?
set -e
[[ $ROLLBACK_STATUS == 0 ]] || { printf '%s\n' "$ROLLBACK_RESULT"; cat "$HOME_DIR/.o8-rollback.err" >&2; exit "$ROLLBACK_STATUS"; }
jq -e --arg operation "$ROLLBACK_OPERATION" --arg plugin "$ROLLBACK_PLUGIN" \
  '.action=="commit" and .operationId==$operation and .pluginId==$plugin and .state=="ROLLED_BACK" and .status=="rolled-back"' <<<"$ROLLBACK_RESULT" >/dev/null
[[ ! -e "$DISCOVERY/$ROLLBACK_PLUGIN" && -d "$STATE_HOME/omarchy/plugin-candidates-v1/$ROLLBACK_OPERATION/candidate" ]]
jq -e '.schema=="omarchy-plugin-transaction-journal/v2" and .state=="ROLLED_BACK" and .rollbackEvidence.outcome=="restored"' \
  "$STATE_HOME/omarchy/plugin-transactions-v1/journals/$ROLLBACK_OPERATION.journal" >/dev/null
printf 'ok - post-exposure failure performs exact fresh-install rollback and retains candidate\n'

UPDATE_OPERATION=83000000-0000-4000-8000-000000000003
UPDATE_PLUGIN=acme.o8.update
UPDATE_ACTIVE="$DISCOVERY/repository-folder"
UPDATE_SOURCE="$TEST_ROOT/update-source"
make_interface_plugin "$ROOT" "$UPDATE_ACTIVE" "$UPDATE_PLUGIN"
make_interface_plugin "$ROOT" "$UPDATE_SOURCE" "$UPDATE_PLUGIN"
printf 'candidate-update\n' >>"$UPDATE_SOURCE/Service.qml"
UPDATE_ACTIVE_IDENTITY=$("$INSTALL_ROOT/native/plugin-transaction/plugin-tree" identity "$UPDATE_ACTIVE")
UPDATE_IDENTITY=$("$INSTALL_ROOT/native/plugin-transaction/plugin-tree" identity "$UPDATE_SOURCE")
UPDATE_REQUEST=$(jq -cn --arg operation "$UPDATE_OPERATION" --arg token "$TOKEN" --arg plugin "$UPDATE_PLUGIN" \
  --arg source "$UPDATE_SOURCE" --arg identity "$UPDATE_IDENTITY" --arg active "$UPDATE_ACTIVE_IDENTITY" --arg projection "$PROJECTION" \
  '{protocol:"legacy-schema-v1-transaction/v1",action:"stage",operationId:$operation,
    operationToken:$token,operation:"update",pluginId:$plugin,source:{kind:"directory",path:$source},
    candidateTree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:("sha256:"+($identity|sub("^omarchy-runtime-tree-sha256-v1:";"")))},
    expectedActive:{state:"present",tree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:("sha256:"+($active|sub("^omarchy-runtime-tree-sha256-v1:";""))) }},
    expectedConfiguration:{source:{kind:"user",identity:"omarchy-shell-config:user:v1"},
      referenceProjectionSha256:$projection,referenceState:"unreferenced",referencePolicy:"preserve-observed"}}')
printf '%s' "$UPDATE_REQUEST" | "$INSTALL_ROOT/bin/omarchy-plugin-transaction" >/dev/null
UPDATE_COMMIT=$(jq -cn --arg operation "$UPDATE_OPERATION" --arg token "$TOKEN" \
  '{protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$operation,operationToken:$token}')
UPDATE_RESULT=$(printf '%s' "$UPDATE_COMMIT" | "$INSTALL_ROOT/bin/omarchy-plugin-transaction")
jq -e --arg operation "$UPDATE_OPERATION" --arg plugin "$UPDATE_PLUGIN" \
  '.action=="commit" and .operationId==$operation and .pluginId==$plugin and .state=="COMMITTED" and .status=="committed"' <<<"$UPDATE_RESULT" >/dev/null
UPDATE_JOURNAL="$STATE_HOME/omarchy/plugin-transactions-v1/journals/$UPDATE_OPERATION.journal"
jq -e --arg destination "$UPDATE_ACTIVE" --arg prior "$UPDATE_ACTIVE_IDENTITY" \
  '.state=="COMMITTED" and .normalizedRequest.facts.destination==$destination and .retainedPrior.state=="captured" and .retainedPrior.identity==$prior' "$UPDATE_JOURNAL" >/dev/null
[[ -d "$DISCOVERY/repository-folder" && -d "$STATE_HOME/omarchy/plugin-candidates-v1/$UPDATE_OPERATION/candidate" ]]
[[ $("$INSTALL_ROOT/native/plugin-transaction/plugin-tree" identity "$STATE_HOME/omarchy/plugin-candidates-v1/$UPDATE_OPERATION/candidate") == "$UPDATE_ACTIVE_IDENTITY" ]]
printf 'ok - update exchange preserves authoritative basename-independent destination and retained prior\n'

UPDATE_ROLLBACK_OPERATION=83000000-0000-4000-8000-000000000004
UPDATE_ROLLBACK_SOURCE="$TEST_ROOT/update-rollback-source"
make_interface_plugin "$ROOT" "$UPDATE_ROLLBACK_SOURCE" "$UPDATE_PLUGIN"
printf 'candidate-update-2\n' >>"$UPDATE_ROLLBACK_SOURCE/Service.qml"
UPDATE_ROLLBACK_IDENTITY=$("$INSTALL_ROOT/native/plugin-transaction/plugin-tree" identity "$UPDATE_ROLLBACK_SOURCE")
UPDATE_ROLLBACK_REQUEST=$(jq -cn --arg operation "$UPDATE_ROLLBACK_OPERATION" --arg token "$TOKEN" --arg plugin "$UPDATE_PLUGIN" \
  --arg source "$UPDATE_ROLLBACK_SOURCE" --arg identity "$UPDATE_ROLLBACK_IDENTITY" --arg active "$UPDATE_IDENTITY" --arg projection "$PROJECTION" \
  '{protocol:"legacy-schema-v1-transaction/v1",action:"stage",operationId:$operation,
    operationToken:$token,operation:"update",pluginId:$plugin,source:{kind:"directory",path:$source},
    candidateTree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:("sha256:"+($identity|sub("^omarchy-runtime-tree-sha256-v1:";"")))},
    expectedActive:{state:"present",tree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:("sha256:"+($active|sub("^omarchy-runtime-tree-sha256-v1:";""))) }},
    expectedConfiguration:{source:{kind:"user",identity:"omarchy-shell-config:user:v1"},
      referenceProjectionSha256:$projection,referenceState:"unreferenced",referencePolicy:"preserve-observed"}}')
printf '%s' "$UPDATE_ROLLBACK_REQUEST" | "$INSTALL_ROOT/bin/omarchy-plugin-transaction" >/dev/null
touch "$HOME_DIR/.o8-fail-next-rescan"
UPDATE_ROLLBACK_COMMIT=$(jq -cn --arg operation "$UPDATE_ROLLBACK_OPERATION" --arg token "$TOKEN" \
  '{protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$operation,operationToken:$token}')
set +e
UPDATE_ROLLBACK_RESULT=$(printf '%s' "$UPDATE_ROLLBACK_COMMIT" | "$INSTALL_ROOT/bin/omarchy-plugin-transaction")
UPDATE_ROLLBACK_STATUS=$?
set -e
if [[ $UPDATE_ROLLBACK_STATUS != 0 ]]; then cat "$HOME_DIR/.o8-shell.err" >&2; printf '%s\n' "$UPDATE_ROLLBACK_RESULT" >&2; exit "$UPDATE_ROLLBACK_STATUS"; fi
jq -e --arg operation "$UPDATE_ROLLBACK_OPERATION" --arg plugin "$UPDATE_PLUGIN" \
  '.action=="commit" and .operationId==$operation and .pluginId==$plugin and .state=="ROLLED_BACK" and .status=="rolled-back"' <<<"$UPDATE_ROLLBACK_RESULT" >/dev/null
[[ $("$INSTALL_ROOT/native/plugin-transaction/plugin-tree" identity "$UPDATE_ACTIVE") == "$UPDATE_IDENTITY" ]]
[[ $("$INSTALL_ROOT/native/plugin-transaction/plugin-tree" identity "$STATE_HOME/omarchy/plugin-candidates-v1/$UPDATE_ROLLBACK_OPERATION/candidate") == "$UPDATE_ROLLBACK_IDENTITY" ]]
printf 'ok - update rollback reverses exchange and restores the basename-independent prior tree\n'
