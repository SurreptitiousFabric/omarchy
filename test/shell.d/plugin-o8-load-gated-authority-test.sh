#!/bin/bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Intermediate O-8 evidence, not final aggregate Gate B approval. All cases
# reuse the actual offscreen shell and the existing pre-namespace barrier.
evidence_root=${OMARCHY_LIFECYCLE_EVIDENCE_DIR:-$(mktemp -d)}
cleanup() {
  [[ -n ${OMARCHY_LIFECYCLE_EVIDENCE_DIR:-} ]] || rm -rf "$evidence_root"
}
trap cleanup EXIT
mkdir -p "$evidence_root"
OMARCHY_LIFECYCLE_EXPECTATION=o8-load-gated-authority \
  OMARCHY_LIFECYCLE_EVIDENCE_DIR="$evidence_root/real-qml" \
  "$ROOT/test/shell.d/plugin-gate-lifecycle-test.sh"

for comparison in source projection; do
  negative="$evidence_root/negative-$comparison"
  status=0
  OMARCHY_LIFECYCLE_EXPECTATION=o8-load-gated-authority \
    OMARCHY_LIFECYCLE_AUTHORITY_CASE="$comparison" \
    OMARCHY_LIFECYCLE_AUTHORITY_BYPASS="$comparison" \
    OMARCHY_LIFECYCLE_EVIDENCE_DIR="$negative" \
    "$ROOT/test/shell.d/plugin-gate-lifecycle-test.sh" >"$negative.log" 2>&1 || status=$?
  [[ $status == 1 ]] || fail "$comparison comparison negative control did not fail its invariant"
  rg -Fx "not ok - $comparison no-exposure invariant: namespace-helper invocation count must be zero" \
    "$negative.log" >/dev/null || {
    cat "$negative.log" >&2
    fail "$comparison failed for an unrelated reason"
  }
  [[ $(<"$negative/configuration-$comparison/detected-comparison-bypass") == "$comparison" ]] || fail "missing valid bypass evidence"
  [[ $(wc -l <"$negative/configuration-$comparison/namespace-calls") == 1 ]] || fail "negative control lacked attempted exposure"
  pass "test-only $comparison comparison bypass detected: one attempted forward namespace-helper invocation at the barrier"
done
