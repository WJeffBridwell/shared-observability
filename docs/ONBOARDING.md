# Service Onboarding Guide

This guide explains how to connect your service to the shared observability stack.

## Prerequisites

1. The shared observability stack is running:
   ```bash
   cd shared-observability
   ./scripts/observability.sh start
   ```

2. Your service is containerized with Docker

## Step 1: Join the Observability Network

Add the `observability-network` to your Docker Compose file:

```yaml
services:
  my-app:
    image: my-app:latest
    networks:
      - my-app-network          # Your own network
      - observability-network   # Shared observability

networks:
  my-app-network:
    driver: bridge
  observability-network:
    external: true
    name: observability-network
```

## Step 2: Add Discovery Labels

Add labels to enable auto-discovery:

```yaml
services:
  my-app:
    labels:
      # For Prometheus metrics scraping
      - "metrics.enabled=true"
      - "metrics.port=3000"
      - "metrics.path=/metrics"

      # For log identification
      - "appName=my-app"
```

### Label Reference

| Label | Required | Description |
|-------|----------|-------------|
| `metrics.enabled` | Yes | Set to `true` to enable Prometheus scraping |
| `metrics.port` | Yes | Port your app exposes metrics on |
| `metrics.path` | No | Path to metrics endpoint (default: `/metrics`) |
| `appName` | Recommended | Application name for log filtering |

## Step 3: Expose a Metrics Endpoint

Your application needs to expose Prometheus metrics. Here's an example for Node.js:

```typescript
import express from 'express';
import { collectDefaultMetrics, register } from 'prom-client';

const app = express();

// Collect default Node.js metrics
collectDefaultMetrics();

// Expose metrics endpoint
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.send(await register.metrics());
});
```

### Common Metrics to Track

```typescript
import { Counter, Histogram } from 'prom-client';

// Request counter
const httpRequestsTotal = new Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'path', 'status']
});

// Request duration histogram
const httpRequestDuration = new Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'path'],
  buckets: [0.01, 0.05, 0.1, 0.5, 1, 2, 5]
});
```

## Step 4: Output JSON Logs

Configure your logger to output JSON with the required fields:

```typescript
import { createLogger, format, transports } from 'winston';

const logger = createLogger({
  format: format.combine(
    format.timestamp(),
    format.json()
  ),
  defaultMeta: {
    appName: 'my-app'
  },
  transports: [
    new transports.Console()
  ]
});

// Usage
logger.info('Request completed', {
  component: 'AuthMiddleware',
  correlationId: 'abc-123',
  method: 'POST',
  path: '/login',
  durationMs: 150
});
```

### Required Log Fields

| Field | Type | Description |
|-------|------|-------------|
| `timestamp` | string | ISO 8601 timestamp |
| `level` | string | Log level (error, warn, info, debug) |
| `appName` | string | Application name |
| `message` | string | Log message |

### Recommended Log Fields

| Field | Type | Description |
|-------|------|-------------|
| `correlationId` | string | Request correlation ID for tracing |
| `requestId` | string | Unique request identifier |
| `component` | string | Application component name |
| `method` | string | HTTP method |
| `path` | string | Request path |
| `durationMs` | number | Request duration in milliseconds |
| `statusCode` | number | HTTP response status code |

## Step 5: Verify Integration

### Check Logs

1. Open Grafana: http://localhost:3100
2. Go to Explore > Loki
3. Query: `{appName="my-app"}`

### Check Metrics

1. Open Prometheus: http://localhost:9090/targets
2. Verify your service appears in the `docker-services` job
3. Query: `up{instance="my-app:3000"}`

### Use Dashboards

1. Open Grafana: http://localhost:3100
2. Navigate to "Shared Observability" folder
3. Open "Service Overview" dashboard

## Terraform Example

If using Terraform for Docker resources:

```hcl
resource "docker_container" "my_app" {
  name  = "my-app"
  image = docker_image.my_app.image_id

  networks_advanced {
    name = "my-app-network"
  }

  networks_advanced {
    name = "observability-network"
  }

  labels {
    label = "metrics.enabled"
    value = "true"
  }

  labels {
    label = "metrics.port"
    value = "3000"
  }

  labels {
    label = "metrics.path"
    value = "/metrics"
  }

  labels {
    label = "appName"
    value = "my-app"
  }
}

data "docker_network" "observability" {
  name = "observability-network"
}
```

## Troubleshooting

### Service not appearing in Prometheus

1. Verify the service is on `observability-network`:
   ```bash
   docker network inspect observability-network
   ```

2. Check labels are correct:
   ```bash
   docker inspect my-app --format '{{json .Config.Labels}}'
   ```

3. Verify metrics endpoint is accessible:
   ```bash
   docker exec prometheus wget -qO- http://my-app:3000/metrics
   ```

### Logs not appearing in Loki

1. Check Promtail is running:
   ```bash
   docker logs promtail
   ```

2. Verify container is on the network:
   ```bash
   docker network inspect observability-network | grep my-app
   ```

3. Check log format is JSON:
   ```bash
   docker logs my-app | head -1 | jq
   ```

### Dashboard shows no data

1. Verify time range in Grafana
2. Check Prometheus has data: query `up{job="docker-services"}`
3. Check Loki has data: query `{appName="my-app"}`
