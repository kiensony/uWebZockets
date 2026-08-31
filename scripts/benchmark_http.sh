#!/usr/bin/env sh
set -eu

if [ "$#" -ne 3 ]; then
    printf '%s\n' "usage: benchmark_http.sh <label> <server-binary> <output-directory>" >&2
    exit 2
fi

label=$1
server_binary=$2
output_directory=$3

case "$label" in
    '' | *[!a-z0-9_-]*)
        printf '%s\n' "benchmark label must contain only lowercase letters, digits, dashes, or underscores" >&2
        exit 2
        ;;
esac

if [ ! -x "$server_binary" ]; then
    printf 'benchmark server is not executable: %s\n' "$server_binary" >&2
    exit 2
fi

mkdir -p "$output_directory"
server_log="$output_directory/$label-server.log"
rates_file="$output_directory/$label-rates.txt"
: >"$rates_file"

server_pid=
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

"$server_binary" >"$server_log" 2>&1 &
server_pid=$!

ready=false
attempt=0
while [ "$attempt" -lt 100 ]; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
        cat "$server_log" >&2
        exit 1
    fi
    if python3 -c '
import http.client
connection = http.client.HTTPConnection("127.0.0.1", 3000, timeout=0.5)
connection.request("GET", "/", headers={"Connection": "close"})
response = connection.getresponse()
response.read()
connection.close()
if response.status != 200:
    raise SystemExit(1)
' 2>/dev/null; then
        ready=true
        break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done

if [ "$ready" != true ]; then
    printf '%s\n' "benchmark server did not become ready" >&2
    exit 1
fi

run=1
while [ "$run" -le 3 ]; do
    result_file="$output_directory/$label-$run.txt"
    wrk -t2 -c64 -d10s --latency http://127.0.0.1:3000/ >"$result_file"
    cat "$result_file" >&2
    rate=$(awk '/Requests\/sec:/ { print $2 }' "$result_file")
    if [ -z "$rate" ]; then
        printf '%s\n' "wrk did not report requests per second" >&2
        exit 1
    fi
    printf '%s\n' "$rate" >>"$rates_file"
    run=$((run + 1))
done

kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=

sort -n "$rates_file" | sed -n '2p'
