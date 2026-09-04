import fs from 'node:fs'
import nodePath from 'node:path'

const path = process.argv[2]
if (!path) throw new Error('usage: instrument-copy.mjs SHELL_QML')
let source = fs.readFileSync(path, 'utf8')
const forgetScreenLoaders = process.env.OMARCHY_LIFECYCLE_FORGET_SCREEN_LOADERS === '1'
const duplicateScreenLoader = process.env.OMARCHY_LIFECYCLE_DUPLICATE_SCREEN_LOADER === '1'
const breakTerminalHandoff = process.env.OMARCHY_LIFECYCLE_BREAK_TERMINAL_HANDOFF === '1'

const registryPath = nodePath.join(nodePath.dirname(path), 'services', 'PluginRegistry.qml')
let registrySource = fs.readFileSync(registryPath, 'utf8')

function replaceRegistryOnce(anchor, replacement, name) {
  const first = registrySource.indexOf(anchor)
  if (first < 0 || registrySource.indexOf(anchor, first + anchor.length) >= 0)
    throw new Error(`registry anchor must occur exactly once: ${name}`)
  registrySource = registrySource.slice(0, first) + replacement
    + registrySource.slice(first + anchor.length)
}

const correctedScanAnchor = '    var script = "set -euo pipefail; shopt -s nullglob; "\n'
const reviewedScanAnchor = '    var script = ""\n'
const scanBarrier = 'if [[ -e "${OMARCHY_LIFECYCLE_HOLD_SCAN:-}" ]]; then '
  + ': >"$OMARCHY_LIFECYCLE_SCAN_READY"; read -r _ <"$OMARCHY_LIFECYCLE_SCAN_RESUME"; fi; '
if (registrySource.includes(correctedScanAnchor)) {
  replaceRegistryOnce(correctedScanAnchor,
    '    var script = "' + scanBarrier.replaceAll('\\', '\\\\').replaceAll('"', '\\"')
      + 'set -euo pipefail; shopt -s nullglob; "\n',
    'corrected scanner barrier')
} else {
  replaceRegistryOnce(reviewedScanAnchor,
    '    var script = "' + scanBarrier.replaceAll('\\', '\\\\').replaceAll('"', '\\"') + '"\n',
    'reviewed scanner barrier')
}
replaceRegistryOnce(
  '  function ensureUserDir() {\n',
  `  function testSetLocalWatcherRunning(value) {
    localPluginWatcher.running = value === true
  }

  function testLocalWatcherRunning() {
    return localPluginWatcher.running
  }

  function ensureUserDir() {
`,
  'test-copy watcher control')
replaceRegistryOnce(
  '  property Process localPluginWatcher: Process {\n',
  '  property bool testWatcherDisabled: false\n\n  property Process localPluginWatcher: Process {\n',
  'test-copy persistent watcher control')
replaceRegistryOnce(
  '    onExited: localPluginWatcherRestart.restart()\n',
  '    onExited: if (!registry.testWatcherDisabled) localPluginWatcherRestart.restart()\n',
  'test-copy watcher restart guard')
fs.writeFileSync(registryPath, registrySource)

if (process.env.OMARCHY_LIFECYCLE_DISABLE_GENERATION_GUARDS === '1') {
  const authorityPath = nodePath.join(nodePath.dirname(path), 'services', 'PluginEligibility.qml')
  let authority = fs.readFileSync(authorityPath, 'utf8')
  function replaceAuthorityOnce(anchor, replacement, name) {
    const first = authority.indexOf(anchor)
    if (first < 0 || authority.indexOf(anchor, first + anchor.length) >= 0)
      throw new Error(`authority anchor must occur exactly once: ${name}`)
    authority = authority.slice(0, first) + replacement + authority.slice(first + anchor.length)
  }
  const reviewedInitialGuard = `    if (!registryGenerationProvider || Number(registryGenerationProvider()) !== Number(gateRecord.generation)) {
      setResult(operationId, pluginId, "release-retained", "stale rescan generation")
      return "stale-rescan-generation"
    }
`
  if (authority.includes(reviewedInitialGuard)) {
    replaceAuthorityOnce(reviewedInitialGuard, '', 'initial current generation guard')
    replaceAuthorityOnce(
      `      && registryGenerationProvider
      && Number(registryGenerationProvider()) === Number(command.generation)
`,
      '',
      'continued current generation guard')
  } else {
    replaceAuthorityOnce(
      `    return current && current.scanning !== true && current.scanSuccessful === true
      && current.unique === true
      && Number(current.generation) === Number(generation)
      && Number(current.scanEpoch) === Number(scanEpoch)
      && String(current.sourceDirectory || "") === String(sourceDirectory || "")
`,
      `    return current && current.scanSuccessful === true
      && current.unique === true
      && String(current.sourceDirectory || "") === String(sourceDirectory || "")
`,
      'central current scan authority guard')
  }
  fs.writeFileSync(authorityPath, authority)
}

if (breakTerminalHandoff) {
  const authorityPath = nodePath.join(nodePath.dirname(path), 'services', 'PluginEligibility.qml')
  let authority = fs.readFileSync(authorityPath, 'utf8')
  function replaceBrokenOnce(anchor, replacement, name) {
    const first = authority.indexOf(anchor)
    if (first < 0 || authority.indexOf(anchor, first + anchor.length) >= 0)
      throw new Error(`authority anchor must occur exactly once: ${name}`)
    authority = authority.slice(0, first) + replacement + authority.slice(first + anchor.length)
  }
  replaceBrokenOnce('          beginTerminalHandoff(command, authorizedGate, "COMMITTED")',
    '          terminalReceipt(command.operationId, command.pluginId, "COMMITTED")',
    'candidate terminal handoff negative control')
  replaceBrokenOnce('        beginTerminalHandoff(command, rollbackAuthorizedGate, "ROLLED_BACK")',
    '        terminalReceipt(command.operationId, command.pluginId, "ROLLED_BACK")',
    'rollback terminal handoff negative control')
  fs.writeFileSync(authorityPath, authority)
}

function replaceOnce(anchor, replacement, name) {
  const first = source.indexOf(anchor)
  if (first < 0 || source.indexOf(anchor, first + anchor.length) >= 0)
    throw new Error(`instrumentation anchor must occur exactly once: ${name}`)
  source = source.slice(0, first) + replacement + source.slice(first + anchor.length)
}

if (process.env.OMARCHY_LIFECYCLE_DISABLE_TOKEN_GUARDS === '1') {
  replaceOnce(
    `      var owner = _pendingServices[key]
      if (!owner || owner.token !== token || owner.component !== comp) {
        if (typeof comp.destroy === "function") comp.destroy()
        return
      }
`,
    `      var owner = _pendingServices[key]
`,
    'service token negative control')
  replaceOnce(
    `      var owner = pluginWidgetComponents[registryKey]
      if (!owner || owner.loadToken !== token || owner.component !== comp) {
        if (typeof comp.destroy === "function") comp.destroy()
        return
      }
`,
    `      var owner = pluginWidgetComponents[registryKey]
`,
    'widget token negative control')
  replaceOnce(
    '    if (pendingService && pendingService.component && typeof pendingService.component.destroy === "function") pendingService.component.destroy()\n',
    '    // Negative control: forget the pending service Component.\n',
    'forgotten pending service negative control')
  replaceOnce(
    '    if (pendingWidget && pendingWidget.component && typeof pendingWidget.component.destroy === "function") pendingWidget.component.destroy()\n',
    '    // Negative control: forget the pending widget Component.\n',
    'forgotten pending widget negative control')
}

replaceOnce(
  '  property var _services: ({})\n',
  `  property var _services: ({})
  // Test-copy-only lifecycle barriers. This file is patched only after shell/
  // has been copied beneath the test's temporary root.
  property bool testHoldUnload: true
  property var testAllowedServiceCallback: null
  property var testAllowedWidgetCallback: null
  property var testDeferredServices: ({})
  property var testDeferredWidgets: ({})
  property var testEvents: []
  property string testSelectedBarOperation: ""
  property string testSelectedBarPlugin: ""
  property bool testGateOnSelectedBarLoading: false
  property bool testSelectedBarSawLoading: false
  property bool testSelectedBarGateRequested: false
  property bool testSplitSnapshotObserved: false
  property int testSplitSnapshotEpoch: -1

  function testEvent(value) {
    var next = testEvents.slice()
    next.push(String(value))
    testEvents = next
  }
`,
  'service state')

const vulnerableConfigAnchor = '    shellConfig = payload\n'
if (source.includes(vulnerableConfigAnchor)) {
  replaceOnce(
    vulnerableConfigAnchor,
    `    shellConfig = payload
    if (JSON.stringify(shellConfig) !== JSON.stringify(pluginEligibility.acceptedConfig)) {
      testSplitSnapshotObserved = true
      testSplitSnapshotEpoch = pluginEligibility.configurationEpoch
    }
`,
    'vulnerable programmatic configuration publication observation')
} else {
  const atomicConfigAnchor = `    configWriteOutcome = "idle"
    publishAcceptedShellConfig(payload, "user", shell.userConfigSourceIdentity, raw)
    return true
`
  const first = source.indexOf(atomicConfigAnchor)
  if (first < 0 || source.indexOf(atomicConfigAnchor, first + atomicConfigAnchor.length) >= 0)
    throw new Error('atomic configuration publication anchor must occur exactly once')
}

replaceOnce(
  '  // ------------------------------------------------------------- services\n',
  `  Connections {
    target: pluginBarLoader
    function onStatusChanged() {
      if (pluginBarLoader.status !== Loader.Loading || !testGateOnSelectedBarLoading) return
      testGateOnSelectedBarLoading = false
      testSelectedBarSawLoading = true
      testSelectedBarGateRequested = pluginEligibility.gatePlugin(testSelectedBarOperation, testSelectedBarPlugin) === "pending"
      testEvent("selected-bar-loading-gate:" + testSelectedBarPlugin)
    }
  }

  // ------------------------------------------------------------- services
`,
  'selected bar loading observer')

replaceOnce(
  '  function unloadExactPlugin(pluginId) {\n    var key = String(pluginId)\n',
  `  function unloadExactPlugin(pluginId) {
    var key = String(pluginId)
    if (testHoldUnload) {
      testEvent("unload-held:" + key)
      return
    }
`,
  'unload barrier')

const finalizeAnchor = '    function finalize() {\n'
let firstFinalize = source.indexOf(finalizeAnchor)
let secondFinalize = source.indexOf(finalizeAnchor, firstFinalize + finalizeAnchor.length)
if (firstFinalize < 0 || secondFinalize < 0 || source.indexOf(finalizeAnchor, secondFinalize + finalizeAnchor.length) >= 0)
  throw new Error('expected exactly two plugin completion closures')

const serviceInsert = `    function finalize() {
      if (testAllowedServiceCallback !== finalize) {
        var deferredService = ({})
        for (var deferredServiceId in testDeferredServices) deferredService[deferredServiceId] = testDeferredServices[deferredServiceId]
        var serviceCallbacks = deferredService[key] ? deferredService[key].slice() : []
        if (serviceCallbacks.indexOf(finalize) === -1) serviceCallbacks.push(finalize)
        deferredService[key] = serviceCallbacks
        testDeferredServices = deferredService
        testEvent("service-deferred:" + key)
        return
      }
      testAllowedServiceCallback = null
      testEvent("service-finalize:" + key)
`
source = source.slice(0, firstFinalize) + serviceInsert + source.slice(firstFinalize + finalizeAnchor.length)

secondFinalize = source.indexOf(finalizeAnchor, firstFinalize + serviceInsert.length)
const widgetInsert = `    function finalize() {
      if (testAllowedWidgetCallback !== finalize) {
        var deferredWidget = ({})
        for (var deferredWidgetId in testDeferredWidgets) deferredWidget[deferredWidgetId] = testDeferredWidgets[deferredWidgetId]
        var widgetCallbacks = deferredWidget[registryKey] ? deferredWidget[registryKey].slice() : []
        if (widgetCallbacks.indexOf(finalize) === -1) widgetCallbacks.push(finalize)
        deferredWidget[registryKey] = widgetCallbacks
        testDeferredWidgets = deferredWidget
        testEvent("widget-deferred:" + registryKey)
        return
      }
      testEvent("widget-finalize:" + registryKey)
`
source = source.slice(0, secondFinalize) + widgetInsert + source.slice(secondFinalize + finalizeAnchor.length)

replaceOnce(
  '  // --------------------------------------------------- image selector IPC\n',
  `  function testRegistryComponent(pluginId) {
    var value = barWidgetRegistry.widgets[String(pluginId)]
    return value && value.component !== undefined ? value.component : (value || null)
  }
  readonly property var testWidgetComponent: testRegistryComponent("acme.lifecycle-widget")
  readonly property var testActiveWidgetComponent: testRegistryComponent("acme.lifecycle-active-widget")
  property bool testKeepActiveScreenComponent: ${forgetScreenLoaders ? 'true' : 'false'}
  property var testHeldActiveWidgetComponent: null
  onTestActiveWidgetComponentChanged: if (testActiveWidgetComponent !== null) testHeldActiveWidgetComponent = testActiveWidgetComponent
  readonly property var testEffectiveActiveWidgetComponent: testActiveWidgetComponent !== null
    ? testActiveWidgetComponent : (testKeepActiveScreenComponent ? testHeldActiveWidgetComponent : null)
  function testScreenItems(pluginId) {
    if (String(pluginId) === "acme.lifecycle-active-widget")
      return (testActiveScreenOne.item !== null ? 1 : 0) + (testActiveScreenTwo.item !== null ? 1 : 0)
    return (testScreenOne.item !== null ? 1 : 0) + (testScreenTwo.item !== null ? 1 : 0)
      + (${duplicateScreenLoader ? 'testScreenDuplicate.item !== null ? 1 : 0' : '0'})
  }
  function testScreenLoading(pluginId) {
    if (String(pluginId) === "acme.lifecycle-active-widget")
      return (testActiveScreenOne.status === Loader.Loading ? 1 : 0) + (testActiveScreenTwo.status === Loader.Loading ? 1 : 0)
    return (testScreenOne.status === Loader.Loading ? 1 : 0) + (testScreenTwo.status === Loader.Loading ? 1 : 0)
  }
  QtObject {
    id: testBarHost
    function retainsPluginWidget(pluginId) {
      if (${forgetScreenLoaders ? 'true' : 'false'} && String(pluginId) === "acme.lifecycle-active-widget") return false
      return shell.testScreenItems(pluginId) > 0 || shell.testScreenLoading(pluginId) > 0
    }
    Component.onCompleted: shell.registerBarHost(testBarHost)
    Component.onDestruction: shell.unregisterBarHost(testBarHost)
  }
  Loader {
    id: testScreenOne
    active: shell.testWidgetComponent !== null
    sourceComponent: shell.testWidgetComponent
    onItemChanged: shell.notifyPluginLifecycleChanged("acme.lifecycle-widget")
    onStatusChanged: shell.notifyPluginLifecycleChanged("acme.lifecycle-widget")
  }
  Loader {
    id: testScreenTwo
    active: shell.testWidgetComponent !== null
    sourceComponent: shell.testWidgetComponent
    onItemChanged: shell.notifyPluginLifecycleChanged("acme.lifecycle-widget")
    onStatusChanged: shell.notifyPluginLifecycleChanged("acme.lifecycle-widget")
  }
  Loader {
    id: testScreenDuplicate
    active: ${duplicateScreenLoader ? 'shell.testWidgetComponent !== null' : 'false'}
    sourceComponent: ${duplicateScreenLoader ? 'shell.testWidgetComponent' : 'null'}
    onItemChanged: shell.notifyPluginLifecycleChanged("acme.lifecycle-widget")
    onStatusChanged: shell.notifyPluginLifecycleChanged("acme.lifecycle-widget")
  }
  Loader {
    id: testActiveScreenOne
    active: shell.testEffectiveActiveWidgetComponent !== null
    sourceComponent: shell.testEffectiveActiveWidgetComponent
    onItemChanged: shell.notifyPluginLifecycleChanged("acme.lifecycle-active-widget")
    onStatusChanged: shell.notifyPluginLifecycleChanged("acme.lifecycle-active-widget")
  }
  Loader {
    id: testActiveScreenTwo
    active: shell.testEffectiveActiveWidgetComponent !== null
    sourceComponent: shell.testEffectiveActiveWidgetComponent
    onItemChanged: shell.notifyPluginLifecycleChanged("acme.lifecycle-active-widget")
    onStatusChanged: shell.notifyPluginLifecycleChanged("acme.lifecycle-active-widget")
  }

  // --------------------------------------------------- image selector IPC
`,
  'test loader slots')

replaceOnce(
  `    Bar {
      omarchyPath: shell.omarchyPath
      barWidgetRegistry: shell.barWidgetRegistry
      barConfig: shell.barConfig
      shell: shell
      manifest: shell.barManifestFor(shell.defaultBarId)
    }
`,
  `    // The offscreen test platform has no PanelWindow backend. The test copy
    // keeps the real third-party Loader paths and substitutes only the visual
    // first-party bar surface.
    Item {}
`,
  'offscreen default bar surface')

replaceOnce(
  '  IpcHandler {\n    target: "shell"\n\n    function ping(): string {\n      return "ok"\n    }\n',
  `  IpcHandler {
    target: "shell"

    function testLifecycleState(pluginId: string): string {
      var key = String(pluginId)
      var pendingService = ("_pendingServices" in shell) && shell._pendingServices[key] !== undefined
      var widgetRecord = shell.pluginWidgetComponents[key]
      return JSON.stringify({
        pendingService: pendingService,
        serviceActive: shell._services[key] !== undefined,
        serviceOwnerActive: ("_serviceOwners" in shell) && shell._serviceOwners[key] !== undefined,
        pendingWidget: widgetRecord !== undefined && widgetRecord.pending === true,
        widgetRegistered: shell.barWidgetRegistry.has(key),
        barRetained: typeof shell.barHostRetainsPlugin === "function" && shell.barHostRetainsPlugin(key),
        selectedBarItem: pluginBarLoader.item !== null,
        selectedBarLoading: pluginBarLoader.status === Loader.Loading,
        selectedBarActive: pluginBarLoader.active,
        selectedBarSource: String(pluginBarLoader.source || ""),
        selectedBarRetainedPlugin: ("retainedPluginId" in pluginBarLoader) ? pluginBarLoader.retainedPluginId : "",
        selectedBarSawLoading: shell.testSelectedBarSawLoading,
        selectedBarGateRequested: shell.testSelectedBarGateRequested,
        screenItems: shell.testScreenItems(key),
        screenLoading: shell.testScreenLoading(key),
        registryScanning: shell.pluginRegistry.scanning,
        pluginWatcherRunning: shell.pluginRegistry.testLocalWatcherRunning(),
        registryGeneration: shell.pluginRegistry.registryGeneration,
        scanEpoch: ("scanEpoch" in shell.pluginRegistry) ? shell.pluginRegistry.scanEpoch : -1,
        configurationEpoch: shell.pluginEligibility.configurationEpoch,
        shellConfig: shell.shellConfig,
        acceptedConfig: shell.pluginEligibility.acceptedConfig,
        acceptedSourceKind: shell.pluginEligibility.acceptedSourceKind,
        acceptedSourceIdentity: shell.pluginEligibility.acceptedSourceIdentity,
        acceptedRawText: shell.pluginEligibility.acceptedRawText,
        fileRawText: userConfigFile.text(),
        splitSnapshotObserved: shell.testSplitSnapshotObserved,
        splitSnapshotEpoch: shell.testSplitSnapshotEpoch,
        shellInstance: shell.pluginEligibility.shellInstanceId,
        inventoryReady: shell.pluginEligibility.inventoryReady,
        gate: shell.pluginEligibility.gates[key] || null,
        directUrl: shell.pluginRegistry.installedPlugins[key]
          ? shell.pluginRegistry.entryPointUrl(shell.pluginRegistry.installedPlugins[key], "service") : "",
        results: shell.pluginEligibility.results,
        deferredService: shell.testDeferredServices[key] ? shell.testDeferredServices[key].length : 0,
        deferredWidget: shell.testDeferredWidgets[key] ? shell.testDeferredWidgets[key].length : 0,
        events: shell.testEvents
      })
    }

    function testReleaseUnload(pluginId: string): string {
      shell.testHoldUnload = false
      shell.unloadExactPlugin(pluginId)
      return "ok"
    }

    function testHoldNextUnload(): string {
      shell.testHoldUnload = true
      return "ok"
    }

    function testSelectBar(operationId: string, pluginId: string): string {
      shell.testSelectedBarOperation = String(operationId)
      shell.testSelectedBarPlugin = String(pluginId)
      shell.testGateOnSelectedBarLoading = true
      var next = JSON.parse(JSON.stringify(shell.shellConfig))
      if (!next.bar) next.bar = {}
      next.bar.id = String(pluginId)
      if (!shell.persistShellConfig(next)) return "configuration-write-failed"
      shell.pluginRegistry.registryRevision++
      shell.pluginRegistry.pluginsChanged()
      return "ok"
    }

    function testOrdinaryRescan(): string {
      return shell.pluginRegistry.rescan() ? "started" : "busy"
    }

    function testStopLocalPluginWatcher(): string {
      shell.pluginRegistry.testWatcherDisabled = true
      shell.pluginRegistry.localPluginWatcherRestart.stop()
      shell.pluginRegistry.testSetLocalWatcherRunning(false)
      return "stopping"
    }

    function testPersistConfigBase64(configBase64: string): string {
      try {
        var config = JSON.parse(Qt.atob(String(configBase64)))
        return shell.persistShellConfig(config) ? "ok" : "failed"
      } catch (error) {
        return "invalid"
      }
    }

    function testUnloadNow(pluginId: string): string {
      shell.unloadExactPlugin(pluginId)
      return "ok"
    }

    function testSyncWidgets(): string {
      shell.syncPluginWidgets()
      return "ok"
    }

    function testResumeDeferredService(pluginId: string, index: string): string {
      var callbacks = shell.testDeferredServices[String(pluginId)] || []
      var callback = callbacks[Number(index)]
      shell.testAllowedServiceCallback = callback
      if (callback) callback()
      return "ok"
    }

    function testResumeDeferredWidget(pluginId: string, index: string): string {
      var callbacks = shell.testDeferredWidgets[String(pluginId)] || []
      var callback = callbacks[Number(index)]
      shell.testAllowedWidgetCallback = callback
      if (callback) callback()
      return "ok"
    }

    function ping(): string {
      return "ok"
    }
`,
  'test IPC anchor')

fs.writeFileSync(path, source)
