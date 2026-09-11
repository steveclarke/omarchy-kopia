# Kopia Backups - agent rules

Omarchy 4 plugin: `Service.qml` polls, `BarWidget.qml` shows, `Panel.qml` explains. Plugin id `io.github.steveclarke.kopia` is permanent.

## Never write to the repository

The plugin only reads: `kopia snapshot list`, `kopia repository status`, `kopia policy show`, `systemctl --user show`, `systemctl --user list-timers`, `journalctl --user`. The only write is `systemctl --user start <unit>` behind the user's "Back up now" click. Nothing runs as root; the word for privilege escalation must not appear anywhere in the repo, this file included (the marketplace scanner flags the token).

## Gates, before every commit

    bin/check

That runs the node tests, bats, `omarchy plugin validate .`, `tools/lint-qml` and `test/check-qml`. GitHub CI runs only the node and bats parts (no Omarchy shell there), so the QML gates are local. Use `tools/lint-qml`, not bare qmllint: it cannot resolve `qs.*` from the shell root and skips `[required]` inside any Repeater. A new regression test must be shown failing first.

## Verify UI yourself

`omarchy-shell shell toggle io.github.steveclarke.kopia`, `omarchy-shell kopia debugState failed|stale|running|unset|healthy|off`, then `grim -g "<geometry>"` from `omarchy-shell shell debugBarGeometry` and look. Then `journalctl --user -b | grep -E "Plugin widget|Required property|Binding loop"`. `IpcHandler ... another handler is registered` is benign (one bar per monitor).

## Install model

`~/.config/omarchy/plugins/io.github.steveclarke.kopia/` is a git clone, not a link. Commit, push, `omarchy plugin update`, `omarchy-restart-shell` after a manifest, glyph or IPC change.

## Public repo

No hostnames, usernames, paths, repository ids or LAN addresses in files, fixtures, screenshots or history. Stand-ins: host `desk`, user `user`, path `/home/user`, repository host `storage`.

Never file the marketplace submission; the owner does that. No AI attribution in commits. `master`, not `main`.
