#!/bin/sh
# Test brew-inventory: full-snapshot output + --delta subtraction against a base Brewfile.
# Uses a fake `brew` on PATH that emits a canned `brew bundle dump`, so it runs on any OS.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../private_dot_local/bin/executable_brew-inventory"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Fake brew: respond to `brew bundle dump ...` with a canned Brewfile snapshot.
cat > "$tmp/brew" <<'EOF'
#!/bin/sh
case "$*" in
  *"bundle dump"*) printf 'tap "homebrew/cask"\nbrew "git"\nbrew "neovim"\ncask "brave-browser"\nmas "Xcode", id: 497799835\n' ;;
  *) : ;;
esac
EOF
chmod +x "$tmp/brew"

# --- full mode: every declaration present ---
out=$(PATH="$tmp:$PATH" sh "$script")
echo "$out"
for want in 'brew "git"' 'cask "brave-browser"' 'mas "Xcode", id: 497799835'; do
  if ! printf '%s\n' "$out" | grep -qF "$want"; then echo "FAIL full: missing $want"; exit 1; fi
done

# --- delta mode: base already has git + brave -> only new entries remain ---
printf 'brew "git"\ncask "brave-browser"\n' > "$tmp/base"
dout=$(PATH="$tmp:$PATH" sh "$script" --delta "$tmp/base")
echo "--- delta ---"; echo "$dout"
if ! printf '%s\n' "$dout" | grep -qF 'brew "neovim"'; then echo "FAIL delta: neovim should remain"; exit 1; fi
if printf '%s\n' "$dout" | grep -qF 'brew "git"'; then echo "FAIL delta: git should be dropped (in base)"; exit 1; fi
if printf '%s\n' "$dout" | grep -qF 'cask "brave-browser"'; then echo "FAIL delta: brave should be dropped (in base)"; exit 1; fi

echo PASS
