#!/bin/bash
#
# Provision a fresh ERPNext site for the end-to-end suite, over HTTP only (no browser, no
# docker exec). Safe to re-run: every step checks first and skips what is already there.
#
#   1. wait for the site to answer (the DB and workers come up after nginx)
#   2. log in as Administrator and pick up the CSRF token from the desk page
#   3. wait until create-site has finished installing erpnext, not just frappe
#   4. run the setup wizard headlessly if setup is not complete
#   5. set the admin preferences the tests rely on (no onboarding tours, ISO dates)
#   6. seed a small, fixed set of masters (customers, suppliers, stocked items)
#   7. optionally run RESTART_CMD and wait for the site to come back
#
# With frappe_docker, restart the frontend after the backend: nginx resolves the backend
# address once at start and keeps sending to the old IP (502) after a backend-only restart.
#   RESTART_CMD='docker compose -p erpnext-e2e-ci -f tests/E2E/ci/compose.yml restart backend frontend'
#
# Test cases create their own uniquely named records; the seed here is only the baseline that
# read-only cases (search, lists, reports) can count on.
#
set -e

base_url="${BASE_URL:-http://localhost:8080}"
admin_user="${ADMIN_USER:-Administrator}"
admin_password="${ADMIN_PASSWORD:-admin}"
company="${COMPANY_NAME:-E2E Test Co}"
abbr="${COMPANY_ABBR:-ETC}"
warehouse="Stores - ${abbr}"
year="$(date +%Y)"

jar="$(mktemp)"
trap 'rm -f "$jar"' EXIT

log() { echo "[install-erpnext] $*"; }

# GET/POST through the shared session. The token header is harmless before it is known.
call() {
    curl -sS -L -b "$jar" -c "$jar" -H "X-Frappe-CSRF-Token: ${csrf_token:-}" "$@"
}

# Pull the integer out of {"message":N}
message_int() { sed -n 's/.*"message": *\([0-9][0-9]*\).*/\1/p'; }

wait_for_site() {
    local tries="${1:-90}"
    for _ in $(seq 1 "$tries"); do
        if curl -sf -o /dev/null "$base_url/api/method/ping"; then
            return 0
        fi
        sleep 5
    done
    log "site at $base_url did not answer after $((tries * 5))s"
    exit 1
}

login() {
    # Retry: right after create-site the first logins can 500 while workers warm up.
    for _ in $(seq 1 20); do
        if call -X POST "$base_url/api/method/login" -H "Content-Type: application/json" \
            -d "{\"usr\":\"$admin_user\",\"pwd\":\"$admin_password\"}" | grep -q '"Logged In"'; then
            # A session only gets a CSRF token once a desk page renders. Develop serves the desk
            # at /desk, v16 and older at /app; -L follows either redirect.
            csrf_token="$(call "$base_url/desk" | grep -o 'csrf_token = "[0-9a-f]*' | cut -d'"' -f2)"
            if [ -z "$csrf_token" ]; then
                csrf_token="$(call "$base_url/app" | grep -o 'csrf_token = "[0-9a-f]*' | cut -d'"' -f2)"
            fi
            [ -n "$csrf_token" ] && return 0
        fi
        sleep 5
    done
    log "could not log in as $admin_user"
    exit 1
}

# count <doctype> <filters-json>; prints nothing when the call fails
count() {
    call -G "$base_url/api/method/frappe.client.get_count" \
        --data-urlencode "doctype=$1" --data-urlencode "filters=$2" | message_int
}

# A failed count must stop the script, not read as "missing" or "present". Called by the
# parent shell, because an exit inside $(count ...) only leaves the subshell.
require_int() {
    case "$1" in
        '' | *[!0-9]*) log "unexpected answer from the server while checking $2"; exit 1 ;;
    esac
}

wait_for_erpnext() {
    # ping and login already work once frappe is installed, while create-site is still
    # installing erpnext; running the wizard then leaves a half set up site. Dashboards are the
    # last thing install_app syncs, and Assets is the last erpnext module that has one.
    for _ in $(seq 1 120); do
        [ "$(count "Dashboard" '{"name":"Asset"}')" = "1" ] && return 0
        sleep 5
    done
    log "erpnext did not finish installing"
    exit 1
}

# insert <doc-json>; fails loudly on any server error
insert() {
    local out
    out="$(call -X POST "$base_url/api/method/frappe.client.insert" --data-urlencode "doc=$1")"
    if ! echo "$out" | grep -q '^{"message"'; then
        log "insert failed: $1"
        echo "$out" | head -c 2000
        exit 1
    fi
    echo "$out"
}

# set_value <doctype> <name> <fields-json>; fails loudly on any server error
set_value() {
    local out
    out="$(call -X POST "$base_url/api/method/frappe.client.set_value" --data-urlencode "doctype=$1"         --data-urlencode "name=$2" --data-urlencode "fieldname=$3")"
    if ! echo "$out" | grep -q '^{"message"'; then
        log "set_value failed: $1 $2 $3"
        echo "$out" | head -c 2000
        exit 1
    fi
}

# ensure <doctype> <name> <doc-json>: insert only when no record has that name
ensure() {
    local n
    n="$(count "$1" "{\"name\":\"$2\"}")"
    require_int "$n" "$1 $2"
    if [ "$n" = "0" ]; then
        insert "$3" > /dev/null
        log "created $1 $2"
    fi
}

setup_wizard() {
    local done
    done="$(call -G "$base_url/api/method/frappe.client.get_single_value" \
        --data-urlencode "doctype=System Settings" --data-urlencode "field=setup_complete" | message_int)"
    require_int "$done" "setup_complete"
    if [ "$done" = "1" ]; then
        log "setup already complete"
        return
    fi
    log "running setup wizard"
    local args="{\"language\":\"English\",\"country\":\"United States\",\"timezone\":\"America/New_York\",
        \"currency\":\"USD\",\"company_name\":\"$company\",\"company_abbr\":\"$abbr\",
        \"chart_of_accounts\":\"Standard\",\"fy_start_date\":\"$year-01-01\",\"fy_end_date\":\"$year-12-31\",
        \"enable_telemetry\":0}"
    call -X POST "$base_url/api/method/frappe.desk.page.setup_wizard.setup_wizard.setup_complete" \
        --data-urlencode "args=$args" | grep -q '"status": *"ok"' || { log "setup wizard failed"; exit 1; }
    # The wizard logs the session in again; refresh the token.
    login
}

preferences() {
    # Onboarding tours and "what's new" dialogs pop over the desk and steal clicks. ISO dates
    # keep typed and asserted dates unambiguous.
    set_value "System Settings" "System Settings" '{"enable_onboarding":0,"disable_change_log_notification":1,
        "disable_system_update_notification":1,"date_format":"yyyy-mm-dd"}'
    # Work orders take their WIP and finished-goods warehouses from the company; the wizard
    # leaves them empty.
    set_value "Company" "$company" "{\"default_wip_warehouse\":\"Work In Progress - ${abbr}\",
        \"default_fg_warehouse\":\"Finished Goods - ${abbr}\"}"
    log "admin preferences set"
}

seed() {
    ensure "Customer" "E2E Seed Customer A" \
        '{"doctype":"Customer","customer_name":"E2E Seed Customer A","customer_type":"Company"}'
    ensure "Customer" "E2E Seed Customer B" \
        '{"doctype":"Customer","customer_name":"E2E Seed Customer B","customer_type":"Individual"}'
    ensure "Supplier" "E2E Seed Supplier A" \
        '{"doctype":"Supplier","supplier_name":"E2E Seed Supplier A"}'

    # standard_rate on insert also creates the Standard Selling item price.
    local code rate
    for pair in "E2E-SEED-001:25" "E2E-SEED-002:40" "E2E-SEED-003:99.5"; do
        code="${pair%%:*}"
        rate="${pair##*:}"
        ensure "Item" "$code" "{\"doctype\":\"Item\",\"item_code\":\"$code\",\"item_name\":\"$code\",
            \"item_group\":\"Products\",\"stock_uom\":\"Nos\",\"is_stock_item\":1,
            \"standard_rate\":$rate,\"valuation_rate\":$rate}"
    done

    # Buying prices, so purchase documents get a non-zero rate (and post to the ledger).
    local priced
    for pair in "E2E-SEED-001:20" "E2E-SEED-002:30" "E2E-SEED-003:80"; do
        code="${pair%%:*}"
        rate="${pair##*:}"
        priced="$(count "Item Price" "{\"item_code\":\"$code\",\"price_list\":\"Standard Buying\"}")"
        require_int "$priced" "buying price $code"
        if [ "$priced" = "0" ]; then
            insert "{\"doctype\":\"Item Price\",\"item_code\":\"$code\",\"price_list\":\"Standard Buying\",
                \"price_list_rate\":$rate}" > /dev/null
            log "created buying price $code"
        fi
    done

    # Opening stock, once: a submitted Material Receipt tagged in remarks.
    local received
    received="$(count "Stock Entry" '{"remarks":"E2E seed opening stock","docstatus":1}')"
    require_int "$received" "opening stock"
    if [ "$received" = "0" ]; then
        # docstatus 1 on insert submits in the same request.
        insert "{\"doctype\":\"Stock Entry\",\"stock_entry_type\":\"Material Receipt\",\"docstatus\":1,
            \"company\":\"$company\",\"remarks\":\"E2E seed opening stock\",\"items\":[
            {\"item_code\":\"E2E-SEED-001\",\"qty\":100,\"t_warehouse\":\"$warehouse\",\"basic_rate\":25},
            {\"item_code\":\"E2E-SEED-002\",\"qty\":100,\"t_warehouse\":\"$warehouse\",\"basic_rate\":40},
            {\"item_code\":\"E2E-SEED-003\",\"qty\":100,\"t_warehouse\":\"$warehouse\",\"basic_rate\":99.5}]}" > /dev/null
        log "opening stock received"
    fi
}

wait_for_site
login
wait_for_erpnext
setup_wizard
preferences
seed

if [ -n "${RESTART_CMD:-}" ]; then
    log "running restart hook"
    eval "$RESTART_CMD"
    wait_for_site
fi

log "done: $base_url ($admin_user / $admin_password)"
