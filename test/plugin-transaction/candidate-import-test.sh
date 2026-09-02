#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'find "$TEST_ROOT" -mindepth 1 -delete; rmdir "$TEST_ROOT"' EXIT
HELPER="$TEST_ROOT/plugin-tree"
STAGE="$ROOT/native/plugin-transaction/stage-candidate"
STORE="$TEST_ROOT/state/plugin-candidates-v1"
TRANSACTION_STATE="$TEST_ROOT/state/plugin-transactions-v1"
HOME_DIR="$TEST_ROOT/home"
PLUGIN_DIR="$HOME_DIR/.config/omarchy/plugins"
CONFIG="$HOME_DIR/.config/omarchy/shell.json"
MARKER="$TEST_ROOT/evaluated"
SHELL_CALLS="$TEST_ROOT/shell-calls"
SANITIZER_FLAGS=${OMARCHY_PLUGIN_TREE_SANITIZER_FLAGS:-}
read -r -a sanitizer_flags <<<"$SANITIZER_FLAGS"
if [[ -n $SANITIZER_FLAGS ]]; then
  export ASAN_OPTIONS="${ASAN_OPTIONS:+$ASAN_OPTIONS:}halt_on_error=1"
  export UBSAN_OPTIONS="${UBSAN_OPTIONS:+$UBSAN_OPTIONS:}halt_on_error=1"
fi

mise exec -- clang -std=c17 -Wall -Wextra -Werror -Wconversion -Wshadow -O2 \
  -DOMARCHY_PLUGIN_TREE_TEST_HOOKS \
  "${sanitizer_flags[@]}" \
  "$ROOT/native/plugin-transaction/plugin-tree.c" -o "$HELPER"

mkdir -p "$PLUGIN_DIR" "$(dirname -- "$CONFIG")" "$TEST_ROOT/bin"
printf '{"version":1,"plugins":[]}\n' >"$CONFIG"
cat >"$TEST_ROOT/bin/omarchy-shell" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$SHELL_CALLS"
SH
chmod 0755 "$TEST_ROOT/bin/omarchy-shell"

make_plugin() {
  local destination=$1 plugin_id=${2:-acme.race-marker}
  mkdir -p "$destination"
  cp "$ROOT/test/shell.d/fixtures/plugin-load-race/Service.qml" "$destination/Service.qml"
  jq --arg id "$plugin_id" '.id = $id' \
    "$ROOT/test/shell.d/fixtures/plugin-load-race/manifest.json" >"$destination/manifest.json"
}

stage() {
  local operation=$1 plugin=$2 source=$3 caller_identity
  caller_identity=$(env -u OMARCHY_PLUGIN_TREE_TEST_HOOK \
    -u OMARCHY_PLUGIN_TREE_TEST_READY_FIFO -u OMARCHY_PLUGIN_TREE_TEST_RESUME_FIFO \
    "$HELPER" identity "$source" 2>/dev/null ||
      printf 'omarchy-runtime-tree-sha256-v1:%064d' 0)
  HOME="$HOME_DIR" PATH="$TEST_ROOT/bin:$PATH" OMARCHY_PATH="$ROOT" \
    OMARCHY_PLUGIN_RACE_MARKER="$MARKER" SHELL_CALLS="$SHELL_CALLS" \
    OMARCHY_PLUGIN_TREE_HELPER="$HELPER" \
    OMARCHY_PLUGIN_VALIDATOR="$ROOT/bin/omarchy-plugin-validate" \
    OMARCHY_PLUGIN_CANDIDATE_STORE="$STORE" \
    OMARCHY_PLUGIN_TRANSACTION_STATE="$TRANSACTION_STATE" \
    OMARCHY_PLUGIN_OPERATION_KIND=install \
    OMARCHY_PLUGIN_CALLER_CANDIDATE_IDENTITY="$caller_identity" \
    OMARCHY_PLUGIN_EXPECTED_ACTIVE_STATE=absent \
    OMARCHY_PLUGIN_EXPECTED_CONFIG_SOURCE_KIND=user \
    OMARCHY_PLUGIN_EXPECTED_CONFIG_SOURCE_IDENTITY=test-user-config-v1 \
    OMARCHY_PLUGIN_EXPECTED_REFERENCE_PROJECTION=sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432 \
    OMARCHY_PLUGIN_EXPECTED_REFERENCE_STATE=unreferenced \
    OMARCHY_PLUGIN_REFERENCE_POLICY=require-unreferenced \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_SOURCE=test-injected-o4 \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_RAW_SHA256=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_REFERENCE_PROJECTION=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_REFERENCE_STATE=unreferenced \
    OMARCHY_PLUGIN_DESTINATION="$PLUGIN_DIR/$plugin" \
    "$STAGE" "$operation" "$plugin" "$source" \
    <<<"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
}

expect_stage_failure() {
  local code=$1 operation=$2 plugin=$3 source=$4
  local output
  if output=$(stage "$operation" "$plugin" "$source" 2>&1); then
    printf 'not ok - expected %s failure\n' "$code" >&2
    exit 1
  fi
  grep -qF "omarchy-plugin-candidate-stage: $code:" <<<"$output"
}

operation=11111111-1111-4111-8111-111111111111
source="$TEST_ROOT/source"
make_plugin "$source"
mkdir "$source/.git"
printf ignored-management-state >"$source/.git/index"
config_before=$(sha256sum "$CONFIG")
catalog_before=$(HOME="$HOME_DIR" OMARCHY_PATH="$ROOT" "$ROOT/bin/omarchy-plugin-catalog")

old_umask=$(umask)
umask 000
first_result=$(stage "$operation" acme.race-marker "$source")
umask "$old_umask"
[[ $(stat -c '%a' "$STORE") == 700 ]]
[[ $(stat -c '%a' "$STORE/$operation") == 700 ]]
[[ $(stat -c '%a' "$STORE/$operation/result.json") == 600 ]]
[[ $(stat -c '%a' "$STORE/$operation/candidate") == 700 ]]
jq -e '.schema == "omarchy-plugin-candidate-stage/v1" and
  .operationId == "11111111-1111-4111-8111-111111111111" and
  .pluginId == "acme.race-marker" and .sourceTree == .candidateTree' \
  <<<"$first_result" >/dev/null
printf 'ok - candidate is atomically staged beneath a private store\n'

candidate="$STORE/$operation/candidate"
candidate_identity=$($HELPER identity "$candidate")
[[ $(jq -r .candidateTree <<<"$first_result") == "$candidate_identity" ]]
[[ ! -e $candidate/.git ]]
cmp "$source/manifest.json" "$candidate/manifest.json"
cmp "$source/Service.qml" "$candidate/Service.qml"
[[ $(find "$candidate" -mindepth 1 -printf '%P\n' | sort) == $'Service.qml\nmanifest.json' ]]
printf 'ok - completed result binds the transaction-owned snapshot identity\n'
printf 'ok - independent byte comparison proves copying and excludes a real root .git\n'

multi_source="$TEST_ROOT/multi-source"
multi_parent="$TEST_ROOT/multi-parent"
mkdir "$multi_source" "$multi_parent"
{
  head -c 65536 /dev/zero | tr '\0' x
  printf y
} >"$multi_source/block"
"$HELPER" copy "$multi_source" "$multi_parent" candidate
cmp "$multi_source/block" "$multi_parent/candidate/block"
[[ $(stat -c '%s' "$multi_parent/candidate/block") == 65537 ]]
[[ $("$HELPER" identity "$multi_parent/candidate") == \
  omarchy-runtime-tree-sha256-v1:54b11fce6589efbe5afc9dd9ac2ceee59ce30daf280610019df2c572c80033e9 ]]
printf 'ok - 65537-byte source is copied byte-for-byte with independent expected identity\n'

directory_source="$TEST_ROOT/directory-source"
make_plugin "$directory_source"
mkdir "$directory_source/assets"
printf resource >"$directory_source/assets/value"
chmod 0777 "$directory_source/assets"
stage 88888888-8888-4888-8888-888888888888 acme.race-marker "$directory_source" >/dev/null
[[ $(stat -c '%a' "$STORE/88888888-8888-4888-8888-888888888888/candidate/assets") == 755 ]]
[[ $(stat -c '%a' "$STORE/88888888-8888-4888-8888-888888888888/candidate/assets/value") == 644 ]]
printf 'ok - snapshot modes are normalized independently of caller umask\n'

printf changed-after-copy >"$source/Service.qml"
[[ $($HELPER identity "$candidate") == "$candidate_identity" ]]
cp "$ROOT/test/shell.d/fixtures/plugin-load-race/Service.qml" "$source/Service.qml"
candidate_inode=$(stat -c '%d:%i' "$candidate")
retry_result=$(stage "$operation" acme.race-marker "$source")
[[ $retry_result == "$first_result" ]]
[[ $(stat -c '%d:%i' "$candidate") == "$candidate_inode" ]]
printf 'ok - retry compares a fresh snapshot without republishing the completed candidate\n'

expect_stage_failure operation-conflict "$operation" other.plugin "$source"
conflict_source="$TEST_ROOT/conflict-source"
make_plugin "$conflict_source"
printf different >"$conflict_source/Service.qml"
expect_stage_failure operation-conflict "$operation" acme.race-marker "$conflict_source"
[[ $($HELPER identity "$candidate") == "$candidate_identity" ]]
printf 'ok - conflicting operation reuse preserves the first candidate\n'

mismatch="$TEST_ROOT/mismatch"
make_plugin "$mismatch" another.plugin
expect_stage_failure manifest-id-mismatch \
  22222222-2222-4222-8222-222222222222 acme.race-marker "$mismatch"
[[ ! -e $STORE/22222222-2222-4222-8222-222222222222 ]]
printf 'ok - requested and validated manifest IDs must match\n'

malformed="$TEST_ROOT/malformed"
make_plugin "$malformed"
printf '{' >"$malformed/manifest.json"
expect_stage_failure validation-failed \
  33333333-3333-4333-8333-333333333333 acme.race-marker "$malformed"

invalid="$TEST_ROOT/invalid"
make_plugin "$invalid"
rm "$invalid/Service.qml"
expect_stage_failure validation-failed \
  44444444-4444-4444-8444-444444444444 acme.race-marker "$invalid"

duplicate="$TEST_ROOT/duplicate"
mkdir "$duplicate"
cp "$ROOT/test/shell.d/fixtures/plugin-load-race/Service.qml" "$duplicate/Service.qml"
printf '%s\n' '{"schemaVersion":1,"id":"ignored.first","id":"acme.duplicate","name":"Duplicate","version":"1","kinds":["service"],"entryPoints":{"service":"Service.qml"}}' >"$duplicate/manifest.json"
duplicate_result=$(stage 55555555-5555-4555-8555-555555555555 acme.duplicate "$duplicate")
[[ $(jq -r .pluginId <<<"$duplicate_result") == acme.duplicate ]]
printf 'ok - malformed, duplicate-key, and invalid-plugin behaviour comes from the existing validator\n'

nested_git="$TEST_ROOT/nested-git"
make_plugin "$nested_git"
mkdir -p "$nested_git/assets/.git"
printf metadata >"$nested_git/assets/.git/config"
if stage 66666666-6666-4666-8666-666666666666 acme.race-marker "$nested_git" \
    >"$TEST_ROOT/nested.out" 2>"$TEST_ROOT/nested.err"; then
  printf 'not ok - nested .git was imported\n' >&2
  exit 1
fi
grep -qF 'omarchy-plugin-tree: nested-git:' "$TEST_ROOT/nested.err"
printf 'ok - production import rejects the nested .git case skipped by the O-3 spike\n'

mutating="$TEST_ROOT/mutating"
make_plugin "$mutating"
mkfifo "$TEST_ROOT/ready" "$TEST_ROOT/resume"
OMARCHY_PLUGIN_TREE_TEST_HOOK=before-file-restat \
OMARCHY_PLUGIN_TREE_TEST_READY_FIFO="$TEST_ROOT/ready" \
OMARCHY_PLUGIN_TREE_TEST_RESUME_FIFO="$TEST_ROOT/resume" \
  stage 77777777-7777-4777-8777-777777777777 acme.race-marker "$mutating" \
  >"$TEST_ROOT/mutating.out" 2>"$TEST_ROOT/mutating.err" &
stage_pid=$!
marker=$(cat "$TEST_ROOT/ready")
[[ $marker == before-file-restat ]]
printf 'changed candidate-v' >"$mutating/Service.qml"
printf x >"$TEST_ROOT/resume"
if wait "$stage_pid"; then
  printf 'not ok - source mutation was staged\n' >&2
  exit 1
fi
grep -qF 'omarchy-plugin-tree: tree-changed:' "$TEST_ROOT/mutating.err"
[[ ! -e $STORE/77777777-7777-4777-8777-777777777777 ]]
if compgen -G "$STORE/.import.77777777-7777-4777-8777-777777777777.*" >/dev/null; then
  printf 'not ok - failed import left temporary content\n' >&2
  exit 1
fi
printf 'ok - deterministic source mutation fails without a complete or partial candidate\n'

depth_operation=cccccccc-cccc-4ccc-8ccc-cccccccccccc
depth_source="$TEST_ROOT/depth-source"
make_plugin "$depth_source"
deep="$depth_source"
for index in $(seq 1 32); do deep="$deep/d$index"; mkdir "$deep"; done
: >"$deep/file"
if stage "$depth_operation" acme.race-marker "$depth_source" \
    >"$TEST_ROOT/depth.out" 2>"$TEST_ROOT/depth.err"; then
  printf 'not ok - level-33 file was staged\n' >&2
  exit 1
fi
grep -qF 'omarchy-plugin-tree: depth-limit:' "$TEST_ROOT/depth.err"
[[ ! -s $TEST_ROOT/depth.out ]]
[[ ! -e $STORE/$depth_operation ]]
if compgen -G "$STORE/.import.$depth_operation.*" >/dev/null; then
  printf 'not ok - depth rejection left temporary content\n' >&2
  exit 1
fi
printf 'ok - candidate import rejects level 33 without publishing or partial content\n'

zero_write_operation=dddddddd-dddd-4ddd-8ddd-dddddddddddd
zero_write_source="$TEST_ROOT/zero-write-source"
make_plugin "$zero_write_source"
if OMARCHY_PLUGIN_TREE_TEST_ZERO_WRITE=1 \
    stage "$zero_write_operation" acme.race-marker "$zero_write_source" \
    >"$TEST_ROOT/zero-write.out" 2>"$TEST_ROOT/zero-write.err"; then
  printf 'not ok - zero-progress destination write was accepted\n' >&2
  exit 1
fi
grep -qF 'omarchy-plugin-tree: io: write destination file:' "$TEST_ROOT/zero-write.err"
grep -qF 'Input/output error' "$TEST_ROOT/zero-write.err"
[[ ! -e $STORE/$zero_write_operation ]]
printf 'ok - zero-progress copied-file write terminates with typed EIO\n'

fsync_operation=99999999-9999-4999-8999-999999999999
fsync_source="$TEST_ROOT/fsync-source"
make_plugin "$fsync_source"
if OMARCHY_PLUGIN_TREE_TEST_FAIL_FSYNC=publication-parent \
    stage "$fsync_operation" acme.race-marker "$fsync_source" \
    >"$TEST_ROOT/fsync.out" 2>"$TEST_ROOT/fsync.err"; then
  printf 'not ok - post-rename fsync failure reported success\n' >&2
  exit 1
fi
grep -qF 'omarchy-plugin-tree: publication-rolled-back:' "$TEST_ROOT/fsync.err"
[[ ! -e $STORE/$fsync_operation ]]
fsync_temporary=$(jq -r .candidate.temporarySlot "$TRANSACTION_STATE/journals/$fsync_operation.journal")
[[ $(jq -r .state "$TRANSACTION_STATE/journals/$fsync_operation.journal") == PUBLICATION_INTENT ]]
[[ -d $STORE/$fsync_temporary/candidate ]]
[[ $($HELPER identity "$STORE/$fsync_temporary/candidate") == \
   $(jq -r .candidate.observed "$TRANSACTION_STATE/journals/$fsync_operation.journal") ]]
printf 'ok - compensated publication retains only the exact journal-owned retry candidate\n'

concurrent_operation=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
concurrent_source="$TEST_ROOT/concurrent-source"
make_plugin "$concurrent_source"
mkfifo "$TEST_ROOT/ready-a" "$TEST_ROOT/resume-a"
OMARCHY_PLUGIN_TREE_TEST_HOOK=before-publication \
OMARCHY_PLUGIN_TREE_TEST_READY_FIFO="$TEST_ROOT/ready-a" \
OMARCHY_PLUGIN_TREE_TEST_RESUME_FIFO="$TEST_ROOT/resume-a" \
  stage "$concurrent_operation" acme.race-marker "$concurrent_source" \
  >"$TEST_ROOT/concurrent-a.out" 2>"$TEST_ROOT/concurrent-a.err" &
stage_a=$!
[[ $(cat "$TEST_ROOT/ready-a") == before-publication ]]
stage "$concurrent_operation" acme.race-marker "$concurrent_source" \
  >"$TEST_ROOT/concurrent-b.out" 2>"$TEST_ROOT/concurrent-b.err" &
stage_b=$!
if flock -n "$TRANSACTION_STATE/locks/operations/$concurrent_operation.lock" true; then
  printf 'not ok - operation lock was not held across publication\n' >&2
  exit 1
fi
kill -0 "$stage_b"
[[ ! -s $TEST_ROOT/concurrent-b.out ]]
printf x >"$TEST_ROOT/resume-a"
wait "$stage_a"
wait "$stage_b"
[[ $(<"$TEST_ROOT/concurrent-a.out") == "$(<"$TEST_ROOT/concurrent-b.out")" ]]
[[ -d $STORE/$concurrent_operation/candidate ]]
if compgen -G "$STORE/.import.$concurrent_operation.*" >/dev/null; then
  printf 'not ok - concurrent publication left temporary content\n' >&2
  exit 1
fi
printf 'ok - synchronized concurrent publication returns one exact completed result\n'

saved_store=$STORE
STORE="$PLUGIN_DIR/candidates"
expect_stage_failure store-inside-discovery \
  bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb acme.race-marker "$concurrent_source"
STORE=$saved_store
printf 'ok - candidate store cannot be placed inside plugin discovery\n'

catalog_after=$(HOME="$HOME_DIR" OMARCHY_PATH="$ROOT" "$ROOT/bin/omarchy-plugin-catalog")
[[ $catalog_after == "$catalog_before" ]]
jq -e 'all(.[]; .id != "acme.race-marker" and .id != "acme.duplicate")' \
  <<<"$catalog_after" >/dev/null
[[ $(sha256sum "$CONFIG") == "$config_before" ]]
[[ ! -e $MARKER && ! -e $SHELL_CALLS ]]
[[ -z $(find "$PLUGIN_DIR" -mindepth 1 -print -quit) ]]
printf 'ok - staging has no configuration, discovery, rescan, registry, or load effect\n'
