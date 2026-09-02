#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
require_command node

ROOT="$ROOT" mise exec -- node <<'JS'
const crypto = require('crypto')
const fs = require('fs')
const vm = require('vm')
const source = fs.readFileSync(process.env.ROOT + '/shell/services/PluginReferenceProjection.js', 'utf8')
  .replace(/^\.pragma library\n/, '')
const api = {}
vm.runInNewContext(source + '\nthis.api={references,canonicalBytes,base64};', api)

function assert(value, message) { if (!value) throw new Error(message) }
function digest(bytes) { return 'sha256:' + crypto.createHash('sha256').update(Buffer.from(bytes)).digest('hex') }

const empty = {version:1,bar:{layout:{left:[],center:[],right:[]}},plugins:[]}
assert(digest(api.api.canonicalBytes(empty, 'acme.plugin')) === 'sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432', 'fixed empty vector')
const selected = {version:1,bar:{id:'acme.plugin',layout:{left:[],center:[],right:[]}},plugins:[]}
assert(digest(api.api.canonicalBytes(selected, 'acme.plugin')) === 'sha256:17d0f33536e3b617c33e7e88d96e487c776746306e9f7f7cf4ee9796dc5e9279', 'fixed selected-bar vector')
const multiple = {version:1,bar:{layout:{left:[{id:'acme.plugin'}],center:[],right:[{id:'other'},{id:'acme.plugin'}]}},plugins:[{id:'acme.plugin'}]}
assert(digest(api.api.canonicalBytes(multiple, 'acme.plugin')) === 'sha256:82549b7aba6ab07f74126e0a0a7f2c7ee942ce7b9879ca1c54b8d3add9e8524f', 'fixed multi-kind vector')
assert(api.api.references(multiple, 'acme.plugin').length === 3, 'all locations retained')
const duplicate = {version:1,bar:{layout:{left:[{id:'acme.plugin'},{id:'acme.plugin'}],center:[],right:[]}},plugins:[]}
assert(api.api.references(duplicate, 'acme.plugin').length === 2, 'duplicate logical references retained')
const unrelated = JSON.parse(JSON.stringify(multiple)); unrelated.theme = {color:'red'}
assert(digest(api.api.canonicalBytes(unrelated, 'acme.plugin')) === digest(api.api.canonicalBytes(multiple, 'acme.plugin')), 'unrelated setting excluded')
const moved = JSON.parse(JSON.stringify(multiple)); moved.bar.layout.left.unshift({id:'other'})
assert(digest(api.api.canonicalBytes(moved, 'acme.plugin')) !== digest(api.api.canonicalBytes(multiple, 'acme.plugin')), 'moving a reference changes location')
assert(api.api.canonicalBytes(null, 'acme.plugin') === null, 'malformed snapshot is not an empty projection')
JS

eligibility=$(<"$ROOT/shell/services/PluginEligibility.qml")
[[ $(grep -c '!releaseBindingCurrent(' <<<"$eligibility") == 3 ]] ||
  fail "release rechecks the complete binding before and after asynchronous phases"
[[ $(grep -c 'Number(registryGenerationProvider()) === Number(command.generation)' <<<"$eligibility") == 1 ]] ||
  fail "the shared release binding compares current registry generation"
grep -F 'Number(registryGenerationProvider()) !== Number(gateRecord.generation)' <<<"$eligibility" >/dev/null ||
  fail "release rejects a stale gated-rescan generation before projection"

without_generation=${eligibility//Number(registryGenerationProvider()) !== Number(command.generation)/false}
[[ $(grep -c 'registryGenerationProvider()) !== Number(command.generation)' <<<"$without_generation" || true) == 0 ]] ||
  fail "generation negative control removes the release guard"

pass "release remains bound to the current registry generation"

pass "schema-v1 reference projection matches independent fixed vectors"
