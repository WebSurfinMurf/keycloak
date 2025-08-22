# Claude AI Assistant Notes - Keycloak

> **For overall environment context, see: `/home/administrator/projects/AINotes/AINotes.md`**

## Project Overview
Keycloak provides centralized identity and access management for all services:
- Single Sign-On (SSO) for all applications
- OIDC/OAuth2 authentication provider
- User management and federation
- Multi-realm support for different security contexts

## Recent Work & Changes
_This section is updated by Claude during each session_

### Session: 2025-08-22
- **MIGRATION COMPLETE**: Moved from websurfinmurf to administrator ownership
- Fixed network configuration for proper database connectivity
- Updated deploy.sh to handle dual-network requirements:
  - Starts on `postgres-net` first (for database access)
  - Then connects to `traefik-proxy` (for web access)
- All paths updated to use administrator's directory structure
- Successfully tested and verified working

### Important Network Configuration
- **Keycloak container**: Must be on BOTH networks
  - `postgres-net`: To reach keycloak-postgres database
  - `traefik-proxy`: For web access via Traefik
- **keycloak-postgres**: Only on `postgres-net`

## Network Architecture
- **Primary Network**: `postgres-net` (started on this for DB access)
- **Secondary Network**: `traefik-proxy` (connected after start for web access)
- **Database**: `keycloak-postgres` on `postgres-net` only

## Important Files & Paths
- **Deploy Script**: `/home/administrator/projects/keycloak/deploy.sh`
- **Secrets**: `/home/administrator/projects/secrets/keycloak.env`
- **Data Volume**: `keycloak_data` (Docker volume)
- **Database Volume**: `keycloak_pg_data` (Docker volume)
- **Certs Volume**: `keycloak_data_certs` (self-signed for internal HTTPS)

## Access Points
- **External HTTPS**: https://keycloak.ai-servicers.com/admin/ (via Traefik)
- **Internal HTTPS**: https://keycloak.linuxserver.lan:8443/admin/ (direct)
- **Admin Console**: Both URLs lead to admin console

## Credentials
- **Admin Username**: admin
- **Admin Password**: SecureAdminPass2024!
- **Database Name**: keycloak
- **Database User**: keycloak
- **Database Password**: SecureDbPass2024!

## Database Management
- **Container**: keycloak-postgres
- **Network**: postgres-net only
- **Accessible via pgAdmin**: Yes (host: keycloak-postgres)
- **PostgreSQL Version**: 15

## Known Issues & TODOs
- Deprecated feature warning: hostname:v1 (works fine, just deprecated)
- No LDAP integration (using local users only)

## Important Notes
- **Owner**: administrator (UID 2000)
- **File ownership**: administrator:administrators
- **Dual HTTPS Support**: Both external (Traefik) and internal (direct) access
- **Network Order Matters**: Must start on postgres-net first

## Common Commands
```bash
# Deploy/restart Keycloak
cd /home/administrator/projects/keycloak
./deploy.sh

# Check Keycloak logs
docker logs keycloak --tail 50

# Check database connectivity
docker exec keycloak ping -c 1 keycloak-postgres

# Verify network configuration
docker inspect keycloak --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}} {{end}}'
# Should show: postgres-net traefik-proxy

# Access database via PostgreSQL client
psql -h localhost -p 5432 -U keycloak -d keycloak
# Password: SecureDbPass2024!
```

## Troubleshooting
1. **Database connection failed**: Ensure Keycloak is on postgres-net
2. **Not accessible via browser**: Ensure Keycloak is on traefik-proxy
3. **Both issues**: Check that deploy.sh creates container on postgres-net first

## OIDC Configuration for Applications
- **Issuer**: https://keycloak.ai-servicers.com/realms/master
- **Discovery URL**: https://keycloak.ai-servicers.com/realms/master/.well-known/openid-configuration
- **Authorization Endpoint**: https://keycloak.ai-servicers.com/realms/master/protocol/openid-connect/auth
- **Token Endpoint**: https://keycloak.ai-servicers.com/realms/master/protocol/openid-connect/token

## Backup Considerations
- **Database**: keycloak-postgres container data
- **Keycloak Data**: Docker volume keycloak_data
- **Realms**: Export via admin console or API

---
*Last Updated: 2025-08-22 by Claude*