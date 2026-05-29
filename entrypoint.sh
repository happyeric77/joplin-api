#!/bin/bash
set -e

# Joplin CLI API Runtime Entrypoint
# Configures Joplin via environment variables, starts the Data API server,
# and sets up periodic WebDAV sync via cron with flock overlap prevention.

PROFILE_DIR="${JOPLIN_PROFILE_DIR:-/data/joplin-profile}"
JOPLIN_BIN="$(command -v joplin)"
JOPLIN="nice ${JOPLIN_BIN} --profile ${PROFILE_DIR}"
SYNC_LOG="/var/log/joplin/sync.log"
SYNC_LOCK="/tmp/joplin-sync.lock"

SYNC_URL="${JOPLIN_WEBDAV_URL:?JOPLIN_WEBDAV_URL is required}"
SYNC_USER="${JOPLIN_WEBDAV_USER:?JOPLIN_WEBDAV_USER is required}"
SYNC_PASS="${JOPLIN_WEBDAV_PASS:?JOPLIN_WEBDAV_PASS is required}"
API_TOKEN="${JOPLIN_API_TOKEN:?JOPLIN_API_TOKEN is required}"
SYNC_INTERVAL="${JOPLIN_SYNC_INTERVAL:-2}"

mkdir -p "${PROFILE_DIR}" /var/log/joplin
touch "${SYNC_LOG}"

echo "Configuring Joplin profile at ${PROFILE_DIR}..."
${JOPLIN} config sync.target 6          >/dev/null 2>&1
${JOPLIN} config sync.6.path "${SYNC_URL}"     >/dev/null 2>&1
${JOPLIN} config sync.6.username "${SYNC_USER}" >/dev/null 2>&1
${JOPLIN} config sync.6.password "${SYNC_PASS}" >/dev/null 2>&1
${JOPLIN} config api.token "${API_TOKEN}"       >/dev/null 2>&1

echo "Installing cron sync schedule (every ${SYNC_INTERVAL} minutes)..."
cat <<EOF | crontab -
PATH=/usr/local/bin:/usr/bin:/bin
*/${SYNC_INTERVAL} * * * * flock -n "${SYNC_LOCK}" "${JOPLIN_BIN}" --profile "${PROFILE_DIR}" sync >> "${SYNC_LOG}" 2>&1
EOF

echo "Starting cron daemon..."
cron

echo "Starting Joplin Data API server..."
${JOPLIN} server start &
SERVER_PID=$!

echo "Launching initial sync in background; follow ${SYNC_LOG} for progress."
(
    if flock -n 9; then
        printf '[%s] Initial sync started.\n' "$(date -Iseconds)" >> "${SYNC_LOG}"
        if "${JOPLIN_BIN}" --profile "${PROFILE_DIR}" sync >> "${SYNC_LOG}" 2>&1; then
            printf '[%s] Initial sync completed successfully.\n' "$(date -Iseconds)" >> "${SYNC_LOG}"
        else
            status=$?
            printf '[%s] Initial sync failed with exit code %s. Cron will retry.\n' "$(date -Iseconds)" "${status}" >> "${SYNC_LOG}"
            exit "${status}"
        fi
    else
        printf '[%s] Initial sync skipped because another sync is already running.\n' "$(date -Iseconds)" >> "${SYNC_LOG}"
    fi

) 9>"${SYNC_LOCK}" &

wait "${SERVER_PID}"
