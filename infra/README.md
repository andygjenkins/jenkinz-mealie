# Production VPS — Rebuild-From-Scratch Runbook

The production Mealie host is a **Hetzner Cloud CX33** (Intel, 4 vCPU / 8 GB / 80 GB
SSD), provisioned from `infra/cloud-init.yaml` via the `hcloud` CLI. It joins a
**Tailscale** tailnet on first boot so `kubectl` and other ops traffic travel over a
private mesh instead of the public internet.

Default region is Nuremberg (`nbg1`); override with `VPS_REGION=<code> just vps-create`
if Hetzner reports `server location disabled` (capacity) for that region. Known EU
options, same price: `fsn1` (Falkenstein), `nbg1` (Nuremberg), `hel1` (Helsinki).

The entire VPS is destroy/rebuild — there is no in-place OS-level drift to manage.

Expected rebuild time from scratch: **< 3 minutes**.

## One-time prerequisites

### 1. Hetzner Cloud

1. Create a Hetzner Cloud account and a project named `mealie-prod`.
2. In the project → Security → API tokens → generate a **Read & Write** token. Save
   it to 1Password as `Hetzner – Mealie Prod API Token`.
3. On your laptop: `brew install hcloud` → `hcloud context create mealie-prod` (paste
   token) → `hcloud context use mealie-prod`.
4. Upload your SSH public key:
   ```bash
   hcloud ssh-key create \
     --name andy-laptop \
     --public-key-from-file ~/.ssh/id_ed25519.pub
   ```

### 2. Tailscale

1. Sign up at [tailscale.com](https://tailscale.com) (free personal plan covers up
   to 100 devices).
2. Install Tailscale on your laptop: `brew install --cask tailscale`, launch it,
   sign in. Confirm with `tailscale status`.
3. Generate a **reusable auth key** at
   [login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys):
   - Reusable: **yes** (so VPS rebuilds don't need a new key every time)
   - Ephemeral: **no** (the node should persist in the tailnet)
   - Expiry: 90 days is fine (you'll rotate the key occasionally)
4. Save the key to 1Password as `Tailscale – mealie-prod auth key`.

## Rebuild procedure

From the repo root:

```bash
# Export the Tailscale auth key from 1Password (or paste manually):
export TS_AUTHKEY="tskey-auth-..."

# 1. Provision the VPS (idempotent: no-op if mealie-prod already exists).
just vps-create

# 2. Fetch the kubeconfig (server URL uses the VPS tailnet IP).
#    Requires the VPS to have finished cloud-init — wait ~90s after vps-create.
just vps-kubeconfig

# 3. Point kubectl at the new cluster and verify.
export KUBECONFIG=~/.kube/mealie-prod.yaml
kubectl get nodes                    # 1 Ready node
kubectl -n kube-system get pods      # traefik, metrics-server, local-path-provisioner Running
```

Typical timings on a fresh run:
- `just vps-create` returns in ~30s (VPS allocation + initial boot).
- cloud-init completes ~60–90s after boot (package install, Tailscale join, K3s install).
- `just vps-kubeconfig` is instant once K3s has written `/etc/rancher/k3s/k3s.yaml`.

If `just vps-kubeconfig` fails with "No such file" or "could not read tailscale IP",
cloud-init hasn't finished — wait 30s and re-run.

## Day-to-day access

- **SSH** (over public internet, key-only): `just vps-ssh`.
- **SSH** (over Tailscale, using tailnet identity): `ssh andy@mealie-prod` or
  `tailscale ssh andy@mealie-prod`.
- **kubectl**: `export KUBECONFIG=~/.kube/mealie-prod.yaml`, then `kubectl …` as
  normal. Tailscale must be running on your laptop; if you're off-tailnet (e.g.
  Tailscale is disconnected), kubectl will time out.

## Teardown

```bash
just vps-destroy     # prompts for typed confirmation "DESTROY"
```

Deletes the VPS and its attached disk. The Tailscale node will show up as "offline"
in the admin console — you can leave it or remove it manually from
[login.tailscale.com/admin/machines](https://login.tailscale.com/admin/machines).

Application backups (phase 6) go to Backblaze B2 and are independent of VPS
lifecycle.

## What's configured on the VPS

- **OS**: Ubuntu 24.04 LTS
- **User**: `andy`, passwordless sudo, SSH key from your local `~/.ssh/id_ed25519.pub`
- **SSH**: key-only, root login disabled
- **Tailscale**: joined on first boot; hostname `mealie-prod`; `tailscale ssh` enabled
- **Firewall (UFW)**: default-deny; allow inbound 22/tcp (SSH), 80/tcp and 443/tcp
  (Traefik). **6443 (Kubernetes API) is not exposed to the internet** — it's only
  reachable via the Tailscale mesh.
- **K3s**: single-node server, cert includes SANs for the tailnet IP and `mealie-prod`,
  bundled Traefik / ServiceLB / local-path-provisioner / metrics-server
- **Packages**: `ufw`, `curl`, `ca-certificates`, `jq`

## What's NOT configured yet (future phases)

- DNS A record for `mealie.jenkinz.net` → VPS public IP (phase 4; manual step in Cloudflare).
- cert-manager + Let's Encrypt (phase 4).
- Mealie chart deploy (phase 5).
- Backup CronJob → Backblaze B2 (phase 6).
- Grafana Cloud agent (phase 8).

## Troubleshooting

**`just vps-create` fails with "TS_AUTHKEY is not set"**
→ You forgot to `export TS_AUTHKEY=...`. Grab it from 1Password and retry.

**`just vps-create` fails with "token invalid"**
→ `hcloud context use mealie-prod` then retry. The context may have expired or
you're on a different one.

**`just vps-kubeconfig` fails with "could not read tailscale IP from VPS"**
→ cloud-init hasn't finished Tailscale join yet. Wait 30s and re-run, or inspect
with `just vps-ssh` → `sudo cloud-init status --long` / `sudo journalctl -u tailscaled`.

**cloud-init didn't run / something went sideways during bootstrap**
→ `just vps-ssh` → `sudo cloud-init status --long`. Full log at
`/var/log/cloud-init-output.log`.

**`kubectl` hangs / `i/o timeout`**
→ Check your laptop's Tailscale is up (`tailscale status` should show the mealie-prod
node as online). If Tailscale is disconnected, kubectl can't reach 6443 — reconnect
in the Tailscale menubar app.

**Need to start over from a bad state**
→ `just vps-destroy && just vps-create && just vps-kubeconfig`. End-to-end rebuild
is the primary recovery mechanism.
