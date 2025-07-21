#!/usr/bin/env bash

# ======================================================================
# Keycloak Client Setup for Mailu Integration
# ======================================================================

set -euo pipefail

# Load environment variables
source "$(dirname "$0")/../secrets/keycloak.env"

# Configuration
KEYCLOAK_URL="https://keycloak.ai-servicers.com"
REALM="master"
CLIENT_ID="mailu-client"
CLIENT_SECRET=$(openssl rand -hex 32)
FORWARD_AUTH_SECRET=$(openssl rand -hex 16)

echo "=== Setting up Keycloak OIDC Client for Mailu ==="

# Check if Keycloak is accessible
if ! curl -f -s "${KEYCLOAK_URL}/health" >/dev/null 2>&1; then
    echo "❌ ERROR: Keycloak is not accessible at ${KEYCLOAK_URL}"
    echo "   Please ensure Keycloak is running and accessible"
    exit 1
fi

# Get admin access token
echo "Getting admin access token..."
TOKEN_RESPONSE=$(curl -s \
  -d "client_id=admin-cli" \
  -d "username=${KEYCLOAK_ADMIN}" \
  -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
  -d "grant_type=password" \
  "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token")

if ! echo "$TOKEN_RESPONSE" | jq -e '.access_token' >/dev/null 2>&1; then
    echo "❌ ERROR: Failed to get admin access token"
    echo "Response: $TOKEN_RESPONSE"
    exit 1
fi

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')
echo "✔️ Admin access token obtained"

# Check if client already exists
echo "Checking if client already exists..."
EXISTING_CLIENT=$(curl -s \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}")

if echo "$EXISTING_CLIENT" | jq -e '.[0].id' >/dev/null 2>&1; then
    echo "⚠️  Client '${CLIENT_ID}' already exists, updating configuration..."
    CLIENT_UUID=$(echo "$EXISTING_CLIENT" | jq -r '.[0].id')
    UPDATE_MODE=true
else
    echo "Creating new client '${CLIENT_ID}'..."
    UPDATE_MODE=false
fi

# Create client configuration
CLIENT_CONFIG=$(cat <<EOF
{
  "clientId": "${CLIENT_ID}",
  "name": "Mailu Email Server",
  "description": "OAuth2/OIDC client for Mailu email server authentication",
  "enabled": true,
  "clientAuthenticatorType": "client-secret",
  "secret": "${CLIENT_SECRET}",
  "redirectUris": [
    "https://auth.ai-servicers.com/_oauth",
    "https://mailu.ai-servicers.com/_oauth",
    "https://mailu.ai-servicers.com/admin/*",
    "https://mailu.ai-servicers.com/webmail/*"
  ],
  "webOrigins": [
    "https://mailu.ai-servicers.com",
    "https://auth.ai-servicers.com"
  ],
  "protocol": "openid-connect",
  "publicClient": false,
  "bearerOnly": false,
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": true,
  "serviceAccountsEnabled": false,
  "fullScopeAllowed": true,
  "attributes": {
    "access.token.lifespan": "3600",
    "client.session.idle.timeout": "1800",
    "client.session.max.lifespan": "86400"
  },
  "defaultClientScopes": [
    "web-origins",
    "role_list",
    "profile",
    "roles",
    "email"
  ],
  "optionalClientScopes": [
    "address",
    "phone",
    "offline_access",
    "microprofile-jwt"
  ]
}
EOF
)

if [ "$UPDATE_MODE" = true ]; then
    # Update existing client
    UPDATE_RESPONSE=$(curl -s -w "%{http_code}" \
      -X PUT \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$CLIENT_CONFIG" \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}")
    
    HTTP_CODE="${UPDATE_RESPONSE: -3}"
    if [ "$HTTP_CODE" = "204" ]; then
        echo "✔️ Client updated successfully"
    else
        echo "❌ ERROR: Failed to update client (HTTP $HTTP_CODE)"
        exit 1
    fi
else
    # Create new client
    CREATE_RESPONSE=$(curl -s -w "%{http_code}" \
      -X POST \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$CLIENT_CONFIG" \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/clients")
    
    HTTP_CODE="${CREATE_RESPONSE: -3}"
    if [ "$HTTP_CODE" = "201" ]; then
        echo "✔️ Client created successfully"
    else
        echo "❌ ERROR: Failed to create client (HTTP $HTTP_CODE)"
        echo "Response: ${CREATE_RESPONSE%???}"
        exit 1
    fi
fi

# Create user if it doesn't exist
echo "=== Setting up test user ==="
USER_EMAIL="websurfinmurf@ai-servicers.com"
USER_USERNAME="websurfinmurf"
USER_PASSWORD="Qwert-0987lr"

# Check if user exists
EXISTING_USER=$(curl -s \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=${USER_USERNAME}")

if echo "$EXISTING_USER" | jq -e '.[0].id' >/dev/null 2>&1; then
    echo "✔️ User '${USER_USERNAME}' already exists"
    USER_UUID=$(echo "$EXISTING_USER" | jq -r '.[0].id')
else
    echo "Creating user '${USER_USERNAME}'..."
    
    USER_CONFIG=$(cat <<EOF
{
  "username": "${USER_USERNAME}",
  "email": "${USER_EMAIL}",
  "firstName": "Web",
  "lastName": "Surfin Murf",
  "enabled": true,
  "emailVerified": true,
  "credentials": [{
    "type": "password",
    "value": "${USER_PASSWORD}",
    "temporary": false
  }]
}
EOF
    )
    
    CREATE_USER_RESPONSE=$(curl -s -w "%{http_code}" \
      -X POST \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$USER_CONFIG" \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/users")
    
    HTTP_CODE="${CREATE_USER_RESPONSE: -3}"
    if [ "$HTTP_CODE" = "201" ]; then
        echo "✔️ User created successfully"
    else
        echo "❌ ERROR: Failed to create user (HTTP $HTTP_CODE)"
        echo "Response: ${CREATE_USER_RESPONSE%???}"
    fi
fi

# Save configuration for forward auth
echo "=== Generating forward auth configuration ==="

# Create forward auth environment file
FORWARD_AUTH_ENV_FILE="$(dirname "$0")/../secrets/forward-auth.env"
cat > "$FORWARD_AUTH_ENV_FILE" <<EOF
# Forward Auth Configuration for Mailu-Keycloak Integration
# Generated on $(date)

# OAuth2 Configuration
PROVIDERS_OIDC_ISSUER_URL=https://keycloak.ai-servicers.com/realms/master
PROVIDERS_OIDC_CLIENT_ID=${CLIENT_ID}
PROVIDERS_OIDC_CLIENT_SECRET=${CLIENT_SECRET}

# Forward Auth Settings
SECRET=${FORWARD_AUTH_SECRET}
AUTH_HOST=auth.ai-servicers.com
COOKIE_DOMAIN=ai-servicers.com

# Headers for Mailu
HEADERS_USERNAME=X-Auth-Email
HEADERS_GROUPS=X-Auth-Groups
HEADERS_NAME=X-Auth-Name

# URLs
URL_PATH=/_oauth
LOGOUT_REDIRECT=https://keycloak.ai-servicers.com/realms/master/protocol/openid-connect/logout

# Session Settings
LIFETIME=86400
LOG_LEVEL=info
EOF

echo "✔️ Forward auth configuration saved to: $FORWARD_AUTH_ENV_FILE"

# Update the docker-compose file with correct secrets
COMPOSE_FILE="$(dirname "$0")/keycloak-auth-middleware.yml"
if [ -f "$COMPOSE_FILE" ]; then
    echo "=== Updating docker-compose file with secrets ==="
    
    # Create a temporary file with the correct values
    sed \
      -e "s/your-client-secret-here/${CLIENT_SECRET}/g" \
      -e "s/your-random-secret-32-chars-here/${FORWARD_AUTH_SECRET}/g" \
      "$COMPOSE_FILE" > "${COMPOSE_FILE}.tmp"
    
    mv "${COMPOSE_FILE}.tmp" "$COMPOSE_FILE"
    echo "✔️ Docker-compose file updated with secrets"
fi

echo ""
echo "🎉 Keycloak setup completed successfully!"
echo ""
echo "📋 Configuration Summary:"
echo "   • Client ID: ${CLIENT_ID}"
echo "   • Client Secret: ${CLIENT_SECRET}"
echo "   • Forward Auth Secret: ${FORWARD_AUTH_SECRET}"
echo ""
echo "👤 Test User:"
echo "   • Username: ${USER_USERNAME}"
echo "   • Email: ${USER_EMAIL}"
echo "   • Password: ${USER_PASSWORD}"
echo ""
echo "🔗 OIDC Endpoints:"
echo "   • Issuer: https://keycloak.ai-servicers.com/realms/master"
echo "   • Auth URL: https://keycloak.ai-servicers.com/realms/master/protocol/openid-connect/auth"
echo "   • Token URL: https://keycloak.ai-servicers.com/realms/master/protocol/openid-connect/token"
echo "   • Userinfo URL: https://keycloak.ai-servicers.com/realms/master/protocol/openid-connect/userinfo"
echo ""
echo "🚀 Next Steps:"
echo "   1. Deploy forward auth service:"
echo "      docker-compose -f keycloak-auth-middleware.yml up -d"
echo ""
echo "   2. Test the authentication flow:"
echo "      curl -I https://mailu.ai-servicers.com/admin"
echo ""
echo "   3. Access Mailu admin interface:"
echo "      https://mailu.ai-servicers.com/admin"
echo "      (Should redirect to Keycloak for authentication)"
echo ""
echo "   4. Monitor logs:"
echo "      docker logs keycloak-forward-auth -f"
