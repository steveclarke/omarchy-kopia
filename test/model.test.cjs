process.env.TZ = 'America/St_Johns'
const assert = require('node:assert')  // loose: Model.js runs in a vm realm, so its objects have a foreign prototype
const {readFileSync} = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const test = require('node:test')

const M = vm.createContext({})
vm.runInContext(readFileSync(path.join(__dirname, '..', 'Model.js'), 'utf8'), M)
const fx = name => readFileSync(path.join(__dirname, 'fixtures', name), 'utf8')

const HOUR = 3600000
// 2026-09-11 11:38 NDT: 38 min after the newest healthy fixture snapshot (11:00 NDT).
const now = Date.parse('2026-09-11T14:08:00Z')
const healthy = M.parseSnapshots(fx('snapshots-healthy.json'))
const failed = M.parseSnapshots(fx('snapshots-failed.json'))
const idle = M.parseUnit(fx('unit-idle.txt'))
const running = M.parseUnit(fx('unit-running.txt'))
const broken = M.parseUnit(fx('unit-failed.txt'))
const ctx = {host: 'storage', unit: 'kopia-snapshot.service', cadence: 'hourly', nextAt: Date.parse('2026-09-11T14:32:46Z'), now}

test('parseSnapshots maps the kopia fields and sorts ascending', () => {
  assert.equal(healthy.length, 2)
  const s = healthy[1]
  assert.equal(s.id, 'fedcba9876543210fedcba9876543210')
  assert.equal(s.start, Date.parse('2026-09-11T13:30:33.705Z'))
  assert.equal(s.durationMs, 17247)
  assert.equal(s.size, 170297003705)
  assert.equal(s.files, 1134585)
  assert.equal(s.dirs, 224543)
  assert.equal(s.filesAdded, 509)
  assert.equal(s.bytesAdded, 170297003705 - 170282581823)
  assert.equal(s.errors, 0)
  assert.equal(healthy[0].bytesAdded, 0)
  assert.ok(healthy[0].start < healthy[1].start)
})
test('parseSnapshots rejects garbage without throwing', () => {
  assert.deepEqual(M.parseSnapshots('not json'), [])
  assert.deepEqual(M.parseSnapshots('{"a":1}'), [])
  assert.deepEqual(M.parseSnapshots('[{"startTime":"nope"},7,null]'), [])
})
test('errors come from errorCount and numFailed, whichever is larger', () => {
  assert.equal(failed[2].errors, 3)
})
test('parseUnit reads unix timestamps and empty ones', () => {
  assert.deepEqual(idle, {loadState: 'loaded', activeState: 'inactive', subState: 'dead', result: 'success', startedAt: 1789133433000, exitedAt: 1789133451000})
  assert.equal(broken.result, 'exit-code')
  assert.equal(broken.exitedAt - broken.startedAt, 2000)
  assert.equal(running.exitedAt, 0)
  assert.equal(M.parseUnit('ActiveState=inactive\nExecMainStartTimestamp=\n').startedAt, 0)
  assert.equal(M.parseUnit('').activeState, '')
})
test('parseTimers converts microseconds and tolerates an empty list', () => {
  assert.deepEqual(M.parseTimers(fx('timers.json')), {nextAt: 1789137166673, lastAt: 1789133433185})
  assert.deepEqual(M.parseTimers(fx('timers-none.json')), {nextAt: 0, lastAt: 0})
  assert.deepEqual(M.parseTimers('garbage'), {nextAt: 0, lastAt: 0})
})
test('parseRepoStatus names the sftp host and free space', () => {
  const r = M.parseRepoStatus(fx('repo-status.json'))
  assert.equal(r.connected, true)
  assert.equal(r.type, 'sftp')
  assert.equal(r.host, 'storage')
  assert.equal(r.available, 14870565707776)
  assert.equal(M.parseRepoStatus('').connected, false)
  assert.equal(M.parseRepoStatus('{"storage":{"type":"filesystem","config":{"path":"/mnt/backup"}}}').host, 'this computer')
  assert.equal(M.parseRepoStatus('{"storage":{"type":"b2","config":{"bucket":"mybucket"}}}').host, 'b2 mybucket')
})
test('parsePolicy and retentionText follow the design (four tiers)', () => {
  const p = M.parsePolicy(fx('policy.json'))
  assert.equal(p.hourly, 24); assert.equal(p.annual, 2)
  assert.equal(M.retentionText(p), '24 hourly · 14 daily · 8 weekly · 12 monthly')
  assert.equal(M.retentionText(M.parsePolicy('{}')), '')
  assert.equal(M.retentionText({hourly: 0, daily: 7, weekly: 0, monthly: 0}), '7 daily')
})
test('computeState orders unset, running, failed, stale, healthy', () => {
  const base = {snapshots: healthy, unit: idle, now, staleHours: 3, kopiaPresent: true}
  assert.equal(M.computeState(base), 'healthy')
  assert.equal(M.computeState({...base, kopiaPresent: false}), 'unset')
  assert.equal(M.computeState({...base, unit: running}), 'running')
  assert.equal(M.computeState({...base, unit: broken}), 'failed')
  assert.equal(M.computeState({...base, snapshots: failed}), 'failed')
  assert.equal(M.computeState({...base, now: now + 3 * HOUR + 1}), 'stale')
  assert.equal(M.computeState({...base, now: healthy[1].start + 3 * HOUR - 60000}), 'healthy')
  assert.equal(M.computeState({...base, snapshots: []}), 'stale')
  assert.equal(M.computeState({...base, unit: null}), 'healthy')
  // running beats failed: a retry in progress is not a failure yet.
  assert.equal(M.computeState({...base, snapshots: failed, unit: running}), 'running')
})
test('newestGood skips snapshots with errors', () => {
  assert.equal(M.newest(failed).id, '00000000000000000000000000000bad')
  assert.equal(M.newestGood(failed).id, 'fedcba9876543210fedcba9876543210')
  assert.equal(M.newestGood([]), null)
})
test('heatmap buckets by local hour, marks future, now, miss and failures', () => {
  const cells = M.heatmap(healthy, now, 7, 0)
  assert.equal(cells.length, 7 * 24)
  const todayOk = cells.filter(c => c.day === 6 && c.status === 'ok').map(c => c.hour)
  assert.deepEqual(todayOk, [10, 11])                       // 12:33Z and 13:30Z are 10:03 and 11:00 NDT
  assert.equal(cells.find(c => c.day === 6 && c.hour === 11).current, true)
  assert.equal(cells.find(c => c.day === 6 && c.hour === 12).status, 'future')
  assert.equal(cells.find(c => c.day === 6 && c.hour === 9).status, 'miss')
  assert.equal(cells.find(c => c.day === 0 && c.hour === 0).label, 'Sat')
  assert.equal(cells.find(c => c.day === 6 && c.hour === 0).label, 'Fri')
  const empty = M.heatmap([], now, 7, 0)
  assert.equal(empty.find(c => c.day === 6 && c.hour === 11).status, 'now')
  const withFailure = M.heatmap(healthy, now, 7, now - 5 * 60000)
  assert.equal(withFailure.find(c => c.day === 6 && c.hour === 11).status, 'bad')
  assert.equal(M.heatmap(failed, now + HOUR, 7, 0).find(c => c.day === 6 && c.hour === 11).status, 'bad')
})
test('heatmapRows is the same data shaped for a Column of Rows', () => {
  const rows = M.heatmapRows(healthy, now, 3, 0)
  assert.equal(rows.length, 3)
  assert.deepEqual(rows.map(r => r.label), ['Wed', 'Thu', 'Fri'])
  assert.equal(rows[2].cells.length, 24)
})
test('relative time strings match the design', () => {
  assert.equal(M.relativeTime(now - 11000, now), '11 s ago')
  assert.equal(M.relativeTime(now - 38 * 60000, now), '38 min ago')
  assert.equal(M.relativeTime(now - (HOUR + 38 * 60000), now), '1 h 38 min ago')
  assert.equal(M.relativeTime(now - 2 * HOUR, now), '2 h ago')
  assert.equal(M.relativeTime(now - 49 * HOUR, now), '2 days ago')
  assert.equal(M.relativeTime(now + 5000, now), '0 s ago')
})
test('duration, until and clock', () => {
  assert.equal(M.duration(17247), '17 s')
  assert.equal(M.duration(65000), '1 min 5 s')
  assert.equal(M.duration(2 * HOUR + 5 * 60000), '2 h 5 min')
  assert.equal(M.duration(300), 'under 1 s')
  assert.equal(M.until(now + 22 * 60000, now), '22 min')
  assert.equal(M.until(now + HOUR + 5 * 60000, now), '1 h 5 min')
  assert.equal(M.until(now - 1, now), 'now')
  assert.equal(M.untilShort(now + 22 * 60000, now), '22m')
  assert.equal(M.untilShort(now + HOUR + 5 * 60000, now), '1h 5m')
  assert.equal(M.untilShort(now + 3 * 24 * HOUR, now), '3d')
  assert.equal(M.clock(healthy[0].start), '10:03')
  assert.equal(M.clock(Date.parse('2026-09-11T12:32:00Z')), '10:02')
})
test('dayClock names today, yesterday, weekday, then date', () => {
  assert.equal(M.dayClock(healthy[1].start, now), 'Today 11:00')
  assert.equal(M.dayClock(now - 24 * HOUR, now), 'Yesterday 11:38')
  assert.equal(M.dayClock(now - 2 * 24 * HOUR, now), 'Wed 11:38')
  assert.equal(M.dayClock(now - 10 * 24 * HOUR, now), 'Sep 1 11:38')
})
test('staleTitle counts hours then days', () => {
  assert.equal(M.staleTitle(now - 5 * HOUR - 60000, now), 'No backup for 5 hours')
  assert.equal(M.staleTitle(now - HOUR - 1, now), 'No backup for 1 hour')
  assert.equal(M.staleTitle(now - 72 * HOUR, now), 'No backup for 3 days')
  assert.equal(M.staleTitle(0, now), 'No backup yet')
})
test('cadence from the median gap', () => {
  const hourly = [0, 1, 2, 3, 4, 5].map(i => ({start: now - i * HOUR, errors: 0})).reverse()
  assert.equal(M.cadence(hourly), 'hourly')
  const daily = [0, 1, 2, 3].map(i => ({start: now - i * 24 * HOUR, errors: 0})).reverse()
  assert.equal(M.cadence(daily), 'daily')
  assert.equal(M.cadence(healthy), '')                     // two points is not a pattern
})
test('classifyError maps the known classes to a sentence with a next step', () => {
  const e = M.classifyError(fx('journal-refused.txt'), ctx)
  assert.equal(e.kind, 'refused')
  assert.equal(e.title, "Can't reach the repository.")
  assert.equal(e.next, 'storage refused the SFTP connection. Check that storage is on, then try again; the hourly timer will also retry on its own at 12:02.')
  assert.equal(e.command, 'journalctl --user -u kopia-snapshot.service')
  assert.equal(e.short, "couldn't reach storage")
  assert.equal(e.notice, "Kopia couldn't reach storage (SFTP connection refused).")
  assert.equal(M.classifyError('ssh: handshake failed: ssh: unable to authenticate', ctx).kind, 'key')
  assert.equal(M.classifyError('dial tcp 192.0.2.10:22: i/o timeout', ctx).kind, 'unreachable')
  assert.equal(M.classifyError('error: unable to acquire lock: repository is locked', ctx).kind, 'locked')
  assert.equal(M.classifyError('write /mnt/x: no space left on device', ctx).kind, 'full')
  assert.equal(M.classifyError('ERROR open repository: repository is not connected', ctx).kind, 'notconnected')
  assert.equal(M.classifyError('error reading /home/user/x: permission denied', ctx).kind, 'source')
  const u = M.classifyError(fx('journal-ok.txt'), ctx)
  assert.equal(u.kind, 'unknown')
  assert.equal(u.title, 'The last backup failed.')
  assert.equal(M.classifyError('', {}).command, 'journalctl --user -u kopia-snapshot.service')
  assert.equal(M.classifyError(fx('journal-refused.txt'), {host: 'storage', unit: 'x.service'}).next,
    'storage refused the SFTP connection. Check that storage is on, then try again; the timer will also retry on its own.')
})
test('notificationBody and staleBox', () => {
  const e = M.classifyError(fx('journal-refused.txt'), ctx)
  assert.equal(M.notificationBody(e, healthy[1].start), "Kopia couldn't reach storage (SFTP connection refused). Last good snapshot was at 11:00.")
  assert.equal(M.notificationBody(e, 0), "Kopia couldn't reach storage (SFTP connection refused). No good snapshot yet.")
  assert.deepEqual(M.staleBox('hourly', 'kopia-snapshot.timer'), {
    title: "The hourly backup didn't run.",
    next: 'The machine may have been asleep, or the schedule is stopped. Run the command below to check, or press Back up now.',
    command: 'systemctl --user status kopia-snapshot.timer'})
  assert.equal(M.staleBox('', 'kopia-snapshot.timer').title, "The backup didn't run.")
  const missing = M.staleBox('hourly', 'kopia-snapshot.timer', true)
  assert.equal(missing.title, 'No backup schedule found.'); assert.ok(missing.next.includes('kopia-snapshot.service'))
  assert.equal(M.parseUnit('LoadState=not-found\nActiveState=inactive\n').loadState, 'not-found')
})
test('barText is empty by default and never shows in unset', () => {
  const next = now + 22 * 60000
  assert.equal(M.barText('none', 'healthy', next, healthy[1], now), '')
  assert.equal(M.barText('next', 'healthy', next, healthy[1], now), '22m')
  assert.equal(M.barText('next', 'healthy', 0, healthy[1], now), '')
  assert.equal(M.barText('last', 'healthy', next, healthy[1], now), '11:00')
  assert.equal(M.barText('last', 'failed', next, null, now), '')
  assert.equal(M.barText('next', 'unset', next, healthy[1], now), '')
})
test('parseProgress reads the kopia counter line and is null without one', () => {
  assert.deepEqual(M.parseProgress(fx('journal-progress.txt')), {hashed: 190, hashedSize: '38 MB', cached: 702113, cachedSize: '105 GB', uploaded: '38 MB', percent: 62})
  assert.equal(M.parseProgress(fx('journal-ok.txt')), null)
  assert.equal(M.parseProgress(' * 1 hashing, 5 hashed (1 MB), 10 cached (2 MB), uploaded 1 MB, estimating...').percent, null)
})
test('formatBytes and formatCount match the design', () => {
  assert.equal(M.formatBytes(170282581823), '170.3 GB')
  assert.equal(M.formatBytes(14870565707776), '14.9 TB')
  assert.equal(M.formatBytes(41 * 1e6), '41 MB')
  assert.equal(M.formatBytes(900), '900 B')
  assert.equal(M.formatBytes(12345), '12 kB')
  assert.equal(M.formatCount(1134585), '1.13 M')
  assert.equal(M.formatCount(702113), '702,113')
  assert.equal(M.formatCount(193), '193')
})
test('normalizeSettings fills defaults and rejects unsafe values', () => {
  const d = M.normalizeSettings({}, '/home/user')
  assert.deepEqual(d, {barText: 'none', staleHours: 3, sourcePath: '/home/user', serviceUnit: 'kopia-snapshot.service', timerUnit: 'kopia-snapshot.timer',
    heatmapDays: 7, showBackupNow: true, webUiUrl: 'http://127.0.0.1:51516', webUiUser: '', webUiPasswordFile: '', notifyOnFail: true, notifyOnStale: true})
  const s = M.normalizeSettings({barText: 'next', staleHours: 999, heatmapDays: 1, serviceUnit: 'x; rm -rf /', timerUnit: 'mine.timer', webUiUrl: 'javascript:alert(1)', sourcePath: 'relative', showBackupNow: false}, '/home/user')
  assert.equal(s.barText, 'next'); assert.equal(s.staleHours, 168); assert.equal(s.heatmapDays, 3)
  assert.equal(s.serviceUnit, 'kopia-snapshot.service'); assert.equal(s.timerUnit, 'mine.timer')
  assert.equal(s.webUiUrl, ''); assert.equal(s.sourcePath, '/home/user'); assert.equal(s.showBackupNow, false)
  assert.equal(M.normalizeSettings({webUiUrl: ''}, '/h').webUiUrl, '')
  // `omarchy bar set` without --json stores strings; the CLI must still work.
  const c = M.normalizeSettings({staleHours: '6', heatmapDays: '10', notifyOnStale: 'false', showBackupNow: 'true'}, '/h')
  assert.equal(c.staleHours, 6); assert.equal(c.heatmapDays, 10); assert.equal(c.notifyOnStale, false); assert.equal(c.showBackupNow, true)
  assert.equal(M.normalizeSettings({staleHours: '6x'}, '/h').staleHours, 3)
  assert.equal(M.normalizeSettings({webUiUrl: 'https://backup.example/ui?x=1'}, '/h').webUiUrl, 'https://backup.example/ui?x=1')
})
test('entry finds the widget in any bar section and mergedEntry keeps other keys', () => {
  const config = {bar: {layout: {left: [], center: [{id: 'other'}], right: [{id: 'io.github.steveclarke.kopia', enabled: true, staleHours: 6}]}}}
  assert.equal(M.entry(config, 'io.github.steveclarke.kopia').staleHours, 6)
  assert.deepEqual(M.entry({}, 'io.github.steveclarke.kopia'), {})
  const merged = M.mergedEntry({id: 'io.github.steveclarke.kopia', enabled: true, keep: 1}, {staleHours: 4})
  assert.deepEqual(merged, {id: 'io.github.steveclarke.kopia', enabled: true, keep: 1, staleHours: 4})
})
test('demo produces each state from stand-in data', () => {
  for (const mode of ['healthy', 'running', 'failed', 'stale', 'unset']) {
    const d = M.demo(mode, now)
    assert.equal(M.computeState({snapshots: d.snapshots, unit: d.unit, now, staleHours: 3, kopiaPresent: d.kopiaPresent}), mode, mode)
    assert.ok(!JSON.stringify(d).includes('steve'), 'no personal names in demo data')
  }
  assert.equal(M.demo('healthy', now).repo.host, 'storage')
  assert.equal(M.classifyError(M.demo('failed', now).journal, ctx).kind, 'refused')
  assert.ok(M.parseProgress(M.demo('running', now).journal))
})

test('web UI sign-in settings: username and password file are validated', () => {
  const ok = M.normalizeSettings({webUiUser: 'user', webUiPasswordFile: '~/.config/kopia/ui.env'}, '/home/user')
  assert.equal(ok.webUiUser, 'user')
  assert.equal(ok.webUiPasswordFile, '/home/user/.config/kopia/ui.env')
  assert.equal(M.normalizeSettings({webUiPasswordFile: '/etc/kopia.env'}, '/h').webUiPasswordFile, '/etc/kopia.env')
  assert.equal(M.normalizeSettings({webUiPasswordFile: 'relative/ui.env'}, '/h').webUiPasswordFile, '')
  assert.equal(M.normalizeSettings({webUiUser: 'a b'}, '/h').webUiUser, '')
  assert.equal(M.normalizeSettings({webUiUser: 'x:y'}, '/h').webUiUser, '')
})
test('webUiLink reads the password from the env file and signs the address', () => {
  const url = 'http://127.0.0.1:51516'
  assert.equal(M.webUiLink(url, 'user', 'KOPIA_SERVER_PASSWORD=s3cret\n'), 'http://user:s3cret@127.0.0.1:51516/')
  assert.equal(M.webUiLink(url, 'user', '# comment\nOTHER=1\nKOPIA_SERVER_PASSWORD="p@ss word"\n'), 'http://user:p%40ss%20word@127.0.0.1:51516/')
  assert.equal(M.webUiLink(url, 'user', "KOPIA_SERVER_PASSWORD='single'\n"), 'http://user:single@127.0.0.1:51516/')
  assert.equal(M.webUiLink(url, 'user', 'justapassword\n'), 'http://user:justapassword@127.0.0.1:51516/')
  assert.equal(M.webUiLink('https://backup.example/ui?x=1', 'u', 'KOPIA_SERVER_PASSWORD=p'), 'https://u:p@backup.example/ui?x=1')
  // Anything missing means the plain address, so the browser asks as it does today.
  assert.equal(M.webUiLink(url, '', 'KOPIA_SERVER_PASSWORD=p'), url)
  assert.equal(M.webUiLink(url, 'user', ''), url)
  assert.equal(M.webUiLink(url, 'user', 'A=1\nB=2\n'), url)
  assert.equal(M.webUiLink('', 'user', 'KOPIA_SERVER_PASSWORD=p'), '')
  // An address that already carries credentials is left alone.
  assert.equal(M.webUiLink('http://a:b@127.0.0.1:51516', 'user', 'KOPIA_SERVER_PASSWORD=p'), 'http://a:b@127.0.0.1:51516')
})

test('text from kopia or errors is made safe for host-rendered sinks', () => {
  const repo = M.parseRepoStatus(JSON.stringify({storage: {type: 'sftp', config: {host: 'nas<img src=http://x/>&"'}}, volume: {}}))
  assert.equal(repo.host, 'nasimg srchttp://x/')
  const bell = String.fromCharCode(7), rlo = String.fromCharCode(0x202e)
  assert.equal(M.plain('a <b>bold</b> & ' + bell + 'bell' + rlo), 'a bbold/b  bell')
  assert.equal(M.plain('x'.repeat(400)).length, 300)
})
