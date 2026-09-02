import QtQuick
import Quickshell

Item {
  Component.onCompleted: Quickshell.execDetached(["bash", "-lc", "printf created >> \"$OMARCHY_GATE_LIFECYCLE_MARKER.service\""])
}
