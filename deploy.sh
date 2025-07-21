#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Keycloak Deployment Script with LDAP Support (Environment-Driven)
# ==============================================================================

# ── Load secrets ──────────────────────────────────────────────
ENV_FILE="$(dirname "$0")/../secrets/keycloak.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "❌ ERROR: Environment file not found at $ENV_FILE"
    exit 1
fi

echo "Loading environment variables from $ENV_FILE..."
set -o allexport
source "$ENV_FILE"
set +o allexport

# ── Validation ──────────────────────────────────────────────
echo "=== Validating Environment Variables ==="
required_vars=(
    "KEYCLOAK_ADMIN" "KEYCLOAK_ADMIN_PASSWORD"
    "POSTGRES_DB" "POSTGRES_USER" "POSTGRES_PASSWORD"
    "LDAP_ADMIN_PASSWORD" "PUBLIC_HOSTNAME"
)

for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "❌ ERROR: Required variable $var is not set"
        exit 1
    fi
done
echo "✔️ Environment validation passed"

# ── Infra provisioning ───────────────────────────────────────
echo "=== Setting up infrastructure ==="

# ensure network exists
if ! docker network ls --format '{{.Name}}' | grep -qx "${NETWORK}"; then
  echo "Creating network ${NETWORK}…"
  docker network create "${NETWORK}"
fi

# ensure volumes exist
for vol in "${PG_VOLUME}" "${KC_VOLUME}" "${LDAP_VOLUME}" "${LDAP_VOLUME}_config"; do
  if ! docker volume ls --format '{{.Name}}' | grep -qx "${vol}"; then
    echo "Creating volume ${vol}…"
    docker volume create "${vol}"
  fi
done

# ── OpenLDAP: only create/start if not already running ────────
echo "=== Setting up OpenLDAP Server ==="
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
    -v "${LDAP_VOLUME}_config":/etc/ldap/slapd.d \
    -e LDAP_ORGANISATION="${LDAP_ORGANISATION}" \
    -e LDAP_DOMAIN="${LDAP_DOMAIN}" \
    -e LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD}" \
    -e LDAP_CONFIG_PASSWORD="${LDAP_CONFIG_PASSWORD:-$LDAP_ADMIN_PASSWORD}" \
    -e LDAP_TLS_VERIFY_CLIENT="${LDAP_TLS_VERIFY_CLIENT:-never}" \
    -p 389:389 \
    -p 636:636 \
    "${LDAP_IMAGE}"
  
  # Wait for LDAP to initialize
  echo "Waiting for LDAP to initialize..."
  sleep 15
  
  # Create initial organizational structure
  echo "Setting up LDAP organizational structure..."
  docker exec "${LDAP_CONTAINER}" bash -c "cat > /tmp/structure.ldif << 'EOF'
dn: ${LDAP_USERS_DN}
objectClass: organizationalUnit
ou: users

dn: ${LDAP_GROUPS_DN}
objectClass: organizationalUnit
ou: groups

dn: ou=services,${LDAP_BASE_DN}
objectClass: organizationalUnit
ou: services

dn: cn=mailu-admins,${LDAP_GROUPS_DN}
objectClass: groupOfNames
cn: mailu-admins
description: Mailu administrators group
member: cn=admin,${LDAP_USERS_DN}

dn: cn=mailu-users,${LDAP_GROUPS_DN}
objectClass: groupOfNames
cn: mailu-users
description: Mailu users group
member: cn=admin,${LDAP_USERS_DN}

dn: cn=mailu,ou=services,${LDAP_BASE_DN}
objectClass: inetOrgPerson
cn: mailu
sn: service
uid: mailu
mail: mailu@${LDAP_DOMAIN}
userPassword: ${MAILU_LDAP_BIND_PASSWORD}
description: Service account for Mailu integration
EOF"

  # Apply the LDAP structure
  docker exec "${LDAP_CONTAINER}" ldapadd -x -D "cn=admin,${LDAP_BASE_DN}" -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/structure.ldif || {
    echo "⚠️  WARNING: LDAP structure creation failed (may already exist)"
  }
  
  echo "✔️ LDAP server initialized successfully"
fi

# ── Postgres: only create/start if not already running ────────
echo "=== Setting up PostgreSQL ==="
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
  
  echo "Waiting for PostgreSQL to initialize..."
  sleep 10
  
  # Test database connectivity
  until docker exec "${PG_CONTAINER}" pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"; do
    echo "  - Waiting for PostgreSQL to be ready..."
    sleep 2
  done
  echo "✔️ PostgreSQL is ready"
fi

# ── Keycloak: always remove & re-deploy ───────────────────────
echo "=== Setting up Keycloak ==="
if docker ps -a --format '{{.Names}}' | grep -qx "${KC_CONTAINER}"; then
  echo "Removing existing Keycloak container '${KC_CONTAINER}'…"
  docker rm -f "${KC_CONTAINER}"
fi

# Wait for dependencies to be ready
echo "Ensuring dependencies are ready..."
sleep 5

echo "Starting Keycloak with LDAP integration support..."
docker run -d \
  --name "${KC_CONTAINER}" \
  --network "${NETWORK}" \
  --restart unless-stopped \
  -v "${KC_VOLUME}":/opt/keycloak/data \
  -e KC_BOOTSTRAP_ADMIN_USERNAME="${KEYCLOAK_ADMIN}" \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD}" \
  -e KC_DB="postgres" \
  -e KC_DB_URL_HOST="${PG_CONTAINER}" \
  -e KC_DB_URL_DATABASE="${POSTGRES_DB}" \
  -e KC_DB_USERNAME="${POSTGRES_USER}" \
  -e KC_DB_PASSWORD="${POSTGRES_PASSWORD}" \
  --label "traefik.enable=true" \
  --label "traefik.docker.network=${NETWORK}" \
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
    --hostname="${PUBLIC_HOSTNAME}" \
    --proxy-headers=xforwarded \
    --http-enabled=true

# Wait for Keycloak to be ready
echo "Waiting for Keycloak to initialize..."
timeout=120
counter=0
until curl -s -f "http://localhost:8080/health/ready" -o /dev/null 2>/dev/null || \
      docker exec "${KC_CONTAINER}" curl -s -f "http://localhost:8080/health/ready" -o /dev/null 2>/dev/null; do
    if [[ $counter -ge $timeout ]]; then
        echo "❌ ERROR: Keycloak failed to start within $timeout seconds"
        echo "Keycloak logs:"
        docker logs "${KC_CONTAINER}" --tail 20
        exit 1
    fi
    echo "  - Waiting for Keycloak to be ready... ($counter/$timeout)"
    sleep 2
    ((counter++))
done
echo "✔️ Keycloak is ready"
docker run -d \
  --name "${KC_CONTAINER}" \
  --network "${NETWORK}" \
  --restart unless-stopped \
  -v "${KC_VOLUME}":/opt/keycloak/data \
  -e KC_BOOTSTRAP_ADMIN_USERNAME="${KEYCLOAK_ADMIN}" \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD}" \
  -e KC_DB="postgres" \
  -e KC_DB_URL_HOST="${PG_CONTAINER}" \
  -e KC_DB_URL_DATABASE="${POSTGRES_DB}" \
  -e KC_DB_USERNAME="${POSTGRES_USER}" \
  -e KC_DB_PASSWORD="${POSTGRES_PASSWORD}" \
  --label "traefik.enable=true" \
  --label "traefik.docker.network=${NETWORK}" \
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
    --hostname="${PUBLIC_HOSTNAME}" \
    --proxy-headers=xforwarded \
    --http-enabled=true

echo
echo "🎉 Keycloak with LDAP support is ready!"
echo ""
echo "📍 Access Points:"
echo "   • Keycloak Admin: https://${PUBLIC_HOSTNAME}/admin/"
echo "   • Internal Access: http://${INTERNAL_HOSTNAME}/admin/"
echo ""
echo "🔐 Admin Credentials:"
echo "   • Username: ${KEYCLOAK_ADMIN}"
echo "   • Password: ${KEYCLOAK_ADMIN_PASSWORD}"
echo ""
echo "🗂️  LDAP Configuration:"
echo "   • LDAP Server: ${LDAP_CONTAINER}:389"
echo "   • Base DN: ${LDAP_BASE_DN}"
echo "   • Admin DN: cn=admin,${LDAP_BASE_DN}"
echo "   • Users DN: ${LDAP_USERS_DN}"
echo "   • Groups DN: ${LDAP_GROUPS_DN}"
echo ""
echo "📋 Next Steps for Mailu Integration:"
echo "   1. Configure LDAP User Federation in Keycloak Admin Console"
echo "   2. Update Mailu environment with LDAP settings"
echo "   3. Test user creation and authentication flow"
echo ""
echo "🔧 Ready-to-use LDAP settings for Keycloak User Federation:"
echo "   • Connection URL: ldap://${LDAP_CONTAINER}:389"
echo "   • Bind DN: cn=admin,${LDAP_BASE_DN}"
echo "   • Bind Credential: ${LDAP_ADMIN_PASSWORD}"
echo "   • Users DN: ${LDAP_USERS_DN}"
echo "   • Username LDAP Attribute: uid"
echo "   • RDN LDAP Attribute: uid"
echo "   • UUID LDAP Attribute: entryUUID"
echo "   • User Object Classes: inetOrgPerson,organizationalPerson"
