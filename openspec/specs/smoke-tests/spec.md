# smoke-tests Specification

## Purpose
TBD - created by archiving change add-deployment-smoke-tests. Update Purpose after archive.
## Requirements
### Requirement: API Health Check
The smoke-test script SHALL verify the Mealie API is reachable and responding.

#### Scenario: API responds with version info
- **WHEN** the smoke-test script runs against a deployed Mealie instance
- **THEN** `GET /api/app/about` returns HTTP 200
- **AND** the JSON response contains a `version` field

#### Scenario: API unreachable
- **WHEN** the API is not reachable at the configured URL
- **THEN** the script prints a clear connection-failure message
- **AND** exits with a non-zero status

### Requirement: Authentication Smoke Test
The smoke-test script SHALL verify authentication works using configured test credentials.

#### Scenario: Successful login
- **WHEN** the script POSTs credentials to `/api/auth/token`
- **THEN** the response contains a non-empty `access_token`
- **AND** the script stores the token for subsequent checks

#### Scenario: Authentication failure
- **WHEN** the credentials are invalid or the auth endpoint is broken
- **THEN** the script reports the failing step and the HTTP status
- **AND** exits with a non-zero status

### Requirement: Database Connectivity Check
The smoke-test script SHALL verify Mealie can read user data from its PostgreSQL database.

#### Scenario: Authenticated user lookup succeeds
- **WHEN** the script calls `GET /api/users/self` with the access token
- **THEN** the response is HTTP 200
- **AND** contains an `email` field matching the authenticated user

#### Scenario: Database unreachable
- **WHEN** Mealie cannot reach PostgreSQL
- **THEN** the authenticated call fails (non-2xx) and the script reports the failure
- **AND** exits with a non-zero status

### Requirement: Environment-Agnostic Execution
The smoke-test script SHALL run against any reachable Mealie URL without code changes.

#### Scenario: Local deployment via port-forward
- **WHEN** the script is invoked with `http://localhost:9000` (the Tilt port-forward)
- **THEN** it runs all checks against the local instance

#### Scenario: Remote deployment via ingress
- **WHEN** the script is invoked with `https://mealie.jenkinz.net`
- **THEN** `curl` validates the TLS certificate by default
- **AND** all checks run against the remote instance

### Requirement: Credential Override
The smoke-test script SHALL allow credentials to be overridden via environment variables.

#### Scenario: Override via env vars
- **WHEN** `SMOKE_EMAIL` and `SMOKE_PASSWORD` are set
- **THEN** the script uses those values instead of the defaults for the auth check

### Requirement: Justfile Recipes
The repository SHALL expose justfile recipes that wrap the script for common cases.

#### Scenario: Run against local Tilt stack
- **WHEN** a developer runs `just smoke`
- **THEN** the script runs against `http://localhost:9000` with the seeded test credentials

#### Scenario: Run against an arbitrary URL
- **WHEN** a developer runs `just smoke-url https://example.com`
- **THEN** the script runs against the provided URL

### Requirement: Exit Status and Output
The smoke-test script SHALL produce clear, actionable output.

#### Scenario: All checks pass
- **WHEN** every check succeeds
- **THEN** the script prints a one-line-per-check summary with pass markers
- **AND** exits with status 0

#### Scenario: Any check fails
- **WHEN** any check fails
- **THEN** the script prints which check failed, the relevant HTTP status or error,
  and the raw response body
- **AND** exits with a non-zero status

