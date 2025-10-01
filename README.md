# Keycloak Identity Provider

**Version**: 25.0.6
**Status**: ✅ PRODUCTION
**Network**: traefik-net, keycloak-net, postgres-net
**Domain**: keycloak.ai-servicers.com

## Overview

Keycloak provides centralized identity and access management for all services:
- Single Sign-On (SSO) for all applications
- OIDC/OAuth2 authentication provider
- User management and authentication
- OAuth2 proxy integration
- Multi-realm support

## Quick Start

```bash
# Deploy Keycloak
cd /home/administrator/projects/keycloak
./deploy.sh

# View logs
docker logs keycloak -f
docker logs keycloak-postgres -f

# Check health
curl -s https://keycloak.ai-servicers.com/realms/master/.well-known/openid-configuration | jq
```

## Architecture

### Services
- **keycloak**: Main identity provider (Keycloak 25.0.6)
- **keycloak-postgres**: PostgreSQL database (PostgreSQL 15)

### Networks
- **traefik-net**: Web access via Traefik
- **keycloak-net**: OAuth2 proxy services integration
- **postgres-net**: Database access

### Dual HTTPS Support
- **External HTTPS**: https://keycloak.ai-servicers.com (via Traefik with Let's Encrypt)
- **Internal HTTPS**: https://keycloak.linuxserver.lan:8443 (direct with self-signed cert)

## Configuration Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Service definitions for both Keycloak and PostgreSQL |
| `deploy.sh` | Deployment script with validation and health checks |
| `setup-client.sh` | Helper script to create new OAuth2 clients |
| `backup.sh` | Database backup script |

## Secrets

**Location**: `/home/administrator/secrets/keycloak.env`

**Required Variables**:
```bash
# Admin credentials
KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=<secure-password>

# Database configuration
POSTGRES_DB=keycloak
POSTGRES_USER=keycloak
POSTGRES_PASSWORD=<secure-password>

# Hostnames
PUBLIC_HOSTNAME=keycloak.ai-servicers.com
INTERNAL_HOSTNAME=keycloak.linuxserver.lan

# Docker configuration
NETWORK=traefik-net
PG_CONTAINER=keycloak-postgres
KC_CONTAINER=keycloak
PG_IMAGE=postgres:15
KC_IMAGE=quay.io/keycloak/keycloak:25.0
PG_VOLUME=keycloak_pg_data
KC_VOLUME=keycloak_data
```

## Access Points

- **Admin Console (External)**: https://keycloak.ai-servicers.com/admin/
- **Admin Console (Internal)**: https://keycloak.linuxserver.lan:8443/admin/
- **Master Realm**: https://keycloak.ai-servicers.com/realms/master

## OIDC Configuration

For integrating applications with Keycloak:

**Discovery URL**:
```
https://keycloak.ai-servicers.com/realms/master/.well-known/openid-configuration
```

**Endpoints**:
- **Issuer**: https://keycloak.ai-servicers.com/realms/master
- **Authorization**: https://keycloak.ai-servicers.com/realms/master/protocol/openid-connect/auth
- **Token**: https://keycloak.ai-servicers.com/realms/master/protocol/openid-connect/token
- **UserInfo**: https://keycloak.ai-servicers.com/realms/master/protocol/openid-connect/userinfo

## OAuth2 Proxy Integration

Keycloak is used by OAuth2 proxies throughout the infrastructure. Example configuration:

```bash
--provider=keycloak-oidc
--client-id=<your-client-id>
--client-secret=<your-client-secret>
--oidc-issuer-url=https://keycloak.ai-servicers.com/realms/master
--redirect-url=https://yourapp.ai-servicers.com/oauth2/callback
--email-domain=*
--cookie-secret=<random-32-byte-base64>
```

## Creating OAuth2 Clients

Use the helper script to create new OAuth2 clients:

```bash
cd /home/administrator/projects/keycloak
./setup-client.sh <client-name> <redirect-url>

# Example:
./setup-client.sh grafana https://grafana.ai-servicers.com/oauth2/callback
```

## User Management

### Creating Users

1. Access admin console: https://keycloak.ai-servicers.com/admin/
2. Login with admin credentials
3. Navigate to: Master Realm → Users → Add User
4. Fill in user details
5. Set credentials in Credentials tab

### User Groups

Common groups used for authorization:
- **administrators**: Full access to all services
- **users**: Standard user access
- **developers**: Development environment access

## Database Management

### Accessing the Database

```bash
# Via docker exec
docker exec -it keycloak-postgres psql -U keycloak -d keycloak

# Via pgAdmin
# Host: keycloak-postgres
# Port: 5432
# Database: keycloak
# Username: keycloak
# Password: <from secrets/keycloak.env>
```

### Backup Database

```bash
cd /home/administrator/projects/keycloak
./backup.sh
```

## Monitoring

### Health Checks

```bash
# Check if Keycloak is responding
curl -s https://keycloak.ai-servicers.com/realms/master/.well-known/openid-configuration | jq '.issuer'

# Check database health
docker exec keycloak-postgres pg_isready -U keycloak -d keycloak

# Check container status
docker ps --filter "name=keycloak"
```

### View Logs

```bash
# Keycloak logs
docker logs keycloak -f

# PostgreSQL logs
docker logs keycloak-postgres -f

# Search for errors
docker logs keycloak 2>&1 | grep -i error
```

## Troubleshooting

### Keycloak Not Accessible

1. **Check container is running**:
   ```bash
   docker ps | grep keycloak
   ```

2. **Check logs for errors**:
   ```bash
   docker logs keycloak --tail 50
   ```

3. **Verify networks**:
   ```bash
   docker inspect keycloak | grep -A5 Networks
   # Should show: traefik-net, keycloak-net, postgres-net
   ```

4. **Test database connectivity**:
   ```bash
   docker exec keycloak-postgres pg_isready -U keycloak -d keycloak
   ```

### OAuth2 Integration Issues

1. **Check client configuration** in Keycloak admin console
2. **Verify redirect URLs** match exactly
3. **Check client secret** is correct
4. **Verify issuer URL** is accessible from OAuth2 proxy

### Certificate Issues

**Internal HTTPS (8443)**:
- Uses self-signed certificate
- Located in `keycloak-certs` volume
- Automatically generated by deploy script

**External HTTPS (443)**:
- Uses Let's Encrypt via Traefik
- Managed by Traefik reverse proxy

## Deployment

### Standard Deployment

```bash
cd /home/administrator/projects/keycloak
./deploy.sh
```

### Manual Deployment

```bash
cd /home/administrator/projects/keycloak
docker compose up -d
```

### Rollback

```bash
cd /home/administrator/projects/keycloak
docker compose down
# Restore from backup if needed
docker compose up -d
```

## Backup

### Critical Data
- PostgreSQL database (`keycloak_pg_data` volume)
- Keycloak configuration (`keycloak_data` volume)
- Environment variables (`/home/administrator/secrets/keycloak.env`)

### Backup Command

```bash
# Backup database
docker exec keycloak-postgres pg_dump -U keycloak keycloak > keycloak-backup-$(date +%Y%m%d).sql

# Backup volumes
docker run --rm \
  -v keycloak_pg_data:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/keycloak-volumes-$(date +%Y%m%d).tar.gz /data
```

## Security

- All external access via HTTPS with Let's Encrypt
- Internal communication via self-signed certificates
- Database isolated on postgres-net
- OAuth2 proxy services on dedicated keycloak-net
- Admin console requires authentication
- Password complexity enforced
- Session management with secure cookies

## Performance

- PostgreSQL with connection pooling
- Infinispan caching enabled
- JGroups clustering support (single node)
- Health checks configured
- Resource limits defined

## Related Documentation

- Network Standards: `/home/administrator/projects/AINotes/network.md`
- Network Topology: `/home/administrator/projects/AINotes/network-detail.md`
- Project Details: `/home/administrator/projects/keycloak/CLAUDE.md`

## Common Tasks

### Reset Admin Password

```bash
docker exec keycloak /opt/keycloak/bin/kc.sh user-password \
  -u admin \
  -p <new-password> \
  --realm master
```

### Export Realm Configuration

```bash
docker exec keycloak /opt/keycloak/bin/kc.sh export \
  --file /opt/keycloak/data/export.json \
  --realm master
```

### Import Realm Configuration

```bash
docker exec keycloak /opt/keycloak/bin/kc.sh import \
  --file /opt/keycloak/data/import.json
```

---

**Last Updated**: 2025-09-30
**Standardized**: Phase 1 - Deployment Standardization
**Status**: ✅ Production Ready
