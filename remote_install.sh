#!/usr/bin/env bash
#
# remote_install.sh — One-shot installer for the Decky Guard watchdog.
#
# Intended to be fetched remotely, e.g.:
#     curl -fsSL https://<repo-url>/raw/HEAD/remote_install.sh | bash
#
# It provisions:
#   1. ~/.local/bin/decky-guard.sh        (user-level health check / trigger)
#   2. ~/.local/bin/decky-guard-root.sh   (root helper that runs the official
#                                          SteamDeckHomebrew installer)
#   3. ~/.config/systemd/user/decky-guard.service  (fires once per login)
#   4. /etc/sudoers.d/decky-guard         (passwordless sudo for the root helper)
#
# The user is always computed dynamically; nothing is hardcoded.
#

set -eu

REPO_URL="${REPO_URL:-https://github.com/LiberQuack/decky-guard}"
BRANCH="${BRANCH:-HEAD}"

# Compute user + home
DECKY_USER="$(id -un)"
DECKY_HOME="$(eval echo "~$DECKY_USER")"
BIN_DIR="$DECKY_HOME/.local/bin"
UNIT_DIR="$DECKY_HOME/.config/systemd/user"
SERVICE="decky-guard.service"
ROOT_HELPER="$BIN_DIR/decky-guard-root.sh"
SUDOERS_FILE="/etc/sudoers.d/decky-guard"

raw() {  # $1 = path in repo
  printf '%s/raw/%s/%s' "$REPO_URL" "$BRANCH" "$1"
}

echo "Installing Decky Guard for user '$DECKY_USER'..."

# --- 1. User binaries ---------------------------------------------------
mkdir -p "$BIN_DIR"
echo "  fetching user scripts -> $BIN_DIR"
curl -fsSL "$(raw scripts/decky-guard.sh)"       -o "$BIN_DIR/decky-guard.sh"
curl -fsSL "$(raw scripts/decky-guard-root.sh)"  -o "$BIN_DIR/decky-guard-root.sh"
chmod 755 "$BIN_DIR/decky-guard.sh" "$BIN_DIR/decky-guard-root.sh"

# --- 2. systemd user unit (once-per-login, graphical session) -----------
mkdir -p "$UNIT_DIR"
echo "  fetching unit -> $UNIT_DIR/$SERVICE"
curl -fsSL "$(raw systemd/decky-guard.service)"  -o "$UNIT_DIR/$SERVICE"
systemctl --user daemon-reload
systemctl --user enable "$SERVICE"

# --- 3. passwordless sudo for the root helper only -----------------------
# Stage to a fixed temp file (never glob later). The staging copy is owned by
# the invoking user because curl | bash runs as them; the 'install' step below
# rewrites it into /etc/sudoers.d with the correct 0440 root:root owner/perms
# that sudo requires. visudo validation fails fast before any install.
STAGE="$(mktemp --tmpdir decky-guard.sudoers.XXXXXX)"
trap 'rm -f "$STAGE"' EXIT
sudo -v
printf '# Allow %s to run ONLY the Decky reinstall helper without a password.\n%s ALL=(root) NOPASSWD: %s\n' \
  "$DECKY_USER" "$DECKY_USER" "$ROOT_HELPER" > "$STAGE"
sudo visudo -c -f "$STAGE" >/dev/null   # fails fast on syntax error
sudo install -m 0440 -o root -g root "$STAGE" "$SUDOERS_FILE"

# --- 4. Run once immediately ---------------------------------------------
echo "  running one-shot check now..."
"$BIN_DIR/decky-guard.sh" || true

echo
echo "Decky Guard installed. It will check Decky once after each login"
echo "and reinstall it (from the official GitHub installer) if missing/broken."
echo "Log: $DECKY_HOME/.local/state/decky-guard/decky-guard.log"
