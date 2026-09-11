import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// One service polls Kopia and systemd for every monitor's bar widget.
Item {
  id: root
  visible: false
  property var shell: null
  property var manifest: null
  readonly property string pluginId: "io.github.steveclarke.kopia"
  readonly property string home: Quickshell.env("HOME")
  // Tools run by absolute path so a directory prepended to PATH cannot stand in
  // for them. The test harness points this at its stubs.
  property string binDir: "/usr/bin/"
  // The shell hands a plugin a one-time copy of the bar config, so the entry is
  // seeded from that and then kept current by the bar widget, whose `settings`
  // the bar patches live (omarchy bar set, the settings view).
  property var entry: ({})
  onShellChanged: if (shell && shell.barConfig) entry = Model.entry({bar: shell.barConfig}, pluginId)
  readonly property var settings: Model.normalizeSettings(entry, home)

  property double nowMs: Date.now()
  property bool panelOpen: false
  property string debugMode: ""

  // Raw collected data.
  property var snapshots: []
  property var unit: ({activeState: "", subState: "", result: "", startedAt: 0, exitedAt: 0})
  property var timer: ({nextAt: 0, lastAt: 0})
  property var repo: Model.parseRepoStatus("")
  property var policy: Model.parsePolicy("{}")
  property string journal: ""
  property bool kopiaPresent: false
  property string unsetReason: "missing"
  property bool snapshotsLoaded: false

  // Derived.
  readonly property string health: Model.computeState({snapshots: snapshots, unit: unit, now: nowMs, staleHours: settings.staleHours, kopiaPresent: kopiaPresent})
  readonly property var progress: health === "running" ? Model.parseProgress(journal) : null
  readonly property var error: health === "failed" ? Model.classifyError(journal, {host: repo.host, unit: settings.serviceUnit, cadence: Model.cadence(snapshots), nextAt: timer.nextAt, now: nowMs}) : null
  readonly property string cadence: Model.cadence(snapshots)
  readonly property bool refreshing: snapshotsProc.active || repoProc.active
  property bool backupStarting: backupProc.active

  // Scheduling.
  property double nextSnapshotsAt: 0
  property double nextRepoAt: 0
  property double nextUnitAt: 0
  property double nextJournalAt: 0
  property double lastSnapshotsAttemptAt: 0
  property int batchesStarted: 0

  // Notification bookkeeping. Task 7 replaces this function; until then it only
  // fetches the failure journal the first time a failed run is seen.
  property double notifiedFailureAt: 0
  property bool notifiedStale: false
  property double failureSeenAt: 0
  // One terminal, from the service, whatever the number of bars. Positional argv only.
  function openLog() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "journalctl", "--user", "-u", settings.serviceUnit, "-e"])
  }

  // Called from the 1 s heartbeat (and from debugState), never from property change
  // handlers: the three startup collectors finish in any order, and a state that
  // is "failed" only after the last of them must still get its journal and its
  // notification. One critical notification per failed run, keyed by the run's
  // start time, so a re-poll of the same failure never repeats it. One normal
  // notification per entry into stale, reset when a snapshot arrives.
  function considerNotifications() {
    if (health === "failed" && unit.startedAt > 0 && failureSeenAt !== unit.startedAt && !journalProc.active) { failureSeenAt = unit.startedAt; if (debugMode === "") journal = ""; collectJournal(40) }
    // Forced demo states never notify: a desktop alert is only ever about a real run.
    if (debugMode !== "") return
    if (health === "failed" && settings.notifyOnFail && error && unit.startedAt > 0 && notifiedFailureAt !== unit.startedAt && journal !== "") {
      notifiedFailureAt = unit.startedAt
      if (notifyProc.active) notifyProc.cancel()   // a newer failure replaces the one still on screen
      var good = Model.newestGood(snapshots)
      notifyProc.command = [binDir + "notify-send", "-u", "critical", "-a", "Kopia Backups", "-A", "open=Open log", "-A", "retry=Try again", "Backup failed", Model.plain(Model.notificationBody(error, good ? good.start : 0))]
      notifyProc.start()
    }
    if (health === "stale" && settings.notifyOnStale && snapshotsLoaded && !notifiedStale) {
      notifiedStale = true
      var last = Model.newest(snapshots)
      staleProc.command = [binDir + "notify-send", "-u", "normal", "-a", "Kopia Backups", "Backup overdue", Model.plain(Model.staleTitle(last ? last.start : 0, nowMs) + ". The timer hasn't run since " + (last ? Model.dayClock(last.start, nowMs) : "it was installed") + ".")]
      staleProc.start()
    }
    if (health !== "stale") notifiedStale = false
  }

  function refresh() {
    if (debugMode !== "") return
    var age = Date.now() - lastSnapshotsAttemptAt
    if (age >= 0 && age < 5000) return
    nextSnapshotsAt = Date.now(); nextUnitAt = Date.now(); nextRepoAt = Date.now()
  }
  function unitPeriod() { return panelOpen || health === "running" ? 10000 : 60000 }

  function collectSnapshots() {
    lastSnapshotsAttemptAt = Date.now()
    batchesStarted++
    snapshotsProc.command = [binDir + "kopia", "snapshot", "list", settings.sourcePath, "--json"]
    snapshotsProc.start()
  }
  function collectRepo() {
    repoProc.command = [binDir + "kopia", "repository", "status", "--json"]
    repoProc.start()
  }
  function collectPolicy() {
    policyProc.command = [binDir + "kopia", "policy", "show", "--json", settings.sourcePath]
    policyProc.start()
  }
  function collectUnit() {
    unitProc.command = [binDir + "systemctl", "--user", "show", settings.serviceUnit, "-p", "LoadState,ActiveState,SubState,Result,ExecMainStartTimestamp,ExecMainExitTimestamp", "--timestamp=unix"]
    unitProc.start()
  }
  function collectTimer() {
    timerProc.command = [binDir + "systemctl", "--user", "list-timers", settings.timerUnit, "--output=json"]
    timerProc.start()
  }
  function collectJournal(lines) {
    journalProc.command = [binDir + "journalctl", "--user", "-u", settings.serviceUnit, "-n", String(lines), "-o", "cat", "--no-pager"]
    if (unit.startedAt > 0) journalProc.command = journalProc.command.concat(["--since=@" + Math.floor(unit.startedAt / 1000)])
    journalProc.start()
  }

  function backupNow() {
    if (debugMode !== "" || backupProc.active || health === "running" || health === "unset") return
    backupProc.command = [binDir + "systemctl", "--user", "start", "--no-block", settings.serviceUnit]
    backupProc.start()
  }
  // Signs in the way the web UI server does: the password is read from its file at
  // click time and put into the link, never saved in shell.json. With no username
  // or password file set, the plain address opens and the browser asks.
  function openWebUi() {
    if (settings.webUiUrl === "" || openProc.active || secretProc.active) return
    if (settings.webUiUser === "" || settings.webUiPasswordFile === "") { launchWebUi(settings.webUiUrl); return }
    secretProc.command = [binDir + "cat", "--", settings.webUiPasswordFile]
    secretProc.start()
  }
  function launchWebUi(link) {
    // No "--": xdg-open rejects it as an unknown option. The link always starts
    // with http:// or https:// (Model.normalizeSettings), so it cannot read as one.
    openProc.command = [binDir + "xdg-open", link]
    openProc.start()
  }
  function saveSettings(value) {
    if (!shell || typeof shell.updateEntryInline !== "function") return false
    var normalized = Model.normalizeSettings(Object.assign({}, settings, value), home)
    if (JSON.stringify(normalized) === JSON.stringify(settings)) return true
    // The native API replaces this entry's fields, so keep the ones we do not own.
    var merged = Model.mergedEntry(entry, normalized)
    var ok = shell.updateEntryInline(pluginId, merged)
    if (ok) entry = merged
    return ok
  }
  property string readKey: ""
  onSettingsChanged: {
    var key = [settings.sourcePath, settings.serviceUnit, settings.timerUnit].join("\n")
    if (key === readKey) return
    readKey = key
    if (debugMode === "") { snapshotsProc.cancel(); lastSnapshotsAttemptAt = 0; refresh() }
  }

  // Forced states for screenshots and tests: omarchy-shell kopia debugState failed
  function debugState(mode) {
    if (["", "off", "healthy", "running", "failed", "stale", "unset"].indexOf(mode) < 0) return
    if (mode === debugMode) return   // re-forcing the same state is a re-poll, not a new run
    if (mode === "" || mode === "off") {
      debugMode = ""
      snapshots = []; journal = ""; kopiaPresent = false; unsetReason = "missing"; snapshotsLoaded = false
      notifiedFailureAt = 0; notifiedStale = false; failureSeenAt = 0
      lastSnapshotsAttemptAt = 0
      refresh()
      return
    }
    snapshotsProc.cancel(); repoProc.cancel(); policyProc.cancel(); unitProc.cancel(); timerProc.cancel(); journalProc.cancel()
    debugMode = mode
    var d = Model.demo(mode, Date.now())
    kopiaPresent = d.kopiaPresent; unsetReason = d.kopiaPresent ? "" : "disconnected"
    snapshots = d.snapshots; unit = d.unit; timer = d.timer; repo = d.repo; policy = d.policy; journal = d.journal
    snapshotsLoaded = true
    failureSeenAt = d.unit.startedAt   // the demo journal is the error text; never replace it with the real log
    considerNotifications()
  }

  Component.onCompleted: { readKey = [settings.sourcePath, settings.serviceUnit, settings.timerUnit].join("\n"); nextSnapshotsAt = Date.now() + 500; nextRepoAt = Date.now() + 500; nextUnitAt = Date.now() + 500 }
  Component.onDestruction: { snapshotsProc.cancel(); repoProc.cancel(); policyProc.cancel(); unitProc.cancel(); timerProc.cancel(); journalProc.cancel(); backupProc.cancel(); openProc.cancel(); secretProc.cancel() }

  Timer {
    interval: 1000; repeat: true; running: true
    onTriggered: {
      var current = Date.now()
      if (current < root.nowMs || current - root.nowMs > 120000) {
        // Clock went backwards, or the machine slept: every deadline is stale and so
        // is the data. Poll now, and hold the stale notification until the snapshot
        // list is fresh, or a wake after a long sleep says "overdue" while the
        // catch-up timer is already running.
        root.nextSnapshotsAt = current; root.nextRepoAt = current; root.nextUnitAt = current; root.nextJournalAt = current
        root.lastSnapshotsAttemptAt = 0
        if (root.debugMode === "") root.snapshotsLoaded = false
      }
      root.nowMs = current
      if (root.debugMode !== "") return
      if (!snapshotsProc.active && root.nextSnapshotsAt > 0 && current >= root.nextSnapshotsAt) root.collectSnapshots()
      if (!repoProc.active && !policyProc.active && root.nextRepoAt > 0 && current >= root.nextRepoAt) root.collectRepo()
      if (!unitProc.active && !timerProc.active && root.nextUnitAt > 0 && current >= root.nextUnitAt) root.collectUnit()
      if (root.health === "running" && !journalProc.active && current >= root.nextJournalAt) { root.nextJournalAt = current + 2000; root.collectJournal(5) }
      root.considerNotifications()
    }
  }

  CollectorProcess {
    id: snapshotsProc
    onCompleted: function(text) {
      root.snapshots = Model.parseSnapshots(text)
      root.snapshotsLoaded = true
      root.nextSnapshotsAt = Date.now() + 300000
    }
    onFailed: function(reason) {
      // kopia missing (timeout) or not connected (exit): both are "unset"; keep the last list otherwise.
      if (reason === "nostart") { root.kopiaPresent = false; root.unsetReason = "missing" }
      else if (reason === "exit") { root.kopiaPresent = false; root.unsetReason = "disconnected" }
      // "timeout": kopia is there but slow (a sleeping SFTP host); keep the last known state.
      root.nextSnapshotsAt = Date.now() + 300000
    }
  }
  CollectorProcess {
    id: repoProc
    onCompleted: function(text) {
      var parsed = Model.parseRepoStatus(text)
      root.repo = parsed
      root.kopiaPresent = parsed.connected
      root.unsetReason = parsed.connected ? "" : "disconnected"
      root.nextRepoAt = Date.now() + 1800000
      root.collectPolicy()
    }
    onFailed: function(reason) {
      if (reason === "nostart") { root.kopiaPresent = false; root.unsetReason = "missing" }
      else if (reason === "exit") { root.kopiaPresent = false; root.unsetReason = "disconnected" }
      root.nextRepoAt = Date.now() + 1800000
    }
  }
  CollectorProcess {
    id: policyProc
    onCompleted: function(text) { root.policy = Model.parsePolicy(text) }
    onFailed: function() {}
  }
  CollectorProcess {
    id: unitProc
    onCompleted: function(text) {
      var next = Model.parseUnit(text)
      var wasRunning = root.unit.activeState === "activating" || root.unit.activeState === "active"
      root.unit = next
      // A run just ended: fetch the new snapshot without waiting for the 5 minute tick.
      if (wasRunning && root.health !== "running") { root.lastSnapshotsAttemptAt = 0; root.nextSnapshotsAt = Date.now() }
      root.collectTimer()
    }
    onFailed: function() { root.nextUnitAt = Date.now() + root.unitPeriod() }
  }
  CollectorProcess {
    id: timerProc
    onCompleted: function(text) { root.timer = Model.parseTimers(text); root.nextUnitAt = Date.now() + root.unitPeriod() }
    onFailed: function() { root.timer = {nextAt: 0, lastAt: 0}; root.nextUnitAt = Date.now() + root.unitPeriod() }
  }
  CollectorProcess {
    id: journalProc
    maxBytes: 65536
    onCompleted: function(text) { root.journal = text }
    onFailed: function() {}
  }
  CollectorProcess {
    id: backupProc
    timeoutMs: 10000
    onCompleted: function() { root.nextUnitAt = Date.now() }
    onFailed: function() { root.nextUnitAt = Date.now() }
  }
  CollectorProcess { id: openProc; timeoutMs: 10000; onCompleted: function() {} onFailed: function() {} }
  CollectorProcess {
    id: secretProc
    timeoutMs: 5000
    maxBytes: 4096
    onCompleted: function(text) { root.launchWebUi(Model.webUiLink(root.settings.webUiUrl, root.settings.webUiUser, text)) }
    // Unreadable or missing file: open the plain address so the button still works.
    onFailed: function() { root.launchWebUi(root.settings.webUiUrl) }
  }
  CollectorProcess {
    id: notifyProc
    timeoutMs: 86400000   // the notification stays up until acted on or dismissed; the process lives that long
    onCompleted: function(text) {
      var action = text.trim()
      if (action === "open") root.openLog()
      else if (action === "retry") root.backupNow()
    }
    onFailed: function() {}
  }
  CollectorProcess { id: staleProc; timeoutMs: 86400000; onCompleted: function() {} onFailed: function() {} }

  IpcHandler {
    target: "kopia"
    function refresh(): void { root.refresh() }
    function debugState(mode: string): void { root.debugState(mode) }
    function status(): string {
      return JSON.stringify({state: root.health, debug: root.debugMode, kopiaPresent: root.kopiaPresent, unsetReason: root.unsetReason,
        snapshots: root.snapshots.length, unit: root.unit, timer: root.timer, host: root.repo.host, batchesStarted: root.batchesStarted,
        notifiedFailureAt: root.notifiedFailureAt, notifiedStale: root.notifiedStale, settings: root.settings})
    }
  }
}
