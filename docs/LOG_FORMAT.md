# Standard Log Format

All services connected to the shared observability stack must output logs in JSON format with a consistent schema.

## Log Schema

```json
{
  "timestamp": "2026-02-06T22:00:00.000Z",
  "level": "info",
  "appName": "my-app",
  "component": "AuthMiddleware",
  "message": "User authenticated successfully",
  "correlationId": "abc-123-def",
  "requestId": "req-456-xyz",
  "method": "POST",
  "path": "/api/login",
  "durationMs": 150,
  "statusCode": 200,
  "userId": "user-789"
}
```

## Field Reference

### Required Fields

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `timestamp` | string | ISO 8601 timestamp | `2026-02-06T22:00:00.000Z` |
| `level` | string | Log level | `error`, `warn`, `info`, `debug` |
| `appName` | string | Application identifier | `jeff-bridwell-personal-site` |
| `message` | string | Human-readable message | `User login successful` |

### Recommended Fields

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `correlationId` | string | Cross-service trace ID | `abc-123-def` |
| `requestId` | string | Unique request ID | `req-456-xyz` |
| `component` | string | Application component | `AuthMiddleware` |

### Context Fields (When Applicable)

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `method` | string | HTTP method | `GET`, `POST` |
| `path` | string | Request path | `/api/users` |
| `statusCode` | number | HTTP status code | `200`, `404` |
| `durationMs` | number | Request duration in ms | `150` |
| `userId` | string | Authenticated user ID | `user-123` |
| `error` | string | Error message | `Connection refused` |
| `stack` | string | Error stack trace | `Error: ...\n  at ...` |

## Log Levels

| Level | Usage |
|-------|-------|
| `error` | Application errors requiring attention |
| `warn` | Unexpected but handled conditions |
| `info` | Normal operational messages |
| `debug` | Detailed debugging information |

## Examples

### Request Logging

```json
{
  "timestamp": "2026-02-06T22:00:00.000Z",
  "level": "info",
  "appName": "my-app",
  "component": "RequestLogger",
  "message": "Request completed",
  "correlationId": "abc-123",
  "requestId": "req-456",
  "method": "GET",
  "path": "/api/users/123",
  "statusCode": 200,
  "durationMs": 45
}
```

### Error Logging

```json
{
  "timestamp": "2026-02-06T22:00:00.000Z",
  "level": "error",
  "appName": "my-app",
  "component": "DatabaseClient",
  "message": "Failed to connect to database",
  "correlationId": "abc-123",
  "error": "ECONNREFUSED",
  "stack": "Error: connect ECONNREFUSED\n    at TCPConnectWrap.afterConnect"
}
```

### Authentication Event

```json
{
  "timestamp": "2026-02-06T22:00:00.000Z",
  "level": "info",
  "appName": "my-app",
  "component": "AuthMiddleware",
  "message": "User authenticated",
  "correlationId": "abc-123",
  "userId": "user-789",
  "method": "POST",
  "path": "/login"
}
```

## Implementation Examples

### Node.js with Winston

```typescript
import { createLogger, format, transports } from 'winston';

const logger = createLogger({
  format: format.combine(
    format.timestamp({ format: 'YYYY-MM-DDTHH:mm:ss.SSSZ' }),
    format.json()
  ),
  defaultMeta: {
    appName: process.env.APP_NAME || 'my-app'
  },
  transports: [
    new transports.Console()
  ]
});

// Add correlation context
export function withCorrelation(correlationId: string) {
  return logger.child({ correlationId });
}
```

### Node.js with Pino

```typescript
import pino from 'pino';

const logger = pino({
  base: {
    appName: process.env.APP_NAME || 'my-app'
  },
  timestamp: pino.stdTimeFunctions.isoTime,
  formatters: {
    level: (label) => ({ level: label })
  }
});
```

### Express Request Logging Middleware

```typescript
import { v4 as uuidv4 } from 'uuid';

export function requestLogger(req, res, next) {
  const start = Date.now();
  const requestId = uuidv4();
  const correlationId = req.headers['x-correlation-id'] || uuidv4();

  req.correlationId = correlationId;
  req.requestId = requestId;

  res.on('finish', () => {
    logger.info('Request completed', {
      component: 'RequestLogger',
      correlationId,
      requestId,
      method: req.method,
      path: req.path,
      statusCode: res.statusCode,
      durationMs: Date.now() - start
    });
  });

  next();
}
```

## Querying Logs in Grafana

### By Service

```
{appName="my-app"}
```

### By Level

```
{appName="my-app", level="error"}
```

### By Correlation ID

```
{appName=~".+"} |= "abc-123-def"
```

### Search Message Content

```
{appName="my-app"} |= "failed"
```

### Parse JSON Fields

```
{appName="my-app"} | json | durationMs > 100
```

## Best Practices

1. **Always include correlation IDs** - Essential for tracing requests across services
2. **Use consistent log levels** - Reserve `error` for actual errors
3. **Include context** - Add relevant fields for debugging
4. **Keep messages concise** - Use fields for details, not the message
5. **Don't log sensitive data** - Never log passwords, tokens, or PII
6. **Use structured fields** - Avoid string interpolation in messages
