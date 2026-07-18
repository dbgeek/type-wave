#!/usr/bin/env bash
#
# Install the type-wave daemon as a signed, headless per-user LaunchAgent (wayfinder #15).
#
# It signs and stages the daemon, its private helper, and their provenance before replacing
# the installed pair. The prior pair is restored if publication fails, so an incomplete
# upgrade cannot displace a working installation. It does NOT load the agent — that first run
# prompts for permissions, so it is left as a deliberate step you run when ready (printed at
# the end). See docs/packaging.md for setup and grant-persistence verification.
#
# Usage:   packaging/install.sh [path-to-daemon] [path-to-helper]
# Env:     TYPE_WAVE_SIGN_IDENTITY   codesign identity name (default: "type-wave dev")
#
# Invoked by `zig build install-agent`, but also runnable standalone.

set -euo pipefail

IDENTITY="${TYPE_WAVE_SIGN_IDENTITY:-type-wave dev}"
BUNDLE_ID="me.ba78.type-wave"
LABEL="me.ba78.type-wave"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
daemon="${1:-$repo_root/zig-out/bin/type-wave}"
helper="${2:-$repo_root/zig-out/bin/type-wave-whisper}"

install_daemon="$HOME/.local/bin/type-wave"
pair_root="$HOME/.local/libexec/type-wave"
pairs_dir="$pair_root/pairs"
current_link="$pair_root/current"
install_helper="$pair_root/type-wave-whisper"
install_data="$HOME/.local/share/type-wave"
packaged_data="$repo_root/packaging/share/type-wave"
agents_dir="$HOME/Library/LaunchAgents"
plist_dst="$agents_dir/$LABEL.plist"
plist_tmpl="$repo_root/packaging/$LABEL.plist"
log_path="$HOME/Library/Logs/type-wave.log"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\033[1m==>\033[0m %s\n' "$*"; }

[ -f "$daemon" ] || die "daemon not found: $daemon
       build it first:  nix develop --command zig build"
[ -f "$helper" ] || die "helper not found: $helper
       build the compatible pair first:  nix develop --command zig build"
[ -d "$packaged_data" ] || die "packaged provenance missing: $packaged_data"
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

# --- stage + sign the complete pair -------------------------------------------------
mkdir -p "$HOME/.local"
transaction="$(mktemp -d "$HOME/.local/.type-wave-install.XXXXXX")"
trap 'rm -rf "$transaction"' EXIT
staged_pair="$transaction/pair"
staged_daemon="$staged_pair/type-wave"
staged_helper="$staged_pair/type-wave-whisper"
staged_data="$staged_pair/share"
mkdir -p "$staged_pair"
cp "$daemon" "$staged_daemon"
cp "$helper" "$staged_helper"
cp -R "$packaged_data" "$staged_data"
chmod 755 "$staged_daemon" "$staged_helper"

step "Code-signing staged daemon and helper with \"$IDENTITY\""
# No --options runtime: hardened runtime is out of scope for #15. --timestamp=none keeps
# signing offline (a self-signed dev cert can't use Apple's timestamp server).
codesign --force --timestamp=none \
  --identifier "$BUNDLE_ID" \
  --sign "$IDENTITY" \
  "$staged_daemon"
codesign --force --timestamp=none \
  --identifier "$BUNDLE_ID.whisper" \
  --sign "$IDENTITY" \
  "$staged_helper"

codesign --verify --strict "$staged_daemon" || die "daemon signature failed to verify"
codesign --verify --strict "$staged_helper" || die "helper signature failed to verify"

# --- publish by switching one shared pair pointer -----------------------------------
# The fixed daemon/helper paths are symlinks through `current`. Upgrades publish an
# immutable pair directory, then replace only that pointer, so neither a running daemon
# nor a concurrent CLI invocation can ever resolve a mixed pair.
mkdir -p "$(dirname "$install_daemon")" "$pairs_dir" "$(dirname "$install_data")"
pair_name="pair-$(date +%s)-$$"
pair_dir="$pairs_dir/$pair_name"
previous_current=""
[ ! -L "$current_link" ] || previous_current="$(readlink "$current_link")"
legacy_pair=""

snapshot_path() {
  path=$1
  name=$2
  snapshot_kind=absent
  snapshot_link=""
  if [ -L "$path" ]; then
    snapshot_kind=link
    snapshot_link="$(readlink "$path")"
  elif [ -d "$path" ]; then
    snapshot_kind=dir
    cp -R "$path" "$transaction/$name"
  elif [ -e "$path" ]; then
    snapshot_kind=file
    cp -p "$path" "$transaction/$name"
  fi
}

replace_link() {
  path=$1
  target=$2
  next="$path.next.$$"
  rm -f "$next"
  ln -s "$target" "$next"
  # BSD-only -h flag; bypass PATH so a GNU coreutils mv (no -h) can't be picked up
  /bin/mv -f -h "$next" "$path"
}

restore_path() {
  path=$1
  name=$2
  kind=$3
  link=$4
  rm -rf "$path"
  case "$kind" in
    link) ln -s "$link" "$path" ;;
    dir) cp -R "$transaction/$name" "$path" ;;
    file) cp -p "$transaction/$name" "$path" ;;
    absent) ;;
  esac
}

snapshot_path "$install_daemon" previous_daemon
previous_daemon_kind=$snapshot_kind
previous_daemon_link=$snapshot_link
snapshot_path "$install_helper" previous_helper
previous_helper_kind=$snapshot_kind
previous_helper_link=$snapshot_link
snapshot_path "$install_data" previous_data
previous_data_kind=$snapshot_kind
previous_data_link=$snapshot_link

publishing=0
rollback() {
  status=$?
  trap - ERR HUP INT TERM
  [ "${publishing:-0}" = 1 ] || exit "$status"
  if [ -n "$previous_current" ]; then
    replace_link "$current_link" "$previous_current"
  else
    rm -f "$current_link"
  fi
  restore_path "$install_daemon" previous_daemon "$previous_daemon_kind" "$previous_daemon_link"
  restore_path "$install_helper" previous_helper "$previous_helper_kind" "$previous_helper_link"
  restore_path "$install_data" previous_data "$previous_data_kind" "$previous_data_link"
  rm -rf "$pair_dir"
  [ -z "$legacy_pair" ] || rm -rf "$legacy_pair"
  die "paired installation failed; restored the previous daemon/helper pair"
}
trap rollback ERR HUP INT TERM

publishing=1
mv "$staged_pair" "$pair_dir"

# Migrate the old two-file layout without changing what either fixed path resolves to.
# Once both paths traverse the legacy pair, the same pointer switch used by later upgrades
# moves them to the new pair together.
if [ -z "$previous_current" ] && [ -e "$install_daemon" ] && [ -e "$install_helper" ]; then
  legacy_name="legacy-$(date +%s)-$$"
  legacy_pair="$pairs_dir/$legacy_name"
  mkdir -p "$legacy_pair"
  cp -p "$install_daemon" "$legacy_pair/type-wave"
  cp -p "$install_helper" "$legacy_pair/type-wave-whisper"
  if [ -d "$install_data" ]; then
    cp -R "$install_data" "$legacy_pair/share"
  else
    mkdir -p "$legacy_pair/share"
  fi
  replace_link "$current_link" "pairs/$legacy_name"
fi

replace_link "$install_daemon" "../libexec/type-wave/current/type-wave"
replace_link "$install_helper" "current/type-wave-whisper"
replace_link "$install_data" "../libexec/type-wave/current/share"
replace_link "$current_link" "pairs/$pair_name"

codesign --verify --strict "$install_daemon"
codesign --verify --strict "$install_helper"
publishing=0
trap - ERR HUP INT TERM

# Only a single installer-owned predecessor directory beneath `pairs` is eligible for cleanup.
previous_name=${previous_current#pairs/}
case "$previous_current:$previous_name" in
  pairs/*:pair-*|pairs/*:legacy-*)
    case "$previous_name" in
      */*) ;;
      *) rm -rf "$pairs_dir/$previous_name" ;;
    esac
    ;;
esac
[ -z "$legacy_pair" ] || rm -rf "$legacy_pair"

# --- render + install the LaunchAgent plist -----------------------------------------
step "Installing LaunchAgent → $plist_dst"
mkdir -p "$agents_dir" "$(dirname "$log_path")"
# launchd plists don't expand ~/$HOME; bake the absolute paths in.
sed "s#__HOME__#$HOME#g" "$plist_tmpl" > "$plist_dst"
plutil -lint "$plist_dst" >/dev/null || die "rendered plist failed to lint: $plist_dst"

# --- report -------------------------------------------------------------------------
echo
step "Installed. Designated Requirement (what TCC keys the grants to):"
codesign -d --requirements - "$install_daemon" 2>&1 | sed 's/^/    /'
step "Helper signature:"
codesign -d --requirements - "$install_helper" 2>&1 | sed 's/^/    /'

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
      $install_daemon --set-key
Run --set-key through THIS installed signed binary — the keychain item's ACL keys to its
creator, so only then does the daemon read it prompt-free. A key still in the legacy
~/.config/type-wave/env file is auto-migrated into the keychain on first run. The daemon
starts fine without a key: the menu-bar icon dims and the status line reads
"No API key" until one appears.
EOF
