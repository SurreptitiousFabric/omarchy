#!/bin/bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

SOURCE_ROOT=${OMARCHY_REGISTRY_AUTHORITY_SOURCE_ROOT:-$ROOT}
EXPECTATION=${OMARCHY_REGISTRY_AUTHORITY_EXPECTATION:-corrected}
FIXTURE="$ROOT/test/shell.d/fixtures/plugin-registry-authority/shell.qml"
TEST_ROOT=$(mktemp -d)
QS_PID=""

cleanup() {
  if [[ -n $QS_PID ]] && kill -0 "$QS_PID" 2>/dev/null; then
    kill "$QS_PID" 2>/dev/null || true
    wait "$QS_PID" 2>/dev/null || true
  fi
  find "$TEST_ROOT" -mindepth 1 -delete
  rmdir "$TEST_ROOT"
}
trap cleanup EXIT

require_command quickshell
require_command jq

plugin_id=acme.registry-authority

write_manifest() {
  local directory=$1
  mkdir -p "$directory"
  jq -n --arg id "$plugin_id" '{
    schemaVersion:1,
    id:$id,
    name:"Registry authority fixture",
    version:"1.0.0",
    kinds:["service"],
    entryPoints:{service:"Service.qml"}
  }' >"$directory/manifest.json"
  printf 'import QtQuick\nQtObject {}\n' >"$directory/Service.qml"
}

run_scan() {
  local name=$1 scenario=$2
  local root="$TEST_ROOT/$name"
  local config="$root/config"
  local plugins="$root/home/.config/omarchy/plugins"
  local expected="$plugins/expected-slot"
  local result="$root/result.json"
  local log="$root/quickshell.log"
  mkdir -p "$config" "$plugins" "$root/home/.cache" "$root/home/.local/state" "$root/runtime"
  chmod 0700 "$root/runtime"
  cp "$FIXTURE" "$config/shell.qml"
  ln -s "$SOURCE_ROOT/shell/services" "$config/services"
  ln -s "$SOURCE_ROOT/shell/Commons" "$config/Commons"

  case $scenario in
    exact|failed)
      write_manifest "$expected"
      ;;
    malformed)
      mkdir -p "$expected"
      printf '{\n' >"$expected/manifest.json"
      ;;
    duplicate)
      write_manifest "$expected"
      write_manifest "$plugins/sibling-slot"
      ;;
    mismatch)
      write_manifest "$plugins/other-slot"
      ;;
    absent) ;;
  esac
  [[ $scenario != failed ]] || chmod 000 "$expected/manifest.json"

  OMARCHY_QML_TEST_RESULT="$result" \
  OMARCHY_REGISTRY_EXPECTED_PLUGIN="$plugin_id" \
  OMARCHY_REGISTRY_EXPECTED_SOURCE="$expected" \
  OMARCHY_REGISTRY_FIRST_PARTY="$root/no-first-party" \
  OMARCHY_REGISTRY_PLUGIN_DIR="$plugins" \
  HOME="$root/home" XDG_CONFIG_HOME="$root/home/.config" \
  XDG_CACHE_HOME="$root/home/.cache" XDG_STATE_HOME="$root/home/.local/state" \
  XDG_RUNTIME_DIR="$root/runtime" \
  QT_QPA_PLATFORM=offscreen \
  QML2_IMPORT_PATH="$SOURCE_ROOT/shell${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}" \
  QML_IMPORT_PATH="$SOURCE_ROOT/shell${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}" \
    quickshell -p "$config" --no-color >"$log" 2>&1 &
  QS_PID=$!
  for _ in {1..100}; do
    [[ -s $result ]] && break
    kill -0 "$QS_PID" 2>/dev/null || {
      sed -n '1,200p' "$log" >&2
      fail "$name scanner process remained alive"
    }
    sleep 0.02
  done
  [[ -s $result ]] || {
    sed -n '1,200p' "$log" >&2
    fail "$name scanner result arrived"
  }
  kill "$QS_PID" 2>/dev/null || true
  wait "$QS_PID" 2>/dev/null || true
  QS_PID=""
  chmod 0600 "$expected/manifest.json" 2>/dev/null || true
  printf '%s\n' "$result"
}

if [[ $EXPECTATION == reviewed-duplicate ]]; then
  duplicate_result=$(run_scan reviewed-duplicate duplicate)
  [[ $(jq -r .selected "$duplicate_result") == true ]]
  [[ $(jq -r .selectedSource "$duplicate_result") != "$(dirname "$duplicate_result")/home/.config/omarchy/plugins/expected-slot" ]]
  pass "reviewed head silently selects one source for a duplicate third-party id"
  exit 0
fi

exact_result=$(run_scan exact exact)
expected_exact="$(dirname "$exact_result")/home/.config/omarchy/plugins/expected-slot"
jq -e --arg source "$expected_exact" '
  .selected == true
  and .selectedSource == $source
  and .entryPointUrl == ("file://" + $source + "/Service.qml")
  and .scanSuccessful == true
  and .binding.valid == true
  and .binding.sourceDirectory == $source
' "$exact_result" >/dev/null
pass "one successful manifest binds discovery and Loader URL to the exact expected source"

failed_result=$(run_scan failed failed)
jq -e '.scanSuccessful == false and .scanStatus == "scan-process-failed"
  and .exitCode != 0 and .selected == false and .binding.valid == false' \
  "$failed_result" >/dev/null
pass "a nonzero manifest scanner cannot acknowledge discovery"

absent_result=$(run_scan absent absent)
jq -e '.selected == false and .binding.status == "target-manifest-absent"' \
  "$absent_result" >/dev/null
pass "an absent target cannot acknowledge discovery"

malformed_result=$(run_scan malformed malformed)
jq -e '.selected == false and .binding.status == "target-manifest-invalid"' \
  "$malformed_result" >/dev/null
pass "a malformed target cannot acknowledge discovery"

duplicate_result=$(run_scan duplicate duplicate)
jq -e '.selected == false and (.sources | length) == 2
  and .binding.status == "duplicate-plugin-id"' "$duplicate_result" >/dev/null
pass "duplicate third-party ids remain visible and non-loadable"

mismatch_result=$(run_scan mismatch mismatch)
jq -e '.selected == true and .binding.status == "registry-source-mismatch"' \
  "$mismatch_result" >/dev/null
pass "a selected source different from the expected destination cannot acknowledge discovery"

pass "directory basename compatibility is preserved while exact operation-bound source identity is enforced"
