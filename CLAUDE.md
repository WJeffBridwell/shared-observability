# Project Rules

## Overview

This is the shared observability infrastructure for multiple microservices. It provides centralized logging (Loki), metrics (Prometheus), and visualization (Grafana).

## Technology Stack

- Docker Compose for service orchestration
- Prometheus for metrics collection
- Grafana for visualization
- Loki for log aggregation
- Promtail for log shipping
- Node Exporter for host metrics

## Infrastructure Management

- Use `./scripts/observability.sh` to manage the stack:
  - `./scripts/observability.sh start` - Start all services
  - `./scripts/observability.sh stop` - Stop all services
  - `./scripts/observability.sh restart` - Restart services
  - `./scripts/observability.sh destroy` - Remove everything
  - `./scripts/observability.sh status` - Check status
  - `./scripts/observability.sh health` - Check health endpoints
  - `./scripts/observability.sh logs [-f]` - View logs

## Port Assignments

| Service | Port | Purpose |
|---------|------|---------|
| Prometheus | 9090 | Metrics TSDB |
| Grafana | 3100 | Dashboards |
| Loki | 3102 | Log aggregation |
| Node Exporter | 9100 | Host metrics |

## Configuration Files

- `config/prometheus/prometheus.yml` - Scrape configuration
- `config/prometheus/rules/*.yml` - Alert rules
- `config/loki/loki-config.yaml` - Loki configuration
- `config/promtail/promtail-config.yaml` - Log collection config
- `config/grafana/provisioning/` - Grafana data sources and dashboards

## Development Guidelines

- Check status before making changes: `./scripts/observability.sh status`
- Test configuration changes locally before committing
- Update dashboards in `dashboards/` directory (JSON files)
- Add new alert rules to `config/prometheus/rules/`

## Service Discovery

Services connect by:
1. Joining `observability-network` Docker network
2. Adding labels: `metrics.enabled=true`, `metrics.port=<port>`, `metrics.path=/metrics`
3. Outputting JSON logs with required fields

## Log Format Requirements

Services must output JSON logs with:
- Required: `timestamp`, `level`, `appName`, `message`
- Recommended: `correlationId`, `requestId`, `component`

## Networking

- All services communicate via `observability-network` bridge
- External access via host port mappings
- Services auto-discovered via Docker labels
