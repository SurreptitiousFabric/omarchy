#!/bin/bash
set -euo pipefail

# Test-first O-8 correction control.  This deliberately runs the reviewed
# implementation through the real offscreen QML shell and records the known
# RELEASE_AUTHORIZED/terminalReceipt handoff defect before production QML is
# changed.  The correction pass changes the expectation to a green handoff in
# the follow-up test rather than weakening this negative control.
OMARCHY_LIFECYCLE_EXPECTATION=o8-terminal-reviewed \
  exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/plugin-gate-lifecycle-test.sh"
