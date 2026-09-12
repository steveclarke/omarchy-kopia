// Pure functions. No Qt, no I/O: node tests run this file in a bare vm context.
var HOUR = 3600000, DAY = 86400000
var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function num(value) { return typeof value === "number" && isFinite(value) && value >= 0 ? value : 0 }
function text(value, max) { return typeof value === "string" ? value.slice(0, max || 200) : "" }
function safeJson(raw) { try { return JSON.parse(raw) } catch (e) { return null } }

// ---- parsers ---------------------------------------------------------------

function parseSnapshots(json) {
  var list = safeJson(json)
  if (!Array.isArray(list)) return []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var s = list[i]
    if (!s || typeof s !== "object" || typeof s.startTime !== "string") continue
    var start = Date.parse(s.startTime), end = Date.parse(typeof s.endTime === "string" ? s.endTime : "")
    if (!isFinite(start)) continue
    if (!isFinite(end) || end < start) end = start
    var stats = s.stats && typeof s.stats === "object" ? s.stats : {}
    var summ = s.rootEntry && s.rootEntry.summ && typeof s.rootEntry.summ === "object" ? s.rootEntry.summ : {}
    out.push({
      id: text(s.id, 64),
      start: start, end: end, durationMs: end - start,
      size: num(stats.totalSize) || num(summ.size),
      files: num(summ.files) || num(stats.cachedFiles) + num(stats.nonCachedFiles),
      dirs: num(summ.dirs) || num(stats.dirCount),
      filesAdded: num(stats.nonCachedFiles) || num(stats.fileCount),
      bytesAdded: 0,
      errors: Math.max(num(stats.errorCount), num(summ.numFailed))
    })
  }
  out.sort(function(a, b) { return a.start - b.start })
  // Kopia reports no per-run upload size; "changed since last" bytes are the tree growth.
  for (var j = 1; j < out.length; j++) out[j].bytesAdded = Math.max(0, out[j].size - out[j - 1].size)
  return out
}

function parseUnit(raw) {
  var unit = {loadState: "", activeState: "", subState: "", result: "", startedAt: 0, exitedAt: 0}
  String(raw || "").split("\n").forEach(function(line) {
    var eq = line.indexOf("=")
    if (eq < 0) return
    var key = line.slice(0, eq).trim(), value = line.slice(eq + 1).trim()
    if (key === "LoadState") unit.loadState = text(value, 40)
    else if (key === "ActiveState") unit.activeState = text(value, 40)
    else if (key === "SubState") unit.subState = text(value, 40)
    else if (key === "Result") unit.result = text(value, 40)
    else if (key === "ExecMainStartTimestamp" || key === "ExecMainExitTimestamp") {
      var m = /^@(\d{1,12})$/.exec(value)
      unit[key === "ExecMainStartTimestamp" ? "startedAt" : "exitedAt"] = m ? Number(m[1]) * 1000 : 0
    }
  })
  return unit
}

function parseTimers(json) {
  var list = safeJson(json)
  var t = Array.isArray(list) && list.length && list[0] && typeof list[0] === "object" ? list[0] : {}
  return {nextAt: Math.floor(num(t.next) / 1000), lastAt: Math.floor(num(t.last) / 1000)}
}

// Values that reach host-rendered text (hero, notifications) keep only the
// characters a hostname, bucket or path segment uses, so no markup survives.
function safeName(value, max) { return text(value, max).replace(/[^A-Za-z0-9._:@\/ -]/g, "") }
// Notification summary and body are rendered by the shell as markup-capable text.
function plain(value) { return String(value || "").replace(/[<>&\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "").slice(0, 300) }
function parseRepoStatus(json) {
  var doc = safeJson(json)
  var out = {connected: false, type: "", host: "", path: "", capacity: 0, available: 0}
  if (!doc || typeof doc !== "object" || !doc.storage || typeof doc.storage !== "object") return out
  var config = doc.storage.config && typeof doc.storage.config === "object" ? doc.storage.config : {}
  out.connected = true
  out.type = text(doc.storage.type, 20)
  out.path = text(config.path, 200)
  if (out.type === "sftp") out.host = safeName(config.host, 80)
  else if (out.type === "filesystem") out.host = "this computer"
  else out.host = (safeName(out.type, 20) + " " + safeName(config.bucket || config.container || config.host, 80)).trim()
  if (doc.volume && typeof doc.volume === "object") { out.capacity = num(doc.volume.capacity); out.available = num(doc.volume.available) }
  return out
}

function parsePolicy(json) {
  var doc = safeJson(json), r = doc && doc.retention && typeof doc.retention === "object" ? doc.retention : {}
  return {latest: num(r.keepLatest), hourly: num(r.keepHourly), daily: num(r.keepDaily), weekly: num(r.keepWeekly), monthly: num(r.keepMonthly), annual: num(r.keepAnnual)}
}

// The design shows four tiers; annual is left out on purpose.
function retentionText(policy) {
  if (!policy) return ""
  return [["hourly", policy.hourly], ["daily", policy.daily], ["weekly", policy.weekly], ["monthly", policy.monthly]]
    .filter(function(t) { return num(t[1]) > 0 }).map(function(t) { return t[1] + " " + t[0] }).join(" · ")
}

// ---- state -----------------------------------------------------------------

function newest(snapshots) { return snapshots && snapshots.length ? snapshots[snapshots.length - 1] : null }
function newestGood(snapshots) {
  for (var i = (snapshots || []).length - 1; i >= 0; i--) if (snapshots[i].errors === 0) return snapshots[i]
  return null
}
function unitRunning(unit) { return !!unit && ["active", "activating", "deactivating", "reloading"].indexOf(unit.activeState) >= 0 }
function unitFailed(unit) { return !!unit && (unit.activeState === "failed" || (unit.result !== "" && unit.result !== "success")) }

function computeState(input) {
  if (!input || !input.kopiaPresent) return "unset"
  if (unitRunning(input.unit)) return "running"
  var last = newest(input.snapshots)
  if (unitFailed(input.unit) || (last && last.errors > 0)) return "failed"
  if (!last || input.now - last.start > num(input.staleHours) * HOUR) return "stale"
  return "healthy"
}

// ---- heatmap ---------------------------------------------------------------

function dayStart(ms, offsetDays) {
  var d = new Date(ms)
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + (offsetDays || 0))
}
function hourKey(ms) { var d = new Date(ms); return dayStart(ms).getTime() + ":" + d.getHours() }

function heatmap(snapshots, now, days, failedAt) {
  days = Math.max(1, Math.min(31, num(days) || 7))
  var index = {}
  ;(snapshots || []).forEach(function(s) { index[hourKey(s.start)] = s.errors > 0 ? "bad" : "ok" })
  if (failedAt > 0) index[hourKey(failedAt)] = "bad"
  var cells = []
  for (var day = 0; day < days; day++) {
    var base = dayStart(now, day - (days - 1))
    for (var hour = 0; hour < 24; hour++) {
      var cellStart = new Date(base.getFullYear(), base.getMonth(), base.getDate(), hour).getTime()
      var current = cellStart <= now && now < cellStart + HOUR
      var status = index[base.getTime() + ":" + hour]
      if (!status) status = cellStart > now ? "future" : current ? "now" : "miss"
      cells.push({day: day, hour: hour, status: status, current: current, label: WEEKDAYS[base.getDay()]})
    }
  }
  return cells
}

function heatmapRows(snapshots, now, days, failedAt) {
  var cells = heatmap(snapshots, now, days, failedAt), rows = []
  cells.forEach(function(c) {
    if (!rows[c.day]) rows[c.day] = {label: c.label, cells: []}
    rows[c.day].cells.push(c)
  })
  return rows
}

// ---- time strings ----------------------------------------------------------

function pad(n) { return (n < 10 ? "0" : "") + n }
function clock(ms) { var d = new Date(ms); return pad(d.getHours()) + ":" + pad(d.getMinutes()) }

function relativeTime(ms, now) {
  var diff = Math.max(0, now - ms)
  if (diff < 60000) return Math.floor(diff / 1000) + " s ago"
  var min = Math.floor(diff / 60000)
  if (min < 60) return min + " min ago"
  var h = Math.floor(min / 60), m = min % 60
  if (h < 24) return m ? h + " h " + m + " min ago" : h + " h ago"
  var d = Math.floor(h / 24)
  return d === 1 ? "1 day ago" : d + " days ago"
}

function duration(ms) {
  ms = Math.max(0, ms)
  if (ms < 1000) return "under 1 s"
  var s = Math.round(ms / 1000)
  if (s < 60) return s + " s"
  var min = Math.floor(s / 60), sec = s % 60
  if (min < 60) return sec ? min + " min " + sec + " s" : min + " min"
  var h = Math.floor(min / 60), m = min % 60
  return m ? h + " h " + m + " min" : h + " h"
}

function until(ms, now) {
  if (ms <= now) return "now"
  var min = Math.ceil((ms - now) / 60000)
  if (min < 60) return min + " min"
  var h = Math.floor(min / 60), m = min % 60
  if (h < 48) return m ? h + " h " + m + " min" : h + " h"
  return Math.floor(h / 24) + " days"
}
function untilShort(ms, now) {
  if (ms <= now) return "now"
  var min = Math.ceil((ms - now) / 60000)
  if (min < 60) return min + "m"
  var h = Math.floor(min / 60), m = min % 60
  if (h < 48) return m ? h + "h " + m + "m" : h + "h"
  return Math.floor(h / 24) + "d"
}

function dayClock(ms, now) {
  var today = dayStart(now).getTime(), that = dayStart(ms).getTime()
  var daysAgo = Math.round((today - that) / DAY)
  if (daysAgo === 0) return "Today " + clock(ms)
  if (daysAgo === 1) return "Yesterday " + clock(ms)
  var d = new Date(ms)
  if (daysAgo < 7) return WEEKDAYS[d.getDay()] + " " + clock(ms)
  return MONTHS[d.getMonth()] + " " + d.getDate() + " " + clock(ms)
}

function staleTitle(newestStart, now) {
  if (!newestStart) return "No backup yet"
  var hours = Math.floor((now - newestStart) / HOUR)
  if (hours >= 48) return "No backup for " + Math.floor(hours / 24) + " days"
  return "No backup for " + hours + (hours === 1 ? " hour" : " hours")
}

function cadence(snapshots) {
  var list = (snapshots || []).slice(-7), gaps = []
  for (var i = 1; i < list.length; i++) gaps.push(list[i].start - list[i - 1].start)
  if (gaps.length < 3) return ""
  gaps.sort(function(a, b) { return a - b })
  var median = gaps[Math.floor(gaps.length / 2)]
  if (median >= 40 * 60000 && median <= 90 * 60000) return "hourly"
  if (median >= 20 * HOUR && median <= 28 * HOUR) return "daily"
  if (median >= 6 * DAY && median <= 8 * DAY) return "weekly"
  return ""
}

// ---- errors ----------------------------------------------------------------

var ERROR_CLASSES = [
  {kind: "refused", test: /connection refused/i, short: "couldn't reach storage",
    title: "Can't reach the repository.",
    next: function(c) { return c.host + " refused the SFTP connection. Check it's on, then try again. The " + (c.cadence ? c.cadence + " " : "") + "timer also retries" + (c.nextAt > c.now ? " at " + clock(c.nextAt) : " on its own") + "." },
    notice: function(c) { return "Kopia couldn't reach " + c.host + " (SFTP connection refused)." }},
  {kind: "key", test: /permission denied \(publickey|handshake failed|unable to authenticate|no supported methods remain|host key/i, short: "key rejected",
    title: "The repository server rejected the SSH key.",
    next: function(c) { return c.host + " wouldn't accept the SSH key. Check the key and the host entry, then try again." },
    notice: function(c) { return "Kopia's SSH key was rejected by " + c.host + "." }},
  {kind: "unreachable", test: /i\/o timeout|timed out|no route to host|network is unreachable|no such host|name resolution|dial tcp/i, short: "no answer from storage",
    title: "Can't reach the repository.",
    next: function(c) { return c.host + " didn't answer. Check the network and that it's up, then try again." },
    notice: function(c) { return "Kopia couldn't reach " + c.host + " (no answer)." }},
  {kind: "locked", test: /unable to acquire lock|is locked|another (kopia )?process|already running/i, short: "repository locked",
    title: "Another Kopia process is using the repository.",
    next: function() { return "Wait for it to finish, or close the Kopia app, then try again." },
    notice: function() { return "Another Kopia process is using the repository." }},
  {kind: "full", test: /no space left|not enough space|quota exceeded|insufficient space/i, short: "storage full",
    title: "The repository disk is full.",
    next: function(c) { return "Free space on " + c.host + ", or keep fewer old backups, then try again." },
    notice: function(c) { return "The repository disk on " + c.host + " is full." }},
  {kind: "notconnected", test: /not connected|repository not found|unable to open repository|open repository/i, short: "not connected",
    title: "Kopia isn't connected to a repository.",
    next: function() { return "Connect Kopia to its storage, then try again." },
    notice: function() { return "Kopia isn't connected to a repository." }},
  {kind: "source", test: /permission denied|no such file or directory/i, short: "source unreadable",
    title: "Kopia couldn't read part of the source.",
    next: function() { return "Check the source path in Settings exists and is readable, then try again." },
    notice: function() { return "Kopia couldn't read part of the source path." }}
]

function classifyError(journalText, context) {
  var c = Object.assign({host: "the repository host", unit: "kopia-snapshot.service", cadence: "", nextAt: 0, now: 0}, context || {})
  var raw = String(journalText || "")
  var match = null
  for (var i = 0; i < ERROR_CLASSES.length && !match; i++) if (ERROR_CLASSES[i].test.test(raw)) match = ERROR_CLASSES[i]
  var command = "journalctl --user -u " + c.unit
  if (!match) return {kind: "unknown", title: "The last backup failed.", next: "The error isn't one this panel recognises. Open the log to see it.", command: command, short: "failed", notice: "Kopia reported an error."}
  return {kind: match.kind, title: match.title, next: match.next(c), command: command, short: match.short, notice: match.notice(c)}
}

function notificationBody(error, newestGoodStart) {
  return error.notice + (newestGoodStart ? " Last good snapshot was at " + clock(newestGoodStart) + "." : " No good snapshot yet.")
}

function staleBox(cadenceName, timerUnit, unitMissing) {
  if (unitMissing) return {title: "No backup schedule found.",
    next: "There is no service named " + timerUnit.replace(/\.timer$/, ".service") + ". Name the right one in Settings, or set up a systemd timer that runs kopia snapshot create.",
    command: "systemctl --user list-timers"}
  return {title: "The " + (cadenceName ? cadenceName + " " : "") + "backup didn't run.",
    next: "The machine may have been asleep, or the schedule is stopped. Check with the command below, or press Back up now.",
    command: "systemctl --user status " + timerUnit}
}

// ---- bar and progress ------------------------------------------------------

function barText(mode, state, timerNext, newestSnapshot, now) {
  if (state === "unset") return ""
  if (mode === "next") return timerNext > now ? untilShort(timerNext, now) : ""
  if (mode === "last") return newestSnapshot ? clock(newestSnapshot.start) : ""
  return ""
}

function parseProgress(journalText) {
  var lines = String(journalText || "").split("\n"), found = null
  var re = /(\d[\d,]*) hashed \(([^)]+)\), (\d[\d,]*) cached \(([^)]+)\), uploaded ([\d.]+ ?[KMGTP]?i?B)(?:.*?\((\d+(?:\.\d+)?)%\))?/
  for (var i = 0; i < lines.length; i++) { var m = re.exec(lines[i]); if (m) found = m }
  if (!found) return null
  return {hashed: Number(found[1].replace(/,/g, "")), hashedSize: found[2], cached: Number(found[3].replace(/,/g, "")), cachedSize: found[4],
    uploaded: found[5], percent: found[6] === undefined ? null : Math.round(Number(found[6]))}
}

function formatBytes(n) {
  n = num(n)
  if (n < 1e3) return n + " B"
  if (n < 1e6) return Math.round(n / 1e3) + " kB"
  if (n < 1e9) return Math.round(n / 1e6) + " MB"
  if (n < 1e12) return (n / 1e9).toFixed(1) + " GB"
  return (n / 1e12).toFixed(1) + " TB"
}
function formatCount(n) {
  n = num(n)
  if (n >= 1e6) return (n / 1e6).toFixed(2) + " M"
  return String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

// ---- settings --------------------------------------------------------------

var DEFAULT_URL = "http://127.0.0.1:51516"
function unitName(value, fallback, suffix) {
  return typeof value === "string" && value.length <= 120 && /^[A-Za-z0-9_][A-Za-z0-9_.@-]*$/.test(value) && value.slice(-suffix.length) === suffix && value.length > suffix.length ? value : fallback
}
// A path to a file holding the web UI password. "~/" is expanded; anything
// relative is refused. Only the path is saved in shell.json, never the password.
function passwordFile(value, home) {
  if (typeof value !== "string" || value.length > 500 || /[\n\0]/.test(value)) return ""
  if (value.slice(0, 2) === "~/" && home) value = home + value.slice(1)
  return value.charAt(0) === "/" ? value : ""
}

function normalizeSettings(raw, home) {
  raw = raw && typeof raw === "object" ? raw : {}
  // `omarchy bar set` without --json stores strings; accept the exact forms it writes.
  function int(v, d, lo, hi) {
    if (typeof v === "string" && /^-?\d{1,6}$/.test(v)) v = parseInt(v, 10)
    return Number.isInteger(v) ? Math.max(lo, Math.min(hi, v)) : d
  }
  function bool(v, d) { return typeof v === "boolean" ? v : v === "true" ? true : v === "false" ? false : d }
  var url = raw.webUiUrl === undefined ? DEFAULT_URL : raw.webUiUrl
  if (!(typeof url === "string" && url.length <= 500 && /^https?:\/\/[A-Za-z0-9._~:\/?#\[\]@!$&'()*+,;=%-]+$/.test(url))) url = ""
  return {
    barText: ["none", "next", "last"].indexOf(raw.barText) >= 0 ? raw.barText : "none",
    staleHours: int(raw.staleHours, 3, 1, 168),
    sourcePath: typeof raw.sourcePath === "string" && raw.sourcePath.charAt(0) === "/" && raw.sourcePath.length <= 500 ? raw.sourcePath : home,
    serviceUnit: unitName(raw.serviceUnit, "kopia-snapshot.service", ".service"),
    timerUnit: unitName(raw.timerUnit, "kopia-snapshot.timer", ".timer"),
    heatmapDays: int(raw.heatmapDays, 7, 3, 14),
    showBackupNow: bool(raw.showBackupNow, true),
    webUiUrl: url,
    webUiUser: typeof raw.webUiUser === "string" && /^[A-Za-z0-9._@-]{0,64}$/.test(raw.webUiUser) ? raw.webUiUser : "",
    webUiPasswordFile: passwordFile(raw.webUiPasswordFile, home),
    notifyOnFail: bool(raw.notifyOnFail, true),
    notifyOnStale: bool(raw.notifyOnStale, true)
  }
}

function entry(config, id) {
  var layout = config && config.bar && config.bar.layout ? config.bar.layout : {}
  var groups = [layout.left, layout.center, layout.right, config ? config.plugins : []]
  for (var i = 0; i < groups.length; i++) {
    var list = Array.isArray(groups[i]) ? groups[i] : []
    for (var j = 0; j < list.length; j++) if (list[j] && list[j].id === id) return list[j]
  }
  return {}
}
function mergedEntry(existing, settings) { return Object.assign({}, existing, settings) }

// ---- demo data for debugState and screenshots ------------------------------

function demo(mode, now) {
  var top = dayStart(now, -6).getTime(), snapshots = [], id = 0
  var miss = {"1:3": 1, "1:4": 1, "1:5": 1, "3:14": 1}, bad = {"5:2": 1}
  for (var day = 0; day < 7; day++) for (var hour = 0; hour < 24; hour++) {
    var base = dayStart(now, day - 6)
    var start = new Date(base.getFullYear(), base.getMonth(), base.getDate(), hour, 2).getTime()
    if (start > now - 10 * 60000) continue
    if (miss[day + ":" + hour]) continue
    if (mode === "stale" && start > now - 5 * HOUR) continue
    var errors = bad[day + ":" + hour] ? 2 : 0
    snapshots.push({id: "demo" + pad(id++), start: start, end: start + 17000, durationMs: 17000, size: 170282581823 + id * 4096,
      files: 1134585, dirs: 224543, filesAdded: [193, 41, 2][id % 3], bytesAdded: [41e6, 3e6, 2e5][id % 3], errors: errors})
  }
  var last = newest(snapshots)
  var unit = {activeState: "inactive", subState: "dead", result: "success", startedAt: last ? last.start : 0, exitedAt: last ? last.end : 0}
  var journal = "Snapshotting user@desk:/home/user ...\nCreated snapshot with root k00 and ID demo in 17s\n"
  var timer = {nextAt: now + 22 * 60000, lastAt: last ? last.start : 0}
  if (mode === "running") { unit = {activeState: "activating", subState: "start", result: "success", startedAt: now - 11000, exitedAt: 0}; journal = " * 0 hashing, 190 hashed (38 MB), 702113 cached (105 GB), uploaded 38 MB, estimated 170.3 GB (62.0%) 6s left\n" }
  if (mode === "failed") { unit = {activeState: "failed", subState: "failed", result: "exit-code", startedAt: now - 2 * 60000, exitedAt: now - 2 * 60000 + 2000}; journal = "ERROR open repository: error connecting to repository: unable to connect to SFTP server: dial tcp 192.0.2.10:22: connect: connection refused\n" }
  if (mode === "stale") timer = {nextAt: 0, lastAt: last ? last.start : 0}
  return {kopiaPresent: mode !== "unset", snapshots: snapshots, unit: unit, timer: timer, journal: journal,
    repo: {connected: mode !== "unset", type: "sftp", host: "storage", path: "/mnt/user/backups/kopia/desk", capacity: 30997703917568, available: 14870565707776},
    policy: {latest: 3, hourly: 24, daily: 14, weekly: 8, monthly: 12, annual: 2}}
}
