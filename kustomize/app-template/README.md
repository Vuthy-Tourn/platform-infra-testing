Reusable Kustomize microservice template for GitOps output.

The Jenkins GitOps writer renders each detected service into a concrete app folder
under the GitOps repo with this structure:

- `kustomization.yaml`
- `deployment.yaml`
- `service.yaml`
- `serviceaccount.yaml`
- `hpa.yaml`
- `ingress.yaml` for gateway services only
- `env.properties`
- `application.yaml`

This template path is kept in Argo CD `Application.spec.info` as provenance:

- `templateRepo`
- `templateRevision`
- `templatePath`

The generated Kustomize app is intentionally concrete and self-contained so each
microservice remains an independent deploy/rollback unit in GitOps.
