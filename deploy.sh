#!/usr/bin/env bash
# deploy.sh – Deploy RHBK + Data Grid OIDC integration on any ROSA/OpenShift cluster.
#
# Prerequisites:
#   - oc CLI logged in with cluster-admin or sufficient RBAC
#   - RHBK Operator (rhbk-operator) installed in the target namespace
#   - Data Grid Operator (datagrid-operator) installed in the target namespace
#
# Usage:
#   ./deploy.sh                          # all defaults
#   NAMESPACE=my-ns ./deploy.sh          # custom namespace
#   DG_CLIENT_SECRET=s3cr3t ./deploy.sh  # custom client secret
#
# Environment variables (all have defaults):
#   NAMESPACE             Namespace where operators are installed  (default: integration)
#   POSTGRES_PASSWORD     PostgreSQL password for RHBK DB          (default: auto-generated)
#   DG_CLIENT_SECRET      Keycloak client secret for Data Grid     (default: auto-generated)
#   ADMIN_USER_PASSWORD   Password for admin-user in datagrid realm (default: auto-generated)
#   APP_USER_PASSWORD     Password for app-user in datagrid realm   (default: auto-generated)
#   RHBK_ADMIN_PASSWORD   Password for permanent RHBK admin account (default: auto-generated)
#   RHBK_HOST             External hostname for RHBK                (default: rhbk-<namespace>.<cluster-domain>)
#   DATAGRID_HOST         External hostname for Data Grid console   (default: datagrid-external-<namespace>.<cluster-domain>)
#   SCRIPT_DIR            Directory containing the YAML files       (default: script's dir)

set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────

info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
error()   { echo "[ERROR] $*" >&2; exit 1; }

gen_password() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24; }

wait_for_condition() {
  local resource="$1" condition="$2" timeout="${3:-300s}"
  info "Waiting for $resource ($condition) …"
  oc wait "$resource" -n "$NAMESPACE" --for="condition=${condition}" --timeout="$timeout" \
    || error "$resource did not reach condition '$condition' within $timeout"
}

wait_for_deployment() {
  local name="$1" timeout="${2:-300s}"
  info "Waiting for Deployment/$name to be available …"
  oc rollout status deployment/"$name" -n "$NAMESPACE" --timeout="$timeout" \
    || error "Deployment/$name did not become available within $timeout"
}

apply_template() {
  local file="$1"
  envsubst < "$file" | oc apply -f -
}

# ── Configuration ─────────────────────────────────────────────────────────────

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

export NAMESPACE="${NAMESPACE:-integration}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(gen_password)}"
export DG_CLIENT_SECRET="${DG_CLIENT_SECRET:-$(gen_password)}"
export ADMIN_USER_PASSWORD="${ADMIN_USER_PASSWORD:-$(gen_password)}"
export APP_USER_PASSWORD="${APP_USER_PASSWORD:-$(gen_password)}"
export RHBK_ADMIN_PASSWORD="${RHBK_ADMIN_PASSWORD:-$(gen_password)}"  # ← permanent RHBK admin

# ── Pre-flight checks ─────────────────────────────────────────────────────────

info "Checking prerequisites …"
oc whoami &>/dev/null || error "Not logged in to OpenShift. Run 'oc login' first."

for op in rhbk-operator datagrid-operator; do
  oc get csv -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q "$op" \
    || error "Operator '$op' not found in namespace '$NAMESPACE'. Install it first."
done

CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}' 2>/dev/null) \
  || error "Could not read cluster ingress domain. Is this an OpenShift cluster?"

export RHBK_HOST="${RHBK_HOST:-rhbk-${NAMESPACE}.${CLUSTER_DOMAIN}}"
export DATAGRID_HOST="${DATAGRID_HOST:-datagrid-external-${NAMESPACE}.${CLUSTER_DOMAIN}}"

# Validate hosts are bare hostnames (no scheme)
[[ "$RHBK_HOST" == http* ]]     && error "RHBK_HOST must be a bare hostname without https:// (got: $RHBK_HOST)"
[[ "$DATAGRID_HOST" == http* ]] && error "DATAGRID_HOST must be a bare hostname without https:// (got: $DATAGRID_HOST)"

success "Prerequisites OK (namespace: $NAMESPACE, RHBK host: $RHBK_HOST, DataGrid host: $DATAGRID_HOST)"

# ── Deploy ────────────────────────────────────────────────────────────────────

info "=== Step 1/6: PostgreSQL ==="
apply_template "$SCRIPT_DIR/00-postgresql.yaml"
wait_for_deployment postgresql 180s
success "PostgreSQL is ready"

info "=== Step 2/6: RHBK (Keycloak) ==="
apply_template "$SCRIPT_DIR/01-keycloak.yaml"
wait_for_condition "keycloak/rhbk" "Ready" 300s
success "RHBK is ready"

# ── Create permanent RHBK admin ───────────────────────────────────────────────
# The operator creates a temporary admin (temp-admin) on first boot.
# We create a permanent admin and delete the temporary one to harden security.

info "=== Step 3/6: Permanent RHBK admin ==="

# Use a random high port to avoid conflicts with other port-forwards
PF_PORT=18080
lsof -ti:${PF_PORT} | xargs kill -9 2>/dev/null || true

oc port-forward -n "$NAMESPACE" svc/rhbk-service ${PF_PORT}:8080 &
PF_PID=$!
sleep 5

TEMP_USER=$(oc get secret -n "$NAMESPACE" rhbk-initial-admin \
  -o jsonpath='{.data.username}' | base64 -d)
TEMP_PASS=$(oc get secret -n "$NAMESPACE" rhbk-initial-admin \
  -o jsonpath='{.data.password}' | base64 -d)

ADMIN_TOKEN=$(curl -s -X POST \
  "http://localhost:${PF_PORT}/realms/master/protocol/openid-connect/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=password&client_id=admin-cli&username=${TEMP_USER}&password=${TEMP_PASS}" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

[ -z "$ADMIN_TOKEN" ] && { kill $PF_PID 2>/dev/null; error "Could not get admin token from RHBK — check rhbk-initial-admin secret"; }

# Create permanent admin user in master realm
curl -s -X POST \
  "http://localhost:${PF_PORT}/admin/realms/master/users" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{
    \"username\": \"rhbk-admin\",
    \"email\": \"rhbk-admin@example.com\",
    \"firstName\": \"RHBK\",
    \"lastName\": \"Admin\",
    \"enabled\": true,
    \"emailVerified\": true,
    \"credentials\": [{
      \"type\": \"password\",
      \"value\": \"${RHBK_ADMIN_PASSWORD}\",
      \"temporary\": false
    }]
  }" > /dev/null

# Get new user UUID
NEW_USER_UUID=$(curl -s \
  "http://localhost:${PF_PORT}/admin/realms/master/users?username=rhbk-admin" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

[ -z "$NEW_USER_UUID" ] && { kill $PF_PID 2>/dev/null; error "Failed to create permanent admin user"; }

# Assign admin role
ADMIN_ROLE=$(curl -s \
  "http://localhost:${PF_PORT}/admin/realms/master/roles/admin" \
  -H "Authorization: Bearer $ADMIN_TOKEN")

curl -s -X POST \
  "http://localhost:${PF_PORT}/admin/realms/master/users/${NEW_USER_UUID}/role-mappings/realm" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "[${ADMIN_ROLE}]" > /dev/null

# Delete temporary admin
TEMP_UUID=$(curl -s \
  "http://localhost:${PF_PORT}/admin/realms/master/users?username=${TEMP_USER}" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

curl -s -X DELETE \
  "http://localhost:${PF_PORT}/admin/realms/master/users/${TEMP_UUID}" \
  -H "Authorization: Bearer $ADMIN_TOKEN"

kill $PF_PID 2>/dev/null || true
success "Permanent admin 'rhbk-admin' created, '${TEMP_USER}' deleted"

info "=== Step 4/6: Realm import ==="
apply_template "$SCRIPT_DIR/02-realm-import.yaml"
wait_for_condition "keycloakrealmimport/datagrid-realm" "Done" 180s
IMPORT_ERRORS=$(oc get keycloakrealmimport/datagrid-realm -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="HasErrors")].status}' 2>/dev/null)
[ "$IMPORT_ERRORS" = "True" ] && error "Realm import reported errors. Check: oc describe keycloakrealmimport/datagrid-realm -n $NAMESPACE"
success "Realm 'datagrid' imported successfully"

info "=== Step 5/6: Data Grid server config ==="
apply_template "$SCRIPT_DIR/03-infinispan-config.yaml"
success "ConfigMap applied"

info "=== Step 6/6: Data Grid cluster ==="
apply_template "$SCRIPT_DIR/04-infinispan.yaml"
wait_for_condition "infinispan/datagrid" "WellFormed" 300s
info "Waiting for datagrid-0 pod to be Ready …"
oc wait pod -n "$NAMESPACE" -l clusterName=datagrid --for=condition=Ready --timeout=120s \
  || error "Data Grid pod did not become Ready within 120s"
success "Data Grid cluster is running"

# ── Verification ──────────────────────────────────────────────────────────────

info "=== Verifying RHBK discovery document ==="
DISCOVERY=$(oc exec -n "$NAMESPACE" datagrid-0 -- curl -s \
  "http://rhbk-service.${NAMESPACE}.svc.cluster.local:8080/realms/datagrid/.well-known/openid-configuration")

for field in issuer authorization_endpoint token_endpoint; do
  VALUE=$(echo "$DISCOVERY" | python3 -c "import sys,json; print(json.load(sys.stdin)['$field'])")
  if [[ "$VALUE" == https://${RHBK_HOST}* ]]; then
    success "$field: $VALUE"
  else
    error "$field is not using the public hostname: $VALUE"
  fi
done

info "=== Verifying end-to-end OIDC flow ==="

RHBK_URL="http://rhbk-service.${NAMESPACE}.svc.cluster.local:8080"

VERIFY=""
for attempt in 1 2 3; do
  VERIFY=$(oc exec -n "$NAMESPACE" datagrid-0 -- sh -c "
    TOKEN=\$(curl -s -X POST '${RHBK_URL}/realms/datagrid/protocol/openid-connect/token' \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      -d 'grant_type=password&client_id=datagrid-client&client_secret=${DG_CLIENT_SECRET}&username=admin-user&password=${ADMIN_USER_PASSWORD}' \
      | grep -o '\"access_token\":\"[^\"]*\"' | cut -d'\"' -f4)
    curl -sk -o /dev/null -w '%{http_code}' \
      -H \"Authorization: Bearer \$TOKEN\" \
      https://localhost:11222/rest/v2/server
  " 2>/dev/null) || true
  [ "$VERIFY" = "200" ] && break
  [ "$attempt" -lt 3 ] && { info "Attempt $attempt failed (got '$VERIFY'), retrying in 10s …"; sleep 10; }
done

[ "$VERIFY" = "200" ] \
  && success "OIDC auth verified: Data Grid accepted RHBK Bearer token (HTTP 200)" \
  || error "Verification failed (got '$VERIFY' instead of 200). Check pod logs."

# ── Summary ───────────────────────────────────────────────────────────────────

DG_CONSOLE=$(oc get infinispan datagrid -n "$NAMESPACE" \
  -o jsonpath='{.status.consoleUrl}' 2>/dev/null || echo "unavailable")

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  RHBK + Data Grid OIDC integration deployed              ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║  Namespace          : %-35s║\n" "$NAMESPACE"
printf "║  RHBK (external)    : %-35s║\n" "https://$RHBK_HOST"
printf "║  Data Grid console  : %-35s║\n" "https://$DATAGRID_HOST/console"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Credentials (store these securely)                      ║"
printf "║  RHBK admin         : rhbk-admin / %-21s║\n" "$RHBK_ADMIN_PASSWORD"
printf "║  admin-user         : %-35s║\n" "$ADMIN_USER_PASSWORD"
printf "║  app-user           : %-35s║\n" "$APP_USER_PASSWORD"
printf "║  DG client secret   : %-35s║\n" "$DG_CLIENT_SECRET"
printf "║  Postgres password  : %-35s║\n" "$POSTGRES_PASSWORD"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Get a token (inside cluster):"
echo "    curl -s -X POST \\"
echo "    ${RHBK_URL}/realms/datagrid/protocol/openid-connect/token \\"
echo "    -d 'grant_type=password&client_id=datagrid-client&client_secret=${DG_CLIENT_SECRET}'"
echo "    -d '&username=admin-user&password=${ADMIN_USER_PASSWORD}'"
echo ""
echo "  Get a token (external):"
echo "    curl -s -X POST \\"
echo "    https://${RHBK_HOST}/realms/datagrid/protocol/openid-connect/token \\"
echo "    -d 'grant_type=password&client_id=datagrid-client&client_secret=${DG_CLIENT_SECRET}'"
echo "    -d '&username=admin-user&password=${ADMIN_USER_PASSWORD}'"
echo ""
echo "  Call Data Grid:"
echo "    curl -k -H 'Authorization: Bearer <token>' https://${DATAGRID_HOST}/rest/v2/server"