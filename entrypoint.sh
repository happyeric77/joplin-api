#!/bin/bash
set -e

# Joplin CLI API Runtime Entrypoint
# Configures Joplin via environment variables, starts the Data API server,
# and sets up periodic WebDAV sync via cron with flock overlap prevention.

PROFILE_DIR="${JOPLIN_PROFILE_DIR:-/data/joplin-profile}"
JOPLIN_BIN="$(command -v joplin)"
JOPLIN="nice ${JOPLIN_BIN} --profile ${PROFILE_DIR}"

SYNC_URL="${JOPLIN_WEBDAV_URL:?JOPLIN_WEBDAV_URL is required}"
SYNC_USER="${JOPLIN_WEBDAV_USER:?JOPLIN_WEBDAV_USER is required}"
SYNC_PASS="${JOPLIN_WEBDAV_PASS:?JOPLIN_WEBDAV_PASS is required}"
API_TOKEN="${JOPLIN_API_TOKEN:?JOPLIN_API_TOKEN is required}"
SYNC_INTERVAL="${JOPLIN_SYNC_INTERVAL:-2}"

mkdir -p "${PROFILE_DIR}"

${JOPLIN} config sync.target 6          >/dev/null 2>&1
${JOPLIN} config sync.6.path "${SYNC_URL}"     >/dev/null 2>&1
${JOPLIN} config sync.6.username "${SYNC_USER}" >/dev/null 2>&1
${JOPLIN} config sync.6.password "${SYNC_PASS}" >/dev/null 2>&1
${JOPLIN} config api.token "${API_TOKEN}"       >/dev/null 2>&1

if ${JOPLIN} sync >/dev/null 2>&1; then
    echo "Initial sync completed successfully."
else
    echo "Initial sync failed (will retry via cron)."
fi

echo "PATH=/usr/local/bin:/usr/bin:/bin
*/${SYNC_INTERVAL} * * * * flock -n /tmp/joplin-sync.lock ${JOPLIN_BIN} --profile ${PROFILE_DIR} sync >> /var/log/joplin/sync.log 2>&1" | crontab -
touch /var/log/joplin/sync.log
cron

${JOPLIN} server start &
wait $!
