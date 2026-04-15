# RHBK + Data Grid OIDC Integration on ROSA/OpenShift

This repository automates the deployment of **Red Hat Build of Keycloak (RHBK)** as an SSO provider for **Red Hat Data Grid 8.x** on a ROSA (or any OpenShift) cluster.

## Overview
Two authentication paths share the same RHBK realm:

- **Web Console (browser)** — Data Grid acts as an OIDC client using the public `datagrid-console` client to drive the authorization code flow. After login at RHBK, the browser is redirected back and Data Grid establishes a session.
- **API / CLI** — callers obtain a Bearer token directly from RHBK (password grant or client credentials) and present it on each request. Data Grid introspects the token via the confidential `datagrid-client`.

Realm roles from the token are mapped to Data Grid authorization permissions in both paths.

## Prerequisites

| Requirement | Notes |
|---|---|
| `oc` CLI | Logged in with cluster-admin or sufficient RBAC |
| RHBK Operator (`rhbk-operator`) | Installed in the target namespace |
| Data Grid Operator (`datagrid-operator`) | Installed in the target namespace |
| Access to `registry.redhat.io` | Required to pull the PostgreSQL image |

## Repository Structure

```
.
├── 00-postgresql.yaml        # PostgreSQL Deployment + Service + credentials Secret
├── 01-keycloak.yaml          # RHBK (Keycloak) CR – PostgreSQL-backed, edge TLS via Route
├── 02-realm-import.yaml      # KeycloakRealmImport – datagrid realm, clients, roles, users
├── 03-infinispan-config.yaml # ConfigMap with OIDC token-realm config for Data Grid
├── 04-infinispan.yaml        # Infinispan CR – OIDC auth, TLS, authorization roles
└── deploy.sh                 # End-to-end automated deploy script
```

All YAML files use `${VAR}` placeholders that are filled in by `envsubst` before being applied to the cluster.

## Quick Start

```bash
# 1. Log in to your OpenShift cluster
oc login <cluster-api-url> --token=<your-token>

# 2. Make the script executable (if needed)
chmod +x deploy.sh

# 3. Deploy with all defaults (namespace: integration, auto-generated passwords)
./deploy.sh

# 4. Or supply your own values
NAMESPACE=my-ns \
DG_CLIENT_SECRET=mysecret \
ADMIN_USER_PASSWORD=adminpass \
APP_USER_PASSWORD=apppass \
./deploy.sh
```
### Example: You're already log into the OCP cluster, and have already set all the prerequisites, then just need to execute:
```
NAMESPACE=my-ns ./deploy.sh
```


At the end of a successful run, the script prints a summary with all credentials and example `curl` commands.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `NAMESPACE` | `integration` | Namespace where operators are installed |
| `POSTGRES_PASSWORD` | auto-generated | PostgreSQL password for RHBK database |
| `DG_CLIENT_SECRET` | auto-generated | Keycloak client secret for Data Grid token introspection |
| `ADMIN_USER_PASSWORD` | auto-generated | Password for `admin-user` in the `datagrid` realm |
| `APP_USER_PASSWORD` | auto-generated | Password for `app-user` in the `datagrid` realm |
| `RHBK_HOST` | auto-detected from cluster ingress domain | External hostname for RHBK (used in browser redirects) |
| `SCRIPT_DIR` | directory containing `deploy.sh` | Directory where YAML templates are located |

## Deployment Steps (what `deploy.sh` does)

1. **Pre-flight checks** — verifies `oc` login, both operators are present, and reads the cluster's wildcard ingress domain to derive `RHBK_HOST`.

2. **Step 1/5 – PostgreSQL** — creates credentials Secret, Service, and Deployment (`registry.redhat.io/rhel9/postgresql-15`). Waits for the rollout to complete.

3. **Step 2/5 – RHBK** — applies the `Keycloak` CR (PostgreSQL-backed, edge TLS via OpenShift Route, `xforwarded` proxy headers). Waits for `condition=Ready`.

4. **Step 3/5 – Realm import** — applies `KeycloakRealmImport` to create the `datagrid` realm, two clients, four realm roles, and two users. Waits for `condition=Done` and verifies no import errors.

5. **Step 4/5 – Data Grid config** — applies the `ConfigMap` containing the OIDC `token-realm` configuration (auth-server URL, introspection URL, client credentials).

6. **Step 5/5 – Data Grid** — applies the `Infinispan` CR (1 replica, TLS via Service CA, OIDC authorization). Waits for `condition=WellFormed` and pod `Ready`.

7. **End-to-end verification** — from inside the Data Grid pod, fetches an RHBK Bearer token for `admin-user` and calls `GET /rest/v2/server`. Expects HTTP 200.

## Keycloak Realm (`datagrid`)

### Clients

| Client ID | Type | Purpose |
|---|---|---|
| `datagrid-console` | Public | Browser-based SSO for the Data Grid web console (authorization code flow) |
| `datagrid-client` | Confidential | Server-side token introspection by the Data Grid server |

These two clients have distinct roles in `03-infinispan-config.yaml`:
- `token-realm.client-id` → `datagrid-console` (public) — used by Data Grid to redirect the browser to RHBK for login
- `oauth2-introspection.client-id` → `datagrid-client` (confidential) — used server-side to validate Bearer tokens

### Realm Roles → Data Grid Permissions

| Role | Data Grid Permissions |
|---|---|
| `admin` | ALL_READ, ALL_WRITE, EXEC, BULK_READ, BULK_WRITE, ADMIN |
| `application` | ALL_READ, ALL_WRITE, EXEC, BULK_READ, BULK_WRITE |
| `observer` | ALL_READ, BULK_READ |
| `monitor` | MONITOR |

### Default Users

| Username | Role | Notes |
|---|---|---|
| `admin-user` | `admin` | Full administrative access |
| `app-user` | `application` | Read/write access for applications |

## Web Console Login

Open `https://<DATAGRID_HOST>/console` in a browser. The console redirects to the RHBK login page for the `datagrid` realm. Log in with one of the default users (e.g. `admin-user`) and you are redirected back to the console with full access based on the user's realm role.

## Getting a Token Manually (CLI / API)

```bash
# From inside a pod that can reach the internal RHBK service
curl -s -X POST \
  http://rhbk-service.<NAMESPACE>.svc.cluster.local:8080/realms/datagrid/protocol/openid-connect/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=password&client_id=datagrid-client&client_secret=<DG_CLIENT_SECRET>' \
  -d '&username=admin-user&password=<ADMIN_USER_PASSWORD>'

# Then call Data Grid (use -k for the self-signed service cert)
curl -sk -H "Authorization: Bearer <token>" \
  https://<datagrid-console-url>/rest/v2/server
```

## Known Gotchas

- **`KeycloakRealmImport` + dev-file DB** — The operator runs the import as a Kubernetes Job using `kc.sh import` (CLI), which opens a second H2 file database. The running RHBK pod holds an exclusive lock, so the import job silently creates its own H2 instance and realm data is lost after the job exits. This deployment avoids the issue by using **PostgreSQL** as the backend. If you must use `dev-file`, import realms via `kcadm.sh` REST API instead.

- **`backchannelDynamic: true` requires a hostname** — RHBK v26 raises `hostname-backchannel-dynamic must be set to false when no hostname is provided`. The manifests always set a hostname so `backchannelDynamic: true` is safe here.

- **Data Grid authorization permissions** — `STATS` is not a valid permission in Data Grid 8.6+; use `MONITOR` instead.

- **`infinispan-config.yaml` schema** — `client-id` is a required attribute directly on `token-realm`; `client-secret` goes **only** inside `oauth2-introspection`, not at both levels.

- **Web console infinite redirect loop** — `token-realm.client-id` must be the **public** client (`datagrid-console`), not the confidential one. Data Grid uses this client ID to build the browser redirect URL for the OIDC authorization code flow. If the confidential client (`datagrid-client`) is set here instead, Keycloak completes the login but the token exchange fails silently on the server side, causing an infinite browser redirect. The confidential client belongs only inside `oauth2-introspection`.

- **`token-realm.name` must match the Keycloak realm name** — Data Grid appends `/realms/{name}` to `auth-server-url` to build the OIDC discovery URL. If `name` does not match the actual realm (e.g. `keycloak` instead of `datagrid`), discovery returns 404 and the web console redirect loop starts. `auth-server-url` must be the bare server root (`https://<RHBK_HOST>`) with no realm path appended manually.

- **Keycloak v26 user profiles** — `firstName`, `lastName`, `email`, and `emailVerified: true` must all be set on users or logins fail with *"Account is not fully set up"*, even when `requiredActions` is empty.
