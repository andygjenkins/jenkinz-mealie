#!/bin/bash
# Seed Mealie with test admin user
# Usage: ./scripts/seed.sh [API_URL]
#
# This script configures the default Mealie admin user with test credentials.
# It's idempotent - if admin is already configured, it exits gracefully.

set -e

API="${1:-http://localhost:9000/api}"

# Configuration (can be overridden via environment)
# NOTE: Password must be at least 8 characters per Mealie API requirements
ADMIN_EMAIL="${SEED_ADMIN_EMAIL:-admin@test.com}"
ADMIN_USERNAME="${SEED_ADMIN_USERNAME:-admin}"
ADMIN_FULLNAME="${SEED_ADMIN_FULLNAME:-Test Admin}"
ADMIN_PASSWORD="${SEED_ADMIN_PASSWORD:-testtest}"

# Default Mealie credentials
DEFAULT_EMAIL="changeme@example.com"
DEFAULT_PASSWORD="MyPassword"

echo "Seeding Mealie at $API"
echo "Target admin: $ADMIN_EMAIL"
echo ""

# Wait for Mealie to be ready
echo "Waiting for Mealie API..."
ATTEMPTS=0
MAX_ATTEMPTS=60
until curl -sf "$API/app/about" > /dev/null 2>&1; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ $ATTEMPTS -ge $MAX_ATTEMPTS ]; then
        echo "ERROR: Mealie did not become ready after ${MAX_ATTEMPTS} attempts"
        exit 1
    fi
    echo "  Attempt $ATTEMPTS/$MAX_ATTEMPTS - waiting..."
    sleep 2
done
echo "Mealie is ready!"
echo ""

# Try to login with default credentials
echo "Attempting login with default credentials..."
RESPONSE=$(curl -s -X POST "$API/auth/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=$DEFAULT_EMAIL&password=$DEFAULT_PASSWORD" || true)

TOKEN=$(echo "$RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ]; then
    # Mealie security blocks email changes on the built-in admin, so after seeding
    # the creds are DEFAULT_EMAIL / ADMIN_PASSWORD (not ADMIN_EMAIL).
    echo "Default credentials failed, trying rotated-password credentials..."
    RESPONSE=$(curl -s -X POST "$API/auth/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=$DEFAULT_EMAIL&password=$ADMIN_PASSWORD" || true)

    TOKEN=$(echo "$RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$TOKEN" ]; then
        echo "ERROR: Could not authenticate with either default or rotated credentials"
        echo "Response: $RESPONSE"
        exit 1
    fi
    echo "Authenticated with rotated credentials — skipping first-time password update."
    AUTH="Authorization: Bearer $TOKEN"
    SKIP_FIRST_TIME_UPDATES=1
fi

AUTH="${AUTH:-Authorization: Bearer $TOKEN}"

if [ "${SKIP_FIRST_TIME_UPDATES:-0}" = "1" ]; then
    echo "Skipping password + profile updates (already applied on earlier run)."
else

# Update password first (before email change invalidates token)
echo "Updating admin password..."
PASSWORD_RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "$API/users/password" \
    -H "$AUTH" \
    -H "Content-Type: application/json" \
    -d "{\"currentPassword\":\"$DEFAULT_PASSWORD\",\"newPassword\":\"$ADMIN_PASSWORD\"}")
PASSWORD_CODE=$(echo "$PASSWORD_RESPONSE" | tail -1)
if [ "$PASSWORD_CODE" != "200" ]; then
    echo "Warning: Password update returned $PASSWORD_CODE (may already be changed)"
fi

# Re-authenticate with new password for remaining updates
RESPONSE=$(curl -s -X POST "$API/auth/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=$DEFAULT_EMAIL&password=$ADMIN_PASSWORD" || true)
TOKEN=$(echo "$RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
if [ -n "$TOKEN" ]; then
    AUTH="Authorization: Bearer $TOKEN"
fi

# Get admin user ID
echo "Getting admin user info..."
SELF=$(curl -s "$API/users/self" -H "$AUTH")
ADMIN_ID=$(echo "$SELF" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$ADMIN_ID" ]; then
    echo "Warning: Could not get admin user ID, skipping profile update"
else
    echo "Admin ID: $ADMIN_ID"
    # Update admin user details (email is required field)
    echo "Updating admin user details..."
    UPDATE_RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "$API/users/$ADMIN_ID" \
        -H "$AUTH" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$ADMIN_EMAIL\",\"username\":\"$ADMIN_USERNAME\",\"fullName\":\"$ADMIN_FULLNAME\"}")
    UPDATE_CODE=$(echo "$UPDATE_RESPONSE" | tail -1)
    if [ "$UPDATE_CODE" != "200" ]; then
        echo "Warning: Profile update returned $UPDATE_CODE"
    fi
fi

fi  # end of SKIP_FIRST_TIME_UPDATES guard

# Ensure the extended-family households exist.
# Space-separated list; admin's own household is created by Mealie on first boot
# via DEFAULT_HOUSEHOLD and is skipped here.
EXTRA_HOUSEHOLDS="${SEED_EXTRA_HOUSEHOLDS:-JenkinsSnrs Munchkins Frenkins Hongkins}"
echo "Ensuring extended-family households exist..."
GROUP_ID=$(curl -s "$API/admin/groups" -H "$AUTH" | jq -r '.items[] | select(.name=="Jenkinz") | .id' 2>/dev/null || echo "")
if [ -n "$GROUP_ID" ]; then
    EXISTING=$(curl -s "$API/admin/households" -H "$AUTH" | jq -r '.items[].name' 2>/dev/null || echo "")
    for HH in $EXTRA_HOUSEHOLDS; do
        if echo "$EXISTING" | grep -Fxq "$HH"; then
            echo "  Already exists: $HH"
        else
            HH_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/admin/households" \
                -H "$AUTH" \
                -H "Content-Type: application/json" \
                -d "{\"name\":\"$HH\",\"groupId\":\"$GROUP_ID\"}" || echo "000")
            case "$HH_CODE" in
                201) echo "  Created: $HH" ;;
                *)   echo "  Skipped $HH (HTTP $HH_CODE) — non-fatal" ;;
            esac
        fi
    done
else
    echo "  Warning: Jenkinz group not found — skipping household seed (non-fatal)"
fi

# Create a welcome recipe so local dev has something to look at.
# Mealie auto-renames duplicates ("name (1)") instead of 409-ing, so we check first.
WELCOME_NAME="Welcome to Jenkinz Mealie"
WELCOME_SLUG="welcome-to-jenkinz-mealie"
echo "Ensuring welcome recipe exists..."
EXISTING_SLUGS=$(curl -s "$API/recipes?perPage=100" -H "$AUTH" | jq -r '.items[].slug' 2>/dev/null || echo "")
if echo "$EXISTING_SLUGS" | grep -Fxq "$WELCOME_SLUG"; then
    echo "  Already exists: $WELCOME_NAME"
else
    RECIPE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/recipes" \
        -H "$AUTH" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$WELCOME_NAME\"}" || echo "000")
    case "$RECIPE_CODE" in
        201) echo "  Created: $WELCOME_NAME" ;;
        *)   echo "  Skipped (HTTP $RECIPE_CODE) — non-fatal" ;;
    esac
fi

echo ""
echo "Seed complete!"
echo "Login: $DEFAULT_EMAIL / $ADMIN_PASSWORD"
echo "(Note: email update may be blocked by Mealie security - password is updated)"
