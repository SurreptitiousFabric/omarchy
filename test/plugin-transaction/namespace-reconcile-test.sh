#!/bin/bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/interface-test-lib.sh"

ROOT=$(interface_test_root)
TEST_ROOT=$(mktemp -d)
trap 'find "$TEST_ROOT" -mindepth 1 -delete; rmdir "$TEST_ROOT"' EXIT
INSTALL_ROOT="$TEST_ROOT/install/share/omarchy"
build_interface_install "$ROOT" "$INSTALL_ROOT"
NATIVE="$INSTALL_ROOT/native/plugin-transaction/plugin-tree"

assert_reconciled() {
  local result=$1
  jq -e '.status == "reconciled-durable"' <<<"$result" >/dev/null || {
    printf 'unexpected reconciliation result: %s\n' "$result" >&2
    return 1
  }
}

# A visible post-rename install is not authoritative until both parents have
# been synchronized and the exact candidate identity has been rechecked.
INSTALL_LAYOUT="$TEST_ROOT/install-layout"
INSTALL_PARENT="$INSTALL_LAYOUT/candidate-store/operation"
DISCOVERY_PARENT="$INSTALL_LAYOUT/discovery"
PLUGIN=acme.reconcile.install
mkdir -p "$INSTALL_PARENT" "$DISCOVERY_PARENT"
make_interface_plugin "$ROOT" "$INSTALL_PARENT/candidate" "$PLUGIN"
IDENTITY=$($NATIVE identity "$INSTALL_PARENT/candidate")
mv "$INSTALL_PARENT/candidate" "$DISCOVERY_PARENT/$PLUGIN"
RESULT=$($NATIVE namespace-reconcile install-post "$INSTALL_PARENT" candidate \
  "$DISCOVERY_PARENT" "$PLUGIN" "$IDENTITY" "$IDENTITY")
assert_reconciled "$RESULT"
[[ ! -e "$INSTALL_PARENT/candidate" && -d "$DISCOVERY_PARENT/$PLUGIN" ]] ||
  { echo "install post-layout changed during read-only reconciliation" >&2; exit 1; }
[[ $($NATIVE identity "$DISCOVERY_PARENT/$PLUGIN") == "$IDENTITY" ]] ||
  { echo "install post-layout identity changed" >&2; exit 1; }
printf 'ok - install post-layout reconciliation proves parent durability without mutation\n'

set +e
RESULT=$(OMARCHY_PLUGIN_TREE_TEST_FAIL_FSYNC=namespace-reconcile-candidate-parent \
  "$NATIVE" namespace-reconcile install-post "$INSTALL_PARENT" candidate \
  "$DISCOVERY_PARENT" "$PLUGIN" "$IDENTITY" "$IDENTITY")
STATUS=$?
set -e
[[ $STATUS == 5 ]] || { echo "install reconciliation fsync failure was not indeterminate" >&2; exit 1; }
jq -e '.status == "indeterminate-namespace"' <<<"$RESULT" >/dev/null || exit 1
[[ ! -e "$INSTALL_PARENT/candidate" && -d "$DISCOVERY_PARENT/$PLUGIN" ]] ||
  { echo "failed reconciliation mutated install layout" >&2; exit 1; }
printf 'ok - install reconciliation parent-fsync failure remains indeterminate\n'

# Update post-layout and restored-layout reads cover the basename-independent
# authoritative destination and the no-repeat rollback boundary.
UPDATE_LAYOUT="$TEST_ROOT/update-layout"
UPDATE_PARENT="$UPDATE_LAYOUT/candidate-store/operation"
UPDATE_DISCOVERY="$UPDATE_LAYOUT/discovery"
UPDATE_PLUGIN=acme.reconcile.update
mkdir -p "$UPDATE_PARENT" "$UPDATE_DISCOVERY"
make_interface_plugin "$ROOT" "$UPDATE_LAYOUT/prior" "$UPDATE_PLUGIN"
printf 'prior\n' >>"$UPDATE_LAYOUT/prior/Service.qml"
make_interface_plugin "$ROOT" "$UPDATE_LAYOUT/candidate-source" "$UPDATE_PLUGIN"
printf 'candidate\n' >>"$UPDATE_LAYOUT/candidate-source/Service.qml"
PRIOR_IDENTITY=$($NATIVE identity "$UPDATE_LAYOUT/prior")
CANDIDATE_IDENTITY=$($NATIVE identity "$UPDATE_LAYOUT/candidate-source")
mv "$UPDATE_LAYOUT/prior" "$UPDATE_PARENT/candidate"
mv "$UPDATE_LAYOUT/candidate-source" "$UPDATE_DISCOVERY/repository-folder"
RESULT=$($NATIVE namespace-reconcile exchange-post "$UPDATE_PARENT" candidate \
  "$UPDATE_DISCOVERY" repository-folder "$PRIOR_IDENTITY" "$CANDIDATE_IDENTITY")
assert_reconciled "$RESULT"
[[ $($NATIVE identity "$UPDATE_PARENT/candidate") == "$PRIOR_IDENTITY" &&
   $($NATIVE identity "$UPDATE_DISCOVERY/repository-folder") == "$CANDIDATE_IDENTITY" ]] ||
  { echo "update post-layout identity mismatch" >&2; exit 1; }
printf 'ok - update post-layout reconciliation accepts a basename-independent destination\n'

mv "$UPDATE_PARENT/candidate" "$UPDATE_LAYOUT/retained-candidate"
mv "$UPDATE_DISCOVERY/repository-folder" "$UPDATE_PARENT/candidate"
mv "$UPDATE_LAYOUT/retained-candidate" "$UPDATE_DISCOVERY/repository-folder"
RESULT=$($NATIVE namespace-reconcile rollback-exchange-restored "$UPDATE_PARENT" candidate \
  "$UPDATE_DISCOVERY" repository-folder "$CANDIDATE_IDENTITY" "$PRIOR_IDENTITY")
assert_reconciled "$RESULT"
[[ $($NATIVE identity "$UPDATE_PARENT/candidate") == "$CANDIDATE_IDENTITY" &&
   $($NATIVE identity "$UPDATE_DISCOVERY/repository-folder") == "$PRIOR_IDENTITY" ]] ||
  { echo "update restored-layout identity mismatch" >&2; exit 1; }
printf 'ok - update restored-layout reconciliation prevents a second exchange\n'
