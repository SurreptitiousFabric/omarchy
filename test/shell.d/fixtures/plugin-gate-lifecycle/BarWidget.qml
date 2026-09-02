import QtQuick
import Quickshell
import Quickshell.Io

Item {
  implicitWidth: 20
  implicitHeight: 20
  Component.onCompleted: Quickshell.execDetached(["bash", "-lc", "printf created >> \"$OMARCHY_GATE_LIFECYCLE_MARKER.widget\""])
  Component.onDestruction: Quickshell.execDetached(["bash", "-lc", "printf destroyed >> \"$OMARCHY_GATE_LIFECYCLE_MARKER.widget\""])

  IpcHandler {
    target: "acme.lifecycle_fixture/1"
    function ping(): string { return "ok" }
  }
}
