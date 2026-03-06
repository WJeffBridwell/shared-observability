#!/bin/bash
# Emit Prometheus metrics for LaunchAgent process state
# Writes to node_exporter textfile collector directory
# Run every 15s via LaunchAgent

set -euo pipefail

TEXTFILE_DIR="/tmp/node-exporter-textfile"
OUTFILE="${TEXTFILE_DIR}/launchagent.prom"
TMPFILE="${OUTFILE}.tmp"

mkdir -p "$TEXTFILE_DIR"

# KeepAlive agents (pipe-separated for grep)
KEEPALIVE="com.chorus.api|com.chorus.alert-notifier|com.chorus.session-watcher|com.chorus.defect-poller|com.chorus.fuseki-perf|com.chorus.ops-agent|com.chorus.andon-light|com.chorus.andon-enrich|com.chorus.jeff-input-monitor|com.gathering.node-exporter|com.gathering.codebase-graph-watcher|com.gathering.images-api-server|com.gathering.images-api-video|com.gathering.ollama"

# Calendar agents
CALENDAR="com.chorus.fuseki-compact"

get_kind() {
  local label="$1"
  if echo "$label" | grep -qE "^(${KEEPALIVE})$"; then
    echo "keepalive"
  elif echo "$label" | grep -qE "^(${CALENDAR})$"; then
    echo "calendar"
  else
    echo "run-once"
  fi
}

cat > "$TMPFILE" <<'HEADER'
# HELP launchagent_up Whether a LaunchAgent process is running (1=up, 0=down)
# TYPE launchagent_up gauge
HEADER

launchctl list 2>/dev/null | grep -E '^[0-9-]+\s+[0-9-]+\s+com\.(chorus|gathering)\.' | while read -r pid status label; do
  if [ "$pid" = "-" ]; then
    up=0
  else
    up=1
  fi

  short="${label#com.chorus.}"
  short="${short#com.gathering.}"
  kind=$(get_kind "$label")

  echo "launchagent_up{label=\"${label}\",name=\"${short}\",kind=\"${kind}\"} ${up}"
done >> "$TMPFILE"

mv "$TMPFILE" "$OUTFILE"
