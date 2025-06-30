#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Keycloak Deployment Script (Traefik-Integrated)
# ==============================================================================
#
# Description:
#   This script deploys Keycloak and a Postgres database. It is configured
#   with Docker labels to be automatically discovered and managed by a
#   separate Traefik container.
#
# Key Changes:
#   1. Connects both containers to the Traefik network.
#   2. Removes direct port mapping (-p) from Keycloak, as Traefik will handle it.
#   3. Adds Docker labels to the Keycloak container so Traefik can discover
#      and route traffic to it automatically.
#
# ==============================================================================


# ── Load secrets ──────────────────────────────────────────────
# AI: source project-specific env after pipeline.env loads
source "$(dirname "$0")/../secrets/keycloak.env"

# ── Infra provisioning ───────────────────────────────────────
# IMPORTANT: This network MUST match the TRAEFIK_NETWORK in your traefik.env
NETWORK="traefik-proxy"
PG_VOLUME="keycloak_pg_data"
KC_VOLUME="keycloak_data"

# ensure network exists
if ! docker network ls --format '{{.Name}}' | grep -qx "${NETWORK}"; then
  echo "Creating network ${NETWORK}…"
  docker network create "${NETWORK}"
fi

# ensure volumes exist
for vol in "${PG_VOLUME}" "${KC_VOLUME}"; do
  if ! docker volume ls --format '{{.Name}}' | grep -qx "${vol}"; then
    echo "Creating volume ${vol}…"
    docker volume create "${vol}"
  fi
done

# ── Docker settings ──────────────────────────────────────────
PG_CONTAINER="keycloak-postgres"
KC_CONTAINER="keycloak"
PG_IMAGE="postgres:15"
KC_IMAGE="quay.io/keycloak/keycloak:latest"
# This hostname will be the URL for your Keycloak instance.
# You can change 'keycloak' to something else if you prefer.
KEYCLOAK_HOSTNAME="keycloak.linuxserver.lan"


# ── Postgres: only create/start if not already running ────────
if docker ps --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
  echo "Postgres '${PG_CONTAINER}' is already running → skipping"
elif docker ps -a --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
  echo "Postgres '${PG_CONTAINER}' exists but is stopped → starting"
  docker start "${PG_CONTAINER}"
else
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
fi

# ── Keycloak: always remove & re-deploy ───────────────────────
if docker ps -a --format '{{.Names}}' | grep -qx "${KC_CONTAINER}"; then
  echo "Removing existing Keycloak container '${KC_CONTAINER}'…"
  docker rm -f "${KC_CONTAINER}"
fi

echo "Starting Keycloak (${KC_IMAGE}) with Traefik labels..."
docker run -d \
  --name "${KC_CONTAINER}" \
  --network "${NETWORK}" \
  --restart unless-stopped \
  -v "${KC_VOLUME}":/opt/keycloak/data \
  -e KC_BOOTSTRAP_ADMIN_USERNAME="${KEYCLOAK_ADMIN}" \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD}" \
  -e KC_DB=postgres \
  -e KC_DB_URL="jdbc:postgresql://${PG_CONTAINER}:5432/${POSTGRES_DB}" \
  -e KC_DB_USERNAME="${POSTGRES_USER}" \
  -e KC_DB_PASSWORD="${POSTGRES_PASSWORD}" \
  -e KC_HOSTNAME="${KEYCLOAK_HOSTNAME}" \
  --label "traefik.enable=true" \
  --label "traefik.http.routers.keycloak.rule=Host(\`${KEYCLOAK_HOSTNAME}\`)" \
  --label "traefik.http.routers.keycloak.entrypoints=websecure" \
  --label "traefik.http.routers.keycloak.tls.certresolver=letsencrypt" \
  --label "traefik.http.services.keycloak.loadbalancer.server.port=8080" \
  "${KC_IMAGE}" start \
    --proxy=edge \
    --hostname-strict=false \
    --optimized

echo
echo "✔️ All set! Keycloak is being managed by Traefik."
echo "   Access it at: https://${KEYCLOAK_HOSTNAME}"

