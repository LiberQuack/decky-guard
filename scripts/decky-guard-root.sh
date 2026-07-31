#!/usr/bin/env bash
#
# decky-guard-root.sh — Privileged helper that (re)installs Decky Loader.
#
# This is the ONLY command whitelisted for passwordless sudo via
# /etc/sudoers.d/decky-guard. It:
#   1. Picks the right Decky release channel (stable | prerelease).
#   2. Reuses the official SteamDeckHomebrew install_release.sh to provision
#      the loader, the systemd unit under /etc/systemd/system/plugin_loader.service
#      and to install + start the service as root.
#
# It is intentionally self-contained so other processes cannot pass arbitrary
# strings into sudo. Only argument accepted: the channel keyword.
#

set -u

fail() {
  echo "decky-guard-root: $*" >&2
  exit 1
}

MODE="${1:-install}"
CHANNEL="${2:-}"
SERVICE="plugin_loader"

# Determine the target user dynamically. sudo sets SUDO_USER to the invoking
# user; when invoked directly (e.g. an interactive run) fall back to the
# current user. Never hardcode a specific username.
DECKY_USER="${SUDO_USER:-}"
if [ -z "$DECKY_USER" ] || [ "$DECKY_USER" = "root" ]; then
  DECKY_USER="$(id -un)"
fi
DECKY_HOME="$(getent passwd "$DECKY_USER" | cut -d: -f6)"
[ -n "$DECKY_HOME" ] || fail "could not resolve home for user $DECKY_USER"
HOMEBREW="$DECKY_HOME/homebrew"
PLUGIN_LOADER="$HOMEBREW/services/PluginLoader"
UNIT="/etc/systemd/system/${SERVICE}.service"

if [ "$MODE" = "check" ]; then
  # Report health. Exit 0 if healthy, 1 if unhealthy. No install is done.
  health_fail="0"

  [ -x "$PLUGIN_LOADER" ]                    || { health_fail=1; echo "bad: loader binary missing"; }
  [ -f "$UNIT" ]                              || { health_fail=1; echo "bad: system unit missing"; }
  [ -f "$HOMEBREW/services/.loader.version" ] || { health_fail=1; echo "bad: no .loader.version"; }

  [ "$(stat -c '%s' "$PLUGIN_LOADER" 2>/dev/null)" -gt 1000000 ] || { health_fail=1; echo "bad: loader binary is empty/truncated"; }

  if ! systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    health_fail=1; echo "bad: $SERVICE not active"
  else
    echo "ok: $SERVICE active"
  fi
  if ! systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
    health_fail=1; echo "bad: $SERVICE not enabled"
  fi

  # Crash-loop detection: if systemd restarted the unit many times recently it
  # is unstable even if momentarily active. NRestarts is a monotonic counter.
  nrestarts="$(systemctl show "$SERVICE" -p NRestarts --value 2>/dev/null | tr -d '[:space:]')"
  [ "${nrestarts:-0}" -lt 5 ] || { health_fail=1; echo "bad: $SERVICE crash-looping (NRestarts=$nrestarts)"; }

  exit "$health_fail"
fi

case "$MODE" in
  install|reinstall)
    ;;
  *)
    fail "invalid mode '$MODE' (expected 'check', 'install', or 'reinstall')"
    ;;
esac
case "$CHANNEL" in
  stable|beta)
    ;;
  *)
    fail "invalid channel '$CHANNEL' (expected 'stable' or 'beta')"
    ;;
esac

INSTALLER_URL="https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/install_release.sh"
TMP_INSTALLER="$(mktemp /tmp/decky-installer.XXXXXX.sh)"

cleanup() {
  rm -f "$TMP_INSTALLER"
}
trap cleanup EXIT

# --- Download the official installer --------------------------------
echo "decky-guard-root: downloading official installer (channel=$CHANNEL)..."
if ! curl -fsSL "$INSTALLER_URL" -o "$TMP_INSTALLER"; then
  fail "could not download installer from GitHub"
fi
chmod +x "$TMP_INSTALLER"

# --- Ensure the per-user homebrew dir belongs to the target user. The ---
# --- stock installer relies on $SUDO_USER to chown the mkdir steps, so ---
# --- export it explicitly since we are invoked via sudo -u root.        ---
install -d -o "$DECKY_USER" -g "$DECKY_USER" "$HOMEBREW" \
  "$HOMEBREW/services" "$HOMEBREW/plugins"

# --- Run it. The stock script always installs latest STABLE; we normalize ---
# --- 'beta' by post-selecting the prerelease binary.                        ---
echo "decky-guard-root: running official installer (as root)..."
export SUDO_USER="$DECKY_USER"
"$TMP_INSTALLER"

# --- If the user wanted the prerelease, upgrade to it after the stable ---
# --- base install. The stable Installer still created the unit/service --.
if [ "$CHANNEL" = "beta" ]; then
  echo "decky-guard-root: selecting Decky PRERELEASE build..."
  API="https://api.github.com/repos/SteamDeckHomebrew/decky-loader/releases"
  ASSET_URL="$(curl -fsSL "$API" | \
    jq -r '[.[] | select(.prerelease == true)] | .[0].assets[] | select(.name == "PluginLoader") | .browser_download_url')"
  [ -n "$ASSET_URL" ] || fail "could not resolve prerelease PluginLoader URL"
  curl -fsSL "$ASSET_URL" -o "$HOMEBREW/services/PluginLoader" || fail "could not download prerelease PluginLoader"
  chmod +x "$HOMEBREW/services/PluginLoader"
  echo "$(basename "$(dirname "$ASSET_URL")")" > "$HOMEBREW/services/.loader.version"
fi

# --- Ensure service is running ---------------------------------------
echo "decky-guard-root: enabling + starting plugin_loader..."
systemctl daemon-reload
systemctl enable plugin_loader 2>/dev/null
systemctl restart plugin_loader || fail "could not (re)start plugin_loader service"

echo "decky-guard-root: done."
