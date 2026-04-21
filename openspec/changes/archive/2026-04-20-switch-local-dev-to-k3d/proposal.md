# Change: Switch Local Dev from Minikube to k3d

## Why

Prod will run on K3s (Hetzner CPX21). Local dev currently uses Minikube, which has
different defaults (nginx ingress addon, Docker-driver VMs, etc.). Running k3d locally
gives us direct parity with the prod orchestrator — same Traefik, same local-path-
provisioner, same K3s version semantics — and faster start/stop with no VM overhead.

## What Changes

- Install/use **k3d** (K3s in Docker) as the local cluster.
- Update `justfile` recipes: `up` creates/reuses a k3d cluster; `down`, `clean`, `stop`
  operate on it.
- Keep the **Tiltfile unchanged** where possible — it's already cluster-agnostic
  (port-forward-based, no minikube-specific calls).
- Drop `minikube addons enable ingress` from `up` — K3s ships Traefik by default.
- Disable ingress in `helm/values/dev.yaml` — dev uses Tilt's port-forward at
  `localhost:9000`; no need to create an orphan Ingress object locally.
- Update `README.md` and `LOCAL_DEV.md` to list k3d as the prereq.

## Out of Scope

- Prod provisioning (separate phase-3 change).
- Exposing services via ingress in local dev (Tilt port-forward is sufficient; if/when
  we want ingress parity locally, that's a later follow-up).

## Impact

- Affected specs: `local-dev` (new capability).
- Affected code: `justfile`, `helm/values/dev.yaml`, `README.md`, `LOCAL_DEV.md`,
  `Tiltfile` (minor if any).
- Dependencies: `k3d` CLI (installed via Homebrew). Minikube becomes optional / can be
  uninstalled.
