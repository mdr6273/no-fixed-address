#!/bin/sh
# No Fixed Address: keeps Cloudflare DNS records pointed at this host's
# current public IP address.
#
# https://github.com/mdr6273/no-fixed-address
# SPDX-License-Identifier: MIT
#
# Exit status: 0 after a TERM/INT shutdown, 1 when Cloudflare rejects the
# token or cannot find the zone, 2 for invalid configuration. Everything else
# is retried rather than treated as fatal.
#
# `local` is not POSIX, but busybox ash, dash and bash all support it, and a
# long-running loop is much easier to reason about without stray globals.
# shellcheck disable=SC3043

# No globbing anywhere: wildcard record names such as *.example.com and the
# bracketed IPv6 lookup URL must never be expanded against the filesystem.
set -fu

NFA_VERSION=${NFA_VERSION:-dev}
USER_AGENT="nofixedaddress/$NFA_VERSION (+https://github.com/mdr6273/no-fixed-address)"

DEFAULT_API_URL='https://api.cloudflare.com/client/v4'
DEFAULT_IPV4_SOURCES='https://1.1.1.1/cdn-cgi/trace,https://api.ipify.org,https://ifconfig.me/ip'
DEFAULT_IPV6_SOURCES='https://[2606:4700:4700::1111]/cdn-cgi/trace,https://api6.ipify.org'
DEFAULT_STATE_DIR='/tmp/nofixedaddress'

BACKOFF_MIN=60
BACKOFF_MAX=3600
# How far past INTERVAL the last success may be before the health check fails.
HEALTH_GRACE=7200

NL='
'
TAB=$(printf '\t')
CR=$(printf '\r')

LOG_THRESHOLD=20
CHILD_PID=''
NFA_TMP=''
ZONE_ID=''
RECORD_CACHE=''
ANNOUNCED=false

# --- logging ----------------------------------------------------------------

# log LEVEL MESSAGE
log() {
    local rank
    case $1 in
        debug) rank=10 ;;
        info) rank=20 ;;
        warn) rank=30 ;;
        *) rank=40 ;;
    esac
    [ "$rank" -ge "$LOG_THRESHOLD" ] || return 0
    # Warnings and errors go to stderr so anything that separates the two
    # streams can surface them.
    if [ "$rank" -ge 30 ]; then
        printf '%s %-5s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" >&2
    else
        printf '%s %-5s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2"
    fi
}

# --- configuration ----------------------------------------------------------

config_error() {
    log error "config: $1"
    CONFIG_ERRORS=$((CONFIG_ERRORS + 1))
}

# Strips surrounding whitespace from the variable named $1, in place. Pasted
# tokens and form fields often pick up a stray space or a Windows line ending.
trim_var() {
    local _value
    eval "_value=\${$1:-}"
    while :; do
        case $_value in
            " "* | "$TAB"* | "$CR"* | "$NL"*) _value=${_value#?} ;;
            *" " | *"$TAB" | *"$CR" | *"$NL") _value=${_value%?} ;;
            *) break ;;
        esac
    done
    eval "$1=\$_value"
}

lower() {
    printf '%s\n' "$1" | awk '{ print tolower($0) }'
}

# Prints true or false for the usual spellings of a boolean; fails otherwise.
parse_bool() {
    case $1 in
        [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss] | [Oo][Nn] | 1) printf true ;;
        [Ff][Aa][Ll][Ss][Ee] | [Nn][Oo] | [Oo][Ff][Ff] | 0) printf false ;;
        *) return 1 ;;
    esac
}

# Normalises the boolean setting named $1 in place, using $2 when it is empty.
# Empty counts as unset because Unraid passes blank template fields as empty
# variables rather than leaving them out.
bool_setting() {
    local name="$1" fallback="$2" raw value
    eval "raw=\${$name:-}"
    trim_var raw
    # shellcheck disable=SC2034 # value is read by the eval below
    if [ -z "$raw" ]; then
        value=$fallback
    elif ! value=$(parse_bool "$raw"); then
        config_error "$name must be true or false, not '$raw'"
        value=$fallback
    fi
    eval "$name=\$value"
}

# Prints a non-negative integer without leading zeros, which $(( )) would
# otherwise read as octal. Fails on anything but plain digits.
parse_uint() {
    case $1 in
        '' | *[!0-9]*) return 1 ;;
    esac
    set -- "${1#"${1%%[!0]*}"}"
    [ "${#1}" -le 9 ] || return 1
    printf '%s' "${1:-0}"
}

# Accepts lowercase DNS names (letters, digits, hyphens, underscores), with an
# optional leading "*." for wildcard records.
is_hostname() {
    local name="$1" label saved_ifs
    [ "${#name}" -le 253 ] || return 1
    case $name in
        '' | *[!a-z0-9.*_-]* | .* | *. | *..*) return 1 ;;
        '*.'*) name=${name#??} ;;
    esac
    case $name in
        *'*'*) return 1 ;;
    esac
    saved_ifs=$IFS
    IFS=.
    # shellcheck disable=SC2086 # deliberately split into labels
    set -- $name
    IFS=$saved_ifs
    for label do
        [ "${#label}" -le 63 ] || return 1
    done
}

# Tidies the comma-separated URL list in the variable named $1, falling back to
# $2 when it is empty, and checks that every entry looks like a URL.
url_list_setting() {
    local name="$1" list url saved_ifs
    eval "list=\${$name:-}"
    list=$(printf '%s' "$list" | tr -d ' \t\r\n')
    [ -n "$list" ] || list=$2
    eval "$name=\$list"
    saved_ifs=$IFS
    IFS=,
    # shellcheck disable=SC2086 # deliberately split on commas
    set -- $list
    IFS=$saved_ifs
    for url do
        case $url in
            '' | https://?*) ;;
            # Validation proves an answer is a public address, not that it is
            # this host's; over plain http anyone on the path can choose it.
            http://?*) log warn "$name entry $url uses plain http, so anyone on the network path could answer with an address of their choosing; use https" ;;
            *) config_error "$name entry '$url' is not an http:// or https:// URL" ;;
        esac
    done
}

# Reads and validates every setting, reporting all problems before giving up
# so they can be fixed in one pass. Returns 2 if anything is wrong.
load_config() {
    local raw name entries
    CONFIG_ERRORS=0

    LOG_LEVEL=${LOG_LEVEL:-}
    trim_var LOG_LEVEL
    LOG_LEVEL=$(lower "${LOG_LEVEL:-info}")
    case $LOG_LEVEL in
        debug) LOG_THRESHOLD=10 ;;
        info) LOG_THRESHOLD=20 ;;
        warn | warning) LOG_LEVEL=warn LOG_THRESHOLD=30 ;;
        error) LOG_THRESHOLD=40 ;;
        *) config_error "LOG_LEVEL must be debug, info, warn or error, not '$LOG_LEVEL'" ;;
    esac

    # The token is copied into a fresh variable that is never exported, and
    # the original is unset, so curl, jq and every other child process start
    # without it in their environment.
    unset NFA_TOKEN
    NFA_TOKEN=''
    if [ -n "${CF_API_TOKEN:-}" ] && [ -n "${CF_API_TOKEN_FILE:-}" ]; then
        config_error "set CF_API_TOKEN or CF_API_TOKEN_FILE, not both"
    elif [ -n "${CF_API_TOKEN_FILE:-}" ]; then
        if [ -f "$CF_API_TOKEN_FILE" ] && [ -r "$CF_API_TOKEN_FILE" ]; then
            IFS= read -r NFA_TOKEN <"$CF_API_TOKEN_FILE" || :
            trim_var NFA_TOKEN
            [ -n "$NFA_TOKEN" ] || config_error "CF_API_TOKEN_FILE $CF_API_TOKEN_FILE is empty"
        else
            config_error "CF_API_TOKEN_FILE $CF_API_TOKEN_FILE does not exist or is not readable by uid $(id -u)"
        fi
    else
        NFA_TOKEN=${CF_API_TOKEN:-}
        trim_var NFA_TOKEN
        [ -n "$NFA_TOKEN" ] || config_error "CF_API_TOKEN is required (or CF_API_TOKEN_FILE naming a file that contains it)"
    fi
    unset CF_API_TOKEN
    case $NFA_TOKEN in
        *[!A-Za-z0-9._~+/=-]*)
            # Bearer tokens never contain anything else (RFC 6750), and the
            # check keeps the value safe to hand to curl as a config line.
            config_error "the API token contains characters a Cloudflare token never has; check for quotes or spaces around it"
            NFA_TOKEN=''
            ;;
    esac

    CF_ZONE=${CF_ZONE:-}
    trim_var CF_ZONE
    CF_ZONE=$(lower "$CF_ZONE")
    CF_ZONE=${CF_ZONE%.}
    if [ -z "$CF_ZONE" ]; then
        config_error "CF_ZONE is required, e.g. CF_ZONE=example.com"
    elif ! is_hostname "$CF_ZONE" || [ "${CF_ZONE#\*}" != "$CF_ZONE" ] || [ "${CF_ZONE#*.}" = "$CF_ZONE" ]; then
        config_error "CF_ZONE '$CF_ZONE' is not a domain name like example.com"
        CF_ZONE=''
    fi

    RECORDS=''
    entries=$(printf '%s\n' "${CF_RECORDS:-}" | tr ',' '\n' | awk '
        { gsub(/^[ \t\r]+|[ \t\r]+$/, ""); $0 = tolower($0); sub(/\.$/, "") }
        $0 != ""
    ')
    for name in $entries; do
        [ "$name" != @ ] || name=$CF_ZONE
        if ! is_hostname "$name"; then
            config_error "CF_RECORDS entry '$name' is not a valid DNS name"
        elif [ -n "$CF_ZONE" ] && [ "$name" != "$CF_ZONE" ] && [ "${name%".$CF_ZONE"}" = "$name" ]; then
            config_error "CF_RECORDS entry '$name' is not in the zone $CF_ZONE"
        else
            case " $RECORDS " in
                *" $name "*) ;;
                *) RECORDS="$RECORDS${RECORDS:+ }$name" ;;
            esac
        fi
    done
    [ -n "$entries" ] || config_error "CF_RECORDS is required, e.g. CF_RECORDS=home.example.com,vpn.example.com"

    raw=${INTERVAL:-}
    trim_var raw
    if INTERVAL=$(parse_uint "${raw:-86400}") && [ "$INTERVAL" -ge 1 ]; then
        [ "$INTERVAL" -ge 60 ] || log warn "INTERVAL=$INTERVAL: checking more than once a minute puts needless load on the address lookup services"
    else
        config_error "INTERVAL must be a whole number of seconds, not '$raw'"
        INTERVAL=86400
    fi

    bool_setting IPV4 true
    bool_setting IPV6 false
    bool_setting PROXIED ''
    bool_setting CREATE_IF_MISSING false
    bool_setting DRY_RUN false
    if [ "$IPV4" = false ] && [ "$IPV6" = false ]; then
        config_error "IPV4 and IPV6 are both false, so there is nothing to update"
    fi

    raw=${TTL:-}
    trim_var raw
    TTL=''
    if [ -n "$raw" ]; then
        if TTL=$(parse_uint "$raw") && { [ "$TTL" -eq 1 ] || { [ "$TTL" -ge 60 ] && [ "$TTL" -le 86400 ]; }; }; then
            [ "$PROXIED" != true ] || [ "$TTL" -eq 1 ] ||
                log warn "TTL=$TTL has no effect: Cloudflare always uses automatic TTL for proxied records"
        else
            config_error "TTL must be 1 (automatic) or 60 to 86400 seconds, not '$raw'"
            TTL=''
        fi
    fi

    url_list_setting IPV4_SOURCES "$DEFAULT_IPV4_SOURCES"
    url_list_setting IPV6_SOURCES "$DEFAULT_IPV6_SOURCES"

    raw=${CF_API_URL:-}
    trim_var raw
    CF_API_URL=${raw:-$DEFAULT_API_URL}
    CF_API_URL=${CF_API_URL%/}
    case $CF_API_URL in
        http://?* | https://?*) ;;
        *) config_error "CF_API_URL must be an http:// or https:// URL, not '$CF_API_URL'" ;;
    esac
    [ "$CF_API_URL" = "$DEFAULT_API_URL" ] ||
        log warn "CF_API_URL is set to $CF_API_URL, so the API token is sent there instead of to Cloudflare"

    STATE_DIR=${STATE_DIR:-}
    trim_var STATE_DIR
    STATE_DIR=${STATE_DIR:-$DEFAULT_STATE_DIR}

    [ "$CONFIG_ERRORS" -eq 0 ] || return 2
}

describe_config() {
    local types=''
    [ "$IPV4" = false ] || types=A
    [ "$IPV6" = false ] || types="${types:+$types and }AAAA"
    log info "zone $CF_ZONE: keeping $types records for $(printf '%s' "$RECORDS" | sed 's/ /, /g') pointed at this host"
    log info "checking every ${INTERVAL}s; proxied: ${PROXIED:-as is}, ttl: ${TTL:-as is}, create missing records: $CREATE_IF_MISSING"
    [ "$DRY_RUN" = false ] || log info "dry run: changes are logged but not applied"
}

# --- addresses --------------------------------------------------------------

is_ipv4() {
    local octet saved_ifs
    case $1 in
        '' | *[!0-9.]* | .* | *. | *..*) return 1 ;;
    esac
    saved_ifs=$IFS
    IFS=.
    # shellcheck disable=SC2086 # deliberately split into octets
    set -- $1
    IFS=$saved_ifs
    [ "$#" -eq 4 ] || return 1
    for octet do
        case $octet in
            ????* | 0?*) return 1 ;;
        esac
        [ "$octet" -le 255 ] || return 1
    done
}

# True for IPv4 addresses that are reachable from the internet. A private,
# loopback, shared (CGNAT) or documentation address means the lookup went
# wrong, and publishing it would break the name for everyone.
is_public_ipv4() {
    local saved_ifs
    is_ipv4 "$1" || return 1
    saved_ifs=$IFS
    IFS=.
    # shellcheck disable=SC2086 # deliberately split into octets
    set -- $1
    IFS=$saved_ifs
    case $1 in
        0 | 10 | 127) return 1 ;;
        100) [ "$2" -lt 64 ] || [ "$2" -gt 127 ] || return 1 ;;
        169) [ "$2" -ne 254 ] || return 1 ;;
        172) [ "$2" -lt 16 ] || [ "$2" -gt 31 ] || return 1 ;;
        192) case $2.$3 in 168.* | 0.0 | 0.2 | 88.99) return 1 ;; esac ;;
        198) case $2.$3 in 18.* | 19.* | 51.100) return 1 ;; esac ;;
        203) [ "$2.$3" != 0.113 ] || return 1 ;;
    esac
    # 224 and up is multicast and reserved space.
    [ "$1" -lt 224 ]
}

# Prints the RFC 5952 form of an IPv6 address (lowercase, no leading zeros,
# longest run of zero groups compressed) or fails if it is not one. Cloudflare
# stores this form, so comparing any other spelling would cause an update on
# every check.
normalize_ipv6() {
    case $1 in
        '' | *[!0-9A-Fa-f:]*) return 1 ;;
    esac
    printf '%s\n' "$1" | awk '
        {
            s = tolower($0)
            if (index(s, ":::")) exit 1
            gap = index(s, "::")
            if (gap) {
                head = substr(s, 1, gap - 1)
                tail = substr(s, gap + 2)
                if (index(tail, "::")) exit 1
                nh = head == "" ? 0 : split(head, h, ":")
                nt = tail == "" ? 0 : split(tail, t, ":")
                if (nh + nt > 7) exit 1
                n = 0
                for (i = 1; i <= nh; i++) g[++n] = h[i]
                for (i = 1; i <= 8 - nh - nt; i++) g[++n] = "0"
                for (i = 1; i <= nt; i++) g[++n] = t[i]
            } else if (split(s, g, ":") != 8) {
                exit 1
            }
            for (i = 1; i <= 8; i++) {
                if (g[i] !~ /^[0-9a-f][0-9a-f]?[0-9a-f]?[0-9a-f]?$/) exit 1
                sub(/^0+/, "", g[i])
                if (g[i] == "") g[i] = "0"
            }
            # Longest run of zero groups; the leftmost wins a tie.
            best = 0; len = 0; run = 0
            for (i = 1; i <= 8; i++) {
                if (g[i] == "0") {
                    if (++run > len) { len = run; best = i - run + 1 }
                } else {
                    run = 0
                }
            }
            out = ""
            if (len >= 2) {
                for (i = 1; i < best; i++) out = out (i > 1 ? ":" : "") g[i]
                out = out "::"
                for (i = best + len; i <= 8; i++) out = out g[i] (i < 8 ? ":" : "")
            } else {
                for (i = 1; i <= 8; i++) out = out (i > 1 ? ":" : "") g[i]
            }
            print out
        }
    '
}

# True for canonical IPv6 addresses in global unicast space (2000::/3), less
# the documentation prefixes 2001:db8::/32 and 3fff::/20. Anything else
# (link-local, unique-local, multicast, mapped IPv4) means the lookup went
# wrong.
is_public_ipv6() {
    case $1 in
        2001:db8:* | 3fff::* | 3fff:[0-9a-f]:* | 3fff:[0-9a-f][0-9a-f]:* | 3fff:[0-9a-f][0-9a-f][0-9a-f]:*) return 1 ;;
        [23][0-9a-f][0-9a-f][0-9a-f]:*) return 0 ;;
    esac
    return 1
}

# Pulls the address out of a lookup response: the ip= line of a Cloudflare
# trace, or the whole body of a plain-text service.
extract_ip() {
    awk '
        { gsub(/[ \t\r]/, "") }
        /^ip=/ { print substr($0, 4); found = 1; exit }
        NR == 1 { first = $0 }
        END { if (!found && NR == 1) print first }
    ' "$1"
}

# Makes an untrusted response short and safe to put in a log line.
printable() {
    printf '%s' "$1" | tr -cd 'A-Za-z0-9.:_/-' | cut -c1-64
}

# Asks each lookup source in turn for this host's public address in family $1
# (4 or 6). The first answer that is a valid public address wins and is left
# in DETECTED_IP.
detect_ip() {
    local family="$1" list url answer canonical saved_ifs
    DETECTED_IP=''
    if [ "$family" = 4 ]; then list=$IPV4_SOURCES; else list=$IPV6_SOURCES; fi
    saved_ifs=$IFS
    IFS=,
    # shellcheck disable=SC2086 # deliberately split on commas
    set -- $list
    IFS=$saved_ifs
    for url do
        [ -n "$url" ] || continue
        : >"$NFA_TMP/lookup"
        # -g: URLs are literal; curl would otherwise read [..] and {..} as ranges.
        # An address fits in a few hundred bytes; the cap stops a hostile
        # source from filling /tmp.
        curl "-$family" -fsSg --connect-timeout 5 --max-time 10 --max-filesize 4096 -A "$USER_AGENT" \
            -o "$NFA_TMP/lookup" "$url" 2>"$NFA_TMP/error" &
        if ! wait_child "$!"; then
            log debug "IPv$family lookup via $url failed: $(first_line "$NFA_TMP/error")"
            continue
        fi
        answer=$(extract_ip "$NFA_TMP/lookup")
        if [ "$family" = 4 ]; then
            if is_public_ipv4 "$answer"; then DETECTED_IP=$answer; fi
        elif canonical=$(normalize_ipv6 "$answer") && is_public_ipv6 "$canonical"; then
            DETECTED_IP=$canonical
        fi
        if [ -n "$DETECTED_IP" ]; then
            log debug "IPv$family address from $url: $DETECTED_IP"
            return 0
        fi
        if [ -z "$answer" ]; then
            log warn "IPv$family lookup via $url returned no address"
        else
            log warn "IPv$family lookup via $url returned '$(printable "$answer")', which is not a public IPv$family address"
        fi
    done
    return 1
}

# --- Cloudflare API ---------------------------------------------------------

# Waits for the background child $1. Running curl and sleep in the background
# and waiting on them lets a TERM or INT trap fire straight away; with a
# foreground command the shell would hold the signal until it finished.
wait_child() {
    local rc
    CHILD_PID=$1
    wait "$1"
    rc=$?
    CHILD_PID=''
    return "$rc"
}

sleep_for() {
    sleep "$1" &
    wait_child "$!"
}

first_line() {
    local line=''
    IFS= read -r line <"$1" || :
    printf '%s' "$line"
}

# cf_api METHOD PATH [JSON]
# Leaves the response body in $NFA_TMP/body and the status in HTTP_STATUS,
# and describes any failure in API_ERROR. Returns 0 on success, 1 when trying
# again later may help (network trouble, 408, 429, 5xx) and 2 when it will not.
cf_api() {
    local method="$1" path="$2" json="${3:-}" rc detail
    HTTP_STATUS=''
    API_ERROR=''
    set -- -sSg --connect-timeout 10 --max-time 20 -X "$method" \
        -A "$USER_AGENT" -H 'Accept: application/json' \
        -o "$NFA_TMP/body" -w '%{http_code}' --config -
    if [ -n "$json" ]; then
        set -- "$@" -H 'Content-Type: application/json' --data-raw "$json"
    fi
    : >"$NFA_TMP/body"

    # The Authorization header reaches curl as a config line on stdin so the
    # token never appears in a process listing.
    curl "$@" "$CF_API_URL$path" >"$NFA_TMP/status" 2>"$NFA_TMP/error" <<EOF &
header = "Authorization: Bearer $NFA_TOKEN"
EOF
    wait_child "$!"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        API_ERROR=$(first_line "$NFA_TMP/error")
        API_ERROR=${API_ERROR:-curl exited with status $rc}
        log debug "$method $path failed: $API_ERROR"
        return 1
    fi

    IFS= read -r HTTP_STATUS <"$NFA_TMP/status" || :
    log debug "$method $path: HTTP $HTTP_STATUS"
    detail=$(jq -r '[.errors[]? | "\(.message) (code \(.code))"] | join("; ")' \
        "$NFA_TMP/body" 2>/dev/null) || detail=''
    case $HTTP_STATUS in
        2??)
            if jq -e '.success == true' "$NFA_TMP/body" >/dev/null 2>&1; then
                return 0
            elif [ -n "$detail" ]; then
                API_ERROR=$detail
                return 2
            fi
            # Typically a captive portal or proxy answering in Cloudflare's place.
            API_ERROR="HTTP $HTTP_STATUS, but the response did not come from the Cloudflare API"
            return 1
            ;;
        408 | 429 | 5??)
            API_ERROR="HTTP $HTTP_STATUS${detail:+: $detail}"
            return 1
            ;;
        *)
            API_ERROR="HTTP $HTTP_STATUS${detail:+: $detail}"
            return 2
            ;;
    esac
}

# Logs a failed API call described by $1, with cf_api's status in $2:
# transient trouble as a warning, anything that needs the user as an error.
report_api_failure() {
    local hint=''
    case $HTTP_STATUS in
        401 | 403) hint="; the token needs Zone:DNS:Edit and Zone:Zone:Read on $CF_ZONE" ;;
    esac
    if [ "$2" -eq 1 ]; then
        log warn "$1 failed: $API_ERROR"
    else
        log error "$1 failed: $API_ERROR$hint"
    fi
}

# Returns 0 if the token is valid and active, 1 if Cloudflare could not be
# reached, and 2 if the token was rejected.
verify_token() {
    local rc
    cf_api GET /user/tokens/verify
    rc=$?
    case $rc in
        0)
            token_is_active "API token verified"
            return
            ;;
        1)
            log warn "could not verify the API token: $API_ERROR"
            return 1
            ;;
    esac
    # The user endpoint answers 401 for account-owned tokens too, even valid
    # ones; those can only be verified under the account that owns the zone.
    if [ "$HTTP_STATUS" = 401 ]; then
        log debug "not a user API token; checking it as an account-owned token"
        verify_account_token
        return
    fi
    report_rejected_token
    return 2
}

verify_account_token() {
    local rc account
    cf_api GET "/zones?name=$CF_ZONE"
    rc=$?
    case $rc in
        0) ;;
        1)
            log warn "could not verify the API token: $API_ERROR"
            return 1
            ;;
        *)
            report_rejected_token
            return 2
            ;;
    esac
    account=$(jq -r --arg zone "$CF_ZONE" \
        '[.result[]? | select(.name == $zone) | .account.id] | if length == 1 then .[0] // empty else empty end' \
        "$NFA_TMP/body" 2>/dev/null)
    case $account in
        '' | *[!0-9A-Za-z]*)
            log error "Cloudflare rejected the API token, or it cannot see zone $CF_ZONE; check the token and that it has Zone:Zone:Read for this zone"
            return 2
            ;;
    esac
    cf_api GET "/accounts/$account/tokens/verify"
    rc=$?
    case $rc in
        0)
            token_is_active "API token verified (account-owned)"
            return
            ;;
        1)
            log warn "could not verify the API token: $API_ERROR"
            return 1
            ;;
    esac
    report_rejected_token
    return 2
}

# Checks the status in a successful verify response, logging $1 if active.
token_is_active() {
    local status
    status=$(jq -r '.result.status // empty' "$NFA_TMP/body" 2>/dev/null)
    if [ "$status" != active ]; then
        log error "the API token is ${status:-not active}; re-enable it or create a new one in the Cloudflare dashboard"
        return 2
    fi
    log info "$1"
}

report_rejected_token() {
    log error "Cloudflare rejected the API token ($API_ERROR); check that it was copied completely and has not been deleted or expired"
}

# Looks up the zone ID for CF_ZONE. Returns 0 on success, 1 if Cloudflare
# could not be reached, and 2 if the zone is not visible to the token.
resolve_zone() {
    local rc id
    cf_api GET "/zones?name=$CF_ZONE"
    rc=$?
    case $rc in
        0) ;;
        1)
            log warn "could not look up zone $CF_ZONE: $API_ERROR"
            return 1
            ;;
        *)
            log error "looking up zone $CF_ZONE failed ($API_ERROR); the token needs Zone:Zone:Read on it"
            return 2
            ;;
    esac
    id=$(jq -r --arg zone "$CF_ZONE" \
        '[.result[]? | select(.name == $zone) | .id] | if length == 1 then .[0] else empty end' \
        "$NFA_TMP/body" 2>/dev/null)
    case $id in
        '' | *[!0-9A-Za-z]*)
            log error "zone $CF_ZONE was not found; check CF_ZONE, and that the token has Zone:Zone:Read for this zone"
            return 2
            ;;
    esac
    ZONE_ID=$id
    log debug "zone $CF_ZONE has ID $ZONE_ID"
}

# --- records ----------------------------------------------------------------

# Record IDs are cached as newline-separated "TYPE NAME ID" lines, since plain
# sh has no associative arrays.
cache_get() {
    printf '%s\n' "$RECORD_CACHE" | awk -v t="$1" -v n="$2" '$1 == t && $2 == n { print $3; exit }'
}

cache_del() {
    RECORD_CACHE=$(printf '%s\n' "$RECORD_CACHE" | awk -v t="$1" -v n="$2" 'NF && !($1 == t && $2 == n)')
}

cache_put() {
    cache_del "$1" "$2"
    RECORD_CACHE="$RECORD_CACHE${RECORD_CACHE:+$NL}$1 $2 $3"
}

# read_record FILTER TYPE NAME
# Loads REC_ID, REC_CONTENT, REC_PROXIED and REC_TTL from the record in the
# last response picked out by the jq FILTER, which may refer to $type and
# $name. Fails unless exactly one well-formed record matches.
read_record() {
    local fields
    fields=$(jq -r --arg type "$2" --arg name "$3" \
        "$1"' | "\(.id) \(.content) \(.proxied) \(.ttl)"' "$NFA_TMP/body" 2>/dev/null) || return 1
    # shellcheck disable=SC2086 # deliberately split into fields
    set -- $fields
    [ "$#" -eq 4 ] || return 1
    case $1 in '' | *[!0-9A-Za-z]*) return 1 ;; esac
    case $3 in true | false) ;; *) return 1 ;; esac
    case $4 in '' | *[!0-9]*) return 1 ;; esac
    REC_ID=$1 REC_CONTENT=$2 REC_PROXIED=$3 REC_TTL=$4
}

# Fetches the current TYPE record for NAME, trying the cached ID first.
# Returns 0 when found (REC_* set), 3 when there is no such record, and
# otherwise 1 or 2 as for cf_api.
# shellcheck disable=SC2016 # the single-quoted $type and $name are jq variables
load_record() {
    local type="$1" name="$2" id rc count
    id=$(cache_get "$type" "$name")
    if [ -n "$id" ]; then
        cf_api GET "/zones/$ZONE_ID/dns_records/$id"
        rc=$?
        if [ "$rc" -eq 0 ] && read_record '.result | select(.type == $type and .name == $name)' "$type" "$name"; then
            return 0
        elif [ "$rc" -eq 0 ] || [ "$HTTP_STATUS" = 404 ]; then
            # Deleted, renamed or retyped since its ID was cached.
            log debug "$name $type: record $id has changed outside this container; looking it up again"
            cache_del "$type" "$name"
        else
            report_api_failure "reading $name $type" "$rc"
            return "$rc"
        fi
    fi

    cf_api GET "/zones/$ZONE_ID/dns_records?type=$type&name=$name&per_page=100"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ "$HTTP_STATUS" = 404 ]; then
            # The zone itself has gone, or was re-added under a new ID; the
            # next check looks it up again.
            ZONE_ID=''
            RECORD_CACHE=''
            rc=1
        fi
        report_api_failure "looking up $name $type" "$rc"
        return "$rc"
    fi
    count=$(jq -r --arg type "$type" --arg name "$name" \
        '[.result[]? | select(.type == $type and .name == $name)] | length' "$NFA_TMP/body" 2>/dev/null)
    case $count in
        0) return 3 ;;
        [2-9] | [1-9][0-9]*)
            log error "$name has $count $type records; leaving them alone because there is no way to tell which one to update"
            return 2
            ;;
    esac
    if ! read_record '.result[] | select(.type == $type and .name == $name)' "$type" "$name"; then
        log error "$name $type: Cloudflare returned a record this tool cannot read"
        return 2
    fi
    cache_put "$type" "$name" "$REC_ID"
}

# Applies whatever differs between the record load_record found and what it
# should be. Returns 0 when nothing needed changing or the change was applied,
# 3 when the record vanished before the write, and otherwise 1 or 2.
update_record() {
    local type="$1" name="$2" ip="$3" current="$REC_CONTENT" proxied="$REC_PROXIED"
    local new_content='' new_proxied='' new_ttl='' prefix='' json rc

    # An AAAA record typed in by hand as 2001:DB8:0::1 is the same address as
    # 2001:db8::1 and must not be rewritten on every check.
    if [ "$type" = AAAA ]; then
        current=$(normalize_ipv6 "$REC_CONTENT") || current=$REC_CONTENT
    fi
    [ "$current" = "$ip" ] || new_content=$ip
    if [ -n "$PROXIED" ] && [ "$PROXIED" != "$REC_PROXIED" ]; then
        new_proxied=$PROXIED
        proxied=$PROXIED
    fi
    # Cloudflare pins proxied records to automatic TTL; asking for anything
    # else would only produce a pointless update on every check.
    if [ -n "$TTL" ] && [ "$proxied" = false ] && [ "$TTL" != "$REC_TTL" ]; then
        new_ttl=$TTL
    fi

    if [ -z "$new_content$new_proxied$new_ttl" ]; then
        log debug "$name $type $REC_CONTENT unchanged"
        CHECK_UNCHANGED=$((CHECK_UNCHANGED + 1))
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        prefix='[dry-run] '
    else
        json=$(jq -cn --arg content "$new_content" --arg proxied "$new_proxied" --arg ttl "$new_ttl" '
            (if $content != "" then {content: $content} else {} end)
            + (if $proxied != "" then {proxied: ($proxied == "true")} else {} end)
            + (if $ttl != "" then {ttl: ($ttl | tonumber)} else {} end)')
        cf_api PATCH "/zones/$ZONE_ID/dns_records/$REC_ID" "$json"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            if [ "$HTTP_STATUS" = 404 ]; then
                cache_del "$type" "$name"
                return 3
            fi
            report_api_failure "updating $name $type" "$rc"
            return "$rc"
        fi
    fi

    [ -z "$new_content" ] || log info "$prefix$name $type $REC_CONTENT -> $new_content"
    [ -z "$new_proxied" ] || log info "$prefix$name $type proxied $REC_PROXIED -> $new_proxied"
    [ -z "$new_ttl" ] || log info "$prefix$name $type ttl $REC_TTL -> $new_ttl"
    CHECK_UPDATED=$((CHECK_UPDATED + 1))
    return 0
}

create_record() {
    local type="$1" name="$2" ip="$3" proxied="${PROXIED:-false}" ttl="${TTL:-1}" json rc
    if [ "$CREATE_IF_MISSING" != true ]; then
        log error "$name has no $type record; create it in Cloudflare or set CREATE_IF_MISSING=true"
        return 2
    fi
    [ "$proxied" = false ] || ttl=1
    if [ "$DRY_RUN" = true ]; then
        log info "[dry-run] $name $type created with $ip"
        CHECK_UPDATED=$((CHECK_UPDATED + 1))
        return 0
    fi
    json=$(jq -cn --arg type "$type" --arg name "$name" --arg content "$ip" \
        --argjson proxied "$proxied" --argjson ttl "$ttl" \
        '{type: $type, name: $name, content: $content, proxied: $proxied, ttl: $ttl,
          comment: "Managed by No Fixed Address"}')
    cf_api POST "/zones/$ZONE_ID/dns_records" "$json"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report_api_failure "creating $name $type" "$rc"
        return "$rc"
    fi
    if read_record '.result' "$type" "$name"; then
        cache_put "$type" "$name" "$REC_ID"
    fi
    log info "$name $type created with $ip"
    CHECK_UPDATED=$((CHECK_UPDATED + 1))
}

# Brings the TYPE record for NAME in line with address $3.
# Returns 0 on success, 1 when worth retrying soon, 2 when the user must act.
sync_record() {
    local type="$1" name="$2" ip="$3" rc attempt=1
    while [ "$attempt" -le 2 ]; do
        load_record "$type" "$name"
        rc=$?
        case $rc in
            0)
                update_record "$type" "$name" "$ip"
                rc=$?
                ;;
            3)
                create_record "$type" "$name" "$ip"
                return
                ;;
        esac
        # 3 here means the record vanished between reading and writing it.
        [ "$rc" -eq 3 ] || return "$rc"
        log debug "$name $type changed while being updated; looking it up again"
        attempt=$((attempt + 1))
    done
    log warn "$name $type kept changing while being updated; trying again later"
    return 1
}

# --- main loop --------------------------------------------------------------

next_backoff() {
    local next=$(($1 * 2))
    [ "$next" -ge "$BACKOFF_MIN" ] || next=$BACKOFF_MIN
    [ "$next" -le "$BACKOFF_MAX" ] || next=$BACKOFF_MAX
    printf '%s\n' "$next"
}

# Folds one record's outcome into CHECK_RESULT. Transient failures win, so
# the check is retried soon rather than after a full INTERVAL.
note_result() {
    case $1 in
        1) CHECK_RESULT=1 ;;
        2) [ "$CHECK_RESULT" -eq 1 ] || CHECK_RESULT=2 ;;
    esac
}

# One pass over every configured record. Returns 0 when all of them are
# current, 1 when something failed that is worth retrying soon, and 2 when
# something needs the user's attention.
run_check() {
    local name addr4='' addr6='' level=debug
    CHECK_RESULT=0
    CHECK_UPDATED=0
    CHECK_UNCHANGED=0

    if [ -z "$ZONE_ID" ]; then
        resolve_zone || return
    fi

    if [ "$IPV4" = true ]; then
        if detect_ip 4; then
            addr4=$DETECTED_IP
        else
            log warn "could not determine the public IPv4 address; A records were not checked"
            CHECK_RESULT=1
        fi
    fi
    if [ "$IPV6" = true ]; then
        if detect_ip 6; then
            addr6=$DETECTED_IP
        else
            log warn "could not determine the public IPv6 address (does this container have IPv6 connectivity?); AAAA records were not checked"
            CHECK_RESULT=1
        fi
    fi

    for name in $RECORDS; do
        [ -n "$ZONE_ID" ] || break
        if [ -n "$addr4" ]; then
            sync_record A "$name" "$addr4"
            note_result "$?"
        fi
        if [ -n "$addr6" ]; then
            sync_record AAAA "$name" "$addr6"
            note_result "$?"
        fi
    done

    if [ "$CHECK_RESULT" -eq 0 ]; then
        # The first successful check is reported at info so a fresh install
        # visibly works; after that, only changes are worth the log space.
        if [ "$ANNOUNCED" = false ]; then
            level=info
            ANNOUNCED=true
        fi
        log "$level" "check complete (${addr4:+IPv4 $addr4}${addr4:+${addr6:+, }}${addr6:+IPv6 $addr6}): $CHECK_UPDATED updated, $CHECK_UNCHANGED unchanged"
    fi
    return "$CHECK_RESULT"
}

# Verifies the token and finds the zone before the first check. Network
# trouble is retried with backoff; a rejected token or missing zone is fatal,
# since retrying cannot fix either.
startup() {
    local backoff=0 rc
    while :; do
        verify_token && resolve_zone
        rc=$?
        [ "$rc" -ne 0 ] || return 0
        if [ "$rc" -eq 2 ]; then
            log error "stopping: fix the problem above, then restart the container"
            exit 1
        fi
        backoff=$(next_backoff "$backoff")
        log warn "retrying in ${backoff}s"
        sleep_for "$backoff"
    done
}

# Records the time of the last successful check for the health check. Written
# atomically so a health check never reads a half-written file.
mark_success() {
    if { mkdir -p "$STATE_DIR" &&
        date +%s >"$STATE_DIR/last-success.tmp" &&
        mv -f "$STATE_DIR/last-success.tmp" "$STATE_DIR/last-success"; } 2>/dev/null; then
        return 0
    fi
    log warn "could not write $STATE_DIR/last-success; the container health check will report unhealthy"
}

# Exits 0 if the last successful check is recent enough: within INTERVAL plus
# a grace period, so one slow or retried check does not flap the status.
healthcheck() {
    local raw interval file last='' age limit
    raw=${INTERVAL:-}
    trim_var raw
    interval=$(parse_uint "${raw:-86400}") || interval=86400
    [ "$interval" -ge 1 ] || interval=86400
    raw=${STATE_DIR:-}
    trim_var raw
    file="${raw:-$DEFAULT_STATE_DIR}/last-success"

    if [ ! -r "$file" ]; then
        printf 'unhealthy: no successful check yet\n'
        return 1
    fi
    IFS= read -r last <"$file" || :
    case $last in
        '' | *[!0-9]*)
            printf 'unhealthy: %s does not contain a timestamp\n' "$file"
            return 1
            ;;
    esac
    age=$(($(date +%s) - last))
    limit=$((interval + HEALTH_GRACE))
    if [ "$age" -gt "$limit" ]; then
        printf 'unhealthy: last successful check was %ss ago (limit %ss)\n' "$age" "$limit"
        return 1
    fi
    printf 'healthy: last successful check was %ss ago\n' "$age"
}

on_signal() {
    log info "received SIG$1, shutting down"
    if [ -n "$CHILD_PID" ]; then
        kill "$CHILD_PID" 2>/dev/null || :
    fi
    exit 0
}

cleanup() {
    if [ -n "$NFA_TMP" ]; then
        rm -rf "$NFA_TMP"
    fi
}

main() {
    local backoff=0 delay
    case ${1:-} in
        '') ;;
        healthcheck)
            healthcheck
            return
            ;;
        version | --version)
            printf 'nofixedaddress %s\n' "$NFA_VERSION"
            return 0
            ;;
        *)
            printf 'usage: nofixedaddress [healthcheck | version]\n' >&2
            return 2
            ;;
    esac

    trap cleanup EXIT
    trap 'on_signal TERM' TERM
    trap 'on_signal INT' INT

    log info "No Fixed Address $NFA_VERSION starting"
    load_config || exit 2
    if ! NFA_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nofixedaddress.XXXXXX"); then
        log error "cannot create a temporary directory in ${TMPDIR:-/tmp}; with a read-only root filesystem, mount a tmpfs at /tmp"
        exit 2
    fi
    describe_config
    startup

    while :; do
        run_check
        case $? in
            0)
                backoff=0
                delay=$INTERVAL
                mark_success
                log debug "next check in ${delay}s"
                ;;
            1)
                backoff=$(next_backoff "$backoff")
                delay=$backoff
                log warn "check incomplete; retrying in ${delay}s"
                ;;
            *)
                backoff=0
                delay=$INTERVAL
                log error "check finished with problems that need attention; next check in ${delay}s"
                ;;
        esac
        sleep_for "$delay"
    done
}

# Sourcing with NFA_SOURCE_ONLY=1 loads the functions without starting the
# daemon, which is how tests/run.sh exercises them.
[ "${NFA_SOURCE_ONLY:-0}" = 1 ] || main "$@"
