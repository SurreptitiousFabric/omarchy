import QtQuick
import Quickshell
import "services"

ShellRoot {
  id: root

  PluginEligibility { id: authority }

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  Component.onCompleted: {
    var raw = Qt.atob(Quickshell.env("OMARCHY_OBSERVATION_RAW_BASE64"))
    var config = JSON.parse(raw)
    var pluginId = Quickshell.env("OMARCHY_OBSERVATION_PLUGIN")
    var before = authority.stageObservation(pluginId)
    var observation
    if (before.valid || before.status !== "invalid-accepted-configuration") {
      observation = { valid: false, status: "initial-snapshot-was-accepted" }
    } else {
      authority.acceptSnapshot(config, "user", "omarchy-shell-config:user:v1", raw)
      config.plugins = []
      observation = authority.stageObservation(pluginId)
    }
    var result = JSON.stringify(observation)
    Quickshell.execDetached(["bash", "-c", "printf '%s' " + shellQuote(result)
      + " > " + shellQuote(Quickshell.env("OMARCHY_QML_TEST_RESULT"))])
  }
}
