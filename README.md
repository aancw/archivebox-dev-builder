# ArchiveBox Dev Builder Patch Script

This repo contains `archivebox-builder.sh`, a local helper script to patch and run ArchiveBox `dev`/`rc` Docker builds while upstream changes are still unstable.

Context:
- Discussion/issue thread: [ArchiveBox/discussions/1790](https://github.com/ArchiveBox/ArchiveBox/discussions/1790)
- Posted fix comment: [discussioncomment-16850909](https://github.com/ArchiveBox/ArchiveBox/discussions/1790#discussioncomment-16850909)

## What This Script Does

The script automates a local dev patch flow for ArchiveBox:

- Resets `Dockerfile`, `pyproject.toml`, and `uv.lock` to clean tracked state.
- Pulls latest ArchiveBox source and submodules.
- Clones/updates local editable dependencies:
  - `abx-dl`
  - `abxpkg`
  - `abx-plugins`
- Patches `Dockerfile` to:
  - remove broken `npm` self-update line
  - install runtime deps (`puppeteer-core`, `puppeteer`, `default-jre`, `build-essential`, `gcc`, `python3-dev`)
  - set runtime env (`NODE_PATH`, `CHROME_BINARY`, `CHROMIUM_BINARY`, `PATH`)
  - add `chromium-archivebox` wrapper that creates a unique temp Chrome profile per launch
  - copy local editable deps into the image
- Builds Docker image (unless skipped).
- Generates `docker-compose.override.yml` with ArchiveBox runtime env:
  - `ALLOWED_HOSTS`
  - `CSRF_TRUSTED_ORIGINS`
  - `CHROME_ARGS_EXTRA` (JSON)
  - `CHROME_ISOLATION` (default `snapshot`)
- Optionally runs full Compose lifecycle:
  - init
  - optional interactive superuser creation
  - `compose up -d`
  - runtime checks/log output

## Why This Exists

At the time of writing, there is no up-to-date Docker container for the ArchiveBox `dev` branch latest commits.
The `dev` image on Docker Hub (`nikisweeting`) was last pushed over 1 year ago, so local patch/build is needed for current dev testing.

This patch addresses recurring Chrome/profile lock and extractor runtime problems seen in `dev` setups, including errors such as:

- profile already in use (`SingletonLock`)
- Chrome debug port not opening
- extractor runtime dependency gaps

Key strategy:
- keep ArchiveBox internal launch args intact by using `CHROME_ARGS_EXTRA`
- force unique per-launch Chrome user-data-dir via wrapper script under `/usr/local/bin/chromium-archivebox`

## Prerequisites

- Linux host with Docker + Docker Compose plugin
- `sudo` access (defaults use `sudo docker` and `sudo docker compose`)
- Git
- Python 3
- ArchiveBox source checkout

## Important: Run Location

Run the script from the **ArchiveBox repo root** (not from this helper repo), because it expects:

- `Dockerfile`
- `pyproject.toml`
- `uv.lock`

If those files are not present, the script exits.

## Usage

1. Put `archivebox-builder.sh` in your local ArchiveBox repo root (or call it from there).
2. Make it executable:

```bash
chmod +x archivebox-builder.sh
```

3. Run:

```bash
./archivebox-builder.sh
```

The script will prompt for:
- base domain/IP
- public port
- scheme (`http` or `https`)

Then it generates `docker-compose.override.yml` and (by default) starts services.

## Environment Flags

You can override behavior with env vars:

```bash
IMAGE_TAG=archivebox-local:dev \
SKIP_BUILD=true \
CREATE_SUPERUSER=false \
RUN_COMPOSE_UP=false \
ARCHIVEBOX_HOST=archivebox.localhost \
ARCHIVEBOX_PORT=8000 \
ARCHIVEBOX_SCHEME=http \
./archivebox-builder.sh
```

Supported toggles:
- `SKIP_BUILD=true|false` (default `false`)
- `CREATE_SUPERUSER=true|false` (default `true`)
- `RUN_COMPOSE_UP=true|false` (default `true`)
- `IMAGE_TAG` (default `archivebox-local:dev`)
- `DOCKER` (default `sudo docker`)
- `COMPOSE` (default `sudo docker compose`)
- `CHROME_ISOLATION_VALUE` (default `snapshot`)
- `ABX_DL_REPO`, `ABXPKG_REPO`, `ABX_PLUGINS_REPO`

## Outputs and Side Effects

The script creates backups:
- `<file>.bak`
- `<file>.bak.<timestamp>`

Files affected:
- `Dockerfile` (patched)
- `pyproject.toml` (reset + backup)
- `uv.lock` (reset + backup)
- `docker-compose.override.yml` (generated)
- local dependency dirs (`abx-dl`, `abxpkg`, `abx-plugins`)

## Notes

- This is a **dev workaround script**, not an upstream replacement.
- It intentionally patches local files in-place for faster iteration while upstream changes settle.
- If you want to regenerate only `docker-compose.override.yml` from prompts without rebuilding image:
  - set `SKIP_BUILD=true`
  - ensure the target image already exists.

## License

MIT. See [LICENSE](LICENSE).
