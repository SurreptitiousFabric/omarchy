#!/bin/bash
set -euo pipefail

# Gate B evidence: fresh-process replay from LOAD_GATED uses the actual
# offscreen QML authority and a native barrier before namespace exposure.
OMARCHY_LIFECYCLE_EXPECTATION=o8-load-gated-authority \
  exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/plugin-gate-lifecycle-test.sh"
