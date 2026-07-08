#!/usr/bin/env bash
#
# Install the type-wave daemon as a signed, headless per-user LaunchAgent (wayfinder #15).
#
# It (1) code-signs the built binary with a STABLE self-signed identity so the three TCC
# grants (Input Monitoring, PostEvent, Microphone) survive rebuilds, (2) installs it to a
# fixed path, and (3) renders + installs the LaunchAgent plist. It does NOT load the agent
# — that first run prompts for permissions, so it is left as a deliberate step you run when
# ready (printed at the end). See docs/packaging.md for the one-time cert setup and the
# grant-persistence verification.
#
# Usage:   packaging/install.sh [path-to-binary]
# Env:     TYPE_WAVE_SIGN_IDENTITY   codesign identity name (default: "type-wave dev")
#
# Invoked by `zig build install-agent`, but also runnable standalone.

set -euo pipefail

IDENTITY="${TYPE_WAVE_SIGN_IDENTITY:-type-wave dev}"
BUNDLE_ID="me.ba78.type-wave"
LABEL="me.ba78.type-wave"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="${1:-$repo_root/zig-out/bin/type-wave}"

install_bin="$HOME/.local/bin/type-wave"
agents_dir="$HOME/Library/LaunchAgents"
plist_dst="$agents_dir/$LABEL.plist"
plist_tmpl="$repo_root/packaging/$LABEL.plist"
log_path="$HOME/Library/Logs/type-wave.log"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\033[1m==>\033[0m %s\n' "$*"; }

[ -f "$binary" ] || die "binary not found: $binary
       build it first:  nix develop --command zig build"
[ -f "$plist_tmpl" ] || die "LaunchAgent template missing: $plist_tmpl"

# --- the stable signing identity must exist (the one-time human step) ---------------
if ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  cat >&2 <<EOF
$(printf '\033[31merror:\033[0m') code-signing identity "$IDENTITY" not found.

This is the one-time setup that gives the daemon a STABLE identity so its TCC grants
survive rebuilds. Create the self-signed cert as described in:

    docs/packaging.md  →  "One-time: create the signing identity"

Then re-run this installer. (Override the name with TYPE_WAVE_SIGN_IDENTITY.)
EOF
  exit 1
fi

# --- install + sign at the fixed path -----------------------------------------------
step "Installing binary → $install_bin"
mkdir -p "$(dirname "$install_bin")"
cp -f "$binary" "$install_bin"

step "Code-signing with \"$IDENTITY\" (identifier $BUNDLE_ID)"
# No --options runtime: hardened runtime is out of scope for #15. --timestamp=none keeps
# signing offline (a self-signed dev cert can't use Apple's timestamp server).
codesign --force --timestamp=none \
  --identifier "$BUNDLE_ID" \
  --sign "$IDENTITY" \
  "$install_bin"

codesign --verify --strict "$install_bin" || die "signature failed to verify"

# --- render + install the LaunchAgent plist -----------------------------------------
step "Installing LaunchAgent → $plist_dst"
mkdir -p "$agents_dir" "$(dirname "$log_path")"
# launchd plists don't expand ~/$HOME; bake the absolute paths in.
sed "s#__HOME__#$HOME#g" "$plist_tmpl" > "$plist_dst"
plutil -lint "$plist_dst" >/dev/null || die "rendered plist failed to lint: $plist_dst"

# --- report -------------------------------------------------------------------------
echo
step "Installed. Designated Requirement (what TCC keys the grants to):"
codesign -d --requirements - "$install_bin" 2>&1 | sed 's/^/    /'

uid="$(id -u)"
cat <<EOF

Next steps:
  • Load (start) the daemon:
        launchctl bootout  gui/$uid "$plist_dst" 2>/dev/null || true
        launchctl bootstrap gui/$uid "$plist_dst"
  • Logs:   $log_path
  • Grant the three permissions on first run, then verify persistence across a rebuild
    per docs/packaging.md.

Note: the OpenAI API key lives in the login keychain (#33). Set it either from the
daemon's menu-bar icon (Set API Key…) once it is running, or right now via:
      $install_bin --set-key
Run --set-key through THIS installed signed binary — the keychain item's ACL keys to its
creator, so only then does the daemon read it prompt-free. A key still in the legacy
~/.config/type-wave/env file is auto-migrated into the keychain on first run. The daemon
starts fine without a key: the menu-bar icon dims and the status line reads
"No API key" until one appears.
EOF
