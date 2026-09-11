import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Panel lifecycle follows Omarchy's clock widget and Headroom.
BarWidget {
  id: root
  moduleName: "io.github.steveclarke.kopia"
  readonly property var service: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
  // The bar keeps `settings` current; the service only ever gets a startup copy.
  function pushSettings() {
    if (!service || !settings) return
    var next = Object.assign({id: moduleName}, settings)
    if (JSON.stringify(next) !== JSON.stringify(service.entry)) service.entry = next   // three bars, one refresh
  }
  onSettingsChanged: pushSettings()
  onServiceChanged: pushSettings()
  readonly property double now: service ? service.nowMs : Date.now()
  readonly property string health: service ? service.health : "unset"
  readonly property string label: service ? Model.barText(service.settings.barText, health, service.timer.nextAt, Model.newest(service.snapshots), now) : ""
  readonly property bool alert: health === "failed" || health === "stale"
  readonly property color ink: alert ? (bar ? bar.urgent : Color.urgent)
    : (health === "running" || health === "unset" ? Qt.darker(button.foreground, 1.4) : button.foreground)
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function activate() { toggle() }
  function showSettings() { if (panelLoader.item) panelLoader.item.showSettings() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  readonly property real openPanelIndicatorWidth: Math.round(content.implicitWidth)
  onBarChanged: injectPanel()
  Loader {
    id: panelLoader
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    hasVisualContent: true
    labelVisible: false
    fixedWidth: root.vertical ? -1 : content.implicitWidth + Style.space(16)
    fixedHeight: root.vertical ? content.implicitHeight + Style.space(12) : -1
    tooltipText: ""
    Accessible.role: Accessible.Button
    Accessible.name: "Kopia Backups. " + ({healthy: "Backups are healthy", running: "Backing up", failed: "Last backup failed", stale: "Backup overdue", unset: "Kopia is not connected"})[root.health]
    Accessible.onPressAction: root.activate()
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.activate()
      else if (root.service) root.service.refresh()
    }
    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.space(5)
      TintedIcon {
        anchors.verticalCenter: parent.verticalCenter
        iconSource: Qt.resolvedUrl("assets/kopia.svg")
        ink: root.ink
        width: Style.bar.iconCanvas
        height: width
        Behavior on ink { ColorAnimation { duration: 160 } }
      }
      Text {
        id: label
        textFormat: Text.PlainText
        visible: root.label !== ""
        anchors.verticalCenter: parent.verticalCenter
        width: Math.ceil(labelSize.width)
        text: root.label
        horizontalAlignment: Text.AlignRight
        color: root.ink
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
        // Pinned so "9m" and "22m" do not move the icon around.
        TextMetrics { id: labelSize; text: root.service && root.service.settings.barText === "last" ? "88:88" : "88h 88m"; font: label.font }
      }
      Text {
        textFormat: Text.PlainText
        visible: root.alert
        anchors.verticalCenter: parent.verticalCenter
        text: "!"
        color: root.ink
        font.family: button.fontFamily
        font.pixelSize: Style.bar.iconFont
        font.bold: true
        renderType: Text.NativeRendering
      }
    }
  }
}
