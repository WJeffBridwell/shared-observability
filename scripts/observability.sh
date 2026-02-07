#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        exit 1
    fi
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running"
        exit 1
    fi
}

start() {
    log_info "Starting shared observability stack..."
    check_docker

    # Create data directories if they don't exist
    mkdir -p "$PROJECT_DIR/data"

    # Start all services
    docker compose -f "$COMPOSE_FILE" up -d

    log_info "Waiting for services to be healthy..."
    sleep 5

    # Check service health
    status

    log_success "Observability stack started!"
    echo ""
    echo "Access points:"
    echo "  Grafana:    http://localhost:3100 (admin/admin)"
    echo "  Prometheus: http://localhost:9090"
    echo "  Loki:       http://localhost:3102"
    echo ""
    echo "To connect a service, add it to the 'observability-network' Docker network"
    echo "and add labels: metrics.enabled=true, metrics.port=<port>, metrics.path=/metrics"
}

stop() {
    log_info "Stopping shared observability stack..."
    docker compose -f "$COMPOSE_FILE" down
    log_success "Observability stack stopped"
}

restart() {
    log_info "Restarting shared observability stack..."
    docker compose -f "$COMPOSE_FILE" restart
    log_success "Observability stack restarted"
}

destroy() {
    log_warn "This will remove all containers, networks, and volumes (including data)"
    read -p "Are you sure? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Destroying shared observability stack..."
        docker compose -f "$COMPOSE_FILE" down -v --remove-orphans
        rm -rf "$PROJECT_DIR/data"
        log_success "Observability stack destroyed"
    else
        log_info "Cancelled"
    fi
}

status() {
    log_info "Observability stack status:"
    echo ""

    # Check each service
    services=("prometheus" "grafana" "loki" "promtail" "node-exporter")

    for service in "${services[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${service}$"; then
            status=$(docker inspect --format='{{.State.Status}}' "$service" 2>/dev/null || echo "unknown")
            if [ "$status" = "running" ]; then
                echo -e "  ${GREEN}●${NC} $service (running)"
            else
                echo -e "  ${YELLOW}●${NC} $service ($status)"
            fi
        else
            echo -e "  ${RED}●${NC} $service (not running)"
        fi
    done

    echo ""

    # Check network
    if docker network ls --format '{{.Name}}' | grep -q "^observability-network$"; then
        connected=$(docker network inspect observability-network --format '{{len .Containers}}' 2>/dev/null || echo "0")
        echo -e "  ${GREEN}●${NC} observability-network ($connected containers connected)"
    else
        echo -e "  ${RED}●${NC} observability-network (not created)"
    fi
}

logs() {
    local follow=""
    local service=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--follow)
                follow="-f"
                shift
                ;;
            *)
                service="$1"
                shift
                ;;
        esac
    done

    if [ -n "$service" ]; then
        docker compose -f "$COMPOSE_FILE" logs $follow "$service"
    else
        docker compose -f "$COMPOSE_FILE" logs $follow
    fi
}

health() {
    log_info "Checking service health..."
    echo ""

    # Check Prometheus
    if curl -s "http://localhost:9090/-/healthy" | grep -q "Healthy"; then
        echo -e "  ${GREEN}●${NC} Prometheus: healthy"
    else
        echo -e "  ${RED}●${NC} Prometheus: unhealthy"
    fi

    # Check Grafana
    if curl -s "http://localhost:3100/api/health" | grep -q "ok"; then
        echo -e "  ${GREEN}●${NC} Grafana: healthy"
    else
        echo -e "  ${RED}●${NC} Grafana: unhealthy"
    fi

    # Check Loki
    if curl -s "http://localhost:3102/ready" | grep -q "ready"; then
        echo -e "  ${GREEN}●${NC} Loki: healthy"
    else
        echo -e "  ${RED}●${NC} Loki: unhealthy"
    fi

    # Check Node Exporter
    if curl -s "http://localhost:9100/metrics" > /dev/null 2>&1; then
        echo -e "  ${GREEN}●${NC} Node Exporter: healthy"
    else
        echo -e "  ${RED}●${NC} Node Exporter: unhealthy"
    fi
}

targets() {
    log_info "Prometheus scrape targets:"
    echo ""
    curl -s "http://localhost:9090/api/v1/targets" | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
for target in data.get('data', {}).get('activeTargets', []):
    state = target.get('health', 'unknown')
    job = target.get('labels', {}).get('job', 'unknown')
    instance = target.get('scrapePool', 'unknown')
    color = '\033[32m' if state == 'up' else '\033[31m'
    print(f'  {color}●\033[0m {job}: {target.get(\"scrapeUrl\", \"\")} ({state})')
" 2>/dev/null || echo "  Could not fetch targets (is Prometheus running?)"
}

usage() {
    echo "Shared Observability Stack Management"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  start       Start all observability services"
    echo "  stop        Stop all services"
    echo "  restart     Restart all services"
    echo "  destroy     Remove all containers, networks, and volumes"
    echo "  status      Show service status"
    echo "  health      Check service health endpoints"
    echo "  targets     Show Prometheus scrape targets"
    echo "  logs [-f]   View logs (optionally follow)"
    echo ""
    echo "Examples:"
    echo "  $0 start"
    echo "  $0 logs -f prometheus"
    echo "  $0 status"
}

# Main
case "${1:-}" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        restart
        ;;
    destroy)
        destroy
        ;;
    status)
        status
        ;;
    health)
        health
        ;;
    targets)
        targets
        ;;
    logs)
        shift
        logs "$@"
        ;;
    *)
        usage
        exit 1
        ;;
esac
