#!/bin/bash
# docker-startup.sh — Boot-order orchestration for all Docker services (#382)
#
# Waits for Docker Desktop daemon, starts compose stacks in dependency order,
# health-gates between phases, validates host-level port connectivity.
#
# Triggered by: com.chorus.docker-services LaunchAgent (on login)
# Also callable: app-state.sh boot
#
# Log: /tmp/docker-startup.log

set -uo pipefail

CASCADEPROJECTS="/Users/jeffbridwell/CascadeProjects"
MAX_DOCKER_WAIT=180  # seconds to wait for Docker daemon
MAX_HEALTH_WAIT=90   # seconds to wait for a container health check
POLL_INTERVAL=5

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [docker-startup] $*"; }

wait_for_docker() {
  local elapsed=0
  log "Waiting for Docker daemon (max ${MAX_DOCKER_WAIT}s)..."
  while ! docker info &>/dev/null; do
    if [ $elapsed -ge $MAX_DOCKER_WAIT ]; then
      log "ERROR: Docker daemon not ready after ${MAX_DOCKER_WAIT}s"
      return 1
    fi
    sleep $POLL_INTERVAL
    elapsed=$((elapsed + POLL_INTERVAL))
  done
  log "Docker daemon ready after ${elapsed}s"
}

wait_healthy() {
  local container=$1
  local timeout=${2:-$MAX_HEALTH_WAIT}
  local elapsed=0
  while [ "$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null)" != "healthy" ]; do
    if [ $elapsed -ge $timeout ]; then
      log "WARN: $container not healthy after ${timeout}s — continuing"
      return 1
    fi
    sleep $POLL_INTERVAL
    elapsed=$((elapsed + POLL_INTERVAL))
  done
  log "$container healthy (${elapsed}s)"
}

check_host_port() {
  local name=$1 host=$2 port=$3
  if curl -s --max-time 5 -o /dev/null "http://${host}:${port}" 2>/dev/null; then
    log "  $name — ${host}:${port} OK"
  else
    log "  WARN: $name — ${host}:${port} NOT reachable"
  fi
}

BEDROOM="192.168.86.242"

# ── Stage 0: Docker daemon ──────────────────────────────────────────

wait_for_docker || exit 1

# Ensure shared network exists
docker network create observability-network 2>/dev/null && log "Created observability-network" || true

# ── Stage 1: Observability (no app dependencies) ────────────────────

log "Stage 1: Starting observability stack..."
docker compose -f "$CASCADEPROJECTS/shared-observability/docker-compose.yml" up -d 2>&1 | grep -v "^$"

wait_healthy loki 60
wait_healthy prometheus 60

# ── Stage 2: Infrastructure services (parallel) ─────────────────────

log "Stage 2: Starting infrastructure services..."
docker compose -f "$CASCADEPROJECTS/messages/vikunja/docker-compose.yml" up -d 2>&1 | grep -v "^$" &
docker compose -f "$CASCADEPROJECTS/wordpress-blog/docker-compose.yml" up -d 2>&1 | grep -v "^$" &
wait

# ── Stage 3: Application (Fuseki must be healthy before app) ────────

log "Stage 3: Starting application stack..."
docker compose -f "$CASCADEPROJECTS/jeff-bridwell-personal-site/docker-compose.yml" up -d 2>&1 | grep -v "^$"

wait_healthy jeff-bridwell-personal-site-fuseki 90
wait_healthy jeff-bridwell-personal-site-app 60

# ── Stage 4: Host-level port validation ─────────────────────────────

# ── Stage 3b: Chorus API (bare Node, not Docker) ────────────────────

if ! curl -s --max-time 2 http://localhost:3340/health &>/dev/null; then
  log "Starting Chorus API..."
  launchctl kickstart "gui/$(id -u)/com.chorus.api" 2>/dev/null || true
  sleep 2
fi

# ── Stage 4: Host-level port validation ─────────────────────────────

log "Stage 4: Validating Library host connectivity..."
check_host_port "App"           localhost 3000
check_host_port "Grafana"       localhost 3100
check_host_port "Loki"          localhost 3102
check_host_port "Vikunja"       localhost 3456
check_host_port "Prometheus"    localhost 9090
check_host_port "WordPress"     localhost 8081
check_host_port "Chorus API"    localhost 3340

# ── Stage 5: Bedroom (secondary Mac) validation ────────────────────

log "Stage 5: Validating Bedroom connectivity..."
check_host_port "images-api"    "$BEDROOM" 3001
check_host_port "video-server"  "$BEDROOM" 8082

# ── Summary ─────────────────────────────────────────────────────────

TOTAL=$(docker ps --format '{{.Names}}' | wc -l | tr -d ' ')
HEALTHY=$(docker ps --filter health=healthy --format '{{.Names}}' | wc -l | tr -d ' ')
log "Library: ${HEALTHY}/${TOTAL} containers healthy"

docker ps --format "table {{.Names}}\t{{.Status}}" | sort
