import QtQuick
import Quickshell
import "services"

ShellRoot {
  id: root

  readonly property string resultPath: Quickshell.env("OMARCHY_QML_TEST_RESULT")
  readonly property string expectedPlugin: Quickshell.env("OMARCHY_REGISTRY_EXPECTED_PLUGIN")
  readonly property string expectedSource: Quickshell.env("OMARCHY_REGISTRY_EXPECTED_SOURCE")
  property int completedScans: 0

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function writeResult() {
    var manifest = registry.installedPlugins[expectedPlugin]
    var hasOutcome = "lastScanOutcome" in registry
    var outcome = hasOutcome ? registry.lastScanOutcome : null
    var hasBinding = "gatedScanBinding" in registry
    var binding = hasBinding
      ? registry.gatedScanBinding("73000000-0000-4000-8000-000000000001",
          expectedPlugin, expectedSource, outcome)
      : null
    var payload = JSON.stringify({
      selected: manifest !== undefined,
      selectedSource: manifest ? String(manifest.__sourceDir || "") : "",
      entryPointUrl: manifest ? registry.entryPointUrl(manifest, "service") : "",
      scanSuccessful: outcome ? outcome.success : null,
      scanStatus: outcome ? outcome.status : "legacy-no-outcome",
      exitCode: outcome ? outcome.exitCode : null,
      sources: outcome && outcome.thirdPartySources
        ? (outcome.thirdPartySources[expectedPlugin] || []) : [],
      invalidSources: outcome && outcome.invalidThirdPartySources
        ? outcome.invalidThirdPartySources : [],
      binding: binding,
      generation: registry.registryGeneration,
      scanEpoch: ("scanEpoch" in registry) ? registry.scanEpoch : null
    })
    Quickshell.execDetached(["bash", "-c",
      "printf '%s' " + shellQuote(payload) + " > " + shellQuote(resultPath)])
  }

  PluginRegistry {
    id: registry
    firstPartyDir: Quickshell.env("OMARCHY_REGISTRY_FIRST_PARTY")
    pluginsDir: Quickshell.env("OMARCHY_REGISTRY_PLUGIN_DIR")
    shellConfigProvider: function() { return ({ version: 1, plugins: [] }) }
    shellConfigMutator: function(mutate) { return true }
  }

  Connections {
    target: registry
    function onScanFinished(context, generation) {
      root.completedScans++
      if (root.completedScans === 1) {
        registry.rescan({
          gated: true,
          operationId: "73000000-0000-4000-8000-000000000001",
          pluginId: root.expectedPlugin
        })
      } else {
        root.writeResult()
      }
    }
  }
}
