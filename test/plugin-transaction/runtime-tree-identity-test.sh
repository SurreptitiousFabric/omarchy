#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'find "$TEST_ROOT" -mindepth 1 -delete; rmdir "$TEST_ROOT"' EXIT
HELPER="$TEST_ROOT/plugin-tree"
SANITIZER_FLAGS=${OMARCHY_PLUGIN_TREE_SANITIZER_FLAGS:-}
read -r -a sanitizer_flags <<<"$SANITIZER_FLAGS"
if [[ -n $SANITIZER_FLAGS ]]; then
  export ASAN_OPTIONS="${ASAN_OPTIONS:+$ASAN_OPTIONS:}halt_on_error=1"
  export UBSAN_OPTIONS="${UBSAN_OPTIONS:+$UBSAN_OPTIONS:}halt_on_error=1"
fi

mise exec -- clang -std=c17 -Wall -Wextra -Werror -Wconversion -Wshadow -O2 -DOMARCHY_PLUGIN_TREE_TEST_HOOKS \
  "${sanitizer_flags[@]}" \
  "$ROOT/native/plugin-transaction/plugin-tree.c" -o "$HELPER"

identity() {
  "$HELPER" identity "$1"
}

expect_rejection() {
  local code="$1" tree="$2"
  local output
  if output=$(identity "$tree" 2>&1); then
    printf 'not ok - expected %s rejection\n' "$code" >&2
    exit 1
  fi
  grep -qF "omarchy-plugin-tree: $code:" <<<"$output"
  if grep -qF 'omarchy-runtime-tree-sha256-v1:' <<<"$output"; then
    printf 'not ok - rejected tree returned an identity\n' >&2
    exit 1
  fi
}

mkdir -p "$TEST_ROOT/golden/sub"
printf 'alpha\n' >"$TEST_ROOT/golden/a.txt"
printf 'beta\n' >"$TEST_ROOT/golden/sub/run"
chmod 0700 "$TEST_ROOT/golden/sub/run"
golden=$(identity "$TEST_ROOT/golden")
[[ $golden == "omarchy-runtime-tree-sha256-v1:e118dae48dce476e9ba27fd9b29464f0887a7ddb31ad94d634f440ea9bf9ef2c" ]]
[[ $(identity "$TEST_ROOT/golden") == "$golden" ]]
printf 'ok - fixed golden identity is deterministic\n'

cp -a "$TEST_ROOT/golden" "$TEST_ROOT/content"
printf 'zeta\n' >"$TEST_ROOT/content/a.txt"
[[ $(identity "$TEST_ROOT/content") != "$golden" ]]
cp -a "$TEST_ROOT/golden" "$TEST_ROOT/mode"
chmod 0644 "$TEST_ROOT/mode/sub/run"
[[ $(identity "$TEST_ROOT/mode") != "$golden" ]]
chmod 0600 "$TEST_ROOT/mode/sub/run"
mode_plain=$(identity "$TEST_ROOT/mode")
chmod 0666 "$TEST_ROOT/mode/sub/run"
[[ $(identity "$TEST_ROOT/mode") == "$mode_plain" ]]
touch -d '2001-01-01 UTC' "$TEST_ROOT/mode/sub/run"
[[ $(identity "$TEST_ROOT/mode") == "$mode_plain" ]]
owner_baseline=$(identity "$TEST_ROOT/mode")
if [[ -z $SANITIZER_FLAGS ]]; then
  owner_changed=$(fakeroot -- sh -c 'chown 123:456 "$1/sub/run"; "$2" identity "$1"' \
    sh "$TEST_ROOT/mode" "$HELPER")
  [[ $owner_changed == "$owner_baseline" ]]
fi
printf 'ok - identity binds content and normalized execute mode, not ownership or timestamps\n'

mkdir "$TEST_ROOT/order-a" "$TEST_ROOT/order-b"
printf latin >"$TEST_ROOT/order-a/z"
printf unicode >"$TEST_ROOT/order-a/é"
printf unicode >"$TEST_ROOT/order-b/é"
printf latin >"$TEST_ROOT/order-b/z"
[[ $(identity "$TEST_ROOT/order-a") == "omarchy-runtime-tree-sha256-v1:908208569b7cb1185938bc9f789810a61d5d284abf48b6539de69c1165c2913d" ]]
[[ $(identity "$TEST_ROOT/order-b") == "omarchy-runtime-tree-sha256-v1:908208569b7cb1185938bc9f789810a61d5d284abf48b6539de69c1165c2913d" ]]
literal_order_digest=$({
  printf 'omarchy-runtime-tree-sha256-v1\0'
  printf 'F\0\0\0\1z\0\0\1\244\0\0\0\0\0\0\0\5latin'
  printf 'F\0\0\0\2\303\251\0\0\1\244\0\0\0\0\0\0\0\7unicode'
} | sha256sum | cut -d' ' -f1)
[[ $literal_order_digest == 908208569b7cb1185938bc9f789810a61d5d284abf48b6539de69c1165c2913d ]]
printf 'ok - encoded UTF-8 byte ordering is stable\n'

mkdir -p "$TEST_ROOT/empty-directories/a/b" "$TEST_ROOT/empty-directories/z"
empty_digest=bdcf87b220d5153f8e9993c42f285c9e2622091d5b21e8697e42d9238970db75
[[ $(identity "$TEST_ROOT/empty-directories") == "omarchy-runtime-tree-sha256-v1:$empty_digest" ]]
chmod 0700 "$TEST_ROOT/empty-directories/a" "$TEST_ROOT/empty-directories/a/b"
chmod 0777 "$TEST_ROOT/empty-directories/z"
[[ $(identity "$TEST_ROOT/empty-directories") == "omarchy-runtime-tree-sha256-v1:$empty_digest" ]]
literal_empty_digest=$({
  printf 'omarchy-runtime-tree-sha256-v1\0'
  printf 'D\0\0\0\1a\0\0\1\355\0\0\0\0\0\0\0\0'
  printf 'D\0\0\0\3a/b\0\0\1\355\0\0\0\0\0\0\0\0'
  printf 'D\0\0\0\1z\0\0\1\355\0\0\0\0\0\0\0\0'
} | sha256sum | cut -d' ' -f1)
[[ $literal_empty_digest == "$empty_digest" ]]
printf 'ok - empty-directory records and normalized directory mode match literal bytes\n'

mkdir "$TEST_ROOT/buffer-boundary"
head -c 65536 /dev/zero | tr '\0' x >"$TEST_ROOT/buffer-boundary/block"
buffer_digest=7dbe9417c7868662f1ba31c7d12b3e6921fb236a2aa218c6fa7476f0d030793f
[[ $(identity "$TEST_ROOT/buffer-boundary") == "omarchy-runtime-tree-sha256-v1:$buffer_digest" ]]
literal_buffer_digest=$({
  printf 'omarchy-runtime-tree-sha256-v1\0'
  printf 'F\0\0\0\5block\0\0\1\244\0\0\0\0\0\1\0\0'
  head -c 65536 /dev/zero | tr '\0' x
} | sha256sum | cut -d' ' -f1)
[[ $literal_buffer_digest == "$buffer_digest" ]]
printf 'ok - exact copy-buffer-boundary content matches a literal canonical stream\n'

mkdir "$TEST_ROOT/multi-buffer"
{
  head -c 65536 /dev/zero | tr '\0' x
  printf y
} >"$TEST_ROOT/multi-buffer/block"
multi_buffer_digest=54b11fce6589efbe5afc9dd9ac2ceee59ce30daf280610019df2c572c80033e9
[[ $(identity "$TEST_ROOT/multi-buffer") == "omarchy-runtime-tree-sha256-v1:$multi_buffer_digest" ]]
literal_multi_buffer_digest=$({
  printf 'omarchy-runtime-tree-sha256-v1\0'
  printf 'F\0\0\0\5block\0\0\1\244\0\0\0\0\0\1\0\1'
  head -c 65536 /dev/zero | tr '\0' x
  printf y
} | sha256sum | cut -d' ' -f1)
[[ $literal_multi_buffer_digest == "$multi_buffer_digest" ]]
printf z | dd of="$TEST_ROOT/multi-buffer/block" bs=1 seek=65536 conv=notrunc status=none
[[ $(identity "$TEST_ROOT/multi-buffer") != "omarchy-runtime-tree-sha256-v1:$multi_buffer_digest" ]]
printf 'ok - 65537-byte literal vector crosses reads and binds its final byte\n'

mkdir "$TEST_ROOT/invalid-utf8"
invalid_name=$(printf 'bad\377')
printf x >"$TEST_ROOT/invalid-utf8/$invalid_name"
expect_rejection invalid-utf8 "$TEST_ROOT/invalid-utf8"
printf 'ok - invalid UTF-8 names are rejected\n'

mkdir "$TEST_ROOT/readdir-errno"
printf entry >"$TEST_ROOT/readdir-errno/value"
readdir_identity=$(identity "$TEST_ROOT/readdir-errno")
[[ $(OMARCHY_PLUGIN_TREE_TEST_STALE_READDIR_ERRNO=1 \
  identity "$TEST_ROOT/readdir-errno") == "$readdir_identity" ]]
printf 'ok - stale errno after a successful entry does not turn normal EOF into failure\n'

if OMARCHY_PLUGIN_TREE_TEST_READDIR_ERROR=1 identity "$TEST_ROOT/readdir-errno" \
    >"$TEST_ROOT/readdir-error.out" 2>"$TEST_ROOT/readdir-error.err"; then
  printf 'not ok - injected readdir error was accepted\n' >&2
  exit 1
fi
grep -qF 'omarchy-plugin-tree: io: read directory:' "$TEST_ROOT/readdir-error.err"
grep -qF 'Input/output error' "$TEST_ROOT/readdir-error.err"
printf 'ok - genuine readdir error remains a typed fail-closed result\n'

ln -s "$TEST_ROOT/golden" "$TEST_ROOT/root-link"
if identity "$TEST_ROOT/root-link" >"$TEST_ROOT/root-link.out" 2>"$TEST_ROOT/root-link.err"; then
  printf 'not ok - root symlink was followed\n' >&2
  exit 1
fi
printf 'ok - root symlink is not followed\n'

cp -a "$TEST_ROOT/golden" "$TEST_ROOT/root-git"
mkdir "$TEST_ROOT/root-git/.git"
printf ignored >"$TEST_ROOT/root-git/.git/index"
[[ $(identity "$TEST_ROOT/root-git") == "$golden" ]]
mkdir -p "$TEST_ROOT/root-git/sub/.git"
expect_rejection nested-git "$TEST_ROOT/root-git"
printf 'ok - root .git is excluded and nested .git is rejected\n'

cp -a "$TEST_ROOT/golden" "$TEST_ROOT/hostile"
ln -s a.txt "$TEST_ROOT/hostile/link"
expect_rejection symlink "$TEST_ROOT/hostile"
unlink "$TEST_ROOT/hostile/link"
ln "$TEST_ROOT/hostile/a.txt" "$TEST_ROOT/hostile/hard"
expect_rejection hard-link "$TEST_ROOT/hostile"
unlink "$TEST_ROOT/hostile/hard"
mkfifo "$TEST_ROOT/hostile/fifo"
expect_rejection special-file "$TEST_ROOT/hostile"
printf 'ok - links and special files are rejected\n'

mkdir "$TEST_ROOT/depth-directory"
deep="$TEST_ROOT/depth-directory"
for index in $(seq 1 32); do deep="$deep/d$index"; mkdir "$deep"; done
identity "$TEST_ROOT/depth-directory" >/dev/null
mkdir "$deep/d33"
expect_rejection depth-limit "$TEST_ROOT/depth-directory"

mkdir "$TEST_ROOT/depth-file-32"
deep="$TEST_ROOT/depth-file-32"
for index in $(seq 1 31); do deep="$deep/d$index"; mkdir "$deep"; done
: >"$deep/file"
identity "$TEST_ROOT/depth-file-32" >/dev/null

mkdir "$TEST_ROOT/depth-file-33"
deep="$TEST_ROOT/depth-file-33"
for index in $(seq 1 32); do deep="$deep/d$index"; mkdir "$deep"; done
: >"$deep/file"
expect_rejection depth-limit "$TEST_ROOT/depth-file-33"
printf 'ok - files and directories are accepted at level 32 and rejected at level 33\n'

mkdir "$TEST_ROOT/entries"
for index in $(seq 1 4096); do : >"$TEST_ROOT/entries/e$index"; done
identity "$TEST_ROOT/entries" >/dev/null
: >"$TEST_ROOT/entries/overflow"
expect_rejection entry-limit "$TEST_ROOT/entries"
printf 'ok - entry-count boundary is checked below and above\n'

mkdir -p "$TEST_ROOT/nested-entries/bucket"
for index in $(seq 1 4095); do : >"$TEST_ROOT/nested-entries/bucket/e$index"; done
identity "$TEST_ROOT/nested-entries" >/dev/null
: >"$TEST_ROOT/nested-entries/bucket/overflow"
expect_rejection entry-limit "$TEST_ROOT/nested-entries"
printf 'ok - global nested entry count is enforced at 4096 and rejected at 4097\n'

mkdir "$TEST_ROOT/path"
component=$(printf 'p%.0s' $(seq 1 200))
path="$TEST_ROOT/path"
for index in $(seq 1 5); do path="$path/$component"; mkdir "$path"; done
short=$(printf 's%.0s' $(seq 1 19))
: >"$path/$short"
identity "$TEST_ROOT/path" >/dev/null
long=$(printf 'l%.0s' $(seq 1 20))
: >"$path/$long"
expect_rejection path-limit "$TEST_ROOT/path"
printf 'ok - relative-path byte boundary is checked below and above\n'

mkdir "$TEST_ROOT/file-size"
truncate -s 16777216 "$TEST_ROOT/file-size/accepted"
identity "$TEST_ROOT/file-size" >/dev/null
truncate -s 16777217 "$TEST_ROOT/file-size/rejected"
expect_rejection file-size-limit "$TEST_ROOT/file-size"
printf 'ok - individual-file boundary is checked below and above\n'

mkdir "$TEST_ROOT/total-size"
for index in 1 2 3 4; do truncate -s 16777216 "$TEST_ROOT/total-size/f$index"; done
identity "$TEST_ROOT/total-size" >/dev/null
: >"$TEST_ROOT/total-size/extra"
printf x >"$TEST_ROOT/total-size/extra"
expect_rejection total-size-limit "$TEST_ROOT/total-size"
printf 'ok - total-byte boundary is checked below and above\n'

mkdir "$TEST_ROOT/pinned"
printf original >"$TEST_ROOT/pinned/value"
mkfifo "$TEST_ROOT/ready" "$TEST_ROOT/resume"
OMARCHY_PLUGIN_TREE_TEST_HOOK=after-root-open \
OMARCHY_PLUGIN_TREE_TEST_READY_FIFO="$TEST_ROOT/ready" \
OMARCHY_PLUGIN_TREE_TEST_RESUME_FIFO="$TEST_ROOT/resume" \
  "$HELPER" identity "$TEST_ROOT/pinned" >"$TEST_ROOT/pinned.out" 2>"$TEST_ROOT/pinned.err" &
helper_pid=$!
marker=$(cat "$TEST_ROOT/ready")
[[ $marker == "after-root-open" ]]
mv "$TEST_ROOT/pinned" "$TEST_ROOT/pinned-original"
mkdir "$TEST_ROOT/pinned"
printf replacement >"$TEST_ROOT/pinned/value"
printf x >"$TEST_ROOT/resume"
if wait "$helper_pid"; then
  [[ $(<"$TEST_ROOT/pinned.out") == "$(identity "$TEST_ROOT/pinned-original")" ]]
else
  grep -qF 'omarchy-plugin-tree: tree-changed:' "$TEST_ROOT/pinned.err"
fi
[[ ! -s "$TEST_ROOT/pinned.out" || $(<"$TEST_ROOT/pinned.out") != "$(identity "$TEST_ROOT/pinned")" ]]
printf 'ok - root replacement cannot substitute the pinned tree\n'

mkdir "$TEST_ROOT/mutating"
printf original >"$TEST_ROOT/mutating/value"
mkfifo "$TEST_ROOT/ready-mutation" "$TEST_ROOT/resume-mutation"
OMARCHY_PLUGIN_TREE_TEST_HOOK=before-file-restat \
OMARCHY_PLUGIN_TREE_TEST_READY_FIFO="$TEST_ROOT/ready-mutation" \
OMARCHY_PLUGIN_TREE_TEST_RESUME_FIFO="$TEST_ROOT/resume-mutation" \
  "$HELPER" identity "$TEST_ROOT/mutating" >"$TEST_ROOT/mutating.out" 2>"$TEST_ROOT/mutating.err" &
helper_pid=$!
marker=$(cat "$TEST_ROOT/ready-mutation")
[[ $marker == "before-file-restat" ]]
printf changed! >"$TEST_ROOT/mutating/value"
printf x >"$TEST_ROOT/resume-mutation"
if wait "$helper_pid"; then
  printf 'not ok - file mutation was accepted\n' >&2
  exit 1
fi
grep -qF 'omarchy-plugin-tree: tree-changed:' "$TEST_ROOT/mutating.err"
printf 'ok - deterministic barrier detects file mutation\n'

if OMARCHY_PLUGIN_TREE_TEST_ZERO_HASH_SEND=1 identity "$TEST_ROOT/golden" \
    >"$TEST_ROOT/zero-hash.out" 2>"$TEST_ROOT/zero-hash.err"; then
  printf 'not ok - zero-progress hash send was accepted\n' >&2
  exit 1
fi
grep -qF 'omarchy-plugin-tree: io: hash update:' "$TEST_ROOT/zero-hash.err"
grep -qF 'Input/output error' "$TEST_ROOT/zero-hash.err"
printf 'ok - zero-progress hash send terminates with typed EIO\n'

mkdir "$TEST_ROOT/replaced-by-fifo"
printf regular >"$TEST_ROOT/replaced-by-fifo/victim"
mkfifo "$TEST_ROOT/ready-replacement" "$TEST_ROOT/resume-replacement"
OMARCHY_PLUGIN_TREE_TEST_HOOK=before-regular-entry-open \
OMARCHY_PLUGIN_TREE_TEST_READY_FIFO="$TEST_ROOT/ready-replacement" \
OMARCHY_PLUGIN_TREE_TEST_RESUME_FIFO="$TEST_ROOT/resume-replacement" \
  "$HELPER" identity "$TEST_ROOT/replaced-by-fifo" \
  >"$TEST_ROOT/replacement.out" 2>"$TEST_ROOT/replacement.err" &
helper_pid=$!
marker=$(cat "$TEST_ROOT/ready-replacement")
[[ $marker == before-regular-entry-open ]]
rm "$TEST_ROOT/replaced-by-fifo/victim"
mkfifo "$TEST_ROOT/replaced-by-fifo/victim"
printf x >"$TEST_ROOT/resume-replacement"
if wait "$helper_pid"; then
  printf 'not ok - regular-to-FIFO replacement was accepted\n' >&2
  exit 1
fi
grep -Eq 'omarchy-plugin-tree: (special-file|tree-changed):' "$TEST_ROOT/replacement.err"
printf 'ok - replacement FIFO is type-checked through O_PATH without blocking\n'
