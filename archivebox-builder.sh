#!/usr/bin/env bash
#
# ArchiveBox Dev Local Builder
# Patch Author : petruknisme
# Patch Version: 0.10.0
# Patch Date   : 2026-05-10
#
# Purpose:
#   Build and run ArchiveBox dev/rc Docker image locally with temporary patches
#   needed while the upstream dev branch is unstable or incomplete.
#
# What this script patches/handles:
#   - Removes broken npm self-update step from Dockerfile
#   - Clones and injects local editable abx-* workspace dependencies:
#       - abx-dl
#       - abxpkg
#       - abx-plugins
#   - Installs extractor runtime dependencies:
#       - puppeteer-core
#       - puppeteer
#       - default-jre
#       - build-essential / gcc / python3-dev for Python packages that build native wheels
#   - Sets Node/Chrome runtime environment:
#       - NODE_PATH
#       - CHROME_BINARY
#       - CHROMIUM_BINARY
#       - CHROME_HEADLESS
#       - CHROME_SANDBOX
#       - CHROME_ISOLATION
#       - CHROME_ARGS_EXTRA
#   - Creates /usr/bin/chromium symlink to chromium-browser
#   - Forces Chrome to use an explicit user-data-dir to avoid stale profile locks
#     from previous dev runs, especially errors like:
#       - "The profile appears to be in use by another Chromium process"
#       - "No Chrome session found (chrome plugin must run first)"
#       - "Chromium exited before opening the debug port"
#   - Uses CHROME_ARGS_EXTRA instead of overriding CHROME_ARGS, preserving
#     ArchiveBox/abx-dl internal Chrome/CDP arguments
#   - Supports CHROME_ISOLATION=snapshot to avoid long-lived crawl-scoped
#     Chrome daemon/profile reuse during dev testing
#   - Cleans stale Chrome/ArchiveBox lock files on container startup:
#       - SingletonLock
#       - SingletonSocket
#       - SingletonCookie
#       - DevToolsActivePort
#       - .launch.lock
#       - .target.lock
#   - Generates docker-compose.override.yml automatically
#   - Prompts for public base domain/IP, port, and scheme
#   - Supports ArchiveBox v0.9/dev subdomain layout:
#       - web.<domain>
#       - admin.<domain>
#       - api.<domain>
#   - Adds ALLOWED_HOSTS and CSRF_TRUSTED_ORIGINS for local/homelab access
#   - Runs archivebox init safely as the archivebox user
#   - Optionally creates a superuser interactively
#   - Supports SKIP_BUILD=true to regenerate compose config without rebuilding
#
# Patch History:
#   v0.1.0  - Initial local dev image build patch
#   v0.2.0  - Added abx-dl, abxpkg, and abx-plugins local dependency handling
#   v0.3.0  - Added docker-compose.override.yml generation
#   v0.4.0  - Added puppeteer-core, NODE_PATH, and Chromium binary fixes
#   v0.5.0  - Added safer init flow and JSON/parser workaround handling
#   v0.6.0  - Added Chrome launch args, shm_size, PATH fixes, explicit ALLOWED_HOSTS,
#             and expanded CSRF_TRUSTED_ORIGINS for HTTP/HTTPS local domains
#   v0.7.0  - Added full PATH injection, puppeteer package install,
#             and scoped wildcard host support for snap-* subdomains
#   v0.8.0  - Switched from CHROME_ARGS to CHROME_ARGS_EXTRA to avoid overriding
#             ArchiveBox/abx-dl internal Chrome/CDP launch arguments
#   v0.9.0  - Added CHROME_ISOLATION=snapshot and startup cleanup for stale
#             Chrome/Profile/ArchiveBox lock files
#   v0.10.0 - Added chromium-archivebox wrapper to force a unique temporary
#             Chrome user-data-dir per launch. This avoids stale/colliding
#             SingletonLock profile errors across Web UI workers, retries,
#   v0.10.1 - Replaced static Chrome --user-data-dir workaround with a
#             chromium-archivebox wrapper that creates a unique temporary
#             Chrome profile directly under /tmp per launch. This prevents
#             SingletonLock collisions and avoids permission issues from
#             stale /tmp/archivebox-chrome-profiles directories when Web UI
#             workers, retries, or snapshot hooks launch Chrome concurrently.
#   v0.11.0 - Added archivebox-janitor sidecar runtime cleanup for stale daemon
#             hooks after Web UI/worker jobs are sealed, while preserving the
#             default ArchiveBox image entrypoint
#

set -euo pipefail

PATCH_NAME="ArchiveBox Dev Local Builder"
PATCH_AUTHOR="petruknisme"
PATCH_VERSION="0.10.1"
PATCH_DATE="2026-05-10"

IMAGE_TAG="${IMAGE_TAG:-archivebox-local:dev}"
DOCKER="${DOCKER:-sudo docker}"
COMPOSE="${COMPOSE:-sudo docker compose}"

# Set SKIP_BUILD=true when you only want to regenerate docker-compose.override.yml
# and restart containers without rebuilding the image.
SKIP_BUILD="${SKIP_BUILD:-false}"

# Set CREATE_SUPERUSER=false if user already exists.
CREATE_SUPERUSER="${CREATE_SUPERUSER:-true}"

# Set RUN_COMPOSE_UP=false if you only want to build/patch but not start containers.
RUN_COMPOSE_UP="${RUN_COMPOSE_UP:-true}"

# Generic defaults.
# User can override via prompt or env:
#   ARCHIVEBOX_HOST=archivebox.lab ./build-dev-local.sh
ARCHIVEBOX_HOST="${ARCHIVEBOX_HOST:-archivebox.localhost}"
ARCHIVEBOX_PORT="${ARCHIVEBOX_PORT:-8000}"
ARCHIVEBOX_SCHEME="${ARCHIVEBOX_SCHEME:-http}"

ABX_DL_REPO="${ABX_DL_REPO:-https://github.com/ArchiveBox/abx-dl.git}"
ABXPKG_REPO="${ABXPKG_REPO:-https://github.com/ArchiveBox/abxpkg.git}"
ABX_PLUGINS_REPO="${ABX_PLUGINS_REPO:-https://github.com/ArchiveBox/abx-plugins.git}"

PATH_VALUE="/home/archivebox/.npm/bin:/venv/bin:/usr/share/archivebox/lib/npm/node_modules/.bin:/usr/share/archivebox/lib/pip/venv/venv/bin:/usr/share/archivebox/lib/pip/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
NODE_PATH_VALUE="/usr/lib/node_modules:/usr/share/archivebox/lib/npm/node_modules:/data/personas/Default/node_modules"

CHROME_BINARY_VALUE="/usr/local/bin/chromium-archivebox"

# Keep this as JSON array for ArchiveBox v0.9/dev config parser.
CHROME_ARGS_EXTRA_JSON='["--headless=new","--no-sandbox","--disable-setuid-sandbox","--disable-dev-shm-usage","--disable-gpu","--no-first-run","--no-default-browser-check","--disable-features=Translate,OptimizationGuideModelDownloading,MediaRouter"]'
CHROME_ISOLATION_VALUE="${CHROME_ISOLATION_VALUE:-snapshot}"

timestamp() {
    date +%Y%m%d-%H%M%S
}

backup_file() {
    local file="$1"
    local ts
    ts="$(timestamp)"

    if [ -f "$file" ]; then
        cp "$file" "$file.bak"
        cp "$file" "$file.bak.$ts"
        echo "[OK] Backup created for $file:"
        echo "     $file.bak"
        echo "     $file.bak.$ts"
    fi
}

clone_or_update() {
    local repo_url="$1"
    local target_dir="$2"

    if [ -d "$target_dir/.git" ]; then
        echo "[+] Updating $target_dir"
        git -C "$target_dir" fetch --all --prune

        if git -C "$target_dir" show-ref --verify --quiet refs/remotes/origin/dev; then
            git -C "$target_dir" checkout dev
        fi

        git -C "$target_dir" pull --recurse-submodules || true
        git -C "$target_dir" submodule update --init --recursive || true
    else
        echo "[+] Cloning $repo_url -> $target_dir"
        git clone "$repo_url" "$target_dir"

        if git -C "$target_dir" show-ref --verify --quiet refs/remotes/origin/dev; then
            git -C "$target_dir" checkout dev
        fi

        git -C "$target_dir" submodule update --init --recursive || true
    fi
}

prompt_public_access() {
    echo
    echo "[+] Configuring ArchiveBox public access..."
    echo "    Use a base domain such as archivebox.localhost, archivebox.lab, or your own domain."
    echo "    ArchiveBox v0.9/dev will use:"
    echo "      web.<domain>"
    echo "      admin.<domain>"
    echo "      api.<domain>"
    echo

    local input_host=""
    local input_port=""
    local input_scheme=""

    read -rp "ArchiveBox base domain/IP [$ARCHIVEBOX_HOST]: " input_host
    ARCHIVEBOX_HOST="${input_host:-$ARCHIVEBOX_HOST}"

    read -rp "ArchiveBox public port [$ARCHIVEBOX_PORT]: " input_port
    ARCHIVEBOX_PORT="${input_port:-$ARCHIVEBOX_PORT}"

    read -rp "ArchiveBox scheme http/https [$ARCHIVEBOX_SCHEME]: " input_scheme
    ARCHIVEBOX_SCHEME="${input_scheme:-$ARCHIVEBOX_SCHEME}"

    if [ "$ARCHIVEBOX_SCHEME" != "http" ] && [ "$ARCHIVEBOX_SCHEME" != "https" ]; then
        echo "[!] Invalid scheme: $ARCHIVEBOX_SCHEME"
        echo "    Use http or https."
        exit 1
    fi

    ARCHIVEBOX_BASE_ORIGIN="${ARCHIVEBOX_SCHEME}://${ARCHIVEBOX_HOST}:${ARCHIVEBOX_PORT}"
    ARCHIVEBOX_WEB_ORIGIN="${ARCHIVEBOX_SCHEME}://web.${ARCHIVEBOX_HOST}:${ARCHIVEBOX_PORT}"
    ARCHIVEBOX_ADMIN_ORIGIN="${ARCHIVEBOX_SCHEME}://admin.${ARCHIVEBOX_HOST}:${ARCHIVEBOX_PORT}"
    ARCHIVEBOX_API_ORIGIN="${ARCHIVEBOX_SCHEME}://api.${ARCHIVEBOX_HOST}:${ARCHIVEBOX_PORT}"

    ARCHIVEBOX_ALLOWED_HOSTS="${ARCHIVEBOX_HOST},web.${ARCHIVEBOX_HOST},admin.${ARCHIVEBOX_HOST},api.${ARCHIVEBOX_HOST},.${ARCHIVEBOX_HOST},archivebox.localhost,web.archivebox.localhost,admin.archivebox.localhost,api.archivebox.localhost,.archivebox.localhost,localhost,127.0.0.1"

    ARCHIVEBOX_CSRF_ORIGINS="${ARCHIVEBOX_BASE_ORIGIN},${ARCHIVEBOX_WEB_ORIGIN},${ARCHIVEBOX_ADMIN_ORIGIN},${ARCHIVEBOX_API_ORIGIN},${ARCHIVEBOX_SCHEME}://*.${ARCHIVEBOX_HOST}:${ARCHIVEBOX_PORT},https://${ARCHIVEBOX_HOST},https://web.${ARCHIVEBOX_HOST},https://admin.${ARCHIVEBOX_HOST},https://api.${ARCHIVEBOX_HOST},https://*.${ARCHIVEBOX_HOST},http://archivebox.localhost:8000,http://web.archivebox.localhost:8000,http://admin.archivebox.localhost:8000,http://api.archivebox.localhost:8000,http://*.archivebox.localhost:8000,https://archivebox.localhost,https://web.archivebox.localhost,https://admin.archivebox.localhost,https://api.archivebox.localhost,https://*.archivebox.localhost,https://localhost,https://127.0.0.1"

    echo
    echo "[+] ArchiveBox public URLs:"
    echo "    Base : $ARCHIVEBOX_BASE_ORIGIN"
    echo "    Web  : $ARCHIVEBOX_WEB_ORIGIN"
    echo "    Admin: $ARCHIVEBOX_ADMIN_ORIGIN"
    echo "    API  : ${ARCHIVEBOX_API_ORIGIN}/api/v1/docs"
}

echo "[+] $PATCH_NAME"
echo "[+] Patch author : $PATCH_AUTHOR"
echo "[+] Patch version: $PATCH_VERSION"
echo "[+] Patch date   : $PATCH_DATE"
echo
echo "[+] Working dir      : $(pwd)"
echo "[+] Image tag        : $IMAGE_TAG"
echo "[+] Docker cmd       : $DOCKER"
echo "[+] Compose cmd      : $COMPOSE"
echo "[+] SKIP_BUILD       : $SKIP_BUILD"
echo "[+] CREATE_SUPERUSER : $CREATE_SUPERUSER"
echo "[+] RUN_COMPOSE_UP   : $RUN_COMPOSE_UP"
echo

if [ ! -f "Dockerfile" ] || [ ! -f "pyproject.toml" ] || [ ! -f "uv.lock" ]; then
    echo "[!] Run this script from the ArchiveBox repo root."
    echo "    Expected files: Dockerfile, pyproject.toml, uv.lock"
    exit 1
fi

if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
    backup_file "$SCRIPT_NAME"
    echo
fi

echo "[+] Resetting tracked files to clean state..."
git checkout -- Dockerfile pyproject.toml uv.lock || true

echo "[+] Pulling latest ArchiveBox source..."
git fetch --all --prune
git pull --recurse-submodules || true
git submodule update --init --recursive || true

echo
echo "[+] Preparing local editable dependencies..."
clone_or_update "$ABX_DL_REPO" "abx-dl"
clone_or_update "$ABXPKG_REPO" "abxpkg"
clone_or_update "$ABX_PLUGINS_REPO" "abx-plugins"

echo
echo "[+] Editable dependencies found in uv.lock:"
grep -n 'editable = "../' uv.lock || true

echo
echo "[+] Verifying dependency folders..."
for dir in abx-dl abxpkg abx-plugins; do
    if [ ! -d "$dir" ]; then
        echo "[!] Missing folder: $dir"
        exit 1
    fi

    if [ ! -f "$dir/pyproject.toml" ]; then
        echo "[!] $dir exists but pyproject.toml was not found"
        exit 1
    fi

    echo "[OK] $dir"
done

echo
echo "[+] Backing up files before patching..."
backup_file Dockerfile
backup_file pyproject.toml
backup_file uv.lock

echo
echo "[+] Patch 1: remove broken npm self-update step..."
sed -i '/npm i -g npm --cache \/root\/.npm/d' Dockerfile

echo "[+] Patch 2: install extractor runtime deps, set browser env, and copy local editable deps..."

python3 - <<'PY'
from pathlib import Path
import re

p = Path("Dockerfile")
s = p.read_text()

# Remove previous custom bind mounts, including broken/glued variants.
for name, target in [
    ("abx-dl", "/abx-dl"),
    ("abxpkg", "/abxpkg"),
    ("abx-plugins", "/abx-plugins"),
]:
    pattern = rf'\s*--mount=type=bind,source={re.escape(name)},target={re.escape(target)}(?:,rw)?\s*\\\s*'
    s = re.sub(pattern, '', s)

s = re.sub(
    r'\n?# Install runtime dependencies for ArchiveBox extractors\n'
    r'(?:ENV PATH=.*\n)?'
    r'ENV NODE_PATH=.*\n'
    r'ENV CHROME_BINARY=/usr/bin/chromium\n'
    r'ENV CHROMIUM_BINARY=/usr/bin/chromium\n'
    r'RUN npm install -g puppeteer-core(?: puppeteer)? --no-audit --no-fund \\\n'
    r'    && apt-get update \\\n'
    r'    && apt-get install -y --no-install-recommends default-jre \\\n'
    r'    && ln -sf /usr/bin/chromium-browser /usr/bin/chromium \\\n'
    r'    && rm -rf /var/lib/apt/lists/\*\n\n',
    '\n',
    s,
)

# Remove older Puppeteer-only block if any.
s = re.sub(
    r'\n?# Install Puppeteer runtime dependency for ArchiveBox browser extractor\n'
    r'(?:ENV PATH=.*\n)?'
    r'ENV NODE_PATH=.*\n'
    r'RUN npm install -g puppeteer-core --no-audit --no-fund\n\n',
    '\n',
    s,
)

s = re.sub(
    r'\n?# Copy local editable ArchiveBox workspace deps into image\n'
    r'COPY abx-dl /abx-dl\n'
    r'COPY abxpkg /abxpkg\n'
    r'COPY abx-plugins /abx-plugins\n\n',
    '\n',
    s,
)

insert_block = """# Install runtime dependencies for ArchiveBox extractors
ENV PATH=/home/archivebox/.npm/bin:/venv/bin:/usr/share/archivebox/lib/npm/node_modules/.bin:/usr/share/archivebox/lib/pip/venv/venv/bin:/usr/share/archivebox/lib/pip/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV NODE_PATH=/usr/lib/node_modules:/usr/share/archivebox/lib/npm/node_modules:/data/personas/Default/node_modules
ENV CHROME_BINARY=/usr/local/bin/chromium-archivebox
ENV CHROMIUM_BINARY=/usr/local/bin/chromium-archivebox

RUN npm install -g puppeteer-core puppeteer --no-audit --no-fund \\
    && apt-get update \\
    && apt-get install -y --no-install-recommends \\
        default-jre \\
        build-essential \\
        gcc \\
        python3-dev \\
    && ln -sf /usr/bin/chromium-browser /usr/bin/chromium \\
    && cat > /usr/local/bin/chromium-archivebox <<'SH' \\
    && chmod +x /usr/local/bin/chromium-archivebox \\
    && rm -rf /var/lib/apt/lists/*
#!/usr/bin/env bash
set -euo pipefail

PROFILE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/archivebox-chrome-profile.XXXXXX")"

cleanup() {
    rm -rf "$PROFILE_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

ARGS=()
SKIP_NEXT=0

for arg in "$@"; do
    if [ "$SKIP_NEXT" = "1" ]; then
        SKIP_NEXT=0
        continue
    fi

    case "$arg" in
        --user-data-dir=*)
            ;;
        --user-data-dir)
            SKIP_NEXT=1
            ;;
        *)
            ARGS+=("$arg")
            ;;
    esac
done

/usr/bin/chromium "${ARGS[@]}" --user-data-dir="$PROFILE_DIR"
STATUS=$?
cleanup
exit "$STATUS"
SH

# Copy local editable ArchiveBox workspace deps into image
COPY abx-dl /abx-dl
COPY abxpkg /abxpkg
COPY abx-plugins /abx-plugins

"""

marker = "# Install ArchiveBox Python venv dependencies from uv.lock"

if marker not in s:
    raise SystemExit("[!] Could not find uv sync marker in Dockerfile")

s = s.replace(marker, insert_block + marker, 1)

p.write_text(s)
PY

echo
echo "[+] Verifying Dockerfile patch..."

if grep -n 'npm i -g npm' Dockerfile; then
    echo "[!] npm self-update line still exists. Check Dockerfile manually."
    exit 1
else
    echo "[OK] npm self-update removed"
fi

grep -n 'NODE_PATH\|CHROME_BINARY\|CHROMIUM_BINARY\|puppeteer-core\|default-jre\|build-essential\|gcc\|python3-dev\|chromium-archivebox\|COPY abx-dl\|COPY abxpkg\|COPY abx-plugins\|ln -sf /usr/bin/chromium-browser' Dockerfile

echo
echo "[+] Checking for broken old bind mounts..."
if grep -n 'source=abx-dl\|source=abxpkg\|source=abx-plugins' Dockerfile; then
    echo "[!] Old bind mount patch still exists. This should not happen."
    exit 1
else
    echo "[OK] No old bind mounts found"
fi

echo
if [ "$SKIP_BUILD" = "true" ]; then
    echo "[+] SKIP_BUILD=true, skipping Docker image build..."
    $DOCKER image inspect "$IMAGE_TAG" >/dev/null 2>&1 || {
        echo "[!] Image $IMAGE_TAG not found."
        echo "    Build it first or run without SKIP_BUILD=true."
        exit 1
    }
else
    echo "[+] Building Docker image: $IMAGE_TAG"
    $DOCKER build --no-cache -t "$IMAGE_TAG" .

    echo
    echo "[+] Build finished successfully."

    echo
    echo "[+] Testing extractor runtime dependencies in image..."
    $DOCKER run --rm "$IMAGE_TAG" bash -lc '
        echo "PATH=$PATH"
        echo "NODE_PATH=$NODE_PATH"
        echo "CHROME_BINARY=$CHROME_BINARY"
        echo "CHROMIUM_BINARY=$CHROMIUM_BINARY"
        which chromium || true
        which chromium-browser || true
        which chromium-archivebox || true
        which defuddle || true
        which trafilatura || true
        which gallery-dl || true
        which yt-dlp || true
        chromium --version || true
        chromium-archivebox --version || true
        java -version || true
        node -e "console.log(require.resolve(\"puppeteer-core\"))"
        node -e "console.log(require.resolve(\"puppeteer\"))"
    ' || true
fi

prompt_public_access

echo
echo "[+] Creating archivebox-janitor.sh..."

cat > archivebox-janitor.sh <<'JANITOR'
#!/usr/bin/env sh
set -eu

INTERVAL="${JANITOR_INTERVAL:-600}"
STALE_AFTER="${STALE_AFTER:-1800}"

while true; do
  echo "[janitor] $(date -Iseconds) checking stale ArchiveBox daemon hooks..."

  CONTAINER="$(docker ps \
    --filter "label=com.docker.compose.service=archivebox" \
    --format "{{.ID}}" \
    | head -n 1)"

  if [ -z "$CONTAINER" ]; then
    echo "[janitor] archivebox container not found"
    sleep 30
    continue
  fi

  docker exec \
    -u archivebox \
    -e STALE_AFTER="$STALE_AFTER" \
    "$CONTAINER" \
    bash -s <<'IN_CONTAINER' || true
set -euo pipefail

STALE_AFTER="${STALE_AFTER:-1800}"

ACTIVE_ADD="$(ps -eo pid,ppid,stat,etimes,cmd \
  | awk '$0 ~ /(^|[ /])archivebox add([[:space:]]|$)/ {print}' || true)"

if [ -n "$ACTIVE_ADD" ]; then
  ADD_AGE="$(echo "$ACTIVE_ADD" | awk 'NR==1 {print $4}')"

  if [ "${ADD_AGE:-0}" -lt "$STALE_AFTER" ]; then
    echo "[janitor] archivebox add is active and still fresh (${ADD_AGE}s), skipping cleanup:"
    echo "$ACTIVE_ADD"
    exit 0
  fi

  echo "[janitor] archivebox add looks stale (${ADD_AGE}s), cleanup will continue:"
  echo "$ACTIVE_ADD"
fi

echo "[janitor] orphan daemon hooks:"
ps -eo pid,ppid,stat,etimes,cmd \
  | awk '$2 == 1 && /on_(Snapshot|CrawlSetup)__.*daemon\.bg\.js/ {print}' || true

echo "[janitor] killing orphan daemon hooks..."
ps -eo pid,ppid,stat,etimes,cmd \
  | awk '$2 == 1 && /on_(Snapshot|CrawlSetup)__.*daemon\.bg\.js/ {print $1}' \
  | xargs -r kill || true

sleep 2

echo "[janitor] killing daemon hooks older than '"$STALE_AFTER"'s..."
ps -eo pid,ppid,stat,etimes,cmd \
  | awk -v stale="$STALE_AFTER" '$4 > stale && /on_(Snapshot|CrawlSetup)__.*daemon\.bg\.js/ {print $1}' \
  | xargs -r kill || true

echo "[janitor] cleaning old temporary Chrome profiles..."
find /tmp -maxdepth 1 -type d -name "archivebox-chrome-profile.*" -mmin +30 -print -exec rm -rf {} + 2>/dev/null || true

echo "[janitor] done"
IN_CONTAINER

  sleep "$INTERVAL"
done
JANITOR

chmod +x archivebox-janitor.sh

echo
echo "[+] Creating docker-compose.override.yml..."

if [ -f "docker-compose.override.yml" ]; then
    backup_file docker-compose.override.yml
fi

cat > docker-compose.override.yml <<EOF
x-archivebox-env: &archivebox-env
  LISTEN_HOST: "${ARCHIVEBOX_HOST}:${ARCHIVEBOX_PORT}"
  ALLOWED_HOSTS: '${ARCHIVEBOX_ALLOWED_HOSTS}'
  CSRF_TRUSTED_ORIGINS: '${ARCHIVEBOX_CSRF_ORIGINS}'
  PATH: "${PATH_VALUE}"
  NODE_PATH: "${NODE_PATH_VALUE}"
  PUPPETEER_EXECUTABLE_PATH: "${CHROME_BINARY_VALUE}"
  CHROME_BIN: "${CHROME_BINARY_VALUE}"
  CHROME_BINARY: "${CHROME_BINARY_VALUE}"
  CHROMIUM_BINARY: "${CHROME_BINARY_VALUE}"
  CHROME_HEADLESS: "true"
  CHROME_SANDBOX: "false"
  CHROME_ISOLATION: "${CHROME_ISOLATION_VALUE}"
  CHROME_ARGS_EXTRA: '${CHROME_ARGS_EXTRA_JSON}'

services:
  archivebox:
    image: $IMAGE_TAG
    ports:
      - "${ARCHIVEBOX_PORT}:8000"
    shm_size: "1gb"
    environment: *archivebox-env
    command: server --init 0.0.0.0:8000

  archivebox-janitor:
    image: docker:cli
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./:/work
    working_dir: /work
    environment:
      STALE_AFTER: "1800"
      JANITOR_INTERVAL: "600"
    command: sh /work/archivebox-janitor.sh
EOF

echo "[OK] docker-compose.override.yml created:"
cat docker-compose.override.yml

if [ "$RUN_COMPOSE_UP" = "true" ]; then
    echo
    echo "[+] Validating generated environment values..."
    $COMPOSE run --rm --user archivebox --entrypoint bash archivebox -lc '
    echo "LISTEN_HOST=$LISTEN_HOST"
    echo "ALLOWED_HOSTS=$ALLOWED_HOSTS"
    echo "CSRF_TRUSTED_ORIGINS=$CSRF_TRUSTED_ORIGINS"
    echo "CHROME_HEADLESS=$CHROME_HEADLESS"
    echo "CHROME_SANDBOX=$CHROME_SANDBOX"
    echo "CHROME_ISOLATION=$CHROME_ISOLATION"
    echo "CHROME_ARGS_EXTRA=$CHROME_ARGS_EXTRA"

    echo
    echo "ALLOWED_HOSTS parsed:"
    printf "%s\n" "$ALLOWED_HOSTS" | tr "," "\n"

    echo
    echo "CSRF_TRUSTED_ORIGINS parsed:"
    printf "%s\n" "$CSRF_TRUSTED_ORIGINS" | tr "," "\n"

    echo
    echo "CHROME_ARGS raw JSON:"
    echo "$CHROME_ARGS"
    '

    echo
    echo "[+] Ensuring /data is writable by archivebox user..."

    $COMPOSE run --rm --user root --entrypoint bash archivebox -lc '
        mkdir -p /data
        chown -R archivebox:archivebox /data
        chmod -R u+rwX /data
    '
    echo
    echo "[+] Initializing ArchiveBox collection if needed..."
    echo "    Running init with runtime config env unset to avoid v0.9/dev JSON parser crash."

    $COMPOSE run --rm --user archivebox --entrypoint bash archivebox -lc '
        unset LISTEN_HOST
        unset ALLOWED_HOSTS
        unset CSRF_TRUSTED_ORIGINS
        unset CHROME_ARGS
        unset CHROME_ARGS_EXTRA
        unset CHROME_ISOLATION
        archivebox init
    '

    if [ "$CREATE_SUPERUSER" = "true" ]; then
        echo
        echo "[+] Creating ArchiveBox superuser interactively..."
        echo "    Running createsuperuser with runtime config env unset to avoid config parser issues."

        $COMPOSE run --rm --user archivebox --entrypoint bash archivebox -lc '
            unset LISTEN_HOST
            unset ALLOWED_HOSTS
            unset CSRF_TRUSTED_ORIGINS
            unset CHROME_ARGS
            unset CHROME_ARGS_EXTRA
            unset CHROME_ISOLATION
            archivebox manage createsuperuser
        ' || true
    fi

    echo
    echo "[+] Starting ArchiveBox with Docker Compose..."
    $COMPOSE down --remove-orphans
    $COMPOSE up -d --force-recreate

    echo
    echo "[+] Compose status:"
    $COMPOSE ps

    echo
    echo "[+] ArchiveBox logs:"
    $COMPOSE logs --tail=100 archivebox || true

    echo
    echo "[+] Testing extractor runtime inside running container..."
    $COMPOSE exec archivebox bash -lc '
        echo "PATH=$PATH"
        echo "NODE_PATH=$NODE_PATH"
        echo "CHROME_BINARY=$CHROME_BINARY"
        echo "CHROMIUM_BINARY=$CHROMIUM_BINARY"
        echo "CHROME_HEADLESS=$CHROME_HEADLESS"
        echo "CHROME_SANDBOX=$CHROME_SANDBOX"
        echo "CHROME_ARGS_EXTRA=$CHROME_ARGS_EXTRA"

        which chromium || true
        which chromium-browser || true
        which chromium-archivebox || true
        which defuddle || true
        which trafilatura || true
        which gallery-dl || true
        which yt-dlp || true

        chromium --version || true
        chromium-archivebox --version || true
        java -version || true

        node -e "console.log(require.resolve(\"puppeteer-core\"))" || true
        node -e "console.log(require.resolve(\"puppeteer\"))" || true
    ' || true

    echo
    echo "[+] Access ArchiveBox:"
    echo "    Base : $ARCHIVEBOX_BASE_ORIGIN"
    echo "    Web  : $ARCHIVEBOX_WEB_ORIGIN"
    echo "    Admin: $ARCHIVEBOX_ADMIN_ORIGIN"
    echo "    API  : ${ARCHIVEBOX_API_ORIGIN}/api/v1/docs"
    echo
    echo "[!] Make sure DNS or /etc/hosts resolves these names to your ArchiveBox server:"
    echo "    $ARCHIVEBOX_HOST"
    echo "    web.$ARCHIVEBOX_HOST"
    echo "    admin.$ARCHIVEBOX_HOST"
    echo "    api.$ARCHIVEBOX_HOST"
else
    echo
    echo "[+] RUN_COMPOSE_UP=false, skipping init/superuser/compose up."
fi

echo
echo "[+] Done."
