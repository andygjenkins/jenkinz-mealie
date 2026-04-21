# local-dev Specification

## Purpose
TBD - created by archiving change switch-local-dev-to-k3d. Update Purpose after archive.
## Requirements
### Requirement: Local Kubernetes Cluster
The local development environment SHALL provide a K3s-based Kubernetes cluster that
matches the production orchestrator.

#### Scenario: Create cluster on first `just up`
- **WHEN** a developer runs `just up` with no existing cluster
- **THEN** a k3d cluster named `mealie-dev` is created
- **AND** Tilt is launched against that cluster

#### Scenario: Reuse cluster on subsequent `just up`
- **WHEN** a developer runs `just up` and a `mealie-dev` cluster already exists
- **THEN** no new cluster is created
- **AND** Tilt is launched against the existing cluster

### Requirement: Cluster Lifecycle Recipes
The justfile SHALL provide recipes that manage the full cluster lifecycle.

#### Scenario: Stop cluster without deletion
- **WHEN** a developer runs `just stop`
- **THEN** the k3d cluster is stopped
- **AND** its Docker containers are preserved so the next `just up` starts quickly

#### Scenario: Fully tear down the environment
- **WHEN** a developer runs `just clean`
- **THEN** Tilt is stopped, the Mealie namespace is deleted, and the k3d cluster is
  deleted

### Requirement: Application Access via Port-Forward
Local dev SHALL expose Mealie at `http://localhost:9000` via Tilt's port-forward.

#### Scenario: Mealie reachable after `just up`
- **WHEN** `just up` completes and the Mealie pod is ready
- **THEN** `http://localhost:9000` returns the Mealie web UI
- **AND** `http://localhost:9000/api/app/about` returns version JSON

#### Scenario: No orphan ingress object
- **WHEN** the local chart is rendered
- **THEN** no Ingress object is created for the dev environment

### Requirement: Documentation Matches Tooling
The `README.md` and `LOCAL_DEV.md` SHALL list k3d — not Minikube — as the required
local cluster tool.

#### Scenario: README prereqs
- **WHEN** a new contributor reads `README.md`
- **THEN** the prerequisites section names k3d
- **AND** does not reference Minikube or `minikube addons`

