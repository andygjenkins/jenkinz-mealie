# Tasks: Provision Hetzner VPS + Install K3s on a Tailnet

## 1. Prereqs (one-time, documented in infra/README.md)

### Hetzner Cloud
- [x] 1.1 Create Hetzner Cloud account + project (`mealie-prod`).
- [x] 1.2 Generate an API token with **read + write** scope; save to 1Password.
- [x] 1.3 `brew install hcloud`; `hcloud context create mealie-prod`.
- [x] 1.4 `hcloud ssh-key create --name andy-laptop --public-key-from-file ~/.ssh/id_ed25519.pub`.

### Tailscale
- [x] 1.5 Sign up for Tailscale (free personal plan).
- [x] 1.6 `brew install --cask tailscale`; install + sign in on the laptop.
- [x] 1.7 Generate a **reusable, non-ephemeral** auth key at https://login.tailscale.com/admin/settings/keys. Save to 1Password as `Tailscale – mealie-prod auth key`.

## 2. cloud-init config
- [x] 2.1 `infra/cloud-init.yaml` — creates `andy` with SSH key, hardens SSH, installs UFW + Tailscale + K3s, joins tailnet, installs K3s with `--tls-san=<tailscale-ip>` and `--tls-san=mealie-prod`.
- [x] 2.2 SSH key and Tailscale auth key delivered via `envsubst` substitution of `${SSH_PUBKEY}` and `${TS_AUTHKEY}` at `just vps-create` time (neither is committed to git).

## 3. Justfile recipes (VPS lifecycle)
- [x] 3.1 `just vps-create` — idempotent guard; validates `TS_AUTHKEY` env var is set; `envsubst` renders `infra/cloud-init.yaml`; `hcloud server create` with `--user-data-from-file`. Prints public IPv4.
- [x] 3.2 `just vps-ssh` — `ssh andy@<public-ip>` (over public internet, key-only). Additional path `ssh andy@mealie-prod` works once on-tailnet.
- [x] 3.3 `just vps-kubeconfig` — SSH to VPS, read `tailscale ip -4`, fetch kubeconfig, rewrite server URL to tailnet IP, write `~/.kube/mealie-prod.yaml` mode 0600.
- [x] 3.4 `just vps-destroy` — typed `DESTROY` confirmation before `hcloud server delete`.

## 4. Documentation
- [x] 4.1 `infra/README.md` — rebuild runbook: Hetzner + Tailscale prereqs, export `TS_AUTHKEY`, create → kubeconfig → `kubectl get nodes`, day-to-day access, teardown, troubleshooting.
- [x] 4.2 Root `README.md` — Production Deployment section points at `infra/README.md`; roadmap reflects phase 3 in progress.

## 5. Verification (end-to-end)
- [x] 5.1 `TS_AUTHKEY=... just vps-create` returned in <2 minutes with a public IP.
- [x] 5.2 Tailscale admin console shows `mealie-prod` as online.
- [x] 5.3 `just vps-ssh` connects with SSH key auth.
- [x] 5.4 UFW active with only 22/80/443 open (verified implicitly by the `kubectl` timeout on public IP).
- [x] 5.5 K3s active — `kubectl get nodes` returns `Ready`.
- [x] 5.6 `tailscaled` active — tailnet IP readable on VPS, accessible from laptop.
- [x] 5.7 `just vps-kubeconfig` produced `~/.kube/mealie-prod.yaml` with the tailnet IP as server.
- [x] 5.8 `kubectl get nodes` shows one `Ready` node.
- [x] 5.9 `kubectl -n kube-system get pods` showed Traefik, metrics-server, local-path-provisioner all Running.
- [ ] 5.10 Disconnect-tailnet drill (optional follow-up).
- [x] 5.11 `just vps-create` on existing VPS reports "already exists" and exits 0 — proven during the destroy+rebuild cycle.
- [x] 5.12 `just vps-destroy` tears VPS down cleanly.
- [x] 5.13 **Full-rebuild drill** completed end-to-end (first SSH-tunnel VPS → destroyed → rebuilt with Tailscale → kubectl works).

## 6. Open decisions (resolved)
- [x] 6.1 Admin username: **`andy`**.
- [x] 6.2 Region: default **`nbg1`** (Nuremberg); overridable via `VPS_REGION`.
- [x] 6.3 kubeconfig mode on VPS: **`0644`**. File only reachable from an authenticated SSH session; UFW blocks 6443 externally; Tailscale-only kubectl reach.
- [x] 6.4 Access-plane choice: **Tailscale tailnet** (not SSH tunnel). Standard self-hosted pattern in 2026; zero-friction day-2 once `tailscale up` is running on laptop.
