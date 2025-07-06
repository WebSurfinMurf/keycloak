#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Keycloak Deployment Script - FINAL Root Access Version
# ==============================================================================

# ── Load secrets ──────────────────────────────────────────────
source "$(dirname "$0")/../secrets/keycloak.env"

# ── Docker settings ──────────────────────────────────────────
KC_CONTAINER="keycloak"
PG_CONTAINER="keycloak-postgres"
NETWORK="traefik-proxy"
KC_IMAGE="quay.io/keycloak/keycloak:latest"
PUBLIC_HOSTNAME="embracenow.asuscomm.com"
LOCAL_HOSTNAME="linuxserver.lan" # Corrected to your preferred local hostname
PG_VOLUME="keycloak_pg_data"
KC_VOLUME="keycloak_data"

# ── Infra provisioning ───────────────────────────────────────
if ! docker network ls --format '{{.Name}}' | grep -qx "${NETWORK}"; then
  echo "Creating network ${NETWORK}..."
  docker network create "${NETWORK}"
fi
for vol in "${PG_VOLUME}" "${KC_VOLUME}"; do
  if ! docker volume ls --format '{{.Name}}' | grep -qx "${vol}"; then
    echo "Creating volume ${vol}..."
    docker volume create "${vol}"
  fi
done

# ── Postgres Container (No changes needed here) ──────────────
if docker ps --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
  echo "Postgres '${PG_CONTAINER}' is already running → skipping"
elif docker ps -a --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
  echo "Postgres '${PG_CONTAINER}' exists but is stopped → starting"
  docker start "${PG_CONTAINER}"
else
  echo "Starting Postgres..."
  docker run -d \
    --name "${PG_CONTAINER}" \
    --network "${NETWORK}" \
    --restart unless-stopped \
    -v "${PG_VOLUME}":/var/lib/postgresql/data \
    -e POSTGRES_DB="${POSTGRES_DB}" \
    -e POSTGRES_USER="${POSTGRES_USER}" \
    -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    postgres:15
fi

# ── Keycloak: always remove & re-deploy ───────────────────────
if docker ps -a --format '{{.Names}}' | grep -qx "${KC_CONTAINER}"; then
  echo "Removing existing Keycloak container '${KC_CONTAINER}'..."
  docker rm -f "${KC_CONTAINER}"
fi

echo "Starting Keycloak for root access at https://${PUBLIC_HOSTNAME} ..."
docker run -d \
  --name "${KC_CONTAINER}" \
  --network "${NETWORK}" \
  --restart unless-stopped \
  -v "${KC_VOLUME}":/opt/keycloak/data \
  -e KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN}" \
  -e KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD}" \
  -e KC_DB_USERNAME="${POSTGRES_USER}" \
  -e KC_DB_PASSWORD="${POSTGRES_PASSWORD}" \
  -e KC_DB="postgres" \
  -e KC_DB_URL_HOST="keycloak-postgres" \
  -e KC_DB_URL_DATABASE="${POSTGRES_DB}" \
  --label "traefik.enable=true" \
  --label "traefik.http.routers.keycloak-router.rule=Host(\`${PUBLIC_HOSTNAME}\`) || Host(\`${LOCAL_HOSTNAME}\`)" \
  --label "traefik.http.routers.keycloak-router.entrypoints=web,websecure" \
  --label "traefik.http.routers.keycloak-router.tls.certresolver=letsencrypt" \
  --label "traefik.http.services.keycloak-service.loadbalancer.server.port=8080" \
  "${KC_IMAGE}" \
  start \
  --hostname=${PUBLIC_HOSTNAME} \
  --proxy-headers=xforwarded \
  --http-enabled=true

echo
echo "✔️ Deployment complete! Keycloak should be accessible shortly."
echo "    Public URL: https://${PUBLIC_HOSTNAME}"
echo "    Local URL:  http://${LOCAL_HOSTNAME}"
