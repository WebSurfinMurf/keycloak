#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Keycloak Deployment Script with LDAP Support
# ==============================================================================

# ── Load secrets ──────────────────────────────────────────────
source "$(dirname "$0")/../secrets/keycloak.env"

# ── Infra provisioning ───────────────────────────────────────
NETWORK="traefik-proxy"
PG_VOLUME="keycloak_pg_data"
KC_VOLUME="keycloak_data"
LDAP_VOLUME="keycloak_ldap_data"

# ensure network exists
if ! docker network ls --format '{{.Name}}' | grep -qx "${NETWORK}"; then
  echo "Creating network ${NETWORK}…"
  docker network create "${NETWORK}"
fi

# ensure volumes exist
for vol in "${PG_VOLUME}" "${KC_VOLUME}" "${LDAP_VOLUME}"; do
  if ! docker volume ls --format '{{.Name}}' | grep -qx "${vol}"; then
    echo "Creating volume ${vol}…"
    docker volume create "${vol}"
  fi
done

# ── Docker settings ──────────────────────────────────────────
PG_CONTAINER="keycloak-postgres"
KC_CONTAINER="keycloak"
LDAP_CONTAINER="keycloak-ldap"
PG_IMAGE="postgres:15"
KC_IMAGE="quay.io/keycloak/keycloak:latest"
LDAP_IMAGE="osixia/openldap:latest"

PUBLIC_HOSTNAME="keycloak.ai-servicers.com"
INTERNAL_HOSTNAME="keycloak.linuxserver.lan"

# ── OpenLDAP: only create/start if not already running ────────
if docker ps --format '{{.Names}}' | grep -qx "${LDAP_CONTAINER}"; then
  echo "OpenLDAP '${LDAP_CONTAINER}' is already running → skipping"
elif docker ps -a --format '{{.Names}}' | grep -qx "${LDAP_CONTAINER}"; then
  echo "OpenLDAP '${LDAP_CONTAINER}' exists but is stopped → starting"
  docker start "${LDAP_CONTAINER}"
else
  echo "Starting OpenLDAP server for Keycloak integration..."
  docker run -d \
    --name "${LDAP_CONTAINER}" \
    --network "${NETWORK}" \
    --restart unless-stopped \
    -v "${LDAP_VOLUME}":/var/lib/ldap \
    -v "${LDAP_VOLUME}"/config:/etc/ldap/slapd.d \
    -e LDAP_ORGANISATION="AI Servicers" \
    -e LDAP_DOMAIN="ai-servicers.com" \
    -e LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD:-changeme123}" \
    -e LDAP_CONFIG_PASSWORD="${LDAP_CONFIG_PASSWORD:-changeme123}" \
    -p 389:389 \
    -p 636:636 \
    "${LDAP_IMAGE}"
  
  # Wait for LDAP to initialize
  echo "Waiting for LDAP to initialize..."
  sleep 10
  
  # Add initial user structure
  docker exec "${LDAP_CONTAINER}" ldapadd -x -D "cn=admin,dc=ai-servicers,dc=com" -w "${LDAP_ADMIN_PASSWORD:-changeme123}" << EOF
dn: ou=users,dc=ai-servicers,dc=com
objectClass: organizationalUnit
ou: users

dn: ou=groups,dc=ai-servicers,dc=com
objectClass: organizationalUnit
ou: groups

dn: cn=mailu-admins,ou=groups,dc=ai-servicers,dc=com
objectClass: groupOfNames
cn: mailu-admins
member: cn=admin,ou=users,dc=ai-servicers,dc=com

dn: cn=mailu-users,ou=groups,dc=ai-servicers,dc=com
objectClass: groupOfNames
cn: mailu-users
member: cn=admin,ou=users,dc=ai-servicers,dc=com
EOF
fi

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

echo "Starting Keycloak with LDAP integration support..."
docker run -d \
  --name "${KC_CONTAINER}" \
  --network "${NETWORK}" \
  --restart unless-stopped \
  -v "${KC_VOLUME}":/opt/keycloak/data \
  -e KC_BOOTSTRAP_ADMIN_USERNAME="${KEYCLOAK_ADMIN}" \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD}" \
  -e KC_DB="postgres" \
  -e KC_DB_URL_HOST="keycloak-postgres" \
  -e KC_DB_URL_DATABASE="${POSTGRES_DB}" \
  -e KC_DB_USERNAME="${POSTGRES_USER}" \
  -e KC_DB_PASSWORD="${POSTGRES_PASSWORD}" \
  --label "traefik.enable=true" \
  --label "traefik.docker.network=traefik-proxy" \
  --label "traefik.http.routers.keycloak-secure.rule=Host(\`${PUBLIC_HOSTNAME}\`)" \
  --label "traefik.http.routers.keycloak-secure.entrypoints=websecure" \
  --label "traefik.http.routers.keycloak-secure.tls=true" \
  --label "traefik.http.routers.keycloak-secure.tls.certresolver=letsencrypt" \
  --label "traefik.http.routers.keycloak-secure.tls.domains[0].main=ai-servicers.com" \
  --label "traefik.http.routers.keycloak-secure.tls.domains[0].sans=*.ai-servicers.com" \
  --label "traefik.http.routers.keycloak-secure.service=keycloak-service" \
  --label "traefik.http.routers.keycloak-internal.rule=Host(\`${INTERNAL_HOSTNAME}\`)" \
  --label "traefik.http.routers.keycloak-internal.entrypoints=web" \
  --label "traefik.http.routers.keycloak-internal.service=keycloak-service" \
  --label "traefik.http.services.keycloak-service.loadbalancer.server.port=8080" \
  "${KC_IMAGE}" start \
    --hostname=${PUBLIC_HOSTNAME} \
    --proxy-headers=xforwarded \
    --http-enabled=true

echo
echo "✔️ Keycloak with LDAP support is ready!"
echo "   • Keycloak Admin: https://${PUBLIC_HOSTNAME}/admin/"
echo "   • LDAP Server: ${LDAP_CONTAINER}:389"
echo "   • LDAP Admin DN: cn=admin,dc=ai-servicers,dc=com"
echo ""
echo "📋 Next Steps:"
echo "   1. Configure LDAP User Federation in Keycloak Admin Console"
echo "   2. Update Mailu to use LDAP authentication"
echo "   3. Test user creation and authentication flow"
echo ""
echo "🔧 LDAP Configuration for Keycloak:"
echo "   Server URL: ldap://keycloak-ldap:389"
echo "   Bind DN: cn=admin,dc=ai-servicers,dc=com"
echo "   Bind Password: ${LDAP_ADMIN_PASSWORD:-changeme123}"
echo "   Users DN: ou=users,dc=ai-servicers,dc=com"
echo "   Username LDAP Attribute: uid"
echo "   User Object Classes: inetOrgPerson,organizationalPerson"
