#!/bin/bash
set -e

echo "🚀 Deploying Keycloak Identity Provider"
echo "========================================="
echo ""

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Environment file
ENV_FILE="$HOME/projects/secrets/keycloak.env"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Pre-deployment Checks ---
echo "🔍 Pre-deployment checks..."

# Check environment file
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Environment file not found: $ENV_FILE${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Environment file exists${NC}"

# Source environment variables
set -o allexport
source "$ENV_FILE"
set +o allexport

# Validate required variables
required_vars=(
    "KEYCLOAK_ADMIN" "KEYCLOAK_ADMIN_PASSWORD"
    "POSTGRES_DB" "POSTGRES_USER" "POSTGRES_PASSWORD"
    "PUBLIC_HOSTNAME"
)

for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo -e "${RED}❌ Required variable $var is not set${NC}"
        exit 1
    fi
done
echo -e "${GREEN}✅ Environment variables validated${NC}"

# Check if networks exist
for network in traefik-net keycloak-net postgres-net; do
    if ! docker network inspect "$network" &>/dev/null; then
        echo -e "${RED}❌ Network $network not found${NC}"
        echo "Run: /home/administrator/projects/infrastructure/setup-networks.sh"
        exit 1
    fi
done
echo -e "${GREEN}✅ Required networks exist${NC}"

# Validate docker-compose.yml syntax
echo ""
echo "✅ Validating docker-compose.yml..."
if ! docker compose config > /dev/null 2>&1; then
    echo -e "${RED}❌ docker-compose.yml validation failed${NC}"
    docker compose config
    exit 1
fi
echo -e "${GREEN}✅ docker-compose.yml is valid${NC}"

# --- Create Docker Volumes ---
echo ""
echo "📦 Checking Docker volumes..."

for volume in keycloak-data keycloak-certs keycloak_pg_data; do
    if ! docker volume inspect "$volume" &>/dev/null; then
        echo "Creating volume: $volume"
        docker volume create "$volume"
    fi
done
echo -e "${GREEN}✅ Docker volumes ready${NC}"

# --- Generate Self-Signed Certificates ---
echo ""
echo "🔐 Checking self-signed certificates..."

# Check if certificates exist
CERT_EXISTS=$(docker run --rm \
    -v keycloak-certs:/certs \
    --entrypoint="" \
    alpine/openssl \
    sh -c "test -f /certs/keycloak-internal.crt && echo 'yes' || echo 'no'")

if [ "$CERT_EXISTS" = "no" ]; then
    echo "Generating self-signed certificates..."
    docker run --rm \
        -v keycloak-certs:/certs \
        --entrypoint="" \
        alpine/openssl \
        sh -c "
            openssl genrsa -out /certs/keycloak-internal.key 2048
            openssl req -new -x509 -key /certs/keycloak-internal.key \
                -out /certs/keycloak-internal.crt -days 365 \
                -subj '/CN=keycloak.linuxserver.lan/O=Internal/C=US' \
                -addext 'subjectAltName=DNS:keycloak.linuxserver.lan,DNS:keycloak,IP:172.22.0.5,IP:192.168.1.13'
            openssl pkcs12 -export -in /certs/keycloak-internal.crt \
                -inkey /certs/keycloak-internal.key \
                -out /certs/keycloak-internal.p12 \
                -name keycloak-internal \
                -passout pass:changeit
            chmod 644 /certs/*
        " >/dev/null 2>&1
    echo -e "${GREEN}✅ Self-signed certificates generated${NC}"
else
    echo -e "${GREEN}✅ Self-signed certificates already exist${NC}"
fi

# --- Deployment ---
echo ""
echo "🚀 Deploying Keycloak services..."
docker compose up -d --remove-orphans

# --- Post-deployment Validation ---
echo ""
echo "⏳ Waiting for PostgreSQL to be ready..."
timeout 60 bash -c 'until docker exec keycloak-postgres pg_isready -U keycloak -d keycloak 2>/dev/null; do sleep 2; done' || {
    echo -e "${RED}❌ PostgreSQL failed to start${NC}"
    docker logs keycloak-postgres --tail 30
    exit 1
}
echo -e "${GREEN}✅ PostgreSQL is ready${NC}"

echo "⏳ Waiting for Keycloak to start..."
sleep 10

# Check if Keycloak is running
if ! docker ps | grep -q "keycloak"; then
    echo -e "${RED}❌ Keycloak container not running${NC}"
    docker logs keycloak --tail 50
    exit 1
fi
echo -e "${GREEN}✅ Keycloak container is running${NC}"

# Wait for Keycloak to be fully initialized
echo "🔍 Checking Keycloak health..."
HEALTH_CHECK_ATTEMPTS=0
MAX_ATTEMPTS=30

while [ $HEALTH_CHECK_ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    if docker logs keycloak 2>&1 | grep -q "Listening on:"; then
        echo -e "${GREEN}✅ Keycloak is healthy${NC}"
        break
    fi
    HEALTH_CHECK_ATTEMPTS=$((HEALTH_CHECK_ATTEMPTS + 1))
    if [ $HEALTH_CHECK_ATTEMPTS -eq $MAX_ATTEMPTS ]; then
        echo -e "${RED}❌ Keycloak health check failed after $MAX_ATTEMPTS attempts${NC}"
        docker logs keycloak --tail 30
        exit 1
    fi
    echo "   Attempt $HEALTH_CHECK_ATTEMPTS/$MAX_ATTEMPTS..."
    sleep 2
done

# Give it a few more seconds to be fully ready
sleep 5

# --- Configure Realm ---
echo ""
echo "⚙️  Configuring realm..."

# Get admin token
ADMIN_TOKEN=$(curl -s -X POST "http://localhost:8080/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=${KEYCLOAK_ADMIN}" \
    -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" 2>/dev/null | jq -r '.access_token' 2>/dev/null)

if [ "$ADMIN_TOKEN" != "null" ] && [ -n "$ADMIN_TOKEN" ]; then
    echo -e "${GREEN}✅ Admin token obtained${NC}"

    # Configure realm with external frontend URL
    curl -s -X PUT "http://localhost:8080/admin/realms/master" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"frontendUrl\": \"https://${PUBLIC_HOSTNAME}\",
            \"adminUrl\": \"https://${PUBLIC_HOSTNAME}\",
            \"attributes\": {
                \"frontendUrl\": \"https://${PUBLIC_HOSTNAME}\",
                \"adminUrl\": \"https://${PUBLIC_HOSTNAME}\",
                \"hostname-strict-backchannel\": \"false\",
                \"hostname-strict\": \"false\"
            }
        }" >/dev/null 2>&1

    echo -e "${GREEN}✅ Realm configured${NC}"
else
    echo -e "${YELLOW}⚠️  Could not obtain admin token - realm configuration skipped${NC}"
fi

# --- Verification ---
echo ""
echo "🔍 Verifying deployment..."

sleep 3

# Test external HTTPS
if curl -s -k "https://${PUBLIC_HOSTNAME}/realms/master/.well-known/openid-configuration" | jq -r '.issuer' | grep -q "${PUBLIC_HOSTNAME}" 2>/dev/null; then
    echo -e "${GREEN}✅ External HTTPS working${NC}"
else
    echo -e "${YELLOW}⚠️  External HTTPS may need a moment to initialize${NC}"
fi

# Test internal HTTPS
if curl -s -k "https://keycloak.linuxserver.lan:8443/realms/master/.well-known/openid-configuration" | jq -r '.issuer' | grep -q "keycloak" 2>/dev/null; then
    echo -e "${GREEN}✅ Internal HTTPS working${NC}"
else
    echo -e "${YELLOW}⚠️  Internal HTTPS may need a moment to initialize${NC}"
fi

# --- Summary ---
echo ""
echo "=========================================="
echo "✅ Keycloak Deployment Summary"
echo "=========================================="
echo "Services:"
echo "  - keycloak (${KC_IMAGE:-quay.io/keycloak/keycloak:25.0})"
echo "  - keycloak-postgres (${PG_IMAGE:-postgres:15})"
echo ""
echo "Networks:"
echo "  - traefik-net (web access)"
echo "  - keycloak-net (auth proxy services)"
echo "  - postgres-net (database access)"
echo ""
echo "Access Points:"
echo "  - External: https://${PUBLIC_HOSTNAME}/admin/"
echo "  - Internal: https://keycloak.linuxserver.lan:8443/admin/"
echo ""
echo "Admin Credentials:"
echo "  - Username: ${KEYCLOAK_ADMIN}"
echo "  - Password: ${KEYCLOAK_ADMIN_PASSWORD}"
echo ""
echo "OIDC Configuration:"
echo "  - Issuer: https://${PUBLIC_HOSTNAME}/realms/master"
echo "  - Discovery: https://${PUBLIC_HOSTNAME}/realms/master/.well-known/openid-configuration"
echo ""
echo "=========================================="
echo ""
echo "📊 View logs:"
echo "   docker logs keycloak -f"
echo "   docker logs keycloak-postgres -f"
echo ""
echo "✅ Deployment complete!"
