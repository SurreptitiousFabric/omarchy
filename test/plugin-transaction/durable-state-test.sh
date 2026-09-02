#!/bin/bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'find "$TEST_ROOT" -mindepth 1 -delete; rmdir "$TEST_ROOT"' EXIT
HELPER="$TEST_ROOT/plugin-tree"
STAGE="$ROOT/native/plugin-transaction/stage-candidate"
STORE="$TEST_ROOT/state/plugin-candidates-v1"
STATE="$TEST_ROOT/state/plugin-transactions-v1"
HOME_DIR="$TEST_ROOT/home"
PLUGIN_DIR="$HOME_DIR/.config/omarchy/plugins"
TOKEN_A=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
TOKEN_B=QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI
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
  local destination=$1 plugin=${2:-acme.state-test}
  mkdir -p "$destination"
  cp "$ROOT/test/shell.d/fixtures/plugin-load-race/Service.qml" "$destination/Service.qml"
  jq --arg id "$plugin" '.id=$id' "$ROOT/test/shell.d/fixtures/plugin-load-race/manifest.json" >"$destination/manifest.json"
}

stage() {
  local operation=$1 plugin=$2 source=$3 token=${4:-$TOKEN_A} caller_identity
  if [[ -n ${TEST_CALLER_IDENTITY:-} ]]; then
    caller_identity=$TEST_CALLER_IDENTITY
  else
    caller_identity=$(env -u OMARCHY_PLUGIN_TREE_TEST_HOOK -u OMARCHY_PLUGIN_TREE_TEST_READY_FIFO \
      -u OMARCHY_PLUGIN_TREE_TEST_RESUME_FIFO -u OMARCHY_PLUGIN_TREE_TEST_CRASH_POINT \
      "$HELPER" identity "$source")
  fi
  HOME="$HOME_DIR" OMARCHY_PATH="$ROOT" OMARCHY_PLUGIN_TREE_HELPER="$HELPER" \
    OMARCHY_PLUGIN_VALIDATOR="${TEST_VALIDATOR:-$ROOT/bin/omarchy-plugin-validate}" \
    OMARCHY_PLUGIN_CANDIDATE_STORE="$STORE" OMARCHY_PLUGIN_TRANSACTION_STATE="$STATE" \
    OMARCHY_PLUGIN_OPERATION_KIND="${TEST_OPERATION_KIND:-install}" \
    OMARCHY_PLUGIN_SOURCE_KIND="${TEST_SOURCE_KIND:-directory}" \
    OMARCHY_PLUGIN_CALLER_CANDIDATE_IDENTITY="$caller_identity" \
    OMARCHY_PLUGIN_EXPECTED_ACTIVE_STATE="${TEST_ACTIVE_STATE:-absent}" \
    OMARCHY_PLUGIN_EXPECTED_ACTIVE_IDENTITY="${TEST_ACTIVE_IDENTITY:-}" \
    OMARCHY_PLUGIN_EXPECTED_CONFIG_SOURCE_KIND="${TEST_CONFIG_KIND:-user}" \
    OMARCHY_PLUGIN_EXPECTED_CONFIG_SOURCE_IDENTITY="${TEST_CONFIG_IDENTITY:-test-user-config-v1}" \
    OMARCHY_PLUGIN_EXPECTED_REFERENCE_PROJECTION="${TEST_PROJECTION:-sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" \
    OMARCHY_PLUGIN_EXPECTED_REFERENCE_STATE="${TEST_REFERENCE_STATE:-unreferenced}" \
    OMARCHY_PLUGIN_REFERENCE_POLICY="${TEST_POLICY:-require-unreferenced}" \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_SOURCE="${TEST_OBSERVATION_SOURCE:-test-injected-o5}" \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_RAW_SHA256="${TEST_RAW:-sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}" \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_REFERENCE_PROJECTION="${TEST_OBS_PROJECTION:-sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_REFERENCE_STATE="${TEST_OBS_STATE:-unreferenced}" \
    OMARCHY_PLUGIN_DESTINATION="${TEST_DESTINATION:-$PLUGIN_DIR/$plugin}" \
    "$STAGE" "$operation" "$plugin" "$source" <<<"$token"
}

expect_failure() {
  local code=$1; shift
  local output
  if output=$("$@" 2>&1); then printf 'not ok - expected %s\n' "$code" >&2; exit 1; fi
  grep -qF "omarchy-plugin-candidate-stage: $code:" <<<"$output"
}

source="$TEST_ROOT/source"; make_plugin "$source"
operation=10000000-0000-4000-8000-000000000001
old_umask=$(umask); umask 000; first=$(stage "$operation" acme.state-test "$source"); umask "$old_umask"
journal="$STATE/journals/$operation.journal"
[[ $(stat -c %a "$STATE") == 700 && $(stat -c %a "$STATE/journals") == 700 && $(stat -c %a "$STATE/locks") == 700 ]]
[[ $(stat -c %a "$journal") == 600 && $(stat -c %h "$journal") == 1 ]]
jq -e '.schema=="omarchy-plugin-transaction-journal/v1" and .state=="STAGED" and .gate=="not-established" and .registry=="not-requested" and .rollback=="not-applicable" and .retainedPrior.state=="not-captured"' "$journal" >/dev/null
cmp -s "$journal" <(jq -cS . "$journal")
! grep -R -F "$TOKEN_A" "$TEST_ROOT" >/dev/null
printf 'ok - private canonical journal is durable authority and stores no raw capability\n'

candidate_inode=$(stat -c %d:%i "$STORE/$operation/candidate")
replay=$(stage "$operation" acme.state-test "$source")
[[ $replay == "$first" && $(stat -c %d:%i "$STORE/$operation/candidate") == "$candidate_inode" ]]
expect_failure invalid-operation-token stage "$operation" acme.state-test "$source" "$TOKEN_B"
[[ $(jq -r .state "$journal") == STAGED ]]
printf 'ok - exact replay is stable and wrong capability leaves operation unchanged\n'

baseline_journal_sha=$(sha256sum "$journal")
baseline_candidate_identity=$("$HELPER" identity "$STORE/$operation/candidate")
for field in operation plugin source_kind source_path caller_candidate active config_kind config_identity projection reference_state policy observation_source observation_raw observation_projection observation_state destination; do
  case $field in
    operation) TEST_OPERATION_KIND=update TEST_ACTIVE_STATE=present TEST_ACTIVE_IDENTITY=omarchy-runtime-tree-sha256-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa TEST_POLICY=preserve-observed expect_failure operation-conflict stage "$operation" acme.state-test "$source" ;;
    plugin) make_plugin "$TEST_ROOT/other-plugin" other.state; expect_failure operation-conflict stage "$operation" other.state "$TEST_ROOT/other-plugin" ;;
    source_kind) TEST_SOURCE_KIND=archive expect_failure operation-conflict stage "$operation" acme.state-test "$source" ;;
    source_path) cp -a "$source" "$TEST_ROOT/other-source"; expect_failure operation-conflict stage "$operation" acme.state-test "$TEST_ROOT/other-source" ;;
    caller_candidate) TEST_CALLER_IDENTITY=omarchy-runtime-tree-sha256-v1:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc expect_failure operation-conflict stage "$operation" acme.state-test "$source" ;;
    active) TEST_OPERATION_KIND=update TEST_ACTIVE_STATE=present TEST_ACTIVE_IDENTITY=omarchy-runtime-tree-sha256-v1:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd TEST_POLICY=preserve-observed expect_failure operation-conflict stage "$operation" acme.state-test "$source" ;;
    config_kind) TEST_CONFIG_KIND=default expect_failure operation-conflict stage "$operation" acme.state-test "$source" ;;
    config_identity) TEST_CONFIG_IDENTITY=other-config expect_failure operation-conflict stage "$operation" acme.state-test "$source" ;;
    projection) TEST_PROJECTION=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc expect_failure operation-conflict stage "$operation" acme.state-test "$source" ;;
    reference_state) TEST_REFERENCE_STATE=referenced expect_failure operation-conflict stage "$operation" acme.state-test "$source" ;;
    policy) TEST_POLICY=preserve-observed expect_failure operation-conflict stage "$operation" acme.state-test "$source" ;;
    observation_source) TEST_OBSERVATION_SOURCE=internal-unestablished expect_failure operation-conflict stage "$operation" acme.state-test "$source" ;;
    observation_raw) TEST_RAW=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc expect_failure operation-conflict stage "$operation" acme.state-test "$source" ;;
    observation_projection) TEST_OBS_PROJECTION=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc expect_failure operation-conflict stage "$operation" acme.state-test "$source" ;;
    observation_state) TEST_OBS_STATE=referenced expect_failure operation-conflict stage "$operation" acme.state-test "$source" ;;
    destination) TEST_DESTINATION="$PLUGIN_DIR/other" expect_failure operation-conflict stage "$operation" acme.state-test "$source" ;;
  esac
  [[ $(sha256sum "$journal") == "$baseline_journal_sha" ]]
  [[ $("$HELPER" identity "$STORE/$operation/candidate") == "$baseline_candidate_identity" ]]
  [[ $(stat -c %d:%i "$STORE/$operation/candidate") == "$candidate_inode" ]]
done
printf 'ok - every immutable request class conflicts without changing durable operation bytes\n'

deleted_operation=18000000-0000-4000-8000-000000000001
deleted_source="$TEST_ROOT/deleted-source"
make_plugin "$deleted_source"
deleted_identity=$("$HELPER" identity "$deleted_source")
deleted_result=$(stage "$deleted_operation" acme.state-test "$deleted_source")
find "$deleted_source" -depth -delete
replayed_without_source=$(TEST_CALLER_IDENTITY="$deleted_identity" stage "$deleted_operation" acme.state-test "$deleted_source")
[[ $replayed_without_source == "$deleted_result" ]]
TEST_CALLER_IDENTITY="$deleted_identity" expect_failure invalid-operation-token stage "$deleted_operation" acme.state-test "$deleted_source" "$TOKEN_B"
TEST_CALLER_IDENTITY="$deleted_identity" expect_failure operation-conflict stage "$deleted_operation" acme.state-test "$TEST_ROOT/another-missing-source"
[[ $("$HELPER" identity "$STORE/$deleted_operation/candidate") == "$deleted_identity" ]]
printf 'ok - durable replay uses owned candidate after the external source disappears\n'

cat >"$TEST_ROOT/crash-after-validation" <<'SH'
#!/bin/bash
"$REAL_VALIDATOR" "$@" || exit
exit 86
SH
chmod 0755 "$TEST_ROOT/crash-after-validation"
import_crash_index=1
for point in before-import-directory-create after-import-directory-create before-file-restat after-import-copy after-identity 'before-journal-write:request-bound-to-publication-intent'; do
  import_operation=$(printf '19000000-0000-4000-8000-%012d' "$import_crash_index")
  import_source="$TEST_ROOT/import-crash-$import_crash_index"
  make_plugin "$import_source"
  import_identity=$("$HELPER" identity "$import_source")
  if OMARCHY_PLUGIN_TREE_TEST_CRASH_POINT="$point" stage "$import_operation" acme.state-test "$import_source" >/dev/null 2>&1; then
    printf 'not ok - import crash point %s returned success\n' "$point" >&2
    exit 1
  fi
  [[ $(jq -r .state "$STATE/journals/$import_operation.journal") == REQUEST_BOUND ]]
  stage "$import_operation" acme.state-test "$import_source" >/dev/null
  [[ $(jq -r .state "$STATE/journals/$import_operation.journal") == STAGED ]]
  [[ -d $STORE/$import_operation/candidate ]]
  [[ ! -e $STORE/.import.$import_operation ]]
  (( import_crash_index++ ))
done
validation_operation=19000000-0000-4000-8000-000000000099
validation_source="$TEST_ROOT/import-crash-validation"
make_plugin "$validation_source"
if REAL_VALIDATOR="$ROOT/bin/omarchy-plugin-validate" TEST_VALIDATOR="$TEST_ROOT/crash-after-validation" \
    stage "$validation_operation" acme.state-test "$validation_source" >/dev/null 2>&1; then
  printf 'not ok - post-validation crash returned success\n' >&2
  exit 1
fi
[[ $(jq -r .state "$STATE/journals/$validation_operation.journal") == REQUEST_BOUND ]]
stage "$validation_operation" acme.state-test "$validation_source" >/dev/null
[[ $(jq -r .state "$STATE/journals/$validation_operation.journal") == STAGED ]]
[[ ! -e $STORE/.import.$validation_operation ]]
printf 'ok - every incomplete import crash is owned and exactly recreated from REQUEST_BOUND\n'

crash_index=10
for boundary in before-journal-write after-journal-write after-journal-file-sync after-journal-rename; do
  point=$boundary:request-bound
  crash_operation=$(printf '20000000-0000-4000-8000-%012d' "$crash_index")
  crash_source="$TEST_ROOT/crash-$crash_index"; make_plugin "$crash_source"
  if OMARCHY_PLUGIN_TREE_TEST_CRASH_POINT="$point" stage "$crash_operation" acme.state-test "$crash_source" >"$TEST_ROOT/crash.out" 2>"$TEST_ROOT/crash.err"; then
    printf 'not ok - crash point %s returned success\n' "$point" >&2; exit 1
  fi
  stage "$crash_operation" acme.state-test "$crash_source" >/dev/null
  [[ $(jq -r .state "$STATE/journals/$crash_operation.journal") == STAGED ]]
  (( crash_index++ ))
done
printf 'ok - fresh processes reconcile every journal replacement interruption\n'

journal_parent_case() {
  local suffix=$1 transition=$2 operation source
  operation=$(printf '21000000-0000-4000-8000-%012d' "$suffix")
  source="$TEST_ROOT/journal-parent-$suffix"; make_plugin "$source"
  if OMARCHY_PLUGIN_TREE_TEST_FAIL_FSYNC="journal-parent:$transition" \
      stage "$operation" acme.state-test "$source" >/dev/null 2>&1; then
    printf 'not ok - journal parent failure for %s returned success\n' "$transition" >&2; exit 1
  fi
  # A new process must positively synchronize and revalidate the visible record.
  stage "$operation" acme.state-test "$source" >/dev/null
  [[ $(jq -r .state "$STATE/journals/$operation.journal") == STAGED ]]
}
journal_parent_case 1 request-bound
journal_parent_case 2 request-bound-to-publication-intent
journal_parent_case 3 publication-intent-to-staged
printf 'ok - REQUEST_BOUND, PUBLICATION_INTENT and STAGED parent-fsync ambiguity is actively reconciled\n'

# Exercise the native durability boundary for every journal transition label.
# Each interrupted helper is followed by a fresh helper process that syncs and
# validates the one authoritative record; temporary journal files are ignored.
transition_matrix_index=1
for transition_spec in \
  'request-bound|REQUEST_BOUND|not-started|' \
  'request-bound-to-publication-intent|PUBLICATION_INTENT|intended|' \
  'publication-intent-to-staged|STAGED|completed-durable|' \
  'publication-intent-to-recovery|RECOVERY_REQUIRED|indeterminate|publication-indeterminate' \
  'recovery-to-staged|STAGED|completed-durable|' \
  'publication-to-manual|MANUAL_ATTENTION|contradictory|missing-candidate' \
  'corruption-manual-attention|MANUAL_ATTENTION|corrupt-unavailable|corrupt-journal'; do
  IFS='|' read -r transition target_state publication reason <<<"$transition_spec"
  for boundary in before-journal-write after-journal-write after-journal-file-sync after-journal-rename; do
    matrix_operation=$(printf '23000000-0000-4000-8000-%012d' "$transition_matrix_index")
    matrix_source="$TEST_ROOT/transition-$transition_matrix_index"; make_plugin "$matrix_source"
    stage "$matrix_operation" acme.state-test "$matrix_source" >/dev/null
    matrix_journal="$STATE/journals/$matrix_operation.journal"
    matrix_input="$TEST_ROOT/transition-$transition_matrix_index.json"
    if [[ $transition == corruption-manual-attention ]]; then
      jq -cnS --arg operationId "$matrix_operation" \
        '{schema:"omarchy-plugin-transaction-journal/v1",operationId:$operationId,pluginId:null,normalizedRequest:null,capabilityHash:null,
          candidate:{expected:null,observed:null,temporarySlot:null,completedSlot:null},publication:{state:"corrupt-unavailable"},
          gate:"not-established",registry:"not-requested",rollback:"not-applicable",retainedPrior:{state:"not-captured",identity:null},
          state:"MANUAL_ATTENTION",reason:"corrupt-journal",corruptEvidenceSha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' >"$matrix_input"
    else
      jq -cS --arg state "$target_state" --arg publication "$publication" --arg reason "$reason" \
        '.state=$state | .publication.state=$publication | .reason=(if $reason=="" then null else $reason end)
         | if $state=="REQUEST_BOUND" then .candidate.observed=null else . end' \
        "$matrix_journal" >"$matrix_input"
    fi
    [[ $(jq -er --arg operation_id "$matrix_operation" -f "$ROOT/native/plugin-transaction/validate-journal.jq" "$matrix_input") == true ]]
    if OMARCHY_PLUGIN_TREE_TEST_CRASH_POINT="$boundary:$transition" \
        "$HELPER" journal-replace "$STATE" "$matrix_operation" "$matrix_input" "$transition" >/dev/null 2>&1; then
      printf 'not ok - transition crash %s:%s returned success\n' "$boundary" "$transition" >&2; exit 1
    fi
    "$HELPER" journal-sync "$STATE" "$matrix_operation"
    [[ $(jq -er --arg operation_id "$matrix_operation" -f "$ROOT/native/plugin-transaction/validate-journal.jq" "$matrix_journal") == true ]]
    (( transition_matrix_index++ ))
  done
  matrix_operation=$(printf '23000000-0000-4000-8000-%012d' "$transition_matrix_index")
  matrix_source="$TEST_ROOT/transition-$transition_matrix_index"; make_plugin "$matrix_source"
  stage "$matrix_operation" acme.state-test "$matrix_source" >/dev/null
  matrix_journal="$STATE/journals/$matrix_operation.journal"
  matrix_input="$TEST_ROOT/transition-$transition_matrix_index.json"
  if [[ $transition == corruption-manual-attention ]]; then
    jq -cnS --arg operationId "$matrix_operation" \
      '{schema:"omarchy-plugin-transaction-journal/v1",operationId:$operationId,pluginId:null,normalizedRequest:null,capabilityHash:null,
        candidate:{expected:null,observed:null,temporarySlot:null,completedSlot:null},publication:{state:"corrupt-unavailable"},
        gate:"not-established",registry:"not-requested",rollback:"not-applicable",retainedPrior:{state:"not-captured",identity:null},
        state:"MANUAL_ATTENTION",reason:"corrupt-journal",corruptEvidenceSha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' >"$matrix_input"
  else
    jq -cS --arg state "$target_state" --arg publication "$publication" --arg reason "$reason" \
      '.state=$state | .publication.state=$publication | .reason=(if $reason=="" then null else $reason end)
       | if $state=="REQUEST_BOUND" then .candidate.observed=null else . end' \
      "$matrix_journal" >"$matrix_input"
  fi
  if OMARCHY_PLUGIN_TREE_TEST_FAIL_FSYNC="journal-parent:$transition" \
      "$HELPER" journal-replace "$STATE" "$matrix_operation" "$matrix_input" "$transition" >/dev/null 2>&1; then
    printf 'not ok - transition parent-fsync %s returned success\n' "$transition" >&2; exit 1
  fi
  "$HELPER" journal-sync "$STATE" "$matrix_operation"
  cmp -s "$matrix_journal" "$matrix_input"
  [[ $(jq -er --arg operation_id "$matrix_operation" -f "$ROOT/native/plugin-transaction/validate-journal.jq" "$matrix_journal") == true ]]
  (( transition_matrix_index++ ))
done
printf 'ok - every O-5 journal transition survives every write/fsync/rename interruption as one valid authority\n'


publish_operation=30000000-0000-4000-8000-000000000001
publish_source="$TEST_ROOT/publish-crash"; make_plugin "$publish_source"
if OMARCHY_PLUGIN_TREE_TEST_CRASH_POINT=after-publication-rename stage "$publish_operation" acme.state-test "$publish_source" >/dev/null 2>&1; then
  printf 'not ok - publication crash returned success\n' >&2; exit 1
fi
[[ $(jq -r .state "$STATE/journals/$publish_operation.journal") == PUBLICATION_INTENT ]]
stage "$publish_operation" acme.state-test "$publish_source" >/dev/null
[[ $(jq -r .state "$STATE/journals/$publish_operation.journal") == STAGED ]]
printf 'ok - exact completed candidate is actively synchronized and reconciled after restart\n'

combined_case() {
  local suffix=$1 fail_sync=$2 combined_operation combined_source stage_a
  combined_operation=$(printf '35000000-0000-4000-8000-%012d' "$suffix")
  combined_source="$TEST_ROOT/combined-$suffix"; make_plugin "$combined_source"
  mkfifo "$TEST_ROOT/combined-ready-$suffix" "$TEST_ROOT/combined-resume-$suffix"
  if $fail_sync; then
    OMARCHY_PLUGIN_TREE_TEST_FAIL_FSYNC=publication-parent \
    OMARCHY_PLUGIN_TREE_TEST_HOOK=after-publication-rename \
    OMARCHY_PLUGIN_TREE_TEST_READY_FIFO="$TEST_ROOT/combined-ready-$suffix" \
    OMARCHY_PLUGIN_TREE_TEST_RESUME_FIFO="$TEST_ROOT/combined-resume-$suffix" \
      stage "$combined_operation" acme.state-test "$combined_source" \
      >"$TEST_ROOT/combined-a-$suffix.out" 2>"$TEST_ROOT/combined-a-$suffix.err" &
  else
    OMARCHY_PLUGIN_TREE_TEST_HOOK=after-publication-rename \
    OMARCHY_PLUGIN_TREE_TEST_READY_FIFO="$TEST_ROOT/combined-ready-$suffix" \
    OMARCHY_PLUGIN_TREE_TEST_RESUME_FIFO="$TEST_ROOT/combined-resume-$suffix" \
      stage "$combined_operation" acme.state-test "$combined_source" \
      >"$TEST_ROOT/combined-a-$suffix.out" 2>"$TEST_ROOT/combined-a-$suffix.err" &
  fi
  stage_a=$!
  [[ $(cat "$TEST_ROOT/combined-ready-$suffix") == after-publication-rename ]]
  stage "$combined_operation" acme.state-test "$combined_source" \
    >"$TEST_ROOT/combined-b-$suffix.out" 2>"$TEST_ROOT/combined-b-$suffix.err" &
  stage_b=$!
  if flock -n "$STATE/locks/operations/$combined_operation.lock" true; then
    printf 'not ok - combined operation lock was not held\n' >&2; exit 1
  fi
  kill -0 "$stage_b"; [[ ! -s $TEST_ROOT/combined-b-$suffix.out ]]
  printf x >"$TEST_ROOT/combined-resume-$suffix"
  if $fail_sync; then
    if wait "$stage_a"; then printf 'not ok - injected candidate-parent fsync succeeded\n' >&2; exit 1; fi
  else
    wait "$stage_a"
  fi
  wait "$stage_b"
  [[ $(jq -r .state "$STATE/journals/$combined_operation.journal") == STAGED ]]
  [[ -d $STORE/$combined_operation/candidate ]]
}
combined_case 1 false
combined_case 2 true
printf 'ok - waiting retry cannot observe provisional publication across success or compensation\n'

indeterminate_operation=36000000-0000-4000-8000-000000000001
indeterminate_source="$TEST_ROOT/indeterminate"; make_plugin "$indeterminate_source"
mkfifo "$TEST_ROOT/indeterminate-ready" "$TEST_ROOT/indeterminate-resume"
OMARCHY_PLUGIN_TREE_TEST_FAIL_FSYNC=publication-parent \
OMARCHY_PLUGIN_TREE_TEST_HOOK=after-publication-rename \
OMARCHY_PLUGIN_TREE_TEST_READY_FIFO="$TEST_ROOT/indeterminate-ready" \
OMARCHY_PLUGIN_TREE_TEST_RESUME_FIFO="$TEST_ROOT/indeterminate-resume" \
  stage "$indeterminate_operation" acme.state-test "$indeterminate_source" \
  >"$TEST_ROOT/indeterminate.out" 2>"$TEST_ROOT/indeterminate.err" &
indeterminate_pid=$!
[[ $(cat "$TEST_ROOT/indeterminate-ready") == after-publication-rename ]]
indeterminate_temporary=$(jq -r .candidate.temporarySlot "$STATE/journals/$indeterminate_operation.journal")
mkdir "$STORE/$indeterminate_temporary"
printf x >"$TEST_ROOT/indeterminate-resume"
if wait "$indeterminate_pid"; then printf 'not ok - indeterminate publication returned success\n' >&2; exit 1; fi
[[ $(jq -r .state "$STATE/journals/$indeterminate_operation.journal") == RECOVERY_REQUIRED ]]
[[ $(jq -r .reason "$STATE/journals/$indeterminate_operation.journal") == publication-indeterminate ]]
expect_failure manual-attention stage "$indeterminate_operation" acme.state-test "$indeterminate_source"
[[ $(jq -r .state "$STATE/journals/$indeterminate_operation.journal") == MANUAL_ATTENTION ]]
[[ -d $STORE/$indeterminate_operation/candidate && -d $STORE/$indeterminate_temporary ]]
printf 'ok - unprovable publication compensation is durable and exact reconciliation retains evidence\n'

corrupt_operation=40000000-0000-4000-8000-000000000001
corrupt_source="$TEST_ROOT/corrupt"; make_plugin "$corrupt_source"; stage "$corrupt_operation" acme.state-test "$corrupt_source" >/dev/null
printf '{"state":"STAGED","state":"MANUAL_ATTENTION"}\n' >"$STATE/journals/$corrupt_operation.journal"
expect_failure manual-attention stage "$corrupt_operation" acme.state-test "$corrupt_source"
[[ $(jq -r .state "$STATE/journals/$corrupt_operation.journal") == MANUAL_ATTENTION ]]
compgen -G "$STATE/journals/$corrupt_operation.corrupt.*" >/dev/null
printf 'ok - malformed/noncanonical duplicate-key evidence is preserved before manual attention\n'

corrupt_discoverer_case() {
  local suffix=$1 discoverer=$2 operation source journal original_digest output
  operation=$(printf '40500000-0000-4000-8000-%012d' "$suffix")
  source="$TEST_ROOT/corrupt-discoverer-$suffix"; make_plugin "$source"
  stage "$operation" acme.state-test "$source" >/dev/null
  journal="$STATE/journals/$operation.journal"
  printf '{"broken":true}\n' >"$journal"; chmod 0600 "$journal"
  original_digest=$(sha256sum "$journal" | cut -d' ' -f1)
  case $discoverer in
    correct) expect_failure manual-attention stage "$operation" acme.state-test "$source" ;;
    wrong-token) expect_failure manual-attention stage "$operation" acme.state-test "$source" "$TOKEN_B" ;;
    conflict) make_plugin "$TEST_ROOT/corrupt-other-$suffix" other.state; expect_failure manual-attention stage "$operation" other.state "$TEST_ROOT/corrupt-other-$suffix" ;;
  esac
  jq -e --arg digest "$original_digest" \
    '.state=="MANUAL_ATTENTION" and .pluginId==null and .normalizedRequest==null and .capabilityHash==null and .corruptEvidenceSha256==$digest' "$journal" >/dev/null
  cmp -s "$STATE/journals/$operation.corrupt.$original_digest" <(printf '{"broken":true}\n')
  expect_failure manual-attention stage "$operation" acme.state-test "$source"
}
corrupt_discoverer_case 1 correct
corrupt_discoverer_case 2 wrong-token
corrupt_discoverer_case 3 conflict
printf 'ok - corruption tombstones never adopt the discovering caller identity or capability\n'

corrupt_preservation_crash_case() {
  local suffix=$1 point=$2 operation source journal
  operation=$(printf '40600000-0000-4000-8000-%012d' "$suffix")
  source="$TEST_ROOT/corrupt-preserve-$suffix"; make_plugin "$source"
  stage "$operation" acme.state-test "$source" >/dev/null
  journal="$STATE/journals/$operation.journal"
  printf '{"broken":%s}\n' "$suffix" >"$journal"; chmod 0600 "$journal"
  if OMARCHY_PLUGIN_TREE_TEST_CRASH_POINT="$point" stage "$operation" acme.state-test "$source" >/dev/null 2>&1; then
    printf 'not ok - corruption crash %s returned success\n' "$point" >&2; exit 1
  fi
  [[ -e $journal || -L $journal ]]
  expect_failure manual-attention stage "$operation" acme.state-test "$source"
  [[ $(jq -r .state "$journal") == MANUAL_ATTENTION ]]
}
corrupt_preservation_crash_case 1 'after-corrupt-evidence-create:corruption-manual-attention'
corrupt_preservation_crash_case 2 'after-corrupt-evidence-sync:corruption-manual-attention'
corrupt_preservation_crash_case 3 'after-journal-rename:corruption-manual-attention'
corrupt_preservation_crash_case 4 'before-journal-write:corruption-manual-attention'
printf 'ok - every corruption-preservation interruption retains an authoritative non-reusable operation\n'

corruption_case() {
  local suffix=$1 filter=$2 operation source journal temporary
  operation=$(printf '41000000-0000-4000-8000-%012d' "$suffix")
  source="$TEST_ROOT/corrupt-$suffix"; make_plugin "$source"; stage "$operation" acme.state-test "$source" >/dev/null
  journal="$STATE/journals/$operation.journal"; temporary="$journal.changed"
  jq -cS "$filter" "$journal" >"$temporary"; chmod 0600 "$temporary"; mv "$temporary" "$journal"
  expect_failure manual-attention stage "$operation" acme.state-test "$source"
  [[ $(jq -r .state "$journal") == MANUAL_ATTENTION ]]
  compgen -G "$STATE/journals/$operation.corrupt.*" >/dev/null
}
corruption_case 1 '.unexpected=true'
corruption_case 2 'del(.candidate)'
corruption_case 3 '.candidate.completedSlot=7'
corruption_case 4 '.state="COMMIT_PREPARED"'
corruption_case 5 '.normalizedRequest.digest="0000000000000000000000000000000000000000000000000000000000000000"'
corruption_case 6 '.operationId="ffffffff-ffff-4fff-8fff-ffffffffffff"'
corruption_case 7 '.pluginId="other.plugin"'
corruption_case 8 '.gate="established"'
corruption_case 9 '.registry="completed"'
corruption_case 10 '.rollback="completed"'
printf 'ok - unknown, missing, typed, transition, digest, identity and lifecycle contradictions fail closed\n'

# State-specific contradictions and primitive types must never be normalized
# into an apparently valid record.
corruption_case 11 '.publication.state="not-started"'
corruption_case 12 '.reason="unexpected"'
corruption_case 13 '.state="RECOVERY_REQUIRED" | .publication.state="completed-durable" | .reason="publication-indeterminate"'
corruption_case 14 '.reason=7'
corruption_case 15 '.candidate.observed="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
corruption_case 16 '.normalizedRequest.facts.expectedConfiguration.referenceProjection="invalid"'
corruption_case 17 '.candidate.temporarySlot="bad/path"'
corruption_case 18 '.candidate.completedSlot="ffffffff-ffff-4fff-8fff-ffffffffffff"'
corruption_case 19 '.schema=7'
corruption_case 20 '.normalizedRequest.facts.expectedConfiguration.source.kind=true'
corruption_case 21 '.candidate=[]'
corruption_case 22 '.retainedPrior.identity={}'
printf 'ok - state-specific contradictions and wrong primitive JSON types fail closed\n'

special_journal_case() {
  local suffix=$1 kind=$2 operation source journal saved
  operation=$(printf '42000000-0000-4000-8000-%012d' "$suffix")
  source="$TEST_ROOT/special-journal-$suffix"; make_plugin "$source"
  stage "$operation" acme.state-test "$source" >/dev/null
  journal="$STATE/journals/$operation.journal"; saved="$journal.saved"
  case $kind in
    oversized) dd if=/dev/zero of="$journal" bs=1048577 count=1 status=none; chmod 0600 "$journal" ;;
    hardlink) ln "$journal" "$saved" ;;
    symlink) mv "$journal" "$saved"; ln -s "$saved" "$journal" ;;
    directory) mv "$journal" "$saved"; mkdir "$journal" ;;
  esac
  if stage "$operation" acme.state-test "$source" >/dev/null 2>&1; then
    printf 'not ok - %s journal was accepted\n' "$kind" >&2; exit 1
  fi
  [[ -e $journal || -L $journal ]]
  if stage "$operation" acme.state-test "$source" >/dev/null 2>&1; then
    printf 'not ok - %s journal reopened its operation ID\n' "$kind" >&2; exit 1
  fi
}
special_journal_case 1 oversized
special_journal_case 2 hardlink
special_journal_case 3 symlink
special_journal_case 4 directory
printf 'ok - oversized, hard-linked, symlink and wrong-type journals cannot reopen an operation ID\n'

missing_operation=50000000-0000-4000-8000-000000000001
missing_source="$TEST_ROOT/missing"; make_plugin "$missing_source"; stage "$missing_operation" acme.state-test "$missing_source" >/dev/null
find "$STORE/$missing_operation" -depth -delete
expect_failure manual-attention stage "$missing_operation" acme.state-test "$missing_source"
[[ $(jq -r .state "$STATE/journals/$missing_operation.journal") == MANUAL_ATTENTION ]]
printf 'ok - durable STAGED contradiction becomes transaction-level manual attention\n'

plugin_a_hash=$(printf acme.state-test | "$HELPER" domain-hash omarchy-plugin-transaction-plugin-lock/v1)
plugin_b_hash=$(printf other.state-test | "$HELPER" domain-hash omarchy-plugin-transaction-plugin-lock/v1)
coproc PLUGIN_LOCK_A { "$HELPER" plugin-lock "$STATE" "$plugin_a_hash"; }
lock_pid=$PLUGIN_LOCK_A_PID
IFS= read -r lock_ready <&"${PLUGIN_LOCK_A[0]}"
[[ $lock_ready == locked ]]
if "$HELPER" plugin-lock "$STATE" "$plugin_a_hash" </dev/null >"$TEST_ROOT/plugin-busy.out" 2>"$TEST_ROOT/plugin-busy.err"; then
  printf 'not ok - same plugin lock was acquired twice\n' >&2; exit 1
fi
grep -qF plugin-busy "$TEST_ROOT/plugin-busy.err"
"$HELPER" plugin-lock "$STATE" "$plugin_b_hash" </dev/null >"$TEST_ROOT/plugin-other.out"
grep -qF locked "$TEST_ROOT/plugin-other.out"
lock_input_fd=${PLUGIN_LOCK_A[1]}
exec {lock_input_fd}>&-
wait "$lock_pid"
printf 'ok - plugin lifecycle locks conflict per plugin and isolate unrelated plugins\n'

# The only O-5 seam that needs both locks acquires the blocking operation lock
# first and the nonblocking plugin lifecycle lock second.
ordered_operation=70000000-0000-4000-8000-000000000001
mkfifo "$TEST_ROOT/ordered-ready" "$TEST_ROOT/ordered-resume" "$TEST_ROOT/ordered-hold" "$TEST_ROOT/ordered-output"
exec {ordered_hold_fd}<>"$TEST_ROOT/ordered-hold"
exec {ordered_output_fd}<>"$TEST_ROOT/ordered-output"
(
  exec {ordered_hold_fd}>&-
  OMARCHY_PLUGIN_TREE_TEST_HOOK=after-ordered-operation-lock \
  OMARCHY_PLUGIN_TREE_TEST_READY_FIFO="$TEST_ROOT/ordered-ready" \
  OMARCHY_PLUGIN_TREE_TEST_RESUME_FIFO="$TEST_ROOT/ordered-resume" \
    "$HELPER" ordered-lock "$STATE" "$ordered_operation" "$plugin_a_hash" \
    <"$TEST_ROOT/ordered-hold" >"$TEST_ROOT/ordered-output" 2>"$TEST_ROOT/ordered.err"
) &
ordered_pid=$!
[[ $(cat "$TEST_ROOT/ordered-ready") == after-ordered-operation-lock ]]
if flock -n "$STATE/locks/operations/$ordered_operation.lock" true; then
  printf 'not ok - ordered seam did not hold operation lock first\n' >&2; exit 1
fi
# The plugin lock remains available until the operation-lock barrier releases.
"$HELPER" plugin-lock "$STATE" "$plugin_a_hash" </dev/null >"$TEST_ROOT/ordered-plugin-before.out"
printf x >"$TEST_ROOT/ordered-resume"
IFS= read -r ordered_ready <&"$ordered_output_fd"
[[ $ordered_ready == locked-operation-then-plugin ]]
if "$HELPER" plugin-lock "$STATE" "$plugin_a_hash" </dev/null >/dev/null 2>"$TEST_ROOT/ordered-busy.err"; then
  printf 'not ok - ordered seam did not hold plugin lock second\n' >&2; exit 1
fi
grep -qF plugin-busy "$TEST_ROOT/ordered-busy.err"
exec {ordered_hold_fd}>&-
exec {ordered_output_fd}>&-
wait "$ordered_pid"
printf 'ok - ordered seam proves operation lock precedes plugin lifecycle lock\n'

[[ -d $STORE/$operation && -d $STORE/$publish_operation ]]
[[ -z $(find "$PLUGIN_DIR" -mindepth 1 -print -quit) ]]
printf 'ok - retained candidates persist and no live discovery namespace is mutated\n'
