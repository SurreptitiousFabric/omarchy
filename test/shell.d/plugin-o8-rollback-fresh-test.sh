#!/bin/bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Checkpoint 3A only: same live QML shell, replacement coordinator at the two
# synchronized restoration boundaries. Keep all four independent case results.
evidence_root=${OMARCHY_LIFECYCLE_EVIDENCE_DIR:-$(mktemp -d)}
cleanup() {
  [[ -n ${OMARCHY_LIFECYCLE_EVIDENCE_DIR:-} ]] || rm -rf "$evidence_root"
}
trap cleanup EXIT
mkdir -p "$evidence_root"
failures=()
for kind in install update; do
  for boundary in before-reverse before-rescan; do
    name="$kind-$boundary"
    status=0
    OMARCHY_LIFECYCLE_EXPECTATION=o8-rollback-fresh \
      OMARCHY_LIFECYCLE_ROLLBACK_KIND="$kind" OMARCHY_LIFECYCLE_ROLLBACK_BOUNDARY="$boundary" \
      OMARCHY_LIFECYCLE_EVIDENCE_DIR="$evidence_root/$name" \
      "$ROOT/test/shell.d/plugin-gate-lifecycle-test.sh" >"$evidence_root/$name.log" 2>&1 || status=$?
    printf '%s\n' "$status" >"$evidence_root/$name.exit"
    cat "$evidence_root/$name.log"
    if ((status != 0)); then failures+=("$name"); fi
  done
done

status=0
OMARCHY_LIFECYCLE_EXPECTATION=o8-rollback-fresh \
  OMARCHY_LIFECYCLE_ROLLBACK_KIND=update OMARCHY_LIFECYCLE_ROLLBACK_BOUNDARY=before-rescan \
  OMARCHY_LIFECYCLE_ROLLBACK_REPEAT=1 OMARCHY_LIFECYCLE_EVIDENCE_DIR="$evidence_root/negative-repeat" \
  "$ROOT/test/shell.d/plugin-gate-lifecycle-test.sh" >"$evidence_root/negative-repeat.log" 2>&1 || status=$?
if [[ $status == 1 && -s $evidence_root/negative-repeat/rollback-update-before-rescan/detected-repeat ]] \
  && rg -Fx 'not ok - restored rollback reverse helper invocation count must be zero' "$evidence_root/negative-repeat.log" >/dev/null; then
  pass "copied no-repeat branch defect detected at pre-native barrier; second mutation did not run"
else
  cat "$evidence_root/negative-repeat.log"
  failures+=(no-repeat-control)
fi
((${#failures[@]} == 0)) || fail "fresh rollback checkpoint cases failed: ${failures[*]}"
