import QtQuick
import Quickshell
import Quickshell.Io

Item {
  readonly property string markerPath: Quickshell.env("OMARCHY_PLUGIN_RACE_MARKER")

  Process {
    id: markerProcess
    command: [
      "bash",
      "-c",
      "if [[ -n $0 ]]; then printf '%s\\n' candidate-v2 >> \"$0\"; fi",
      markerPath
    ]
  }

  Component.onCompleted: markerProcess.running = true
}
