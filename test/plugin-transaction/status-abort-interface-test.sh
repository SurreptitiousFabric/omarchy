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
STAGE="$INSTALL_ROOT/native/plugin-transaction/stage-candidate"
VALIDATOR="$INSTALL_ROOT/bin/omarchy-plugin-validate"
JOURNAL_VALIDATOR="$INSTALL_ROOT/native/plugin-transaction/validate-journal.jq"
TOKEN=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
WRONG_TOKEN=QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI
EMPTY_DIGEST=sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432

build_interface_install "$ROOT" "$INSTALL_ROOT"
initialize_transaction_state "$STATE_ROOT"
mkdir -p "$HOME_DIR" "$DISCOVERY"
jq -nS '{version:1,bar:{layout:{left:[],center:[],right:[]}},plugins:[]}' \
  >"$HOME_DIR/.config/omarchy/shell.json"

mv "$NATIVE" "$NATIVE.real"
cat >"$NATIVE" <<'SH'
#!/bin/bash
set -euo pipefail
directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
real="$directory/plugin-tree.real"
if [[ ${1:-} == ordered-lock && -f $directory/omit-plugin-lock-negative ]]; then
  exec {operation_fd}>"$2/locks/operations/$3.lock"
  chmod 0600 "$2/locks/operations/$3.lock"
  flock "$operation_fd"
  printf 'locked-operation-then-plugin\n'
  read -r _ || true
  exit 0
fi
if [[ ${1:-} == operation-lock && -f $directory/stage-wait-operation &&
    ${3:-} == "$(<"$directory/stage-wait-operation")" ]]; then
  printf 'stage-waiting\n' >"$directory/stage-wait-ready"
fi
if [[ ${1:-} == ordered-lock && -e $directory/hold-after-operation ]]; then
  export OMARCHY_PLUGIN_TREE_TEST_HOOK=after-ordered-operation-lock
  export OMARCHY_PLUGIN_TREE_TEST_READY_FIFO="$directory/operation-ready"
  export OMARCHY_PLUGIN_TREE_TEST_RESUME_FIFO="$directory/operation-resume"
fi
if [[ ${1:-} == identity && -f $directory/hold-candidate-operation ]]; then
  operation=$(<"$directory/hold-candidate-operation")
  if [[ ${2:-} == */plugin-candidates-v1/$operation/candidate ]]; then
    printf 'locks-held\n' >"$directory/both-ready"
    read -r _ <"$directory/both-resume"
  fi
fi
if [[ ${1:-} == journal-replace && ${5:-} == staged-to-aborted && -f $directory/abort-fault ]]; then
  fault=$(<"$directory/abort-fault")
  case $fault in
    before-write) export OMARCHY_PLUGIN_TREE_TEST_CRASH_POINT=before-journal-write:staged-to-aborted ;;
    after-write) export OMARCHY_PLUGIN_TREE_TEST_CRASH_POINT=after-journal-write:staged-to-aborted ;;
    file-fsync) export OMARCHY_PLUGIN_TREE_TEST_FAIL_FSYNC=journal-file:staged-to-aborted ;;
    after-file-fsync) export OMARCHY_PLUGIN_TREE_TEST_CRASH_POINT=after-journal-file-sync:staged-to-aborted ;;
    rename) export OMARCHY_PLUGIN_TREE_TEST_FAIL_RENAME=journal-rename:staged-to-aborted ;;
    after-rename) export OMARCHY_PLUGIN_TREE_TEST_CRASH_POINT=after-journal-rename:staged-to-aborted ;;
    parent-fsync) export OMARCHY_PLUGIN_TREE_TEST_FAIL_FSYNC=journal-parent:staged-to-aborted ;;
  esac
fi
if [[ (${1:-} == journal-read || ${1:-} == journal-read-locked || ${1:-} == journal-read-held) && -f $directory/status-write-negative ]]; then
  touch -m -d '2002-01-01 UTC' "$2/journals/$3.journal"
fi
if [[ (${1:-} == journal-read-locked || ${1:-} == journal-read-held) && -f $directory/journal-authority-fault ]]; then
  export OMARCHY_PLUGIN_TREE_TEST_FAIL_FSYNC=journal-reconciliation-parent
fi
exec "$real" "$@"
SH
chmod 0755 "$NATIVE"

invoke() {
  HOME="$HOME_DIR" XDG_STATE_HOME="$STATE_HOME" "$COMMAND"
}

stage_direct() {
  local operation=$1 plugin=$2 source=$3 operation_kind=${4:-install}
  local active_state=${5:-absent} active_identity=${6:-} reference_state=${7:-unreferenced}
  local policy=${8:-require-unreferenced} projection=${9:-$EMPTY_DIGEST} identity
  identity=$("$NATIVE" identity "$source")
  HOME="$HOME_DIR" XDG_STATE_HOME="$STATE_HOME" OMARCHY_PATH="$INSTALL_ROOT" \
    OMARCHY_PLUGIN_TREE_HELPER="$NATIVE" OMARCHY_PLUGIN_VALIDATOR="$VALIDATOR" \
    OMARCHY_PLUGIN_JOURNAL_VALIDATOR="$JOURNAL_VALIDATOR" \
    OMARCHY_PLUGIN_CANDIDATE_STORE="$STORE" OMARCHY_PLUGIN_TRANSACTION_STATE="$STATE_ROOT" \
    OMARCHY_PLUGIN_DISCOVERY_DIR="$DISCOVERY" OMARCHY_PLUGIN_OPERATION_KIND="$operation_kind" \
    OMARCHY_PLUGIN_SOURCE_KIND=directory OMARCHY_PLUGIN_CALLER_CANDIDATE_IDENTITY="$identity" \
    OMARCHY_PLUGIN_EXPECTED_ACTIVE_STATE="$active_state" \
    OMARCHY_PLUGIN_EXPECTED_ACTIVE_IDENTITY="$active_identity" \
    OMARCHY_PLUGIN_EXPECTED_CONFIG_SOURCE_KIND=user \
    OMARCHY_PLUGIN_EXPECTED_CONFIG_SOURCE_IDENTITY=omarchy-shell-config:user:v1 \
    OMARCHY_PLUGIN_EXPECTED_REFERENCE_PROJECTION="$projection" \
    OMARCHY_PLUGIN_EXPECTED_REFERENCE_STATE="$reference_state" \
    OMARCHY_PLUGIN_REFERENCE_POLICY="$policy" \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_SOURCE=shell-authoritative-o7 \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_RAW_SHA256=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_REFERENCE_PROJECTION="$projection" \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_REFERENCE_STATE="$reference_state" \
    OMARCHY_PLUGIN_DESTINATION="$DISCOVERY/$plugin" \
    "$STAGE" "$operation" "$plugin" "$source" <<<"$TOKEN" >/dev/null
}

status_request() {
  jq -cnS --arg operation "$1" \
    '{protocol:"legacy-schema-v1-transaction/v1",action:"status",operationId:$operation}'
}

abort_request() {
  jq -cnS --arg operation "$1" --arg token "${2:-$TOKEN}" \
    '{protocol:"legacy-schema-v1-transaction/v1",action:"abort",operationId:$operation,operationToken:$token}'
}

status_operation() {
  printf '%s' "$(status_request "$1")" | invoke
}

abort_operation() {
  printf '%s' "$(abort_request "$1" "${2:-$TOKEN}")" | invoke
}

public_stage_request() {
  local journal_path=$1
  jq -cS --arg token "$TOKEN" '
    .normalizedRequest.facts as $facts
    | {protocol:"legacy-schema-v1-transaction/v1",action:"stage",
       operationId:.operationId,operationToken:$token,operation:$facts.operation,pluginId:.pluginId,
       source:$facts.source,
       candidateTree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:("sha256:" + ($facts.callerCandidateIdentity | sub("^omarchy-runtime-tree-sha256-v1:";"")))},
       expectedActive:(if $facts.expectedActive.state == "absent" then {state:"absent"}
         else {state:"present",tree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:("sha256:" + ($facts.expectedActive.identity | sub("^omarchy-runtime-tree-sha256-v1:";"")))}} end),
       expectedConfiguration:{source:$facts.expectedConfiguration.source,
         referenceProjectionSha256:$facts.expectedConfiguration.referenceProjection,
         referenceState:$facts.expectedConfiguration.referenceState,
         referencePolicy:$facts.expectedConfiguration.referencePolicy}}' "$journal_path"
}

source_for() {
  local operation=$1 plugin=$2 source
  source="$TEST_ROOT/source-$operation"
  make_interface_plugin "$ROOT" "$source" "$plugin"
  printf '%s\n' "$source"
}

missing_home="$TEST_ROOT/missing-home"
missing_state="$TEST_ROOT/missing-state"
before_missing=$(find "$missing_home" "$missing_state" -print 2>/dev/null | sort || true)
missing_output=$(printf '%s' "$(status_request 83000000-0000-4000-8000-000000000001)" |
  HOME="$missing_home" XDG_STATE_HOME="$missing_state" "$COMMAND" 2>"$TEST_ROOT/missing.err")
after_missing=$(find "$missing_home" "$missing_state" -print 2>/dev/null | sort || true)
jq -e '.status == "not-found" and .reason == "operation-not-found"' <<<"$missing_output" >/dev/null
[[ $before_missing == "$after_missing" ]]
printf 'ok - missing status is stable and creates no state or lock\n'

declare -A state_operations
state_index=10
for durable_state in REQUEST_BOUND PUBLICATION_INTENT STAGED RECOVERY_REQUIRED MANUAL_ATTENTION ABORTED; do
  printf -v operation '83000000-0000-4000-8000-%012d' "$state_index"
  plugin=acme.o7-status-${durable_state,,}
  source=$(source_for "$operation" "$plugin")
  stage_direct "$operation" "$plugin" "$source"
  journal="$STATE_ROOT/journals/$operation.journal"
  case $durable_state in
    REQUEST_BOUND)
      jq -cS '.state="REQUEST_BOUND" | .candidate.observed=null | .publication.state="not-started" | .reason=null' \
        "$journal" >"$journal.next"
      find "$STORE/$operation" -depth -delete
      ;;
    PUBLICATION_INTENT)
      jq -cS '.state="PUBLICATION_INTENT" | .publication.state="intended" | .reason=null' \
        "$journal" >"$journal.next"
      ;;
    STAGED) cp "$journal" "$journal.next" ;;
    RECOVERY_REQUIRED)
      jq -cS '.state="RECOVERY_REQUIRED" | .publication.state="indeterminate" | .reason="publication-indeterminate"' \
        "$journal" >"$journal.next"
      ;;
    MANUAL_ATTENTION)
      jq -cS '.state="MANUAL_ATTENTION" | .publication.state="contradictory" | .reason="missing-candidate"' \
        "$journal" >"$journal.next"
      ;;
    ABORTED)
      jq -cS '.state="ABORTED" | .reason="owner-aborted"' "$journal" >"$journal.next"
      ;;
  esac
  chmod 0600 "$journal.next"
  mv "$journal.next" "$journal"
  jq -e --arg operation_id "$operation" -f "$JOURNAL_VALIDATOR" "$journal" >/dev/null
  state_operations[$durable_state]=$operation
  output=$(status_operation "$operation" 2>"$TEST_ROOT/status-$durable_state.err")
  jq -e --arg state "$durable_state" '.action == "status" and .state == $state
    and (has("capabilityHash") | not) and (tostring | contains("AAAAAAAAAAAAAAAA") | not)' \
    <<<"$output" >/dev/null
  ((state_index++))
done
printf 'ok - status redacts and reports every durable O-5/O-7 state\n'

status_operation_id=${state_operations[STAGED]}
status_journal="$STATE_ROOT/journals/$status_operation_id.journal"
legacy_identity="$TEST_ROOT/private-shell.json"
jq -cS --arg identity "$legacy_identity" '
  .normalizedRequest.facts.expectedConfiguration.source.identity=$identity
  | .normalizedRequest.facts.stageObservation.provenance="test-injected-o5"
' "$status_journal" >"$status_journal.next"
legacy_facts=$(jq -cS '.normalizedRequest.facts' "$status_journal.next")
legacy_digest=$(printf '%s\n' "$legacy_facts" | "$NATIVE" domain-hash omarchy-plugin-transaction-request/v1)
jq -cS --arg digest "$legacy_digest" '.normalizedRequest.digest=$digest' \
  "$status_journal.next" >"$status_journal.redacted"
chmod 0600 "$status_journal.redacted"
mv "$status_journal.redacted" "$status_journal"
rm "$status_journal.next"
legacy_status=$(status_operation "$status_operation_id" 2>"$TEST_ROOT/status-legacy.err")
jq -e '.observedConfiguration.source.identity == null' <<<"$legacy_status" >/dev/null
[[ $legacy_status != *"$legacy_identity"* ]]
printf 'ok - status redacts historical non-opaque configuration source identities\n'

status_hash_before=$(sha256sum "$status_journal")
touch -a -d '2001-01-01 UTC' "$status_journal"
status_metadata_before=$(stat -c '%d:%i:%s:%a:%X:%Y:%Z' "$status_journal")
status_entries_before=$(find "$STATE_ROOT" "$STORE" "$DISCOVERY" -printf '%p|%y|%m|%s|%i\n' | sort)
status_output=$(status_operation "$status_operation_id" 2>"$TEST_ROOT/status-readonly.err")
status_metadata_after=$(stat -c '%d:%i:%s:%a:%X:%Y:%Z' "$status_journal")
status_entries_after=$(find "$STATE_ROOT" "$STORE" "$DISCOVERY" -printf '%p|%y|%m|%s|%i\n' | sort)
status_hash_after=$(sha256sum "$status_journal")
[[ $status_metadata_before == "$status_metadata_after" && $status_entries_before == "$status_entries_after"
    && $status_hash_before == "$status_hash_after" ]]
[[ ! -s $TEST_ROOT/status-readonly.err ]]
printf 'ok - status preserves journal bytes, inode, timestamps and all scoped directory entries\n'

status_negative_marker=$(dirname -- "$NATIVE")/status-write-negative
: >"$status_negative_marker"
status_negative_before=$(stat -c '%d:%i:%s:%a:%X:%Y:%Z' "$status_journal")
status_operation "$status_operation_id" >/dev/null 2>"$TEST_ROOT/status-write-negative.err"
status_negative_after=$(stat -c '%d:%i:%s:%a:%X:%Y:%Z' "$status_journal")
rm "$status_negative_marker"
[[ $status_negative_before != "$status_negative_after" ]] || {
  printf 'not ok - status-write negative control escaped the metadata proof\n' >&2
  exit 1
}
printf 'ok - status-write negative control trips the read-only metadata proof\n'

set +e
token_status_output=$(printf '%s' "$(status_request "$status_operation_id" | jq -c --arg token "$TOKEN" '.operationToken=$token')" |
  invoke 2>/dev/null)
token_status_code=$?
set -e
[[ $token_status_code == 2 ]]
jq -e '.reason == "invalid-request-schema"' <<<"$token_status_output" >/dev/null
printf 'ok - status neither requires nor accepts an operation token\n'

invalid_case() {
  local suffix=$1 kind=$2 operation plugin source journal before after output code
  printf -v operation '83100000-0000-4000-8000-%012d' "$suffix"
  plugin=acme.o7-invalid-$suffix
  source=$(source_for "$operation" "$plugin")
  stage_direct "$operation" "$plugin" "$source"
  journal="$STATE_ROOT/journals/$operation.journal"
  case $kind in
    corrupt) printf '{\n' >"$journal"; chmod 0600 "$journal" ;;
    noncanonical) jq . "$journal" >"$journal.next"; mv "$journal.next" "$journal"; chmod 0600 "$journal" ;;
    contradictory) jq -cS '.gate="established"' "$journal" >"$journal.next"; mv "$journal.next" "$journal"; chmod 0600 "$journal" ;;
    oversized) truncate -s 1048577 "$journal"; chmod 0600 "$journal" ;;
    symlink) mv "$journal" "$journal.saved"; ln -s "$journal.saved" "$journal" ;;
    hardlink) ln "$journal" "$journal.link" ;;
  esac
  before=$(find "$STATE_ROOT" -printf '%p|%y|%m|%s|%i|%Y\n' | sort)
  set +e
  output=$(status_operation "$operation" 2>"$TEST_ROOT/invalid-$suffix.err")
  code=$?
  set -e
  [[ $code == 4 ]]
  jq -e '.status == "manual-attention" and .reason == "invalid-state"' <<<"$output" >/dev/null
  after=$(find "$STATE_ROOT" -printf '%p|%y|%m|%s|%i|%Y\n' | sort)
  [[ $before == "$after" ]]
}

invalid_case 1 corrupt
invalid_case 2 noncanonical
invalid_case 3 contradictory
invalid_case 4 oversized
invalid_case 5 symlink
invalid_case 6 hardlink
printf 'ok - corrupt, noncanonical, contradictory, oversized, symlinked and hard-linked status fails without mutation\n'

abort_plugin=acme.o7-abort
active="$DISCOVERY/$abort_plugin"
candidate="$TEST_ROOT/abort-candidate"
make_interface_plugin "$ROOT" "$active" "$abort_plugin"
make_interface_plugin "$ROOT" "$candidate" "$abort_plugin"
printf 'candidate-v2\n' >>"$candidate/Service.qml"
active_identity=$("$NATIVE" identity "$active")
candidate_identity=$("$NATIVE" identity "$candidate")
abort_operation_id=83200000-0000-4000-8000-000000000001
stage_direct "$abort_operation_id" "$abort_plugin" "$candidate" update present \
  "$active_identity" referenced preserve-observed \
  sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
abort_journal="$STATE_ROOT/journals/$abort_operation_id.journal"
candidate_path="$STORE/$abort_operation_id/candidate"
candidate_before=$("$NATIVE" identity "$candidate_path")
candidate_inode=$(stat -c '%d:%i' "$candidate_path")
active_before=$("$NATIVE" identity "$active")
config_before=$(sha256sum "$HOME_DIR/.config/omarchy/shell.json")
gate_entries_before=$(find "$STATE_ROOT/gates" -mindepth 1 -printf '%P\n' | sort)
abort_output=$(abort_operation "$abort_operation_id" 2>"$TEST_ROOT/abort.err")
jq -e '.action == "abort" and .state == "ABORTED" and .status == "aborted"
  and .reason == "owner-aborted"' <<<"$abort_output" >/dev/null
jq -e '.state == "ABORTED" and .reason == "owner-aborted"
  and .publication.state == "completed-durable" and .gate == "not-established"
  and .registry == "not-requested" and .rollback == "not-applicable"
  and .retainedPrior == {state:"not-captured",identity:null}
  and .candidate.observed == .candidate.expected' "$abort_journal" >/dev/null
[[ $("$NATIVE" identity "$candidate_path") == "$candidate_before" &&
    $(stat -c '%d:%i' "$candidate_path") == "$candidate_inode" &&
    $("$NATIVE" identity "$active") == "$active_before" &&
    $(sha256sum "$HOME_DIR/.config/omarchy/shell.json") == "$config_before" &&
    $(find "$STATE_ROOT/gates" -mindepth 1 -printf '%P\n' | sort) == "$gate_entries_before" ]]
printf 'ok - exact STAGED abort durably records ABORTED and retains inert candidate and live state\n'

aborted_sha=$(sha256sum "$abort_journal")
aborted_inode=$(stat -c '%d:%i' "$abort_journal")
abort_retry=$(abort_operation "$abort_operation_id" 2>"$TEST_ROOT/abort-retry.err")
[[ $abort_retry == "$abort_output" && $(sha256sum "$abort_journal") == "$aborted_sha"
    && $(stat -c '%d:%i' "$abort_journal") == "$aborted_inode" ]]
printf 'ok - exact abort retry is idempotent without journal replacement\n'

aborted_stage_request=$(public_stage_request "$abort_journal")
find "$candidate" -depth -delete
aborted_stage_output=$(printf '%s' "$aborted_stage_request" | invoke 2>"$TEST_ROOT/aborted-stage.err")
jq -e '.action == "stage" and .state == "ABORTED" and .reason == "owner-aborted"' \
  <<<"$aborted_stage_output" >/dev/null
[[ $(sha256sum "$abort_journal") == "$aborted_sha" &&
    $(stat -c '%d:%i' "$candidate_path") == "$candidate_inode" ]]
printf 'ok - stage replay after ABORTED cannot recreate or republish the candidate\n'

wrong_plugin=acme.o7-wrong-token
wrong_operation=83200000-0000-4000-8000-000000000002
wrong_source=$(source_for "$wrong_operation" "$wrong_plugin")
stage_direct "$wrong_operation" "$wrong_plugin" "$wrong_source"
wrong_journal="$STATE_ROOT/journals/$wrong_operation.journal"
wrong_before=$(sha256sum "$wrong_journal")
set +e
wrong_output=$(abort_operation "$wrong_operation" "$WRONG_TOKEN" 2>"$TEST_ROOT/abort-wrong.err")
wrong_code=$?
set -e
[[ $wrong_code == 3 ]]
jq -e '.reason == "invalid-operation-token"' <<<"$wrong_output" >/dev/null
[[ $(sha256sum "$wrong_journal") == "$wrong_before" ]]
! grep -aF "$WRONG_TOKEN" "$TEST_ROOT/abort-wrong.err" >/dev/null
printf 'ok - wrong abort token changes and reveals nothing\n'

for durable_state in REQUEST_BOUND PUBLICATION_INTENT RECOVERY_REQUIRED MANUAL_ATTENTION; do
  operation=${state_operations[$durable_state]}
  journal="$STATE_ROOT/journals/$operation.journal"
  before=$(sha256sum "$journal")
  set +e
  output=$(abort_operation "$operation" 2>"$TEST_ROOT/refuse-$durable_state.err")
  code=$?
  set -e
  case $durable_state in
    REQUEST_BOUND|PUBLICATION_INTENT)
      [[ $code == 0 ]]; jq -e '.reason == "operation-in-progress"' <<<"$output" >/dev/null ;;
    RECOVERY_REQUIRED)
      [[ $code == 5 ]]; jq -e '.reason == "recovery-required"' <<<"$output" >/dev/null ;;
    MANUAL_ATTENTION)
      [[ $code == 4 ]]; jq -e '.reason == "manual-attention"' <<<"$output" >/dev/null ;;
  esac
  [[ $(sha256sum "$journal") == "$before" ]]
done
printf 'ok - abort refuses all non-STAGED non-ABORTED durable states without mutation\n'

for durable_state in REQUEST_BOUND PUBLICATION_INTENT RECOVERY_REQUIRED MANUAL_ATTENTION; do
  operation=${state_operations[$durable_state]}
  journal="$STATE_ROOT/journals/$operation.journal"
  before=$(sha256sum "$journal")
  set +e
  output=$(printf '%s' "$(public_stage_request "$journal")" | invoke \
    2>"$TEST_ROOT/stage-refuse-$durable_state.err")
  code=$?
  set -e
  case $durable_state in
    REQUEST_BOUND|PUBLICATION_INTENT)
      [[ $code == 0 ]]; jq -e '.state == "STAGED" and .status == "ok"' <<<"$output" >/dev/null ;;
    RECOVERY_REQUIRED)
      [[ $code == 5 ]]; jq -e '.reason == "recovery-required"' <<<"$output" >/dev/null ;;
    MANUAL_ATTENTION)
      [[ $code == 4 ]]; jq -e '.reason == "manual-attention"' <<<"$output" >/dev/null ;;
  esac
  if [[ $durable_state == REQUEST_BOUND || $durable_state == PUBLICATION_INTENT ]]; then
    [[ $(jq -r .state "$journal") == STAGED ]]
  else
    [[ $(sha256sum "$journal") == "$before" ]]
  fi
done
printf 'ok - exact stage replay resumes recoverable nonterminal journals and refuses recovery states\n'

waiting_operation=83100000-0000-4000-8000-000000000099
waiting_plugin=acme.o7-stage-wait
waiting_source=$(source_for "$waiting_operation" "$waiting_plugin")
stage_direct "$waiting_operation" "$waiting_plugin" "$waiting_source"
waiting_journal="$STATE_ROOT/journals/$waiting_operation.journal"
jq -cS '.state="REQUEST_BOUND" | .candidate.observed=null | .publication.state="not-started" | .reason=null' \
  "$waiting_journal" >"$waiting_journal.next"
chmod 0600 "$waiting_journal.next"
mv "$waiting_journal.next" "$waiting_journal"
find "$STORE/$waiting_operation" -depth -delete
waiting_lock="$STATE_ROOT/locks/operations/$waiting_operation.lock"
waiting_before=$(sha256sum "$waiting_journal")
helper_dir=$(dirname -- "$NATIVE")
printf '%s\n' "$waiting_operation" >"$helper_dir/stage-wait-operation"
mkfifo "$helper_dir/stage-wait-ready"
exec {waiting_owner_fd}>"$waiting_lock"
flock "$waiting_owner_fd"
printf '%s' "$(public_stage_request "$waiting_journal")" | invoke \
  >"$TEST_ROOT/stage-wait.out" 2>"$TEST_ROOT/stage-wait.err" &
waiting_stage_pid=$!
[[ $(timeout 5 cat "$helper_dir/stage-wait-ready") == stage-waiting ]]
kill -0 "$waiting_stage_pid"
[[ ! -s $TEST_ROOT/stage-wait.out ]]
flock -u "$waiting_owner_fd"
exec {waiting_owner_fd}>&-
wait "$waiting_stage_pid"
jq -e '.state == "STAGED" and .status == "ok"' \
  "$TEST_ROOT/stage-wait.out" >/dev/null
[[ $(jq -r .state "$waiting_journal") == STAGED ]]
[[ $(sha256sum "$waiting_journal") != "$waiting_before" ]]
rm "$helper_dir/stage-wait-operation" "$helper_dir/stage-wait-ready"
printf 'ok - exact stage retry resumes an owner-abandoned REQUEST_BOUND journal\n'

gate_plugin=acme.o7-gated-abort
gate_operation=83200000-0000-4000-8000-000000000003
gate_source=$(source_for "$gate_operation" "$gate_plugin")
stage_direct "$gate_operation" "$gate_plugin" "$gate_source"
printf 'evidence\n' >"$STATE_ROOT/gates/$gate_plugin.gate"
chmod 0600 "$STATE_ROOT/gates/$gate_plugin.gate"
gate_before=$(sha256sum "$STATE_ROOT/journals/$gate_operation.journal" "$STATE_ROOT/gates/$gate_plugin.gate")
gate_output=$(abort_operation "$gate_operation" 2>"$TEST_ROOT/gate-abort.err")
jq -e '.reason == "operation-in-progress"' <<<"$gate_output" >/dev/null
[[ $(sha256sum "$STATE_ROOT/journals/$gate_operation.journal" "$STATE_ROOT/gates/$gate_plugin.gate") == "$gate_before" ]]
printf 'ok - any durable plugin gate prevents inert abort\n'

lock_plugin=acme.o7-lock-held
lock_operation=83200000-0000-4000-8000-000000000004
lock_source=$(source_for "$lock_operation" "$lock_plugin")
stage_direct "$lock_operation" "$lock_plugin" "$lock_source"
coproc HELD_PLUGIN { "$NATIVE.real" plugin-lock "$STATE_ROOT" "$lock_plugin"; }
held_pid=$HELD_PLUGIN_PID
IFS= read -r held_ready <&"${HELD_PLUGIN[0]}"
[[ $held_ready == locked ]]
lock_before=$(sha256sum "$STATE_ROOT/journals/$lock_operation.journal")
lock_output=$(abort_operation "$lock_operation" 2>"$TEST_ROOT/held-plugin.err")
jq -e '.reason == "operation-in-progress"' <<<"$lock_output" >/dev/null
[[ $(sha256sum "$STATE_ROOT/journals/$lock_operation.journal") == "$lock_before" ]]

other_plugin=acme.o7-unrelated-lock
other_operation=83200000-0000-4000-8000-000000000005
other_source=$(source_for "$other_operation" "$other_plugin")
stage_direct "$other_operation" "$other_plugin" "$other_source"
other_output=$(abort_operation "$other_operation" 2>"$TEST_ROOT/unrelated-lock.err")
jq -e '.state == "ABORTED"' <<<"$other_output" >/dev/null
held_input_fd=${HELD_PLUGIN[1]}
exec {held_input_fd}>&-
wait "$held_pid"
printf 'ok - plugin lock blocks same-plugin abort while unrelated plugin abort progresses\n'

negative_lock_plugin=acme.o7-negative-lock
negative_lock_operation=83200000-0000-4000-8000-000000000008
negative_lock_source=$(source_for "$negative_lock_operation" "$negative_lock_plugin")
stage_direct "$negative_lock_operation" "$negative_lock_plugin" "$negative_lock_source"
coproc NEGATIVE_HELD_PLUGIN { "$NATIVE.real" plugin-lock "$STATE_ROOT" "$negative_lock_plugin"; }
negative_held_pid=$NEGATIVE_HELD_PLUGIN_PID
IFS= read -r negative_held_ready <&"${NEGATIVE_HELD_PLUGIN[0]}"
[[ $negative_held_ready == locked ]]
: >"$(dirname -- "$NATIVE")/omit-plugin-lock-negative"
negative_lock_output=$(abort_operation "$negative_lock_operation" 2>"$TEST_ROOT/negative-lock.err")
rm "$(dirname -- "$NATIVE")/omit-plugin-lock-negative"
negative_held_input_fd=${NEGATIVE_HELD_PLUGIN[1]}
exec {negative_held_input_fd}>&-
wait "$negative_held_pid"
if jq -e '.reason == "operation-in-progress"' <<<"$negative_lock_output" >/dev/null; then
  printf 'not ok - omitted-plugin-lock negative control remained blocked\n' >&2
  exit 1
fi
jq -e '.state == "ABORTED"' <<<"$negative_lock_output" >/dev/null
printf 'ok - omitted-plugin-lock negative control demonstrates the blocking assertion\n'

ordered_plugin=acme.o7-ordered-abort
ordered_operation=83200000-0000-4000-8000-000000000006
ordered_source=$(source_for "$ordered_operation" "$ordered_plugin")
stage_direct "$ordered_operation" "$ordered_plugin" "$ordered_source"
mkfifo "$helper_dir/operation-ready" "$helper_dir/operation-resume" \
  "$helper_dir/both-ready" "$helper_dir/both-resume"
: >"$helper_dir/hold-after-operation"
printf '%s\n' "$ordered_operation" >"$helper_dir/hold-candidate-operation"
abort_operation "$ordered_operation" >"$TEST_ROOT/ordered.out" 2>"$TEST_ROOT/ordered.err" &
ordered_pid=$!
[[ $(timeout 5 cat "$helper_dir/operation-ready") == after-ordered-operation-lock ]]
if flock -n "$STATE_ROOT/locks/operations/$ordered_operation.lock" true; then
  printf 'not ok - abort did not acquire the operation lock first\n' >&2
  exit 1
fi
"$NATIVE.real" plugin-lock "$STATE_ROOT" "$ordered_plugin" </dev/null >/dev/null
printf 'resume\n' >"$helper_dir/operation-resume"
[[ $(timeout 5 cat "$helper_dir/both-ready") == locks-held ]]
if flock -n "$STATE_ROOT/locks/operations/$ordered_operation.lock" true; then
  printf 'not ok - abort released its operation lock early\n' >&2
  exit 1
fi
if "$NATIVE.real" plugin-lock "$STATE_ROOT" "$ordered_plugin" </dev/null >/dev/null 2>&1; then
  printf 'not ok - abort did not acquire the plugin lock second\n' >&2
  exit 1
fi
printf 'resume\n' >"$helper_dir/both-resume"
wait "$ordered_pid"
jq -e '.state == "ABORTED"' "$TEST_ROOT/ordered.out" >/dev/null
rm "$helper_dir/hold-after-operation" "$helper_dir/hold-candidate-operation"
printf 'ok - deterministic barriers prove operation-lock then plugin-lock ordering\n'

live_sentinel="$DISCOVERY/acme.o7-live-sentinel"
mkdir "$live_sentinel"
printf 'live\n' >"$live_sentinel/value"
live_before=$(sha256sum "$live_sentinel/value")
config_before=$(sha256sum "$HOME_DIR/.config/omarchy/shell.json")
fault_index=1
for fault in before-write after-write file-fsync after-file-fsync rename after-rename parent-fsync; do
  printf -v operation '83300000-0000-4000-8000-%012d' "$fault_index"
  plugin=acme.o7-abort-fault-$fault_index
  source=$(source_for "$operation" "$plugin")
  stage_direct "$operation" "$plugin" "$source"
  journal="$STATE_ROOT/journals/$operation.journal"
  candidate_path="$STORE/$operation/candidate"
  candidate_before=$("$NATIVE" identity "$candidate_path")
  printf '%s\n' "$fault" >"$helper_dir/abort-fault"
  set +e
  output=$(abort_operation "$operation" 2>"$TEST_ROOT/fault-$fault.err")
  code=$?
  set -e
  rm "$helper_dir/abort-fault"
  [[ $code == 5 ]]
  jq -e '.status == "indeterminate" and .reason == "abort-indeterminate"' <<<"$output" >/dev/null
  if [[ $fault == after-rename || $fault == parent-fsync ]]; then
    expected_state=ABORTED
  else
    expected_state=STAGED
  fi
  [[ $(jq -r .state "$journal") == "$expected_state" ]]
  fresh=$(status_operation "$operation" 2>"$TEST_ROOT/fresh-$fault.err")
  jq -e --arg state "$expected_state" '.state == $state' <<<"$fresh" >/dev/null
  [[ $("$NATIVE" identity "$candidate_path") == "$candidate_before" &&
      $(sha256sum "$live_sentinel/value") == "$live_before" &&
      $(sha256sum "$HOME_DIR/.config/omarchy/shell.json") == "$config_before" &&
      ! -e $DISCOVERY/$plugin ]]
  retry=$(abort_operation "$operation" 2>"$TEST_ROOT/fault-retry-$fault.err")
  jq -e '.state == "ABORTED" and .reason == "owner-aborted"' <<<"$retry" >/dev/null
  [[ $("$NATIVE" identity "$candidate_path") == "$candidate_before" ]]
  ((fault_index++))
done
printf 'ok - every abort write/file-fsync/rename/parent-fsync fault reconciles as exact old or new state\n'
printf 'ok - all abort faults retain candidates and leave live tree and configuration untouched\n'

authority_operation=83300000-0000-4000-8000-000000000099
authority_plugin=acme.o7-journal-authority
authority_source=$(source_for "$authority_operation" "$authority_plugin")
stage_direct "$authority_operation" "$authority_plugin" "$authority_source"
printf 'parent-fsync\n' >"$helper_dir/abort-fault"
set +e
authority_first=$(abort_operation "$authority_operation" 2>"$TEST_ROOT/authority-first.err")
authority_first_code=$?
set -e
rm "$helper_dir/abort-fault"
[[ $authority_first_code == 5 ]]
: >"$helper_dir/journal-authority-fault"
set +e
authority_status=$(status_operation "$authority_operation" 2>"$TEST_ROOT/authority-status.err")
authority_status_code=$?
authority_retry=$(abort_operation "$authority_operation" 2>"$TEST_ROOT/authority-retry.err")
authority_retry_code=$?
set -e
[[ $authority_status_code == 5 && $authority_retry_code == 5 ]]
jq -e '.status == "indeterminate" and .reason == "journal-authority-indeterminate"' \
  <<<"$authority_status" >/dev/null
jq -e '.status == "indeterminate" and .reason == "journal-authority-indeterminate"' \
  <<<"$authority_retry" >/dev/null
rm "$helper_dir/journal-authority-fault"
authority_reconciled=$(status_operation "$authority_operation")
jq -e '.state == "ABORTED" and .status == "aborted"' <<<"$authority_reconciled" >/dev/null
authority_idempotent=$(abort_operation "$authority_operation")
jq -e '.state == "ABORTED" and .status == "aborted"' <<<"$authority_idempotent" >/dev/null
printf 'ok - parent-fsync ambiguity stays indeterminate until status/abort reconciliation sync succeeds\n'

[[ ! -e $HOME_DIR/.o7-shell-calls ]]
printf 'ok - status and abort never contact the running shell or add candidate collection\n'
