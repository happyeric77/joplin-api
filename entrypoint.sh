#!/bin/bash
set -e

# Joplin CLI API Runtime Entrypoint
# Configures Joplin via environment variables, then runs a single-writer loop
# that alternates between the Data API server and WebDAV sync.

PROFILE_DIR="${JOPLIN_PROFILE_DIR:-/data/joplin-profile}"
JOPLIN_BIN="$(command -v joplin)"
SYNC_LOG="/var/log/joplin/sync.log"

SYNC_URL="${JOPLIN_WEBDAV_URL:?JOPLIN_WEBDAV_URL is required}"
SYNC_USER="${JOPLIN_WEBDAV_USER:?JOPLIN_WEBDAV_USER is required}"
SYNC_PASS="${JOPLIN_WEBDAV_PASS:?JOPLIN_WEBDAV_PASS is required}"
API_TOKEN="${JOPLIN_API_TOKEN:?JOPLIN_API_TOKEN is required}"
SYNC_INTERVAL="${JOPLIN_SYNC_INTERVAL:-2}"

JOPLIN_BASE_CMD=(nice "${JOPLIN_BIN}" --profile "${PROFILE_DIR}")
SERVER_PID=""

timestamp() {
    date -Iseconds
}

log_stdout() {
    printf '[%s] %s\n' "$(timestamp)" "$*"
}

log_sync() {
    printf '[%s] %s\n' "$(timestamp)" "$*" >> "${SYNC_LOG}"
}

server_is_running() {
    [ -n "${SERVER_PID}" ] && kill -0 "${SERVER_PID}" 2>/dev/null
}

start_server() {
    log_stdout "Starting Joplin Data API server..."
    "${JOPLIN_BASE_CMD[@]}" server start &
    SERVER_PID=$!
    log_stdout "Joplin Data API server started with PID ${SERVER_PID}."
}

stop_server() {
    if ! server_is_running; then
        if [ -n "${SERVER_PID}" ]; then
            wait "${SERVER_PID}" 2>/dev/null || true
        fi
        SERVER_PID=""
        return 0
    fi

    log_stdout "Stopping Joplin Data API server (PID ${SERVER_PID}) before sync..."
    kill -TERM "${SERVER_PID}" 2>/dev/null || true

    if wait "${SERVER_PID}"; then
        log_stdout "Joplin Data API server stopped cleanly."
    else
        status=$?
        log_stdout "Joplin Data API server exited with status ${status} during stop."
    fi

    SERVER_PID=""
}

run_sync() {
    log_stdout "Starting Joplin sync; output will be appended to ${SYNC_LOG}."
    log_sync "Sync started."

    if "${JOPLIN_BASE_CMD[@]}" sync >> "${SYNC_LOG}" 2>&1; then
        log_stdout "Joplin sync completed successfully."
        log_sync "Sync completed successfully."
    else
        status=$?
        log_stdout "Joplin sync failed with exit code ${status}; continuing to next cycle."
        log_sync "Sync failed with exit code ${status}; continuing to next cycle."
    fi
}

cleanup() {
    log_stdout "Received shutdown signal; stopping Joplin services..."
    stop_server
    log_stdout "Shutdown complete."
    exit 0
}

mkdir -p "${PROFILE_DIR}" /var/log/joplin
touch "${SYNC_LOG}"

trap cleanup SIGTERM SIGINT

log_stdout "Configuring Joplin profile at ${PROFILE_DIR}..."
"${JOPLIN_BASE_CMD[@]}" config sync.target 6 >/dev/null 2>&1
"${JOPLIN_BASE_CMD[@]}" config sync.6.path "${SYNC_URL}" >/dev/null 2>&1
"${JOPLIN_BASE_CMD[@]}" config sync.6.username "${SYNC_USER}" >/dev/null 2>&1
"${JOPLIN_BASE_CMD[@]}" config sync.6.password "${SYNC_PASS}" >/dev/null 2>&1
"${JOPLIN_BASE_CMD[@]}" config api.token "${API_TOKEN}" >/dev/null 2>&1

log_stdout "Initial sync is deferred to preserve Data API availability after startup. First maintenance sync will run after ${SYNC_INTERVAL} minute(s)."
start_server

while true; do
    log_stdout "Joplin server running; next sync window in ${SYNC_INTERVAL} minute(s)."
    sleep "$((SYNC_INTERVAL * 60))"

    stop_server
    run_sync
    start_server
done
