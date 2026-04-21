#!/usr/bin/env bash
# Mealie deployment smoke test.
#
# Runs three checks against a Mealie deployment and exits non-zero on any failure:
#   1. API health       — GET /api/app/about returns 200 + version
#   2. Authentication   — POST /api/auth/token returns an access_token
#   3. DB-backed read   — GET /api/users/self (authenticated) returns the user's email
#
# Usage:
#   ./scripts/smoke-test.sh [BASE_URL]
#
# BASE_URL defaults to http://localhost:9000 (the Tilt port-forward).
# Override test credentials with SMOKE_EMAIL / SMOKE_PASSWORD env vars.

set -euo pipefail

BASE_URL="${1:-http://localhost:9000}"
# Mealie's built-in admin; `scripts/seed.sh` rotates the password to "testtest"
# but email changes are blocked by Mealie's security, so the email stays as the default.
EMAIL="${SMOKE_EMAIL:-changeme@example.com}"
PASSWORD="${SMOKE_PASSWORD:-testtest}"

API="${BASE_URL%/}/api"

# --- pretty output helpers --------------------------------------------------
if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'
    RED=$'\033[0;31m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
else
    GREEN=""; RED=""; BOLD=""; RESET=""
fi

pass() { printf "  %s✓%s %s\n" "$GREEN" "$RESET" "$1"; }
fail() {
    printf "  %s✗%s %s\n" "$RED" "$RESET" "$1"
    if [[ -n "${2:-}" ]]; then
        printf "    %s\n" "$2"
    fi
    if [[ -n "${3:-}" ]]; then
        printf "    response: %s\n" "$3"
    fi
    exit 1
}

printf "%sSmoke-testing Mealie at %s%s\n" "$BOLD" "$BASE_URL" "$RESET"

# --- Check 1: API health ----------------------------------------------------
ABOUT_BODY=$(mktemp)
trap 'rm -f "$ABOUT_BODY" "${TOKEN_BODY:-}" "${SELF_BODY:-}"' EXIT

ABOUT_CODE=$(curl -sS -o "$ABOUT_BODY" -w "%{http_code}" \
    --max-time 10 \
    "$API/app/about" 2>/dev/null || true)
ABOUT_CODE=${ABOUT_CODE:-000}

if [[ "$ABOUT_CODE" != "200" ]]; then
    fail "API health: GET /api/app/about" \
         "expected HTTP 200, got $ABOUT_CODE" \
         "$(cat "$ABOUT_BODY" 2>/dev/null || echo '(no body)')"
fi

VERSION=$(jq -r '.version // empty' < "$ABOUT_BODY" 2>/dev/null || true)
if [[ -z "$VERSION" ]]; then
    fail "API health: GET /api/app/about" \
         "response missing 'version' field" \
         "$(cat "$ABOUT_BODY")"
fi
pass "API health — Mealie version $VERSION"

# --- Check 2: Authentication ------------------------------------------------
TOKEN_BODY=$(mktemp)
TOKEN_CODE=$(curl -sS -o "$TOKEN_BODY" -w "%{http_code}" \
    --max-time 10 \
    -X POST "$API/auth/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "username=$EMAIL" \
    --data-urlencode "password=$PASSWORD" 2>/dev/null || true)
TOKEN_CODE=${TOKEN_CODE:-000}

if [[ "$TOKEN_CODE" != "200" ]]; then
    fail "Authentication: POST /api/auth/token" \
         "expected HTTP 200, got $TOKEN_CODE (user: $EMAIL)" \
         "$(cat "$TOKEN_BODY")"
fi

TOKEN=$(jq -r '.access_token // empty' < "$TOKEN_BODY" 2>/dev/null || true)
if [[ -z "$TOKEN" ]]; then
    fail "Authentication: POST /api/auth/token" \
         "response missing 'access_token' field" \
         "$(cat "$TOKEN_BODY")"
fi
pass "Authentication — logged in as $EMAIL"

# --- Check 3: DB-backed read ------------------------------------------------
SELF_BODY=$(mktemp)
SELF_CODE=$(curl -sS -o "$SELF_BODY" -w "%{http_code}" \
    --max-time 10 \
    -H "Authorization: Bearer $TOKEN" \
    "$API/users/self" 2>/dev/null || true)
SELF_CODE=${SELF_CODE:-000}

if [[ "$SELF_CODE" != "200" ]]; then
    fail "DB read: GET /api/users/self" \
         "expected HTTP 200, got $SELF_CODE" \
         "$(cat "$SELF_BODY")"
fi

SELF_EMAIL=$(jq -r '.email // empty' < "$SELF_BODY" 2>/dev/null || true)
if [[ -z "$SELF_EMAIL" ]]; then
    fail "DB read: GET /api/users/self" \
         "response missing 'email' field" \
         "$(cat "$SELF_BODY")"
fi
pass "DB read — /users/self returned email $SELF_EMAIL"

printf "%s%sAll checks passed.%s\n" "$GREEN" "$BOLD" "$RESET"
