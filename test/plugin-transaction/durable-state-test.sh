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
TOKEN_B=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
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
  caller_identity=$(env -u OMARCHY_PLUGIN_TREE_TEST_HOOK -u OMARCHY_PLUGIN_TREE_TEST_READY_FIFO \
    -u OMARCHY_PLUGIN_TREE_TEST_RESUME_FIFO -u OMARCHY_PLUGIN_TREE_TEST_CRASH_POINT \
    "$HELPER" identity "$source")
  HOME="$HOME_DIR" OMARCHY_PATH="$ROOT" OMARCHY_PLUGIN_TREE_HELPER="$HELPER" \
    OMARCHY_PLUGIN_VALIDATOR="$ROOT/bin/omarchy-plugin-validate" \
    OMARCHY_PLUGIN_CANDIDATE_STORE="$STORE" OMARCHY_PLUGIN_TRANSACTION_STATE="$STATE" \
    OMARCHY_PLUGIN_OPERATION_KIND="${TEST_OPERATION_KIND:-install}" \
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

for field in plugin source config projection destination operation; do
  case $field in
    plugin) make_plugin "$TEST_ROOT/other-plugin" other.state; expect_failure operation-conflict stage "$operation" other.state "$TEST_ROOT/other-plugin" ;;
    source) cp -a "$source" "$TEST_ROOT/other-source"; expect_failure operation-conflict stage "$operation" acme.state-test "$TEST_ROOT/other-source" ;;
    config) TEST_CONFIG_IDENTITY=other-config expect_failure operation-conflict stage "$operation" acme.state-test "$source" ;;
    projection) TEST_PROJECTION=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc expect_failure operation-conflict stage "$operation" acme.state-test "$source" ;;
    destination) TEST_DESTINATION="$PLUGIN_DIR/other" expect_failure operation-conflict stage "$operation" acme.state-test "$source" ;;
    operation) TEST_OPERATION_KIND=update TEST_ACTIVE_STATE=present TEST_ACTIVE_IDENTITY=omarchy-runtime-tree-sha256-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa TEST_POLICY=preserve-observed expect_failure operation-conflict stage "$operation" acme.state-test "$source" ;;
  esac
done
printf 'ok - immutable request classes and normalized source path are operation-bound\n'

crash_index=10
for point in before-journal-write after-journal-write after-journal-file-sync after-journal-rename; do
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

corrupt_operation=40000000-0000-4000-8000-000000000001
corrupt_source="$TEST_ROOT/corrupt"; make_plugin "$corrupt_source"; stage "$corrupt_operation" acme.state-test "$corrupt_source" >/dev/null
printf '{"state":"STAGED","state":"MANUAL_ATTENTION"}\n' >"$STATE/journals/$corrupt_operation.journal"
expect_failure manual-attention stage "$corrupt_operation" acme.state-test "$corrupt_source"
[[ $(jq -r .state "$STATE/journals/$corrupt_operation.journal") == MANUAL_ATTENTION ]]
compgen -G "$STATE/journals/$corrupt_operation.corrupt.*" >/dev/null
printf 'ok - malformed/noncanonical duplicate-key evidence is preserved before manual attention\n'

corruption_case() {
  local suffix=$1 filter=$2 operation source journal temporary
  operation=$(printf '41000000-0000-4000-8000-%012d' "$suffix")
  source="$TEST_ROOT/corrupt-$suffix"; make_plugin "$source"; stage "$operation" acme.state-test "$source" >/dev/null
  journal="$STATE/journals/$operation.journal"; temporary="$journal.changed"
  jq -cS "$filter" "$journal" >"$temporary"; mv "$temporary" "$journal"
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

[[ -d $STORE/$operation && -d $STORE/$publish_operation ]]
[[ -z $(find "$PLUGIN_DIR" -mindepth 1 -print -quit) ]]
printf 'ok - retained candidates persist and no live discovery namespace is mutated\n'
