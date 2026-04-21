# TLS Issuance Specification

## ADDED Requirements

### Requirement: Authoritative DNS at Cloudflare
The `jenkinz.net` zone SHALL be served by Cloudflare nameservers so that DNS-01 ACME
challenges and Cloudflare's edge services (proxy, WAF, analytics) are available.

#### Scenario: NS records point at Cloudflare
- **WHEN** a resolver queries `NS jenkinz.net`
- **THEN** the response lists two `*.ns.cloudflare.com` nameservers

#### Scenario: Mealie subdomain proxied by Cloudflare
- **WHEN** `A mealie.jenkinz.net` is resolved
- **THEN** the returned address is a Cloudflare edge IP (proxied), not the VPS
  origin IPv4

### Requirement: cert-manager Installed and Healthy
The cluster SHALL have cert-manager installed in a dedicated namespace with its CRDs
bundled, ready to process Certificate resources.

#### Scenario: Bootstrap installs cert-manager
- **WHEN** a developer runs `just tls-bootstrap`
- **THEN** the `cert-manager` namespace exists
- **AND** cert-manager's controller, webhook, and cainjector pods are all `Running`
  and `Ready`

#### Scenario: Idempotent re-run
- **WHEN** a developer re-runs `just tls-bootstrap` against a cluster where
  cert-manager is already installed
- **THEN** the command completes without errors
- **AND** no cert-manager pods are recreated (Helm upgrade is a no-op)

### Requirement: Cloudflare DNS-01 Credentials
The cluster SHALL hold a scoped Cloudflare API token (not the deprecated Global
Key) as a Kubernetes Secret in the `cert-manager` namespace, sourced from
1Password at bootstrap time.

#### Scenario: Secret exists with expected shape
- **WHEN** `kubectl get secret cloudflare-api-token -n cert-manager -o yaml` is run
- **THEN** the secret contains exactly one key, `api-token`, with the Cloudflare
  API token

#### Scenario: Bootstrap fails fast without the token
- **WHEN** `just tls-bootstrap` runs without `CF_API_TOKEN` set
- **THEN** the command exits non-zero with a message naming the missing env var
- **AND** no Helm install / kubectl apply side effects occur

### Requirement: Let's Encrypt ClusterIssuers
Two ClusterIssuer resources SHALL exist so that workloads can request certs against
either the Let's Encrypt staging or production environment.

#### Scenario: Both issuers are present and Ready
- **WHEN** `kubectl get clusterissuers` is run
- **THEN** `letsencrypt-staging` and `letsencrypt-prod` are both listed
- **AND** each has status condition `Ready: True`

#### Scenario: Issuers use Cloudflare DNS-01
- **WHEN** the ClusterIssuer manifests are inspected
- **THEN** each uses the `dns01` solver with `cloudflare.apiTokenSecretRef` pointing
  at the `cloudflare-api-token` secret in `cert-manager`
- **AND** the solver selector restricts to the `jenkinz.net` zone

### Requirement: End-to-End Cert Issuance Proven
The repository SHALL provide a self-contained test that proves DNS-01 issuance
works end-to-end without committing to a production subdomain.

#### Scenario: Test cert is issued and cleaned up
- **WHEN** a developer runs `just tls-test`
- **THEN** a staging Certificate for `test.jenkinz.net` is created
- **AND** it reaches status condition `Ready: True` within 3 minutes
- **AND** the Certificate and its resulting Secret are deleted by the recipe on
  completion

### Requirement: Cloudflare TLS in Full (Strict) Mode
The Cloudflare zone SHALL be configured for Full (strict) TLS so traffic between
Cloudflare and the origin uses the Let's Encrypt cert (no self-signed / flexible
fallback).

#### Scenario: Cloudflare SSL/TLS setting
- **WHEN** the Cloudflare dashboard → SSL/TLS → Overview for `jenkinz.net` is
  inspected
- **THEN** the encryption mode is set to "Full (strict)"

### Requirement: Runbook for DNS + TLS Setup
A runbook SHALL document the full flow: DNS migration, Cloudflare API token
creation, bootstrap, verification, and common troubleshooting.

#### Scenario: Runbook exists and is complete
- **WHEN** a developer opens `k8s/cert-manager/README.md`
- **THEN** the document lists: Porkbun → Cloudflare NS switch, Cloudflare API token
  scopes, the exact `just` commands to run, expected timings, and troubleshooting
  for the most common failures (DNS-01 propagation, rate limits, stale tokens).
