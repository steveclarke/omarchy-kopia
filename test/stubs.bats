#!/usr/bin/env bats

setup() {
  export PATH="$BATS_TEST_DIRNAME/stub:$PATH"
  export KOPIA_STUB_FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  export KOPIA_STUB_LOG="$BATS_TEST_TMPDIR/log"
  export KOPIA_STUB_MODE=healthy
}

@test "kopia snapshot list returns the healthy fixture" {
  run kopia snapshot list /home/user --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d)==2 and d[-1]["source"]["host"]=="desk"'
}

@test "failed mode returns a newest snapshot with errors" {
  KOPIA_STUB_MODE=failed run kopia snapshot list /home/user --json
  echo "$output" | python3 -c 'import json,sys; assert json.load(sys.stdin)[-1]["stats"]["errorCount"]==3'
}

@test "missing-repo mode exits 1 like a disconnected kopia" {
  KOPIA_STUB_MODE=missing-repo run kopia repository status --json
  [ "$status" -eq 1 ]
}

@test "systemctl show follows the mode" {
  run systemctl --user show kopia-snapshot.service -p ActiveState,SubState,Result,ExecMainStartTimestamp,ExecMainExitTimestamp --timestamp=unix
  [[ "$output" == *"ActiveState=inactive"* ]]
  KOPIA_STUB_MODE=failed run systemctl --user show kopia-snapshot.service -p ActiveState --timestamp=unix
  [[ "$output" == *"Result=exit-code"* ]]
}

@test "systemctl start is recorded, not executed" {
  run systemctl --user start kopia-snapshot.service
  [ "$status" -eq 0 ]
  grep -q '"start"' "$KOPIA_STUB_LOG"
}

@test "notify-send records its arguments and replies only when told" {
  run notify-send -u critical -a "Kopia Backups" -A open="Open log" "Backup failed" "body"
  [ "$output" = "" ]
  grep -q '"Backup failed"' "$KOPIA_STUB_LOG"
  KOPIA_STUB_NOTIFY_REPLY=open run notify-send "x"
  [ "$output" = "open" ]
}

@test "no fixture carries a real name" {
  # Only the stand-ins may appear: user "user", host "desk", repository host "storage".
  # Assert on captured output: under bats `! cmd` never fails a test (set -e ignores negations).
  local f="$BATS_TEST_DIRNAME/fixtures"
  [ -z "$(grep -rE '/home/[a-z]+' "$f" | grep -v '/home/user')" ]
  [ -z "$(grep -rEi '[a-z0-9-]+\.(home|local|lan)\b' "$f")" ]
  [ -z "$(grep -rF "$(id -un)" "$f" | grep -v user)" ]
  [ -z "$(grep -rF "$(hostname)" "$f" | grep -v desk)" ]
}
