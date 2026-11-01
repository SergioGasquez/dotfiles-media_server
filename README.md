# Media server and 3D printing services (macOS)

This describes the **current installation on this Mac**, not a one-command
installer. Application data, service definitions, and credentials live outside
this repository. Paths below use `~` instead of a machine-specific
username; do not commit databases, API keys, printer access codes, or local
network details.

## Media stack

| App | Role | Installation and service | Local port |
| --- | --- | --- | --- |
| Jellyfin | Plays movies and shows | Homebrew cask; `local.jellyfin` system LaunchDaemon | 8096 |
| Sonarr | TV library and downloads | Homebrew cask; `local.sonarr` system LaunchDaemon | 8989 |
| Radarr | Movie library and downloads | Homebrew cask; `local.radarr` system LaunchDaemon | 7878 |
| Prowlarr | Indexers for Sonarr and Radarr | Homebrew cask; `local.prowlarr` system LaunchDaemon | 9696 |
| Bazarr | Subtitles for Sonarr and Radarr | Homebrew formula; `local.bazarr` system LaunchDaemon | 6767 |
| Transmission | Torrent downloads | Homebrew `transmission-cli` formula; `homebrew.mxcl.transmission-cli` system LaunchDaemon | 9091 (RPC/web) |
| Seerr | Requests for Jellyfin, Sonarr, and Radarr | Locally built Node/pnpm app; `local.seerr` **system** LaunchDaemon | 5055 |

The Homebrew-managed applications are installed in the usual Homebrew and
`/Applications` locations. Their configuration and databases are **not** kept
in this repo: Jellyfin, Radarr, Prowlarr, and Seerr use directories under
`~/Library/Application Support/`; Sonarr uses `~/.config/Sonarr`; Bazarr and
Transmission use `/opt/homebrew/var/`. Media lives under `~/Media/` (movies,
TV, and download folders). The services currently run via launchd, not Docker
or `brew services`. Legacy Jackett is disabled; it is not the active indexer
manager.

The local deployment project at `~/Server/media-server/` holds setup notes,
service plist templates (`boot-daemons/`), scripts, backups, and the Seerr app.
Installed system jobs are in `/Library/LaunchDaemons/`; copying a template into
that directory alone does not activate a service. The local scripts include
Jellyfin library refresh and watched-item cleanup, Transmission completed-item
cleanup, and Spanish-original tagging for Bazarr. Some automation runs via
user LaunchAgents; see `~/Server/media-server/scripts/` and the active launchd
jobs rather than assuming every template is installed. The setup notes in
`~/Server/media-server/docs/` may contain private host details and should not
be copied into this repository.

Seerr is a versioned local source install: `~/Server/media-server/seerr` is a
symlink to a release in `~/Server/media-server/releases/seerr/`. Its config/database
is separate at `~/Library/Application Support/seerr`. The existing system
LaunchDaemon is **still active**. A matching user LaunchAgent is only staged at
`~/Server/media-server/launch-agents/local.seerr.plist`; it is **not** installed
in `~/Library/LaunchAgents/` or loaded. Do not load both jobs on port 5055.
The planned cutover requires disabling the root-owned system job first, then
starting and checking the user agent. A previous `pkexec` attempt failed on
this Mac, so the cutover remains pending.

## 3D printing and filament tracking

| App | Role | Installation and service | Local port |
| --- | --- | --- | --- |
| Spoolman | Filament inventory and usage database | Local Python app in a virtual environment; `local.spoolman` user LaunchAgent | 7912 |
| HaspelSync | Syncs Bambu Lab AMS spool state and print consumption with Spoolman | Local Node app; `local.haspelsync` user LaunchAgent | 4000 |

Spoolman runs from `~/Server/spoolman/app` using
`~/Server/spoolman/venv/bin/uvicorn`; `venv` links to `app/.venv`, so each
release has its own virtual environment. Its persistent data and backups are in
`~/Server/spoolman/data`, with logs in `~/Library/Logs/Spoolman`.
HaspelSync runs `entrypoint.js` from `~/Server/haspelsync/app` with dependencies
in `node_modules`. Its service sets `DATA_DIR=~/Server/haspelsync/data` and
writes logs under `~/Library/Logs/HaspelSync`. Also preserve runtime files in
`~/Server/haspelsync/app/printers/` when replacing the application: they may
contain printer configuration or state. HaspelSync talks to Spoolman and the
printer over the local network; do not publish printer identifiers or access
codes. Neither service currently runs in a container.

The stable app paths are symlinks to the current release, named after its
GitHub tag:

| Stable path | Releases |
| --- | --- |
| `~/Server/spoolman/app` | `~/Server/spoolman/releases/` |
| `~/Server/haspelsync/app` | `~/Server/haspelsync/releases/` |
| `~/Server/media-server/seerr` | `~/Server/media-server/releases/seerr/` |

## Updates, backups, and checks

The Fish `upup` in
[`mac-os/shell/platform.fish`](https://github.com/SergioGasquez/dotfiles/blob/main/mac-os/shell/platform.fish)
calls `media_server_update` from [`shell/media_server.fish`](shell/media_server.fish)
after `brew upgrade`. It upgrades the installed Jellyfin, Sonarr, Radarr, and
Prowlarr casks with `--greedy`, then restarts with `launchctl kickstart -k` the
upgraded apps' `local.*` daemons and any launchd service still running Homebrew
files the upgrade removed (`stale_brew_services`; system daemons need `sudo`).
A restarted service may need Local Network re-approval in System Settings >
Privacy & Security > Local Network.

It then updates Spoolman, HaspelSync, and Seerr to their latest GitHub
releases. For each app that is behind, it:

1. Checks that launchd has the service loaded. The Spoolman and HaspelSync user
   agents exist only while someone is logged in at the Mac; without that login,
   for example over SSH after a reboot, `upup` skips them with a warning.
2. Builds the release in `releases/<tag>` while the old one keeps running:
   Spoolman from `spoolman.zip` with its own `uv` virtual environment,
   HaspelSync from the source tarball with `npm ci --omit=dev` plus a copy of
   `app/printers/`, and Seerr from a shallow clone of the tag with its
   `packageManager` pnpm on Node 22, as in its Dockerfile.
3. Backs up the data to `backups/<app>-<old release>-<timestamp>` next to the
   app link: `sqlite3 .backup` copies of the Spoolman and Seerr databases,
   Seerr's `settings.json`, and HaspelSync's `data/`.
4. Switches the app link, restarts the service (`sudo` for Seerr's system
   daemon), and waits up to two minutes for its HTTP endpoint.
5. Deletes all releases except the new and previous ones. If the service does
   not answer, it switches the link back, restarts the old release, and stops
   `upup`.

Spoolman and Seerr migrate their databases when they start, and switching back
does not undo that. If the old release fails on the migrated database, stop the
service and restore the database from the printed backup folder. Do not run the
full `upup` merely to test these services.

Read-only local checks (ports are examples of the current setup):

```bash
launchctl list | grep -E 'local\.(spoolman|haspelsync)'
launchctl print system/local.seerr | grep -E 'state =|pid ='
for port in 7912 4000 5055; do curl -fsS -o /dev/null -w "$port: %{http_code}\n" "http://127.0.0.1:$port/"; done
```

The [media-server-repro Pi skill](pi/skills/media-server-repro/SKILL.md) can
create a sanitized inventory bundle; it is linked to
`~/.agents/skills/media-server-repro` (see [Setup](#setup)). Its optional sensitive backup mode
requires explicit permission and must never be committed or shared publicly.

## Setup

Clone next to the main [dotfiles](https://github.com/SergioGasquez/dotfiles)
and link the files by hand; `dot` manages only the main repository:

```bash
gh repo clone SergioGasquez/dotfiles-media_server "$HOME/.dotfiles-media_server"
ln -sfn "$HOME/.dotfiles-media_server/shell/media_server.fish" "$HOME/.config/fish/conf.d/media_server.fish"
mkdir -p "$HOME/.agents/skills"
ln -sfn "$HOME/.dotfiles-media_server/pi/skills/media-server-repro" "$HOME/.agents/skills/media-server-repro"
```
