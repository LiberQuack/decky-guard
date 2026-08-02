#!/usr/bin/env bash
#
# decky-guard.sh — Self-healing watchdog for Decky Loader.
#
# Detects whether Decky's loader is present and healthy, and if not, triggers
# a reinstall through the official SteamDeckHomebrew GitHub installer.
#
# Channel policy (see prompt decision):
#   - Steam client on a BETA  channel -> install Decky  PRERELEASE
#   - Steam client default/STABLE     -> install Decky  STABLE   (default)
#
# This USER-level script only decides and triggers. The elevated install runs
# the scoped-root helper (decky-guard-root.sh) via passwordless sudo, which is
# the single command whitelisted in /etc/sudoers.d/decky-guard.
#

set -u

# Compute user + home dynamically; never hardcode a username.
DECKY_USER="$(id -un)"
DECKY_HOME="$(getent passwd "$DECKY_USER" | cut -d: -f6)"
HOMEBREW="$DECKY_HOME/homebrew"
PLUGIN_LOADER="$HOMEBREW/services/PluginLoader"
SERVICE="plugin_loader"
LOG="$DECKY_HOME/.local/state/decky-guard/decky-guard.log"
ROOT_HELPER="$DECKY_HOME/.local/bin/decky-guard-root.sh"

# Default to stable unless a beta file says otherwise.
CHANNEL="stable"
BETA_FILE="$DECKY_HOME/.steam/steam/package/beta"

SILENT="0"
[ "${1:-}" = "--silent" ] && SILENT="1"

log() {
  [ "$SILENT" = "1" ] && return 0
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"
}

# ---------------------------------------------------------------------------
# 1. Determine the Steam client channel.
# ---------------------------------------------------------------------------
detect_channel() {
  local beta
  if [ -r "$BETA_FILE" ]; then
    beta="$(tr '[:upper:]' '[:lower:]' <"$BETA_FILE" 2>/dev/null | tr -d '\r\n')"
    if printf '%s' "$beta" | grep -q 'beta'; then
      CHANNEL="beta"
    fi
  fi
  printf '%s\n' "$CHANNEL"
}

# ---------------------------------------------------------------------------
# 1b. Determine which Decky branch is currently installed.
#   The .loader.version marker records the exact tag of the installed build
#   (e.g. "v3.2.6" for stable, "v3.2.8-pre1" for prerelease). Prerelease tags
#   contain "-pre"; stable tags do not. Returns "stable" or "beta" (prerelease).
# ---------------------------------------------------------------------------
installed_branch() {
  local ver=""
  [ -r "$HOMEBREW/services/.loader.version" ] && ver="$(tr -d '\r\n' <"$HOMEBREW/services/.loader.version")"
  if [ -n "$ver" ] && printf '%s' "$ver" | grep -q -- '-pre'; then
    printf '%s\n' "beta"
  else
    printf '%s\n' "stable"
  fi
}

# ---------------------------------------------------------------------------
# 1c. Detect if the Steam client channel and installed Decky branch disagree
#   (the user switched channels since the last install). If so, Decky must be
#   reinstalled with the build matching the current channel. Returns 0 when a
#   reinstall is required due to branch mismatch, 1 otherwise.
# ---------------------------------------------------------------------------
branch_mismatch() {
  local desired="$1"
  local installed
  installed="$(installed_branch)"
  [ "$desired" = "$installed" ] && return 1
  log "decky-guard: branch mismatch (steam=$desired vs decky=$installed) — will reinstall."
  return 0
}

# ---------------------------------------------------------------------------
# 2. Health check.
#    Simple file-based check: the loader binary exists/executable and the
#    systemd system unit file is present on disk. plugin_loader is a SYSTEM
#    service that restarts itself (Restart=always), so a regular user checking
#    files is the reliable and simple signal for "is Decky installed" — the
#    branch-mismatch check above already handles reinstalling the correct build.
# ---------------------------------------------------------------------------
is_healthy() {
  [ -x "$PLUGIN_LOADER" ] && [ -f "/etc/systemd/system/${SERVICE}.service" ]
}

# ---------------------------------------------------------------------------
# 3. Trigger the scoped-root install helper.
# ---------------------------------------------------------------------------
run_root_install() {
  local channel="$1"
  # shellcheck disable=SC2024
  if ! sudo -n -u root "$ROOT_HELPER" "$channel"; then
    log "decky-guard: install failed (sudo/helper). Check /etc/sudoers.d/decky-guard and the helper."
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local decided
  decided="$(detect_channel)"

  # Never run while another guard/invocation may be mid-install.
  if ps -C decky-guard-root.sh >/dev/null 2>&1; then
    log "decky-guard: install already in progress, skipping."
    exit 0
  fi

  # If the user switched Steam channels (stable<->beta), the installed Decky
  # build no longer matches. Reinstall even if Decky looks healthy.
  if branch_mismatch "$decided"; then
    log "decky-guard: Steam channel changed (channel=$decided) — reinstalling matching build."
    if ! run_root_install "$decided"; then
      exit 1
    fi
    log "decky-guard: reinstall finished. Restarting Steam is required for the Decky UI to appear."
    exit 0
  fi

  if is_healthy; then
    log "decky-guard: healthy (channel=$decided), nothing to do."
    exit 0
  fi

  log "decky-guard: Decky missing/unhealthy (channel=$decided) — reinstalling."
  if ! run_root_install "$decided"; then
    exit 1
  fi

  log "decky-guard: reinstall finished. Restarting Steam is required for the Decky UI to appear."
}

mkdir -p "$(dirname "$LOG")"
main "$@"
