#!/bin/sh
# Offline tests for the parts of nofixedaddress.sh that need no network:
# address validation and normalisation, configuration parsing, backoff, the
# record ID cache and the health check.
#
#   sh tests/run.sh
#
# NFA_SCRIPT selects another copy of the script, such as the one installed in
# the image, so the same tests can run under busybox ash:
#
#   docker run --rm --entrypoint sh -v "$PWD/tests:/tests:ro" \
#       -e NFA_SCRIPT=/usr/local/bin/nofixedaddress IMAGE /tests/run.sh

set -u

here=$(cd "$(dirname "$0")" && pwd)
NFA_SCRIPT=${NFA_SCRIPT:-$here/../src/nofixedaddress.sh}
# Read by the sourced script: load the functions without starting the daemon.
# shellcheck disable=SC2034
NFA_SOURCE_ONLY=1
# shellcheck source=src/nofixedaddress.sh
. "$NFA_SCRIPT"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
LOGFILE=$TMP/test.log
passed=0
failed=0

fail() {
    failed=$((failed + 1))
    printf 'FAIL  %s\n' "$1"
}

# expect_eq DESCRIPTION EXPECTED ACTUAL
expect_eq() {
    if [ "$2" = "$3" ]; then
        passed=$((passed + 1))
    else
        fail "$1: expected '$2', got '$3'"
    fi
}

# expect_ok DESCRIPTION COMMAND...
expect_ok() {
    desc=$1
    shift
    if "$@" >>"$LOGFILE" 2>&1; then
        passed=$((passed + 1))
    else
        fail "$desc"
    fi
}

# expect_fail DESCRIPTION COMMAND...
expect_fail() {
    desc=$1
    shift
    if "$@" >>"$LOGFILE" 2>&1; then
        fail "$desc"
    else
        passed=$((passed + 1))
    fi
}

# config SETTING=value... [-- COMMAND...]
# Runs load_config in a subshell that has exactly the given settings, then
# runs COMMAND there to inspect the result. The exit status is load_config's
# when it fails, otherwise COMMAND's. Log output lands in $TMP/config.log.
config() {
    (
        unset CF_API_TOKEN CF_API_TOKEN_FILE CF_ZONE CF_RECORDS INTERVAL IPV4 \
            IPV6 PROXIED TTL CREATE_IF_MISSING DRY_RUN LOG_LEVEL IPV4_SOURCES \
            IPV6_SOURCES CF_API_URL STATE_DIR
        while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
            export "${1?}"
            shift
        done
        [ "$#" -eq 0 ] || shift
        load_config >"$TMP/config.log" 2>&1 || exit
        [ "$#" -eq 0 ] || "$@"
    )
}

show() {
    eval "printf '%s' \"\$$1\""
}

TOKEN=CF_API_TOKEN=Abc123_-.~+/=token
ZONE=CF_ZONE=example.com
RECS=CF_RECORDS=home.example.com

# --- IPv4 -------------------------------------------------------------------

for ip in 1.2.3.4 5.6.7.8 8.8.8.8 9.9.9.9 100.63.255.255 100.128.0.1 \
    169.253.1.1 172.15.0.1 172.32.0.1 192.0.3.1 192.169.0.1 198.17.255.255 \
    198.20.0.1 198.51.101.1 203.0.114.1 223.255.255.255; do
    expect_ok "public IPv4 $ip is accepted" is_public_ipv4 "$ip"
done

for ip in 10.0.0.1 127.0.0.1 192.168.1.1 0.0.0.0; do
    expect_ok "well-formed IPv4 $ip passes the format check" is_ipv4 "$ip"
done

for ip in 1.2.3 1.2.3.4.5 1.2.3. .1.2.3 1..2.3 256.1.1.1 1.2.3.256 01.2.3.4 \
    1.2.3.04 00.1.2.3 1234.1.1.1 a.b.c.d 1.2.3.-4 -1.2.3.4 +1.2.3.4 \
    0x1.2.3.4 1.2.3.4/24 '1.2.3.4 ' ' 1.2.3.4' "1.2.3.4$NL" ''; do
    expect_fail "malformed IPv4 '$ip' is rejected" is_public_ipv4 "$ip"
done

for ip in 0.0.0.0 0.1.2.3 10.0.0.1 10.255.255.255 100.64.0.1 100.127.255.255 \
    127.0.0.1 169.254.1.1 172.16.0.1 172.31.255.255 192.0.0.1 192.0.2.1 \
    192.168.1.1 198.18.0.1 198.19.255.255 198.51.100.7 203.0.113.9 224.0.0.1 \
    239.255.255.250 240.0.0.1 255.255.255.255; do
    expect_fail "non-public IPv4 $ip is rejected" is_public_ipv4 "$ip"
done

# --- IPv6 -------------------------------------------------------------------

check_ipv6() {
    expect_eq "IPv6 $1 normalises" "$2" "$(normalize_ipv6 "$1")"
}
check_ipv6 2001:DB8:0:0:0:0:0:1 2001:db8::1
check_ipv6 2001:0db8:0000:0000:0000:0000:0000:0001 2001:db8::1
check_ipv6 2606:4700:4700:0:0:0:0:1111 2606:4700:4700::1111
check_ipv6 2606:4700:4700::1111 2606:4700:4700::1111
check_ipv6 2001:db8:0:1:1:1:1:1 2001:db8:0:1:1:1:1:1
check_ipv6 2001:0:0:1:0:0:0:1 2001:0:0:1::1
check_ipv6 2001:db8:0:0:1:0:0:1 2001:db8::1:0:0:1
check_ipv6 1:2:3:4:5:6:7:8 1:2:3:4:5:6:7:8
check_ipv6 1:2:3:4:5:6:7:: 1:2:3:4:5:6:7:0
check_ipv6 ::2:3:4:5:6:7:8 0:2:3:4:5:6:7:8
check_ipv6 FE80::1 fe80::1
check_ipv6 ::1 ::1
check_ipv6 :: ::
check_ipv6 1:: 1::
check_ipv6 0:0:0:0:0:0:0:0 ::

for ip in '' 1:2:3:4:5:6:7 1:2:3:4:5:6:7:8:9 1:2:3:4:5:6:7:8:: 1::2::3 :::1 \
    1:::2 12345::1 g::1 ::ffff:1.2.3.4 fe80::1%eth0 :1:2:3:4:5:6:7 \
    1:2:3:4:5:6:7: '[2001:db8::1]' ' 2001:db8::1' "2001:db8::1$NL"; do
    expect_fail "malformed IPv6 '$ip' is rejected" normalize_ipv6 "$ip"
done

for ip in 2606:4700:4700::1111 2a00:1450:4001:82a::200e 2001:4860:4860::8888 \
    3fff:1::1; do
    expect_ok "public IPv6 $ip is accepted" is_public_ipv6 "$ip"
done

for ip in :: ::1 fe80::1 febf::1 fc00::1 fd12:3456::1 ff02::1 2001:db8::1 \
    ::ffff:102:304 64:ff9b::102:304 100::1 200::1 1fff::1 4000::1; do
    expect_fail "non-public IPv6 $ip is rejected" is_public_ipv6 "$ip"
done

# --- lookup responses -------------------------------------------------------

printf 'fl=123\nh=1.1.1.1\nip=5.6.7.8\nts=1700000000.1\n' >"$TMP/trace"
expect_eq "trace response" 5.6.7.8 "$(extract_ip "$TMP/trace")"
printf 'fl=1\r\nip=2606:4700::1\r\n' >"$TMP/trace-crlf"
expect_eq "trace response with CRLF" 2606:4700::1 "$(extract_ip "$TMP/trace-crlf")"
printf '5.6.7.8' >"$TMP/plain"
expect_eq "plain response without newline" 5.6.7.8 "$(extract_ip "$TMP/plain")"
printf ' 5.6.7.8 \r\n' >"$TMP/plain-ws"
expect_eq "plain response with whitespace" 5.6.7.8 "$(extract_ip "$TMP/plain-ws")"
printf '<html>\n<body>blocked</body>\n</html>\n' >"$TMP/html"
expect_eq "multi-line response without ip=" '' "$(extract_ip "$TMP/html")"
: >"$TMP/empty"
expect_eq "empty response" '' "$(extract_ip "$TMP/empty")"
expect_eq "control characters are dropped from logged responses" 'a31mb' \
    "$(printable "$(printf 'a\033[31mb')")"
long_response=$(printable "$(printf '%080d' 0)")
expect_eq "logged responses are truncated" 64 "${#long_response}"

# --- small parsers ----------------------------------------------------------

for v in true TRUE True yes Yes on ON 1; do
    expect_eq "parse_bool $v" true "$(parse_bool "$v")"
done
for v in false FALSE no No off OFF 0; do
    expect_eq "parse_bool $v" false "$(parse_bool "$v")"
done
for v in maybe tru 2 '' ' true'; do
    expect_fail "parse_bool rejects '$v'" parse_bool "$v"
done

expect_eq "parse_uint strips leading zeros" 300 "$(parse_uint 0300)"
expect_eq "parse_uint of all zeros" 0 "$(parse_uint 000)"
expect_eq "parse_uint plain" 86400 "$(parse_uint 86400)"
for v in '' 1e3 -1 +1 ' 1' 1.5 1234567890; do
    expect_fail "parse_uint rejects '$v'" parse_uint "$v"
done

for name in example.com home.example.com '*.example.com' '*.home.example.com' \
    _acme-challenge.example.com a-b.example.com x1.example.com; do
    expect_ok "hostname $name is accepted" is_hostname "$name"
done
long_label=$(printf '%064d' 0)
for name in '' home..example.com .example.com example.com. 'home example.com' \
    https://home.example.com '*' '*.' a.*.example.com '*example.com' \
    Home.example.com "$long_label.example.com"; do
    expect_fail "hostname '$name' is rejected" is_hostname "$name"
done

value='  padded token  '
trim_var value
expect_eq "trim_var strips spaces" 'padded token' "$value"
value="$TAB$CR${NL}x$CR$NL"
trim_var value
expect_eq "trim_var strips tabs and line endings" x "$value"

# --- configuration ----------------------------------------------------------

expect_ok "minimal config loads" config "$TOKEN" "$ZONE" "$RECS"
expect_eq "default INTERVAL" 86400 "$(config "$TOKEN" "$ZONE" "$RECS" -- show INTERVAL)"
expect_eq "default IPV4" true "$(config "$TOKEN" "$ZONE" "$RECS" -- show IPV4)"
expect_eq "default IPV6" false "$(config "$TOKEN" "$ZONE" "$RECS" -- show IPV6)"
expect_eq "default PROXIED preserves" '' "$(config "$TOKEN" "$ZONE" "$RECS" -- show PROXIED)"
expect_eq "default TTL preserves" '' "$(config "$TOKEN" "$ZONE" "$RECS" -- show TTL)"
expect_eq "default CREATE_IF_MISSING" false "$(config "$TOKEN" "$ZONE" "$RECS" -- show CREATE_IF_MISSING)"
expect_eq "default DRY_RUN" false "$(config "$TOKEN" "$ZONE" "$RECS" -- show DRY_RUN)"
expect_eq "default log threshold" 20 "$(config "$TOKEN" "$ZONE" "$RECS" -- show LOG_THRESHOLD)"
expect_eq "default API URL" https://api.cloudflare.com/client/v4 \
    "$(config "$TOKEN" "$ZONE" "$RECS" -- show CF_API_URL)"
expect_eq "default state dir" /tmp/nofixedaddress "$(config "$TOKEN" "$ZONE" "$RECS" -- show STATE_DIR)"
expect_eq "default IPv4 sources" "$DEFAULT_IPV4_SOURCES" \
    "$(config "$TOKEN" "$ZONE" "$RECS" -- show IPV4_SOURCES)"
expect_eq "default IPv6 sources" "$DEFAULT_IPV6_SOURCES" \
    "$(config "$TOKEN" "$ZONE" "$RECS" -- show IPV6_SOURCES)"

# Unraid passes every template field, blank or not.
blank_check() {
    printf '%s %s %s %s %s' "$INTERVAL" "$IPV4" "$IPV6" "$PROXIED" "$TTL"
}
expect_eq "blank settings fall back to defaults" '86400 true false  ' \
    "$(config "$TOKEN" "$ZONE" "$RECS" INTERVAL= IPV4= IPV6= PROXIED= TTL= \
        CF_API_TOKEN_FILE= LOG_LEVEL= IPV4_SOURCES= CF_API_URL= STATE_DIR= -- blank_check)"

# Token handling.
expect_eq "token is trimmed" abc "$(config 'CF_API_TOKEN=  abc  ' "$ZONE" "$RECS" -- show NFA_TOKEN)"
child_sees() {
    sh -c 'printf "%s/%s" "${CF_API_TOKEN:-unset}" "${NFA_TOKEN:-unset}"'
}
expect_eq "token is not passed to child processes" unset/unset \
    "$(config "$TOKEN" "$ZONE" "$RECS" -- child_sees)"
expect_fail "missing token is an error" config "$ZONE" "$RECS"
expect_fail "whitespace-only token is an error" config 'CF_API_TOKEN=   ' "$ZONE" "$RECS"
expect_fail 'token with a quote is rejected' config 'CF_API_TOKEN=abc"def' "$ZONE" "$RECS"
expect_fail 'token with inner space is rejected' config 'CF_API_TOKEN=abc def' "$ZONE" "$RECS"
config 'CF_API_TOKEN=secret"value' "$ZONE" "$RECS" >/dev/null 2>&1
expect_fail "a rejected token is not echoed in the log" grep -q secret "$TMP/config.log"

printf 'filetoken' >"$TMP/token-no-newline"
printf 'filetoken\r\n' >"$TMP/token-crlf"
printf '  filetoken  \nsecond line\n' >"$TMP/token-padded"
: >"$TMP/token-empty"
for f in token-no-newline token-crlf token-padded; do
    expect_eq "token file $f" filetoken \
        "$(config "CF_API_TOKEN_FILE=$TMP/$f" "$ZONE" "$RECS" -- show NFA_TOKEN)"
done
expect_fail "empty token file is an error" config "CF_API_TOKEN_FILE=$TMP/token-empty" "$ZONE" "$RECS"
expect_fail "missing token file is an error" config "CF_API_TOKEN_FILE=$TMP/nope" "$ZONE" "$RECS"
expect_fail "token and token file together are an error" \
    config "$TOKEN" "CF_API_TOKEN_FILE=$TMP/token-crlf" "$ZONE" "$RECS"

# Zone and records.
expect_eq "zone is lowercased and loses its trailing dot" example.com \
    "$(config "$TOKEN" 'CF_ZONE= Example.COM. ' "$RECS" -- show CF_ZONE)"
expect_fail "missing zone is an error" config "$TOKEN" "$RECS"
expect_fail "single-label zone is an error" config "$TOKEN" CF_ZONE=localhost CF_RECORDS=localhost
expect_fail "wildcard zone is an error" config "$TOKEN" 'CF_ZONE=*.example.com' "$RECS"
expect_eq "records are trimmed, lowercased and de-duplicated" \
    'home.example.com vpn.example.com example.com *.lan.example.com' \
    "$(config "$TOKEN" "$ZONE" \
        'CF_RECORDS= Home.Example.com , vpn.example.com,,home.example.com. ,@,example.com,*.lan.example.com' \
        -- show RECORDS)"
expect_fail "missing records are an error" config "$TOKEN" "$ZONE"
expect_fail "blank records are an error" config "$TOKEN" "$ZONE" 'CF_RECORDS= , '
expect_fail "record in another zone is an error" config "$TOKEN" "$ZONE" CF_RECORDS=home.example.org
expect_fail "record that only ends with the zone name is an error" \
    config "$TOKEN" "$ZONE" CF_RECORDS=notexample.com
expect_fail "record that is a URL is an error" config "$TOKEN" "$ZONE" CF_RECORDS=https://home.example.com

# Numbers.
expect_eq "INTERVAL with leading zero is decimal" 300 \
    "$(config "$TOKEN" "$ZONE" "$RECS" INTERVAL=0300 -- show INTERVAL)"
expect_eq "INTERVAL is trimmed" 600 "$(config "$TOKEN" "$ZONE" "$RECS" 'INTERVAL= 600 ' -- show INTERVAL)"
for v in 0 -5 abc 1.5 1h; do
    expect_fail "INTERVAL=$v is an error" config "$TOKEN" "$ZONE" "$RECS" "INTERVAL=$v"
done
config "$TOKEN" "$ZONE" "$RECS" INTERVAL=30 >/dev/null 2>&1
expect_ok "a very short INTERVAL is allowed but warned about" grep -q 'INTERVAL=30' "$TMP/config.log"

for v in 1 60 300 86400; do
    expect_eq "TTL=$v is accepted" "$v" "$(config "$TOKEN" "$ZONE" "$RECS" "TTL=$v" -- show TTL)"
done
for v in 0 2 59 86401 auto; do
    expect_fail "TTL=$v is an error" config "$TOKEN" "$ZONE" "$RECS" "TTL=$v"
done
config "$TOKEN" "$ZONE" "$RECS" PROXIED=true TTL=300 >/dev/null 2>&1
expect_ok "TTL on proxied records is warned about" grep -q 'no effect' "$TMP/config.log"

# Booleans.
families() {
    printf '%s/%s' "$IPV4" "$IPV6"
}
expect_eq "IPV4/IPV6 accept yes/no" false/true \
    "$(config "$TOKEN" "$ZONE" "$RECS" IPV4=no IPV6=Yes -- families)"
expect_fail "IPV4 and IPV6 both off is an error" config "$TOKEN" "$ZONE" "$RECS" IPV4=false IPV6=false
expect_fail "IPV6=maybe is an error" config "$TOKEN" "$ZONE" "$RECS" IPV6=maybe
expect_eq "PROXIED=TRUE" true "$(config "$TOKEN" "$ZONE" "$RECS" PROXIED=TRUE -- show PROXIED)"
expect_eq "DRY_RUN=1" true "$(config "$TOKEN" "$ZONE" "$RECS" DRY_RUN=1 -- show DRY_RUN)"

# Logging and endpoints.
expect_eq "LOG_LEVEL=DEBUG" 10 "$(config "$TOKEN" "$ZONE" "$RECS" LOG_LEVEL=DEBUG -- show LOG_THRESHOLD)"
expect_eq "LOG_LEVEL=warning" warn "$(config "$TOKEN" "$ZONE" "$RECS" LOG_LEVEL=warning -- show LOG_LEVEL)"
expect_fail "LOG_LEVEL=verbose is an error" config "$TOKEN" "$ZONE" "$RECS" LOG_LEVEL=verbose
expect_eq "source lists lose whitespace" 'https://a.example/ip,http://b.example/ip' \
    "$(config "$TOKEN" "$ZONE" "$RECS" 'IPV4_SOURCES= https://a.example/ip , http://b.example/ip ' -- show IPV4_SOURCES)"
expect_fail "non-HTTP source is an error" config "$TOKEN" "$ZONE" "$RECS" IPV4_SOURCES=ftp://a.example/ip
expect_eq "API URL loses its trailing slash" http://127.0.0.1:8080/client/v4 \
    "$(config "$TOKEN" "$ZONE" "$RECS" CF_API_URL=http://127.0.0.1:8080/client/v4/ -- show CF_API_URL)"
expect_fail "API URL without a scheme is an error" config "$TOKEN" "$ZONE" "$RECS" CF_API_URL=api.cloudflare.com

config CF_RECORDS=home.example.com INTERVAL=abc TTL=7 >/dev/null 2>&1
expect_eq "every config problem is reported at once" 4 "$(grep -c 'config:' "$TMP/config.log")"

# --- logging ----------------------------------------------------------------

(
    LOG_THRESHOLD=30
    log info hidden
    log warn shown
) >"$TMP/stdout" 2>"$TMP/stderr"
expect_eq "info below the threshold is dropped" '' "$(cat "$TMP/stdout")"
expect_ok "warnings go to stderr" grep -q 'warn  shown$' "$TMP/stderr"

# --- backoff ----------------------------------------------------------------

delays=''
delay=0
for _ in 1 2 3 4 5 6 7 8; do
    delay=$(next_backoff "$delay")
    delays="$delays $delay"
done
expect_eq "backoff doubles from 60s and stops at an hour" \
    ' 60 120 240 480 960 1920 3600 3600' "$delays"

# --- record ID cache --------------------------------------------------------

RECORD_CACHE=''
cache_put A home.example.com id1
cache_put AAAA home.example.com id2
cache_put A vpn.example.com id3
expect_eq "cache returns the A ID" id1 "$(cache_get A home.example.com)"
expect_eq "cache keeps types apart" id2 "$(cache_get AAAA home.example.com)"
cache_put A home.example.com id4
expect_eq "cache replaces an entry" id4 "$(cache_get A home.example.com)"
cache_del A home.example.com
expect_eq "cache forgets a deleted entry" '' "$(cache_get A home.example.com)"
expect_eq "cache keeps the other entries" 'id2 id3' \
    "$(cache_get AAAA home.example.com) $(cache_get A vpn.example.com)"
expect_eq "cache misses unknown names" '' "$(cache_get A '*.example.com')"
RECORD_CACHE=''

# --- health check -----------------------------------------------------------

health() {
    (
        unset INTERVAL
        STATE_DIR=$TMP/state
        [ -z "${2:-}" ] || INTERVAL=$2
        mkdir -p "$STATE_DIR"
        if [ "$1" = none ]; then
            rm -f "$STATE_DIR/last-success"
        else
            printf '%s\n' "$1" >"$STATE_DIR/last-success"
        fi
        healthcheck
    )
}
now=$(date +%s)
expect_fail "no recorded success is unhealthy" health none
expect_ok "a fresh success is healthy" health "$now"
expect_ok "a success inside INTERVAL plus grace is healthy" health $((now - 10000)) 3600
expect_fail "a success older than INTERVAL plus grace is unhealthy" health $((now - 11000)) 3600
expect_ok "the default INTERVAL is a day" health $((now - 90000))
expect_fail "a day plus more than two hours is unhealthy" health $((now - 94000))
expect_ok "a blank INTERVAL means the default" health $((now - 90000)) ' '
expect_fail "a corrupt timestamp is unhealthy" health 'not-a-time'

# --- command line -----------------------------------------------------------

expect_eq "version prints the name" nofixedaddress "$(sh "$NFA_SCRIPT" version | cut -d ' ' -f 1)"
expect_fail "unknown commands fail" sh "$NFA_SCRIPT" bogus

printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
