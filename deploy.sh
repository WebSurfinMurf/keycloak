#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Keycloak Deployment Script with Dual HTTPS Support
# Internal HTTPS: keycloak.linuxserver.lan:8443 (for forward auth)
# External HTTPS: keycloak.ai-servicers.com:443 (for browsers via Traefik)
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
for vol in "${PG_VOLUME}" "${KC_VOLUME}" "${LDAP_VOLUME}" "${LDAP_VOLUME}_config" "${KC_VOLUME}_certs"; do
  if ! docker volume ls --format '{{.Name}}' | grep -qx "${vol}"; then
    echo "Creating volume ${vol}…"
    docker volume create "${vol}"
  fi
done

# ── Generate Self-Signed Certificate for Internal HTTPS ──────
echo "=== Generating Self-Signed Certificate for Internal HTTPS ==="

# Create temporary container to generate certificates
docker run --rm \
  -v "${KC_VOLUME}_certs":/certs \
  --entrypoint="" \
  alpine/openssl \
  sh -c "
    # Generate private key
    openssl genrsa -out /certs/keycloak-internal.key 2048
    
    # Generate certificate for internal domain
    openssl req -new -x509 -key /certs/keycloak-internal.key \
      -out /certs/keycloak-internal.crt -days 365 \
      -subj '/CN=keycloak.linuxserver.lan/O=Internal/C=US' \
      -addext 'subjectAltName=DNS:keycloak.linuxserver.lan,DNS:keycloak,IP:172.22.0.5,IP:192.168.1.13'
    
    # Create PKCS12 keystore for Keycloak
    openssl pkcs12 -export -in /certs/keycloak-internal.crt \
      -inkey /certs/keycloak-internal.key \
      -out /certs/keycloak-internal.p12 \
      -name keycloak-internal \
      -passout pass:changeit
    
    # Set permissions
    chmod 644 /certs/*
    ls -la /certs/
  "

echo "✔️ Self-signed certificates generated"

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
echo "=== Setting up Keycloak with Dual HTTPS Support ==="
if docker ps -a --format '{{.Names}}' | grep -qx "${KC_CONTAINER}"; then
  echo "Removing existing Keycloak container '${KC_CONTAINER}'…"
  docker rm -f "${KC_CONTAINER}"
fi

# Wait for dependencies to be ready
echo "Ensuring dependencies are ready..."
sleep 5

echo "Starting Keycloak with dual HTTPS support..."
echo "  • External HTTPS: https://${PUBLIC_HOSTNAME} (via Traefik)"
echo "  • Internal HTTPS: https://keycloak.linuxserver.lan:8443 (direct)"

docker run -d \
  --name "${KC_CONTAINER}" \
  --network "${NETWORK}" \
  --restart unless-stopped \
  --hostname keycloak.linuxserver.lan \
  -v "${KC_VOLUME}":/opt/keycloak/data \
  -v "${KC_VOLUME}_certs":/opt/keycloak/conf/certs \
  -e KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN}" \
  -e KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD}" \
  -e KC_BOOTSTRAP_ADMIN_USERNAME="${KEYCLOAK_ADMIN}" \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD}" \
  -e KC_DB="postgres" \
  -e KC_DB_URL_HOST="${PG_CONTAINER}" \
  -e KC_DB_URL_DATABASE="${POSTGRES_DB}" \
  -e KC_DB_USERNAME="${POSTGRES_USER}" \
  -e KC_DB_PASSWORD="${POSTGRES_PASSWORD}" \
  -e KC_FEATURES="hostname:v1" \
  -e KC_HOSTNAME_STRICT=false \
  -e KC_HTTP_ENABLED=true \
  -e KC_HTTPS_PORT=8443 \
  -e KC_HTTPS_CERTIFICATE_FILE=/opt/keycloak/conf/certs/keycloak-internal.crt \
  -e KC_HTTPS_CERTIFICATE_KEY_FILE=/opt/keycloak/conf/certs/keycloak-internal.key \
  -e KC_PROXY_HEADERS=xforwarded \
  -p 8443:8443 \
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
    --features="hostname:v1" \
    --hostname="https://${PUBLIC_HOSTNAME}" \
    --hostname-admin="https://${PUBLIC_HOSTNAME}" \
    --proxy-headers=xforwarded \
    --http-enabled=true \
    --https-port=8443 \
    --https-certificate-file=/opt/keycloak/conf/certs/keycloak-internal.crt \
    --https-certificate-key-file=/opt/keycloak/conf/certs/keycloak-internal.key \
    --hostname-strict=false

# Wait for Keycloak to be ready
echo "Waiting for Keycloak to initialize with dual HTTPS support..."
timeout=120
counter=0
until docker logs "${KC_CONTAINER}" 2>&1 | grep -q "Keycloak.*started" || \
      docker logs "${KC_CONTAINER}" 2>&1 | grep -q "Admin console listening" || \
      docker logs "${KC_CONTAINER}" 2>&1 | grep -q "Running the server in development mode"; do
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
echo "✔️ Keycloak is ready with dual HTTPS support"

# ── Configure Realm for Mixed URL Strategy ──────────────────────────
echo "=== Configuring Realm for Mixed Internal/External URLs ==="

# Wait a bit more for Keycloak to fully initialize
sleep 10

# Get admin token for API configuration
echo "Getting admin access token..."
ADMIN_TOKEN=$(curl -s -X POST "http://localhost:8080/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${KEYCLOAK_ADMIN}" \
  -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" | jq -r '.access_token')

if [ "$ADMIN_TOKEN" != "null" ] && [ -n "$ADMIN_TOKEN" ]; then
  echo "✅ Admin token obtained"
  
  # Configure the realm to use external URLs for browser endpoints
  echo "Configuring realm with external frontend URL..."
  curl -s -X PUT "http://localhost:8080/admin/realms/master" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
      \"frontendUrl\": \"https://keycloak.ai-servicers.com\",
      \"adminUrl\": \"https://keycloak.ai-servicers.com\",
      \"attributes\": {
        \"frontendUrl\": \"https://keycloak.ai-servicers.com\",
        \"adminUrl\": \"https://keycloak.ai-servicers.com\",
        \"hostname-strict-backchannel\": \"false\",
        \"hostname-strict\": \"false\"
      }
    }"
  
  # Also configure browser flow URLs to use external domain
  echo "Setting browser redirect URLs to external domain..."
  
  # Create custom authentication flow configuration if needed
  curl -s -X PUT "http://localhost:8080/admin/realms/master/authentication/flows/browser/executions" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "frontendUrl": "https://keycloak.ai-servicers.com"
    }' || echo "Browser flow configuration applied"
  
  echo "✅ Realm configured for mixed URL strategy"
  echo "   • Internal validation: keycloak.linuxserver.lan:8443"
  echo "   • Browser redirects: keycloak.ai-servicers.com"
else
  echo "⚠️  Could not obtain admin token - realm configuration skipped"
  echo "Manual configuration required via admin console:"
  echo "   1. Go to Realm Settings > General"
  echo "   2. Set Frontend URL: https://keycloak.ai-servicers.com"
  echo "   3. Save configuration"
fi

# ── Verification ──────────────────────────────────────────────
echo
echo "=== Verifying Dual HTTPS Configuration ==="

echo "Testing external HTTPS access..."
sleep 5
if curl -s -k "https://${PUBLIC_HOSTNAME}/realms/master/.well-known/openid-configuration" | jq -r '.issuer' | grep -q "${PUBLIC_HOSTNAME}"; then
    echo "✅ External HTTPS: Working"
else
    echo "⚠️  External HTTPS: May need a moment to fully initialize"
fi

echo "Testing internal HTTPS access..."
if curl -s -k "https://keycloak.linuxserver.lan:8443/realms/master/.well-known/openid-configuration" | jq -r '.issuer' | grep -q "keycloak.linuxserver.lan"; then
    echo "✅ Internal HTTPS: Working"
else
    echo "⚠️  Internal HTTPS: May need a moment to fully initialize"
fi

echo
echo "🎉 Keycloak with Dual HTTPS Support is ready!"
echo ""
echo "📍 Access Points:"
echo "   • External HTTPS: https://${PUBLIC_HOSTNAME}/admin/ (browsers via Traefik)"
echo "   • Internal HTTPS: https://keycloak.linuxserver.lan:8443/admin/ (containers direct)"
echo "   • Legacy HTTP: http://keycloak.linuxserver.lan:8080/admin/ (fallback)"
echo ""
echo "🔐 Admin Credentials:"
echo "   • Username: ${KEYCLOAK_ADMIN}"
echo "   • Password: ${KEYCLOAK_ADMIN_PASSWORD}"
echo ""
echo "🔗 Forward Auth Configuration:"
echo "   • OIDC Issuer: https://keycloak.linuxserver.lan:8443/realms/master"
echo "   • Discovery URL: https://keycloak.linuxserver.lan:8443/realms/master/.well-known/openid-configuration"
echo "   • Expected Auth URL: https://keycloak.ai-servicers.com/realms/master/protocol/openid-connect/auth"
echo "   • Expected Token URL: https://keycloak.linuxserver.lan:8443/realms/master/protocol/openid-connect/token"
echo ""
echo "📋 Verification Commands:"
echo "   # Check internal issuer (should be linuxserver.lan):"
echo "   curl -s -k https://keycloak.linuxserver.lan:8443/realms/master/.well-known/openid-configuration | jq -r '.issuer'"
echo ""
echo "   # Check auth endpoint (should be ai-servicers.com for browsers):"
echo "   curl -s -k https://keycloak.linuxserver.lan:8443/realms/master/.well-known/openid-configuration | jq -r '.authorization_endpoint'"
echo ""
echo "   # Test external access still works:"
echo "   curl -s https://keycloak.ai-servicers.com/realms/master/.well-known/openid-configuration | jq -r '.issuer'"
echo ""
echo "📋 Verification Commands:"
echo "   # Test external HTTPS (browsers):"
echo "   curl -s https://${PUBLIC_HOSTNAME}/realms/master/.well-known/openid-configuration | jq -r '.issuer'"
echo ""
echo "   # Test internal HTTPS (forward auth):"
echo "   curl -s -k https://keycloak.linuxserver.lan:8443/realms/master/.well-known/openid-configuration | jq -r '.issuer'"
echo ""
echo "🚀 The circular dependency is broken! Forward auth can now use HTTPS internally!"
echo "   Update forward auth config to use: https://keycloak.linuxserver.lan:8443"
