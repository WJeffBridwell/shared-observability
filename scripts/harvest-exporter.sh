#!/usr/bin/env bash
# harvest-exporter.sh — Prometheus textfile exporter for harvest pipeline state
# Reads manifest JSON files, emits harvest.prom for node_exporter textfile collector
# Card: #653
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST_DIR="${MANIFEST_DIR:-$(cd "$SCRIPT_DIR/../../jeff-bridwell-personal-site/data/harvest/manifests" && pwd)}"
OUTPUT="${OUTPUT:-$SCRIPT_DIR/../data/textfile_collector/harvest.prom}"
TMP="${OUTPUT}.tmp"

: > "$TMP"

cat >> "$TMP" << 'HEADER'
# HELP harvest_stage_status Pipeline stage status (0=not_started, 1=in_progress, 2=complete, 3=partial, 4=blocked, 5=manual)
# TYPE harvest_stage_status gauge
# HELP harvest_stage_last_run_epoch Unix timestamp of last stage run
# TYPE harvest_stage_last_run_epoch gauge
# HELP harvest_stage_record_count Records processed in stage
# TYPE harvest_stage_record_count gauge
# HELP harvest_domain_gap_count Number of open gaps for domain
# TYPE harvest_domain_gap_count gauge
# HELP harvest_domain_updated_epoch Unix timestamp of last manifest update
# TYPE harvest_domain_updated_epoch gauge
# HELP harvest_domain_task_total Total tasks for domain
# TYPE harvest_domain_task_total gauge
# HELP harvest_domain_task_complete Completed tasks for domain
# TYPE harvest_domain_task_complete gauge
# HELP harvest_exporter_last_run_epoch Unix timestamp of last exporter run
# TYPE harvest_exporter_last_run_epoch gauge
HEADER

for manifest in "$MANIFEST_DIR"/*.json; do
  [ -f "$manifest" ] || continue

  python3 - "$manifest" >> "$TMP" << 'PYEOF'
import json, sys
from datetime import datetime

STATUS_MAP = {
    'not_started': 0, 'in_progress': 1, 'complete': 2,
    'partial': 3, 'blocked': 4, 'manual': 5
}

def iso_to_epoch(iso_str):
    if not iso_str:
        return 0
    try:
        # Handle both Z and +00:00 suffixes
        iso_str = iso_str.replace('Z', '+00:00')
        dt = datetime.fromisoformat(iso_str)
        return int(dt.timestamp())
    except (ValueError, TypeError):
        return 0

m = json.load(open(sys.argv[1]))
domain = m.get('domain', 'unknown')
stages = m.get('stages', {})
gaps = m.get('gaps', [])
tasks = m.get('tasks', [])
updated = m.get('updated', '')

# Stage metrics
for stage_name, stage_info in stages.items():
    if not isinstance(stage_info, dict):
        continue
    status = stage_info.get('status', 'not_started')
    status_val = STATUS_MAP.get(status, 0)
    last_run = iso_to_epoch(stage_info.get('last_run', ''))
    # Try multiple count fields
    count = (stage_info.get('output_count')
             or stage_info.get('fuseki_count')
             or stage_info.get('count')
             or 0)

    print(f'harvest_stage_status{{domain="{domain}",stage="{stage_name}"}} {status_val}')
    if last_run > 0:
        print(f'harvest_stage_last_run_epoch{{domain="{domain}",stage="{stage_name}"}} {last_run}')
    if count:
        print(f'harvest_stage_record_count{{domain="{domain}",stage="{stage_name}"}} {count}')

# Domain-level metrics
print(f'harvest_domain_gap_count{{domain="{domain}"}} {len(gaps)}')
if updated:
    print(f'harvest_domain_updated_epoch{{domain="{domain}"}} {iso_to_epoch(updated)}')

tasks_total = len(tasks)
tasks_complete = sum(1 for t in tasks if t.get('status') == 'complete')
print(f'harvest_domain_task_total{{domain="{domain}"}} {tasks_total}')
print(f'harvest_domain_task_complete{{domain="{domain}"}} {tasks_complete}')
PYEOF

done

# Exporter timestamp
echo "harvest_exporter_last_run_epoch $(date +%s)" >> "$TMP"

# Atomic move
mv "$TMP" "$OUTPUT"
