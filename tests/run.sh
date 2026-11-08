#!/bin/sh
# Offline tests for the parts of nofixedaddress.sh that need no network:
# address validation and normalisation, configuration parsing, backoff, the
# record ID cache, matching records to zones, notification messages and when
# they are sent, and the health check.
#
#   sh tests/run.sh
#
# Needs jq, which builds the notification messages.
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
        unset CF_API_TOKEN CF_API_TOKEN_FILE CF_ZONE CF_RECORDS ZONE RECORDS INTERVAL IPV4 \
            IPV6 PROXIED TTL CREATE_IF_MISSING DRY_RUN LOG_LEVEL IPV4_SOURCES \
            IPV6_SOURCES CF_API_URL STATE_DIR NOTIFY_URL NOTIFY_URL_FILE NOTIFY_FORMAT
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
ZONE_ARG=ZONE=example.com
RECS=RECORDS=home.example.com

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
    192.88.99.1 192.168.1.1 198.18.0.1 198.19.255.255 198.51.100.7 203.0.113.9 224.0.0.1 \
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
    3fff:1000::1 3ffe:1::1; do
    expect_ok "public IPv6 $ip is accepted" is_public_ipv6 "$ip"
done

for ip in :: ::1 fe80::1 febf::1 fc00::1 fd12:3456::1 ff02::1 2001:db8::1 \
    3fff::1 3fff:1::1 3fff:ab::1 3fff:fff::1 \
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

expect_ok "minimal config loads" config "$TOKEN" "$ZONE_ARG" "$RECS"
expect_eq "default INTERVAL" 86400 "$(config "$TOKEN" "$ZONE_ARG" "$RECS" -- show INTERVAL)"
expect_eq "default IPV4" true "$(config "$TOKEN" "$ZONE_ARG" "$RECS" -- show IPV4)"
expect_eq "default IPV6" false "$(config "$TOKEN" "$ZONE_ARG" "$RECS" -- show IPV6)"
expect_eq "default PROXIED preserves" '' "$(config "$TOKEN" "$ZONE_ARG" "$RECS" -- show PROXIED)"
expect_eq "default TTL preserves" '' "$(config "$TOKEN" "$ZONE_ARG" "$RECS" -- show TTL)"
expect_eq "default CREATE_IF_MISSING" false "$(config "$TOKEN" "$ZONE_ARG" "$RECS" -- show CREATE_IF_MISSING)"
expect_eq "default DRY_RUN" false "$(config "$TOKEN" "$ZONE_ARG" "$RECS" -- show DRY_RUN)"
expect_eq "default log threshold" 20 "$(config "$TOKEN" "$ZONE_ARG" "$RECS" -- show LOG_THRESHOLD)"
expect_eq "default API URL" https://api.cloudflare.com/client/v4 \
    "$(config "$TOKEN" "$ZONE_ARG" "$RECS" -- show CF_API_URL)"
expect_eq "default state dir" /tmp/nofixedaddress "$(config "$TOKEN" "$ZONE_ARG" "$RECS" -- show STATE_DIR)"
expect_eq "default IPv4 sources" "$DEFAULT_IPV4_SOURCES" \
    "$(config "$TOKEN" "$ZONE_ARG" "$RECS" -- show IPV4_SOURCES)"
expect_eq "default IPv6 sources" "$DEFAULT_IPV6_SOURCES" \
    "$(config "$TOKEN" "$ZONE_ARG" "$RECS" -- show IPV6_SOURCES)"

# Unraid passes every template field, blank or not.
blank_check() {
    printf '%s %s %s %s %s' "$INTERVAL" "$IPV4" "$IPV6" "$PROXIED" "$TTL"
}
expect_eq "blank settings fall back to defaults" '86400 true false  ' \
    "$(config "$TOKEN" "$ZONE_ARG" "$RECS" INTERVAL= IPV4= IPV6= PROXIED= TTL= \
        CF_API_TOKEN_FILE= LOG_LEVEL= IPV4_SOURCES= CF_API_URL= STATE_DIR= -- blank_check)"

# Token handling.
expect_eq "token is trimmed" abc "$(config 'CF_API_TOKEN=  abc  ' "$ZONE_ARG" "$RECS" -- show NFA_TOKEN)"
child_sees() {
    sh -c 'printf "%s/%s" "${CF_API_TOKEN:-unset}" "${NFA_TOKEN:-unset}"'
}
expect_eq "token is not passed to child processes" unset/unset \
    "$(config "$TOKEN" "$ZONE_ARG" "$RECS" -- child_sees)"
expect_fail "missing token is an error" config "$ZONE_ARG" "$RECS"
expect_fail "whitespace-only token is an error" config 'CF_API_TOKEN=   ' "$ZONE_ARG" "$RECS"
expect_fail 'token with a quote is rejected' config 'CF_API_TOKEN=abc"def' "$ZONE_ARG" "$RECS"
expect_fail 'token with inner space is rejected' config 'CF_API_TOKEN=abc def' "$ZONE_ARG" "$RECS"
config 'CF_API_TOKEN=secret"value' "$ZONE_ARG" "$RECS" >/dev/null 2>&1
expect_fail "a rejected token is not echoed in the log" grep -q secret "$TMP/config.log"

printf 'filetoken' >"$TMP/token-no-newline"
printf 'filetoken\r\n' >"$TMP/token-crlf"
printf '  filetoken  \nsecond line\n' >"$TMP/token-padded"
: >"$TMP/token-empty"
for f in token-no-newline token-crlf token-padded; do
    expect_eq "token file $f" filetoken \
        "$(config "CF_API_TOKEN_FILE=$TMP/$f" "$ZONE_ARG" "$RECS" -- show NFA_TOKEN)"
done
expect_fail "empty token file is an error" config "CF_API_TOKEN_FILE=$TMP/token-empty" "$ZONE_ARG" "$RECS"
expect_fail "missing token file is an error" config "CF_API_TOKEN_FILE=$TMP/nope" "$ZONE_ARG" "$RECS"
expect_fail "token and token file together are an error" \
    config "$TOKEN" "CF_API_TOKEN_FILE=$TMP/token-crlf" "$ZONE_ARG" "$RECS"

# Zone and records.
expect_eq "zone is lowercased and loses its trailing dot" example.com \
    "$(config "$TOKEN" 'ZONE= Example.COM. ' "$RECS" -- show ZONE)"
expect_ok "missing zone is allowed" config "$TOKEN" "$RECS"
expect_eq "blank zone stays blank" '' "$(config "$TOKEN" 'ZONE= ' "$RECS" -- show ZONE)"
expect_fail "single-label zone is an error" config "$TOKEN" ZONE=localhost RECORDS=localhost
expect_fail "wildcard zone is an error" config "$TOKEN" 'ZONE=*.example.com' "$RECS"
expect_eq "records are trimmed, lowercased and de-duplicated" \
    'home.example.com vpn.example.com example.com *.lan.example.com' \
    "$(config "$TOKEN" "$ZONE_ARG" \
        'RECORDS= Home.Example.com , vpn.example.com,,home.example.com. ,@,example.com,*.lan.example.com' \
        -- show RECORD_NAMES)"
expect_fail "missing records are an error" config "$TOKEN" "$ZONE_ARG"
expect_fail "blank records are an error" config "$TOKEN" "$ZONE_ARG" 'RECORDS= , '
expect_fail "record in another zone is an error" config "$TOKEN" "$ZONE_ARG" RECORDS=home.example.org
expect_fail "record that only ends with the zone name is an error" \
    config "$TOKEN" "$ZONE_ARG" RECORDS=notexample.com
expect_fail "record that is a URL is an error" config "$TOKEN" "$ZONE_ARG" RECORDS=https://home.example.com

# Records without ZONE: the zone of each is found when the container starts.
expect_eq "records in several zones are accepted without a zone" \
    'home.example.com vpn.example.net *.example.org' \
    "$(config "$TOKEN" 'RECORDS=home.example.com,vpn.example.net,*.example.org,Home.example.com' -- show RECORD_NAMES)"
expect_fail "@ without a zone is an error" config "$TOKEN" RECORDS=@
expect_ok "@ without a zone says to write the name in full" grep -q "'@' needs ZONE" "$TMP/config.log"
expect_fail "single-label record without a zone is an error" config "$TOKEN" RECORDS=home
expect_ok "single-label record without a zone is explained" \
    grep -q "'home' is not a full name like home.example.com" "$TMP/config.log"
expect_fail "wildcard top-level domain without a zone is an error" config "$TOKEN" 'RECORDS=*.com'
describes() {
    describe_config 2>&1 | grep -q "$1"
}
expect_ok "a set ZONE is described as optional" \
    config "$TOKEN" "$ZONE_ARG" "$RECS" -- describes 'ZONE is optional'
expect_fail "without ZONE nothing is said about it" config "$TOKEN" "$RECS" -- describes 'ZONE is optional'

# The names used before 0.0.3.
expect_fail "old CF_ZONE name is an error" config "$TOKEN" "$ZONE_ARG" "$RECS" CF_ZONE=example.com
expect_fail "old CF_RECORDS name is an error" config "$TOKEN" "$ZONE_ARG" "$RECS" CF_RECORDS=home.example.com
config "$TOKEN" CF_ZONE=example.com CF_RECORDS=home.example.com >/dev/null 2>&1
expect_eq "old names are reported with their new names" 2 \
    "$(grep -cE 'CF_ZONE is now called ZONE|CF_RECORDS is now called RECORDS' "$TMP/config.log")"
expect_ok "blank old names are ignored" config "$TOKEN" "$ZONE_ARG" "$RECS" CF_ZONE= 'CF_RECORDS= '

# Numbers.
expect_eq "INTERVAL with leading zero is decimal" 300 \
    "$(config "$TOKEN" "$ZONE_ARG" "$RECS" INTERVAL=0300 -- show INTERVAL)"
expect_eq "INTERVAL is trimmed" 600 "$(config "$TOKEN" "$ZONE_ARG" "$RECS" 'INTERVAL= 600 ' -- show INTERVAL)"
for v in 0 -5 abc 1.5 1h; do
    expect_fail "INTERVAL=$v is an error" config "$TOKEN" "$ZONE_ARG" "$RECS" "INTERVAL=$v"
done
config "$TOKEN" "$ZONE_ARG" "$RECS" INTERVAL=30 >/dev/null 2>&1
expect_ok "a very short INTERVAL is allowed but warned about" grep -q 'INTERVAL=30' "$TMP/config.log"

for v in 1 60 300 86400; do
    expect_eq "TTL=$v is accepted" "$v" "$(config "$TOKEN" "$ZONE_ARG" "$RECS" "TTL=$v" -- show TTL)"
done
for v in 0 2 59 86401 auto; do
    expect_fail "TTL=$v is an error" config "$TOKEN" "$ZONE_ARG" "$RECS" "TTL=$v"
done
config "$TOKEN" "$ZONE_ARG" "$RECS" PROXIED=true TTL=300 >/dev/null 2>&1
expect_ok "TTL on proxied records is warned about" grep -q 'no effect' "$TMP/config.log"

# Settings that are allowed but risky.
config "$TOKEN" "$ZONE_ARG" "$RECS" >/dev/null 2>&1
expect_fail "the default lookup URLs are not warned about" grep -q 'uses plain http' "$TMP/config.log"
expect_fail "the default API URL is not warned about" grep -q 'token is sent there' "$TMP/config.log"
config "$TOKEN" "$ZONE_ARG" "$RECS" IPV4_SOURCES=http://ip.example.com >/dev/null 2>&1
expect_ok "a plain http lookup URL is warned about" grep -q 'uses plain http' "$TMP/config.log"
config "$TOKEN" "$ZONE_ARG" "$RECS" CF_API_URL=https://api.example.com/client/v4 >/dev/null 2>&1
expect_ok "a non-default API URL is warned about" grep -q 'token is sent there' "$TMP/config.log"

# Booleans.
families() {
    printf '%s/%s' "$IPV4" "$IPV6"
}
expect_eq "IPV4/IPV6 accept yes/no" false/true \
    "$(config "$TOKEN" "$ZONE_ARG" "$RECS" IPV4=no IPV6=Yes -- families)"
expect_fail "IPV4 and IPV6 both off is an error" config "$TOKEN" "$ZONE_ARG" "$RECS" IPV4=false IPV6=false
expect_fail "IPV6=maybe is an error" config "$TOKEN" "$ZONE_ARG" "$RECS" IPV6=maybe
expect_eq "PROXIED=TRUE" true "$(config "$TOKEN" "$ZONE_ARG" "$RECS" PROXIED=TRUE -- show PROXIED)"
expect_eq "DRY_RUN=1" true "$(config "$TOKEN" "$ZONE_ARG" "$RECS" DRY_RUN=1 -- show DRY_RUN)"

# Logging and endpoints.
expect_eq "LOG_LEVEL=DEBUG" 10 "$(config "$TOKEN" "$ZONE_ARG" "$RECS" LOG_LEVEL=DEBUG -- show LOG_THRESHOLD)"
expect_eq "LOG_LEVEL=warning" warn "$(config "$TOKEN" "$ZONE_ARG" "$RECS" LOG_LEVEL=warning -- show LOG_LEVEL)"
expect_fail "LOG_LEVEL=verbose is an error" config "$TOKEN" "$ZONE_ARG" "$RECS" LOG_LEVEL=verbose
expect_eq "source lists lose whitespace" 'https://a.example/ip,http://b.example/ip' \
    "$(config "$TOKEN" "$ZONE_ARG" "$RECS" 'IPV4_SOURCES= https://a.example/ip , http://b.example/ip ' -- show IPV4_SOURCES)"
expect_fail "non-HTTP source is an error" config "$TOKEN" "$ZONE_ARG" "$RECS" IPV4_SOURCES=ftp://a.example/ip
expect_eq "API URL loses its trailing slash" http://127.0.0.1:8080/client/v4 \
    "$(config "$TOKEN" "$ZONE_ARG" "$RECS" CF_API_URL=http://127.0.0.1:8080/client/v4/ -- show CF_API_URL)"
expect_fail "API URL without a scheme is an error" config "$TOKEN" "$ZONE_ARG" "$RECS" CF_API_URL=api.cloudflare.com

# Notifications.
notify_setup() {
    printf '%s %s %s' "${NFA_NOTIFY_URL:-none}" "$NOTIFY_FORMAT" "${NOTIFY_HOST:-none}"
}
DISCORD=NOTIFY_URL=https://discord.com/api/webhooks/123/abc-DEF_ghi
SLACK_URL=https://hooks.slack.com/services/T0/B0/xyz
expect_eq "notifications are off by default" 'none auto none' "$(config "$TOKEN" "$RECS" -- notify_setup)"
expect_eq "a blank notification URL is off" 'none auto none' \
    "$(config "$TOKEN" "$RECS" 'NOTIFY_URL= ' NOTIFY_FORMAT= -- notify_setup)"
expect_eq "a Discord webhook is recognised" \
    'https://discord.com/api/webhooks/123/abc-DEF_ghi discord discord.com' \
    "$(config "$TOKEN" "$RECS" "$DISCORD" -- notify_setup)"
for host in ptb.discord.com discordapp.com canary.discordapp.com; do
    expect_eq "a webhook on $host is recognised as Discord" discord \
        "$(config "$TOKEN" "$RECS" "NOTIFY_URL=https://$host/api/webhooks/1/x" -- show NOTIFY_FORMAT)"
done
expect_eq "a Slack webhook is recognised" slack \
    "$(config "$TOKEN" "$RECS" "NOTIFY_URL=$SLACK_URL" -- show NOTIFY_FORMAT)"
expect_fail "auto with an unrecognised host is an error" \
    config "$TOKEN" "$RECS" NOTIFY_URL=https://ntfy.sh/secret-topic
expect_ok "the error names the host" grep -q 'points at ntfy.sh;' "$TMP/config.log"
expect_fail "the error leaves out the rest of the URL" grep -q secret-topic "$TMP/config.log"
for f in discord slack ntfy gotify apprise json text; do
    expect_eq "NOTIFY_FORMAT=$f is accepted" "$f" \
        "$(config "$TOKEN" "$RECS" NOTIFY_URL=https://notify.example/x "NOTIFY_FORMAT=$f" -- show NOTIFY_FORMAT)"
done
expect_eq "NOTIFY_FORMAT is trimmed and lowercased" ntfy \
    "$(config "$TOKEN" "$RECS" NOTIFY_URL=https://notify.example/x 'NOTIFY_FORMAT= Ntfy ' -- show NOTIFY_FORMAT)"
expect_fail "an unknown NOTIFY_FORMAT is an error" \
    config "$TOKEN" "$RECS" NOTIFY_URL=https://notify.example/x NOTIFY_FORMAT=email
config "$TOKEN" "$RECS" NOTIFY_FORMAT=ntfy >/dev/null 2>&1
expect_ok "NOTIFY_FORMAT without a URL is warned about" grep -q 'has no effect without NOTIFY_URL' "$TMP/config.log"

printf '%s\r\n' "$SLACK_URL" >"$TMP/notify-url"
: >"$TMP/notify-url-empty"
expect_eq "the URL can come from a file" "$SLACK_URL" \
    "$(config "$TOKEN" "$RECS" "NOTIFY_URL_FILE=$TMP/notify-url" -- show NFA_NOTIFY_URL)"
expect_fail "a URL and a URL file together are an error" \
    config "$TOKEN" "$RECS" "$DISCORD" "NOTIFY_URL_FILE=$TMP/notify-url"
expect_fail "a missing URL file is an error" config "$TOKEN" "$RECS" "NOTIFY_URL_FILE=$TMP/nope"
expect_fail "an empty URL file is an error" config "$TOKEN" "$RECS" "NOTIFY_URL_FILE=$TMP/notify-url-empty"

for url in 'https://a.example/x"y' 'https://a.example/x\y' 'https://a.example/x y' \
    "https://a.example/x${NL}y" ftp://a.example/x https:// a.example/x; do
    expect_fail "NOTIFY_URL '$url' is rejected" config "$TOKEN" "$RECS" "NOTIFY_URL=$url" NOTIFY_FORMAT=json
done
config "$TOKEN" "$RECS" 'NOTIFY_URL=https://hooks.slack.com/services/secretpath"x' >/dev/null 2>&1
expect_fail "a rejected URL is not echoed in the log" grep -q secretpath "$TMP/config.log"
expect_ok "a plain http URL is allowed" \
    config "$TOKEN" "$RECS" NOTIFY_URL=http://ntfy.example/secret-topic NOTIFY_FORMAT=ntfy
expect_ok "a plain http URL is warned about" grep -q 'NOTIFY_URL uses plain http' "$TMP/config.log"
expect_fail "the warning leaves out the URL" grep -q secret-topic "$TMP/config.log"
expect_fail "an unencoded special character in a password is an error" \
    config "$TOKEN" "$RECS" 'NOTIFY_URL=https://user:p?ss@ntfy.example/t' NOTIFY_FORMAT=ntfy
expect_fail "the password is not echoed in the log" grep -qF 'p?ss' "$TMP/config.log"
child_sees_url() {
    sh -c 'printf "%s/%s" "${NOTIFY_URL:-unset}" "${NFA_NOTIFY_URL:-unset}"'
}
expect_eq "the URL is not passed to child processes" unset/unset \
    "$(config "$TOKEN" "$RECS" "$DISCORD" -- child_sees_url)"
expect_ok "the startup log names the format and host" \
    config "$TOKEN" "$RECS" "$DISCORD" -- describes 'notifications: discord via discord.com'
expect_fail "the startup log leaves out the rest of the URL" \
    config "$TOKEN" "$RECS" "$DISCORD" -- describes 'abc-DEF'

config RECORDS=home.example.com INTERVAL=abc TTL=7 >/dev/null 2>&1
expect_eq "every config problem is reported at once" 3 "$(grep -c 'config:' "$TMP/config.log")"

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

# --- zone matching ----------------------------------------------------------

ZONE_TABLE="example.com id1 active
sub.example.com id2 active
example.co.uk id3 active
pending.example.com id4 pending
example.net id5 pending"
expect_eq "a record is matched to its zone" 'example.com id1' "$(zone_for home.example.com)"
expect_eq "the zone apex is in the zone" 'example.com id1' "$(zone_for example.com)"
expect_eq "the longest matching zone wins" 'sub.example.com id2' "$(zone_for host.sub.example.com)"
expect_eq "a subdomain zone apex is in that zone" 'sub.example.com id2' "$(zone_for sub.example.com)"
expect_eq "zones match whole labels only" 'example.com id1' "$(zone_for notsub.example.com)"
expect_eq "a leading wildcard is ignored" 'sub.example.com id2' "$(zone_for '*.sub.example.com')"
expect_eq "two-part endings such as .co.uk work" 'example.co.uk id3' "$(zone_for www.example.co.uk)"
expect_eq "an active parent beats a pending subdomain zone" 'example.com id1' \
    "$(zone_for host.pending.example.com)"
expect_eq "a pending zone is used when nothing else matches" 'example.net id5' "$(zone_for home.example.net)"
expect_fail "a record in no zone has no match" zone_for home.example.org
expect_fail "a zone name inside a label is no match" zone_for notexample.com
expect_fail "a bare top-level domain has no match" zone_for com
ZONE_TABLE=''
expect_fail "no zones means no match" zone_for home.example.com

ZONE_MAP="home.example.com example.com id1
host.sub.example.com sub.example.com id2
vpn.example.com example.com id1"
expect_eq "zones are described with their records" \
    "zone example.com: keeping A records for home.example.com, vpn.example.com pointed at this host${NL}zone sub.example.com: keeping A records for host.sub.example.com pointed at this host" \
    "$(IPV4=true; IPV6=false; describe_zones | sed 's/^[^ ]* [a-z]* *//')"
expect_eq "both address families are described" \
    'zone sub.example.com: keeping A and AAAA records for host.sub.example.com pointed at this host' \
    "$(IPV4=true; IPV6=true; describe_zones | sed -n 's/^[^ ]* [a-z]* *//; 2p')"
ZONE_MAP=''

# --- notifications ----------------------------------------------------------

for case in 'https://discord.com/api/webhooks/1/x discord.com' \
    'https://user:pass@ntfy.example:8443/topic?auth=x ntfy.example' \
    'http://NTFY.Example/t ntfy.example' \
    'https://[2001:db8::1]:8080/x [2001:db8::1]' \
    'https://gotify.example/message?token=abc gotify.example' \
    'https://host.example#frag host.example' \
    'https://host.example host.example'; do
    expect_eq "host of ${case% *}" "${case#* }" "$(url_host "${case% *}")"
done

update_msg="home.example.com A 1.2.3.4 -> 5.6.7.8${NL}vpn.example.com A created with 5.6.7.8"
update_json='home.example.com A 1.2.3.4 -> 5.6.7.8\nvpn.example.com A created with 5.6.7.8'
payload() {
    notify_body "$@" | jq -cS .
}
expect_eq "Discord message" \
    "{\"allowed_mentions\":{\"parse\":[]},\"content\":\"$update_json\",\"username\":\"No Fixed Address\"}" \
    "$(payload discord updated "$update_msg")"
expect_eq "Slack message, with markup characters escaped" \
    '{"text":"No Fixed Address: home.example.com A 1.2.3.4 -&gt; 5.6.7.8\nvpn.example.com A created with 5.6.7.8"}' \
    "$(payload slack updated "$update_msg")"
expect_eq "Gotify message" "{\"message\":\"$update_json\",\"priority\":4,\"title\":\"No Fixed Address\"}" \
    "$(payload gotify updated "$update_msg")"
expect_eq "Gotify failures are high priority" 8 "$(notify_body gotify failing x | jq -r .priority)"
expect_eq "Apprise message" \
    '{"body":"needs attention:\nx","format":"text","title":"No Fixed Address","type":"failure"}' \
    "$(payload apprise failing "needs attention:${NL}x")"
expect_eq "Apprise recovery" success "$(notify_body apprise recovered x | jq -r .type)"
expect_eq "Apprise update" info "$(notify_body apprise updated x | jq -r .type)"
expect_eq "JSON message lists the changes" \
    "{\"changes\":[\"home.example.com A 1.2.3.4 -> 5.6.7.8\",\"vpn.example.com A created with 5.6.7.8\"],\"event\":\"updated\",\"message\":\"$update_json\",\"title\":\"No Fixed Address\"}" \
    "$(payload json updated "$update_msg")"
expect_eq "JSON failure lists no changes" '[]' "$(notify_body json failing "needs attention:${NL}x" | jq -c .changes)"
expect_eq "ntfy message is plain text" "$update_msg" "$(notify_body ntfy updated "$update_msg")"
expect_eq "text message is prefixed with the title" "No Fixed Address: working again (IPv4 5.6.7.8)" \
    "$(notify_body text recovered 'working again (IPv4 5.6.7.8)')"
long_message=$(printf '%02500d' 0)
expect_eq "long Discord messages are cut to 2000 characters" 2000 \
    "$(notify_body discord failing "$long_message" | jq -r '.content | length')"
expect_eq "cut Discord messages end with an ellipsis" '...' \
    "$(notify_body discord failing "$long_message" | jq -r '.content[-3:]')"
is_json() {
    printf '%s' "$1" | jq -e . >/dev/null
}
for f in discord slack gotify apprise json; do
    expect_ok "$f message with quotes and backslashes is valid JSON" \
        is_json "$(notify_body "$f" failing "a \"quoted\" \\path\\ and a${TAB}tab")"
done
expect_eq "ntfy tags and priority for a failure" 'rotating_light high' \
    "$(notify_level tag failing) $(notify_level ntfy failing)"
expect_eq "ntfy tags and priority for an update" 'white_check_mark default' \
    "$(notify_level tag updated) $(notify_level ntfy updated)"
expect_ok "nothing is sent when notifications are off" notify updated x

CHECK_CHANGES=''
note_change 'a.example.com A 1.2.3.4 -> 5.6.7.8' >/dev/null
note_change 'b.example.com A created with 5.6.7.8' >/dev/null
expect_eq "changes are kept for the notification" \
    "a.example.com A 1.2.3.4 -> 5.6.7.8${NL}b.example.com A created with 5.6.7.8" "$CHECK_CHANGES"
CHECK_CHANGES=''
expect_eq "warnings and errors are kept for the notification, even below LOG_LEVEL" "quiet warning${NL}quiet error" \
    "$(LOG_THRESHOLD=50; CHECK_PROBLEMS=''; log warn 'quiet warning'; log info 'not a problem'; log error 'quiet error'; printf '%s' "$CHECK_PROBLEMS")"

# notify_events STEP...
# Runs check_failed and check_succeeded through STEPs (RC@TIME for a failed
# check, ok for a successful one) and prints the notifications they send.
notify_events() {
    (
        # shellcheck disable=SC2329 # called by check_failed and check_succeeded
        notify() {
            printf '%s;' "$1"
        }
        FAILING_SINCE=''
        NOTIFIED_FAILING=0
        CHECK_PROBLEMS=x
        CHECK_SUMMARY='IPv4 5.6.7.8'
        for step do
            case $step in
                ok) check_succeeded ;;
                *) check_failed "${step%@*}" "${step#*@}" ;;
            esac
        done
    )
}
expect_eq "a short outage sends nothing" '' "$(notify_events 1@1000 1@1060 1@1180 ok)"
expect_eq "a lasting outage is reported once, when the health check gives up, then its end" \
    'failing;recovered;' "$(notify_events 1@1000 1@8199 1@8200 1@9000 ok ok)"
expect_eq "a problem that needs attention is reported at once, and once" \
    'failing;recovered;' "$(notify_events 2@1000 2@1001 1@1002 2@1003 ok)"
expect_eq "an outage that turns into a problem that needs attention is reported again" \
    'failing;failing;' "$(notify_events 1@1000 1@8200 2@8300 2@8400 1@8500)"
expect_eq "each run of failures is timed from its own start" '' "$(notify_events 1@1000 ok 1@8300)"
expect_eq "nothing is sent for a success after a quiet failure" '' "$(notify_events 1@1000 ok ok)"

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
