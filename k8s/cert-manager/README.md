# DNS + TLS Runbook

End-to-end flow for getting public HTTPS on `*.jenkinz.net`: migrate DNS from
Porkbun to Cloudflare, install cert-manager, and prove DNS-01 issuance works with
Let's Encrypt.

After this, issuing a cert for any `foo.jenkinz.net` subdomain is as simple as
referencing `letsencrypt-prod` in an Ingress/Certificate resource.

## One-time prerequisites

### 1. Migrate DNS from Porkbun to Cloudflare (~15 min, no downtime if careful)

1. **Inventory existing Porkbun DNS records.** Porkbun → `jenkinz.net` → DNS. Note
   every record. Pay close attention to mail records (MX / SPF / DKIM / DMARC) and
   any subdomains already in use.

2. **Sign up at [cloudflare.com](https://www.cloudflare.com)** (free plan is fine).
   Add site `jenkinz.net`. Cloudflare auto-scans your current DNS. Review the
   scanned records carefully — add anything it missed.

3. **Lower Porkbun TTLs to 300s** and wait ~15 min. Speeds up the nameserver flip.

4. **Change nameservers at Porkbun:** Porkbun → `jenkinz.net` → Edit Nameservers.
   Paste the two `*.ns.cloudflare.com` names that Cloudflare showed you. Save.

5. **Wait for propagation** — usually <30 min, max 24h. Verify with:
   ```bash
   dig NS jenkinz.net @1.1.1.1
   # should show both cloudflare NS records
   ```

6. In Cloudflare → **SSL/TLS → Overview** → set encryption mode to **Full (strict)**.

7. In Cloudflare → **DNS** → **Add record**:
   - Type: `A`
   - Name: `mealie`
   - IPv4: `<your VPS public IP>` (get from `hcloud server ip mealie-prod`)
   - **Proxy status: Proxied (orange cloud)**
   - TTL: Auto
   Verify:
   ```bash
   dig A mealie.jenkinz.net @1.1.1.1
   # should return a Cloudflare IP (e.g., 104.21.x.x), not the VPS IP
   ```

### 2. Create a scoped Cloudflare API token (~2 min)

Cloudflare → profile icon (top-right) → **My Profile** → **API Tokens** →
**Create Token** → **Create Custom Token**:

- **Name**: `jenkinz.net DNS-01 (cert-manager)`
- **Permissions**:
  - `Zone` / `Zone` / `Read` — on *All zones* (required for cert-manager to list zones)
  - `Zone` / `DNS` / `Edit` — on *Specific zone* → `jenkinz.net`
- **Client IP Address Filtering**: none (cert-manager runs from the VPS, IP rotates)
- **TTL**: 365 days (set a calendar reminder to rotate)
- Click **Continue to summary** → **Create Token**

Copy the token immediately (it's only shown once). Save to 1Password as
`Cloudflare – jenkinz.net DNS-01 token`.

## Bootstrap

From the repo root, with kubectl pointed at the prod cluster
(`export KUBECONFIG=~/.kube/mealie-prod.yaml` and Tailscale up):

```bash
# Export the token from 1Password (or paste manually):
export CF_API_TOKEN="<the Cloudflare API token>"

# Install cert-manager, create the Cloudflare secret, apply both ClusterIssuers.
just tls-bootstrap
```

Expected ~60s. At the end:

```bash
kubectl -n cert-manager get pods
# cert-manager / cert-manager-cainjector / cert-manager-webhook → all Running 1/1

kubectl get clusterissuers
# letsencrypt-staging   True    ...
# letsencrypt-prod      True    ...
```

If either issuer is not `Ready: True`, the Cloudflare token is most likely
wrong-scoped. Check with:

```bash
kubectl describe clusterissuer letsencrypt-staging
```

## Prove it works end-to-end

```bash
just tls-test
```

This applies `test-certificate.yaml` (a staging cert for `test.jenkinz.net`), polls
every 10s for `Ready: True`, then deletes the Certificate. Expected ~60-120s total.

On success you'll see something like:

```
certificate.cert-manager.io/tls-test created
waiting for cert Ready...  attempt 1/18
waiting for cert Ready...  attempt 2/18
tls-test is Ready.
certificate.cert-manager.io "tls-test" deleted
```

If it fails, run `kubectl -n default describe cert tls-test` and look at the events
to see which step failed. Common issues below.

## Day-to-day: issuing a real cert

Just annotate the Ingress or use a Certificate resource pointing at
`letsencrypt-prod`. Phase 5 will do this for `mealie.jenkinz.net`.

## Troubleshooting

**`just tls-bootstrap` fails with "CF_API_TOKEN is not set"**
→ You forgot `export CF_API_TOKEN=...`. Grab from 1Password and retry.

**ClusterIssuer not `Ready: True`**
→ `kubectl describe clusterissuer letsencrypt-staging`. Usually the Cloudflare
token scope is wrong (missing `Zone:Read`) or expired. Regenerate and re-run
`just tls-bootstrap`.

**`just tls-test` Certificate stuck in `False` / `DoesNotExist`**
→ `kubectl -n default describe cert tls-test` → look at the Order events. Most
common failures:
- **DNS-01 propagation timeout**: Cloudflare DNS is fast, but if cert-manager polls
  before the `_acme-challenge` TXT record is visible to LE's resolvers, it retries.
  Usually self-corrects within another minute.
- **Token lacks `DNS:Edit` on `jenkinz.net`**: re-scope the token.
- **Rate limit hit on LE production**: `tls-test` uses staging, so this shouldn't
  happen — but if you've been manually testing against prod, you'll see
  `too many failed authorizations`. Wait 1 hour and reuse the staging issuer.

**Cloudflare proxy returns 521 (origin unreachable) after cert is issued**
→ Traefik isn't listening on 443, or UFW is blocking. Check:
`kubectl -n kube-system get svc traefik` (should have an ExternalIP / LoadBalancer
type and ports 80/443); on the VPS, `sudo ufw status` should allow 443.

**Lost the Cloudflare API token**
→ Regenerate in Cloudflare, update 1Password, re-run:
```bash
CF_API_TOKEN=<new> just tls-bootstrap   # re-applies the Secret
```
