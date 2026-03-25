#!/usr/bin/env bash
# start-all.sh – Start all Kafka-Ranger services and verify they are running.

set -euo pipefail

COMPOSE_FILES=(
  -f docker-compose.ranger-base.yml
  -f docker-compose.ranger.yml
  -f docker-compose.ranger-postgres.yml
  -f docker-compose.ranger-usersync.yml
  -f docker-compose.ranger-tagsync.yml
  -f docker-compose.ranger-kafka.yml
  -f docker-compose.ranger-schema-registry.yml
)

###############################################################################
# 0. Pre-flight: dist/ must contain Ranger artifacts.
#    If missing, run the build container first:
#      docker compose -f docker compose.ranger-base.yml \
#                     -f docker compose.ranger-build.yml up
#    (This clones Apache Ranger from GitHub and compiles it — may take ~45 min)
###############################################################################
if [ ! -f dist/version ]; then
  echo "ERROR: dist/version not found. Ranger artifacts have not been built yet."
  echo ""
  echo "  Run the build container first:"
  echo "    docker compose -f docker-compose.ranger-base.yml \\"
  echo "                   -f docker-compose.ranger-build.yml up"
  echo ""
  echo "  Then re-run this script once the build completes."
  exit 1
fi

###############################################################################
# 1. Export required environment variables
###############################################################################
export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1
export RANGER_DB_TYPE=postgres

# Load additional variables from .env when present
if [ -f .env ]; then
  # Export only KEY=VALUE lines (skip comments and blank lines)
  set -o allexport
  # shellcheck disable=SC1091
  source .env
  set +o allexport
fi

###############################################################################
# 2. Start all services in detached mode
###############################################################################
echo "==> Starting all Kafka-Ranger services..."
docker compose "${COMPOSE_FILES[@]}" up -d

###############################################################################
# 3. Verify that every container is running (not exited / restarting)
###############################################################################
echo ""
echo "==> Checking container status..."

ERRORS=0
TIMEOUT=${HEALTH_TIMEOUT:-30}   # seconds to wait for containers to stabilise
INTERVAL=3                       # poll every N seconds

# Collect the names of every service defined in the compose files
mapfile -t SERVICE_NAMES < <(docker compose "${COMPOSE_FILES[@]}" ps --services 2>/dev/null)

check_containers() {
  local failed=0
  for svc in "${SERVICE_NAMES[@]}"; do
    # Resolve the actual container name from the compose project
    local container_id
    container_id=$(docker compose "${COMPOSE_FILES[@]}" ps -q "$svc" 2>/dev/null | head -n1)

    if [[ -z "$container_id" ]]; then
      echo "  [ERROR] $svc  (container not found)"
      failed=$(( failed + 1 ))
      continue
    fi

    # Use docker inspect for reliable state information
    local status
    status=$(docker inspect --format '{{.State.Status}}' "$container_id" 2>/dev/null)

    if [[ "$status" == "running" ]]; then
      echo "  [OK]    $svc  ($status)"
    else
      echo "  [ERROR] $svc  ($status)"
      failed=$(( failed + 1 ))
    fi
  done
  return "$failed"
}

# Retry loop – wait up to TIMEOUT seconds for all containers to stabilise
elapsed=0
while true; do
  # Reset output buffer so we can reprint on each iteration
  output=$(check_containers 2>&1)
  failed_count=$(echo "$output" | grep -c '\[ERROR\]' || true)

  if [[ "$failed_count" -eq 0 ]]; then
    echo "$output"
    ERRORS=0
    break
  fi

  if [[ "$elapsed" -ge "$TIMEOUT" ]]; then
    echo "$output"
    ERRORS="$failed_count"
    break
  fi

  sleep "$INTERVAL"
  elapsed=$(( elapsed + INTERVAL ))
  echo "  (waiting for containers to start... ${elapsed}s / ${TIMEOUT}s)"
done

echo ""
if [ "$ERRORS" -gt 0 ]; then
  echo "==> $ERRORS container(s) failed to start. Inspect individual service logs with:"
  echo "    docker compose -f docker compose.ranger-base.yml -f docker compose.ranger.yml \\"
  echo "      -f docker compose.ranger-postgres.yml -f docker compose.ranger-usersync.yml \\"
  echo "      -f docker compose.ranger-tagsync.yml -f docker compose.ranger-kafka.yml \\"
  echo "      logs --tail=50 <service>"
  exit 1
else
  echo "==> All services are running successfully."
  echo "    Ranger Admin: http://localhost:6080  (admin / rangerR0cks!)"
fi
