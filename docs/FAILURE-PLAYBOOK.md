# Failure Playbook — Shared Observability Stack

Single source of truth for diagnosing and recovering from observability stack failures.

## Architecture Summary

8 containers on `observability-network`, all `restart: unless-stopped`, all ports on `127.0.0.1` (ADR-012). Total memory cap: ~2 GB on 16 GB host. Named volumes for all stateful services.

```
Prometheus (512 MB) ─┬─→ Alertmanager (128 MB) ─→ Slack
                     │
Promtail (256 MB) ───→ Loki (512 MB) ───→ Grafana (384 MB)
                     │
Blackbox (64 MB) ────┘
Node Exporter (64 MB)
MySQL Exporter (64 MB)
```

## Named Volumes (Data Persistence)

| Volume | Service | What's stored | Loss impact |
|--------|---------|---------------|-------------|
| `prometheus-data` | Prometheus | 15d of metrics | Lose historical metrics, re-scrapes from now |
| `loki-data` | Loki | 7d of logs | Lose historical logs |
| `grafana-data` | Grafana | Dashboard state, user prefs | Dashboards re-provisioned from JSON, minor loss |
| `alertmanager-data` | Alertmanager | Silences, notification history | Active silences lost, alerts re-fire |
| `promtail-positions` | Promtail | File read positions | Duplicate log entries on restart (one-time) |

## Failure Scenarios

### 1. Single Container Down

**Detection**: `ServiceDown` alert fires after 1m. Grafana Docker dashboard shows restart.

**Recovery**: `restart: unless-stopped` handles it automatically. If stuck:

```bash
cd /Users/jeffbridwell/CascadeProjects/shared-observability
./scripts/observability.sh restart
```

**Impact by service**:

| Service | Impact while down | Data loss |
|---------|-------------------|-----------|
| Prometheus | Metrics gap, alerts stop evaluating | Gap in time series (acceptable for 15d window) |
| Loki | Log ingestion stops, Promtail buffers | None — Promtail resumes from position file |
| Grafana | Dashboards unavailable | None (visualization only) |
| Promtail | Logs stop flowing to Loki | None — position file tracks where it left off |
| Alertmanager | Alerts fire but don't route to Slack | Prometheus buffers alerts briefly |
| Blackbox | Probe-based alerts stop (external, LAN) | No cascading impact |
| Node Exporter | Host metrics gap | No cascading impact |
| MySQL Exporter | WordPress DB metrics gap | No cascading impact |

### 2. Full Stack Down

**Cause**: Host reboot, Docker daemon restart, `observability.sh stop`.

**Recovery**:

```bash
cd /Users/jeffbridwell/CascadeProjects/shared-observability
./scripts/observability.sh start
./scripts/observability.sh health
```

All data persists in named volumes. Promtail resumes from its position file — no duplicate logs. Metrics and logs have a gap equal to downtime. Alerts re-evaluate immediately.

### 3. Host OOM

**Detection**: System becomes unresponsive, or `dmesg` shows OOM kills.

**Why resource limits matter**: Without limits, a single Loki ingestion burst or Prometheus query can consume all host memory. With limits, Docker kills the offending container first, and `restart: unless-stopped` brings it back.

**Triage priority** (highest memory first):
1. Prometheus (512 MB cap) — check for expensive queries
2. Loki (512 MB cap) — check for ingestion burst
3. Grafana (384 MB cap) — check for many concurrent dashboards

**Recovery**: Containers auto-restart within limits. If host is truly OOMing:
```bash
# Check what's consuming memory (non-Docker)
top -o MEM
# Restart just the observability stack
cd /Users/jeffbridwell/CascadeProjects/shared-observability
./scripts/observability.sh restart
```

### 4. Prometheus Data Volume Growing

**Current**: 1.9 GB with 15d retention, ~38 scrape targets.

**Detection**: `DiskSpaceLow` alert, or check:
```bash
docker volume inspect shared-observability_prometheus-data
```

**Recovery**: Prometheus self-compacts. If retention needs reducing:
- Edit `docker-compose.yml` → `--storage.tsdb.retention.time=7d`
- Restart Prometheus

### 5. Loki Ingestion Overload

**Detection**: Log queries slow down, Loki container at memory limit.

**Current config**: `ingestion_rate_mb: 16`, `retention_period: 168h` (7d), compactor runs every 10m.

**Recovery**:
1. Check which container is flooding logs: Grafana → Explore → Loki → `sum(rate({job="docker"}[5m])) by (container_name)`
2. Fix the noisy container (usually an app bug or tight polling loop)
3. If persistent, adjust Promtail pipeline filters in `config/promtail/promtail-config.yaml`

### 6. Alertmanager Not Routing to Slack

**Detection**: Alerts visible in Prometheus (http://localhost:9090/alerts) but not appearing in Slack.

**Triage**:
1. Check Alertmanager is running: http://localhost:9093/#/status
2. Check Slack token: Alertmanager injects `SLACK_BOT_TOKEN` at startup via `sed`. If the env var is missing, the config has a literal placeholder string.
3. Check Alertmanager logs (via Grafana → Loki → `{container_name="alertmanager"}`)

**Recovery**: Restart Alertmanager to re-inject the token:
```bash
cd /Users/jeffbridwell/CascadeProjects/shared-observability
docker compose restart alertmanager
```

### 7. Promtail Duplicate Logs After Restart

**Prevention**: The `promtail-positions` named volume persists file read positions across restarts. This was added in WF-007 step 2.

**If it happens anyway** (volume corruption, manual removal):
- One-time duplicate burst as Promtail re-reads from log file heads
- Self-resolves after catching up to current position
- No action needed — Loki deduplication handles most cases

### 8. Grafana Dashboard Missing or Broken

**Detection**: Dashboard not loading or showing "No data".

**Triage**:
1. Dashboards are provisioned from `dashboards/*.json` — restart restores them
2. "No data" usually means the datasource (Prometheus or Loki) is down
3. Check datasource health: Grafana → Connections → Data Sources → Test

**Recovery**: `./scripts/observability.sh restart` restores provisioned dashboards.

## Dashboards Quick Reference

| Dashboard | URL | What to look for |
|-----------|-----|-------------------|
| Home Cloud | http://localhost:3100/d/home-cloud | CPU, memory, disk, service health |
| Home Network | http://localhost:3100/d/home-network | LAN device reachability |
| App Operations | http://localhost:3100/d/app-operations | Request rates, errors, latency |
| Chorus Activity | http://localhost:3100/d/chorus-activity | Team coordination events |
| Docker Containers | http://localhost:3100/d/docker-containers | Container CPU, memory, restarts |
| Logs Explorer | http://localhost:3100/d/logs-explorer | Search logs by service/level |

## Key Ports

| Port | Service | Accessible from |
|------|---------|-----------------|
| 3100 | Grafana | localhost only |
| 3102 | Loki API | localhost only |
| 9090 | Prometheus | localhost only |
| 9093 | Alertmanager | localhost only |
| 9080 | Promtail | localhost only |
| 9100 | Node Exporter | localhost only |

## WF-007 Hardening Summary

Changes applied during Loki consolidation (2026-02-22):

1. **Step 1 (Kade)**: Destroyed 5 ghost containers from stale app-side Terraform prometheus/ workspace. Removed 58 MB of stale config. Verified shared Promtail covers all app containers (5/6 non-infra, webvowl silent by design).
2. **Step 2 (Silas)**: Resource limits on all 8 containers (total ~2 GB cap). Alertmanager persistence volume + pinned to v0.26.0. Promtail position tracking volume.
3. **Step 3 (Kade)**: This document. Updated README (components, resource limits, directory structure). Updated ALERTING.md (alertmanager is live, not future).
