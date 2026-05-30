#!/bin/bash
set -e

# Joplin CLI API Runtime Entrypoint
# Configures Joplin via environment variables, then runs a single-writer loop
# that alternates between the Data API server and WebDAV sync.

PROFILE_DIR="${JOPLIN_PROFILE_DIR:-/data/joplin-profile}"
JOPLIN_BIN="$(command -v joplin)"
SYNC_LOG="/var/log/joplin/sync.log"
API_BASE_URL="http://localhost:41184"

SYNC_URL="${JOPLIN_WEBDAV_URL:?JOPLIN_WEBDAV_URL is required}"
SYNC_USER="${JOPLIN_WEBDAV_USER:?JOPLIN_WEBDAV_USER is required}"
SYNC_PASS="${JOPLIN_WEBDAV_PASS:?JOPLIN_WEBDAV_PASS is required}"
API_TOKEN="${JOPLIN_API_TOKEN:?JOPLIN_API_TOKEN is required}"

if [ -n "${JOPLIN_PERIODIC_SYNC_INTERVAL_SECONDS:-}" ]; then
    PERIODIC_SYNC_INTERVAL_SECONDS="${JOPLIN_PERIODIC_SYNC_INTERVAL_SECONDS}"
    PERIODIC_SYNC_SOURCE="JOPLIN_PERIODIC_SYNC_INTERVAL_SECONDS"
else
    LEGACY_SYNC_INTERVAL_MINUTES="${JOPLIN_SYNC_INTERVAL:-10}"
    if ! [[ "${LEGACY_SYNC_INTERVAL_MINUTES}" =~ ^[1-9][0-9]*$ ]]; then
        printf '[%s] %s\n' "$(date -Iseconds)" "Invalid JOPLIN_SYNC_INTERVAL='${LEGACY_SYNC_INTERVAL_MINUTES}'. Expected a positive integer number of minutes." >&2
        exit 1
    fi
    PERIODIC_SYNC_INTERVAL_SECONDS="$((LEGACY_SYNC_INTERVAL_MINUTES * 60))"
    PERIODIC_SYNC_SOURCE="JOPLIN_SYNC_INTERVAL"
fi

EVENT_POLL_INTERVAL_SECONDS="${JOPLIN_EVENT_POLL_INTERVAL_SECONDS:-15}"
EVENT_SYNC_DEBOUNCE_SECONDS="${JOPLIN_EVENT_SYNC_DEBOUNCE_SECONDS:-30}"

JOPLIN_BASE_CMD=(nice "${JOPLIN_BIN}" --profile "${PROFILE_DIR}")
SERVER_PID=""
EVENT_CURSOR=""
EVENT_SYNC_DUE_AT=""
NEXT_PERIODIC_SYNC_AT=""

timestamp() {
    date -Iseconds
}

log_stdout() {
    printf '[%s] %s\n' "$(timestamp)" "$*"
}

log_sync() {
    printf '[%s] %s\n' "$(timestamp)" "$*" >> "${SYNC_LOG}"
}

now_epoch() {
    date +%s
}

validate_positive_integer() {
    local name="$1"
    local value="$2"

    if ! [[ "${value}" =~ ^[1-9][0-9]*$ ]]; then
        log_stdout "Invalid ${name}='${value}'. Expected a positive integer."
        exit 1
    fi
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

wait_for_server_api() {
    log_stdout "Waiting for Joplin Data API readiness on ${API_BASE_URL}/ping..."

    while true; do
        if ! server_is_running; then
            log_stdout "Joplin Data API server is no longer running while waiting for readiness."
            exit 1
        fi

        if curl --silent --show-error --fail --max-time 5 "${API_BASE_URL}/ping" >/dev/null; then
            log_stdout "Joplin Data API is ready."
            return 0
        fi

        log_stdout "Joplin Data API not ready yet; retrying in 2 seconds."
        sleep 2
    done
}

extract_cursor_from_events_response() {
    local response="$1"

    printf '%s' "${response}" \
        | tr -d '\n\r' \
        | sed -n 's/.*"cursor":[[:space:]]*"\{0,1\}\([^",}[:space:]]\{1,\}\)"\{0,1\}.*/\1/p'
}

events_response_has_items() {
    local response="$1"
    local compact_response

    compact_response="$(printf '%s' "${response}" | tr -d '\n\r\t ')"

    case "${compact_response}" in
        *'"items":[]'*)
            return 1
            ;;
        *'"items":['*)
            return 0
            ;;
        *)
            log_stdout "Unable to determine whether /events returned items. Response: ${response}"
            return 2
            ;;
    esac
}

fetch_events() {
    local url="${API_BASE_URL}/events?token=${API_TOKEN}"

    if [ -n "$1" ]; then
        url="${url}&cursor=$1"
    fi

    curl --silent --show-error --fail --max-time 10 "${url}"
}

initialize_event_cursor() {
    local response=""
    local cursor=""

    log_stdout "Initializing Joplin events cursor via /events."

    while true; do
        if ! server_is_running; then
            log_stdout "Joplin Data API server stopped before events cursor initialization completed."
            exit 1
        fi

        if response="$(fetch_events "")"; then
            cursor="$(extract_cursor_from_events_response "${response}")"

            if [ -n "${cursor}" ]; then
                EVENT_CURSOR="${cursor}"
                EVENT_SYNC_DUE_AT=""
                log_stdout "Initialized Joplin events cursor at ${EVENT_CURSOR}."
                return 0
            fi

            log_stdout "Joplin /events response did not include a cursor. Response: ${response}"
        else
            log_stdout "Failed to initialize Joplin events cursor; retrying in 2 seconds."
        fi

        sleep 2
    done
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

schedule_event_sync() {
    EVENT_SYNC_DUE_AT="$(($(now_epoch) + EVENT_SYNC_DEBOUNCE_SECONDS))"
    log_stdout "Detected note change events; scheduling sync in ${EVENT_SYNC_DEBOUNCE_SECONDS} second(s) at ${EVENT_SYNC_DUE_AT}."
}

poll_events_once() {
    local response=""
    local next_cursor=""
    local items_status=0

    if ! response="$(fetch_events "${EVENT_CURSOR}")"; then
        log_stdout "Failed to poll Joplin /events with cursor ${EVENT_CURSOR}; will retry on next poll."
        return 1
    fi

    next_cursor="$(extract_cursor_from_events_response "${response}")"
    if [ -z "${next_cursor}" ]; then
        log_stdout "Joplin /events poll response did not include a cursor. Response: ${response}"
        return 1
    fi

    EVENT_CURSOR="${next_cursor}"

    if events_response_has_items "${response}"; then
        schedule_event_sync
    else
        items_status=$?

        if [ "${items_status}" -eq 1 ]; then
            log_stdout "No new note events; cursor advanced to ${EVENT_CURSOR}."
            return 0
        fi

        return 1
    fi

    return 0
}

restart_server_and_reinitialize_events() {
    start_server
    wait_for_server_api
    initialize_event_cursor
}

run_sync_cycle() {
    local reason="$1"

    log_stdout "Starting sync cycle because ${reason}."
    stop_server
    run_sync
    restart_server_and_reinitialize_events
    NEXT_PERIODIC_SYNC_AT="$(($(now_epoch) + PERIODIC_SYNC_INTERVAL_SECONDS))"
    EVENT_SYNC_DUE_AT=""
    log_stdout "Sync cycle complete. Next periodic sync deadline is ${NEXT_PERIODIC_SYNC_AT}."
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

validate_positive_integer "JOPLIN_PERIODIC_SYNC_INTERVAL_SECONDS" "${PERIODIC_SYNC_INTERVAL_SECONDS}"
validate_positive_integer "JOPLIN_EVENT_POLL_INTERVAL_SECONDS" "${EVENT_POLL_INTERVAL_SECONDS}"
validate_positive_integer "JOPLIN_EVENT_SYNC_DEBOUNCE_SECONDS" "${EVENT_SYNC_DEBOUNCE_SECONDS}"

log_stdout "Configuring Joplin profile at ${PROFILE_DIR}..."
"${JOPLIN_BASE_CMD[@]}" config sync.target 6 >/dev/null 2>&1
"${JOPLIN_BASE_CMD[@]}" config sync.6.path "${SYNC_URL}" >/dev/null 2>&1
"${JOPLIN_BASE_CMD[@]}" config sync.6.username "${SYNC_USER}" >/dev/null 2>&1
"${JOPLIN_BASE_CMD[@]}" config sync.6.password "${SYNC_PASS}" >/dev/null 2>&1
"${JOPLIN_BASE_CMD[@]}" config api.token "${API_TOKEN}" >/dev/null 2>&1

if [ "${PERIODIC_SYNC_SOURCE}" = "JOPLIN_SYNC_INTERVAL" ]; then
    log_stdout "Using legacy JOPLIN_SYNC_INTERVAL minute-based setting for periodic sync compatibility."
fi

log_stdout "Initial sync is deferred to preserve Data API availability after startup. Periodic sync interval=${PERIODIC_SYNC_INTERVAL_SECONDS}s, event poll interval=${EVENT_POLL_INTERVAL_SECONDS}s, debounce=${EVENT_SYNC_DEBOUNCE_SECONDS}s."
restart_server_and_reinitialize_events
NEXT_PERIODIC_SYNC_AT="$(($(now_epoch) + PERIODIC_SYNC_INTERVAL_SECONDS))"

while true; do
    now="$(now_epoch)"

    if [ -n "${EVENT_SYNC_DUE_AT}" ] && [ "${now}" -ge "${EVENT_SYNC_DUE_AT}" ]; then
        run_sync_cycle "the event debounce window elapsed"
        continue
    fi

    if [ "${now}" -ge "${NEXT_PERIODIC_SYNC_AT}" ]; then
        run_sync_cycle "the periodic sync interval elapsed"
        continue
    fi

    sleep_seconds="${EVENT_POLL_INTERVAL_SECONDS}"

    if [ -n "${EVENT_SYNC_DUE_AT}" ]; then
        event_wait_seconds="$((EVENT_SYNC_DUE_AT - now))"
        if [ "${event_wait_seconds}" -lt "${sleep_seconds}" ]; then
            sleep_seconds="${event_wait_seconds}"
        fi
    fi

    periodic_wait_seconds="$((NEXT_PERIODIC_SYNC_AT - now))"
    if [ "${periodic_wait_seconds}" -lt "${sleep_seconds}" ]; then
        sleep_seconds="${periodic_wait_seconds}"
    fi

    if [ "${sleep_seconds}" -le 0 ]; then
        continue
    fi

    log_stdout "Joplin server running; sleeping ${sleep_seconds}s before next /events poll or sync deadline check."
    sleep "${sleep_seconds}"
    if ! poll_events_once; then
        log_stdout "Joplin /events polling iteration ended with an error; continuing main loop."
    fi
done
