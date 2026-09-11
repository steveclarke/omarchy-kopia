### Repository URL

https://github.com/steveclarke/omarchy-kopia

### Category

System

### Tags

bar, quickshell, system

### Suggest a missing tag

backup

### Maintainer notes

Plugin id `io.github.steveclarke.kopia`, version 0.1.0, MIT. A bar widget plus a headless service that shows whether Kopia's scheduled backups are healthy, running, failed or overdue, with a seven-day heatmap and a critical notification when a backup fails. It only reads: `kopia snapshot list`, `kopia repository status`, `kopia policy show`, `systemctl --user show`, `systemctl --user list-timers`, `journalctl --user`. The single write is `systemctl --user start <unit>` behind the user's "Back up now" click. "Open web UI" runs `xdg-open`. If the user sets a web UI username and password file, `bin/kopia-web-signin` (stdlib Python, run as `/usr/bin/python3 -I -S`) opens the file once with O_NOFOLLOW on every path component, requires a 0600 regular file owned by the user, writes a one-use 0600 redirect page into a verified 0700 folder under `$XDG_RUNTIME_DIR`, passes only that page path to `xdg-open`, and deletes it after 20 s. The password never appears in argv or the environment; only the file path is stored in the shell config. Contributor guidance lives in `docs/CONTRIBUTING.md`; `tools/check-agent-files` keeps agent-instruction files out of the tree in local checks and CI. Nothing runs as root, there is no installer file, and no external code is fetched.

### Submission checklist

- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.
