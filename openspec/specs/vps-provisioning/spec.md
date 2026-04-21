# vps-provisioning Specification

## Purpose
TBD - created by archiving change provision-hetzner-k3s. Update Purpose after archive.
## Requirements
### Requirement: Reproducible VPS Creation
The repository SHALL provide a single command that provisions the production VPS from
scratch using infrastructure-as-code (cloud-init) and the `hcloud` CLI.

#### Scenario: Fresh provisioning
- **WHEN** a developer runs `TS_AUTHKEY=… just vps-create` with no existing
  `mealie-prod` server
- **THEN** a Hetzner CX33 is provisioned in the configured region
- **AND** the cloud-init config from `infra/cloud-init.yaml` runs on first boot
- **AND** the public IPv4 of the new server is printed to stdout

#### Scenario: Missing Tailscale auth key
- **WHEN** a developer runs `just vps-create` without `TS_AUTHKEY` set
- **THEN** the command exits non-zero with a message naming the missing variable
- **AND** no server is created

#### Scenario: Idempotent re-run
- **WHEN** a developer runs `just vps-create` against a project that already has a
  `mealie-prod` server
- **THEN** no new server is created
- **AND** the command exits 0 with a message indicating the server already exists

### Requirement: Hardened Host Defaults
The provisioned VPS SHALL enforce baseline hardening before any application workload
is deployed.

#### Scenario: Firewall allows only required public ports
- **WHEN** the cloud-init run completes
- **THEN** UFW is enabled with a default-deny inbound policy
- **AND** inbound traffic is allowed only on TCP 22, 80, and 443

#### Scenario: Kubernetes API is not exposed to the internet
- **WHEN** an external host attempts `curl https://<public-ip>:6443`
- **THEN** the connection fails (UFW drops the packet)

#### Scenario: SSH is key-only
- **WHEN** a user attempts SSH password authentication to the VPS
- **THEN** the connection is rejected
- **AND** only SSH public-key authentication is accepted

#### Scenario: Non-root admin user
- **WHEN** a developer runs `just vps-ssh`
- **THEN** the session authenticates as a non-root user (`andy`) with passwordless
  `sudo`
- **AND** direct SSH login as `root` is disabled

### Requirement: VPS Joins the Tailnet on First Boot
The provisioned VPS SHALL install Tailscale and join the configured tailnet during
cloud-init, so ops traffic (kubectl, future CI) travels over the private mesh
instead of the public internet.

#### Scenario: Tailscale auto-join
- **WHEN** cloud-init completes
- **THEN** `tailscaled` is running and enabled
- **AND** the node is visible in the Tailscale admin console with hostname
  `mealie-prod`
- **AND** `tailscale ip -4` on the VPS returns a `100.x.x.x` tailnet address

### Requirement: K3s Ready for Workloads
The provisioned VPS SHALL come up with a working single-node K3s cluster with the K3s
default bundled components available.

#### Scenario: K3s service is active
- **WHEN** the cloud-init run completes on the VPS
- **THEN** `systemctl is-active k3s` returns `active`
- **AND** the node reports `Ready` via `kubectl get nodes`

#### Scenario: Default K3s components are running
- **WHEN** K3s has reached `Ready`
- **THEN** the `traefik`, `metrics-server`, and `local-path-provisioner` deployments
  in `kube-system` are all in `Running` status

#### Scenario: Server certificate valid for the tailnet
- **WHEN** K3s is installed
- **THEN** the server certificate's SANs include the VPS's tailnet IPv4 address and
  the short hostname `mealie-prod`
- **AND** kubectl can connect to the API using either of those names without a TLS
  mismatch error

### Requirement: Local Kubeconfig Retrieval via Tailnet
The repository SHALL provide a command that fetches the cluster kubeconfig to the
local machine with the server URL set to the VPS tailnet address.

#### Scenario: Fetch kubeconfig
- **WHEN** a developer runs `just vps-kubeconfig` against a provisioned VPS
- **THEN** a kubeconfig file is written to `~/.kube/mealie-prod.yaml` with mode `0600`
- **AND** the `server:` URL in that file uses the VPS **tailnet IPv4** (not
  `127.0.0.1` and not the public IP)

#### Scenario: Kubeconfig works from an on-tailnet laptop
- **WHEN** a developer has Tailscale connected on their laptop
- **AND** exports `KUBECONFIG=~/.kube/mealie-prod.yaml`
- **AND** runs `kubectl get nodes`
- **THEN** one node is listed in `Ready` state

#### Scenario: Kubeconfig fails off-tailnet
- **WHEN** a developer's laptop is not connected to the tailnet
- **AND** runs `kubectl get nodes` with the fetched kubeconfig
- **THEN** the request times out at the network layer (no alternate public route
  exists)

### Requirement: Documented Teardown
The repository SHALL provide a command to delete the VPS, with an explicit
confirmation step to prevent accidental destruction.

#### Scenario: Teardown requires confirmation
- **WHEN** a developer runs `just vps-destroy`
- **THEN** the command prompts the developer to type `DESTROY` to confirm
- **AND** the VPS is deleted only after confirmation
- **AND** the command exits non-zero without deleting anything if confirmation is
  not provided

### Requirement: Rebuild-From-Scratch Runbook
The repository SHALL document a step-by-step rebuild procedure so the cluster can be
recreated from scratch.

#### Scenario: Runbook exists and is discoverable
- **WHEN** a developer opens `infra/README.md`
- **THEN** the document lists the prereqs (hcloud CLI, Hetzner account/token, SSH
  key upload, Tailscale account + auth key, Tailscale on laptop), the exact `just`
  commands to run, expected timings, and sanity checks

#### Scenario: Runbook is validated end-to-end
- **WHEN** the change author executes the runbook from scratch (destroy → create →
  kubeconfig → `kubectl get nodes`)
- **THEN** the cluster reaches `Ready` within 3 minutes
- **AND** all steps in the runbook succeed without manual intervention beyond the
  documented prereqs

