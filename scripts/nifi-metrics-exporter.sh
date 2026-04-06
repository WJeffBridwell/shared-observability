#!/bin/bash
# NiFi Prometheus Metrics Exporter
# Polls NiFi API and serves metrics on port 9091 for Prometheus scraping
# LaunchAgent: com.gathering.nifi-metrics on Bedroom

set -euo pipefail

NIFI_URL="https://192.168.86.242:8443"
NIFI_USER="admin"
NIFI_PASS="nifi-gathering-2026"
METRICS_PORT=9091
METRICS_FILE="/tmp/nifi-metrics.prom"
POLL_INTERVAL=15

get_token() {
  curl -sk -X POST "${NIFI_URL}/nifi-api/access/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "username=${NIFI_USER}&password=${NIFI_PASS}" 2>/dev/null
}

collect_metrics() {
  local token="$1"
  local auth="Authorization: Bearer ${token}"

  # System diagnostics
  local sys
  sys=$(curl -sk -H "$auth" "${NIFI_URL}/nifi-api/system-diagnostics" 2>/dev/null)

  local heap_used heap_max heap_pct threads processors load
  heap_used=$(echo "$sys" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['systemDiagnostics']['aggregateSnapshot']['usedHeapBytes'])" 2>/dev/null || echo 0)
  heap_max=$(echo "$sys" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['systemDiagnostics']['aggregateSnapshot']['maxHeapBytes'])" 2>/dev/null || echo 0)
  heap_pct=$(echo "$sys" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['systemDiagnostics']['aggregateSnapshot']['heapUtilization'].replace('%',''))" 2>/dev/null || echo 0)
  threads=$(echo "$sys" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['systemDiagnostics']['aggregateSnapshot']['totalThreads'])" 2>/dev/null || echo 0)
  processors=$(echo "$sys" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['systemDiagnostics']['aggregateSnapshot']['availableProcessors'])" 2>/dev/null || echo 0)
  load=$(echo "$sys" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['systemDiagnostics']['aggregateSnapshot']['processorLoadAverage'])" 2>/dev/null || echo 0)

  # Flow status (root process group)
  local flow
  flow=$(curl -sk -H "$auth" "${NIFI_URL}/nifi-api/flow/status" 2>/dev/null)

  local active_threads queued_count queued_bytes bytes_in bytes_out flowfiles_in flowfiles_out
  active_threads=$(echo "$flow" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['controllerStatus']['activeThreadCount'])" 2>/dev/null || echo 0)
  queued_count=$(echo "$flow" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['controllerStatus']['flowFilesQueued'])" 2>/dev/null || echo 0)
  queued_bytes=$(echo "$flow" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['controllerStatus']['bytesQueued'])" 2>/dev/null || echo 0)
  bytes_in=$(echo "$flow" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['controllerStatus']['bytesIn'])" 2>/dev/null || echo 0)
  bytes_out=$(echo "$flow" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['controllerStatus']['bytesOut'])" 2>/dev/null || echo 0)
  flowfiles_in=$(echo "$flow" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['controllerStatus']['flowFilesIn'])" 2>/dev/null || echo 0)
  flowfiles_out=$(echo "$flow" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['controllerStatus']['flowFilesOut'])" 2>/dev/null || echo 0)

  # Running/stopped/invalid processor counts
  local running stopped invalid
  running=$(echo "$flow" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['controllerStatus']['runningCount'])" 2>/dev/null || echo 0)
  stopped=$(echo "$flow" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['controllerStatus']['stoppedCount'])" 2>/dev/null || echo 0)
  invalid=$(echo "$flow" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['controllerStatus']['invalidCount'])" 2>/dev/null || echo 0)

  cat > "${METRICS_FILE}.tmp" << METRICS
# HELP nifi_jvm_heap_used_bytes JVM heap memory used
# TYPE nifi_jvm_heap_used_bytes gauge
nifi_jvm_heap_used_bytes ${heap_used}
# HELP nifi_jvm_heap_max_bytes JVM heap memory max
# TYPE nifi_jvm_heap_max_bytes gauge
nifi_jvm_heap_max_bytes ${heap_max}
# HELP nifi_jvm_heap_utilization_percent JVM heap utilization percentage
# TYPE nifi_jvm_heap_utilization_percent gauge
nifi_jvm_heap_utilization_percent ${heap_pct}
# HELP nifi_jvm_threads_total Total JVM threads
# TYPE nifi_jvm_threads_total gauge
nifi_jvm_threads_total ${threads}
# HELP nifi_system_processors Available CPU cores
# TYPE nifi_system_processors gauge
nifi_system_processors ${processors}
# HELP nifi_system_load_average System load average
# TYPE nifi_system_load_average gauge
nifi_system_load_average ${load}
# HELP nifi_flow_active_threads Active processing threads
# TYPE nifi_flow_active_threads gauge
nifi_flow_active_threads ${active_threads}
# HELP nifi_flow_flowfiles_queued FlowFiles currently queued
# TYPE nifi_flow_flowfiles_queued gauge
nifi_flow_flowfiles_queued ${queued_count}
# HELP nifi_flow_bytes_queued Bytes currently queued
# TYPE nifi_flow_bytes_queued gauge
nifi_flow_bytes_queued ${queued_bytes}
# HELP nifi_flow_bytes_in Bytes received (5 min)
# TYPE nifi_flow_bytes_in gauge
nifi_flow_bytes_in ${bytes_in}
# HELP nifi_flow_bytes_out Bytes sent (5 min)
# TYPE nifi_flow_bytes_out gauge
nifi_flow_bytes_out ${bytes_out}
# HELP nifi_flow_flowfiles_in FlowFiles received (5 min)
# TYPE nifi_flow_flowfiles_in gauge
nifi_flow_flowfiles_in ${flowfiles_in}
# HELP nifi_flow_flowfiles_out FlowFiles sent (5 min)
# TYPE nifi_flow_flowfiles_out gauge
nifi_flow_flowfiles_out ${flowfiles_out}
# HELP nifi_processors_running Running processor count
# TYPE nifi_processors_running gauge
nifi_processors_running ${running}
# HELP nifi_processors_stopped Stopped processor count
# TYPE nifi_processors_stopped gauge
nifi_processors_stopped ${stopped}
# HELP nifi_processors_invalid Invalid processor count
# TYPE nifi_processors_invalid gauge
nifi_processors_invalid ${invalid}
# HELP nifi_up NiFi is reachable (1=up, 0=down)
# TYPE nifi_up gauge
nifi_up 1
METRICS

  mv "${METRICS_FILE}.tmp" "${METRICS_FILE}"
}

serve_metrics() {
  while true; do
    { echo -ne "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\n\r\n"; cat "${METRICS_FILE}" 2>/dev/null || echo "nifi_up 0"; } | nc -l "${METRICS_PORT}" > /dev/null 2>&1 || true
  done
}

# Initialize metrics file
echo "nifi_up 0" > "${METRICS_FILE}"

# Start HTTP server in background
serve_metrics &
SERVER_PID=$!
trap "kill $SERVER_PID 2>/dev/null" EXIT

echo "NiFi metrics exporter started on port ${METRICS_PORT}" >&2

# Main collection loop
TOKEN=""
TOKEN_TIME=0
while true; do
  NOW=$(date +%s)
  # Refresh token every 7 hours (token lasts 8)
  if [ $((NOW - TOKEN_TIME)) -gt 25200 ] || [ -z "$TOKEN" ]; then
    TOKEN=$(get_token)
    TOKEN_TIME=$NOW
    echo "Token refreshed" >&2
  fi

  if collect_metrics "$TOKEN" 2>/dev/null; then
    : # success
  else
    echo "nifi_up 0" > "${METRICS_FILE}"
    echo "Collection failed, will retry" >&2
  fi

  sleep "${POLL_INTERVAL}"
done
