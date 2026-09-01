#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SPIKE_DIR=$(mktemp -d)
trap 'find "$SPIKE_DIR" -mindepth 1 -delete; rmdir "$SPIKE_DIR"' EXIT
HELPER="$SPIKE_DIR/helper"

mise exec -- clang -std=c17 -Wall -Wextra -Werror -O2 "$ROOT/test/spikes/plugin-transaction-fs-helper.c" -o "$HELPER"

mkdir -p "$SPIKE_DIR/tree/sub" "$SPIKE_DIR/tree/.git" "$SPIKE_DIR/stage" "$SPIKE_DIR/live"
printf 'alpha\n' >"$SPIKE_DIR/tree/a"
printf 'beta\n' >"$SPIKE_DIR/tree/sub/b"
printf 'ignored\n' >"$SPIKE_DIR/tree/.git/index"
chmod 0755 "$SPIKE_DIR/tree/sub/b"

first=$($HELPER stream "$SPIKE_DIR/tree" | sha256sum | cut -d' ' -f1)
second=$($HELPER stream "$SPIKE_DIR/tree" | sha256sum | cut -d' ' -f1)
[[ $first == "$second" ]]
printf 'changed\n' >"$SPIKE_DIR/tree/.git/index"
third=$($HELPER stream "$SPIKE_DIR/tree" | sha256sum | cut -d' ' -f1)
[[ $first == "$third" ]]
chmod 0644 "$SPIKE_DIR/tree/sub/b"
fourth=$($HELPER stream "$SPIKE_DIR/tree" | sha256sum | cut -d' ' -f1)
[[ $first != "$fourth" ]]
printf 'ok - canonical stream is deterministic, mode-sensitive, and excludes .git\n'

ln -s a "$SPIKE_DIR/tree/link"
if $HELPER stream "$SPIKE_DIR/tree" >/dev/null 2>&1; then exit 1; fi
unlink "$SPIKE_DIR/tree/link"
mkfifo "$SPIKE_DIR/tree/fifo"
if $HELPER stream "$SPIKE_DIR/tree" >/dev/null 2>&1; then exit 1; fi
unlink "$SPIKE_DIR/tree/fifo"
printf 'ok - traversal rejects symlinks and special files\n'

mkdir "$SPIKE_DIR/tree/deep"
deep="$SPIKE_DIR/tree/deep"
for index in $(seq 1 33); do
  deep="$deep/d$index"
  mkdir "$deep"
done
if $HELPER stream "$SPIKE_DIR/tree" >/dev/null 2>&1; then exit 1; fi
find "$SPIKE_DIR/tree/deep" -mindepth 1 -depth -type d -delete
rmdir "$SPIKE_DIR/tree/deep"
truncate -s 67108865 "$SPIKE_DIR/tree/oversized"
if $HELPER stream "$SPIKE_DIR/tree" >/dev/null 2>&1; then exit 1; fi
unlink "$SPIKE_DIR/tree/oversized"
printf 'ok - traversal enforces depth and total-byte bounds\n'

mkdir "$SPIKE_DIR/stage/candidate"
printf candidate >"$SPIKE_DIR/stage/candidate/value"
candidate_hash=$($HELPER stream "$SPIKE_DIR/stage/candidate" | sha256sum | cut -d' ' -f1)
$HELPER install "$SPIKE_DIR/stage" candidate "$SPIKE_DIR/live" plugin
[[ -d $SPIKE_DIR/live/plugin && ! -e $SPIKE_DIR/stage/candidate ]]
live_hash=$($HELPER stream "$SPIKE_DIR/live/plugin" | sha256sum | cut -d' ' -f1)
[[ $candidate_hash == "$live_hash" ]]
mkdir "$SPIKE_DIR/stage/second"
if $HELPER install "$SPIKE_DIR/stage" second "$SPIKE_DIR/live" plugin >/dev/null 2>&1; then exit 1; fi
[[ -d $SPIKE_DIR/stage/second && -d $SPIKE_DIR/live/plugin ]]
printf 'ok - no-replace install is atomic and postchecked\n'

printf old >"$SPIKE_DIR/live/plugin/value"
mkdir "$SPIKE_DIR/stage/candidate"
printf new >"$SPIKE_DIR/stage/candidate/value"
old_hash=$($HELPER stream "$SPIKE_DIR/live/plugin" | sha256sum | cut -d' ' -f1)
new_hash=$($HELPER stream "$SPIKE_DIR/stage/candidate" | sha256sum | cut -d' ' -f1)
$HELPER exchange "$SPIKE_DIR/stage" candidate "$SPIKE_DIR/live" plugin
[[ $(<"$SPIKE_DIR/live/plugin/value") == "new" && $(<"$SPIKE_DIR/stage/candidate/value") == "old" ]]
[[ $($HELPER stream "$SPIKE_DIR/live/plugin" | sha256sum | cut -d' ' -f1) == "$new_hash" ]]
[[ $($HELPER stream "$SPIKE_DIR/stage/candidate" | sha256sum | cut -d' ' -f1) == "$old_hash" ]]
printf 'ok - update exchange retains the exact previous directory\n'

for point in before-install after-install before-exchange after-exchange; do
  fault_root="$SPIKE_DIR/fault-$point"
  mkdir -p "$fault_root/stage/candidate" "$fault_root/live"
  if [[ $point == *exchange ]]; then mkdir "$fault_root/live/plugin"; fi
  operation=install
  [[ $point == *exchange ]] && operation=exchange
  set +e
  OMARCHY_FS_SPIKE_FAULT=$point "$HELPER" "$operation" "$fault_root/stage" candidate "$fault_root/live" plugin >/dev/null 2>&1
  status=$?
  set -e
  [[ $status == 73 ]]
  if [[ $point == before-* ]]; then
    [[ -d $fault_root/stage/candidate ]]
  else
    [[ -d $fault_root/live/plugin ]]
  fi
done
printf 'ok - every namespace mutation has before/after fault evidence\n'
