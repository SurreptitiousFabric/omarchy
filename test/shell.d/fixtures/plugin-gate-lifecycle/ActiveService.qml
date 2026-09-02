import QtQuick
import Quickshell

Item {
  Component.onCompleted: Quickshell.execDetached(["bash", "-lc", "printf created >> \"$OMARCHY_GATE_LIFECYCLE_MARKER.active\""])
  Component.onDestruction: Quickshell.execDetached(["bash", "-lc", "printf destroyed >> \"$OMARCHY_GATE_LIFECYCLE_MARKER.active\""])
}
