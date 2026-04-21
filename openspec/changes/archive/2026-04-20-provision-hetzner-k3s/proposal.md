# Change: Provision Hetzner VPS + Install K3s on a Tailnet (Phase 3)

## Why

Phase 3 of the approved plan lifts the project off `localhost` onto a real VPS. We
need a **reproducible, documented** way to stand up (and tear down) the prod host so
that:

- The cluster can be rebuilt from scratch with confidence if the node dies or the
  provider has an incident.
- Future phases (TLS, deploy, backups, monitoring) can run `kubectl` against a real
  K3s cluster from the local laptop without exposing the Kubernetes API to the
  public internet.
- The budget and SKU from `openspec/project.md` (Hetzner CX33, €6.49 + €0.50 IPv4/mo)
  are encoded as code, not tribal knowledge.

The Kubernetes API (port 6443) is kept firewalled from the internet. Access is via
**Tailscale** — the VPS joins a tailnet on first boot, and kubectl reaches K3s over
the private mesh. This is a standard pattern in the self-hosted K3s community in
2026 and avoids the SSH-tunnel-per-session friction of the earlier proposal draft.

## What Changes

- Add `infra/` directory with a cloud-init config that bootstraps the VPS:
  - non-root admin user (`andy`) with the local SSH public key installed
  - SSH hardening (password auth off, key auth only)
  - UFW firewall: allow 22/80/443, default-deny everything else (no 6443 inbound)
  - **Tailscale**: install + `tailscale up --authkey=${TS_AUTHKEY} --hostname=mealie-prod --ssh`
  - K3s server install via the stock one-liner; `--tls-san` includes the Tailscale
    IP and the `mealie-prod` MagicDNS short name so the cert is valid on the tailnet
- Add `justfile` recipes backed by Hetzner's official `hcloud` CLI:
  - `just vps-create` — provision a CX33 (default region `nbg1`, overridable via
    `VPS_REGION`) with cloud-init rendered via envsubst. Requires `TS_AUTHKEY` env
    var; fails fast with a helpful message if missing. Idempotent.
  - `just vps-destroy` — delete the VPS (requires typed confirmation).
  - `just vps-ssh` — SSH into the VPS as the admin user.
  - `just vps-kubeconfig` — fetch `/etc/rancher/k3s/k3s.yaml`, rewrite the server URL
    to the **VPS tailnet IP**, save to `~/.kube/mealie-prod.yaml`.
- Add `infra/README.md` documenting the end-to-end rebuild procedure and both
  Hetzner + Tailscale one-time prereqs.
- Update root `README.md` / `LOCAL_DEV.md` to reference `infra/README.md` for prod
  rebuild and the Production Deployment quick-reference.

## Out of Scope (deferred to later phases)

- **DNS A record** for `mealie.jenkinz.net` → VPS public IP (phase 4).
- **cert-manager / Let's Encrypt** for public HTTPS (phase 4).
- **Mealie deployment** (phase 5). The VPS ends this phase with K3s up but no
  application workload.
- **GitHub Actions deploy path** (phase 5). Likely joins the same tailnet as an
  ephemeral Tailscale node to reach `kubectl`.
- **Fail2ban / advanced host hardening** — deferred; UFW + key-only SSH + Tailscale
  mesh is adequate.
- **Hetzner snapshots / provider-level backups** — phase 6 handles application
  backups via restic → B2.
- **Multi-node / HA** — explicitly non-goal per the approved plan.

## Impact

- New capability spec: `vps-provisioning`.
- New files: `infra/cloud-init.yaml`, `infra/README.md`, justfile recipes.
- Touches: root `README.md`, `justfile`.
- New local dependencies:
  - `hcloud` CLI (`brew install hcloud`)
  - Tailscale macOS app (`brew install --cask tailscale`)
  - `jq` (already a dep)
- New cloud dependencies:
  - Hetzner Cloud account + API token (stored in 1Password; exported as
    `HCLOUD_TOKEN` env var for `hcloud` CLI use)
  - Tailscale account (free plan covers ≤100 devices) + reusable auth key (stored
    in 1Password; exported as `TS_AUTHKEY` when running `just vps-create`)
  - An SSH public key uploaded to Hetzner Cloud (referenced by name in the create
    recipe)

- Cost impact: the VPS starts billing per-hour as soon as `just vps-create` runs.
  ~€7/mo while it's up; €0 while destroyed. Tailscale is free at this scale.
