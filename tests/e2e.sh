#!/bin/sh
# End-to-end tests against tests/mock_cf_api.py: startup, a dry run, real
# updates, a record deleted behind the updater's back, lookup and API
# failures, fatal configuration problems, and prompt shutdown.
#
#   sh tests/e2e.sh                               # runs src/nofixedaddress.sh
#   NFA_IMAGE=nofixedaddress:dev sh tests/e2e.sh  # runs a built image instead
#
# Needs curl and python3, plus jq when running the script directly. In image
# mode the container uses the host network so it can reach the mock on
# 127.0.0.1. Docker Desktop has no host network by default; there, run with
#
#   NFA_DOCKER_NETWORK=bridge NFA_MOCK_HOST=host.docker.internal MOCK_BIND=0.0.0.0

set -u

here=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$here/../src/nofixedaddress.sh
PYTHON=${PYTHON:-python3}
IMAGE=${NFA_IMAGE:-}
DOCKER_NETWORK=${NFA_DOCKER_NETWORK:-host}
MOCK_HOST=${NFA_MOCK_HOST:-127.0.0.1}
MOCK_BIND=${MOCK_BIND:-127.0.0.1}
TOKEN=e2e-token_0123456789abcdef
ACCOUNT_TOKEN=cfat_e2e-account-token_0123456789

# Settings from the caller's environment must not leak into the runs below.
unset CF_API_TOKEN CF_API_TOKEN_FILE CF_ZONE CF_RECORDS INTERVAL IPV4 IPV6 \
    PROXIED TTL CREATE_IF_MISSING DRY_RUN LOG_LEVEL IPV4_SOURCES IPV6_SOURCES \
    CF_API_URL STATE_DIR NFA_SOURCE_ONLY

WORK=$(mktemp -d)
MOCK_PID=''
NFA_PID=''
CID=''
failed=0

cleanup() {
    [ -z "$NFA_PID" ] || kill "$NFA_PID" 2>/dev/null
    [ -z "$CID" ] || docker rm -f "$CID" >/dev/null 2>&1
    [ -z "$MOCK_PID" ] || kill "$MOCK_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# check DESCRIPTION COMMAND...
check() {
    desc=$1
    shift
    if "$@"; then
        printf 'ok    %s\n' "$desc"
    else
        failed=$((failed + 1))
        printf 'FAIL  %s\n' "$desc"
    fi
}

not() {
    ! "$@"
}

# wait_for SECONDS COMMAND...
wait_for() {
    deadline=$(($(date +%s) + $1))
    shift
    until "$@"; do
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep 0.2
    done
}

with_time_limit() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 60 "$@"
    else
        "$@"
    fi
}

# --- the mock API -------------------------------------------------------------

start_mock() {
    "$PYTHON" "$here/mock_cf_api.py" --host "$MOCK_BIND" --port-file "$WORK/port" \
        --token "$TOKEN" --account-token "$ACCOUNT_TOKEN" --zone example.com --ip 5.6.7.8 \
        --record A:home.example.com:1.2.3.4 &
    MOCK_PID=$!
    if ! wait_for 20 test -s "$WORK/port"; then
        echo "the mock API did not start" >&2
        exit 1
    fi
    PORT=$(cat "$WORK/port")
    API_URL=http://$MOCK_HOST:$PORT/client/v4
    TRACE_URL=http://$MOCK_HOST:$PORT/trace
}

# mock GET|POST PATH
mock() {
    curl -fsS -X "$1" "http://127.0.0.1:$PORT/_mock/$2"
}

mock_has() {
    mock GET state | grep -qF -- "$1"
}

# --- running the updater ------------------------------------------------------

# Starts the updater in the background with the shared settings plus "$@".
nfa_start() {
    set -- "CF_API_TOKEN=$TOKEN" CF_ZONE=example.com "CF_API_URL=$API_URL" \
        "IPV4_SOURCES=$TRACE_URL" LOG_LEVEL=debug "$@"
    : >"$WORK/out"
    if [ -n "$IMAGE" ]; then
        for kv do
            shift
            set -- "$@" -e "$kv"
        done
        CID=$(docker run -d --network "$DOCKER_NETWORK" "$@" "$IMAGE")
    else
        rm -rf "$WORK/state"
        (
            for kv do
                export "${kv?}"
            done
            export STATE_DIR="$WORK/state"
            exec sh "$SCRIPT"
        ) >"$WORK/out" 2>&1 &
        NFA_PID=$!
    fi
}

# Runs the updater in the foreground until it exits by itself, leaving the
# exit status in RUN_STATUS.
nfa_run() {
    set -- "CF_API_TOKEN=$TOKEN" CF_ZONE=example.com "CF_API_URL=$API_URL" \
        "IPV4_SOURCES=$TRACE_URL" LOG_LEVEL=debug "$@"
    if [ -n "$IMAGE" ]; then
        for kv do
            shift
            set -- "$@" -e "$kv"
        done
        with_time_limit docker run --rm --network "$DOCKER_NETWORK" "$@" "$IMAGE" >"$WORK/out" 2>&1
        RUN_STATUS=$?
    else
        (
            for kv do
                export "${kv?}"
            done
            with_time_limit sh "$SCRIPT"
        ) >"$WORK/out" 2>&1
        RUN_STATUS=$?
    fi
}

nfa_logs() {
    if [ -n "$CID" ]; then
        docker logs "$CID" 2>&1
    else
        cat "$WORK/out"
    fi
}

log_has() {
    nfa_logs | grep -qF -- "$1"
}

nfa_running() {
    if [ -n "$IMAGE" ]; then
        [ "$(docker inspect -f '{{.State.Running}}' "$CID")" = true ]
    else
        kill -0 "$NFA_PID" 2>/dev/null
    fi
}

nfa_health() {
    if [ -n "$IMAGE" ]; then
        docker exec "$CID" nofixedaddress healthcheck
    else
        STATE_DIR=$WORK/state sh "$SCRIPT" healthcheck
    fi
}

# Sends TERM, the way `docker stop` does, and records the exit status in
# STOP_STATUS and how long the shutdown took in STOP_SECONDS.
nfa_stop() {
    started=$(date +%s)
    if [ -n "$IMAGE" ]; then
        docker stop -t 10 "$CID" >/dev/null
        STOP_STATUS=$(docker inspect -f '{{.State.ExitCode}}' "$CID")
        docker logs "$CID" >"$WORK/out" 2>&1
        docker rm "$CID" >/dev/null
        CID=''
    else
        kill -TERM "$NFA_PID"
        wait "$NFA_PID"
        STOP_STATUS=$?
        NFA_PID=''
    fi
    STOP_SECONDS=$(($(date +%s) - started))
}

check_prompt_stop() {
    nfa_stop
    check "exits with status 0 on SIGTERM (got $STOP_STATUS)" [ "$STOP_STATUS" -eq 0 ]
    check "stops within 2 seconds (took ${STOP_SECONDS}s)" [ "$STOP_SECONDS" -le 2 ]
}

# Prints the updater's output, always for the dry run and otherwise only when
# a scenario has failures worth debugging.
show_log() {
    if [ "$1" = always ] || [ "$failed" -gt "$2" ]; then
        echo '    ---- output ----'
        sed 's/^/    /' "$WORK/out"
        echo '    ----------------'
    fi
}

start_mock
if [ -n "$IMAGE" ]; then
    echo "Testing image $IMAGE against the mock API on port $PORT"
else
    echo "Testing $SCRIPT against the mock API on port $PORT"
fi

echo
echo "Dry run"
before=$failed
nfa_start CF_RECORDS=home.example.com,vpn.example.com DRY_RUN=true CREATE_IF_MISSING=true INTERVAL=3600
check "completes the first check" wait_for 30 log_has 'check complete'
check "verifies the token" log_has 'API token verified'
check "reports the update it would make" log_has '[dry-run] home.example.com A 1.2.3.4 -> 5.6.7.8'
check "reports the record it would create" log_has '[dry-run] vpn.example.com A created with 5.6.7.8'
check "writes nothing" mock_has 'writes 0'
check "leaves the record as it was" mock_has 'A home.example.com 1.2.3.4 '
check "reports healthy after a successful check" nfa_health
check "never logs the token" not log_has "$TOKEN"
check_prompt_stop
show_log always

echo
echo "Account-owned token"
before=$failed
nfa_start "CF_API_TOKEN=$ACCOUNT_TOKEN" CF_RECORDS=home.example.com DRY_RUN=true INTERVAL=3600
check "completes the first check" wait_for 30 log_has 'check complete'
check "verifies the token under its account" log_has 'API token verified (account-owned)'
check "never logs the token" not log_has "$ACCOUNT_TOKEN"
check_prompt_stop
show_log failures "$before"

echo
echo "Live updates"
before=$failed
nfa_start CF_RECORDS=home.example.com,vpn.example.com CREATE_IF_MISSING=true INTERVAL=2
check "completes the first check" wait_for 30 log_has 'check complete'
check "updates the stale record" log_has 'home.example.com A 1.2.3.4 -> 5.6.7.8'
check "creates the missing record" log_has 'vpn.example.com A created with 5.6.7.8'
check "the API has the new address" mock_has 'A home.example.com 5.6.7.8 '
check "the API has the new record" mock_has 'A vpn.example.com 5.6.7.8 '
# The address changes and someone deletes home's record in the dashboard, so
# the cached record ID now returns 404 and the name has to be looked up again.
mock POST 'ip?value=9.9.9.9' >/dev/null
mock POST 'delete?type=A&name=home.example.com' >/dev/null
check "follows an address change" wait_for 30 log_has 'vpn.example.com A 5.6.7.8 -> 9.9.9.9'
check "recreates a record deleted behind its back" wait_for 30 log_has 'home.example.com A created with 9.9.9.9'
check "leaves current records alone" wait_for 30 log_has 'home.example.com A 9.9.9.9 unchanged'
check "writes only when something changed" mock_has 'writes 4'
check "reports healthy" nfa_health
check_prompt_stop
show_log failures "$before"

echo
echo "Address lookup failure"
before=$failed
nfa_start CF_RECORDS=home.example.com INTERVAL=3600 "IPV4_SOURCES=http://$MOCK_HOST:$PORT/missing"
check "warns that the address is unknown" wait_for 30 log_has 'could not determine the public IPv4 address'
check "backs off for 60 seconds" wait_for 10 log_has 'check incomplete; retrying in 60s'
check "reports unhealthy" not nfa_health
check_prompt_stop
show_log failures "$before"

echo
echo "API outage at startup"
before=$failed
mock POST 'fail?count=1&status=503' >/dev/null
nfa_start CF_RECORDS=home.example.com INTERVAL=3600
check "treats HTTP 503 as temporary" wait_for 30 log_has 'could not verify the API token: HTTP 503'
check "backs off instead of exiting" wait_for 10 log_has 'retrying in 60s'
check "is still running" nfa_running
check_prompt_stop
show_log failures "$before"

echo
echo "Missing record without CREATE_IF_MISSING"
before=$failed
nfa_start CF_RECORDS=nothere.example.com INTERVAL=3600
check "explains what to do" wait_for 30 log_has 'nothere.example.com has no A record; create it in Cloudflare or set CREATE_IF_MISSING=true'
check "waits for the next check" wait_for 10 log_has 'check finished with problems that need attention; next check in 3600s'
check "keeps running" nfa_running
check "reports unhealthy" not nfa_health
check_prompt_stop
show_log failures "$before"

echo
echo "Fatal problems"
before=$failed
nfa_run CF_RECORDS=home.example.com CF_API_TOKEN=not-the-right-token
check "a rejected token exits with status 1 (got $RUN_STATUS)" [ "$RUN_STATUS" -eq 1 ]
check "a rejected token is explained" log_has 'Cloudflare rejected the API token'
nfa_run CF_ZONE=example.org CF_RECORDS=home.example.org
check "an unknown zone exits with status 1 (got $RUN_STATUS)" [ "$RUN_STATUS" -eq 1 ]
check "an unknown zone is explained" log_has 'zone example.org was not found'
nfa_run CF_RECORDS=home.example.org INTERVAL=soon
check "invalid settings exit with status 2 (got $RUN_STATUS)" [ "$RUN_STATUS" -eq 2 ]
check "every invalid setting is reported" log_has "INTERVAL must be a whole number of seconds, not 'soon'"
check "records outside the zone are reported" log_has "CF_RECORDS entry 'home.example.org' is not in the zone example.com"
nfa_run CF_RECORDS=home.example.com CF_API_TOKEN=
check "a missing token exits with status 2 (got $RUN_STATUS)" [ "$RUN_STATUS" -eq 2 ]
show_log failures "$before"

echo
if [ "$failed" -eq 0 ]; then
    echo "All end-to-end checks passed."
else
    echo "$failed end-to-end check(s) failed."
    exit 1
fi
