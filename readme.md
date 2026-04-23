# platform-infra

Production-grade CI/CD building blocks for a multi-tenant deployment platform (Vercel/Render style).

## What this repo provides

- Single generic Jenkins pipeline for the supported microservice frameworks
- Automatic framework detection and Dockerfile fallback templates
- Spring Boot Docker templates auto-detect the Java version from the app build files
- App container ports are framework-aware:
  - `nextjs` / `nodejs` -> `3000`
  - `react` / `static` -> `80`
  - `springboot-*` / `java-*` -> `8080`
  - `APP_PORT` still works as an explicit override when you need a custom port
- App health checks are framework-aware too:
  - Spring Boot and Java apps use TCP startup/readiness/liveness probes
  - Web and API apps keep HTTP probes on `/`
- Docker image build/push with immutable version tag format:
  - `<userId>-<buildNumber>-<commitSHA>`
- GitOps update script that writes only deployment state to the GitOps repo:
  - `apps/<workspaceId>/<userId>/<projectName>/values.yaml`
  - `apps/<workspaceId>/<userId>/<projectName>/application.yaml`
  - `apps/<workspaceId>/<userId>/namespace.yaml`
  - runtime env vars are passed as `ENV_JSON` and written into generated Helm values
- Argo CD application manifests that reference the Helm chart from this infra repo instead of copying the chart into the GitOps repo
- Helm templates for Deployment, Service, Ingress, and HPA
- Platform-managed Java Docker templates:
  - `Dockerfile.gradle`
  - `Dockerfile.maven`
- Platform-managed web Docker templates:
  - `Dockerfile.nodejs`
  - `Dockerfile.static`
- Conflict-safe GitOps pushes with retry logic
- Tenant bootstrap helper for namespace + registry secret replication

## Supported frameworks

- Node.js (`nextjs`, `react`, `nodejs`)
- Java (`springboot-maven`, `springboot-gradle`, `java-maven`, `java-gradle`)
- Static sites (`static`)

## Key files

- `jenkins/Jenkinsfile`
- `jenkins/scripts/detect-framework.sh`
- `jenkins/scripts/generate-dockerfile.sh`
- `jenkins/scripts/update-gitops.sh`
- `kubernetes/bootstrap-tenant-namespace.sh`
- `kubernetes/registry-secret.yaml`
- `docker/dockerfiles/*`
- `kustomize/app-template/*`

## Jenkins credentials required

- `infra-repo-url` (Secret text)
- `infra-repo-creds` (Git credentials)
- `registry-repository` (Secret text, e.g. `registry.example.com/platform`)
- `registry-credentials` (Username/Password)
- `gitops-repo-url` (Secret text, SSH URL)
- `gitops-ssh` (SSH private key)

## Pipeline inputs

- `REPO_URL`
- `BRANCH`
- `USER_ID`
- `PROJECT_NAME`
- `APP_PORT`
- `ENV_JSON` (optional JSON array of runtime env vars, manual form or `.env` import)
- `PLATFORM_DOMAIN`
- `GITOPS_BRANCH`
- `REPO_CREDENTIALS_ID` (optional)

## Local validation

```bash
bash -n jenkins/scripts/detect-framework.sh
bash -n jenkins/scripts/generate-dockerfile.sh
bash -n jenkins/scripts/update-gitops.sh
bash -n kubernetes/bootstrap-tenant-namespace.sh
```
