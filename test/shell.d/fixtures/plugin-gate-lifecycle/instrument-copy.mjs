import fs from 'node:fs'
import nodePath from 'node:path'

const path = process.argv[2]
if (!path) throw new Error('usage: instrument-copy.mjs SHELL_QML')
let source = fs.readFileSync(path, 'utf8')
const forgetScreenLoaders = process.env.OMARCHY_LIFECYCLE_FORGET_SCREEN_LOADERS === '1'
const duplicateScreenLoader = process.env.OMARCHY_LIFECYCLE_DUPLICATE_SCREEN_LOADER === '1'

if (process.env.OMARCHY_LIFECYCLE_DISABLE_GENERATION_GUARDS === '1') {
  const authorityPath = nodePath.join(nodePath.dirname(path), 'services', 'PluginEligibility.qml')
  let authority = fs.readFileSync(authorityPath, 'utf8')
  function replaceAuthorityOnce(anchor, replacement, name) {
    const first = authority.indexOf(anchor)
    if (first < 0 || authority.indexOf(anchor, first + anchor.length) >= 0)
      throw new Error(`authority anchor must occur exactly once: ${name}`)
    authority = authority.slice(0, first) + replacement + authority.slice(first + anchor.length)
  }
  replaceAuthorityOnce(
    `    if (!registryGenerationProvider || Number(registryGenerationProvider()) !== Number(gateRecord.generation)) {
      setResult(operationId, pluginId, "release-retained", "stale rescan generation")
      return "stale-rescan-generation"
    }
`,
    '',
    'initial current generation guard')
  replaceAuthorityOnce(
    `      && registryGenerationProvider
      && Number(registryGenerationProvider()) === Number(command.generation)
`,
    '',
    'continued current generation guard')
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

  function testEvent(value) {
    var next = testEvents.slice()
    next.push(String(value))
    testEvents = next
  }
`,
  'service state')

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
        registryGeneration: shell.pluginRegistry.registryGeneration,
        configurationEpoch: shell.pluginEligibility.configurationEpoch,
        shellInstance: shell.pluginEligibility.shellInstanceId,
        inventoryReady: shell.pluginEligibility.inventoryReady,
        gate: shell.pluginEligibility.gates[key] || null,
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
      shell.shellConfig = next
      shell.pluginEligibility.acceptSnapshot(next, shell.pluginEligibility.acceptedSourceKind,
        shell.pluginEligibility.acceptedSourceIdentity, JSON.stringify(next))
      shell.pluginRegistry.registryRevision++
      shell.pluginRegistry.pluginsChanged()
      return "ok"
    }

    function testOrdinaryRescan(): string {
      return shell.pluginRegistry.rescan() ? "started" : "busy"
    }

    function testBumpConfigurationEpoch(): string {
      shell.pluginEligibility.acceptSnapshot(shell.pluginEligibility.acceptedConfig,
        shell.pluginEligibility.acceptedSourceKind, shell.pluginEligibility.acceptedSourceIdentity,
        shell.pluginEligibility.acceptedRawText)
      return String(shell.pluginEligibility.configurationEpoch)
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
