#!/bin/bash
set -e

# =============================================================================
# devops-automation.sh
# Location: <devops-repo>/automation/devops-automation.sh
#
# Automates onboarding of a new application into the devops repo.
# - Clones the source repo to inspect k8s/ manifests
# - Generates deployment, service, kustomization YAMLs per environment
# - Injects secrets and configmap mappings into each env's deployment
# - Creates ArgoCD applications (gated by DEPLOY_STAGE env var in pipeline)
# - Generates ingress YAML and updates the shared ingress kustomization
# =============================================================================

# =============================================================================
# HARDCODED CONFIGURATION — update these to match your environment
# =============================================================================
ARGOCD_SERVER="http://localhost:8082"
ARGOCD_USERNAME="admin"
ARGOCD_PASSWORD="8zJjXj3Jthy2Jeaz"          # Inject via pipeline secret
DEVOPS_REPO="https://github.com/ekelejames/devops.git"
DEVOPS_REPO_PATH="$(cd "$(dirname "$0")/.." && pwd)"  # Root of the devops repo
REGISTRY_URL="coureregistry.azurecr.io"
CONTAINER_PORT="8080"

# Namespace mapping
NS_DEV="dev-anq"
NS_STAGING="staging-anq"
NS_PROD="app-prod"

# Ingress host mapping
DMZ_HOST_DEV="devgtw.coure-tech.com"
DMZ_HOST_STAGING="stgtw.coure-tech.com"
DMZ_HOST_PROD="gtw.coure-tech.com"

TCP_HOST_DEV="devanqapi.coure-tech.com"
TCP_HOST_STAGING="stganqapi.coure-tech.com"
TCP_HOST_PROD="anqapi.coure-tech.com"

UDP_HOST_DEV="devanqenum.coure-tech.com"
UDP_HOST_STAGING="stganqenum.coure-tech.com"
UDP_HOST_PROD="anqenum.coure-tech.com"

# Resource defaults
CPU_REQUEST="100m"
MEM_REQUEST="128Mi"
CPU_LIMIT="500m"
MEM_LIMIT="512Mi"

# =============================================================================
# USAGE
# =============================================================================
usage() {
  echo ""
  echo "Usage: $0 --repo <source-repo-url> --ingress-type <dmz|tcp|udp> [--port <container-port>]"
  echo ""
  echo "  --repo          Git URL of the application source repo (required)"
  echo "  --ingress-type  Ingress class for this app: dmz, tcp, or udp (required)"
  echo "  --port          Container port (default: 8080)"
  echo ""
  echo "Pipeline env vars:"
  echo "  DEPLOY_STAGE    Which stage is running: dev | staging | prod"
  echo "  ARGOCD_PASSWORD ArgoCD admin password (required for ArgoCD app creation)"
  echo ""
  echo "Example:"
  echo "  $0 --repo https://github.com/coure-tech/fraud-prvt-posdevice-location.git --ingress-type tcp"
  echo ""
  exit 1
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
REPO_URL=""
INGRESS_TYPE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)         REPO_URL="$2";       shift 2 ;;
    --ingress-type) INGRESS_TYPE="$2";   shift 2 ;;
    --port)         CONTAINER_PORT="$2"; shift 2 ;;
    -h|--help)      usage ;;
    *) echo "❌ Unknown argument: $1"; usage ;;
  esac
done

# =============================================================================
# VALIDATION
# =============================================================================
if [ -z "$REPO_URL" ]; then
  echo "❌ --repo is required."
  usage
fi

if [ -z "$INGRESS_TYPE" ]; then
  echo "❌ --ingress-type is required (dmz, tcp, or udp)."
  usage
fi

if [[ "$INGRESS_TYPE" != "dmz" && "$INGRESS_TYPE" != "tcp" && "$INGRESS_TYPE" != "udp" ]]; then
  echo "❌ --ingress-type must be one of: dmz, tcp, udp"
  exit 1
fi

if ! command -v yq &>/dev/null; then
  echo "❌ yq is not installed. Please install it before running this script."
  exit 1
fi

if ! command -v git &>/dev/null; then
  echo "❌ git is not installed."
  exit 1
fi

# =============================================================================
# DERIVE APP NAME FROM REPO URL
# e.g. https://github.com/org/fraud-prvt-posdevice-location.git
#   -> fraud-prvt-posdevice-location
# =============================================================================
REPO_BASENAME=$(basename "$REPO_URL" .git)
APP_NAME="${REPO_BASENAME}"

echo ""
echo "============================================================"
echo "  DevOps Automation — App Onboarding"
echo "============================================================"
echo "  App name     : ${APP_NAME}"
echo "  Source repo  : ${REPO_URL}"
echo "  Ingress type : ${INGRESS_TYPE}"
echo "  Container port: ${CONTAINER_PORT}"
echo "  Deploy stage : ${DEPLOY_STAGE:-<all — local run>}"
echo "============================================================"
echo ""

# =============================================================================
# DERIVE SLUG FOR DMZ PATH
# Strips common prefixes to produce a short path slug.
# e.g. fraud-prvt-posdevice-location -> posdevice-location
#      anq-cms-wks                   -> cms-wks
# Strips (in order): fraud-prvt-, anq-, coure-
# =============================================================================
derive_slug() {
  local name="$1"
  local slug="$name"
  # Strip known prefixes iteratively
  for prefix in "fraud-prvt-" "fraudprevention-" "kyc-" "coure-" "anq-"; do
    slug="${slug#$prefix}"
  done
  echo "$slug"
}

APP_SLUG=$(derive_slug "$APP_NAME")
echo "ℹ️  Derived ingress path slug: ${APP_SLUG}"

# =============================================================================
# PATHS
# =============================================================================
APPS_DIR="${DEVOPS_REPO_PATH}/apps"
APP_DIR="${APPS_DIR}/${APP_NAME}"
INGRESS_BASE="${DEVOPS_REPO_PATH}/ingress"
TMP_CLONE=$(mktemp -d)

cleanup() {
  echo ""
  echo "🧹 Cleaning up temporary clone..."
  rm -rf "$TMP_CLONE"
}
trap cleanup EXIT

# =============================================================================
# CLONE SOURCE REPO
# =============================================================================
echo "📥 Cloning source repo..."
git clone --depth=1 "$REPO_URL" "$TMP_CLONE"
SOURCE_K8S="${TMP_CLONE}/k8s"

if [ ! -d "$SOURCE_K8S" ]; then
  echo "⚠️  No k8s/ directory found in source repo. Secret/config injection will be skipped."
fi

# =============================================================================
# CHECK APP FOLDER DOES NOT ALREADY EXIST
# =============================================================================
if [ -d "$APP_DIR" ]; then
  echo "❌ App folder already exists: ${APP_DIR}"
  echo "   If you are re-onboarding, remove the folder first."
  exit 1
fi

# =============================================================================
# CREATE FOLDER STRUCTURE
# apps/<app-name>/
#   dev/
#     deployment.yaml
#     service.yaml
#     kustomization.yaml
#   staging/  (same)
#   prod/     (same)
# =============================================================================
echo "📁 Creating app folder structure at: ${APP_DIR}"
mkdir -p "${APP_DIR}/dev"
mkdir -p "${APP_DIR}/staging"
mkdir -p "${APP_DIR}/prod"

# =============================================================================
# HELPER: Build env block from secrets mapping file
# =============================================================================
build_env_block_from_secrets() {
  local mapping_file="$1"  # path to <app>-secrets.yaml
  local block=""

  if [ ! -f "$mapping_file" ]; then
    echo ""
    return
  fi

  local secret_name
  secret_name=$(yq eval '.secretRef.name' "$mapping_file")
  local count
  count=$(yq eval '.mappings | length' "$mapping_file")

  for ((i=0; i<count; i++)); do
    local k8s_key env_name
    k8s_key=$(yq eval ".mappings[$i].k8sKey" "$mapping_file")
    env_name=$(yq eval ".mappings[$i].envName" "$mapping_file")
    block+="        - name: ${env_name}
          valueFrom:
            secretKeyRef:
              name: ${secret_name}
              key: ${k8s_key}
"
  done
  echo "$block"
}

# =============================================================================
# HELPER: Build env block from config mapping file
# =============================================================================
build_env_block_from_config() {
  local mapping_file="$1"  # path to <app>-config.yaml
  local block=""

  if [ ! -f "$mapping_file" ]; then
    echo ""
    return
  fi

  local config_name
  config_name=$(yq eval '.configMapRef.name' "$mapping_file")
  local count
  count=$(yq eval '.mappings | length' "$mapping_file")

  for ((i=0; i<count; i++)); do
    local k8s_key env_name
    k8s_key=$(yq eval ".mappings[$i].k8sKey" "$mapping_file")
    env_name=$(yq eval ".mappings[$i].envName" "$mapping_file")
    block+="        - name: ${env_name}
          valueFrom:
            configMapKeyRef:
              name: ${config_name}
              key: ${k8s_key}
"
  done
  echo "$block"
}

# =============================================================================
# HELPER: Render deployment.yaml for a given environment
# =============================================================================
generate_deployment() {
  local env="$1"         # dev | staging | prod
  local namespace="$2"   # dev-anq | staging-anq | app-prod
  local out_file="$3"

  # Collect env vars from mapping files (if k8s/ folder exists in source repo)
  local secrets_block="" config_block="" full_env_block=""
  if [ -d "$SOURCE_K8S" ]; then
    secrets_block=$(build_env_block_from_secrets "${SOURCE_K8S}/${APP_NAME}-secrets.yaml")
    config_block=$(build_env_block_from_config   "${SOURCE_K8S}/${APP_NAME}-config.yaml")
  fi

  if [ -n "$secrets_block" ] || [ -n "$config_block" ]; then
    full_env_block="      env:
${secrets_block}${config_block}"
  fi

  cat > "$out_file" <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}-deployment
  namespace: ${namespace}
  labels:
    app: ${APP_NAME}
spec:
  selector:
    matchLabels:
      app: ${APP_NAME}
  replicas: 1
  strategy:
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: ${APP_NAME}
      annotations:
        dapr.io/app-id: ${APP_SLUG}
        dapr.io/app-port: '${CONTAINER_PORT}'
        dapr.io/config: tracing
        dapr.io/enabled: 'true'
        dapr.io/log-as-json: 'true'
        dapr.io/sidecar-liveness-probe-timeout-seconds: '10'
        dapr.io/sidecar-readiness-probe-timeout-seconds: '10'
    spec:
      containers:
        - name: ${APP_NAME}
          image: ${REGISTRY_URL}/${APP_NAME}:latest
          resources:
            requests:
              cpu: ${CPU_REQUEST}
              memory: ${MEM_REQUEST}
            limits:
              cpu: ${CPU_LIMIT}
              memory: ${MEM_LIMIT}
          ports:
            - containerPort: ${CONTAINER_PORT}
              name: http
${full_env_block}
      imagePullSecrets:
        - name: docker-creds
EOF

  echo "  ✅ deployment.yaml → ${out_file}"
}

# =============================================================================
# HELPER: Render service.yaml
# =============================================================================
generate_service() {
  local namespace="$1"
  local out_file="$2"

  cat > "$out_file" <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}-service
  namespace: ${namespace}
  labels:
    app: ${APP_NAME}
spec:
  ports:
    - port: ${CONTAINER_PORT}
      targetPort: http
      protocol: TCP
      name: http
  selector:
    app: ${APP_NAME}
EOF

  echo "  ✅ service.yaml → ${out_file}"
}

# =============================================================================
# HELPER: Render kustomization.yaml
# =============================================================================
generate_kustomization() {
  local namespace="$1"
  local out_file="$2"

  cat > "$out_file" <<EOF
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${namespace}
resources:
  - deployment.yaml
  - service.yaml
images:
  - name: ${REGISTRY_URL}/${APP_NAME}
    newTag: latest
EOF

  echo "  ✅ kustomization.yaml → ${out_file}"
}

# =============================================================================
# GENERATE MANIFESTS FOR ALL THREE ENVIRONMENTS
# =============================================================================
declare -A ENV_NAMESPACES=(
  [dev]="$NS_DEV"
  [staging]="$NS_STAGING"
  [prod]="$NS_PROD"
)

for env in dev staging prod; do
  ns="${ENV_NAMESPACES[$env]}"
  env_dir="${APP_DIR}/${env}"

  echo ""
  echo "📝 Generating manifests for [${env}] (namespace: ${ns})..."

  generate_deployment  "$env" "$ns" "${env_dir}/deployment.yaml"
  generate_service     "$ns"        "${env_dir}/service.yaml"
  generate_kustomization "$ns"      "${env_dir}/kustomization.yaml"
done

# =============================================================================
# GENERATE INGRESS YAML
# =============================================================================
echo ""
echo "🌐 Generating ingress manifests..."

generate_ingress_dmz() {
  local env="$1"
  local namespace="$2"
  local host="$3"
  local out_file="$4"

  # Prod has no namespace in manifest
  local ns_line=""
  if [ "$env" != "prod" ]; then
    ns_line="  namespace: ${namespace}"
  fi

  cat > "$out_file" <<EOF
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${APP_NAME}-ingress
${ns_line}
  annotations:
    nginx.ingress.kubernetes.io/force-ssl-redirect: 'true'
    nginx.ingress.kubernetes.io/rewrite-target: /\$2
    nginx.ingress.kubernetes.io/ssl-redirect: 'true'
spec:
  ingressClassName: dmz-nginx
  tls:
  - hosts:
    - ${host}
    secretName: coure-secret
  rules:
  - host: ${host}
    http:
      paths:
      - path: /${APP_SLUG}(/|\$)(.*)
        pathType: Prefix
        backend:
          service:
            name: ${APP_NAME}-service
            port:
              number: ${CONTAINER_PORT}
EOF
  echo "  ✅ ingress (dmz) → ${out_file}"
}

generate_ingress_tcp_udp() {
  local env="$1"
  local namespace="$2"
  local host="$3"
  local ingress_class="$4"   # tcp-nginx | udp-nginx
  local out_file="$5"

  local ns_line=""
  if [ "$env" != "prod" ]; then
    ns_line="  namespace: ${namespace}"
  fi

  # UDP gets extra timeout annotations
  local extra_annotations=""
  if [ "$ingress_class" == "udp-nginx" ]; then
    extra_annotations="    nginx.ingress.kubernetes.io/proxy-read-timeout: '600'
    nginx.ingress.kubernetes.io/proxy-send-timeout: '600'"
  fi

  cat > "$out_file" <<EOF
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${APP_NAME}-ingress
${ns_line}
  annotations:
    nginx.ingress.kubernetes.io/force-ssl-redirect: 'true'
    nginx.ingress.kubernetes.io/rewrite-target: /
    nginx.ingress.kubernetes.io/ssl-redirect: 'true'
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
${extra_annotations}
spec:
  ingressClassName: ${ingress_class}
  tls:
  - hosts:
    - ${host}
    secretName: coure-secret
  rules:
  - host: ${host}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${APP_NAME}-service
            port:
              number: ${CONTAINER_PORT}
EOF
  echo "  ✅ ingress (${ingress_class}) → ${out_file}"
}

# Map env → hosts and generate ingress files
declare -A DMZ_HOSTS=([dev]="$DMZ_HOST_DEV" [staging]="$DMZ_HOST_STAGING" [prod]="$DMZ_HOST_PROD")
declare -A TCP_HOSTS=([dev]="$TCP_HOST_DEV" [staging]="$TCP_HOST_STAGING" [prod]="$TCP_HOST_PROD")
declare -A UDP_HOSTS=([dev]="$UDP_HOST_DEV" [staging]="$UDP_HOST_STAGING" [prod]="$UDP_HOST_PROD")

for env in dev staging prod; do
  ns="${ENV_NAMESPACES[$env]}"
  ingress_env_dir="${INGRESS_BASE}/overlays/${env}/external-apis/${INGRESS_TYPE}"
  mkdir -p "$ingress_env_dir"
  ingress_out="${ingress_env_dir}/${APP_NAME}.yaml"

  case "$INGRESS_TYPE" in
    dmz) generate_ingress_dmz     "$env" "$ns" "${DMZ_HOSTS[$env]}" "$ingress_out" ;;
    tcp) generate_ingress_tcp_udp "$env" "$ns" "${TCP_HOSTS[$env]}" "tcp-nginx" "$ingress_out" ;;
    udp) generate_ingress_tcp_udp "$env" "$ns" "${UDP_HOSTS[$env]}" "udp-nginx" "$ingress_out" ;;
  esac
done

# =============================================================================
# UPDATE INGRESS KUSTOMIZATION.YAML FOR EACH ENV
# Appends the new resource entry if not already present
# =============================================================================
echo ""
echo "🔧 Updating ingress kustomization files..."

for env in dev staging prod; do
  kust_file="${INGRESS_BASE}/overlays/${env}/kustomization.yaml"
  new_entry="- external-apis/${INGRESS_TYPE}/${APP_NAME}.yaml"

  if [ ! -f "$kust_file" ]; then
    echo "  ⚠️  kustomization.yaml not found for [${env}]: ${kust_file} — skipping"
    continue
  fi

  # Check if entry already exists
  if grep -qF "$new_entry" "$kust_file"; then
    echo "  ℹ️  [${env}] Entry already exists in kustomization.yaml — skipping"
  else
    # Append under the resources: block — find last resource line and insert after it
    # We append at end of file as the kustomization resources list just grows
    echo "$new_entry" >> "$kust_file"
    echo "  ✅ [${env}] Appended '${new_entry}' to kustomization.yaml"
  fi

  # Also update ingress-extention.txt tracker
  tracker="${INGRESS_BASE}/overlays/${env}/external-apis/ingress-extention.txt"
  if [ -f "$tracker" ]; then
    if ! grep -qF "$new_entry" "$tracker"; then
      echo "$new_entry" >> "$tracker"
      echo "  ✅ [${env}] Updated ingress-extention.txt tracker"
    fi
  fi
done

# =============================================================================
# ARGOCD APP CREATION
# Gated by DEPLOY_STAGE env var:
#   DEPLOY_STAGE=dev     → create dev ArgoCD app only
#   DEPLOY_STAGE=staging → create staging ArgoCD app only
#   DEPLOY_STAGE=prod    → create prod ArgoCD app only
#   (unset)              → create all (for local/manual runs)
# =============================================================================
create_argocd_app() {
  local env="$1"
  local namespace="$2"
  local app_path="apps/${APP_NAME}/${env}"  # path inside devops repo

  local argocd_app_name="${APP_NAME}-${env}"

  echo ""
  echo "🚀 Creating ArgoCD application: ${argocd_app_name}"
  echo "   Repo    : ${DEVOPS_REPO}"
  echo "   Path    : ${app_path}"
  echo "   NS      : ${namespace}"

  if [ -z "$ARGOCD_PASSWORD" ]; then
    echo "  ❌ ARGOCD_PASSWORD is not set. Cannot login to ArgoCD."
    exit 1
  fi

  # Login
  argocd login "$ARGOCD_SERVER" \
    --username "$ARGOCD_USERNAME" \
    --password "$ARGOCD_PASSWORD" \
    --insecure

  # Create app (idempotent — upsert)
  argocd app create "$argocd_app_name" \
    --repo "$DEVOPS_REPO" \
    --path "$app_path" \
    --dest-server "https://kubernetes.default.svc" \
    --dest-namespace "$namespace" \
    --sync-policy automated \
    --auto-prune \
    --self-heal \
    --upsert

  echo "  ✅ ArgoCD app '${argocd_app_name}' created/updated."
}

echo ""
echo "============================================================"
echo "  ArgoCD Application Creation"
echo "============================================================"

if ! command -v argocd &>/dev/null; then
  echo "⚠️  argocd CLI not found. Skipping ArgoCD app creation."
  echo "   Install it or ensure it is on PATH in your pipeline agent."
else
  case "${DEPLOY_STAGE:-all}" in
    dev)
      create_argocd_app "dev" "$NS_DEV"
      ;;
    staging)
      create_argocd_app "staging" "$NS_STAGING"
      ;;
    prod)
      create_argocd_app "prod" "$NS_PROD"
      ;;
    all)
      echo "ℹ️  DEPLOY_STAGE not set — creating ArgoCD apps for all environments."
      create_argocd_app "dev"     "$NS_DEV"
      create_argocd_app "staging" "$NS_STAGING"
      create_argocd_app "prod"    "$NS_PROD"
      ;;
    *)
      echo "⚠️  Unknown DEPLOY_STAGE '${DEPLOY_STAGE}'. Skipping ArgoCD app creation."
      ;;
  esac
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "============================================================"
echo "  ✅ Onboarding Complete: ${APP_NAME}"
echo "============================================================"
echo ""
echo "  App manifests created:"
echo "    ${APP_DIR}/dev/"
echo "    ${APP_DIR}/staging/"
echo "    ${APP_DIR}/prod/"
echo ""
echo "  Ingress YAMLs created:"
for env in dev staging prod; do
  echo "    ${INGRESS_BASE}/overlays/${env}/external-apis/${INGRESS_TYPE}/${APP_NAME}.yaml"
done
echo ""
echo "  Ingress kustomization.yaml files updated for: dev, staging, prod"
echo ""
echo "  Next steps:"
echo "  1. Review generated files and commit them to the devops repo."
echo "  2. Ensure the ArgoCD apps are syncing correctly."
echo "  3. Verify ingress routing is resolving as expected."
echo ""