import QtQuick
import Qt5Compat.GraphicalEffects

Item {
  id: root
  required property url iconSource
  required property color ink
  Image {
    id: mark
    anchors.fill: parent
    source: root.iconSource
    sourceSize: Qt.size(width * 2, height * 2)
    visible: false
  }
  ColorOverlay { anchors.fill: parent; source: mark; color: root.ink }
}
