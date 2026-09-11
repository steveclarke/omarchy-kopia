pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import qs.Ui as Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.steveclarke.kopia"
  manageIpc: false
  property var anchorItem: null
  property var hostWidget: null
  property bool anchorCaptured: false
  readonly property Item heldAnchor: Item {
    parent: root.anchorItem && root.anchorItem.QsWindow.window ? root.anchorItem.QsWindow.window.contentItem : null
  }
  function captureAnchor() {
    if (!anchorItem || !heldAnchor.parent) { anchorCaptured = false; return }
    var position = anchorItem.mapToItem(heldAnchor.parent, 0, 0)
    heldAnchor.x = position.x; heldAnchor.y = position.y
    heldAnchor.width = anchorItem.width; heldAnchor.height = anchorItem.height
    anchorCaptured = true
  }
  onAnchorItemChanged: anchorCaptured = false

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
  readonly property double now: service ? service.nowMs : Date.now()
  readonly property string health: service ? service.health : "unset"
  readonly property var prefs: service ? service.settings : Model.normalizeSettings({}, "")
  readonly property var snapshots: service ? service.snapshots : []
  readonly property var newest: Model.newest(snapshots)
  readonly property var newestGood: Model.newestGood(snapshots)
  readonly property var unit: service ? service.unit : Model.parseUnit("")
  readonly property var timer: service ? service.timer : ({nextAt: 0, lastAt: 0})
  readonly property var repo: service ? service.repo : Model.parseRepoStatus("")
  readonly property var error: service ? service.error : null
  readonly property var progress: service ? service.progress : null
  readonly property string cadence: service ? service.cadence : ""
  // Rebuild the 168 cells once an hour, not once a second: bind to the hour, not to now.
  readonly property double hourStamp: Math.floor(now / 3600000)
  readonly property var rows: Model.heatmapRows(snapshots, hourStamp * 3600000 + 1, prefs.heatmapDays, health === "failed" && unit.startedAt > 0 ? unit.startedAt : 0)

  readonly property color surface: Color.popups.background
  readonly property color foreground: Color.popups.text
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color track: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  readonly property color urgent: Color.urgent
  readonly property color ok: surface.hslLightness > 0.5 ? "#40a02b" : "#a6e3a1"
  readonly property color warn: surface.hslLightness > 0.5 ? "#c49a16" : "#edc35b"
  readonly property color stateColor: health === "failed" ? urgent : health === "stale" ? warn : health === "unset" ? dim : foreground

  property bool settingsOpen: false
  property bool showAll: false
  property int cursor: -1
  readonly property var recent: snapshots.slice().reverse().slice(0, showAll ? 10 : 3)

  function showSettings() { if (service) { settingsOpen = true; scroll.contentY = 0; settingsView.begin() } }
  function hideSettings() { settingsOpen = false; scroll.contentY = 0; keys.forceActiveFocus() }
  function refresh() { if (service) service.refresh() }
  function backupNow() { if (service) service.backupNow() }
  function openWebUi() { if (service) service.openWebUi() }
  function openLog() { if (service) service.openLog() }
  function moreSnapshots() { if (prefs.webUiUrl !== "") openWebUi(); else showAll = !showAll }
  onOpenedChanged: {
    if (opened) { captureAnchor(); cursor = -1; showAll = false }
    else settingsOpen = false
    if (service) service.panelOpen = opened
  }

  // ---- hero strings, straight from the design cards ----
  readonly property string heroTitle: health === "healthy" ? "Backups are healthy"
    : health === "running" ? "Backing up…"
    : health === "failed" ? "Last backup failed"
    : health === "stale" ? Model.staleTitle(newest ? newest.start : 0, now)
    : "Kopia isn't connected"
  readonly property string heroMeta: health === "running" ? "Started " + Model.relativeTime(unit.startedAt, now)
    : health === "failed" ? "Failed " + Model.dayClock(unit.startedAt, now).toLowerCase()
    : health === "stale" ? "Last backup " + (newest ? Model.dayClock(newest.start, now).toLowerCase() : "never")
    : health === "unset" ? (service && service.unsetReason === "missing" ? "Kopia isn't installed" : "No backup storage connected")
    : newest ? "Last backup " + Model.relativeTime(newest.start, now) : "Waiting for the first backup"
  readonly property string heroDetail: health === "running" ? (newestGood ? "Last backup " + Model.relativeTime(newestGood.start, now) + " · took " + Model.duration(newestGood.durationMs) : "First backup")
    : health === "failed" ? (unit.exitedAt > unit.startedAt ? Model.duration(unit.exitedAt - unit.startedAt) + " after starting · " : "") + (newestGood ? "last good backup " + Model.relativeTime(newestGood.start, now) + " (" + Model.clock(newestGood.start) + ")" : "no good backup yet")
    : health === "stale" ? "Runs " + (cadence || "on a schedule") + " · nothing has run since"
    : health === "unset" ? (service && service.unsetReason === "missing" ? "The kopia command isn't installed" : "Kopia has no repository to read")
    : "Kopia · took " + (newest ? Model.duration(newest.durationMs) : "") + " · " + (timer.nextAt > now ? "next in " + Model.until(timer.nextAt, now) : "no next run scheduled") + (cadence ? " · " + cadence : "") + (repo.host ? " to " + repo.host : "")

  component Label: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }
  component InfoPair: Row {
    property string label: ""
    property string value: ""
    property string secondary: ""
    width: parent.width
    spacing: Style.space(8)
    Label { text: label; color: root.dim; font.pixelSize: Style.font.bodySmall }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - valueRow.implicitWidth - parent.spacing * 2); height: 1 }
    Row {
      id: valueRow
      spacing: Style.space(4)
      Label { text: value; font.pixelSize: Style.font.bodySmall }
      Label { visible: secondary !== ""; text: "· " + secondary; color: root.dim; font.pixelSize: Style.font.bodySmall }
    }
  }
  component MessageBox: Rectangle {
    property color tone: root.urgent
    property string title: ""
    property string next: ""
    property string command: ""
    width: parent.width
    implicitHeight: boxText.implicitHeight + Style.space(20)
    color: "transparent"
    border.width: 1; border.color: tone; radius: Style.cornerRadius
    Column {
      id: boxText
      x: Style.space(12); y: Style.space(10); width: parent.width - Style.space(24)
      spacing: Style.space(4)
      Label { width: parent.width; wrapMode: Text.WordWrap; text: title; color: tone; font.bold: true }
      Label { width: parent.width; wrapMode: Text.WordWrap; text: next }
      Label { width: parent.width; text: command; color: root.dim; font.pixelSize: Style.font.bodySmall; elide: Text.ElideRight }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorCaptured ? root.heldAnchor : root.anchorItem
    bar: root.bar
    owner: root.hostWidget || root
    open: root.opened
    focusTarget: root.settingsOpen ? settingsView : keys
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(1000))
    PanelKeyCatcher {
      id: keys
      blocked: root.settingsOpen
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { if (root.bar) root.bar.switchPanelFrom(root.hostWidget || root, direction) }
      onMoveRequested: function(dx, dy) {
        if (dy) root.cursor = Math.max(-1, Math.min(root.recent.length - (root.health === "failed" && root.error && root.unit.startedAt > 0 && !(root.newest && root.newest.errors > 0) ? 0 : 1), root.cursor + dy))
      }
      onActivateRequested: if (root.cursor >= 0) { if (root.health === "failed") root.openLog(); else root.openWebUi() }
      onTextKey: function(t) {
        if (t.toLowerCase() === "r") root.refresh()
        if (t.toLowerCase() === "s") root.backupNow()
        if (t === ",") root.showSettings()
      }
      Flickable {
        id: scroll
        anchors.fill: parent
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        Column {
          id: content
          width: scroll.width
          spacing: Style.spacing.panelGap

          SettingsView {
            id: settingsView
            visible: root.settingsOpen
            width: parent.width
            service: root.service
            ink: root.foreground; dim: root.dim
            onDone: root.hideSettings()
          }

          // ---------- 1. Hero ----------
          PanelHero {
            visible: !root.settingsOpen
            title: root.heroTitle
            meta: root.heroMeta
            foreground: root.stateColor
            metaOpacity: 1
            iconComponent: Component {
              TintedIcon { width: Style.font.display; height: width; iconSource: Qt.resolvedUrl("assets/kopia.svg"); ink: root.stateColor }
            }
            trailingControl: Component {
              PanelActionButton {
                iconText: "󰒓"; tooltipText: "Settings"
                foreground: root.foreground
                onClicked: root.showSettings()
              }
            }
          }
          Label { visible: !root.settingsOpen; width: parent.width; text: root.heroDetail; color: root.dim; font.pixelSize: Style.font.bodySmall; elide: Text.ElideRight
            topPadding: -Style.space(8) }   // tucked under the hero meta, not a full panelGap away

          // ---------- running: progress ----------
          Column {
            visible: !root.settingsOpen && root.health === "running"
            width: parent.width
            spacing: Style.space(6)
            Rectangle {
              width: parent.width; height: Style.space(5); radius: height / 2; color: root.track
              Rectangle {
                id: progressFill
                height: parent.height; radius: parent.radius; color: Color.accent
                width: root.progress && root.progress.percent !== null ? parent.width * root.progress.percent / 100 : parent.width * 0.25
                x: root.progress && root.progress.percent !== null ? 0 : 0
                SequentialAnimation on x {
                  running: root.opened && root.health === "running" && !(root.progress && root.progress.percent !== null)
                  loops: Animation.Infinite
                  NumberAnimation { from: 0; to: progressFill.parent.width * 0.75; duration: 1100; easing.type: Easing.InOutSine }
                  NumberAnimation { from: progressFill.parent.width * 0.75; to: 0; duration: 1100; easing.type: Easing.InOutSine }
                }
              }
            }
            InfoPair { visible: root.progress !== null; label: "Scanned"; value: root.progress ? Model.formatCount(root.progress.hashed + root.progress.cached) + " files" : ""; secondary: root.progress ? root.progress.cachedSize : "" }
            InfoPair { visible: root.progress !== null; label: "Uploaded"; value: root.progress ? root.progress.uploaded : ""; secondary: root.progress ? Model.formatCount(root.progress.hashed) + " files" : "" }
          }

          // ---------- 2. Message box (failed / stale) ----------
          MessageBox {
            visible: !root.settingsOpen && root.health === "failed" && root.error !== null
            tone: root.urgent
            title: root.error ? root.error.title : ""
            next: root.error ? root.error.next : ""
            command: root.error ? root.error.command : ""
          }
          MessageBox {
            visible: !root.settingsOpen && root.health === "stale"
            tone: root.warn
            readonly property var box: Model.staleBox(root.cadence, root.prefs.timerUnit, root.unit.loadState === "not-found")
            title: box.title; next: box.next; command: box.command
          }

          // ---------- unset: three steps ----------
          Column {
            visible: !root.settingsOpen && root.health === "unset"
            width: parent.width
            spacing: Style.space(10)
            PanelSeparator { foreground: root.foreground }
            Label { width: parent.width; wrapMode: Text.WordWrap; color: root.dim
              text: "This widget reads backups from the Kopia command line. Install it and connect a repository, then this panel fills in on its own." }
            Repeater {
              model: ["omarchy-pkg-aur-add kopia-bin", "kopia repository connect sftp --path /backups/desk --host storage --username backup --keyfile ~/.ssh/backup_key", "Set the source path in Settings if it isn't your home folder"]
              Row {
                required property string modelData
                required property int index
                width: parent.width; spacing: Style.space(12)
                Label { text: String(index + 1); color: root.dim; font.pixelSize: Style.font.bodySmall }
                Label { width: parent.width - Style.space(20); text: modelData; wrapMode: Text.WordWrap; font.pixelSize: Style.font.bodySmall }
              }
            }
          }

          // ---------- 3. Heatmap ----------
          PanelSeparator { visible: !root.settingsOpen && root.health !== "unset"; foreground: root.foreground }
          Column {
            visible: !root.settingsOpen && root.health !== "unset"
            width: parent.width
            spacing: Style.space(8)
            PanelSectionHeader { text: "LAST " + root.prefs.heatmapDays + " DAYS · ONE SQUARE PER HOUR"; foreground: root.foreground }
            Column {
              id: heatGrid
              width: parent.width
              spacing: Style.space(3)
              readonly property real cell: Math.floor((width - Style.space(34) - 23 * Style.space(3)) / 24)
              Repeater {
                model: root.rows
                Row {
                  id: heatRow
                  required property var modelData
                  spacing: Style.space(3)
                  Label { width: Style.space(34) - Style.space(3); text: heatRow.modelData.label; color: root.dim; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                  Repeater {
                    model: heatRow.modelData.cells
                    Rectangle {
                      id: cell
                      required property var modelData
                      width: heatGrid.cell; height: width; radius: Style.space(2)
                      readonly property bool pulse: cell.modelData.current && root.health === "running"
                      color: pulse ? Color.accent
                        : cell.modelData.status === "ok" ? root.ok
                        : cell.modelData.status === "bad" ? root.urgent
                        : cell.modelData.status === "future" ? "transparent"
                        : root.track
                      border.width: cell.modelData.current ? 2 : cell.modelData.status === "future" ? 1 : 0
                      border.color: cell.modelData.current ? root.foreground : root.track
                      SequentialAnimation on opacity {
                        running: cell.pulse && root.opened
                        loops: Animation.Infinite
                        NumberAnimation { from: 1; to: 0.35; duration: 600 }
                        NumberAnimation { from: 0.35; to: 1; duration: 600 }
                      }
                    }
                  }
                }
              }
              Item {
                x: Style.space(34); width: parent.width - x; height: axisSample.implicitHeight
                Label { id: axisSample; text: "00"; visible: false; font.pixelSize: Style.font.caption }
                Repeater {
                  model: ["00", "06", "12", "18", "23"]
                  Label { required property string modelData; required property int index
                    x: index === 4 ? parent.width - implicitWidth : index * 6 * (heatGrid.cell + Style.space(3))
                    text: modelData; color: root.dim; font.pixelSize: Style.font.caption }
                }
              }
            }
            Row {
              spacing: Style.space(14)
              Repeater {
                model: [{c: root.ok, t: "Backup"}, {c: root.health === "running" ? Color.accent : root.urgent, t: root.health === "running" ? "Running now" : "Failed"}, {c: root.track, t: "No backup"}]
                Row {
                  required property var modelData
                  spacing: Style.space(5)
                  Rectangle { width: Style.space(9); height: width; radius: Style.space(2); color: modelData.c; anchors.verticalCenter: parent.verticalCenter }
                  Label { text: modelData.t; color: root.dim; font.pixelSize: Style.font.caption }
                }
              }
            }
          }

          // ---------- 4. Stat rows ----------
          PanelSeparator { visible: !root.settingsOpen && root.health !== "unset"; foreground: root.foreground }
          Column {
            visible: !root.settingsOpen && root.health !== "unset"
            width: parent.width
            spacing: Style.spacing.labelGap
            InfoPair { label: root.prefs.sourcePath === root.service.home ? "Home" : root.prefs.sourcePath.split("/").pop() || "Source"; value: root.newest ? Model.formatBytes(root.newest.size) : "—"; secondary: root.newest ? Model.formatCount(root.newest.files) + " files" : "" }
            InfoPair { visible: root.health === "healthy" && root.newest !== null; label: "Changed since previous"; value: root.newest ? Model.formatCount(root.newest.filesAdded) + " files" : ""; secondary: root.newest && root.newest.bytesAdded > 0 ? Model.formatBytes(root.newest.bytesAdded) : "" }
            InfoPair { label: "Repository"; value: root.repo.host || "—"; secondary: root.repo.available ? Model.formatBytes(root.repo.available) + " free" : "" }
            InfoPair { visible: root.health === "healthy"; label: "Keeps"; value: root.service ? Model.retentionText(root.service.policy) : "" }
          }

          // ---------- 5. Recent snapshots ----------
          PanelSeparator { visible: !root.settingsOpen && (root.health === "healthy" || root.health === "failed"); foreground: root.foreground }
          Column {
            visible: !root.settingsOpen && (root.health === "healthy" || root.health === "failed")
            width: parent.width
            spacing: Style.space(2)
            PanelSectionHeader { text: "RECENT BACKUPS"; foreground: root.foreground; bottomPadding: Style.space(6) }
            Repeater {
              id: recentRepeater
              model: root.health === "failed" && root.error && root.unit.startedAt > 0 && !(root.newest && root.newest.errors > 0)
                ? [{failedRun: true, start: root.unit.startedAt, sub: root.error.short}].concat(root.recent) : root.recent
              CursorSurface {
                id: row
                required property var modelData
                required property int index
                width: parent.width
                implicitHeight: rowContent.implicitHeight + Style.space(12)
                foreground: root.foreground
                hasCursor: root.cursor === index
                HoverHandler { onHoveredChanged: if (hovered) root.cursor = row.index }
                TapHandler { onTapped: root.openWebUi() }
                Row {
                  id: rowContent
                  x: Style.space(8); width: parent.width - Style.space(16)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(10)
                  readonly property bool bad: row.modelData.failedRun === true || row.modelData.errors > 0
                  Label { text: rowContent.bad ? "✗" : "✓"; color: rowContent.bad ? root.urgent : root.ok }
                  Row {
                    width: parent.width - Style.space(10) * 2 - parent.children[0].implicitWidth - right.implicitWidth
                    spacing: Style.space(4)
                    Label { text: Model.dayClock(row.modelData.start, root.now) }
                    Label {
                      color: root.dim; font.pixelSize: Style.font.bodySmall; elide: Text.ElideRight
                      text: row.modelData.failedRun ? "· " + row.modelData.sub
                        : "· " + Model.duration(row.modelData.durationMs) + " · +" + Model.formatCount(row.modelData.filesAdded) + " files"
                    }
                  }
                  Label { id: right; text: rowContent.bad ? "failed" : Model.formatBytes(row.modelData.size); color: rowContent.bad ? root.urgent : root.dim; font.pixelSize: Style.font.bodySmall }
                }
              }
            }
            CursorSurface {
              visible: root.snapshots.length > 3
              width: parent.width; implicitHeight: Style.space(30)
              foreground: root.foreground
              TapHandler { onTapped: root.moreSnapshots() }
              Label { x: Style.space(28); anchors.verticalCenter: parent.verticalCenter; color: root.dim; font.pixelSize: Style.font.bodySmall
                text: root.showAll ? "Fewer backups" : (root.prefs.webUiUrl !== "" ? "All " + root.snapshots.length + " backups in the web UI" : "More backups") }
              Label { anchors.right: parent.right; anchors.rightMargin: Style.space(8); anchors.verticalCenter: parent.verticalCenter; color: root.dim; text: "›" }
            }
          }

          // ---------- 6. Actions ----------
          Row {
            visible: !root.settingsOpen
            width: parent.width
            layoutDirection: Qt.RightToLeft
            spacing: Style.space(8)
            Ui.Button {
              visible: root.health === "unset" || (root.prefs.webUiUrl !== "" && root.health !== "failed")
              text: root.health === "unset" ? "Settings" : "Open web UI"
              iconText: root.health === "unset" ? "󰒓" : "󰖟"
              foreground: root.foreground; bordered: true; iconSize: Style.font.icon
              onClicked: root.health === "unset" ? root.showSettings() : root.openWebUi()
            }
            Ui.Button {
              visible: root.health === "failed"
              text: "Open log"; iconText: "󰈙"
              foreground: root.foreground; bordered: true; iconSize: Style.font.icon
              onClicked: root.openLog()
            }
            Ui.Button {
              visible: (root.health === "unset" || root.prefs.showBackupNow) && root.health !== "running"
              enabled: root.health === "unset" || !(root.service && root.service.backupStarting)
              opacity: enabled ? 1 : 0.5
              text: root.health === "unset" ? "Check again" : root.health === "failed" ? "Try again now" : "Back up now"
              iconText: root.health === "unset" ? "󰑐" : "󰁯"
              foreground: root.foreground; bordered: true; iconSize: Style.font.icon
              onClicked: root.health === "unset" ? root.refresh() : root.backupNow()
            }
          }
          Label { visible: !root.settingsOpen && root.health !== "unset" && root.health !== "running"; width: parent.width; color: root.dim; font.pixelSize: Style.font.caption; elide: Text.ElideRight
            text: "j/k · enter " + (root.health === "failed" ? "log" : "web UI") + " · s back up · , settings" }
        }
      }
    }
  }
}
