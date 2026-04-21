# Production Deployment Specification

## ADDED Requirements

### Requirement: Prod Values File
The repository SHALL provide a `helm/values/prod.yaml` that configures Mealie for
production use on the Hetzner VPS.

#### Scenario: Prod values override baseUrl, signup, persistence, ingress
- **WHEN** `helm/values/prod.yaml` is rendered
- **THEN** `baseUrl` is `https://mealie.jenkinz.net`
- **AND** `allowSignup` is `false`
- **AND** `persistence.enabled` is `true` with at least 5 Gi
- **AND** `ingress.enabled` is `true` with host `mealie.jenkinz.net` and a TLS block
- **AND** the seed Helm hook is disabled

#### Scenario: Ingress annotated for cert-manager
- **WHEN** the chart is rendered with `prod.yaml`
- **THEN** the Ingress resource has the annotation
  `cert-manager.io/cluster-issuer: letsencrypt-prod`
- **AND** the TLS block references the secret `mealie-tls` for host
  `mealie.jenkinz.net`

### Requirement: Secrets Injected at Deploy Time
Production secrets (Mealie `SECRET_KEY`, PostgreSQL password) SHALL NOT be present
in `helm/values/prod.yaml`. They SHALL be supplied as env vars to the deploy command
and injected via `helm --set`.

#### Scenario: prod.yaml contains no secret values
- **WHEN** `helm/values/prod.yaml` is inspected
- **THEN** neither `mealie.secretKey` nor `externalDatabase.password` is set to a
  non-empty value in the file

#### Scenario: Deploy fails fast without secrets
- **WHEN** `just deploy-prod` runs with `MEALIE_SECRET_KEY` or `POSTGRES_PASSWORD`
  unset
- **THEN** the command exits non-zero with a message naming the missing variable
- **AND** no Helm install / upgrade side effects occur

### Requirement: Deploy Recipe Targets the Prod Cluster
The repository SHALL provide a justfile recipe that safely targets the prod
kubeconfig.

#### Scenario: Deploy against prod kubeconfig
- **WHEN** a developer runs `just deploy-prod` with both env vars set
- **THEN** the command uses `KUBECONFIG=~/.kube/mealie-prod.yaml` regardless of the
  caller's shell `KUBECONFIG`
- **AND** runs `helm upgrade --install mealie ./helm/mealie -n mealie -f
  helm/values/prod.yaml` with the two secrets passed via `--set`

#### Scenario: Missing prod kubeconfig
- **WHEN** `~/.kube/mealie-prod.yaml` does not exist
- **THEN** the recipe exits non-zero with a message referencing `just
  vps-kubeconfig`
- **AND** no Helm action is taken

### Requirement: TLS via cert-manager on First Deploy
The first deploy of Mealie SHALL trigger cert-manager to issue a Let's Encrypt
production certificate for `mealie.jenkinz.net` via the DNS-01 solver, and Traefik
SHALL serve that cert on 443.

#### Scenario: Certificate reaches Ready
- **WHEN** Mealie's Ingress is created via `just deploy-prod`
- **THEN** a Certificate resource `mealie-tls` appears in the `mealie` namespace
- **AND** it reaches `Ready: True` within 3 minutes

#### Scenario: HTTPS returns 200
- **WHEN** the certificate is Ready
- **AND** `curl -sS -o /dev/null -w "%{http_code}" https://mealie.jenkinz.net/api/app/about`
  is executed
- **THEN** the response code is `200`
- **AND** the TLS chain validates against the public Let's Encrypt roots

### Requirement: End-to-End Smoke Test Passes Against Prod
The existing `scripts/smoke-test.sh` SHALL pass against `https://mealie.jenkinz.net`
after a successful deploy, with no special-casing.

#### Scenario: Smoke test against prod URL
- **WHEN** a developer runs `just smoke-url https://mealie.jenkinz.net` after
  deploy
- **THEN** all three checks (API health, authentication, DB-backed read) pass
- **AND** the script exits 0

### Requirement: Admin Bootstrap Is Manual
The automatic `scripts/seed.sh` flow SHALL NOT run in production on first deploy.
Admin credentials SHALL be rotated manually via the Mealie UI before the service
is shared with family.

#### Scenario: Seed is disabled in prod
- **WHEN** `helm/values/prod.yaml` is rendered
- **THEN** `seed.enabled` is `false`
- **AND** no Helm-managed seed Job is created
