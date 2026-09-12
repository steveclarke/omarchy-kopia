# Copy table

Every user-facing string, from the final QML and Model.js. Rule: a sentence with a next step; no CLI internals outside a command line; state named in plain words.

| State | Element | String | Next step present |
|-------|---------|--------|-------------------|
| healthy | hero | Backups are healthy / LAST BACKUP 38 MIN AGO / Kopia · took 17 s · next in 22 min · hourly to storage | n/a |
| healthy | section | LAST 7 DAYS · ONE SQUARE PER HOUR; legend Backup · Failed · No backup | n/a |
| healthy | stats | Home (or folder name) · Changed since previous · Repository · Keeps | n/a |
| healthy | rows | RECENT BACKUPS; Today 10:02 · 17 s · +193 files · 170.3 GB; All N backups in the web UI / More backups | yes (row opens web UI) |
| healthy | actions | Back up now · Open web UI | yes |
| running | hero | Backing up… / STARTED 11 S AGO / Last backup 59 min ago · took 17 s; Scanned · Uploaded | n/a |
| failed | hero | Last backup failed / FAILED TODAY 11:49 / 2 s after starting · last good backup 49 min ago (11:02) | box below |
| failed | box (refused) | Can't reach the repository. storage refused the SFTP connection. Check it's on, then try again. The hourly timer also retries at 12:15. `journalctl --user -u <unit>` | yes |
| failed | box (key) | The repository server rejected the SSH key. storage wouldn't accept the SSH key. Check the key and the host entry, then try again. | yes |
| failed | box (unreachable) | storage didn't answer. Check the network and that it's up, then try again. | yes |
| failed | box (locked) | Wait for it to finish, or close the Kopia app, then try again. | yes |
| failed | box (full) | Free space on storage, or keep fewer old backups, then try again. | yes |
| failed | box (not connected) | Connect Kopia to its storage, then try again. | yes |
| failed | box (source) | Check the source path in Settings exists and is readable, then try again. | yes |
| failed | box (unknown) | The last backup failed. The error isn't one this panel recognises. Open the log to see it. | yes |
| failed | row | ✗ Today 11:49 · couldn't reach storage · failed | yes (enter opens log) |
| failed | actions | Try again now · Open log | yes |
| failed | notification | Backup failed: Kopia couldn't reach storage (SFTP connection refused). Last good backup was at 11:02. [Open log] [Try again] | yes |
| stale | hero | No backup for 5 hours / LAST BACKUP TODAY 06:02 / Runs hourly · nothing has run since | box below |
| stale | box | The hourly backup didn't run. The machine may have been asleep, or the schedule is stopped. Check with the command below, or press Back up now. `systemctl --user status <timer>` | yes |
| stale | box (no unit) | No backup schedule found. There is no service named X. Name the right one in Settings, or set up a systemd timer that runs kopia snapshot create. `systemctl --user list-timers` | yes |
| stale | notification | Backup overdue: No backup for 5 hours. The timer hasn't run since Today 06:02. | yes |
| unset | hero | Kopia isn't connected / NO BACKUP STORAGE CONNECTED (or KOPIA ISN'T INSTALLED) / Kopia has no repository to read (or The kopia command isn't installed) | steps below |
| unset | body | Install Kopia and connect a repository; the panel fills in on its own. 1 omarchy-pkg-aur-add kopia-bin · 2 kopia repository connect sftp … · 3 Set the source path in Settings if it isn't your home folder | yes |
| unset | actions | Check again · Settings | yes |
| settings | hero | Backup widget settings / SAVED AS YOU CHANGE THEM | n/a |
| settings | rows | Bar text · Warn after (hours) · Source path · Backup service · Backup schedule · History · Show the Back up now button · Web UI address · Notify when a backup fails · Notify when a backup is overdue | help line each |
| settings | error | Could not save this change. Try again. | yes |
| any | footer | j/k · enter web UI (log) · s back up · , settings | n/a |
