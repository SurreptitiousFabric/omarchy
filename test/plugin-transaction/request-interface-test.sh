#!/bin/bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/interface-test-lib.sh"

ROOT=$(interface_test_root)
TEST_ROOT=$(mktemp -d)
trap 'find "$TEST_ROOT" -mindepth 1 -delete; rmdir "$TEST_ROOT"' EXIT
INSTALL_ROOT="$TEST_ROOT/install/share/omarchy"
HOME_DIR="$TEST_ROOT/home"
STATE_HOME="$TEST_ROOT/state"
COMMAND="$INSTALL_ROOT/bin/omarchy-plugin-transaction"
NATIVE="$INSTALL_ROOT/native/plugin-transaction/plugin-tree"
TOKEN=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
OPERATION=81000000-0000-4000-8000-000000000001
PLUGIN=acme.o7-parser
EMPTY_DIGEST=sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432

build_interface_install "$ROOT" "$INSTALL_ROOT"

invoke() {
  HOME="$HOME_DIR" XDG_STATE_HOME="$STATE_HOME" "$COMMAND"
}

expect_invalid() {
  local description=$1 input=$2 output status
  set +e
  output=$(printf '%s' "$input" | invoke 2>"$TEST_ROOT/error")
  status=$?
  set -e
  [[ $status == 2 ]]
  jq -e '.status == "invalid-request" or .status == "incompatible-request"' <<<"$output" >/dev/null
  [[ $output != *"$TOKEN"* ]]
  ! grep -qF "$TOKEN" "$TEST_ROOT/error"
  printf 'ok - %s\n' "$description"
}

capabilities='{"protocol":"legacy-schema-v1-transaction/v1","action":"capabilities"}'
before=$(find "$HOME_DIR" "$STATE_HOME" -print 2>/dev/null | sort || true)
capability_output=$(printf '%s' "$capabilities" | invoke)
after=$(find "$HOME_DIR" "$STATE_HOME" -print 2>/dev/null | sort || true)
expected_capabilities='{"actions":["capabilities","stage","status","abort","commit"],"capabilities":["legacy-schema-v1-transaction/v1"],"operations":["install","update"],"protocol":"legacy-schema-v1-transaction/v1","referencePolicies":["require-unreferenced","preserve-observed"],"treeIdentityAlgorithms":["omarchy-runtime-tree-sha256-v1"]}'
[[ $capability_output == "$expected_capabilities" ]]
[[ $before == "$after" ]]
minimal_capability_output=$(printf '%s' "$capabilities" |
  env -i PATH=/usr/bin:/bin "$COMMAND")
[[ $minimal_capability_output == "$expected_capabilities" ]]
printf 'ok - canonical capabilities are exact and side-effect free\n'

route_output=$(printf '%s' "$capabilities" |
  HOME="$HOME_DIR" XDG_STATE_HOME="$STATE_HOME" "$INSTALL_ROOT/bin/omarchy" plugin transaction)
[[ $route_output == "$expected_capabilities" ]]
printf 'ok - exact omarchy plugin transaction route dispatches the stdin protocol\n'

[[ $capability_output == *commit* && $capability_output != *recover* &&
   $capability_output != *activate* && $capability_output != *rollback* ]]
printf 'ok - capabilities advertise only implemented O-8 actions\n'

set +e
empty_output=$(invoke </dev/null 2>"$TEST_ROOT/empty.err")
empty_status=$?
set -e
[[ $empty_status == 2 ]]
jq -e '.reason == "malformed-request"' <<<"$empty_output" >/dev/null
printf 'ok - empty input is rejected\n'

set +e
oversized_output=$(head -c 65537 /dev/zero | tr '\0' ' ' | invoke 2>"$TEST_ROOT/oversized.err")
oversized_status=$?
set -e
[[ $oversized_status == 2 ]]
jq -e '.reason == "malformed-request"' <<<"$oversized_output" >/dev/null
printf 'ok - input larger than 64 KiB is rejected\n'

expect_invalid "malformed JSON is rejected" '{'
for non_object in '[]' 'null' '"value"' '1'; do
  expect_invalid "non-object input is rejected: $non_object" "$non_object"
done
set +e
multiple_output=$(printf '%s' '{} {}' | invoke 2>"$TEST_ROOT/multiple.err")
multiple_status=$?
trailing_output=$(printf '%s' '{}x' | invoke 2>"$TEST_ROOT/trailing.err")
trailing_status=$?
utf8_output=$(printf '{"protocol":"legacy-schema-v1-transaction/v1","action":"capabilities","x":"\377"}' | invoke 2>"$TEST_ROOT/utf8.err")
utf8_status=$?
nul_output=$(printf '{"protocol":"legacy-schema-v1-transaction/v1","action":"capabilities"}\0' | invoke 2>"$TEST_ROOT/nul.err")
nul_status=$?
set -e
[[ $multiple_status == 2 && $trailing_status == 2 && $utf8_status == 2 && $nul_status == 2 ]]
for output in "$multiple_output" "$trailing_output" "$utf8_output" "$nul_output"; do
  jq -e '.reason == "malformed-request"' <<<"$output" >/dev/null
done
printf 'ok - multiple values, trailing data, invalid UTF-8 and literal NUL are rejected\n'

set +e
duplicate_top=$(printf '%s' '{"protocol":"legacy-schema-v1-transaction/v1","action":"capabilities","\u0061ction":"status"}' | invoke 2>/dev/null)
duplicate_top_status=$?
duplicate_nested=$(printf '%s' '{"protocol":"legacy-schema-v1-transaction/v1","action":"stage","operationId":"81000000-0000-4000-8000-000000000001","operationToken":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","operation":"install","pluginId":"acme.o7-parser","source":{"kind":"directory","kind":"directory","path":"/tmp/source"},"candidateTree":{"algorithm":"omarchy-runtime-tree-sha256-v1","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"expectedActive":{"state":"absent"},"expectedConfiguration":{"source":{"kind":"user","identity":"omarchy-shell-config:user:v1"},"referenceProjectionSha256":"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432","referenceState":"unreferenced","referencePolicy":"require-unreferenced"}}' | invoke 2>/dev/null)
duplicate_nested_status=$?
set -e
[[ $duplicate_top_status == 2 && $duplicate_nested_status == 2 ]]
jq -e '.reason == "malformed-request"' <<<"$duplicate_top" >/dev/null
jq -e '.reason == "malformed-request"' <<<"$duplicate_nested" >/dev/null
printf 'ok - decoded-equivalent top-level and nested duplicate keys are rejected before jq\n'

if printf '%s' '{"a":1,"\u0061":2}' | "$NATIVE" json-request-check >/dev/null 2>&1; then
  printf 'not ok - production duplicate-key checker accepted a collision\n' >&2
  exit 1
fi
if printf '%s' '{"":1,"":2}' | "$NATIVE" json-request-check >/dev/null 2>&1; then
  printf 'not ok - production duplicate-key checker accepted empty duplicate keys\n' >&2
  exit 1
fi
OMARCHY_PLUGIN_TREE_TEST_ALLOW_DUPLICATE_KEYS=1 \
  "$NATIVE" json-request-check <<<'{"a":1,"\u0061":2}' >/dev/null
printf 'ok - duplicate-key negative control demonstrates the removed guard\n'

valid_stage=$(jq -cnS --arg token "$TOKEN" --arg operation "$OPERATION" --arg plugin "$PLUGIN" '
  {protocol:"legacy-schema-v1-transaction/v1",action:"stage",operationId:$operation,
   operationToken:$token,operation:"install",pluginId:$plugin,
   source:{kind:"directory",path:"/tmp/source"},
   candidateTree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
   expectedActive:{state:"absent"},
   expectedConfiguration:{source:{kind:"user",identity:"omarchy-shell-config:user:v1"},
     referenceProjectionSha256:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",
     referenceState:"unreferenced",referencePolicy:"require-unreferenced"}}')

expect_invalid "unknown top-level fields fail" "$(jq -c '.extra=true' <<<"$valid_stage")"
expect_invalid "unknown nested fields fail" "$(jq -c '.source.extra=true' <<<"$valid_stage")"

for mutation in \
  '.protocol=1' '.action=[]' '.operationId=7' '.operationToken=null' \
  '.operation=true' '.pluginId=9' '.source=[]' '.source.kind=1' \
  '.source.path=false' '.candidateTree=null' '.candidateTree.algorithm=[]' \
  '.candidateTree.digest=1' '.expectedActive=null' '.expectedActive.state=false' \
  '.expectedConfiguration=[]' '.expectedConfiguration.source=false' \
  '.expectedConfiguration.source.kind=[]' '.expectedConfiguration.source.identity=3' \
  '.expectedConfiguration.referenceProjectionSha256=false' \
  '.expectedConfiguration.referenceState=0' '.expectedConfiguration.referencePolicy=null'; do
  expect_invalid "wrong primitive type fails: $mutation" "$(jq -c "$mutation" <<<"$valid_stage")"
done

expect_invalid "unsupported protocol fails" "$(jq -c '.protocol="legacy-schema-v1-transaction/v2"' <<<"$valid_stage")"
expect_invalid "unsupported action fails" "$(jq -c '.action="recover"' <<<"$valid_stage")"
expect_invalid "non-v4 UUID fails" "$(jq -c '.operationId="81000000-0000-3000-8000-000000000001"' <<<"$valid_stage")"
expect_invalid "uppercase UUID fails" "$(jq -c '.operationId="81000000-0000-4000-8000-00000000000A"' <<<"$valid_stage")"
expect_invalid "reserved plugin ID fails" "$(jq -c '.pluginId="omarchy.parser"' <<<"$valid_stage")"
expect_invalid "double-dot plugin ID fails" "$(jq -c '.pluginId="acme..parser"' <<<"$valid_stage")"
long_plugin=$(head -c 129 /dev/zero | tr '\0' a)
expect_invalid "excessive plugin ID fails" "$(jq -c --arg plugin "$long_plugin" '.pluginId=$plugin' <<<"$valid_stage")"
expect_invalid "unsupported source kind fails" "$(jq -c '.source.kind="archive"' <<<"$valid_stage")"
expect_invalid "relative source path fails" "$(jq -c '.source.path="relative"' <<<"$valid_stage")"
expect_invalid "control-bearing source path fails" "$(jq -c '.source.path="/tmp/bad\npath"' <<<"$valid_stage")"
expect_invalid "escaped NUL source path fails" "$(jq -c '.source.path="/tmp/bad\u0000path"' <<<"$valid_stage")"
expect_invalid "non-normalized source path fails" "$(jq -c '.source.path="/tmp/../source"' <<<"$valid_stage")"
long_path=/$(head -c 4097 /dev/zero | tr '\0' x)
expect_invalid "excessive source path fails" "$(jq -c --arg path "$long_path" '.source.path=$path' <<<"$valid_stage")"
bounded_unresolvable_path=/$(head -c 4095 /dev/zero | tr '\0' x)
set +e
bounded_path_output=$(printf '%s' "$(jq -c --arg path "$bounded_unresolvable_path" \
  '.source.path=$path' <<<"$valid_stage")" | invoke 2>"$TEST_ROOT/bounded-path.err")
bounded_path_status=$?
set -e
[[ $bounded_path_status == 0 ]]
jq -e '.status == "rejected" and .reason == "invalid-source"' <<<"$bounded_path_output" >/dev/null
printf 'ok - a schema-valid but locally unresolvable bounded path keeps the JSON contract\n'
expect_invalid "unsupported tree algorithm fails" "$(jq -c '.candidateTree.algorithm="sha256"' <<<"$valid_stage")"
expect_invalid "uppercase digest fails" "$(jq -c '.candidateTree.digest="sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' <<<"$valid_stage")"
expect_invalid "short digest fails" "$(jq -c '.candidateTree.digest="sha256:aa"' <<<"$valid_stage")"
expect_invalid "malformed digest fails" "$(jq -c '.candidateTree.digest="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' <<<"$valid_stage")"
expect_invalid "unsupported configuration source kind fails" "$(jq -c '.expectedConfiguration.source.kind="path"' <<<"$valid_stage")"
long_identity=$(head -c 257 /dev/zero | tr '\0' x)
expect_invalid "excessive configuration identity fails" "$(jq -c --arg identity "$long_identity" '.expectedConfiguration.source.identity=$identity' <<<"$valid_stage")"
expect_invalid "noncanonical token fails" "$(jq -c '.operationToken="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="' <<<"$valid_stage")"
expect_invalid "short token fails" "$(jq -c '.operationToken="AAAA"' <<<"$valid_stage")"
long_token=$(head -c 172 /dev/zero | tr '\0' A)
expect_invalid "excessive token fails" "$(jq -c --arg token "$long_token" '.operationToken=$token' <<<"$valid_stage")"
expect_invalid "install cannot carry an active tree" "$(jq -c '.expectedActive.tree=.candidateTree' <<<"$valid_stage")"
expect_invalid "update requires a present active tree" "$(jq -c '.operation="update"' <<<"$valid_stage")"
expect_invalid "update requires an active tree object" "$(jq -c '.operation="update" | .expectedActive={state:"present",tree:null}' <<<"$valid_stage")"
expect_invalid "install cannot preserve observed references" "$(jq -c '.expectedConfiguration.referencePolicy="preserve-observed"' <<<"$valid_stage")"
expect_invalid "require-unreferenced rejects referenced state" "$(jq -c '.expectedConfiguration.referenceState="referenced"' <<<"$valid_stage")"
expect_invalid "require-unreferenced rejects nonempty projection" "$(jq -c '.expectedConfiguration.referenceProjectionSha256="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' <<<"$valid_stage")"

for field in safe trusted approved approvedSigner signer publisher scanner analysis consent permission verifiedSafe; do
  expect_invalid "trust field is rejected: $field" "$(jq -c --arg field "$field" '.[$field]=true' <<<"$valid_stage")"
done

output_file="$TEST_ROOT/output"
error_file="$TEST_ROOT/stderr"
printf '%s' "$capabilities" | invoke >"$output_file" 2>"$error_file"
cmp -s "$output_file" <(jq -cS . "$output_file")
[[ ! -s $error_file && $(tail -c 1 "$output_file" | od -An -tuC) =~ 10 ]]
! LC_ALL=C grep -P '\x1b' "$output_file" >/dev/null
printf 'ok - handled output is one canonical compact JSON object plus LF\n'
