# Shared Observability Stack

A standalone, shared observability infrastructure that multiple microservices can connect to via a shared Docker network. Services are auto-discovered for log aggregation and metrics collection.

## Components

| Service | Image | Port | Mem Limit | Purpose |
|---------|-------|------|-----------|---------|
| Prometheus | prom/prometheus:v2.45.0 | 9090 | 512 MB | Metrics TSDB (15d retention) |
| Grafana | grafana/grafana:10.1.0 | 3100 | 384 MB | Dashboards |
| Loki | grafana/loki:2.9.2 | 3102 | 512 MB | Log aggregation (7d retention) |
| Promtail | grafana/promtail:2.9.2 | 9080 | 256 MB | Log shipper (auto-discovery) |
| Alertmanager | prom/alertmanager:v0.26.0 | 9093 | 128 MB | Alert routing → Slack |
| Blackbox Exporter | prom/blackbox-exporter:v0.24.0 | — | 64 MB | HTTP/ICMP probes |
| Node Exporter | prom/node-exporter:v1.6.0 | 9100 | 64 MB | Host metrics |
| MySQL Exporter | prom/mysqld-exporter:v0.15.0 | — | 64 MB | WordPress DB metrics |

**Total memory cap: ~2 GB** on a 16 GB host. All ports bound to `127.0.0.1` (ADR-012).

## Quick Start

```bash
# Start the observability stack
./scripts/observability.sh start

# Check status
./scripts/observability.sh status

# View logs
./scripts/observability.sh logs -f

# Stop the stack
./scripts/observability.sh stop
```

## Access Points

- **Grafana**: http://localhost:3100 (admin/admin)
- **Prometheus**: http://localhost:9090
- **Loki**: http://localhost:3102

## Connecting Services

Services connect by joining the `observability-network` Docker network and adding discovery labels.

### Docker Compose Example

```yaml
services:
  my-app:
    image: my-app:latest
    networks:
      - my-app-network
      - observability-network
    labels:
      - "metrics.enabled=true"
      - "metrics.port=3000"
      - "metrics.path=/metrics"
      - "appName=my-app"

networks:
  my-app-network:
    driver: bridge
  observability-network:
    external: true
    name: observability-network
```

### Required Labels

| Label | Description | Example |
|-------|-------------|---------|
| `metrics.enabled` | Enable Prometheus scraping | `true` |
| `metrics.port` | Port exposing metrics | `3000` |
| `metrics.path` | Metrics endpoint path | `/metrics` |
| `appName` | Application name for logs | `my-app` |

## Pre-built Dashboards

1. **Service Overview** - Request rate, error rate, P95 latency by service
2. **Logs Explorer** - Search logs by service, level, correlationId
3. **Node Metrics** - CPU, memory, disk, network
4. **Docker Containers** - Container CPU, memory, restarts

## Log Format

All services should output JSON logs with the following schema:

```json
{
  "timestamp": "2026-02-06T22:00:00.000Z",
  "level": "info",
  "appName": "my-app",
  "message": "Request completed",
  "correlationId": "abc-123-def"
}
```

See [docs/LOG_FORMAT.md](docs/LOG_FORMAT.md) for the complete specification.

## Alert Rules

Three rule files in `config/prometheus/rules/`:

**common-alerts.yml** — Core infrastructure:
- **ServiceDown** - Service unreachable for 1m (critical)
- **HighErrorRate** - >5% 5xx responses for 2m (warning)
- **HighLatency** - P95 > 1s for 5m (warning)
- **HighMemory** - Host >90% for 5m (warning)
- **HighCPU** - Host >90% for 5m (warning)
- **DiskSpaceLow** - <10% free (critical)
- **ContainerRestarting** - >3 restarts/hour (warning)

**external-traffic-alerts.yml** — Cloudflare tunnel + external traffic:
- **CloudflareTunnelDown** - Tunnel unreachable (critical → #all-gathering)
- **ExternalTrafficSpike** - Unusual traffic volume (warning → #silas)
- **HighExternalErrorRate** - High error rate on external requests (warning → #silas)
- **CloudflaredMetricsMissing** - Scrape target down (warning → #silas)

**home-network-alerts.yml** — LAN device probes

Alerts route to Slack via Alertmanager (live, not future). See [docs/ALERTING.md](docs/ALERTING.md).

## Directory Structure

```
shared-observability/
├── README.md
├── CLAUDE.md
├── docker-compose.yml
├── scripts/
│   └── observability.sh
├── config/
│   ├── prometheus/
│   │   ├── prometheus.yml
│   │   └── rules/
│   │       ├── common-alerts.yml
│   │       ├── external-traffic-alerts.yml
│   │       └── home-network-alerts.yml
│   ├── alertmanager/
│   │   └── alertmanager.yml
│   ├── blackbox/
│   │   └── blackbox.yml
│   ├── loki/
│   │   └── loki-config.yaml
│   ├── promtail/
│   │   └── promtail-config.yaml
│   └── grafana/
│       └── provisioning/
│           ├── datasources/
│           └── dashboards/
├── dashboards/
│   ├── service-overview.json
│   ├── logs-explorer.json
│   ├── node-metrics.json
│   └── docker-containers.json
├── data/                         # Persistent (gitignored)
└── docs/
    ├── ONBOARDING.md
    ├── LOG_FORMAT.md
    ├── ALERTING.md
    └── FAILURE-PLAYBOOK.md
```

## Management Commands

```bash
./scripts/observability.sh start     # Start all services
./scripts/observability.sh stop      # Stop all services
./scripts/observability.sh restart   # Restart all services
./scripts/observability.sh destroy   # Remove everything including data
./scripts/observability.sh status    # Show service status
./scripts/observability.sh health    # Check health endpoints
./scripts/observability.sh targets   # Show Prometheus scrape targets
./scripts/observability.sh logs [-f] # View logs
```

## Documentation

- [ONBOARDING.md](docs/ONBOARDING.md) - How to connect your service
- [LOG_FORMAT.md](docs/LOG_FORMAT.md) - Standard log schema
- [ALERTING.md](docs/ALERTING.md) - Alert configuration
- [FAILURE-PLAYBOOK.md](docs/FAILURE-PLAYBOOK.md) - Failure modes and recovery procedures
