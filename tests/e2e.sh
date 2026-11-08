#!/bin/sh
# End-to-end tests against tests/mock_cf_api.py: startup, a dry run, real
# updates, a record deleted behind the updater's back, turning the proxy on,
# records in several zones, lookup and API failures, fatal configuration
# problems, prompt shutdown, and the notifications each of those sends (or
# doesn't) to a webhook on the mock. Scenarios run both with ZONE set, the way
# installs from before 1.1.0 are set up, and without it, so each record's
# zone is found automatically. Which zone wins when several match, including
# zones that are not active yet, is covered by the unit tests in run.sh.
#
#   sh tests/e2e.sh                               # runs src/nofixedaddress.sh
#   NFA_IMAGE=nofixedaddress:dev sh tests/e2e.sh  # runs a built image instead
#
# NFA_PLATFORM, such as linux/arm/v7, is passed to docker run as --platform,
# for an image built for another architecture and run under QEMU.
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
PLATFORM=${NFA_PLATFORM:-}
DOCKER_NETWORK=${NFA_DOCKER_NETWORK:-host}
MOCK_HOST=${NFA_MOCK_HOST:-127.0.0.1}
MOCK_BIND=${MOCK_BIND:-127.0.0.1}
TOKEN=e2e-token_0123456789abcdef
ACCOUNT_TOKEN=cfat_e2e-account-token_0123456789

# Settings from the caller's environment must not leak into the runs below.
unset CF_API_TOKEN CF_API_TOKEN_FILE CF_ZONE CF_RECORDS ZONE RECORDS INTERVAL IPV4 IPV6 \
    PROXIED TTL CREATE_IF_MISSING DRY_RUN LOG_LEVEL IPV4_SOURCES IPV6_SOURCES \
    CF_API_URL STATE_DIR NOTIFY_URL NOTIFY_URL_FILE NOTIFY_FORMAT NFA_SOURCE_ONLY

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

# Two zones, one a subdomain zone of the other, listed one per page so that
# finding the zones without ZONE has to page through the listing.
start_mock() {
    "$PYTHON" "$here/mock_cf_api.py" --host "$MOCK_BIND" --port-file "$WORK/port" \
        --token "$TOKEN" --account-token "$ACCOUNT_TOKEN" \
        --zone example.com --zone sub.example.com --max-per-page 1 --ip 5.6.7.8 \
        --record A:home.example.com:1.2.3.4 --record A:host.sub.example.com:1.2.3.4 &
    MOCK_PID=$!
    if ! wait_for 20 test -s "$WORK/port"; then
        echo "the mock API did not start" >&2
        exit 1
    fi
    PORT=$(cat "$WORK/port")
    API_URL=http://$MOCK_HOST:$PORT/client/v4
    TRACE_URL=http://$MOCK_HOST:$PORT/trace
    # Each scenario that notifies uses its own path under this, so its
    # messages can be told apart.
    NOTIFY_BASE=http://$MOCK_HOST:$PORT/notify
}

# mock GET|POST PATH
mock() {
    curl -fsS -X "$1" "http://127.0.0.1:$PORT/_mock/$2"
}

mock_has() {
    mock GET state | grep -qF -- "$1"
}

# sent NAME COUNT [TEXT]
# True when exactly COUNT webhook requests to /notify/NAME (containing TEXT,
# if given) have reached the mock.
sent() {
    [ "$(mock GET notifications | grep -F -- " /notify/$1 " | grep -cF -- "${3:-}")" -eq "$2" ]
}

notifications_have() {
    mock GET notifications | grep -qF -- "$1"
}

# --- running the updater ------------------------------------------------------

# Starts the updater in the background with the shared settings plus "$@".
# ZONE is not shared: each scenario says whether it sets one.
nfa_start() {
    set -- "CF_API_TOKEN=$TOKEN" "CF_API_URL=$API_URL" \
        "IPV4_SOURCES=$TRACE_URL" LOG_LEVEL=debug "$@"
    : >"$WORK/out"
    if [ -n "$IMAGE" ]; then
        for kv do
            shift
            set -- "$@" -e "$kv"
        done
        [ -z "$PLATFORM" ] || set -- --platform "$PLATFORM" "$@"
        # Locked down the way the README and the Unraid template run it.
        CID=$(docker run -d --network "$DOCKER_NETWORK" --read-only --tmpfs /tmp \
            --cap-drop ALL --security-opt no-new-privileges "$@" "$IMAGE")
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
    set -- "CF_API_TOKEN=$TOKEN" "CF_API_URL=$API_URL" \
        "IPV4_SOURCES=$TRACE_URL" LOG_LEVEL=debug "$@"
    if [ -n "$IMAGE" ]; then
        for kv do
            shift
            set -- "$@" -e "$kv"
        done
        [ -z "$PLATFORM" ] || set -- --platform "$PLATFORM" "$@"
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

# log_count_at_least TEXT COUNT
log_count_at_least() {
    [ "$(nfa_logs | grep -cF -- "$1")" -ge "$2" ]
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
nfa_start RECORDS=home.example.com,vpn.example.com DRY_RUN=true CREATE_IF_MISSING=true INTERVAL=3600 \
    "NOTIFY_URL=$NOTIFY_BASE/dryrun" NOTIFY_FORMAT=json
check "completes the first check" wait_for 30 log_has 'check complete'
check "verifies the token" log_has 'API token verified'
check "pages through the zones" log_has 'GET /zones?per_page=50&page=2: HTTP 200'
check "finds the zone of every record" \
    log_has 'zone example.com: keeping A records for home.example.com, vpn.example.com pointed at this host'
check "reports the update it would make" log_has '[dry-run] home.example.com A 1.2.3.4 -> 5.6.7.8'
check "reports the record it would create" log_has '[dry-run] vpn.example.com A created with 5.6.7.8'
check "writes nothing" mock_has 'writes 0'
check "leaves the record as it was" mock_has 'A home.example.com 1.2.3.4 '
check "reports healthy after a successful check" nfa_health
check "never logs the token" not log_has "$TOKEN"
check "names the notification host" log_has "notifications: json via $MOCK_HOST"
check "warns about a plain http notification URL" log_has 'NOTIFY_URL uses plain http'
check "never logs the notification URL" not log_has '/notify/'
check "sends one message for the check" wait_for 10 sent dryrun 1
check "the message is JSON about an update" sent dryrun 1 'application/json'
check "the message lists what would change" \
    sent dryrun 1 '[dry-run] home.example.com A 1.2.3.4 -> 5.6.7.8\n[dry-run] vpn.example.com A created with 5.6.7.8'
check "the message has the event" sent dryrun 1 '"event":"updated"'
check_prompt_stop
show_log always

echo
echo "Account-owned token"
before=$failed
nfa_start "CF_API_TOKEN=$ACCOUNT_TOKEN" ZONE=example.com RECORDS=home.example.com DRY_RUN=true INTERVAL=3600
check "completes the first check" wait_for 30 log_has 'check complete'
check "verifies the token under its account" log_has 'API token verified (account-owned)'
check "says that ZONE is optional" log_has 'ZONE is optional since 1.1.0'
check "never logs the token" not log_has "$ACCOUNT_TOKEN"
check_prompt_stop
show_log failures "$before"

echo
echo "Live updates"
before=$failed
nfa_start RECORDS=home.example.com,vpn.example.com CREATE_IF_MISSING=true INTERVAL=2 \
    "NOTIFY_URL=$NOTIFY_BASE/live" NOTIFY_FORMAT=discord
check "completes the first check" wait_for 30 log_has 'check complete'
check "updates the stale record" log_has 'home.example.com A 1.2.3.4 -> 5.6.7.8'
check "creates the missing record" log_has 'vpn.example.com A created with 5.6.7.8'
check "the API has the new address" mock_has 'A home.example.com 5.6.7.8 '
check "the API has the new record" mock_has 'A vpn.example.com 5.6.7.8 '
check "announces the changes in one Discord message" wait_for 10 sent live 1 \
    '"content":"home.example.com A 1.2.3.4 -> 5.6.7.8\nvpn.example.com A created with 5.6.7.8"'
check "the Discord message is signed" sent live 1 '"username":"No Fixed Address"'
# The address changes and someone deletes home's record in the dashboard, so
# the cached record ID now returns 404 and the name has to be looked up again.
mock POST 'ip?value=9.9.9.9' >/dev/null
mock POST 'delete?type=A&name=home.example.com' >/dev/null
check "follows an address change" wait_for 30 log_has 'vpn.example.com A 5.6.7.8 -> 9.9.9.9'
check "recreates a record deleted behind its back" wait_for 30 log_has 'home.example.com A created with 9.9.9.9'
check "leaves current records alone" wait_for 30 log_has 'home.example.com A 9.9.9.9 unchanged'
check "writes only when something changed" mock_has 'writes 4'
check "reports healthy" nfa_health
check "announces the second changes" sent live 1 'vpn.example.com A 5.6.7.8 -> 9.9.9.9'
check "announces nothing when nothing changed" sent live 2
check_prompt_stop
show_log failures "$before"

echo
echo "Proxy status"
before=$failed
# home already has the current address, so only its proxy status differs. The
# webhook fails once, which must not stop the update.
mock POST 'notify-fail?count=1&status=500' >/dev/null
nfa_start ZONE=example.com RECORDS=home.example.com PROXIED=true INTERVAL=2 \
    "NOTIFY_URL=$NOTIFY_BASE/proxy" NOTIFY_FORMAT=ntfy
check "turns the proxy on" wait_for 30 log_has 'home.example.com A proxied false -> true'
check "the API has the record proxied" mock_has 'A home.example.com 9.9.9.9 proxied=true '
check "leaves it alone afterwards" wait_for 30 log_has 'home.example.com A 9.9.9.9 unchanged'
check "writes only once" mock_has 'writes 5'
check "a failed notification is a warning" log_has "notification to $MOCK_HOST failed: HTTP 500"
check "a failed notification is tried once" sent proxy 1
check "sends ntfy's title, tags and priority" \
    sent proxy 1 'text/plain title=No Fixed Address tags=white_check_mark priority=default'
check "sends the change as plain text" sent proxy 1 'body=home.example.com A proxied false -> true'
check_prompt_stop
show_log failures "$before"

echo
echo "Several zones"
before=$failed
# home is in example.com and host in its subdomain zone sub.example.com. An
# account-owned token without ZONE has to find its account from the listing.
mock POST 'ip?value=7.7.7.7' >/dev/null
nfa_start "CF_API_TOKEN=$ACCOUNT_TOKEN" RECORDS=home.example.com,host.sub.example.com INTERVAL=3600
check "completes the first check" wait_for 30 log_has 'check complete'
check "verifies an account-owned token without ZONE" log_has 'API token verified (account-owned)'
check "finds the parent zone" \
    log_has 'zone example.com: keeping A records for home.example.com pointed at this host'
check "finds the subdomain zone" \
    log_has 'zone sub.example.com: keeping A records for host.sub.example.com pointed at this host'
check "updates the record in the parent zone" log_has 'home.example.com A 9.9.9.9 -> 7.7.7.7'
check "updates the record in the subdomain zone" log_has 'host.sub.example.com A 1.2.3.4 -> 7.7.7.7'
check "the parent zone has the new address" mock_has 'example.com A home.example.com 7.7.7.7 '
check "the subdomain zone has the new address" mock_has 'sub.example.com A host.sub.example.com 7.7.7.7 '
check "writes once per record" mock_has 'writes 7'
check_prompt_stop
show_log failures "$before"

echo
echo "Address lookup failure"
before=$failed
nfa_start ZONE=example.com RECORDS=home.example.com INTERVAL=3600 "IPV4_SOURCES=http://$MOCK_HOST:$PORT/missing" \
    "NOTIFY_URL=$NOTIFY_BASE/lookup" NOTIFY_FORMAT=json
check "warns that the address is unknown" wait_for 30 log_has 'could not determine the public IPv4 address'
check "backs off for 60 seconds" wait_for 10 log_has 'check incomplete; retrying in 60s'
check "reports unhealthy" not nfa_health
check "does not notify about trouble that may pass" sent lookup 0
check_prompt_stop
show_log failures "$before"

echo
echo "API outage at startup"
before=$failed
mock POST 'fail?count=1&status=503' >/dev/null
nfa_start ZONE=example.com RECORDS=home.example.com INTERVAL=3600
check "treats HTTP 503 as temporary" wait_for 30 log_has 'could not verify the API token: HTTP 503'
check "backs off instead of exiting" wait_for 10 log_has 'retrying in 60s'
check "is still running" nfa_running
check_prompt_stop
show_log failures "$before"

echo
echo "Missing record without CREATE_IF_MISSING"
before=$failed
nfa_start RECORDS=nothere.example.com INTERVAL=2 "NOTIFY_URL=$NOTIFY_BASE/missing" NOTIFY_FORMAT=json
check "explains what to do" wait_for 30 log_has 'nothere.example.com has no A record; create it in Cloudflare or set CREATE_IF_MISSING=true'
check "waits for the next check" wait_for 10 log_has 'check finished with problems that need attention; next check in 2s'
check "keeps running" nfa_running
check "reports unhealthy" not nfa_health
check "reports the problem at once" wait_for 10 sent missing 1 '"event":"failing"'
check "says what the problem is" \
    sent missing 1 'needs attention:\nnothere.example.com has no A record; create it in Cloudflare or set CREATE_IF_MISSING=true'
check "keeps failing" wait_for 15 log_count_at_least 'nothere.example.com has no A record' 3
check "reports the problem only once" sent missing 1
# Someone creates the record in the dashboard.
mock POST 'add?type=A&name=nothere.example.com&content=7.7.7.7' >/dev/null
check "reports that it works again" wait_for 30 sent missing 1 '"event":"recovered"'
check "says what it found" sent missing 1 '"message":"working again (IPv4 7.7.7.7)"'
check "sends nothing else" sent missing 2
check "reports healthy again" nfa_health
check_prompt_stop
show_log failures "$before"

echo
echo "Fatal problems"
before=$failed
nfa_run RECORDS=home.example.com CF_API_TOKEN=not-the-right-token "NOTIFY_URL=$NOTIFY_BASE/fatal" NOTIFY_FORMAT=text
check "a rejected token exits with status 1 (got $RUN_STATUS)" [ "$RUN_STATUS" -eq 1 ]
check "a rejected token is explained" log_has 'Cloudflare rejected the API token'
check "stopping is notified" sent fatal 1 'text/plain'
check "the notification says why" sent fatal 1 'body=No Fixed Address: stopping:\nCloudflare rejected the API token'
nfa_run ZONE=example.org RECORDS=home.example.org
check "an unknown zone exits with status 1 (got $RUN_STATUS)" [ "$RUN_STATUS" -eq 1 ]
check "an unknown zone is explained" log_has 'zone example.org was not found'
nfa_run RECORDS=home.example.com,home.example.org
check "a record in no zone exits with status 1 (got $RUN_STATUS)" [ "$RUN_STATUS" -eq 1 ]
check "a record in no zone is explained" \
    log_has 'no zone was found for home.example.org; check the name, and that the token has Zone:Zone:Read for its zone (the token can see example.com, sub.example.com)'
nfa_run ZONE=example.com RECORDS=home.example.org INTERVAL=soon "NOTIFY_URL=$NOTIFY_BASE/config" NOTIFY_FORMAT=json
check "invalid settings exit with status 2 (got $RUN_STATUS)" [ "$RUN_STATUS" -eq 2 ]
check "every invalid setting is reported" log_has "INTERVAL must be a whole number of seconds, not 'soon'"
check "records outside the zone are reported" log_has "RECORDS entry 'home.example.org' is not in the zone example.com"
check "invalid settings are not notified" sent config 0
nfa_run RECORDS=home.example.com "NOTIFY_URL=$NOTIFY_BASE/auto"
check "an unrecognised webhook without NOTIFY_FORMAT exits with status 2 (got $RUN_STATUS)" [ "$RUN_STATUS" -eq 2 ]
check "an unrecognised webhook is explained by its host" log_has "NOTIFY_URL points at $MOCK_HOST;"
check "an unrecognised webhook's path is not logged" not log_has '/notify/auto'
nfa_run RECORDS=@
check "@ without ZONE exits with status 2 (got $RUN_STATUS)" [ "$RUN_STATUS" -eq 2 ]
check "@ without ZONE is explained" log_has "RECORDS entry '@' needs ZONE"
nfa_run RECORDS=home.example.com CF_API_TOKEN=
check "a missing token exits with status 2 (got $RUN_STATUS)" [ "$RUN_STATUS" -eq 2 ]
check "no notification contains the token" not notifications_have "$TOKEN"
check "no notification contains the account token" not notifications_have "$ACCOUNT_TOKEN"
check "no notification contains a rejected token" not notifications_have not-the-right-token
show_log failures "$before"

echo
if [ "$failed" -eq 0 ]; then
    echo "All end-to-end checks passed."
else
    echo "$failed end-to-end check(s) failed."
    exit 1
fi
