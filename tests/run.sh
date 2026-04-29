#!/bin/bash
#
# Integration tests for dokku-uptime plugin.
#
# Spins up a Dokku container with Uptime Kuma, installs the plugin,
# and tests monitor CRUD through the full lifecycle.
#
# Usage:
#   DOKKU_VERSION=0.37.6 ./tests/run.sh
#
# Requires: docker
#
set -euo pipefail

DOKKU_VERSION="${DOKKU_VERSION:-0.37.6}"
CONTAINER_NAME="dokku-uptime-test-${DOKKU_VERSION//\./-}"
PASS=0
FAIL=0
KUMA_PASSWORD="testpassword123"

cleanup() {
    echo ""
    echo "=== Cleaning up ==="
    docker rm -f uptime-kuma-test 2>/dev/null || true
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

# Clean up any leftover containers from previous runs
docker rm -f uptime-kuma-test 2>/dev/null || true
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

assert_contains() {
    local label="$1"
    local haystack="$2"
    local needle="$3"
    if echo "$haystack" | grep -q "$needle"; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (expected to find '$needle')"
        echo "  GOT: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local label="$1"
    local haystack="$2"
    local needle="$3"
    if echo "$haystack" | grep -q "$needle"; then
        echo "  FAIL: $label (did not expect to find '$needle')"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    fi
}

assert_equals() {
    local label="$1"
    local actual="$2"
    local expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

dokku_exec() {
    docker exec "$CONTAINER_NAME" dokku "$@"
}

container_exec() {
    docker exec "$CONTAINER_NAME" "$@"
}

# --- Start Dokku ---
echo "=== Starting dokku $DOKKU_VERSION ==="
docker run -d \
    --name "$CONTAINER_NAME" \
    --env DOKKU_HOSTNAME=dokku.me \
    --env DOKKU_HOST_ROOT=/var/lib/dokku/home/dokku \
    --env DOKKU_LIB_HOST_ROOT=/var/lib/dokku/var/lib/dokku \
    --volume /var/run/docker.sock:/var/run/docker.sock \
    "dokku/dokku:${DOKKU_VERSION}"

echo "Waiting for dokku to be ready..."
for i in $(seq 1 60); do
    if docker exec "$CONTAINER_NAME" dokku version 2>/dev/null; then
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "FATAL: dokku did not become ready in time"
        exit 1
    fi
    sleep 2
done

DOKKU_ACTUAL_VERSION=$(docker exec "$CONTAINER_NAME" dokku version 2>/dev/null || echo "unknown")
echo "Dokku version: $DOKKU_ACTUAL_VERSION"

# --- Install uptime plugin ---
echo ""
echo "=== Installing dokku-uptime plugin ==="
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docker cp "$PLUGIN_DIR" "$CONTAINER_NAME":/var/lib/dokku/plugins/available/uptime
container_exec bash -c "dokku plugin:enable uptime 2>&1" || true
container_exec bash -c "dokku plugin:install 2>&1" || true

# Verify plugin installed
OUTPUT=$(dokku_exec uptime:help 2>&1 || true)
assert_contains "plugin help available" "$OUTPUT" "uptime"

# --- Start Uptime Kuma ---
echo ""
echo "=== Starting Uptime Kuma ==="
container_exec docker pull louislam/uptime-kuma:1 2>&1 | tail -1
container_exec docker run -d \
    --name uptime-kuma-test \
    -v /tmp/uptime-kuma-data:/app/data \
    louislam/uptime-kuma:1

# Get the container IP on the docker bridge network
KUMA_IP=$(container_exec docker inspect uptime-kuma-test --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
KUMA_URL="http://${KUMA_IP}:3001"
echo "Uptime Kuma URL: $KUMA_URL"

echo "Waiting for Uptime Kuma to be ready..."
for i in $(seq 1 60); do
    if container_exec curl -sS -o /dev/null -w "%{http_code}" "$KUMA_URL/" 2>/dev/null | grep -q "200\|302"; then
        echo "Uptime Kuma is ready"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "FATAL: Uptime Kuma did not become ready in time"
        exit 1
    fi
    sleep 2
done

# --- Set up Uptime Kuma user ---
echo ""
echo "=== Setting up Uptime Kuma user ==="
# Use the setup endpoint via node inside the Uptime Kuma container
# The socket.io-client module is bundled with Uptime Kuma
docker exec uptime-kuma-test node -e "
const { io } = require('socket.io-client');
const socket = io('ws://127.0.0.1:3001', {
    transports: ['websocket'],
    reconnection: false
});
socket.on('connect', () => {
    console.log('Connected');
    socket.emit('needSetup', (needSetup) => {
        console.log('needSetup:', needSetup);
        if (needSetup) {
            socket.emit('setup', 'admin', '${KUMA_PASSWORD}', (res) => {
                console.log('Setup result:', JSON.stringify(res));
                socket.disconnect();
                process.exit(0);
            });
        } else {
            console.log('Already set up');
            socket.disconnect();
            process.exit(0);
        }
    });
});
socket.on('connect_error', (err) => {
    console.error('Connection error:', err.message);
    process.exit(1);
});
setTimeout(() => { console.error('Timeout'); process.exit(1); }, 15000);
" 2>&1

sleep 2

# --- Configure plugin ---
echo ""
echo "=== Configuring uptime plugin ==="
dokku_exec uptime:set --global url "$KUMA_URL"
dokku_exec uptime:set --global username admin
dokku_exec uptime:set --global password "$KUMA_PASSWORD"

# ============================================================
# Test 1: uptime:status on app with no monitor
# ============================================================
echo ""
echo "=== Test 1: Status on app with no monitor ==="
dokku_exec apps:create test-app 2>&1 || true
dokku_exec domains:set test-app test-app.dokku.me 2>&1 || true

OUTPUT=$(dokku_exec uptime:status test-app 2>&1)
assert_contains "shows monitoring enabled" "$OUTPUT" "Monitoring enabled: true"
assert_contains "shows no monitor id" "$OUTPUT" "Monitor ID: none"

# ============================================================
# Test 2: uptime:disable / uptime:enable
# ============================================================
echo ""
echo "=== Test 2: Disable and enable ==="
dokku_exec uptime:disable test-app 2>&1

OUTPUT=$(dokku_exec uptime:status test-app 2>&1)
assert_contains "shows disabled" "$OUTPUT" "Monitoring enabled: false"

dokku_exec uptime:enable test-app 2>&1

OUTPUT=$(dokku_exec uptime:status test-app 2>&1)
assert_contains "shows re-enabled" "$OUTPUT" "Monitoring enabled: true"

# ============================================================
# Test 3: uptime:set global and per-app
# ============================================================
echo ""
echo "=== Test 3: Set configuration ==="
dokku_exec uptime:set --global interval 30 2>&1
OUTPUT=$(dokku_exec uptime:set --global interval 30 2>&1)
assert_contains "set global property" "$OUTPUT" "Set global uptime property"

OUTPUT=$(dokku_exec uptime:set test-app disabled true 2>&1)
assert_contains "set per-app property" "$OUTPUT" "Set uptime property"

# Clean up - re-enable
dokku_exec uptime:enable test-app 2>&1

# ============================================================
# Test 4: uptime:discover creates monitors
# ============================================================
echo ""
echo "=== Test 4: Discover creates monitors ==="
dokku_exec apps:create app-one 2>&1 || true
dokku_exec domains:set app-one app-one.dokku.me 2>&1 || true
dokku_exec git:from-image app-one nginx:latest 2>&1 || true
dokku_exec apps:create app-two 2>&1 || true
dokku_exec domains:set app-two app-two.dokku.me 2>&1 || true
dokku_exec git:from-image app-two nginx:latest 2>&1 || true

OUTPUT=$(dokku_exec uptime:discover 2>&1)
assert_contains "discover creates monitors" "$OUTPUT" "created"
assert_not_contains "discover has no failures" "$OUTPUT" "Failed"

# Check monitors were stored
OUTPUT=$(dokku_exec uptime:status app-one 2>&1)
assert_not_contains "app-one has monitor id" "$OUTPUT" "Monitor ID: none"

OUTPUT=$(dokku_exec uptime:status app-two 2>&1)
assert_not_contains "app-two has monitor id" "$OUTPUT" "Monitor ID: none"

# ============================================================
# Test 5: Discover is idempotent
# ============================================================
echo ""
echo "=== Test 5: Discover is idempotent ==="
OUTPUT=$(dokku_exec uptime:discover 2>&1)
assert_contains "second discover skips existing" "$OUTPUT" "already monitored"
assert_contains "nothing new created" "$OUTPUT" "0 created"

# ============================================================
# Test 6: Discover skips disabled apps
# ============================================================
echo ""
echo "=== Test 6: Discover skips disabled apps ==="
dokku_exec apps:create disabled-app 2>&1 || true
dokku_exec domains:set disabled-app disabled-app.dokku.me 2>&1 || true
dokku_exec uptime:disable disabled-app 2>&1

OUTPUT=$(dokku_exec uptime:discover 2>&1)
assert_contains "skips disabled app" "$OUTPUT" "disabled"

OUTPUT=$(dokku_exec uptime:status disabled-app 2>&1)
assert_contains "disabled app has no monitor" "$OUTPUT" "Monitor ID: none"

# ============================================================
# Test 7: uptime:disable removes existing monitor
# ============================================================
echo ""
echo "=== Test 7: Disable removes monitor ==="
OUTPUT=$(dokku_exec uptime:status app-one 2>&1)
assert_not_contains "app-one has monitor before disable" "$OUTPUT" "Monitor ID: none"

dokku_exec uptime:disable app-one 2>&1

OUTPUT=$(dokku_exec uptime:status app-one 2>&1)
assert_contains "monitor removed after disable" "$OUTPUT" "Monitor ID: none"

# ============================================================
# Test 8: uptime:enable creates monitor for existing app
# ============================================================
echo ""
echo "=== Test 8: Enable creates monitor ==="
dokku_exec uptime:enable app-one 2>&1

OUTPUT=$(dokku_exec uptime:status app-one 2>&1)
assert_not_contains "monitor recreated after enable" "$OUTPUT" "Monitor ID: none"

# ============================================================
# Test 9: post-deploy trigger creates monitor (via real deploy)
# ============================================================
echo ""
echo "=== Test 9: post-deploy trigger ==="
dokku_exec apps:create deploy-app 2>&1 || true
dokku_exec domains:set deploy-app deploy-app.dokku.me 2>&1 || true

# Deploy a real app to fire the post-deploy trigger
dokku_exec git:from-image deploy-app nginx:latest 2>&1 || true

OUTPUT=$(dokku_exec uptime:status deploy-app 2>&1)
assert_not_contains "post-deploy created monitor" "$OUTPUT" "Monitor ID: none"

# ============================================================
# Test 10: post-deploy skips disabled apps
# ============================================================
echo ""
echo "=== Test 10: post-deploy skips disabled apps ==="
dokku_exec apps:create deploy-disabled 2>&1 || true
dokku_exec domains:set deploy-disabled deploy-disabled.dokku.me 2>&1 || true
dokku_exec uptime:disable deploy-disabled 2>&1

dokku_exec git:from-image deploy-disabled nginx:latest 2>&1 || true

OUTPUT=$(dokku_exec uptime:status deploy-disabled 2>&1)
assert_contains "post-deploy skipped disabled app" "$OUTPUT" "Monitor ID: none"

# ============================================================
# Test 11: post-deploy is idempotent (redeploy same app)
# ============================================================
echo ""
echo "=== Test 11: post-deploy is idempotent ==="
OUTPUT_BEFORE=$(dokku_exec uptime:status deploy-app 2>&1)

dokku_exec ps:rebuild deploy-app 2>&1 || true

OUTPUT_AFTER=$(dokku_exec uptime:status deploy-app 2>&1)
assert_equals "post-deploy idempotent" "$OUTPUT_BEFORE" "$OUTPUT_AFTER"

# ============================================================
# Test 12: pre-delete trigger removes monitor (via apps:destroy)
# ============================================================
echo ""
echo "=== Test 12: pre-delete trigger ==="
OUTPUT=$(dokku_exec uptime:status deploy-app 2>&1)
assert_not_contains "deploy-app has monitor before delete" "$OUTPUT" "Monitor ID: none"

dokku_exec apps:destroy deploy-app --force 2>&1 || true

# App is gone so we check the property file directly
MONITOR_ID=$(container_exec cat /var/lib/dokku/config/uptime/deploy-app/monitor-id 2>/dev/null || echo "")
assert_equals "pre-delete removed monitor id" "$MONITOR_ID" ""

# ============================================================
# Test 14: post-deploy skips apps with no ports mapped
# ============================================================
echo ""
echo "=== Test 14: post-deploy skips apps with no ports ==="
dokku_exec apps:create no-ports-app 2>&1 || true
dokku_exec domains:set no-ports-app no-ports-app.dokku.me 2>&1 || true

# Trigger post-deploy without deploying — call the trigger directly
OUTPUT=$(container_exec /var/lib/dokku/plugins/available/uptime/post-deploy no-ports-app 2>&1 || true)
assert_contains "post-deploy warns about missing ports" "$OUTPUT" "No ports mapped"

OUTPUT=$(dokku_exec uptime:status no-ports-app 2>&1)
assert_contains "no monitor created for portless app" "$OUTPUT" "Monitor ID: none"

# ============================================================
# Test 13: Missing credentials produces error
# ============================================================
echo ""
echo "=== Test 13: Missing credentials error ==="
dokku_exec apps:create creds-test 2>&1 || true
dokku_exec domains:set creds-test creds-test.dokku.me 2>&1 || true

# Clear credentials temporarily
container_exec rm -f /var/lib/dokku/config/uptime/--global/url 2>&1 || true

OUTPUT=$(dokku_exec uptime:enable creds-test 2>&1 || true)
assert_contains "missing creds error" "$OUTPUT" "credentials not configured"

# Restore credentials
dokku_exec uptime:set --global url "$KUMA_URL" 2>&1

# ============================================================
# Summary
# ============================================================
echo ""
echo "========================================"
echo "  dokku-uptime Integration Tests"
echo "  Dokku $DOKKU_VERSION"
echo "========================================"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
