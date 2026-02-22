# Alert Configuration

This document describes the pre-configured alerts and how to customize alerting.

## Pre-configured Alerts

### Service Availability

| Alert | Condition | Severity | Description |
|-------|-----------|----------|-------------|
| ServiceDown | `up == 0` for 1m | critical | Service is unreachable |
| ContainerRestarting | >3 restarts/hour | warning | Container is crash-looping |

### HTTP Metrics

| Alert | Condition | Severity | Description |
|-------|-----------|----------|-------------|
| HighErrorRate | >5% 5xx for 2m | warning | High server error rate |
| HighLatency | P95 > 1s for 5m | warning | Slow response times |

### Host Resources

| Alert | Condition | Severity | Description |
|-------|-----------|----------|-------------|
| HighMemoryUsage | >90% for 5m | warning | Host memory exhaustion |
| HighCPUUsage | >90% for 5m | warning | Host CPU saturation |
| DiskSpaceLow | <10% free for 5m | critical | Disk space exhaustion |

### Log Metrics

| Alert | Condition | Severity | Description |
|-------|-----------|----------|-------------|
| HighErrorLogRate | >10 errors/sec for 2m | warning | High error log volume |

## Alert Rules Location

All alert rules are defined in:
```
config/prometheus/rules/common-alerts.yml
```

## Adding Custom Alerts

### Example: Custom Alert Rule

```yaml
groups:
  - name: my-service-alerts
    rules:
      - alert: MyServiceHighLatency
        expr: |
          histogram_quantile(0.95,
            sum(rate(http_request_duration_seconds_bucket{service="my-service"}[5m]))
            by (le)
          ) > 0.5
        for: 5m
        labels:
          severity: warning
          service: my-service
        annotations:
          summary: "High latency for my-service"
          description: "P95 latency is {{ $value | humanizeDuration }}"
```

### Alert Rule Structure

```yaml
- alert: AlertName
  expr: <prometheus_expression>
  for: <duration>
  labels:
    severity: <critical|warning|info>
    <custom_labels>
  annotations:
    summary: "Brief description"
    description: "Detailed description with {{ $value }}"
```

## Viewing Active Alerts

### Prometheus UI

1. Open http://localhost:9090/alerts
2. View firing and pending alerts
3. Click on an alert for details

### Grafana

1. Open http://localhost:3100
2. Navigate to Alerting > Alert rules
3. View all configured rules and their state

## Alert Notification (LIVE)

Alertmanager is deployed and routing to Slack. Config at `config/alertmanager/alertmanager.yml`.

### Current Routing

| Severity | Channel | Repeat |
|----------|---------|--------|
| critical | #all-gathering | 3h |
| warning (external traffic) | #silas | 3h |
| warning (default) | #all-gathering | 3h |

### How It Works

1. Prometheus evaluates rules every 15s
2. Firing alerts are sent to Alertmanager (port 9093)
3. Alertmanager groups by `alertname` + `severity`, waits 10s, then routes to Slack
4. Resolved notifications are sent when the condition clears

The `SLACK_BOT_TOKEN` env var is injected at runtime via `sed` in the entrypoint (token never written to config files on disk).

### Alertmanager Persistence

Silence state and notification history are stored in the `alertmanager-data` named volume at `/alertmanager`. Survives restarts.

## Silencing Alerts

### Via Prometheus

Add a silence in Prometheus UI or via API:

```bash
curl -X POST http://localhost:9090/api/v2/silences \
  -H "Content-Type: application/json" \
  -d '{
    "matchers": [
      {"name": "alertname", "value": "HighMemoryUsage", "isRegex": false}
    ],
    "startsAt": "2026-02-06T22:00:00Z",
    "endsAt": "2026-02-07T22:00:00Z",
    "createdBy": "admin",
    "comment": "Planned maintenance"
  }'
```

## Testing Alerts

### Trigger a Test Alert

Create a test container that will fail health checks:

```bash
docker run -d --name test-fail --network observability-network \
  --label metrics.enabled=true \
  --label metrics.port=8080 \
  alpine sleep 1
```

The `ServiceDown` alert should fire after 1 minute.

### Check Alert Expression

Test your PromQL expression in Prometheus:

1. Go to http://localhost:9090/graph
2. Enter your expression
3. Check if it returns expected results

## Best Practices

1. **Use `for` durations** - Avoid alert flapping with appropriate wait times
2. **Add context to annotations** - Include `{{ $labels }}` and `{{ $value }}`
3. **Use severity labels** - Route alerts appropriately
4. **Test alert expressions** - Verify in Prometheus before deploying
5. **Document custom alerts** - Explain what the alert means and how to respond
6. **Keep alerts actionable** - Only alert on things that require human intervention
