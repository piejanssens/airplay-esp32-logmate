#!/usr/bin/env bash
#
# capture_logs.sh
#
# Reads config.yaml and, for each enabled device, runs a background loop
# that connects to the websocket log stream and appends timestamped lines to
# logs/<name>.log. If a connection drops, it reconnects after a short
# backoff. Runs until killed (Ctrl+C or `docker stop`).
#
# config.yaml format:
#
#   devices:
#     - name: esp32-221           # required, used for the log filename
#       url: ws://192.168.1.221/ws/logs   # required
#     - name: esp32-213
#       url: ws://192.168.1.213/ws/logs
#       enabled: false            # optional, default true
#       logfile: custom.log       # optional, default <name>.log

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-./config.yaml}"
LOG_DIR="${LOG_DIR:-./logs}"
RECONNECT_DELAY="${RECONNECT_DELAY:-5}"
# Off by default — a browser's WebSocket client never sends its own pings,
# it only replies to server-initiated ones. Forcing client pings has been
# observed to make some embedded websocket servers close the connection.
# Set WS_PING_INTERVAL=30 (seconds) to re-enable if you specifically need it.
WS_PING_INTERVAL="${WS_PING_INTERVAL:-}"
# Seconds between passive "last line N ago" reports on stdout. Purely local —
# nothing is sent to the devices. Set to 0 to disable.
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-900}"

mkdir -p "$LOG_DIR"

if ! command -v websocat >/dev/null 2>&1; then
    echo "ERROR: websocat is not installed. See README for install instructions." >&2
    exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
    echo "ERROR: yq is not installed; it is required to read $CONFIG_FILE." >&2
    exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: config file not found at $CONFIG_FILE" >&2
    exit 1
fi

pids=()
watched=()

cleanup() {
    echo "Stopping all device log capture..."
    for pid in "${pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    exit 0
}
trap cleanup INT TERM

# Reads lines on stdin and re-emits them with an ISO-8601 timestamp, plus an
# optional tag used to mark websocat's own diagnostics apart from device output.
timestamp_stream() {
    local tag="${1:-}"
    while IFS= read -r line; do
        printf '%s %s%s\n' "$(date -Iseconds)" "${tag:+$tag }" "$line"
    done
}

# Records a capture-level event (connect, disconnect, reconnect) to the
# container's stdout AND into the device's own log file. The log file copy is
# what survives `docker compose up --build`, which discards `docker logs`.
log_event() {
    local name="$1" logfile="$2" msg="$3"
    local line
    line="$(date -Iseconds) [capture] $msg"
    echo "[$name] $msg"
    echo "$line" >> "$logfile"
}

# Passive liveness report: every HEARTBEAT_INTERVAL seconds, print how long
# each device has been silent. Sends nothing to the devices — a silent device
# may simply be idle (these only log during playback), so this is a signal for
# a human to interpret, not an error condition. Set to 0 to disable.
heartbeat() {
    local interval="$1"; shift
    local entry name file age
    while true; do
        sleep "$interval"
        for entry in "$@"; do
            name="${entry%%|*}"; file="${entry#*|}"
            [[ -f "$file" ]] || continue
            age=$(( $(date +%s) - $(stat -c %Y "$file") ))
            printf '%s [heartbeat] %s: last line %dm %ds ago\n' \
                "$(date -Iseconds)" "$name" "$((age / 60))" "$((age % 60))"
        done
    done
}

capture_device() {
    local name="$1"
    local url="$2"
    local logfile="$LOG_DIR/$3"

    while true; do
        log_event "$name" "$logfile" "connecting to $url ..."
        local ping_args=()
        if [[ -n "$WS_PING_INTERVAL" ]]; then
            ping_args=(--ping-interval "$WS_PING_INTERVAL")
        fi
        # -U: unidirectional-reverse — never read stdin, only receive from the
        #     websocket. This is the actual fix, verified empirically: with a
        #     detached container's stdin at EOF, websocat's *forward* direction
        #     (stdin -> websocket) finishes immediately, which tears down the
        #     whole session even with -n. -U inhibits that forward direction
        #     entirely so EOF on stdin never happens/matters. (Note: despite
        #     the naming, plain -u does NOT achieve this — confirmed by testing.)
        # -n: don't send a Close frame on EOF, as extra insurance.
        # -v: verbose, so close reasons/handshake errors are captured for diagnosis.
        # -b: binary mode, so the payload passes through byte-for-byte and the
        #     firmware's own newline framing becomes our line framing: one log
        #     record per line, each with its own ISO-8601 timestamp. Do NOT use
        #     -t here — text mode enforces one-message-per-line by rewriting
        #     newlines *inside* a message to spaces, and the device batches many
        #     records per message under load (~12 observed), welding them onto a
        #     single line. -t also injects a spurious newline at every message
        #     boundary, splitting records that span two messages. Verified by
        #     sending one message containing "AAA\nBBB\nCCC": -t yields
        #     "AAA BBB CCC\n", -b yields the bytes unchanged.
        # websocat's stderr is timestamped too and merged into the same .log,
        # tagged [websocat], so errors sit in chronological order next to the
        # device output that preceded them.
        if websocat -b -v -U -n "${ping_args[@]}" "$url" < /dev/null \
                2> >(timestamp_stream '[websocat]' >> "$logfile") \
            | timestamp_stream >> "$logfile"; then
            log_event "$name" "$logfile" "connection closed cleanly, reconnecting in ${RECONNECT_DELAY}s..."
        else
            log_event "$name" "$logfile" "connection failed, reconnecting in ${RECONNECT_DELAY}s..."
        fi
        sleep "$RECONNECT_DELAY"
    done
}

echo "Starting capture for devices listed in $CONFIG_FILE"
echo "Logs will be written to $LOG_DIR/"
echo

# yq exits 0 on an empty or absent "devices:" key, so the entry count is
# validated separately below. Missing fields would render as the literal
# string "null", hence the // "" fallbacks.
if ! device_list=$(yq -r \
    '.devices[] | select(.enabled != false) | [.name // "", .url // "", .logfile // ""] | @tsv' \
    "$CONFIG_FILE"); then
    echo "ERROR: could not parse $CONFIG_FILE (see yq error above)" >&2
    exit 1
fi

while IFS=$'\t' read -r name url logfile; do
    [[ -z "$name" && -z "$url" ]] && continue
    if [[ -z "$name" || -z "$url" ]]; then
        echo "ERROR: each device in $CONFIG_FILE needs both 'name' and 'url'" \
             "(got name='$name' url='$url')" >&2
        exit 1
    fi
    logfile="${logfile:-${name}.log}"
    # logrotate.conf only matches *.log, so anything else grows unbounded.
    if [[ "$logfile" != *.log ]]; then
        echo "WARNING: [$name] logfile '$logfile' does not end in .log and will not be rotated" >&2
    fi
    capture_device "$name" "$url" "$logfile" &
    pids+=("$!")
    watched+=("$name|$LOG_DIR/$logfile")
done <<< "$device_list"

if [[ ${#pids[@]} -eq 0 ]]; then
    echo "No enabled devices found in $CONFIG_FILE" >&2
    exit 1
fi

if [[ "$HEARTBEAT_INTERVAL" -gt 0 ]]; then
    heartbeat "$HEARTBEAT_INTERVAL" "${watched[@]}" &
    pids+=("$!")
fi

wait