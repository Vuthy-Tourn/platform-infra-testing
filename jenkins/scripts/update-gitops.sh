#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

usage() {
  cat <<USAGE
Usage: update-gitops.sh \
  --gitops-repo <repo-url> \
  --gitops-branch <branch> \
  --gitops-workdir <path> \
  --infra-repo <repo-url> \
  --infra-revision <revision> \
  --chart-path <path> \
  --ssh-key <path> \
  --skip-push <true|false> \
  --operation <deploy|rollback|destroy> \
  --workspace-id <workspace-id> \
  --user-id <user-id> \
  --project-name <stack-name> \
  --platform-domain <domain> \
  --services-json <json-array> \
  --commit-sha <sha> \
  --build-number <build-number>

Legacy single-service arguments are still accepted and will be wrapped into a
single-item workspace stack:
  --custom-domain <domain>
  --env-json <json-array>
  --image-repository <repository>
  --image-tag <tag>
  --app-port <port>
  --framework <framework>
  --service-type <gateway|internal|registry>
  --sync-wave <number>
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

copy_chart_template() {
  local source_dir="$1"
  local target_dir="$2"

  if [[ ! -d "${source_dir}" ]]; then
    echo "Chart template source directory not found: ${source_dir}" >&2
    exit 1
  fi

  rm -rf "${target_dir}"
  mkdir -p "$(dirname "${target_dir}")"
  cp -R "${source_dir}" "${target_dir}"
}

relative_path() {
  local from_dir="$1"
  local to_dir="$2"

  python3 - "$from_dir" "$to_dir" <<'PY'
import os
import sys

print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY
}

create_workspace_kustomization() {
  local file="$1"
  local namespace="$2"
  local release_name="$3"
  local chart_home="$4"

  cat > "${file}" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${namespace}
resources:
  - namespace.yaml
helmGlobals:
  chartHome: ${chart_home}
helmCharts:
  - name: app-template
    releaseName: ${release_name}
    valuesFile: values.yaml
YAML
}

create_empty_kustomization() {
  local file="$1"

  cat > "${file}" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
YAML
}

create_namespace_manifest() {
  local file="$1"
  local namespace="$2"
  local safe_user_id="$3"
  local safe_workspace_id="$4"

  cat > "${file}" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${namespace}
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
  labels:
    app.kubernetes.io/managed-by: argocd
    platform.devops/user-namespace: "true"
    platform.devops/user-id: "${safe_user_id}"
    platform.devops/workspace-id: "${safe_workspace_id}"
YAML
}

create_values_file() {
  local values_file="$1"
  local workspace_id="$2"
  local user_id="$3"
  local namespace="$4"
  local project_name="$5"
  local platform_domain="$6"
  local services_json="$7"

  python3 - "$values_file" "$workspace_id" "$user_id" "$namespace" "$project_name" "$platform_domain" "$services_json" <<'PY'
import json
import re
import sys

values_file, workspace_id, user_id, namespace, project_name, platform_domain, raw_services = sys.argv[1:8]

def slugify(raw: str, max_len: int = 40) -> str:
    normalized = re.sub(r'[^a-z0-9-]+', '-', raw.strip().lower())
    normalized = re.sub(r'-{2,}', '-', normalized).strip('-')
    normalized = normalized or "x"
    return normalized[:max_len]

def default_container_port(framework: str) -> int:
    framework = (framework or "").strip()
    if framework in {"springboot-maven", "springboot-gradle", "java-maven", "java-gradle"}:
        return 8080
    if framework in {"nextjs", "nodejs"}:
        return 3000
    if framework in {"react", "static"}:
        return 80
    return 8080

def probe_mode(framework: str) -> str:
    framework = (framework or "").strip()
    if framework in {"springboot-maven", "springboot-gradle", "java-maven", "java-gradle"}:
        return "tcp"
    return "http"

def startup_probe_enabled(framework: str) -> bool:
    framework = (framework or "").strip()
    return framework in {"springboot-maven", "springboot-gradle", "java-maven", "java-gradle"}

def sanitize_port(value, framework: str) -> int:
    default_port = default_container_port(framework)
    raw = str(value or "").strip()
    if not raw:
        return default_port
    try:
        return int(raw)
    except ValueError:
        return default_port

try:
    services = json.loads(raw_services)
except Exception:
    services = []

if not isinstance(services, list) or not services:
    raise SystemExit("SERVICES_JSON must be a non-empty JSON array.")

lines = [
    "workspace:",
    f'  id: "{workspace_id}"',
    f'  userId: "{user_id}"',
    f'  namespace: "{namespace}"',
    f'  domain: "{platform_domain}"',
    "",
    "imagePullSecrets:",
    '  - name: "registry-secret"',
    "",
    "defaults:",
    "  replicaCount: 1",
    "  image:",
    '    pullPolicy: "IfNotPresent"',
    "  resources:",
    "    requests:",
    '      cpu: "100m"',
    '      memory: "128Mi"',
    "    limits:",
    '      cpu: "500m"',
    '      memory: "512Mi"',
    "  autoscaling:",
    "    enabled: true",
    "    minReplicas: 1",
    "    maxReplicas: 4",
    "    targetCPUUtilizationPercentage: 70",
    "  nodeSelector: {}",
    "  tolerations: []",
    "  affinity: {}",
    "",
    "services:",
]

for svc in services:
    if not isinstance(svc, dict):
        continue

    name = str(svc.get("name") or "").strip()
    if not name:
        continue

    framework = str(svc.get("framework") or "").strip() or "nodejs"
    service_type = str(svc.get("serviceType") or "internal").strip() or "internal"
    container_port = sanitize_port(svc.get("appPort"), framework)
    service_port = sanitize_port(svc.get("servicePort"), framework) if svc.get("servicePort") else container_port
    image_repository = str((svc.get("image") or {}).get("repository") or svc.get("imageRepository") or "").strip()
    image_tag = str((svc.get("image") or {}).get("tag") or svc.get("imageTag") or "").strip()
    if not image_repository or not image_tag:
        raise SystemExit(f"Service '{name}' is missing image repository or tag.")

    custom_domain = str(svc.get("customDomain") or "").strip()
    host = custom_domain or f"{slugify(project_name, 24)}-{slugify(name, 24)}-{workspace_id}.{platform_domain}"
    env_json = str(svc.get("envJson") or "[]").strip() or "[]"
    sync_wave = int(svc.get("syncWave") or 0)
    p_mode = probe_mode(framework)
    startup_enabled = startup_probe_enabled(framework)
    expose_public = svc.get("exposePublic")
    if expose_public is None:
        expose_public = service_type in {"gateway", "frontend"}
    ingress_enabled = bool(expose_public)
    primary_public = svc.get("primaryPublic")
    if primary_public is None:
        primary_public = False

    lines.extend([
        f'  - name: "{slugify(name, 63)}"',
        f'    framework: "{framework}"',
        f'    serviceType: "{service_type}"',
        f"    exposePublic: {'true' if ingress_enabled else 'false'}",
        f"    primaryPublic: {'true' if primary_public and ingress_enabled else 'false'}",
        f'    syncWave: {sync_wave}',
        "    replicaCount: 1",
        f"    containerPort: {container_port}",
        f"    servicePort: {service_port}",
        f'    host: "{host}"',
        "    image:",
        f'      repository: "{image_repository}"',
        f'      tag: "{image_tag}"',
        '      pullPolicy: "IfNotPresent"',
        "    resources:",
        "      requests:",
        '        cpu: "100m"',
        '        memory: "128Mi"',
        "      limits:",
        '        cpu: "500m"',
        '        memory: "512Mi"',
        "    probes:",
        f'      mode: "{p_mode}"',
        "      startup:",
        f"        enabled: {'true' if startup_enabled else 'false'}",
        "        initialDelaySeconds: 0",
        "        periodSeconds: 5",
        "        failureThreshold: 24",
        "      readiness:",
        "        enabled: true",
        '        path: "/"',
        "        initialDelaySeconds: 10",
        "        periodSeconds: 10",
        "        failureThreshold: 3",
        "      liveness:",
        "        enabled: true",
        '        path: "/"',
        "        initialDelaySeconds: 30",
        "        periodSeconds: 15",
        "        failureThreshold: 3",
        "    autoscaling:",
        "      enabled: true",
        "      minReplicas: 1",
        "      maxReplicas: 4",
        "      targetCPUUtilizationPercentage: 70",
        "    ingress:",
        f"      enabled: {'true' if ingress_enabled else 'false'}",
        '      className: "nginx"',
        "      annotations:",
        '        cert-manager.io/cluster-issuer: "letsencrypt-prod"',
        "      tls:",
        "        enabled: true",
        '        secretName: ""',
        "    serviceAccount:",
        "      create: true",
        '      name: ""',
        "      annotations: {}",
        "    env: []",
        f"    envJson: {json.dumps(env_json)}",
    ])

with open(values_file, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
PY
}

sanitize_repo_url_for_manifest() {
  local repo_url="$1"
  echo "${repo_url}" | sed -E 's#(https?://)[^/@]+(:[^/@]*)?@#\1#'
}

create_application_manifest() {
  local application_file="$1"
  local application_name="$2"
  local project_name="$3"
  local namespace="$4"
  local gitops_repo="$5"
  local gitops_branch="$6"
  local source_path="$7"
  local infra_repo="$8"
  local infra_revision="$9"
  local chart_path="${10}"
  local operation="${11:-deploy}"
  local manifest_repo
  local allow_empty_block=""

  manifest_repo="$(sanitize_repo_url_for_manifest "${gitops_repo}")"
  if [[ "${operation}" == "destroy" ]]; then
    allow_empty_block="      allowEmpty: true"
  fi

  cat > "${application_file}" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: "${application_name}"
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "0"
  labels:
    app.kubernetes.io/managed-by: argocd
    platform.devops/project-name: "${project_name}"
spec:
  project: "default"
  destination:
    server: https://kubernetes.default.svc
    namespace: "${namespace}"
  source:
    repoURL: "${manifest_repo}"
    targetRevision: "${gitops_branch}"
    path: "${source_path}"
    kustomize: {}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
${allow_empty_block}
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
  info:
    - name: templateRepo
      value: "${infra_repo}"
    - name: templateRevision
      value: "${infra_revision}"
    - name: templatePath
      value: "${chart_path}"
YAML
}

commit_and_push() {
  local repo_dir="$1"
  local branch="$2"
  local project_path="$3"
  local shared_chart_root="$4"
  local application_path="$5"
  local commit_message="$6"

  (
    cd "${repo_dir}"
    git config user.email "jenkins@platform.local"
    git config user.name "Jenkins CI"

    git add "${project_path}" "${shared_chart_root}" "${application_path}"

    if git diff --cached --quiet; then
      echo "No GitOps changes required."
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
GITOPS_WORKDIR=""
INFRA_REPO=""
INFRA_REVISION="main"
CHART_PATH="helm/app-template"
SSH_KEY=""
SKIP_PUSH="false"
OPERATION="deploy"
WORKSPACE_ID=""
USER_ID=""
PROJECT_NAME="workspace-stack"
SERVICES_JSON=""
PLATFORM_DOMAIN=""
COMMIT_SHA=""
BUILD_NUMBER=""

# legacy single-service compatibility
CUSTOM_DOMAIN=""
ENV_JSON="[]"
IMAGE_REPOSITORY=""
IMAGE_TAG=""
APP_PORT=""
FRAMEWORK=""
SERVICE_TYPE="internal"
SYNC_WAVE="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gitops-repo) GITOPS_REPO="$2"; shift 2 ;;
    --gitops-branch) GITOPS_BRANCH="$2"; shift 2 ;;
    --gitops-workdir) GITOPS_WORKDIR="$2"; shift 2 ;;
    --infra-repo) INFRA_REPO="$2"; shift 2 ;;
    --infra-revision) INFRA_REVISION="$2"; shift 2 ;;
    --chart-path) CHART_PATH="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --skip-push) SKIP_PUSH="$2"; shift 2 ;;
    --operation) OPERATION="$2"; shift 2 ;;
    --workspace-id) WORKSPACE_ID="$2"; shift 2 ;;
    --user-id) USER_ID="$2"; shift 2 ;;
    --project-name) PROJECT_NAME="$2"; shift 2 ;;
    --platform-domain) PLATFORM_DOMAIN="$2"; shift 2 ;;
    --services-json) SERVICES_JSON="$2"; shift 2 ;;
    --commit-sha) COMMIT_SHA="$2"; shift 2 ;;
    --build-number) BUILD_NUMBER="$2"; shift 2 ;;
    --custom-domain) CUSTOM_DOMAIN="$2"; shift 2 ;;
    --env-json) ENV_JSON="$2"; shift 2 ;;
    --image-repository) IMAGE_REPOSITORY="$2"; shift 2 ;;
    --image-tag) IMAGE_TAG="$2"; shift 2 ;;
    --app-port) APP_PORT="$2"; shift 2 ;;
    --framework) FRAMEWORK="$2"; shift 2 ;;
    --service-type) SERVICE_TYPE="$2"; shift 2 ;;
    --sync-wave) SYNC_WAVE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

for required in GITOPS_REPO INFRA_REPO USER_ID PLATFORM_DOMAIN BUILD_NUMBER; do
  if [[ -z "${!required}" ]]; then
    echo "Missing required argument: ${required}" >&2
    usage
    exit 1
  fi
done

if [[ -z "${WORKSPACE_ID}" ]]; then
  WORKSPACE_ID="${USER_ID}"
fi

if [[ -z "${SERVICES_JSON}" ]]; then
  for required in PROJECT_NAME IMAGE_REPOSITORY IMAGE_TAG APP_PORT FRAMEWORK; do
    if [[ -z "${!required}" ]]; then
      echo "Missing required legacy single-service argument: ${required}" >&2
      usage
      exit 1
    fi
  done

  SERVICES_JSON="$(python3 - "$PROJECT_NAME" "$FRAMEWORK" "$APP_PORT" "$SERVICE_TYPE" "$CUSTOM_DOMAIN" "$ENV_JSON" "$IMAGE_REPOSITORY" "$IMAGE_TAG" "$SYNC_WAVE" <<'PY'
import json
import sys

print(json.dumps([{
    "name": sys.argv[1],
    "framework": sys.argv[2],
    "appPort": sys.argv[3],
    "serviceType": sys.argv[4],
    "exposePublic": sys.argv[4] in {"gateway", "frontend"},
    "primaryPublic": sys.argv[4] in {"gateway", "frontend"},
    "customDomain": sys.argv[5],
    "envJson": sys.argv[6] or "[]",
    "imageRepository": sys.argv[7],
    "imageTag": sys.argv[8],
    "syncWave": sys.argv[9] or "0",
}], separators=(",", ":")))
PY
)"
fi

if [[ "${SKIP_PUSH}" != "true" && "${SKIP_PUSH}" != "false" ]]; then
  echo "SKIP_PUSH must be 'true' or 'false'" >&2
  exit 1
fi

if [[ -n "${GITOPS_WORKDIR}" && ! -d "${GITOPS_WORKDIR}" ]]; then
  echo "GitOps workdir not found: ${GITOPS_WORKDIR}" >&2
  exit 1
fi

if [[ -z "${GITOPS_WORKDIR}" || "${SKIP_PUSH}" != "true" ]]; then
  if [[ "${GITOPS_REPO}" =~ ^https?:// ]]; then
    SSH_KEY=""
  fi

  if [[ "${GITOPS_REPO}" =~ ^git@|^ssh:// ]] && [[ ! -f "${SSH_KEY}" ]]; then
    echo "SSH key file not found: ${SSH_KEY}" >&2
    exit 1
  fi
fi

SAFE_USER_ID="$(slugify "${USER_ID}" 30)"
SAFE_WORKSPACE_ID="$(slugify "${WORKSPACE_ID}" 30)"
SAFE_PROJECT_NAME="$(slugify "${PROJECT_NAME}" 40)"
APPLICATION_NAME="$(slugify "${SAFE_PROJECT_NAME}-${SAFE_USER_ID}" 55)"
NAMESPACE="${SAFE_WORKSPACE_ID}"

if [[ -n "${GITOPS_WORKDIR}" ]]; then
  GITOPS_DIR="${GITOPS_WORKDIR}"
else
  GITOPS_DIR="$(mktemp -d)"
fi

cleanup() {
  if [[ -z "${GITOPS_WORKDIR}" && -d "${GITOPS_DIR}" ]]; then
    rm -rf "${GITOPS_DIR}"
  fi
}
trap cleanup EXIT

if [[ -z "${GITOPS_WORKDIR}" ]]; then
  if [[ "${GITOPS_REPO}" =~ ^git@|^ssh:// ]]; then
    GIT_SSH_COMMAND="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no" \
      git clone --branch "${GITOPS_BRANCH}" --depth 1 "${GITOPS_REPO}" "${GITOPS_DIR}" >/dev/null
  else
    git clone --branch "${GITOPS_BRANCH}" --depth 1 "${GITOPS_REPO}" "${GITOPS_DIR}" >/dev/null
  fi
fi

APP_ROOT="apps/${SAFE_WORKSPACE_ID}/${SAFE_USER_ID}/${SAFE_PROJECT_NAME}"
APPLICATION_ROOT="applications/${SAFE_WORKSPACE_ID}/${SAFE_USER_ID}"
APPLICATION_FILE="${GITOPS_DIR}/${APPLICATION_ROOT}/${SAFE_PROJECT_NAME}.yaml"
WORKSPACE_DIR="${GITOPS_DIR}/${APP_ROOT}"
VALUES_FILE="${WORKSPACE_DIR}/values.yaml"
KUSTOMIZATION_FILE="${WORKSPACE_DIR}/kustomization.yaml"
NAMESPACE_FILE="${WORKSPACE_DIR}/namespace.yaml"
SHARED_CHART_ROOT="templates/charts"
CHART_TARGET_DIR="${GITOPS_DIR}/${SHARED_CHART_ROOT}/app-template"
CHART_SOURCE_DIR="${INFRA_ROOT_DIR}/${CHART_PATH}"
COMMIT_MESSAGE="${OPERATION}(${SAFE_WORKSPACE_ID}/${SAFE_USER_ID}/${SAFE_PROJECT_NAME}): build=${BUILD_NUMBER}"

mkdir -p "${WORKSPACE_DIR}" "${GITOPS_DIR}/${APPLICATION_ROOT}"

if [[ "${OPERATION}" == "destroy" ]]; then
  rm -f "${VALUES_FILE}" "${NAMESPACE_FILE}"
  create_empty_kustomization "${KUSTOMIZATION_FILE}"
create_application_manifest \
  "${APPLICATION_FILE}" \
  "${APPLICATION_NAME}" \
  "${SAFE_PROJECT_NAME}" \
  "${NAMESPACE}" \
  "${GITOPS_REPO}" \
  "${GITOPS_BRANCH}" \
  "${APP_ROOT}" \
  "${INFRA_REPO}" \
  "${INFRA_REVISION}" \
  "${CHART_PATH}" \
  "${OPERATION}"
  echo "Prepared destroy plan at ${APP_ROOT}"
else
  copy_chart_template "${CHART_SOURCE_DIR}" "${CHART_TARGET_DIR}"
  create_namespace_manifest "${NAMESPACE_FILE}" "${NAMESPACE}" "${SAFE_USER_ID}" "${SAFE_WORKSPACE_ID}"
  create_values_file "${VALUES_FILE}" "${SAFE_WORKSPACE_ID}" "${SAFE_USER_ID}" "${NAMESPACE}" "${SAFE_PROJECT_NAME}" "${PLATFORM_DOMAIN}" "${SERVICES_JSON}"

  CHART_HOME_RELATIVE="$(relative_path "${WORKSPACE_DIR}" "${GITOPS_DIR}/${SHARED_CHART_ROOT}")"
  create_workspace_kustomization "${KUSTOMIZATION_FILE}" "${NAMESPACE}" "${SAFE_PROJECT_NAME}" "${CHART_HOME_RELATIVE}"
  create_application_manifest \
    "${APPLICATION_FILE}" \
    "${APPLICATION_NAME}" \
    "${SAFE_PROJECT_NAME}" \
    "${NAMESPACE}" \
    "${GITOPS_REPO}" \
    "${GITOPS_BRANCH}" \
    "${APP_ROOT}" \
    "${INFRA_REPO}" \
    "${INFRA_REVISION}" \
    "${CHART_PATH}"

  echo "Prepared workspace stack at ${APP_ROOT}"
fi

if [[ "${SKIP_PUSH}" == "true" ]]; then
  exit 0
fi

if [[ "${GITOPS_REPO}" =~ ^git@|^ssh:// ]]; then
  GIT_SSH_COMMAND="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no" \
    commit_and_push "${GITOPS_DIR}" "${GITOPS_BRANCH}" "${APP_ROOT}" "${SHARED_CHART_ROOT}" "${APPLICATION_ROOT}" "${COMMIT_MESSAGE}"
else
  commit_and_push "${GITOPS_DIR}" "${GITOPS_BRANCH}" "${APP_ROOT}" "${SHARED_CHART_ROOT}" "${APPLICATION_ROOT}" "${COMMIT_MESSAGE}"
fi
