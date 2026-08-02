# Decky Guard

A small self-healing watchdog for [Decky Loader](https://github.com/SteamDeckHomebrew/decky-loader).

Decky can disappear or break — for example when a SteamOS-style system update
wipes the loader's systemd unit, or when the loader's service stops while its
files are still on disk. **Decky Guard runs once after every login, checks
whether Decky is actually healthy, and reinstalls it (via the official
SteamDeckHomebrew GitHub installer) only if it is missing or broken.**

## What it checks

The health check is deliberately simple — Decky is considered **installed and
healthy** when both are present:

1. The loader binary exists and is executable (`~/homebrew/services/PluginLoader`).
2. The systemd unit file exists on disk (`/etc/systemd/system/plugin_loader.service`).

The system service uses `Restart=always`, so the file-level check is the
reliable, low-privilege signal that Decky is installed and wired up — it
catches the common "wiped after an update" case without needing periodic
privileged probes.

If either check fails, it re-runs the official installer and restarts the
service.

Additionally, Decky Guard **detects Steam channel changes** (stable ↔ beta): if
you switch Steam client channels, the installed Decky build is compared against
the build that should be installed, and Decky is automatically reinstalled with
the matching build even if it looks healthy otherwise.

## Channel policy

The installed Decky build is matched to the Steam client channel, auto-detected
from `~/.steam/steam/package/beta`:

| Steam client channel            | Decky build installed |
| ------------------------------- | --------------------- |
| stable / default (no beta file) | latest **stable**     |
| `*beta*`                        | latest **prerelease** |

The currently-installed Decky branch is derived from `~/homebrew/services/.loader.version`
(pre-release tags contain `-pre`; stable tags do not). If the Steam channel and
installed branch disagree, Decky Guard reinstalls the correct build.

## Requirements

- Linux with a graphical user session (Steam Deck gamepad, or a desktop host
  with Steam installed).
- `curl`, `jq`, `systemd`, and `sudo` (password privileges to install the
  sudoers rule).
- Network access to GitHub.

## Install

**Remote one-shot:**

```sh
curl -fsSL https://github.com/LiberQuack/decky-guard/raw/HEAD/remote_install.sh | bash
```

You will be asked for your `sudo` password once — it is used only to create a
scoped rule that lets the watchdog run its single helper passwordlessly.

**Manual (if you already have the repo):**

```sh
# these resolve your real username + home at runtime (nothing hardcoded)
usr=$(id -un); home=$(eval echo "~$usr")

# copy the scripts + unit into place
mkdir -p "$home/.local/bin" "$home/.config/systemd/user"
cp scripts/decky-guard.sh scripts/decky-guard-root.sh   "$home/.local/bin/"
cp systemd/decky-guard.service                          "$home/.config/systemd/user/"
chmod 755 "$home/.local/bin/decky-guard.sh" "$home/.local/bin/decky-guard-root.sh"

# allow the root helper to run without a password (single command only)
stage="$(mktemp)"
printf '# Allow %s to run ONLY the Decky reinstall helper without a password.\n%s ALL=(root) NOPASSWD: %s\n' \
  "$usr" "$usr" "$home/.local/bin/decky-guard-root.sh" > "$stage"
sudo visudo -c -f "$stage"   # validate before installing
sudo install -m 0440 -o root -g root "$stage" /etc/sudoers.d/decky-guard
rm -f "$stage"

# run once per login
systemctl --user daemon-reload
systemctl --user enable --now decky-guard.service
```

> The sudoers file must end in a newline and be mode `0440 root:root` for sudo
> to accept it. `remote_install.sh` (and the snippet above) enforce this.

## Layout

```
decky-guard/
├── remote_install.sh            # curl one-shot installer
├── scripts/
│   ├── decky-guard.sh           # user-level health check + trigger
│   └── decky-guard-root.sh      # root helper (re)install, scoped-sudo target
└── systemd/
    └── decky-guard.service      # one-shot unit, once per login (graphical-session)
```

**Installed locations:**

| Source | Installed to | Purpose |
| ------ | ------------ | ------- |
| `scripts/decky-guard.sh` | `~/.local/bin/decky-guard.sh` | decides channel, checks health, triggers install |
| `scripts/decky-guard-root.sh` | `~/.local/bin/decky-guard-root.sh` | runs the official installer as root |
| `systemd/decky-guard.service` | `~/.config/systemd/user/decky-guard.service` | runs the check once per login |
| — | `/etc/sudoers.d/decky-guard` | passwordless sudo for the single helper |

## Run / debug

```sh
# run the check manually (loud) — will reinstall Decky if unhealthy
~/.local/bin/decky-guard.sh

# view the log
tail -f ~/.local/state/decky-guard/decky-guard.log
```

After an automatic reinstall, **restart Steam** for the Decky UI to appear.

## Uninstall

```sh
systemctl --user disable --now decky-guard.service
sudo rm -f /etc/sudoers.d/decky-guard
rm -f ~/.local/bin/decky-guard.sh ~/.local/bin/decky-guard-root.sh \
      ~/.config/systemd/user/decky-guard.service
systemctl --user daemon-reload
```

This does **not** remove Decky itself or your plugins/settings.

## SteamOS updates: how `/etc` files are handled

On **Steam Deck / SteamOS** the OS updates by writing a brand-new root image
onto the opposite A/B partition and rebooting into it. `/etc` is a writable
**overlay** (actual data under `/var/lib/overlays/etc/upper/`, which is rsynced
onto the new side), so changes normally persist. **However, since SteamOS 3.6
only `/etc` files that are listed in `/etc/atomic-update.conf.d/*.conf` are
carried over to the new image** — anything not whitelisted is discarded (a copy
is kept under `/etc/previous/` and in `/var/lib/steamos-atomupd/etc_backup/`).

Because of that, on SteamOS the installer **also registers** the sudoers rule
and the `plugin_loader.service` unit in:

```conf
/etc/atomic-update.conf.d/decky-guard.conf
  /etc/sudoers.d/decky-guard
  /etc/systemd/system/plugin_loader.service
```

so the guard survives an OS update. On normal persistent-root Linux (e.g.
CachyOS/Arch) `/etc/atomic-update.conf.d` does not exist and this step is
skipped automatically — files are already persistent there.

This is why Decky (and these files) can vanish on SteamOS after an update but
not on CachyOS. Re-running the installer (or the guard itself) restores them.

## Notes on `/etc` NOT surviving (the guard itself)

The guard's **user-level** parts live under `~/.local/bin` and
`~/.config/systemd/user`, both under `/home`, which is fully persistent across
SteamOS updates — so the watchdog itself keeps working. What an update can
discard is the **system**-side bits (`/etc/sudoers.d` rule, system unit), which
is exactly what the `atomic-update.conf.d` registration protects.

## Security notes

- Passwordless sudo is **scoped to a single helper** (`decky-guard-root.sh`).
  The helper only accepts a validated `stable`/`beta` channel and is otherwise
  self-contained.
- The user and home directory are always computed at runtime — no hardcoded
  username.

## License

MIT
