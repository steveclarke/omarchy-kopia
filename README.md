# Kopia Backups

An Omarchy bar widget for [Kopia](https://kopia.io) backups run by a systemd user timer. The icon shows whether the last backup is healthy, running, failed or overdue; the panel shows a seven-day heatmap, sizes, retention and the last snapshots, with a desktop notification when a backup fails.

## Requirements

- Omarchy with the Quattro shell.
- The Kopia CLI connected to a repository (`kopia repository connect ...`).
- A systemd user service that runs `kopia snapshot create <path>` and a timer that starts it. The plugin never runs a backup on its own schedule; it reads what Kopia already did.

## Install

    omarchy plugin add https://github.com/steveclarke/omarchy-kopia --enable

## Settings

Open the panel and press the gear (or `,`):

- Bar text: icon only, time until the next backup, or the last backup time
- Warn after N hours without a backup
- Source path, backup service and schedule unit names
- History days shown in the grid
- Show the Back up now button; web UI address
- Web UI sign-in: a username and the path to a file holding `KOPIA_SERVER_PASSWORD=...` (the same file a systemd `EnvironmentFile=` for `kopia server start` reads). The password is read when the button is pressed and put into the link; only the path is saved in the shell config.
- Notify when a backup fails; notify when a backup is overdue

## Preview

Sample data; the panel follows the active Omarchy theme.

| Dark | Light |
|------|-------|
| ![Kopia Backups in dark mode with sample data](screenshots/kopia-dark.png) | ![Kopia Backups in light mode with sample data](screenshots/kopia-light.png) |

## Remove

    omarchy plugin remove io.github.steveclarke.kopia

## License and dependencies

MIT. Reads the `kopia`, `systemctl` and `journalctl` commands already on the machine; sends alerts with `notify-send`. No network access of its own and nothing runs as root.
