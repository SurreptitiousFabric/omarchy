#!/bin/bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command quickshell
require_command jq
require_command node

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

fixture="$ROOT/test/shell.d/fixtures/plugin-transaction-observation"
config="$TEST_ROOT/config"
home="$TEST_ROOT/home"
runtime="$TEST_ROOT/runtime"
result="$TEST_ROOT/result.json"
log="$TEST_ROOT/quickshell.log"
plugin=acme.o7-observation
mkdir -p "$config" "$home/.cache" "$home/.local/state" "$runtime"
chmod 0700 "$runtime"
cp "$fixture/shell.qml" "$config/shell.qml"
ln -s "$ROOT/shell/services" "$config/services"
ln -s "$ROOT/shell/Commons" "$config/Commons"

raw=$(jq -nS --arg plugin "$plugin" '
  {version:1,bar:{layout:{left:[],center:[],right:[]}},plugins:[{id:$plugin}],unrelated:{value:7}}')
raw_base64=$(printf '%s\n' "$raw" | base64 -w0)
OMARCHY_QML_TEST_RESULT="$result" \
OMARCHY_OBSERVATION_PLUGIN="$plugin" \
OMARCHY_OBSERVATION_RAW_BASE64="$raw_base64" \
HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_CACHE_HOME="$home/.cache" \
XDG_STATE_HOME="$home/.local/state" XDG_RUNTIME_DIR="$runtime" \
QT_QPA_PLATFORM=offscreen \
QML2_IMPORT_PATH="$ROOT/shell${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}" \
QML_IMPORT_PATH="$ROOT/shell${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}" \
  quickshell -p "$config" --no-color >"$log" 2>&1 &
QS_PID=$!

for _ in {1..100}; do
  [[ -s $result ]] && break
  kill -0 "$QS_PID" 2>/dev/null || {
    sed -n '1,160p' "$log" >&2
    fail "O-7 observation fixture remained alive"
  }
  sleep 0.02
done
[[ -s $result ]] || {
  sed -n '1,160p' "$log" >&2
  fail "O-7 observation fixture produced a result"
}

jq -e --arg plugin "$plugin" '
  .valid == true and .schema == "omarchy-plugin-stage-observation/v1"
  and .pluginId == $plugin and .configurationSource == {
    kind:"user",identity:"omarchy-shell-config:user:v1"}
  and .referenceState == "referenced"
' "$result" >/dev/null
[[ $(jq -r .rawBase64 "$result" | base64 -d) == "$raw" ]]

expected_projection=$(ROOT="$ROOT" RAW="$raw" PLUGIN="$plugin" mise exec -- node <<'JS'
const fs = require('fs')
const vm = require('vm')
const source = fs.readFileSync(process.env.ROOT + '/shell/services/PluginReferenceProjection.js', 'utf8')
  .replace(/^\.pragma library\n/, '')
const scope = {}
vm.runInNewContext(source + '\nthis.api={canonicalBytes,base64};', scope)
process.stdout.write(scope.api.base64(scope.api.canonicalBytes(JSON.parse(process.env.RAW), process.env.PLUGIN)))
JS
)
[[ $(jq -r .referenceProjectionBase64 "$result") == "$expected_projection" ]]
pass "O-7 observation is emitted from one copied O-6 accepted snapshot"
pass "O-7 observation reuses the canonical reference projection producer"

grep -F 'function transactionStageObservation(pluginId: string): string' "$ROOT/shell/shell.qml" >/dev/null ||
  fail "production shell exposes the narrow transaction observation IPC"
pass "production shell exposes only the plugin-scoped observation seam"
