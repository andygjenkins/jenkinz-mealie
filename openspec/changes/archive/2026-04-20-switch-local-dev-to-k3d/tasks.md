# Tasks: Switch Local Dev from Minikube to k3d

## 1. Justfile recipes
- [x] 1.1 Update `up`: create k3d cluster `mealie-dev` if missing (idempotent), then `tilt up`. No minikube, no ingress-addon enable.
- [x] 1.2 Update `clean`: `tilt down` (best-effort) + `k3d cluster delete mealie-dev` + namespace cleanup.
- [x] 1.3 Update `stop`: `k3d cluster stop mealie-dev` (leaves cluster definition intact for next `up`).
- [x] 1.4 Keep `down` unchanged (it's just `tilt down`).

## 2. Helm values
- [x] 2.1 Add `ingress.enabled: false` to `helm/values/dev.yaml` — dev uses Tilt port-forward at localhost:9000.

## 3. Tiltfile
- [x] 3.1 Tiltfile is already cluster-agnostic (uses `ext://namespace` + `k8s_yaml(helm(...))` + port-forward). No changes needed.

## 4. Docs
- [x] 4.1 Update `README.md`: prereqs list k3d + OrbStack/Docker (not minikube); start instructions reference `just up`.
- [x] 4.2 Update `LOCAL_DEV.md`: prereqs + start instructions use k3d. Removed minikube tunnel / ingress-addon notes. Added lifecycle table.

## 5. Verification
- [x] 5.1 Fresh: `k3d cluster create mealie-dev` + `tilt up --stream` → Helm applies cleanly, pods reach Ready.
- [x] 5.2 `seed.sh` ran via Tilt `local_resource`; welcome recipe exists at `/g/jenkinz/r/welcome-to-jenkinz-mealie`.
- [x] 5.3 `just smoke` — all three checks pass (API v3.8.0, auth, DB read).
- [x] 5.4 Browser verification (Playwright) — navigated to http://localhost:9000, login page rendered, login succeeded with `changeme@example.com`/`testtest`, recipes list shows "Welcome to Jenkinz Mealie" in group `jenkinz`.
- [ ] 5.5 `just down` + `just up` cycle completes cleanly (cluster reused, not recreated). *(pending — manual verification next session)*
- [ ] 5.6 `just clean` tears everything down. *(pending — manual verification next session)*

## Notes / discoveries

- Mealie security blocks email changes for the built-in admin, so after `just seed` the login stays `changeme@example.com` (password rotated to `testtest`). Smoke-test defaults and `LOCAL_DEV.md` updated to reflect this.
- First pull of `ghcr.io/mealie-recipes/mealie:v3.8.0` onto a fresh k3d cluster takes ~3 minutes (~230 MB). Subsequent starts reuse the containerd image cache inside the k3d node.
