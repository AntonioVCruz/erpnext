#!/bin/bash
#
# Run the testRigor end-to-end suite against a throwaway ERPNext stack. Used by the CI
# workflow and for local runs; both take the same path.
#
#   1. optionally build an ERPNext image from a git branch (frappe_docker layered image)
#   2. start the stack (compose.yml: frappe_docker's quick-start services)
#   3. provision the site with install-erpnext.sh (setup wizard, preferences, seed data)
#   4. run the suite with the testRigor CLI; --localhost tunnels testRigor's browsers to the site
#   5. save the JUnit report and, on failure, the container logs; then remove the stack
#
# Required:
#   TESTRIGOR_AUTH_TOKEN   testRigor personal access token
#   TESTRIGOR_SUITE_ID     test suite to run in; --explicit-mutations makes it mirror tests/E2E
# Optional:
#   ERPNEXT_IMAGE          image to run (default frappe/erpnext:develop)
#   BUILD_REPO, BUILD_BRANCH
#                          build the image from this ERPNext repo and branch instead
#   FRAPPE_BRANCH          frappe branch for the build (default develop)
#   FRAPPE_DOCKER_DIR      frappe_docker checkout for the build (default: shallow clone)
#   COMPOSE_PROJECT        compose project name (default erpnext-e2e-ci)
#   HTTP_PORT              host port for the site (default 8080)
#   ARTIFACTS_DIR          where reports and logs go (default tests/E2E/ci/artifacts)
#   KEEP_STACK=1           leave the stack running afterwards
#
set -e

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
e2e="$(dirname "$here")"

: "${TESTRIGOR_AUTH_TOKEN:?set TESTRIGOR_AUTH_TOKEN}"
: "${TESTRIGOR_SUITE_ID:?set TESTRIGOR_SUITE_ID}"
project="${COMPOSE_PROJECT:-erpnext-e2e-ci}"
port="${HTTP_PORT:-8080}"
artifacts="${ARTIFACTS_DIR:-$here/artifacts}"
export ERPNEXT_IMAGE="${ERPNEXT_IMAGE:-frappe/erpnext:develop}"
export HTTP_PORT="$port"

log() { echo "[run-e2e] $*"; }
compose() { docker compose -p "$project" -f "$here/compose.yml" "$@"; }

mkdir -p "$artifacts"

build_image() {
    local fd="${FRAPPE_DOCKER_DIR:-}"
    if [ -z "$fd" ]; then
        fd="$(mktemp -d)"
        git clone --depth 1 https://github.com/frappe/frappe_docker "$fd"
    fi
    local apps_json
    apps_json="$(mktemp)"
    echo "[{\"url\": \"$BUILD_REPO\", \"branch\": \"$BUILD_BRANCH\"}]" > "$apps_json"
    ERPNEXT_IMAGE="erpnext-e2e:ci"
    log "building $ERPNEXT_IMAGE from $BUILD_REPO@$BUILD_BRANCH (frappe ${FRAPPE_BRANCH:-develop})"
    # CACHE_BUST: the branch name alone would let BuildKit reuse a stale bench layer.
    docker build \
        --secret=id=apps_json,src="$apps_json" \
        --build-arg FRAPPE_BRANCH="${FRAPPE_BRANCH:-develop}" \
        --build-arg CACHE_BUST="$(date +%s)" \
        -f "$fd/images/layered/Containerfile" \
        -t "$ERPNEXT_IMAGE" "$fd"
    rm -f "$apps_json"
}

teardown() {
    local status=$?
    if [ "$status" != "0" ]; then
        log "failed (exit $status); saving container logs"
        compose logs --no-color > "$artifacts/compose.log" 2>&1 || true
    fi
    if [ "${KEEP_STACK:-}" = "1" ]; then
        log "leaving the stack running (project $project, http://localhost:$port)"
    else
        compose down -v --remove-orphans > /dev/null 2>&1 || true
    fi
    exit "$status"
}

if [ -n "${BUILD_REPO:-}" ]; then
    : "${BUILD_BRANCH:?set BUILD_BRANCH together with BUILD_REPO}"
    build_image
fi

trap teardown EXIT

log "starting $ERPNEXT_IMAGE as project $project on port $port"
# Start clean: create-site skips an existing site, so leftover volumes would reuse old data.
compose down -v --remove-orphans > /dev/null 2>&1 || true
compose up -d

BASE_URL="http://localhost:$port" \
    RESTART_CMD="docker compose -p $project -f $here/compose.yml restart backend frontend" \
    bash "$here/install-erpnext.sh"

log "running the suite"
# Relative paths: the CLI expands the globs itself.
cd "$e2e"
junit="$(realpath --relative-to="$e2e" "$artifacts")/junit.xml"
testrigor test-suite run "$TESTRIGOR_SUITE_ID" \
    --auth-token "$TESTRIGOR_AUTH_TOKEN" \
    --localhost --url "http://localhost:$port" \
    --explicit-mutations \
    --test-cases-path 'test-cases/*.yaml' \
    --rules-path 'rules/*.txt' \
    --variables-path variables.json \
    --junit-report-save-path "$junit"
