#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command node

ROOT="$ROOT" node <<'JS'
const fs = require('fs')
const path = require('path')
const root = process.env.ROOT
const shell = fs.readFileSync(path.join(root, 'shell/shell.qml'), 'utf8')
const bar = fs.readFileSync(path.join(root, 'shell/plugins/bar/Bar.qml'), 'utf8')

function assert(condition, message) {
  if (!condition) throw new Error(message)
}

// These are executable third-party URL consumers, not comments: changing or
// adding an entryPointUrl call changes this exact call-site inventory.
const calls = [...shell.matchAll(/pluginRegistry\.entryPointUrl\(([^\n]+)\)/g)]
  .map(match => match[1].trim())
assert(calls.length === 7, `expected seven guarded entryPointUrl calls, found ${calls.length}`)
assert(calls.includes('activeBarManifest, "bar"'), 'selected bar URL is inventoried')
assert(calls.includes('manifest, "service"'), 'service component URL is inventoried')
assert(calls.includes('manifest, entryKind'), 'panel/overlay/menu URL is inventoried')
assert(calls.includes('manifest, "barWidget"'), 'bar-widget component URL is inventoried')
assert(calls.filter(call => call.indexOf('manifest, "service"') === 0).length === 2,
  'service creation and asynchronous completion both resolve centrally')
assert(calls.filter(call => call.indexOf('"barWidget"') !== -1).length === 2,
  'bar-widget creation and asynchronous completion both resolve centrally')

assert(/id: pluginBarLoader[\s\S]{0,260}?source: shell\.activeBarId[^\n]*shell\.activeBarSourceUrl/.test(shell),
  'selected third-party bar source assignment is inventoried')
assert(/var comp = Qt\.createComponent\(url, Component\.PreferSynchronous\)/.test(shell),
  'service dynamic component creation is inventoried')
assert(/id: panelEntry[\s\S]{0,500}?source: panelEntry\.sourceUrl/.test(shell),
  'panel/overlay/menu source assignment is inventoried')
assert(/var comp = Qt\.createComponent\(url, Component\.Asynchronous\)/.test(shell),
  'bar-widget dynamic component creation is inventoried')
assert(/id: registryLoader[\s\S]{0,180}?sourceComponent: slot\.registered \? slot\.registryComponent : null/.test(bar),
  'bar slot component instantiation is inventoried')

assert(/property var _pendingServices/.test(shell)
  && /owner\.token !== token \|\| owner\.component !== comp/.test(shell),
  'service completion requires ownership of its recorded pending component')
assert(/pendingWidget\.component\.destroy\(\)/.test(shell)
  && /owner\.loadToken !== token \|\| owner\.component !== comp/.test(shell),
  'bar-widget unload invalidates its component and stale completion token')
assert(/pluginBarLoader\.status === Loader\.Loading/.test(shell),
  'selected-bar Loading state blocks unload acknowledgement')
assert(/barHostRetainsPlugin\(key\)/.test(shell)
  && /registryLoader\.status === Loader\.Loading/.test(bar),
  'per-screen retained or Loading widget loaders block acknowledgement')

function lifecycleGuardsPresent(shellText, barText) {
  return /owner\.token !== token \|\| owner\.component !== comp/.test(shellText)
    && /owner\.loadToken !== token \|\| owner\.component !== comp/.test(shellText)
    && /barHostRetainsPlugin\(key\)/.test(shellText)
    && /registryLoader\.status === Loader\.Loading/.test(barText)
}

assert(lifecycleGuardsPresent(shell, bar), 'complete lifecycle guard is accepted')
assert(!lifecycleGuardsPresent(shell.replace('owner.token !== token || owner.component !== comp', 'false'), bar),
  'negative control detects omitted service token ownership')
assert(!lifecycleGuardsPresent(shell.replace('owner.loadToken !== token || owner.component !== comp', 'false'), bar),
  'negative control detects stale widget completion permission')
assert(!lifecycleGuardsPresent(shell.replace('&& !barHostRetainsPlugin(key)', ''), bar),
  'negative control detects omitted per-screen retention')
JS

pass "third-party loader creation sites match the O-6 inventory"
