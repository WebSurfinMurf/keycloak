#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Keycloak Deployment Script (Community-Vetted Fix)
# ==============================================================================
#
# Description:
#   This script uses the community-recommended solution for mixed-content
#   errors. It configures a Traefik middleware to explicitly set the
#   X-Forwarded-Proto header, which is the standard way to inform a backend
#   application that it is behind a secure reverse proxy. It also sets the
#   required KC_HOSTNAME variable to satisfy Keycloak's startup checks.
#
# ==============================================================================


# ── Load secrets ──────────────────────────────────────────────
source "$(dirname "$0")/../secrets/keycloak.env"

# ── Infra provisioning ───────────────────────────────────────
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
# Define the hostnames that will be routed to Keycloak
PUBLIC_HOSTNAME="embracenow.asuscomm.com"
INTERNAL_HOSTNAME="keycloak.linuxserver.lan"


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

echo "Starting Keycloak (${KC_IMAGE}) with Traefik header middleware..."
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
  -e KC_PROXY=edge \
  -e KC_HOSTNAME=${PUBLIC_HOSTNAME} \
  --label "traefik.enable=true" \
  --label "traefik.docker.network=traefik-proxy" \
  --label "traefik.http.middlewares.keycloak-headers.headers.customrequestheaders.X-Forwarded-Proto=https" \
  --label "traefik.http.routers.keycloak-secure.rule=Host(\`${PUBLIC_HOSTNAME}\`, \`${INTERNAL_HOSTNAME}\`)" \
  --label "traefik.http.routers.keycloak-secure.entrypoints=websecure" \
  --label "traefik.http.routers.keycloak-secure.tls=true" \
  --label "traefik.http.routers.keycloak-secure.tls.certresolver=letsencrypt" \
  --label "traefik.http.routers.keycloak-secure.middlewares=keycloak-headers@docker" \
  --label "traefik.http.services.keycloak-service.loadbalancer.server.url=http://keycloak:8080" \
  --label "traefik.http.routers.keycloak-secure.service=keycloak-service" \
  "${KC_IMAGE}" start \
    --http-enabled=true

echo
echo "✔️ All set! Keycloak is being managed by Traefik."
echo "   Access it at: https://${PUBLIC_HOSTNAME} (or https://${INTERNAL_HOSTNAME})"
