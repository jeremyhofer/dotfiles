#!/bin/sh
# Test: `image-bump` for an image build's pinned-inputs file -- artifact descriptors that move
# `file` and `deb` pins in two files (one per architecture), after verifying a signature.
#
# The world is built fresh for each case by one Python script: a release host (checksums, a
# bundle, assets for two versions), a signed apt repository, two pins files and two descriptors.
# Served by a stdlib HTTP server on 127.0.0.1, so nothing reaches the network. `cosign` is a stub
# (real verification needs sigstore's trust root, which is online): it "verifies" a bundle that
# holds the sha256 of the blob, and demands the exact identity and issuer. `trivy` is a stub that
# answers from a fixture keyed by the sha256 of the file it finds in the directory it is given.
# `gpg` and `gpgv` are the real ones, over throwaway keys in a scratch home. Names are invented.
# Each case asserts an exit status, a specific message, and what the files on disk became.
#
# Overrides: IMAGE_BUMP_BIN (the executable under test), PYTHON (the interpreter).
# Run: sh tests/test-image-bump-estate.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
BIN=${IMAGE_BUMP_BIN:-$here/../private_dot_local/bin/executable_image-bump}
PY=$(command -v "${PYTHON:-python3}") || { echo "FAIL: python3 is required"; exit 1; }
[ -f "$BIN" ] || { echo "FAIL: no image-bump at $BIN"; exit 1; }
# Required on Linux, where every fleet machine has them. On macOS they are an optional install, so a
# Mac without them SKIPs, visibly, rather than failing a suite set that has nothing else wrong.
for c in gpg gpgv; do
  command -v $c >/dev/null 2>&1 && continue
  [ "$(uname -s)" = Darwin ] && { echo "SKIP: $c is not installed (brew install gnupg to run this suite)"; exit 0; }
  echo "FAIL: $c is required"; exit 1
done

t=${TMPDIR:-/tmp}; t=${t%/}
w=$(mktemp -d "$t/image-bump-estate.XXXXXX") || exit 1
HOME="$w/home"; export HOME; mkdir -p "$HOME"
GNUPGHOME_ROOT="$w/gpg"; mkdir -p "$GNUPGHOME_ROOT"; chmod 700 "$GNUPGHOME_ROOT"
unset IMAGE_BUMP_ROOT IMAGE_BUMP_SOURCE_ROOT

cleanup() {
  kill "${srv_pid:-}" 2>/dev/null
  for h in "$GNUPGHOME_ROOT"/*; do [ -d "$h" ] && gpgconf --homedir "$h" --kill gpg-agent 2>/dev/null; done
  rm -rf "${w:?}"
}
trap cleanup EXIT

fail=0
ok() { printf '  ok    %s\n' "$1"; }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
rc() { cat "$w/rc"; }
# expect <name> <status> [<text expected in stdout or stderr>]
expect() {
  name=$1; want=$2; text=${3:-}
  got=$(rc)
  if [ "$got" != "$want" ]; then no "$name (status $got, wanted $want; out: $(cat "$w/out"); err: $(cat "$w/err"))"; return; fi
  if [ -n "$text" ] && ! cat "$w/out" "$w/err" | grep -qF -- "$text"; then
    no "$name (no '$text' in output: $(cat "$w/out" "$w/err"))"; return
  fi
  ok "$name"
}
has() { if grep -qF -- "$2" "$3"; then ok "$1"; else no "$1 (no '$2' in $3: $(cat "$3" 2>&1))"; fi; }
lacks() { if grep -qF -- "$2" "$3"; then no "$1 ('$2' in $3)"; else ok "$1"; fi; }

# ---------- the stubs ----------
S="$w/stubs"; mkdir -p "$S"
cat > "$S/cosign" <<'EOF'
#!/bin/sh
echo "cosign $*" >> "$STUB_LOG"
[ "$1" = verify-blob ] || { echo "stub cosign: not verify-blob" >&2; exit 2; }
shift
exec "$PY" "$FX/cosign-stub.py" "$@"
EOF
cat > "$S/trivy" <<'EOF'
#!/bin/sh
echo "trivy $*" >> "$STUB_LOG"
case "$1 $2" in
  "image --download-db-only") exit 0 ;;
  "version --format") printf '{"Version": "0.99.0", "VulnerabilityDB": {"UpdatedAt": "2026-10-27T06:00:00Z"}}\n'; exit 0 ;;
esac
[ "$1" = rootfs ] || { echo "stub trivy: unexpected $*" >&2; exit 2; }
exec "$PY" "$FX/trivy-stub.py" "$@"
EOF
chmod +x "$S/cosign" "$S/trivy"
FX="$w/fx"; STUB_LOG="$w/log"; export FX STUB_LOG PY
PATH="$S:$PATH"; export PATH
mkdir -p "$FX"

cat > "$FX/cosign-stub.py" <<'PYEOF'
import hashlib, os, sys
a = sys.argv[1:]
opt = dict(zip(a[:-1:2], a[1:-1:2])) if False else {}
i = 0
while i < len(a) - 1:
    opt[a[i]] = a[i + 1]; i += 2
blob = a[-1]
for flag, env in (("--certificate-identity", "EXPECT_IDENTITY"), ("--certificate-oidc-issuer", "EXPECT_ISSUER")):
    if opt.get(flag) != os.environ[env]:
        sys.stderr.write("stub cosign: %s is %r, wanted %r\n" % (flag, opt.get(flag), os.environ[env])); sys.exit(1)
want = open(opt["--bundle"]).read().strip()
got = hashlib.sha256(open(blob, "rb").read()).hexdigest()
if want != got:
    sys.stderr.write("stub cosign: invalid signature when validating ASN.1 encoded signature\n"); sys.exit(1)
sys.stderr.write("Verified OK\n")
PYEOF
cat > "$FX/trivy-stub.py" <<'PYEOF'
import hashlib, os, sys
d = sys.argv[-1]
files = sorted(os.path.join(r, n) for r, _d, ns in os.walk(d) for n in ns)
if "--skip-db-update" not in sys.argv or len(files) != 1:
    sys.stderr.write("stub trivy: want --skip-db-update and one file, got %r\n" % files); sys.exit(1)
key = hashlib.sha256(open(files[0], "rb").read()).hexdigest()
f = os.path.join(os.environ["FX"], "trivy", key + ".json")
if not os.path.isfile(f):
    sys.stderr.write("stub trivy: no fixture %s\n" % key); sys.exit(1)
sys.stdout.write(open(f).read())
PYEOF

# ---------- keys: a good one, pinned; and an attacker's ----------
mkkey() {
  h="$GNUPGHOME_ROOT/$1"; mkdir -m700 "$h"
  gpg --homedir "$h" --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "$1 <$1@example.invalid>" ed25519 sign never >/dev/null 2>&1 || { echo "FAIL: cannot make key $1"; exit 1; }
  gpg --homedir "$h" --export --armor > "$w/$1.public"
  gpg --homedir "$h" --with-colons --list-keys | awk -F: '$1=="fpr"{print $10; exit}' > "$w/$1.fpr"
}
mkkey good; mkkey evil
GOOD_FPR=$(cat "$w/good.fpr"); EVIL_FPR=$(cat "$w/evil.fpr")

# ---------- the world builder ----------
cat > "$FX/world.py" <<'PYEOF'
"""world.py <root> <port>: build srv/, repo/ and fixtures under <root>. Environment knobs:
PINNED=no -> the pins hold PLACEHOLDER; SIGNER=evil -> the Release is signed by the other key;
KEYFILE=evil -> the descriptor's key file holds the other key; ONLYGZ=1 -> the Release lists only Packages.gz; SIGFORM=inrelease -> only InRelease."""
import gzip, hashlib, io, json, os, shutil, subprocess, sys, tarfile
root, port = sys.argv[1], sys.argv[2]
w = os.environ["W"]
fx = os.environ["FX"]
srv, repo = [os.path.join(root, n) for n in ("srv", "repo")]
for d in (srv, repo, os.path.join(fx, "trivy")):
    shutil.rmtree(d, ignore_errors=True)
os.makedirs(os.path.join(fx, "trivy"))
sha = lambda b: hashlib.sha256(b).hexdigest()
def put(path, data):
    p = os.path.join(srv, path); os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "wb").write(data if isinstance(data, bytes) else data.encode())
def report(key, npkgs, vulns=()):
    vs = [{"VulnerabilityID": i, "PkgName": pkg, "InstalledVersion": "1.0", "FixedVersion": fixed,
           "Severity": "HIGH"} for i, pkg, fixed in vulns]
    doc = {"Results": [{"Target": "x", "Packages": [{"Name": "p%d" % n} for n in range(npkgs)],
                        "Vulnerabilities": vs or None}]}
    json.dump(doc, open(os.path.join(fx, "trivy", key + ".json"), "w"))
ARCH = {"arm": "arm64", "x86": "amd64"}
base = "http://127.0.0.1:" + port

# --- release host, for the file artifact "widget" (cosign-bundle)
for ver in ("3.0.0", "3.1.0"):
    lines = []
    for k, a in ARCH.items():
        data = ("widget %s %s" % (ver, a)).encode()
        name = "widget-v%s.linux.%s" % (ver, a)
        put("acme/widget/releases/download/v%s/%s" % (ver, name), data)
        put("acme/widget/releases/download/v%s/%s.spdx.sbom.json" % (ver, name), '{"sbom": "%s %s"}' % (ver, a))
        lines.append("%s  %s\n" % (sha(data), name))
        report(sha(data), 7)
    lines.append("%s  widget-v%s.darwin.arm64\n" % ("ab" * 32, ver))
    text = "".join(lines)
    put("acme/widget/releases/download/v%s/widget-v%s.checksums.txt" % (ver, ver), text)
    put("acme/widget/releases/download/v%s/widget-v%s.checksums.sigstore.json" % (ver, ver), sha(text.encode()))
put("repos/acme/widget/releases/latest", json.dumps({"tag_name": "v3.1.0"}))

# --- apt repository for the deb artifact "vector"
def gpg(*a, data=None):
    h = os.path.join(w, "gpg", os.environ.get("SIGNER", "good"))
    return subprocess.run(["gpg", "--homedir", h, "--batch", "--yes", "--pinentry-mode", "loopback",
                           "--passphrase", ""] + list(a), check=True, stdout=subprocess.PIPE).stdout
def deb(ver, a):
    inner = ("vector %s %s" % (ver, a)).encode()
    tarbuf = io.BytesIO()
    # mtime=0: the gzip header otherwise carries the clock, and two builds could differ.
    with gzip.GzipFile(fileobj=tarbuf, mode="wb", mtime=0) as gz, tarfile.open(fileobj=gz, mode="w") as tf:
        ti = tarfile.TarInfo("./usr/bin/vector"); ti.size = len(inner); ti.mode = 0o755
        tf.addfile(ti, io.BytesIO(inner))
    def member(name, body):
        return name.ljust(16).encode() + b"0".ljust(12) + b"0".ljust(6) + b"0".ljust(6) + b"100644".ljust(8) \
            + str(len(body)).ljust(10).encode() + b"`\n" + body + (b"\n" if len(body) % 2 else b"")
    return (b"!<arch>\n" + member("debian-binary", b"2.0\n") + member("control.tar.gz", b"x")
            + member("data.tar.gz", tarbuf.getvalue())), inner
packages = {}
for ver in ("1.0.0", "1.1.0"):
    for k, a in ARCH.items():
        blob, inner = deb(ver, a)
        fn = "pool/v/ve/vector_%s-1_%s.deb" % (ver, a)
        put("apt/" + fn, blob)
        report(sha(inner), 5)
        packages.setdefault(a, []).append(
            "Package: vector\nVersion: %s-1\nArchitecture: %s\nFilename: %s\nSize: %d\nSHA256: %s\n"
            "Description: a log shipper\n" % (ver, a, fn, len(blob), sha(blob)))
rel = ["Codename: stable\nDate: Thu, 29 Oct 2026 15:22:04 UTC\nSHA256:\n"]
for a, stanzas in packages.items():
    # Another package of the same name at another architecture must not be picked.
    text = ("\n".join(stanzas) + "\nPackage: curl\nVersion: 9\nArchitecture: %s\nFilename: pool/c/curl_9_%s.deb\n"
            "SHA256: %s\n" % (a, a, "cd" * 32)).encode()
    put("apt/dists/stable/vector-0/binary-%s/Packages" % a, text)
    packed = gzip.compress(text, mtime=0)
    put("apt/dists/stable/vector-0/binary-%s/Packages.gz" % a, packed)
    if not os.environ.get("ONLYGZ"):
        rel.append(" %s %16d vector-0/binary-%s/Packages\n" % (sha(text), len(text), a))
    rel.append(" %s %16d vector-0/binary-%s/Packages.gz\n" % (sha(packed), len(packed), a))
release = "".join(rel).encode()
os.makedirs(os.path.join(root, "rel"), exist_ok=True)
rp = os.path.join(root, "rel", "Release"); open(rp, "wb").write(release)
if os.environ.get("SIGFORM") == "inrelease":
    put("apt/dists/stable/InRelease", gpg("--clearsign", "-o", "-", rp))
else:
    put("apt/dists/stable/Release", release)
    put("apt/dists/stable/Release.gpg", gpg("--detach-sign", "-o", "-", rp))

# --- the repository: pins files and descriptors
def pins(k):
    a = ARCH[k]
    if os.environ.get("PINNED") == "no":
        file_line = "file /usr/local/bin/widget PLACEHOLDER sha256:PLACEHOLDER"
        deb_line = "deb vector PLACEHOLDER sha256:PLACEHOLDER"
    else:
        d = ("widget 3.0.0 %s" % a).encode()
        file_line = "file /usr/local/bin/widget %s/acme/widget/releases/download/v3.0.0/widget-v3.0.0.linux.%s sha256:%s" % (base, a, sha(d))
        blob, _ = deb("1.0.0", a)
        deb_line = "deb vector %s/apt/pool/v/ve/vector_1.0.0-1_%s.deb sha256:%s  # the shipper" % (base, a, sha(blob))
    return ("# pinned inputs, %s\npackage curl\n\n%s\nfile /usr/local/bin/other http://127.0.0.1/o sha256:%s\n"
            "%s\nimage registry.invalid/x sha256:%s\n") % (k, file_line, "ee" * 32, deb_line, "ff" * 32)
os.makedirs(os.path.join(repo, "image", "scans"))
for k in ARCH:
    open(os.path.join(repo, "image", "pins-%s.txt" % k), "w").write(pins(k))
common = '''arches = {"arm": "arm64", "x86": "amd64"}
pins_files = {"arm": "image/pins-arm.txt", "x86": "image/pins-x86.txt"}
release_line = "github-latest-stable"
git_tag = "v{version}"
scan_dir = "image/scans"
gate = {"kind": "fixable-count-floor"}
checklist = ["read the release notes"]
'''
d = os.path.join(repo, "image", "bump", "widget"); os.makedirs(d)
open(os.path.join(d, "image_bump.py"), "w").write(common + '''release_api = {"host": "github", "repo": "acme/widget"}
artifact = {"kind": "release-file", "path": "/usr/local/bin/widget", "asset": "widget-v{version}.linux.{arch}",
            "sbom": "widget-v{version}.linux.{arch}.spdx.sbom.json"}
verify = {"kind": "cosign-bundle", "checksums": "widget-v{version}.checksums.txt",
          "bundle": "widget-v{version}.checksums.sigstore.json",
          "certificate_identity": "https://example.invalid/acme/widget/release.yml@refs/tags/v{version}",
          "certificate_oidc_issuer": "https://issuer.invalid"}
''')
d = os.path.join(repo, "image", "bump", "vector"); os.makedirs(d)
open(os.path.join(d, "image_bump.py"), "w").write(common + '''release_api = {"host": "github", "repo": "acme/vector"}
artifact = {"kind": "release-deb", "package": "vector", "asset": "vector_{version}-1_{arch}.deb"}
verify = {"kind": "apt-release", "repo": "%s/apt", "suite": "stable", "component": "vector-0",
          "fingerprint": "%s", "key_file": "key.public"}
''' % (base, open(os.path.join(w, "good.fpr")).read().strip()))
shutil.copy(os.path.join(w, os.environ.get("KEYFILE", "good") + ".public"), os.path.join(d, "key.public"))
PYEOF

# ---------- the server: serves $w/world/srv, logs each path ----------
cat > "$FX/server.py" <<'PYEOF'
import http.server, os, sys
root, log = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        open(log, "a").write(self.path + "\n")
        f = os.path.join(root, self.path.split("?")[0].lstrip("/"))
        if not os.path.isfile(f):
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
        body = open(f, "rb").read()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        # A file with a sibling ".cut" is announced in full and sent short.
        self.wfile.write(body[:len(body) // 2] if os.path.exists(f + ".cut") else body)
    log_message = lambda self, *a: None
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PYEOF
mkdir -p "$w/world/srv"; : > "$w/srvlog"
"$PY" "$FX/server.py" "$w/world/srv" "$w/srvlog" > "$w/port" &
srv_pid=$!
i=0; while [ ! -s "$w/port" ] && [ $i -lt 50 ]; do i=$((i+1)); "$PY" -c 'import time; time.sleep(0.1)'; done
[ -s "$w/port" ] || { echo "FAIL: the stub server did not start"; exit 1; }
PORT=$(cat "$w/port")
IMAGE_BUMP_GITHUB_DOWNLOAD="http://127.0.0.1:$PORT"; IMAGE_BUMP_GITHUB_API="http://127.0.0.1:$PORT"
export IMAGE_BUMP_GITHUB_DOWNLOAD IMAGE_BUMP_GITHUB_API
EXPECT_IDENTITY="https://example.invalid/acme/widget/release.yml@refs/tags/v3.1.0"
EXPECT_ISSUER="https://issuer.invalid"; export EXPECT_IDENTITY EXPECT_ISSUER

# world [VAR=value ...]: a fresh world with the knobs set for this one build
R="$w/world/repo"; SRV="$w/world/srv"
world() {
  : > "$STUB_LOG"; : > "$w/srvlog"
  env W="$w" "$@" "$PY" "$FX/world.py" "$w/world" "$PORT" || { echo "FAIL: world.py"; exit 1; }
}
go() { (cd "$R" && "$PY" "$BIN" "$@" --root image/bump) >"$w/out" 2>"$w/err"; echo $? >"$w/rc"; }
# edit <file> <sed script>: rewrite a file in place, portably
edit() { sed "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
sh256() { "$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
pinsnap() { cat "$R/image/pins-arm.txt" "$R/image/pins-x86.txt"; ls "$R/image/scans"; }
DL="http://127.0.0.1:$PORT/acme/widget/releases/download"
WARM=$(printf 'widget 3.1.0 arm64' | "$PY" -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
WX86=$(printf 'widget 3.1.0 amd64' | "$PY" -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')

# ============ the file artifact, verified by a cosign bundle ============
world
cp "$R/image/pins-arm.txt" "$w/arm.before"; cp "$R/image/pins-x86.txt" "$w/x86.before"
go check widget 3.1.0
expect "widget 3.1.0 passes" 0 "gate fixable-count-floor: pass"
has "cosign was given the bundle, the identity of this version and the issuer" "verify-blob --bundle" "$w/log"
has "  with the version in the identity" "--certificate-identity $EXPECT_IDENTITY --certificate-oidc-issuer $EXPECT_ISSUER" "$w/log"
has "arm pin is the verified hash at the release URL" \
  "file /usr/local/bin/widget $DL/v3.1.0/widget-v3.1.0.linux.arm64 sha256:$WARM" "$R/image/pins-arm.txt"
has "x86 pin is the verified hash at the release URL" \
  "file /usr/local/bin/widget $DL/v3.1.0/widget-v3.1.0.linux.amd64 sha256:$WX86" "$R/image/pins-x86.txt"
# nothing but the one line changed, in either file
for k in arm x86; do
  diff "$w/$k.before" "$R/image/pins-$k.txt" | grep -c '^[<>]' > "$w/ndiff"
  [ "$(cat "$w/ndiff")" = 2 ] && ok "$k: exactly one line replaced" || no "$k: $(cat "$w/ndiff") changed lines"
  grep -q '# the shipper' "$R/image/pins-$k.txt" && ok "$k: the other pin and its comment are intact" || no "$k: vector line lost"
done
rec=$(ls "$R/image/scans/widget-3.1.0-"*.txt 2>/dev/null | head -1)
[ -n "$rec" ] && ok "scan record written" || no "no scan record"
if [ -n "$rec" ]; then
  has "record names what signed what" "verify: cosign-bundle: widget-v3.1.0.checksums.txt signed by $EXPECT_IDENTITY via $EXPECT_ISSUER" "$rec"
  has "record has the arm URL and hash" "arm: $DL/v3.1.0/widget-v3.1.0.linux.arm64 sha256:$WARM" "$rec"
  has "record has the SBOM hash" "sbom-arm: widget-v3.1.0.linux.arm64.spdx.sbom.json sha256:$(sh256 "$SRV/acme/widget/releases/download/v3.1.0/widget-v3.1.0.linux.arm64.spdx.sbom.json")" "$rec"
  has "record replaces 3.0.0" "replaces: 3.0.0" "$rec"
  has "record says coverage" "coverage: yes" "$rec"
  has "record verdict" "verdict: pass" "$rec"
  cp "$rec" "$w/record.keep"
fi
# the same version again
go check widget 3.1.0
expect "an already pinned version is refused" 4 "already pinned"
go check widget 3.1.0 --no-write
expect "near miss: --no-write continues on an already pinned version" 0 "continuing because of --no-write"

# --- a tampered checksums file: one hash changed after signing
world
cp "$R/image/pins-arm.txt" "$w/arm.before"; cp "$R/image/pins-x86.txt" "$w/x86.before"
sed '1s/^./0/' "$SRV/acme/widget/releases/download/v3.1.0/widget-v3.1.0.checksums.txt" > "$w/tamper"
cp "$w/tamper" "$SRV/acme/widget/releases/download/v3.1.0/widget-v3.1.0.checksums.txt"
go check widget 3.1.0
expect "a tampered checksums file is refused" 4 "cosign verify-blob refused"
[ -z "$(ls "$R/image/scans")" ] && ok "  no record" || no "  a record was written"
cmp -s "$w/arm.before" "$R/image/pins-arm.txt" && cmp -s "$w/x86.before" "$R/image/pins-x86.txt" && ok "  both pins files unchanged" || no "  a pins file changed"
lacks "  no asset was fetched before the signature held" "linux.arm64 " "$w/srvlog"
grep -q 'linux\.\(arm64\|amd64\)$' "$w/srvlog" && no "  an asset was fetched before the signature held" || ok "  no asset was fetched before the signature held (server log)"

# --- an asset whose bytes do not match the verified hash: only the x86 one
world
cp "$R/image/pins-arm.txt" "$w/arm.before"; cp "$R/image/pins-x86.txt" "$w/x86.before"
printf 'swapped' > "$SRV/acme/widget/releases/download/v3.1.0/widget-v3.1.0.linux.amd64"
go check widget 3.1.0
expect "an x86 asset with the wrong bytes is refused" 4 "widget-v3.1.0.linux.amd64: the downloaded bytes hash to"
cmp -s "$w/arm.before" "$R/image/pins-arm.txt" && cmp -s "$w/x86.before" "$R/image/pins-x86.txt" && ok "  one architecture failing leaves both pins files unchanged" || no "  a pins file changed ($(diff "$w/arm.before" "$R/image/pins-arm.txt"))"
[ -z "$(ls "$R/image/scans")" ] && ok "  no record" || no "  a record was written"

# --- an asset cut off mid-transfer is the environment's fault, not a verdict on the release
world
touch "$SRV/acme/widget/releases/download/v3.1.0/widget-v3.1.0.linux.amd64.cut"
go check widget 3.1.0
expect "a transfer that ends early is an environment error" 2 "bytes of the"
[ -z "$(ls "$R/image/scans")" ] && ok "  nothing written" || no "  a record was written"

# --- the checksums do not list the asset
world
grep -v 'linux.amd64' "$SRV/acme/widget/releases/download/v3.1.0/widget-v3.1.0.checksums.txt" > "$w/c2"
"$PY" - "$SRV/acme/widget/releases/download/v3.1.0" "$w/c2" <<'PYEOF'
import hashlib, shutil, sys
d, c = sys.argv[1:]
shutil.copy(c, d + "/widget-v3.1.0.checksums.txt")
open(d + "/widget-v3.1.0.checksums.sigstore.json", "w").write(hashlib.sha256(open(c, "rb").read()).hexdigest())
PYEOF
go check widget 3.1.0
expect "a validly signed file that omits an asset is refused" 4 "does not list widget-v3.1.0.linux.amd64"

# --- the gate and the scan
# tfix <sha256 of the scanned file> <number of packages> [ID:package:fixed ...]
tfix() {
  h=$1; n=$2; shift 2
  "$PY" - "$FX/trivy/$h.json" "$n" "$@" <<'PYEOF'
import json, sys
vs = []
for spec in sys.argv[3:]:
    i, pkg, fixed = spec.split(":")
    vs.append({"VulnerabilityID": i, "PkgName": pkg, "InstalledVersion": "1.0", "FixedVersion": fixed, "Severity": "HIGH"})
json.dump({"Results": [{"Target": "x", "Packages": [{"Name": "p%d" % k} for k in range(int(sys.argv[2]))],
                        "Vulnerabilities": vs or None}]}, open(sys.argv[1], "w"))
PYEOF
}
world
tfix "$WARM" 7 CVE-9:libnew:2
go check widget 3.1.0
expect "a fixable finding with a clean current pin is refused" 4 "not fewer than the current pin's 0"
[ -z "$(ls "$R/image/scans")" ] && ok "  nothing written" || no "  a record was written"
world
tfix "$WX86" 7 CVE-9:libnew:2
go check widget 3.1.0
expect "a fixable finding in the x86 artifact alone is refused" 4 "not fewer"

# --- no coverage: trivy detects no package in the x86 artifact only
world
tfix "$WX86" 0
go check widget 3.1.0
expect "no trivy coverage on one architecture is exit 3, never 0" 3 "NO COVERAGE: trivy detected no package in the x86 artifact"
rec=$(ls "$R/image/scans/widget-3.1.0-"*.txt 2>/dev/null | head -1)
if [ -n "$rec" ]; then
  has "  the record says coverage none" "coverage: none" "$rec"
  has "  and counts the packages" "packages: arm 7, x86 0" "$rec"
  has "  and the verdict is exception" "verdict: exception" "$rec"
else no "  no record"; fi
has "  the approval line says no coverage" "so there is no coverage" "$w/out"

# --- first pin: PLACEHOLDER lines
world PINNED=no
go check widget 3.1.0
expect "a placeholder pin is moved" 0 "wrote "
rec=$(ls "$R/image/scans/widget-3.1.0-"*.txt | head -1)
has "  record: replaces none" "replaces: none" "$rec"
has "  arm line written" "widget-v3.1.0.linux.arm64 sha256:$WARM" "$R/image/pins-arm.txt"

# --- a first pin with fixable findings: the operator's approval (3), never a refusal (4) or a pass (0)
world PINNED=no
tfix "$WARM" 7 CVE-9:libnew:2 CVE-8:libold:
go check widget 3.1.0
expect "a first pin with a fixable finding is exit 3" 3 "gate fixable-count-floor: exception: 1 fixable findings in a first pin"
has "  the approval line says why" "in a first pin, which has no current pin to compare" "$w/out"
rec=$(ls "$R/image/scans/widget-3.1.0-"*.txt 2>/dev/null | head -1)
if [ -n "$rec" ]; then
  has "  the record's verdict is exception" "verdict: exception" "$rec"
  has "  the record replaces none" "replaces: none" "$rec"
  has "  the record lists the fixable finding" "CVE-9" "$rec"
  has "  and the unfixed one" "CVE-8" "$rec"
else no "  no record"; fi
has "  the arm line is written" "widget-v3.1.0.linux.arm64 sha256:$WARM" "$R/image/pins-arm.txt"

# --- the pins files
world
{ printf 'file /usr/local/bin/widget http://x sha256:PLACEHOLDER\n'; cat "$R/image/pins-arm.txt"; } > "$w/x"; cp "$w/x" "$R/image/pins-arm.txt"
go check widget 3.1.0
expect "two lines for the pin in one file is refused" 4 "has 2 \`file /usr/local/bin/widget\` lines"
world
grep -v 'bin/widget' "$R/image/pins-x86.txt" > "$w/x"; cp "$w/x" "$R/image/pins-x86.txt"
go check widget 3.1.0
expect "no line for the pin is refused" 4 "has 0 \`file /usr/local/bin/widget\` lines"
world
edit "$R/image/pins-x86.txt" 's/v3.0.0\/widget-v3.0.0.linux.amd64/v2.9.0\/widget-v2.9.0.linux.amd64/'
go check widget 3.1.0
expect "pins files naming different versions are refused" 4 "disagree on the version"
world
printf 'tampered' > "$SRV/acme/widget/releases/download/v3.0.0/widget-v3.0.0.linux.arm64"
go check widget 3.1.0
expect "a current pin whose bytes no longer match its hash is refused" 4 "no longer matches its own hash"

# --- latest
world
go latest widget
expect "latest: reads 3.0.0 from the arm URL and sees 3.1.0" 7 "newer widget 3.0.0 -> 3.1.0 (v3.1.0)"
go latest widget --pin 3.1.0
expect "latest: up to date" 0 "up to date widget 3.1.0"
world PINNED=no
go latest widget
expect "latest: a placeholder pin has no version" 2 "no version yet"

# --- deploy and validate
world
go deploy widget
expect "deploy refuses an artifact descriptor" 4 "nothing to deploy"
go validate widget
expect "validate accepts the good descriptor" 0 "ok widget"
desc="$R/image/bump/widget/image_bump.py"
good=$(cat "$desc")
try_desc() { printf '%s\n' "$2" > "$desc"; go validate widget; expect "$1" 4 "$3"; printf '%s\n' "$good" > "$desc"; }
try_desc "validate: a descriptor with no verify is refused" "$(printf '%s\n' "$good" | grep -v '^verify = \|^          "bundle\|^          "certificate')" "verify: missing"
try_desc "validate: an asset without {version} is refused" "$(printf '%s\n' "$good" | sed 's/"asset": "widget-v{version}.linux/"asset": "widget-v1.linux/')" "artifact.asset: must be a string containing both {version} and {arch}"
try_desc "validate: an asset without {arch} is refused" "$(printf '%s\n' "$good" | sed 's/"asset": "widget-v{version}.linux.{arch}"/"asset": "widget-v{version}.linux"/')" "artifact.asset: must be a string containing both"
try_desc "validate: a container field is refused" "$(printf '%s\nservice = "x.service"\n' "$good")" "service: not used by an artifact descriptor"
try_desc "validate: pins_files keys must match arches" "$(printf '%s\n' "$good" | sed 's/"x86": "image\/pins-x86.txt"/"mips": "image\/pins-x86.txt"/')" "pins_files: must have the same keys as arches"
try_desc "validate: a deb cannot be verified by cosign-bundle" "$(printf '%s\n' "$good" | sed 's/"kind": "release-file", "path": "\/usr\/local\/bin\/widget"/"kind": "release-deb", "package": "widget"/')" "cannot verify an artifact of kind release-deb"
try_desc "validate: a cosign descriptor needs its identity" "$(printf '%s\n' "$good" | sed 's/"certificate_identity"/"certificate_idx"/')" "needs a non-empty string 'certificate_identity'"
try_desc "validate: a missing pins line is a problem" "$(printf '%s\n' "$good" | sed 's/"path": "\/usr\/local\/bin\/widget"/"path": "\/usr\/local\/bin\/nothere"/')" "has 0 \`file /usr/local/bin/nothere\` lines"

# ============ the deb artifact, verified by a signed apt Release ============
world
cp "$R/image/pins-arm.txt" "$w/arm.before"; cp "$R/image/pins-x86.txt" "$w/x86.before"
go check vector 1.1.0
expect "vector 1.1.0 passes" 0 "verified the Release"
armdeb=$(sh256 "$SRV/apt/pool/v/ve/vector_1.1.0-1_arm64.deb"); x86deb=$(sh256 "$SRV/apt/pool/v/ve/vector_1.1.0-1_amd64.deb")
has "arm deb pinned at the pool URL with the Packages hash" "deb vector http://127.0.0.1:$PORT/apt/pool/v/ve/vector_1.1.0-1_arm64.deb sha256:$armdeb  # the shipper" "$R/image/pins-arm.txt"
has "x86 deb pinned" "deb vector http://127.0.0.1:$PORT/apt/pool/v/ve/vector_1.1.0-1_amd64.deb sha256:$x86deb" "$R/image/pins-x86.txt"
has "the widget pin was left alone" "widget-v3.0.0.linux.arm64" "$R/image/pins-arm.txt"
rec=$(ls "$R/image/scans/vector-1.1.0-"*.txt | head -1)
has "record names the key and the chain" "verify: apt-release: Release of http://127.0.0.1:$PORT/apt stable signed by key $GOOD_FPR" "$rec"
has "record: packages detected in the unpacked deb" "packages: arm 5, x86 5" "$rec"
has "trivy scanned an unpacked directory with rootfs" "trivy rootfs --skip-db-update --scanners vuln" "$w/log"
go check vector 1.1.0
expect "an already pinned deb is refused" 4 "already pinned"

# --- Release signed by another key
world SIGNER=evil
cp "$R/image/pins-arm.txt" "$w/arm.before"; cp "$R/image/pins-x86.txt" "$w/x86.before"
go check vector 1.1.0
expect "a Release signed by another key is refused" 4 "is not signed by the pinned key $GOOD_FPR"
cmp -s "$w/arm.before" "$R/image/pins-arm.txt" && cmp -s "$w/x86.before" "$R/image/pins-x86.txt" && [ -z "$(ls "$R/image/scans")" ] && ok "  nothing written" || no "  something was written"
grep -q 'pool/' "$w/srvlog" && no "  a .deb was fetched" || ok "  no .deb was fetched"

# --- the key file is not the pinned key
world KEYFILE=evil SIGNER=evil
go check vector 1.1.0
expect "a key file whose fingerprint is not the pinned one is refused" 4 "not exactly the pinned $GOOD_FPR"

# --- the Release is intact but Packages was swapped
world
edit "$SRV/apt/dists/stable/vector-0/binary-arm64/Packages" 's/^SHA256: .*/SHA256: '"$(printf 'f%.0s' $(seq 64))"'/'
rm "$SRV/apt/dists/stable/vector-0/binary-arm64/Packages.gz"
go check vector 1.1.0
expect "a Packages index that differs from the signed Release hash is refused" 4 "does not match the hash the signed Release gives it"

# --- the Packages hash does not match the .deb (x86 only)
world
printf 'swapped deb' > "$SRV/apt/pool/v/ve/vector_1.1.0-1_amd64.deb"
cp "$R/image/pins-arm.txt" "$w/arm.before"; cp "$R/image/pins-x86.txt" "$w/x86.before"
go check vector 1.1.0
expect "an x86 .deb that does not match the signed Packages hash is refused" 4 "the signed Packages index says"
cmp -s "$w/arm.before" "$R/image/pins-arm.txt" && cmp -s "$w/x86.before" "$R/image/pins-x86.txt" && ok "  both pins files unchanged" || no "  a pins file changed"

# --- a version the index does not list
world
go check vector 9.9.9
expect "a version absent from Packages is refused" 4 "lists 0 entries for vector_9.9.9-1_arm64.deb"

# --- a Release that lists only the compressed index
world ONLYGZ=1
go check vector 1.1.0
expect "a gzip-only Packages index is read" 0 "verified the Release"
grep -q 'Packages.gz' "$w/srvlog" && ok "  the .gz was the one fetched" || no "  no Packages.gz fetch"

# --- InRelease instead of Release + Release.gpg
world SIGFORM=inrelease
go check vector 1.1.0
expect "InRelease is used when Release.gpg is absent" 0 "verified the Release"
world SIGFORM=inrelease SIGNER=evil
go check vector 1.1.0
expect "a clearsigned InRelease from another key is refused" 4 "is not signed by the pinned key"
# A gpgv that reports a good signature but returns no signed text (exits 0, writes no file, prints
# no text) is refused with a message, not a traceback from reading a file that is not there.
mkdir -p "$w/notext"
cat > "$w/notext/gpgv" <<STUB
#!/bin/sh
line="[GNUPG:] VALIDSIG $GOOD_FPR 2026-01-01 1767225600 0 4 0 1 10 01 $GOOD_FPR"
case " \$* " in *" --status-fd 1 "*) echo "\$line" ;; *) echo "\$line" >&2 ;; esac
exit 0
STUB
chmod +x "$w/notext/gpgv"
world SIGFORM=inrelease
oldpath=$PATH; PATH="$w/notext:$PATH"
go check vector 1.1.0
PATH=$oldpath
expect "a gpgv that returns no signed text is refused" 4 "returned no signed text"
lacks "  and not with a traceback" "Traceback" "$w/err"

# --- a plain-http repository is not a pin
world
edit "$R/image/bump/vector/image_bump.py" 's#"repo": "http://127.0.0.1:[0-9]*/apt"#"repo": "http://repo.example.invalid/apt"#'
go validate vector
expect "validate: an http repository is refused" 4 "'repo' must be an https URL"

if [ "$fail" -eq 0 ]; then echo PASS; exit 0; fi
echo "FAIL: $fail case(s)"; exit 1
