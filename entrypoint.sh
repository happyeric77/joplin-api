#!/bin/bash
set -e

# =============================================================================
# Joplin CLI API Runtime Entrypoint
#
# Configures Joplin via environment variables, starts the Data API server,
# sets up periodic WebDAV sync via cron with flock overlap prevention,
# and runs a socat proxy so the API is reachable from outside localhost.
#
# Environment variables (required):
#   JOPLIN_WEBDAV_URL   - WebDAV sync target URL
#   JOPLIN_WEBDAV_USER  - WebDAV username
#   JOPLIN_WEBDAV_PASS  - WebDAV password
#   JOPLIN_API_TOKEN    - Joplin Data API bearer token
#
# Environment variables (optional):
#   JOPLIN_PROFILE_DIR  - profile directory (default: /data/joplin-profile)
#   JOPLIN_API_PORT     - Data API listen port (default: 41184)
#   JOPLIN_PROXY_PORT   - socat proxy listen port (default: 41185)
#   JOPLIN_SYNC_INTERVAL - sync interval in minutes (default: 2)
# =============================================================================

# ------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------
PROFILE_DIR="${JOPLIN_PROFILE_DIR:-/data/joplin-profile}"
JOPLIN_BIN="$(command -v joplin)"
JOPLIN="nice ${JOPLIN_BIN} --profile ${PROFILE_DIR}"

# Required - fail fast if missing
SYNC_URL="${JOPLIN_WEBDAV_URL:?JOPLIN_WEBDAV_URL is required}"
SYNC_USER="${JOPLIN_WEBDAV_USER:?JOPLIN_WEBDAV_USER is required}"
SYNC_PASS="${JOPLIN_WEBDAV_PASS:?JOPLIN_WEBDAV_PASS is required}"
API_TOKEN="${JOPLIN_API_TOKEN:?JOPLIN_API_TOKEN is required}"

# Optional with defaults
SYNC_INTERVAL="${JOPLIN_SYNC_INTERVAL:-2}"
API_PORT="${JOPLIN_API_PORT:-41184}"
PROXY_PORT="${JOPLIN_PROXY_PORT:-41185}"

mkdir -p "${PROFILE_DIR}"

# ------------------------------------------------------------------
# Configure Joplin
# All config commands are silenced to prevent credential leakage in logs.
# ------------------------------------------------------------------
echo "Configuring Joplin..."
${JOPLIN} config sync.target 6          >/dev/null 2>&1
${JOPLIN} config sync.6.path "${SYNC_URL}"     >/dev/null 2>&1
${JOPLIN} config sync.6.username "${SYNC_USER}" >/dev/null 2>&1
${JOPLIN} config sync.6.password "${SYNC_PASS}" >/dev/null 2>&1
${JOPLIN} config api.token "${API_TOKEN}"       >/dev/null 2>&1

# ------------------------------------------------------------------
# Initial sync (best-effort — network may not be ready on first boot)
# ------------------------------------------------------------------
echo "Running initial sync..."
if ${JOPLIN} sync >/dev/null 2>&1; then
    echo "Initial sync completed successfully."
else
    echo "Warning: initial sync failed (will retry via cron when network is ready)."
fi

# ------------------------------------------------------------------
# Periodic sync via cron with flock overlap prevention
# ------------------------------------------------------------------
echo "Setting up periodic sync every ${SYNC_INTERVAL} minute(s)..."
mkdir -p /var/log/joplin

cat > /tmp/joplin-cron << EOF
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/${SYNC_INTERVAL} * * * * flock -n /tmp/joplin-sync.lock ${JOPLIN_BIN} --profile ${PROFILE_DIR} sync >> /var/log/joplin/sync.log 2>&1
EOF

crontab /tmp/joplin-cron
rm -f /tmp/joplin-cron

# Start cron daemon in background
cron

# ------------------------------------------------------------------
# Start Joplin Data API server (background)
# ------------------------------------------------------------------
echo "Starting Joplin Data API server on 127.0.0.1:${API_PORT}..."
${JOPLIN} server start >/dev/null 2>&1 &

# Allow server to initialize
sleep 2

# ------------------------------------------------------------------
# Start socat TCP proxy as the foreground process
# Maps 0.0.0.0:PROXY_PORT -> 127.0.0.1:API_PORT
# ------------------------------------------------------------------
echo "Starting socat proxy: 0.0.0.0:${PROXY_PORT} -> 127.0.0.1:${API_PORT}..."
exec socat TCP-LISTEN:${PROXY_PORT},fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:${API_PORT}
