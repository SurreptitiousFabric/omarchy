#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'find "$TEST_ROOT" -mindepth 1 -delete; rmdir "$TEST_ROOT"' EXIT
HELPER="$TEST_ROOT/plugin-tree"
STAGE="$ROOT/native/plugin-transaction/stage-candidate"
STORE="$TEST_ROOT/state/plugin-candidates-v1"
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
  HOME="$HOME_DIR" PATH="$TEST_ROOT/bin:$PATH" OMARCHY_PATH="$ROOT" \
    OMARCHY_PLUGIN_RACE_MARKER="$MARKER" SHELL_CALLS="$SHELL_CALLS" \
    OMARCHY_PLUGIN_TREE_HELPER="$HELPER" \
    OMARCHY_PLUGIN_VALIDATOR="$ROOT/bin/omarchy-plugin-validate" \
    OMARCHY_PLUGIN_CANDIDATE_STORE="$STORE" \
    "$STAGE" "$@"
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
printf 'ok - completed result binds the transaction-owned snapshot identity\n'

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
printf 'ok - source changes cannot alter a snapshot and exact retry does not copy again\n'

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

catalog_after=$(HOME="$HOME_DIR" OMARCHY_PATH="$ROOT" "$ROOT/bin/omarchy-plugin-catalog")
[[ $catalog_after == "$catalog_before" ]]
jq -e 'all(.[]; .id != "acme.race-marker" and .id != "acme.duplicate")' \
  <<<"$catalog_after" >/dev/null
[[ $(sha256sum "$CONFIG") == "$config_before" ]]
[[ ! -e $MARKER && ! -e $SHELL_CALLS ]]
[[ -z $(find "$PLUGIN_DIR" -mindepth 1 -print -quit) ]]
printf 'ok - staging has no configuration, discovery, rescan, registry, or load effect\n'
