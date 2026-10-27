#!/bin/sh
# Test: `image-bump deploy` -- preconditions, export, keep, install, checks, rollback.
#
# `podman` is a stub first on PATH: it logs its argv to a file and answers `inspect`, `image
# exists` and `machine ssh ...` from fixture files, and a `machine ssh cp <kept unit> <unit>` (a
# restore) makes the stub service healthy again, as the real one would. The descriptor's checks
# and install script are tiny scripts that append a line to the same log, so ORDER is assertable.
# Nothing reaches a VM or the network. Services and registries are invented.
#
# Overrides: IMAGE_BUMP_BIN (the executable under test), PYTHON (the interpreter).
# Run: sh tests/test-image-bump-deploy.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
BIN=${IMAGE_BUMP_BIN:-$here/../private_dot_local/bin/executable_image-bump}
PY=$(command -v "${PYTHON:-python3}") || { echo "FAIL: python3 is required"; exit 1; }
[ -f "$BIN" ] || { echo "FAIL: no image-bump at $BIN"; exit 1; }

t=${TMPDIR:-/tmp}; t=${t%/}
w=$(mktemp -d "$t/image-bump-deploy.XXXXXX") || exit 1
trap 'rm -rf "${w:?}"' EXIT
HOME="$w/home"; export HOME; mkdir -p "$HOME"
XDG_STATE_HOME="$w/state"; export XDG_STATE_HOME
unset IMAGE_BUMP_ROOT IMAGE_BUMP_SOURCE_ROOT

fail=0
ok() { printf '  ok    %s\n' "$1"; }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
rc() { cat "$w/rc"; }
# expect <name> <status> [<text expected in stdout or stderr>]
expect() {
  name=$1; want=$2; text=${3:-}
  got=$(rc)
  if [ "$got" != "$want" ]; then no "$name (status $got, wanted $want; output: $(cat "$w/out" "$w/err"))"; return; fi
  if [ -n "$text" ] && ! cat "$w/out" "$w/err" | grep -qF -- "$text"; then
    no "$name (no '$text' in output: $(cat "$w/out" "$w/err"))"; return
  fi
  ok "$name"
}
logged() { if grep -Eq -- "$2" "$w/log"; then ok "$1"; else no "$1 (no /$2/ in stub log: $(cat "$w/log"))"; fi; }
unlogged() { if grep -Eq -- "$2" "$w/log"; then no "$1 (/$2/ in stub log: $(cat "$w/log"))"; else ok "$1"; fi; }
# first <regex>: the line number of the first log line matching, or empty
first() { grep -nE -- "$1" "$w/log" | head -1 | cut -d: -f1; }
last() { grep -nE -- "$1" "$w/log" | tail -1 | cut -d: -f1; }
# before <name> <regex-a> <regex-b>: the first match of a comes before the first match of b
before() {
  a=$(first "$2"); b=$(first "$3")
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok "$1"
  else no "$1 (/$2/ at '${a:-none}', /$3/ at '${b:-none}'; log: $(cat "$w/log"))"; fi
}
count() { grep -Ec -- "$1" "$w/log"; }

# ---------- the stubs ----------
S="$w/stubs"; mkdir -p "$S"
cat > "$S/podman" <<'EOF'
#!/bin/sh
echo "podman $*" >> "$STUB_LOG"
case "$1" in
  inspect) cat "$FX/running"; exit 0 ;;
  image) [ "$2" = exists ] && exit "$(cat "$FX/exists")" ;;
  volume) exit 0 ;;
  machine)
    shift 2
    if [ "$1" = cp ]; then case "$2" in *.pre-*) echo up > "$FX/health" ;; esac; fi
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$S/podman"
FX="$w/fx"; STUB_LOG="$w/log"; export FX STUB_LOG
PATH="$S:$PATH"; export PATH

IMG=registry.invalid/acme/widget
D0=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef   # running, replaced
DA=sha256:$(printf 'aa%.0s' $(seq 32))   # the applied pin
DX=sha256:$(printf 'dd%.0s' $(seq 32))   # some other digest
VMU=/vm/units/widget.container

# scenario: a fresh descriptor, pin, record, checks and fixtures. The variables MIG (yes|no),
# INSTALL (vm-copy|script), HEALTH (up|down), RUNNING (digest), EXISTS (0|1), ROLLED (a digest to
# list as rolled back), NORECORD and FLAKY tune it for one call and are cleared at its end.
scenario() {
  rm -rf "${w:?}/root" "${FX:?}" "${w:?}/state" "${w:?}/home"; mkdir -p "$HOME"; : > "$STUB_LOG"
  mkdir -p "$w/root/svc/scans" "$FX"
  d="$w/root/svc"
  printf '%s:v1.3.0-rootless@%s\n' "$IMG" "$DA" > "$d/IMAGE"
  printf '%s@%s\n' "$IMG" "${RUNNING:-$D0}" > "$FX/running"
  echo "${EXISTS:-0}" > "$FX/exists"
  echo "${HEALTH:-up}" > "$FX/health"
  echo 0 > "$FX/install-rc"; echo 0 > "$FX/flaky-count"
  if [ "${INSTALL:-vm-copy}" = script ]; then
    install='{"kind": "script", "path": "install.sh"}'
  else
    install='{"kind": "vm-copy", "applied_unit": "widget.container"}'
  fi
  echo '[Container]' > "$d/widget.container"
  cat > "$d/install.sh" <<EOF
#!/bin/sh
echo "install-script" >> "$STUB_LOG"
exit "\$(cat "$FX/install-rc")"
EOF
  cat > "$d/check-health" <<EOF
#!/bin/sh
echo "check health" >> "$STUB_LOG"
[ "\$(cat "$FX/health")" = up ]
EOF
  cat > "$d/check-flaky" <<EOF
#!/bin/sh
echo "check flaky" >> "$STUB_LOG"
n=\$(cat "$FX/flaky-count"); echo \$((n + 1)) > "$FX/flaky-count"
[ "\$n" -ge 1 ]
EOF
  chmod +x "$d/install.sh" "$d/check-health" "$d/check-flaky"
  if [ -n "${FLAKY:-}" ]; then checks="[{\"name\": \"flaky\", \"command\": [\"$d/check-flaky\"], \"pass\": \"exit 0\"}]"
  else checks="[{\"name\": \"health\", \"command\": [\"$d/check-health\"], \"pass\": \"exit 0\"}]"; fi
  cat > "$d/image_bump.py" <<PYEOF
image = "$IMG"
release_line = "patch-of-pinned-major"
release_api = {"host": "github", "repo": "acme/widget"}
git_tag = "v{version}"
platform = "linux/arm64"
pin_file = "IMAGE"
scan_dir = "scans"
gate = {"kind": "fixable-count-floor"}
migrations = {"kind": "always"}
volume = "widget-data"
container = "widget"
service = "widget.service"
vm_unit = "$VMU"
install = $install
checks = $checks
checklist = ["read the release notes"]
tag_suffix = "-rootless"
PYEOF
  if [ -z "${NORECORD:-}" ]; then
    {
      echo "widget image CVE scan record"
      echo "image: $IMG:v1.3.0-rootless"
      echo "digest: $DA"
      echo "platform: linux/arm64"
      echo "replaces: $D0"
      echo "verdict: pass"
      echo "migrates: ${MIG:-no}"
      echo
      echo "New image findings: none"
    } > "$d/scans/widget-1.3.0-2026-10-27.txt"
    # an older record for another digest, which must not be picked
    sed "s/^digest: .*/digest: $DX/; s/^migrates: .*/migrates: yes/" "$d/scans/widget-1.3.0-2026-10-27.txt" > "$d/scans/widget-1.2.9-2026-10-01.txt"
  fi
  if [ -n "${ROLLED:-}" ]; then mkdir -p "$w/state/image-bump"; echo "$ROLLED" > "$w/state/image-bump/svc.rolled-back"; fi
  MIG=; INSTALL=; HEALTH=; RUNNING=; EXISTS=; ROLLED=; NORECORD=; FLAKY=
}
go() { "$PY" "$BIN" deploy svc --root "$w/root" "$@" >"$w/out" 2>"$w/err"; echo $? >"$w/rc"; }
KEPT="$VMU.pre-1.3.0"
RB="$w/state/image-bump/svc.rolled-back"

# ---------- near miss: a clean deploy ----------
scenario
go --wait 0
expect "a clean deploy exits 0" 0 "deployed"
logged "the running image is read from the container" "^podman inspect widget --format \{\{\.ImageName\}\}$"
logged "the replaced image is looked up in the VM's storage" "^podman image exists $IMG@$D0$"
logged "the unit is kept as .pre-<version>" "^podman machine ssh cp $VMU $KEPT$"
logged "the applied unit, resolved to its path, is copied in" "^podman machine ssh cp $w/root/svc/widget.container $VMU$"
logged "systemd is reloaded" "^podman machine ssh systemctl --user daemon-reload$"
logged "the service is restarted" "^podman machine ssh systemctl --user restart widget.service$"
before "keep before install" "cp $VMU $KEPT" "cp $w/root/svc/widget.container $VMU"
before "install before reload" "cp $w/root/svc/widget.container" "daemon-reload"
before "reload before restart" "daemon-reload" "restart widget.service"
before "restart before the checks" "restart widget.service" "^check health"
unlogged "no stop and no export when the version does not migrate" "systemctl --user stop|volume export"
unlogged "no restore" "cp $KEPT $VMU"
[ ! -e "$RB" ] && ok "nothing listed as rolled back" || no "rolled-back list written"
grep -qF "kept as $KEPT" "$w/out" && ok "the report names the kept unit" || no "kept unit not reported"
grep -qF "tell the other users" "$w/out" && ok "reminder: tell other users" || no "reminder missing"

# ---------- preconditions, each its own refusal ----------
RUNNING=$DA scenario
go --wait 0
expect "refused: applied pin is already running" 4 "pin not applied or already running"
unlogged "nothing changed on that refusal" "machine ssh|volume"

RUNNING=$DX scenario
go --wait 0
expect "refused: the running image is not the one the record replaces" 4 "but the scan record says this version replaces"
unlogged "nothing changed on that refusal" "machine ssh|volume"

EXISTS=1 scenario
go --wait 0
expect "refused: the replaced image is gone from the VM" 4 "not in the VM's storage"
unlogged "nothing changed on that refusal" "machine ssh|volume"

ROLLED=$DA scenario
go --wait 0
expect "refused: the digest was rolled back before" 4 "was rolled back before"
unlogged "nothing changed on that refusal" "machine ssh|volume"

ROLLED=$DX scenario
go --wait 0
expect "near miss: another digest in the rolled-back list does not stop it" 0 "deployed"

NORECORD=1 scenario
go --wait 0
expect "refused: no scan record for the applied digest" 4 "no scan record"
unlogged "no podman call at all" "^podman"

# ---------- a service that never comes back ----------
HEALTH=down scenario
go --wait 1
expect "no migration, checks fail: rolled back, exit 5" 5 "must be reverted by a commit"
[ "$(count '^check health$')" -ge 3 ] && ok "the check was retried within the wait, then re-run after the restore" || no "check count $(count '^check health$')"
before "restore after the failed check" "^check health" "cp $KEPT $VMU"
logged "the kept unit is restored" "^podman machine ssh cp $KEPT $VMU$"
[ "$(count 'daemon-reload')" = 2 ] && [ "$(count 'restart widget.service')" = 2 ] && ok "reload and restart ran for the install and for the restore" || no "reload/restart counts"
r=$(last "cp $KEPT $VMU"); c=$(last '^check health$')
[ -n "$r" ] && [ -n "$c" ] && [ "$c" -gt "$r" ] && ok "the checks re-run after the restore" || no "no check after the restore"
grep -qF "the checks pass again" "$w/out" && ok "the restored service's result is reported" || no "restore result not reported"
grep -qx "$DA" "$RB" 2>/dev/null && ok "the applied digest is listed as rolled back" || no "rolled-back list: $(cat "$RB" 2>&1)"
go --wait 0
expect "a second deploy of that digest refuses" 4 "was rolled back before"

# ---------- a migrating version that fails ----------
MIG=yes HEALTH=down scenario
go --wait 0
expect "migrating, checks fail: exit 6" 6 "$w/home/widget-data-pre-1.3.0.tar"
unlogged "nothing restored" "cp $KEPT $VMU"
[ "$(count 'restart widget.service')" = 1 ] && ok "no second restart" || no "restart count"
[ ! -e "$RB" ] && ok "not listed as rolled back" || no "rolled-back list written"

# ---------- a migrating version that succeeds: the export comes first ----------
MIG=yes scenario
go --wait 0
expect "migrating, clean: exit 0" 0 "delete $w/home/widget-data-pre-1.3.0.tar once the nightly backup"
logged "the service is stopped" "^podman machine ssh systemctl --user stop widget.service$"
logged "the volume is exported to the version-named file" "^podman volume export widget-data -o $w/home/widget-data-pre-1.3.0.tar$"
before "stop before export" "systemctl --user stop" "volume export"
before "export before keep" "volume export" "cp $VMU $KEPT"
before "export before install" "volume export" "cp $w/root/svc/widget.container $VMU"

# ---------- the install script ----------
INSTALL=script scenario
go --wait 0
expect "near miss: a script install that succeeds" 0 "deployed"
logged "the script ran" "^install-script$"
before "keep before the script" "cp $VMU $KEPT" "^install-script$"
before "the script before the checks" "^install-script$" "^check health"
unlogged "a script install is not copied or restarted by the tool" "cp $w/root|restart widget.service"

INSTALL=script scenario; echo 1 > "$FX/install-rc"
go --wait 0
expect "a failing install script counts as a failed check: rolled back" 5 "the install script exited 1"
logged "the unit is restored" "^podman machine ssh cp $KEPT $VMU$"
grep -qx "$DA" "$RB" 2>/dev/null && ok "digest listed" || no "digest not listed"

INSTALL=script MIG=yes scenario; echo 1 > "$FX/install-rc"
go --wait 0
expect "a failing install script on a migrating version: exit 6" 6 "the install script exited 1"
unlogged "nothing restored" "cp $KEPT $VMU"

# ---------- the checks retry ----------
FLAKY=1 scenario
go --wait 3
expect "near miss: a check that passes on its second try" 0 "deployed"
[ "$(count '^check flaky$')" = 2 ] && ok "tried twice" || no "tried $(count '^check flaky$') times"

# ---------- environment ----------
scenario; mv "$S/podman" "$S/podman.off"
PATH_SAVE=$PATH; mkdir -p "$w/emptybin"; PATH="$w/emptybin"
"$PY" "$BIN" deploy svc --root "$w/root" --wait 0 >"$w/out" 2>"$w/err"; echo $? >"$w/rc"
PATH=$PATH_SAVE; mv "$S/podman.off" "$S/podman"
expect "a missing podman is an environment error" 2 "cannot run podman"

if [ "$fail" -eq 0 ]; then echo PASS; exit 0; fi
echo "FAIL: $fail case(s)"; exit 1
