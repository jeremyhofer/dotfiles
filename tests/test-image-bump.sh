#!/bin/sh
# Test: `image-bump` frame -- descriptor loading, `validate`, the pin reader, exit statuses.
#
# Judged by exit status and by the one specific message each refusal prints. Every bad-field case
# changes ONE thing in an otherwise valid descriptor, so a refusal can only come from that field.
# The services here are invented; nothing reaches the network.
#
# Overrides: IMAGE_BUMP_BIN (the executable under test), PYTHON (the interpreter).
# Run: sh tests/test-image-bump.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
BIN=${IMAGE_BUMP_BIN:-$here/../private_dot_local/bin/executable_image-bump}
PY=${PYTHON:-python3}
command -v "$PY" >/dev/null 2>&1 || { echo "FAIL: $PY is required"; exit 1; }
[ -f "$BIN" ] || { echo "FAIL: no image-bump at $BIN"; exit 1; }

t=${TMPDIR:-/tmp}; t=${t%/}
w=$(mktemp -d "$t/image-bump.XXXXXX") || exit 1
trap 'rm -rf "$w"' EXIT
HOME="$w/home"; export HOME; mkdir -p "$HOME"
unset IMAGE_BUMP_ROOT IMAGE_BUMP_SOURCE_ROOT

fail=0
ok() { printf '  ok    %s\n' "$1"; }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
run() { "$PY" "$BIN" "$@" >"$w/out" 2>"$w/err"; echo $? >"$w/rc"; }
rc() { cat "$w/rc"; }
# expect <name> <status> [<text expected on stderr>]
expect() {
  name=$1; want=$2; text=${3:-}
  got=$(rc)
  if [ "$got" != "$want" ]; then no "$name (status $got, wanted $want; stderr: $(cat "$w/err"))"; return; fi
  if [ -n "$text" ] && ! grep -qF -- "$text" "$w/err"; then
    no "$name (no '$text' in stderr: $(cat "$w/err"))"; return
  fi
  ok "$name"
}

# mk <service> [sed-script applied to the good descriptor]
PIN='registry.invalid/acme/widget:v1.2.3-rootless@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
mk() {
  d="$w/root/$1"; mkdir -p "$d"
  printf '%s\n' "$PIN" > "$d/IMAGE"
  cat > "$d/image_bump.py.in" <<'PYEOF'
image = "registry.invalid/acme/widget"
release_line = "patch-of-pinned-major"
release_api = {"host": "github", "repo": "acme/widget"}
git_tag = "v{version}"
platform = "linux/arm64"
pin_file = "IMAGE"
scan_dir = "scans"
gate = {"kind": "fixable-count-floor"}
migrations = {"kind": "forgejo-compare", "path": "models/migrations"}
volume = "widget-data"
vm_unit = "/etc/containers/systemd/widget.container"
install = {"kind": "vm-copy", "applied_unit": "/tmp/widget.container"}
checks = [{"name": "health", "command": ["curl", "-f", "http://localhost/health"], "pass": "exit 0"}]
checklist = ["read the release notes"]
tag_suffix = "-rootless"
PYEOF
  if [ -n "${2:-}" ]; then sed "$2" "$d/image_bump.py.in" > "$d/image_bump.py"
  else cp "$d/image_bump.py.in" "$d/image_bump.py"; fi
  rm "$d/image_bump.py.in"
}
validate() { run validate "$1" --root "$w/root"; }

# ---------- a good descriptor ----------
mk good
validate good
expect "good descriptor validates" 0
grep -qx 'ok good' "$w/out" && ok "prints 'ok good'" || no "prints 'ok good' (got: $(cat "$w/out"))"

# ---------- one case per kind of bad field ----------
mk nofield '/^volume = /d'
validate nofield;      expect "missing field" 4 "volume: missing"

mk badgate 's/fixable-count-floor/count-everything/'
validate badgate;      expect "unknown gate kind" 4 "gate: unknown kind 'count-everything'"

mk badmig 's/forgejo-compare/always-maybe/'
validate badmig;       expect "unknown migrations kind" 4 "migrations: unknown kind 'always-maybe'"

mk badinst 's/vm-copy/teleport/'
validate badinst;      expect "unknown install kind" 4 "install: unknown kind 'teleport'"

mk badline 's/patch-of-pinned-major/whatever-is-newest/'
validate badline;      expect "unknown release_line strategy" 4 "release_line: unknown strategy"

mk badplat 's|linux/arm64|arm64|'
validate badplat;      expect "platform not os/arch" 4 "platform: 'arm64' is not of the form os/arch"

mk nearplat 's|linux/arm64|darwin/amd64|'
validate nearplat;     expect "near miss: another os/arch passes" 0

mk badtype 's|^volume = .*|volume = 7|'
validate badtype;      expect "wrong type" 4 "volume: expected a non-empty str"

mk badgit 's|v{version}|v1|'
validate badgit;       expect "git_tag without {version}" 4 "git_tag: must contain {version}"

mk badpin
printf 'registry.invalid/acme/widget:v1.2.3\n' > "$w/root/badpin/IMAGE"
validate badpin;       expect "unparsable pin file" 4 "pin_file: not of the form"

mk wrongimg
printf 'registry.invalid/acme/other:1.0@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n' > "$w/root/wrongimg/IMAGE"
validate wrongimg;     expect "pin names another image" 4 "pins image"

validate absent;       expect "no descriptor" 4 "no descriptor at"

# ---------- a descriptor that raises is status 2, never 1 ----------
mkdir -p "$w/root/boom"; printf 'raise RuntimeError("boom")\n' > "$w/root/boom/image_bump.py"
validate boom;         expect "descriptor raising at import" 2 "RuntimeError: boom"

# ---------- the verbs not built yet ----------
for verb in check deploy latest; do
  run "$verb" good --root "$w/root"; expect "$verb is not implemented yet" 2 "not implemented yet"
done
run bogus good;        expect "unknown verb is a usage error" 2

# ---------- default roots come from the environment ----------
IMAGE_BUMP_ROOT="$w/root" "$PY" "$BIN" validate good >"$w/out" 2>"$w/err"; echo $? >"$w/rc"
expect "IMAGE_BUMP_ROOT is the default root" 0

# ---------- the pin reader and the version helpers, called directly ----------
cat > "$w/helpers.py" <<'PYEOF'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("ib", sys.argv[1])
spec = importlib.util.spec_from_loader("ib", loader)
ib = importlib.util.module_from_spec(spec); loader.exec_module(ib)
digest = "sha256:" + "ab" * 32
assert ib.parse_pin("host:5000/a/b:v1.2@" + digest + "\n") == ("host:5000/a/b", "v1.2", digest)
for bad in ("a/b:1", "a/b@" + digest, "a/b:1@sha256:abc", "a/b:1@" + digest + "\nc/d:2@" + digest):
    try: ib.parse_pin(bad)
    except ValueError: pass
    else: raise SystemExit("accepted " + repr(bad))
assert ib.version_from_tag("v1.2.3-rootless", "-rootless") == "1.2.3"
assert ib.version_from_tag("1.2.3") == "1.2.3"
assert ib.version_from_tag("v1.2.3", "-rootless") == "1.2.3"
assert ib.git_tag_for("v{version}", "1.2.3") == "v1.2.3"
PYEOF
if "$PY" "$w/helpers.py" "$BIN" >"$w/out" 2>"$w/err"; then ok "pin reader and version helpers"
else no "pin reader and version helpers: $(cat "$w/err")"; fi

if [ "$fail" -eq 0 ]; then echo PASS; exit 0; fi
echo "FAIL: $fail case(s)"; exit 1
