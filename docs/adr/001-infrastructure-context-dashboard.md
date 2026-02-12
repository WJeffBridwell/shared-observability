# ADR-001: Infrastructure Context Diagram Dashboard

**Date:** 2026-02-12
**Status:** Accepted
**Deciders:** Jeff Bridwell

## Context

The shared-observability Grafana dashboard ("App Operations") had a simple stat panel showing UP/DOWN for Prometheus targets. This provided no visual context about how services relate to each other, which services are local vs. external, or what role each plays in the architecture. Operators had to mentally map target names to infrastructure components.

Additionally, WordPress, MySQL, and Fuseki lacked any Prometheus monitoring — their health was invisible to the observability stack.

## Decision

Replace the Service Status stat panel with a **Grafana Canvas panel** that renders an interactive infrastructure context diagram. Add **blackbox-exporter** and **mysqld-exporter** to enable monitoring of services that don't natively expose Prometheus metrics. Connect all monitored services to the `observability-network` so exporters can reach them.

### Canvas Panel Design

The diagram organizes services into visual groups:

- **Application** — Express App (:3000), Fuseki (:3031)
- **Content** — WordPress (:8081), MySQL (:3306)
- **Observability** — Prometheus, Grafana, Loki, Promtail, Node Exporter
- **External Services** — Pivot (OIDC), Google Photos API

Each service box has its background color bound to a Prometheus metric via thresholds (green = UP/1, red = DOWN/0). A **Service dropdown** variable lets operators filter the CPU Usage and Memory Usage panels to any individual service.

### Monitoring Strategy by Service Type

| Service | Metric Source | Query |
|---------|--------------|-------|
| Express App | Docker SD (native `/metrics`) | `up{instance="jeff-bridwell-personal-site-app"}` |
| Prometheus | Self-scrape | `up{instance="localhost:9090"}` |
| Node Exporter | Static scrape | `up{instance="node-exporter:9100"}` |
| Grafana | Static scrape | `up{instance="grafana:3000"}` |
| Loki | Static scrape | `up{instance="loki:3100"}` |
| Promtail | Static scrape | `up{instance="promtail:9080"}` |
| WordPress | Blackbox HTTP probe | `probe_success{instance="http://wordpress-blog:80"}` |
| Fuseki | Blackbox HTTP probe | `probe_success{instance="http://...fuseki:3030/$/ping"}` |
| MySQL | mysqld-exporter | `mysql_up{instance="mysqld-exporter:9104"}` |

### Absent-target handling

When a Docker container stops, its `up{}` metric disappears entirely (Docker SD removes the target). Canvas field bindings fall back to the `fixed` color (green) when the field is absent, which would incorrectly show a stopped service as green. We use `(up{...} or on() vector(0))` to synthesize a 0 value when the target is absent, ensuring the threshold maps to red.

## Alternatives Considered

### 1. Grafana Flowcharting Plugin
A community plugin that renders SVG diagrams with data bindings. Rejected because it requires plugin installation (not bundled with Grafana 10.1) and uses a different rendering model (SVG overlays vs. native canvas).

### 2. Static image with stat overlays
A background image with stat panels positioned over each service. Rejected because it's fragile (pixel-perfect positioning), hard to maintain, and doesn't scale when services are added.

### 3. External dashboard tool (e.g., Mermaid in markdown)
Renders outside Grafana, losing the real-time data binding that makes the diagram useful for at-a-glance health monitoring.

## Consequences

### Positive
- At-a-glance infrastructure health — green/red boxes show service state immediately
- Service dropdown enables per-service drill-down for CPU and memory without separate dashboards
- WordPress, MySQL, and Fuseki are now monitored (previously invisible)
- Terraform configs updated for persistence — network connections survive `terraform apply`

### Negative
- Canvas panel JSON is verbose and not easily hand-editable; future layout changes require careful JSON editing or Grafana UI editing
- Blackbox and mysqld exporters add two more containers to the observability stack
- Cross-project network dependencies: WordPress, MySQL, and Fuseki containers must join `observability-network` (Terraform configs in 3 separate repos)

### Cross-Repository Changes
This decision required coordinated changes across three repositories:
- **shared-observability** — dashboard, exporters, Prometheus scrape configs
- **wordpress-blog** — Terraform: WordPress + MySQL join observability-network
- **jeff-bridwell-personal-site** — Terraform: Fuseki joins observability-network

## Technical Notes

- Grafana Canvas panel (`type: "canvas"`) uses `options.root.elements[]` with `placement` (absolute px positioning) and `background.color.field` for data binding
- Canvas connections require `source: {x, y}` and `target: {x, y}` coordinate objects (0-1 relative) — omitted per user preference (arrows add clutter without value)
- `probe_success` (blackbox) and `mysql_up` (mysqld-exporter) return 1/0, matching the same threshold scheme as `up{}`
- mysqld-exporter v0.15.0 requires `--mysqld.address` + `MYSQLD_EXPORTER_PASSWORD` env var (not the legacy `DATA_SOURCE_NAME`)
