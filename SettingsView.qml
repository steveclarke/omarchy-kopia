import QtQuick
import qs.Commons
import qs.Ui
import qs.Ui as Ui

Column {
  id: root
  required property var service
  required property color ink
  required property color dim
  readonly property var settings: service ? service.settings : ({})
  property string error: ""
  signal done()
  spacing: Style.space(10)
  Keys.onEscapePressed: function(event) { root.done(); event.accepted = true }
  function begin() { error = ""; forceActiveFocus() }
  function apply(patch) { error = service && service.saveSettings(patch) ? "" : "Could not save this change. Try again." }

  component PlainLabel: Text {
    textFormat: Text.PlainText
    color: root.ink
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }
  component SettingRow: Item {
    property string label: ""
    property string help: ""
    default property alias control: slot.children
    width: parent.width
    implicitHeight: Math.max(labels.implicitHeight, slot.implicitHeight) + Style.space(10)
    Column {
      id: labels
      anchors.left: parent.left; anchors.right: slot.left; anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)
      PlainLabel { width: parent.width; text: label; wrapMode: Text.WordWrap }
      PlainLabel { visible: help !== ""; width: parent.width; text: help; color: root.dim; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
    }
    Item { id: slot; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; implicitWidth: childrenRect.width; implicitHeight: childrenRect.height }
    PanelSeparator { anchors.bottom: parent.bottom; foreground: root.ink }
  }
  function patch(key, value) { var o = {}; o[key] = value; return o }
  component SettingSwitch: ToggleSwitch {
    property string key: ""
    checked: root.settings[key] === true
    foreground: root.ink
    onToggled: root.apply(root.patch(key, !checked))
  }
  component SettingField: Ui.TextField {
    property string key: ""
    width: Style.space(190)
    foreground: root.ink
    // Seeded, never bound: binding `text` to the model loops. The view is created
    // with the panel, before the service has settings, so re-seed on change while
    // the field is not being edited.
    function seed() { if (!activeFocus) text = String(root.settings[key] === undefined ? "" : root.settings[key]) }
    Component.onCompleted: seed()
    Connections { target: root; function onSettingsChanged() { seed() } }
    onEditingFinished: root.apply(root.patch(key, text))
  }
  component SettingNumber: NumberField {
    property string key: ""
    label: ""
    fieldWidth: Style.space(64)
    foreground: root.ink
    value: Number(root.settings[key])
    onModified: function(v) { root.apply(root.patch(key, v)) }
  }

  PanelHero {
    title: "Backup widget settings"
    meta: "Saved as you change them"
    foreground: root.ink
    iconComponent: Component { TintedIcon { width: Style.space(30); height: width; iconSource: Qt.resolvedUrl("assets/kopia.svg"); ink: root.ink } }
    trailingControl: Component { PanelActionButton { iconText: "󰅖"; tooltipText: "Back"; foreground: root.ink; onClicked: root.done() } }
  }
  PanelSeparator { foreground: root.ink }

  PanelSectionHeader { text: "BAR"; foreground: root.ink }
  SettingRow {
    label: "Bar text"; help: "Shown beside the icon"
    Dropdown {
      width: Style.space(190)
      showLabel: false
      foreground: root.ink
      options: [{value: "none", label: "Icon only"}, {value: "next", label: "Next backup in"}, {value: "last", label: "Last backup time"}]
      value: root.settings.barText
      onChanged: function(v) { root.apply({barText: v}) }
    }
  }
  SettingRow { label: "Warn after (hours)"; help: "Hours without a backup before the icon turns red"; SettingNumber { key: "staleHours"; from: 1; to: 168 } }

  PanelSectionHeader { text: "BACKUP"; foreground: root.ink; topPadding: Style.space(14) }
  SettingRow { label: "Source path"; help: "The folder the backup covers"; SettingField { key: "sourcePath" } }
  SettingRow { label: "Backup service"; help: "The systemd user service that runs the backup"; SettingField { key: "serviceUnit" } }
  SettingRow { label: "Backup schedule"; help: "The systemd user timer that starts it"; SettingField { key: "timerUnit" } }
  SettingRow { label: "History"; help: "Days shown in the grid"; SettingNumber { key: "heatmapDays"; from: 3; to: 14 } }

  PanelSectionHeader { text: "BUTTONS"; foreground: root.ink; topPadding: Style.space(14) }
  SettingRow { label: "Show the Back up now button"; SettingSwitch { key: "showBackupNow" } }
  SettingRow { label: "Web UI address"; help: "Blank hides the Open web UI button"; SettingField { key: "webUiUrl" } }
  SettingRow { label: "Web UI username"; help: "Blank signs in by hand in the browser"; SettingField { key: "webUiUser" } }
  SettingRow { label: "Web UI password file"; help: "Holds KOPIA_SERVER_PASSWORD. Only the path is saved"; SettingField { key: "webUiPasswordFile" } }

  PanelSectionHeader { text: "ALERTS"; foreground: root.ink; topPadding: Style.space(14) }
  SettingRow { label: "Notify when a backup fails"; SettingSwitch { key: "notifyOnFail" } }
  SettingRow { label: "Notify when a backup is overdue"; SettingSwitch { key: "notifyOnStale" } }

  PlainLabel { visible: root.error !== ""; width: parent.width; text: root.error; wrapMode: Text.WordWrap }
  Row {
    width: parent.width
    layoutDirection: Qt.RightToLeft
    Ui.Button { text: "Done"; foreground: root.ink; focusable: true; bordered: true; onClicked: root.done() }
  }
}
