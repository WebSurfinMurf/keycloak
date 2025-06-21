#!/usr/bin/env bash
set -euo pipefail

# ── Load secrets ──────────────────────────────────────────────
#AI: source project-specific env after pipeline.env loads
source "$(dirname "$0")/../secrets/keycloak.env"

# ── Docker settings ──────────────────────────────────────────
NETWORK="keycloak-net"
PG_CONTAINER="keycloak-postgres"
KC_CONTAINER="keycloak"
PG_VOLUME="keycloak_pg_data"
KC_VOLUME="keycloak_data"
PG_IMAGE="postgres:15"
KC_IMAGE="quay.io/keycloak/keycloak:latest"
HTTP_PORT=8080

# ── Tear down old instances ──────────────────────────────────
for name in "$KC_CONTAINER" "$PG_CONTAINER"; do
  if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
    echo "Removing existing container ${name}…"
    docker rm -f "${name}"
  fi
done

# ── Run Postgres ─────────────────────────────────────────────
echo "Starting Postgres (${PG_IMAGE})…"
docker run -d \
  --name "${PG_CONTAINER}" \
  --network "${NETWORK}" \
  --restart unless-stopped \
  -v "${PG_VOLUME}":/var/lib/postgresql/data \
  -e POSTGRES_DB="${POSTGRES_DB}" \
  -e POSTGRES_USER="${POSTGRES_USER}" \
  -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
  "${PG_IMAGE}"

# ── Run Keycloak ─────────────────────────────────────────────
echo "Starting Keycloak (${KC_IMAGE})…"
docker run -d \
  --name "${KC_CONTAINER}" \
  --network "${NETWORK}" \
  --restart unless-stopped \
  -p "${HTTP_PORT}:8080" \
  -v "${KC_VOLUME}":/opt/keycloak/data \
  -e KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN}" \
  -e KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD}" \
  -e KC_DB=postgres \
  -e KC_DB_URL="jdbc:postgresql://${PG_CONTAINER}:5432/${POSTGRES_DB}" \
  -e KC_DB_USERNAME="${POSTGRES_USER}" \
  -e KC_DB_PASSWORD="${POSTGRES_PASSWORD}" \
  "${KC_IMAGE}" start

echo
echo "✔️ All set! Keycloak is live on port ${HTTP_PORT}:"
echo "   http://$(hostname -I | awk '{print $1}'):${HTTP_PORT}/"
