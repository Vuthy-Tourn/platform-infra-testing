# Jenkins-Only Testing Guide

This copy is for Jenkins-first validation before you have a Kubernetes cluster.

What you can validate here:

- repository checkout
- framework detection
- Dockerfile generation
- Docker build
- image push to registry
- microservice deployment ordering
- optional GitOps file generation

What you cannot validate yet:

- Argo CD sync
- Helm rendering inside a live cluster
- namespace readiness
- pod startup and readiness probes

## Recommended Jenkins jobs for this test repo

Create two pipeline jobs from SCM:

1. `deploy-service-test`
   Script path: `jenkins/Jenkinsfile`

2. `deploy-microservices-test`
   Script path: `jenkins/Jenkinsfile-microservices`

This test copy is wired so the orchestrator defaults to calling `deploy-service-test`.

## Recommended first test order

1. Run `deploy-service-test` with one repository.
2. Confirm build and push work.
3. Keep `ENABLE_GITOPS_UPDATE=false` for the first run.
4. After that succeeds, run `deploy-microservices-test`.
5. Only enable GitOps update when you are ready to test writing deployment state.

## Jenkins credentials required

- `infra-repo-url` as Secret text
- `infra-repo-creds` as Git credentials
- `registry-repository` as Secret text
- `registry-credentials` as Username with password
- `gitops-repo-url` as Secret text
- `gitops-ssh` as SSH private key

If your user repositories are private, also create a credential that can be passed in `REPO_CREDENTIALS_ID`.

## Single-service sample parameters

Use these in `deploy-service-test`:

- `REPO_URL`: your service repository URL
- `BRANCH`: `main`
- `USER_ID`: `test-user`
- `WORKSPACE_ID`: `micro-test`
- `PROJECT_NAME`: `api-gateway`
- `APP_PORT`: `8080`
- `FRAMEWORK`: blank to auto-detect
- `ENV_JSON`: `[]`
- `SERVICE_TYPE`: `gateway`
- `PLATFORM_DOMAIN`: `apps.example.com`
- `GITOPS_BRANCH`: `main`
- `ENABLE_TRIVY_SCAN`: `true`
- `ENABLE_GITOPS_UPDATE`: `false`
- `ROLLBACK_MODE`: `false`

## Microservices sample parameters

Use these in `deploy-microservices-test`:

- `USER_ID`: `test-user`
- `WORKSPACE_ID`: `micro-test`
- `PLATFORM_DOMAIN`: `apps.example.com`
- `GITOPS_BRANCH`: `main`
- `SERVICE_JOB_NAME`: `deploy-service-test`
- `ENABLE_TRIVY_SCAN`: `true`
- `ENABLE_GITOPS_UPDATE`: `false`
- `ROLLBACK_MODE`: `false`
- `SERVICES_JSON`: paste the sample from `jenkins/examples/services.sample.json`

## Sample payload files

- `jenkins/examples/services.sample.json`

Start with the sample and replace the repository URLs with real ones you can access from Jenkins.
