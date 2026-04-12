#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: update-gitops.sh \
  --gitops-repo <ssh-url> \
  --gitops-branch <branch> \
  --infra-repo <repo-url> \
  --infra-revision <revision> \
  --chart-path <path> \
  --ssh-key <path> \
  --operation <deploy|rollback> \
  --workspace-id <workspace-id> \
  --user-id <user-id> \
  --project-name <project-name> \
  --custom-domain <domain> \
  --env-json <json> \
  --image-repository <repository> \
  --image-tag <tag> \
  --app-port <port> \
  --platform-domain <domain> \
  --framework <framework> \
  --service-type <gateway|internal|registry> \
  --commit-sha <sha> \
  --build-number <build-number>
USAGE
}

slugify() {
  local raw="$1"
  local max_len="${2:-40}"

  local normalized
  normalized="$(echo "${raw}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g')"

  if [[ -z "${normalized}" ]]; then
    normalized="x"
  fi

  echo "${normalized}" | cut -c1-"${max_len}"
}

default_container_port_for_framework() {
  local framework="$1"

  case "${framework}" in
    springboot-maven|springboot-gradle|java-maven|java-gradle)
      echo "8080"
      ;;
    nextjs|nodejs)
      echo "3000"
      ;;
    react|static)
      echo "80"
      ;;
    *)
      echo ""
      ;;
  esac
}

probe_mode_for_framework() {
  local framework="$1"

  case "${framework}" in
    springboot-maven|springboot-gradle|java-maven|java-gradle)
      echo "tcp"
      ;;
    nextjs|nodejs|react|static)
      echo "http"
      ;;
    *)
      echo "http"
      ;;
  esac
}

startup_probe_enabled_for_framework() {
  local framework="$1"

  case "${framework}" in
    springboot-maven|springboot-gradle|java-maven|java-gradle)
      echo "true"
      ;;
    nextjs|nodejs|react|static|*)
      echo "false"
      ;;
  esac
}

indent_block_scalar() {
  local content="$1"
  local indent="${2:-2}"
  local prefix
  prefix="$(printf '%*s' "${indent}" '')"

  if [[ -z "${content}" ]]; then
    echo "${prefix}[]"
    return 0
  fi

  while IFS= read -r line || [[ -n "${line}" ]]; do
    echo "${prefix}${line}"
  done <<< "${content}"
}

resolve_container_port() {
  local framework="$1"
  local requested_port="$2"
  local default_port

  default_port="$(default_container_port_for_framework "${framework}")"

  if [[ -z "${requested_port}" || "${requested_port}" == "3000" ]]; then
    echo "${default_port}"
    return 0
  fi

  echo "${requested_port}"
}

force_https_ingress() {
  local values_file="$1"

  if ! awk '
    BEGIN { in_ingress = 0; in_tls = 0 }
    {
      line = $0

      if (line ~ /^[[:space:]]*ingress:[[:space:]]*$/) {
        in_ingress = 1
        in_tls = 0
        print line
        next
      }

      if (in_ingress && line ~ /^[^[:space:]#][^:]*:[[:space:]]*$/) {
        in_ingress = 0
        in_tls = 0
      }

      if (in_ingress && line ~ /^[[:space:]]*tls:[[:space:]]*$/) {
        in_tls = 1
        print line
        next
      }

      if (in_ingress && in_tls && line ~ /^[[:space:]]*enabled:[[:space:]]*(true|false)[[:space:]]*$/) {
        sub(/enabled:[[:space:]]*(true|false)/, "enabled: true")
        print line
        next
      }

      print line
    }
  ' "${values_file}" > "${values_file}.tmp"; then
    rm -f "${values_file}.tmp"
    return 1
  fi

  mv "${values_file}.tmp" "${values_file}"
}

create_values_file() {
  local values_file="$1"
  local safe_workspace_id="$2"
  local safe_user_id="$3"
  local safe_project_name="$4"
  local namespace="$5"
  local framework="$6"
  local image_repository="$7"
  local image_tag="$8"
  local app_port="$9"
  local domain="${10}"
  local custom_domain="${11}"
  local env_json="${12}"
  local service_type="${13:-internal}"
  local effective_app_port
  local probe_mode
  local startup_probe_enabled

  local default_host_label
  default_host_label="$(slugify "${safe_project_name}-${safe_workspace_id}" 63)"
  effective_app_port="$(resolve_container_port "${framework}" "${app_port}")"
  probe_mode="$(probe_mode_for_framework "${framework}")"
  startup_probe_enabled="$(startup_probe_enabled_for_framework "${framework}")"

  local effective_host="${default_host_label}.${domain}"
  if [[ -n "${custom_domain}" ]]; then
    effective_host="${custom_domain}"
  fi

  if [[ -z "${env_json}" ]]; then
    env_json="[]"
  fi

  # Ingress is only enabled for gateway services (externally reachable).
  # internal and registry services are ClusterIP-only — reachable by name
  # within the namespace via Kubernetes DNS.
  local ingress_enabled="false"
  if [[ "${service_type}" == "gateway" ]]; then
    ingress_enabled="true"
  fi

  cat > "${values_file}" <<VALUES
app:
  name: "${safe_project_name}"
  userId: "${safe_user_id}"
  projectName: "${safe_project_name}"
  namespace: "${namespace}"
  framework: "${framework}"
  serviceType: "${service_type}"
  containerPort: ${effective_app_port}
  servicePort: 80
  domain: "${domain}"
  host: "${effective_host}" # managed-by-jenkins-host

image:
  repository: "${image_repository}"
  tag: "${image_tag}" # managed-by-jenkins-image-tag
  pullPolicy: "IfNotPresent"

replicaCount: 1

resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "500m"
    memory: "512Mi"

autoscaling:
  enabled: true
  minReplicas: 1
  maxReplicas: 4
  targetCPUUtilizationPercentage: 70

ingress:
  enabled: ${ingress_enabled}
  className: "nginx"
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
  tls:
    enabled: true
    secretName: "${safe_project_name}-tls"

imagePullSecrets:
  - name: "registry-secret"

envJson: |
$(indent_block_scalar "${env_json}" 2)

probes:
  mode: "${probe_mode}"
  startup:
    enabled: ${startup_probe_enabled}
    initialDelaySeconds: 0
    periodSeconds: 5
    failureThreshold: 24
  readiness:
    enabled: true
    path: "/"
    initialDelaySeconds: 10
    periodSeconds: 10
    failureThreshold: 3
  liveness:
    enabled: true
    path: "/"
    initialDelaySeconds: 30
    periodSeconds: 15
    failureThreshold: 3
VALUES
}

ensure_namespace_manifest() {
  local user_root="$1"
  local namespace="$2"

  cat > "${user_root}/namespace.yaml" <<NAMESPACE
apiVersion: v1
kind: Namespace
metadata:
  name: ${namespace}
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
  labels:
    app.kubernetes.io/managed-by: argocd
    platform.devops/user-namespace: "true"
NAMESPACE
}

create_application_manifest() {
  local application_file="$1"
  local application_name="$2"
  local project_name="$3"
  local namespace="$4"
  local gitops_repo="$5"
  local gitops_branch="$6"
  local values_file_path="$7"
  local infra_repo="$8"
  local infra_revision="$9"
  local chart_path="${10}"
  local safe_project_name="${11}"

  cat > "${application_file}" <<APPLICATION
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: "${application_name}"
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
  labels:
    app.kubernetes.io/managed-by: argocd
    platform.devops/project-name: "${safe_project_name}"
spec:
  project: "${project_name}"
  destination:
    server: https://kubernetes.default.svc
    namespace: "${namespace}"
  sources:
    - repoURL: "${infra_repo}"
      targetRevision: "${infra_revision}"
      path: "${chart_path}"
      helm:
        releaseName: "${safe_project_name}"
        valueFiles:
          - \$values/${values_file_path}
    - repoURL: "${gitops_repo}"
      targetRevision: "${gitops_branch}"
      ref: values
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
APPLICATION
}

commit_and_push() {
  local repo_dir="$1"
  local branch="$2"
  local project_path="$3"
  local namespace_file="$4"
  local commit_message="$5"

  (
    cd "${repo_dir}"
    git config user.email "jenkins@platform.local"
    git config user.name "Jenkins CI"

    git add "${project_path}" "${namespace_file}"

    if git diff --cached --quiet; then
      echo "No GitOps changes required. Requested image tag already present."
      return 10
    fi

    git commit -m "${commit_message}" >/dev/null

    if git push origin "${branch}" >/dev/null; then
      echo "GitOps repository updated successfully."
      return 0
    fi

    return 1
  )
}

GITOPS_REPO=""
GITOPS_BRANCH="main"
INFRA_REPO=""
INFRA_REVISION="main"
CHART_PATH="helm/app-template"
SSH_KEY=""
OPERATION="deploy"
WORKSPACE_ID=""
USER_ID=""
PROJECT_NAME=""
IMAGE_REPOSITORY=""
IMAGE_TAG=""
APP_PORT=""
PLATFORM_DOMAIN=""
FRAMEWORK=""
SERVICE_TYPE="internal"
COMMIT_SHA=""
BUILD_NUMBER=""
CUSTOM_DOMAIN=""
ENV_JSON="[]"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gitops-repo)
      GITOPS_REPO="$2"
      shift 2
      ;;
    --gitops-branch)
      GITOPS_BRANCH="$2"
      shift 2
      ;;
    --infra-repo)
      INFRA_REPO="$2"
      shift 2
      ;;
    --infra-revision)
      INFRA_REVISION="$2"
      shift 2
      ;;
    --chart-path)
      CHART_PATH="$2"
      shift 2
      ;;
    --ssh-key)
      SSH_KEY="$2"
      shift 2
      ;;
    --operation)
      OPERATION="$2"
      shift 2
      ;;
    --workspace-id)
      WORKSPACE_ID="$2"
      shift 2
      ;;
    --user-id)
      USER_ID="$2"
      shift 2
      ;;
    --project-name)
      PROJECT_NAME="$2"
      shift 2
      ;;
    --custom-domain)
      CUSTOM_DOMAIN="$2"
      shift 2
      ;;
    --env-json)
      ENV_JSON="$2"
      shift 2
      ;;
    --image-repository)
      IMAGE_REPOSITORY="$2"
      shift 2
      ;;
    --image-tag)
      IMAGE_TAG="$2"
      shift 2
      ;;
    --app-port)
      APP_PORT="$2"
      shift 2
      ;;
    --platform-domain)
      PLATFORM_DOMAIN="$2"
      shift 2
      ;;
    --framework)
      FRAMEWORK="$2"
      shift 2
      ;;
    --service-type)
      SERVICE_TYPE="$2"
      shift 2
      ;;
    --commit-sha)
      COMMIT_SHA="$2"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

for required in GITOPS_REPO INFRA_REPO SSH_KEY USER_ID PROJECT_NAME IMAGE_REPOSITORY IMAGE_TAG APP_PORT PLATFORM_DOMAIN FRAMEWORK COMMIT_SHA BUILD_NUMBER; do
  if [[ -z "${!required}" ]]; then
    echo "Missing required argument: ${required}" >&2
    usage
    exit 1
  fi
done

if [[ -z "${INFRA_REVISION}" ]]; then
  echo "INFRA_REVISION must not be empty" >&2
  exit 1
fi

if [[ -z "${CHART_PATH}" ]]; then
  echo "CHART_PATH must not be empty" >&2
  exit 1
fi

if [[ -z "${WORKSPACE_ID}" ]]; then
  WORKSPACE_ID="${USER_ID}"
fi

if [[ -n "${CUSTOM_DOMAIN}" ]]; then
  CUSTOM_DOMAIN="$(echo "${CUSTOM_DOMAIN}" | tr '[:upper:]' '[:lower:]' | sed -E 's#^https?://##; s#/.*$##; s/^[[:space:]]+|[[:space:]]+$//g')"
  if [[ -n "${CUSTOM_DOMAIN}" ]]; then
    if [[ "${CUSTOM_DOMAIN}" == *":"* ]]; then
      echo "Custom domain must not include a port: ${CUSTOM_DOMAIN}" >&2
      exit 1
    fi
    if [[ "${CUSTOM_DOMAIN}" == \*.* ]]; then
      echo "Wildcard custom domain is not supported: ${CUSTOM_DOMAIN}" >&2
      exit 1
    fi
    if [[ ! "${CUSTOM_DOMAIN}" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
      echo "Invalid custom domain format: ${CUSTOM_DOMAIN}" >&2
      exit 1
    fi
  fi
fi

if [[ ! -f "${SSH_KEY}" ]]; then
  echo "SSH key file not found: ${SSH_KEY}" >&2
  echo "Verify Jenkins credential 'gitops-ssh' is configured as 'SSH Username with private key'." >&2
  exit 1
fi

chmod 600 "${SSH_KEY}" || true

if ! ssh-keygen -y -f "${SSH_KEY}" >/dev/null 2>&1; then
  echo "Invalid SSH private key provided by Jenkins credential 'gitops-ssh'." >&2
  echo "Expected a real private key (OpenSSH/PEM), not a GitHub token/password." >&2
  echo "Use username 'git' and paste the private key content in Jenkins credentials." >&2
  exit 1
fi

# If Jenkins stores GitHub repo as HTTPS but we authenticate via SSH key,
# convert to SSH URL so git clone/push can use GIT_SSH_COMMAND.
if [[ "${GITOPS_REPO}" =~ ^https://github\.com/([^/]+)/([^/]+?)(\.git)?/?$ ]]; then
  GITOPS_REPO="git@github.com:${BASH_REMATCH[1]}/${BASH_REMATCH[2]}.git"
fi

SAFE_WORKSPACE_ID="$(slugify "${WORKSPACE_ID}" 30)"
SAFE_USER_ID="$(slugify "${USER_ID}" 30)"
SAFE_PROJECT_NAME="$(slugify "${PROJECT_NAME}" 40)"
APPLICATION_NAME="$(slugify "${SAFE_PROJECT_NAME}-${SAFE_USER_ID}" 55)"
NAMESPACE="user-${SAFE_USER_ID}"
DEFAULT_HOST_LABEL="$(slugify "${SAFE_PROJECT_NAME}-${SAFE_WORKSPACE_ID}" 63)"
EFFECTIVE_HOST="${DEFAULT_HOST_LABEL}.${PLATFORM_DOMAIN}"
if [[ -n "${CUSTOM_DOMAIN}" ]]; then
  EFFECTIVE_HOST="${CUSTOM_DOMAIN}"
fi

export GIT_SSH_COMMAND="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no"

MAX_ATTEMPTS=5
ATTEMPT=1

while [[ "${ATTEMPT}" -le "${MAX_ATTEMPTS}" ]]; do
  WORK_DIR="$(mktemp -d)"

  cleanup() {
    cd /tmp || true
    rm -rf "${WORK_DIR}"
  }
  trap cleanup EXIT

  echo "[GitOps] Attempt ${ATTEMPT}/${MAX_ATTEMPTS}: cloning ${GITOPS_REPO}"
  git clone --branch "${GITOPS_BRANCH}" --depth 1 "${GITOPS_REPO}" "${WORK_DIR}/gitops" >/dev/null

  REPO_DIR="${WORK_DIR}/gitops"
  LEGACY_APP_ROOT="apps/${SAFE_USER_ID}/${SAFE_PROJECT_NAME}"
  NEW_APP_ROOT="apps/${SAFE_WORKSPACE_ID}/${SAFE_USER_ID}/${SAFE_PROJECT_NAME}"

  if [[ -d "${REPO_DIR}/${LEGACY_APP_ROOT}" && ! -d "${REPO_DIR}/${NEW_APP_ROOT}" ]]; then
    APP_ROOT="${LEGACY_APP_ROOT}"
    USER_ROOT="apps/${SAFE_USER_ID}"
    echo "[GitOps] Legacy layout detected, writing to ${APP_ROOT}"
  else
    APP_ROOT="${NEW_APP_ROOT}"
    USER_ROOT="apps/${SAFE_WORKSPACE_ID}/${SAFE_USER_ID}"
  fi

  NAMESPACE_FILE="${USER_ROOT}/namespace.yaml"
  PROJECT_DIR="${REPO_DIR}/${APP_ROOT}"
  VALUES_FILE="${PROJECT_DIR}/values.yaml"
  APPLICATION_FILE="${PROJECT_DIR}/application.yaml"

  mkdir -p "${PROJECT_DIR}" "${REPO_DIR}/${USER_ROOT}"

  ensure_namespace_manifest "${REPO_DIR}/${USER_ROOT}" "${NAMESPACE}"

  create_values_file "${VALUES_FILE}" "${SAFE_WORKSPACE_ID}" "${SAFE_USER_ID}" "${SAFE_PROJECT_NAME}" "${NAMESPACE}" "${FRAMEWORK}" "${IMAGE_REPOSITORY}" "${IMAGE_TAG}" "${APP_PORT}" "${PLATFORM_DOMAIN}" "${CUSTOM_DOMAIN}" "${ENV_JSON}" "${SERVICE_TYPE}"

  create_application_manifest \
    "${APPLICATION_FILE}" \
    "${APPLICATION_NAME}" \
    "default" \
    "${NAMESPACE}" \
    "${GITOPS_REPO}" \
    "${GITOPS_BRANCH}" \
    "${APP_ROOT}/values.yaml" \
    "${INFRA_REPO}" \
    "${INFRA_REVISION}" \
    "${CHART_PATH}" \
    "${SAFE_PROJECT_NAME}"

  if [[ "${SERVICE_TYPE}" == "gateway" ]]; then
    force_https_ingress "${VALUES_FILE}" || {
      echo "Unable to force HTTPS ingress mode in ${VALUES_FILE}." >&2
      exit 1
    }
  fi

  if [[ "${OPERATION}" == "rollback" ]]; then
    COMMIT_MESSAGE="rollback(${SAFE_USER_ID}/${SAFE_PROJECT_NAME}): image=${IMAGE_REPOSITORY}:${IMAGE_TAG} build=${BUILD_NUMBER} sha=${COMMIT_SHA}"
  else
    COMMIT_MESSAGE="deploy(${SAFE_USER_ID}/${SAFE_PROJECT_NAME}): image=${IMAGE_REPOSITORY}:${IMAGE_TAG} build=${BUILD_NUMBER} sha=${COMMIT_SHA}"
  fi

  set +e
  commit_and_push "${REPO_DIR}" "${GITOPS_BRANCH}" "${APP_ROOT}" "${NAMESPACE_FILE}" "${COMMIT_MESSAGE}"
  RESULT=$?
  set -e

  if [[ "${RESULT}" -eq 0 ]]; then
    trap - EXIT
    cleanup
    exit 0
  fi

  if [[ "${RESULT}" -eq 10 ]]; then
    trap - EXIT
    cleanup
    exit 0
  fi

  echo "[GitOps] Push conflict detected, retrying..."
  ATTEMPT=$((ATTEMPT + 1))
  trap - EXIT
  cleanup
  sleep 2
done

echo "Failed to update GitOps repository after ${MAX_ATTEMPTS} attempts." >&2
exit 1
