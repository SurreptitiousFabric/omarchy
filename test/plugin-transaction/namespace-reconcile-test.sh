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

# Gate B matrix: every reconciliation layout is read-only, and any authority
# or durability failure leaves both package-owned parents unchanged.
run_reconcile_case() {
  local label=$1 operation=$2 fault=${3:-none} mutation=${4:-none}
  local base="$TEST_ROOT/matrix-$label"
  local source_parent="$base/candidate-store/op"
  local dest_parent="$base/discovery" source_name=candidate dest_name=repository-folder
  local source_tree="$base/source-tree" dest_tree="$base/dest-tree" source_id dest_id
  mkdir -p "$source_parent" "$dest_parent"
  make_interface_plugin "$ROOT" "$source_tree" "acme.matrix.$label.source"
  make_interface_plugin "$ROOT" "$dest_tree" "acme.matrix.$label.dest"
  source_id=$($NATIVE identity "$source_tree")
  dest_id=$($NATIVE identity "$dest_tree")
  case "$operation" in
    install-post)
      mv "$source_tree" "$dest_parent/repository-folder"
      source_id="$source_id"; dest_id="$source_id"
      ;;
    rollback-install-restored)
      mv "$source_tree" "$source_parent/candidate"
      dest_id="$source_id"
      ;;
    exchange-post)
      mv "$source_tree" "$source_parent/candidate"
      mv "$dest_tree" "$dest_parent/repository-folder"
      ;;
    rollback-exchange-restored)
      mv "$source_tree" "$source_parent/candidate"
      mv "$dest_tree" "$dest_parent/repository-folder"
      # In the restored image source is the candidate and destination prior.
      ;;
    *) return 1 ;;
  esac
  case "$mutation" in
    source-mismatch) printf 'mutation\n' >>"$source_parent/candidate/Service.qml" 2>/dev/null || true ;;
    dest-mismatch) printf 'mutation\n' >>"$dest_parent/repository-folder/Service.qml" 2>/dev/null || true ;;
    source-symlink)
      rm -rf "$source_parent/candidate"
      ln -s "$source_tree" "$source_parent/candidate"
      ;;
    dest-symlink)
      rm -rf "$dest_parent/repository-folder"
      ln -s "$dest_tree" "$dest_parent/repository-folder"
      ;;
    unexpected-source) mkdir -p "$source_parent/unexpected" ;;
    unexpected-dest) mkdir -p "$dest_parent/unexpected" ;;
  esac
  local before after result status expected_source expected_dest
  before=$(find "$base" -printf '%P %y %s\n' | sort)
  expected_source="$source_id"
  expected_dest="$dest_id"
  if [[ $operation == install-post ]]; then
    expected_source="$source_id"; expected_dest="$source_id"
  elif [[ $operation == rollback-install-restored ]]; then
    expected_source="$source_id"; expected_dest="$source_id"
  fi
  set +e
  if [[ $fault == none ]]; then
    result=$($NATIVE namespace-reconcile "$operation" "$source_parent" "$source_name" \
      "$dest_parent" "$dest_name" "$expected_source" "$expected_dest")
  else
    result=$(OMARCHY_PLUGIN_TREE_TEST_FAIL_FSYNC="$fault" $NATIVE namespace-reconcile \
      "$operation" "$source_parent" "$source_name" "$dest_parent" "$dest_name" \
      "$expected_source" "$expected_dest")
  fi
  status=$?
  set -e
  after=$(find "$base" -printf '%P %y %s\n' | sort)
  [[ "$before" == "$after" ]] || { echo "$label: reconciliation mutated namespace" >&2; return 1; }
  if [[ $fault != none ]]; then
    [[ $status == 5 ]] || { echo "$label: fsync failure status=$status" >&2; return 1; }
    jq -e '.status == "indeterminate-namespace"' <<<"$result" >/dev/null || return 1
  elif [[ $mutation != none && $mutation != unexpected-source && $mutation != unexpected-dest ]]; then
    [[ $status == 5 ]] || { echo "$label: contradiction status=$status" >&2; return 1; }
    jq -e '.status == "exact-postcheck-mismatch"' <<<"$result" >/dev/null || return 1
  else
    assert_reconciled "$result"
  fi
  printf 'ok - namespace reconcile %s (%s, %s) is read-only and authoritative\n' "$label" "$operation" "${fault:-none}"
}

run_reconcile_case install-restored rollback-install-restored none
run_reconcile_case install-restored-candidate-fsync rollback-install-restored namespace-reconcile-candidate-parent
run_reconcile_case install-restored-discovery-fsync rollback-install-restored namespace-reconcile-discovery-parent
run_reconcile_case install-restored-source-mismatch rollback-install-restored none source-mismatch
run_reconcile_case install-restored-source-symlink rollback-install-restored none source-symlink
run_reconcile_case install-restored-dest-symlink rollback-install-restored none dest-symlink

run_reconcile_case exchange-post-candidate-fsync exchange-post namespace-reconcile-candidate-parent
run_reconcile_case exchange-post-discovery-fsync exchange-post namespace-reconcile-discovery-parent
run_reconcile_case exchange-post-source-mismatch exchange-post none source-mismatch
run_reconcile_case exchange-post-dest-mismatch exchange-post none dest-mismatch
run_reconcile_case exchange-post-source-symlink exchange-post none source-symlink
run_reconcile_case exchange-post-dest-symlink exchange-post none dest-symlink
run_reconcile_case exchange-post-unexpected-source exchange-post none unexpected-source
run_reconcile_case exchange-post-unexpected-dest exchange-post none unexpected-dest

run_reconcile_case rollback-exchange-restored-candidate-fsync rollback-exchange-restored namespace-reconcile-candidate-parent
run_reconcile_case rollback-exchange-restored-discovery-fsync rollback-exchange-restored namespace-reconcile-discovery-parent
run_reconcile_case rollback-exchange-restored-source-mismatch rollback-exchange-restored none source-mismatch
run_reconcile_case rollback-exchange-restored-dest-mismatch rollback-exchange-restored none dest-mismatch

printf 'ok - namespace reconciliation matrix covers restored layouts, faults, identities and symlinks\n'
