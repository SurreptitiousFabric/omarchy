#!/bin/bash
set -euo pipefail

# Real offscreen QML evidence for the corrected RELEASE_AUTHORIZED handoff.
OMARCHY_LIFECYCLE_EXPECTATION=o8-terminal-corrected \
  exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/plugin-gate-lifecycle-test.sh"
