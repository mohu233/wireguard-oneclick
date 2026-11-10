#!/bin/sh
# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR
# POSIX entry point: this file is also safe to launch with `sh deploy.sh`.
if [ -z "${BASH_VERSION:-}" ]; then
    command -v bash >/dev/null 2>&1 || { echo 'Bash is required.' >&2; exit 1; }
    exec bash "$0" "$@"
fi
set -Eeuo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
BASE=/opt/office-wg
UNIT=/etc/systemd/system/office-wg.service
SYSCTL_FILE=/etc/sysctl.d/90-office-wg.conf
MANAGER=office-wg-bundle-v1
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
MODE=deploy
EXPORT_STDOUT=0
CONFIG=''
DEMO_DIR=''
NEW_INSTALL=0
COMMITTED=0
OLD_FORWARD=''

log() { printf '[office-wg] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
usage() {
    cat <<'HELP'
Usage: sh deploy.sh [--check | --export] [--export-stdout] [server.env]
       sh deploy.sh --render-demo OUTPUTDIR [server.env]

Run on a new systemd Linux VPS as root. The configuration is data, not shell code.
--check          Validate inputs and server readiness without changing anything.
--export         Export an existing installation without replacing keys or peers.
--export-stdout  Return two base64 profile markers for the Windows launcher.
--render-demo    Offline example rendering only: invalid placeholder keys, no deployment.
HELP
}

while (($#)); do
    case "$1" in
        --check) [[ $MODE = deploy ]] || die 'Choose only one mode.'; MODE=check ;;
        --export) [[ $MODE = deploy ]] || die 'Choose only one mode.'; MODE='export' ;;
        --export-stdout) EXPORT_STDOUT=1 ;;
        --render-demo)
            [[ $MODE = deploy && $# -ge 2 ]] || die '--render-demo requires an output directory.'
            MODE=demo; DEMO_DIR=$2; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; (($# <= 1)) || die 'Too many configuration files.'; CONFIG=${1:-}; break ;;
        -*) die 'Unknown option.' ;;
        *) [[ -z $CONFIG ]] || die 'Only one server.env may be supplied.'; CONFIG=$1 ;;
    esac
    shift
done

trim() {
    local text=$1
    text="${text#"${text%%[!$' \t\r\n']*}"}"
    text="${text%"${text##*[!$' \t\r\n']}"}"
    REPLY=$text
}

# No source/eval: quoted values are unwrapped as data, never interpreted.
read_data_file() {
    local file=$1 kind=$2 line key value number=0
    local -A seen=()
    [[ -f $file && ! -L $file ]] || die "Configuration must be a regular non-symlink file: $file"
    while IFS= read -r line || [[ -n $line ]]; do
        number=$((number + 1)); line=${line%$'\r'}
        if ((number == 1)); then line=${line#$'\xEF\xBB\xBF'}; fi
        trim "$line"; line=$REPLY
        [[ -z $line || $line = \#* ]] && continue
        [[ $line = *=* ]] || die "Invalid data line $number in $file"
        key=${line%%=*}; value=${line#*=}
        trim "$key"; key=$REPLY; trim "$value"; value=$REPLY
        [[ $key =~ ^[A-Z][A-Z0-9_]*$ ]] || die "Invalid setting name on line $number"
        [[ -z ${seen[$key]+present} ]] || die "Duplicate setting on line $number: $key"
        seen[$key]=1
        if [[ ${value:0:1} = '"' || ${value:0:1} = "'" ]]; then
            [[ ${#value} -ge 2 && ${value: -1} = "${value:0:1}" ]] || die "Unmatched quotes on line $number"
            value=${value:1:${#value}-2}
        fi
        [[ $value != *$'\n'* && $value != *$'\r'* && $value != *$'\t'* ]] || die "Control character on line $number"
        if [[ $kind = config ]]; then
            case "$key" in
                ENDPOINT|WG_PORT|VPN_SUBNET|DNS|MTU|WAN_INTERFACE) printf -v "$key" '%s' "$value" ;;
                SSH_HOST|SSH_PORT|SSH_USER|SSH_IDENTITY_FILE) : ;;
                *) die "Unknown setting on line $number: $key" ;;
            esac
        else
            case "$key" in
                MANAGED_BY|ENDPOINT|WG_PORT|VPN_SUBNET|DNS|MTU|WAN_INTERFACE|RUNTIME|WG_BIN|GO_BIN|FIREWALL_MODE)
                    printf -v "S_$key" '%s' "$value" ;;
                *) die "Unexpected deployment metadata field: $key" ;;
            esac
        fi
    done < "$file"
}

ipv4_valid() {
    local ip=$1 part
    local -a octets
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a octets <<< "$ip"
    for part in "${octets[@]}"; do
        [[ ${#part} -le 3 && ( $part = 0 || $part != 0* ) ]] || return 1
        ((10#$part <= 255)) || return 1
    done
}

validate_settings() {
    local prefix last part label first second
    local -a dns_values labels
    [[ -n $ENDPOINT && ${#ENDPOINT} -le 253 ]] || die 'ENDPOINT is required (public IPv4 address or hostname).'
    if [[ $ENDPOINT =~ ^[0-9.]+$ ]]; then
        ipv4_valid "$ENDPOINT" || die 'ENDPOINT is not a valid IPv4 address.'
    else
        [[ $ENDPOINT =~ ^[A-Za-z0-9.-]+$ && $ENDPOINT != .* && $ENDPOINT != *. && $ENDPOINT != *..* ]] || die 'ENDPOINT must be a plain hostname, without scheme or port.'
        IFS=. read -r -a labels <<< "$ENDPOINT"
        for label in "${labels[@]}"; do
            [[ ${#label} -le 63 && $label != -* && $label != *- ]] || die 'Invalid ENDPOINT hostname label.'
        done
        ENDPOINT=${ENDPOINT,,}
    fi
    [[ $WG_PORT =~ ^[0-9]{1,5}$ ]] || die 'WG_PORT must be 1..65535.'
    ((10#$WG_PORT >= 1 && 10#$WG_PORT <= 65535)) || die 'WG_PORT must be 1..65535.'
    WG_PORT=$((10#$WG_PORT))
    [[ $VPN_SUBNET = */24 ]] || die 'VPN_SUBNET must be an IPv4 /24 network, for example 10.66.66.0/24.'
    prefix=${VPN_SUBNET%/24}; ipv4_valid "$prefix" || die 'Invalid VPN_SUBNET.'
    last=${prefix##*.}; [[ $last = 0 ]] || die 'VPN_SUBNET must end in .0/24.'
    IFS=. read -r first second _ _ <<< "$prefix"
    [[ $first = 10 || ( $first = 172 && $second -ge 16 && $second -le 31 ) || ( $first = 192 && $second = 168 ) ]] || die 'VPN_SUBNET must be an RFC1918 private /24 (10.x, 172.16..31.x, or 192.168.x).'
    VPN_PREFIX=${prefix%.*}
    [[ $MTU =~ ^[0-9]{3,4}$ ]] || die 'MTU must be 1280..1420.'
    ((10#$MTU >= 1280 && 10#$MTU <= 1420)) || die 'MTU must be 1280..1420.'
    MTU=$((10#$MTU))
    [[ $WAN_INTERFACE = auto || $WAN_INTERFACE =~ ^[A-Za-z0-9_][A-Za-z0-9_.:-]{0,14}$ ]] || die 'Invalid WAN_INTERFACE.'
    [[ -n $DNS && $DNS != ,* && $DNS != *, && $DNS != *,,* ]] || die 'DNS must be a comma-separated IPv4 list.'
    IFS=, read -r -a dns_values <<< "$DNS"
    ((${#dns_values[@]} <= 3)) || die 'Use at most three DNS servers.'
    DNS=''
    for part in "${dns_values[@]}"; do
        trim "$part"; part=$REPLY; ipv4_valid "$part" || die 'DNS contains an invalid IPv4 address.'
        DNS+="${DNS:+,}$part"
    done
}

ENDPOINT=''; WG_PORT=51820; VPN_SUBNET=10.66.66.0/24
DNS=1.1.1.1,9.9.9.9; MTU=1420; WAN_INTERFACE=auto
if [[ -n $CONFIG ]]; then
    read_data_file "$CONFIG" config
elif [[ -f "$SCRIPT_DIR/server.env" ]]; then
    CONFIG="$SCRIPT_DIR/server.env"; read_data_file "$CONFIG" config
fi
if [[ -z $ENDPOINT ]]; then
    if [[ $MODE = demo ]]; then ENDPOINT=203.0.113.10
    elif [[ -t 0 && -t 1 ]]; then read -r -p 'VPS public IPv4 or hostname: ' ENDPOINT
    else die 'ENDPOINT is empty. Fill server.env before non-interactive deployment.'; fi
fi
validate_settings

render_profiles() {
    local directory=$1 server_public=$2 router_private=$3 test_private=$4 role private suffix
    for role in router test; do
        if [[ $role = router ]]; then private=$router_private; suffix=2; else private=$test_private; suffix=3; fi
        cat > "$directory/wg-$role.conf" <<PROFILE
[Interface]
PrivateKey = $private
Address = $VPN_PREFIX.$suffix/32
DNS = $DNS
MTU = $MTU

[Peer]
PublicKey = $server_public
AllowedIPs = 0.0.0.0/0
Endpoint = $ENDPOINT:$WG_PORT
PersistentKeepalive = 25
PROFILE
        chmod 0600 "$directory/wg-$role.conf"
    done
}

if [[ $MODE = demo ]]; then
    [[ $EXPORT_STDOUT = 0 ]] || die 'Demo cannot export real profile markers.'
    [[ -n $DEMO_DIR && ! -L $DEMO_DIR ]] || die 'Invalid demo output directory.'
    mkdir -p -- "$DEMO_DIR"; chmod 0700 "$DEMO_DIR"
    [[ ! -e "$DEMO_DIR/wg-router.conf" && ! -e "$DEMO_DIR/wg-test.conf" ]] || die 'Demo refuses to overwrite existing profiles.'
    render_profiles "$DEMO_DIR" '<DEMO_SERVER_PUBLIC_KEY_NOT_USABLE>' '<DEMO_ROUTER_PRIVATE_KEY_NOT_USABLE>' '<DEMO_TEST_PRIVATE_KEY_NOT_USABLE>'
    log 'DEMO ONLY: two example files contain invalid placeholder keys; no server was changed.'
    exit 0
fi

[[ $(uname -s) = Linux && $EUID = 0 ]] || die 'Run as root on the target Linux VPS.'
[[ -d /run/systemd/system ]] || die 'This installer requires systemd running as PID 1.'
command -v systemctl >/dev/null 2>&1 || die 'This installer requires systemd running as PID 1.'
command -v ip >/dev/null 2>&1 || die 'Install iproute2 (Debian/Ubuntu) or iproute (RHEL/CentOS) first.'
command -v flock >/dev/null 2>&1 || die 'The flock utility (util-linux) is required.'

if [[ $WAN_INTERFACE = auto ]]; then
    WAN_INTERFACE=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
fi
[[ -n $WAN_INTERFACE ]] || die 'No IPv4 default route. Specify WAN_INTERFACE.'
ip link show dev "$WAN_INTERFACE" >/dev/null 2>&1 || die 'WAN_INTERFACE does not exist.'
[[ $WAN_INTERFACE != wg-office && $WAN_INTERFACE != lo ]] || die 'WAN_INTERFACE must be a physical/public upstream interface.'

detect_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        die 'UFW is active. Automatic deployment is refused; integrate WireGuard forwarding/NAT with UFW explicitly first.'
    fi
    if systemctl is-active --quiet firewalld; then
        command -v firewall-cmd >/dev/null 2>&1 || die 'firewalld is active but firewall-cmd is missing.'
        local backend='' version
        if [[ -r /etc/firewalld/firewalld.conf ]]; then
            backend=$(awk -F= '/^[[:space:]]*FirewallBackend[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2);print $2;exit}' /etc/firewalld/firewalld.conf)
        fi
        if [[ -z $backend ]]; then
            # firewalld >= 0.6 defaults to nftables, including when its config file is absent.
            version=$(firewall-cmd --version)
            case "$version" in 0.[0-5].*) backend=iptables ;; *) backend=nftables ;; esac
        fi
        [[ $backend = iptables ]] || die 'firewalld uses nftables. This package refuses partial direct-rule integration; use a supported iptables backend or an explicit firewalld zone/policy setup.'
        FIREWALL_MODE=firewalld
    else
        if command -v nft >/dev/null 2>&1 && nft list tables 2>/dev/null | grep -q '^table inet '; then
            die 'A native nftables inet firewall is present. Automatic iptables-only integration is refused.'
        fi
        FIREWALL_MODE=iptables
    fi
}
detect_firewall

load_existing() {
    [[ -f "$BASE/metadata.env" ]] || return 1
    read_data_file "$BASE/metadata.env" metadata
    [[ ${S_MANAGED_BY:-} = "$MANAGER" ]] || die 'Existing /opt/office-wg is not managed by this bundle.'
    local key current saved
    for key in ENDPOINT WG_PORT VPN_SUBNET DNS MTU WAN_INTERFACE FIREWALL_MODE; do
        current=${!key}; saved=S_$key
        [[ $current = "${!saved:-}" ]] || die "Existing installation has different $key. No service, peer or key was overwritten."
    done
    RUNTIME=${S_RUNTIME:-}; WG_BIN=${S_WG_BIN:-}; GO_BIN=${S_GO_BIN:-}
    [[ $RUNTIME = kernel || $RUNTIME = userspace ]] || die 'Invalid runtime metadata.'
    [[ $WG_BIN =~ ^/[A-Za-z0-9_./+-]+$ && -x $WG_BIN ]] || die 'Managed wg executable is missing.'
    [[ $RUNTIME = kernel || ( $GO_BIN =~ ^/[A-Za-z0-9_./+-]+$ && -x $GO_BIN ) ]] || die 'Managed userspace runtime is missing.'
    [[ -f $UNIT && -x "$BASE/service.sh" && -f "$BASE/server/server.conf" ]] || die 'Managed installation is incomplete; preserve its files and inspect it manually.'
    grep -q '^# Managed-By: office-wg-bundle-v1$' "$UNIT" || die 'Service ownership marker is missing.'
    return 0
}

guard_new_install() {
    [[ ! -e $BASE && ! -L $BASE ]] || die '/opt/office-wg already exists without valid metadata; refusing to overwrite it.'
    [[ ! -e $UNIT && ! -L $UNIT && ! -e $SYSCTL_FILE && ! -L $SYSCTL_FILE ]] || die 'A service/sysctl file conflicts with this deployment.'
    if [[ -e /VPS/server/server.conf || -e /usr/local/sbin/office-wg-up ]] || \
       systemctl cat office-wireguard.service >/dev/null 2>&1 || \
       systemctl cat office-wg.service >/dev/null 2>&1; then
        die 'An existing/historical Office WireGuard installation was found. This bundle will not overwrite or migrate it.'
    fi
    ! ip link show dev wg-office >/dev/null 2>&1 || die 'wg-office is already owned by another installation.'
    if command -v ss >/dev/null 2>&1 && ss -H -lun | awk -v p=":$WG_PORT" '$5 ~ (p"$") || $4 ~ (p"$") {found=1} END{exit !found}'; then
        die "UDP $WG_PORT is already in use."
    fi
    # Refuse overlap with connected networks, including a non-/24 covering this subnet.
    local network
    network=$(ip -4 route show scope link | awk '{print $1}')
    if awk -v target="$VPN_SUBNET" '
        function number(ip,a){split(ip,a,".");return ((a[1]*256+a[2])*256+a[3])*256+a[4]}
        BEGIN{split(target,t,"/");n=number(t[1]);bad=0}
        {if($0 !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/)next;
         split($0,r,"/");size=2^(32-r[2]);start=number(r[1]);
         if(n<start+size && n+256>start)bad=1}
        END{exit !bad}' <<< "$network"; then
        die 'VPN_SUBNET overlaps a connected IPv4 network. Choose another /24.'
    fi
    if command -v iptables >/dev/null 2>&1; then
        local item table chain
        for item in filter:OWG_INPUT filter:OWG_FWD nat:OWG_NAT mangle:OWG_MSS; do
            table=${item%:*}; chain=${item#*:}
            ! iptables -w 5 -t "$table" -S "$chain" >/dev/null 2>&1 || die "Existing firewall chain $chain conflicts with this bundle."
        done
    fi
}

validate_existing_profiles() {
    local role private public
    local peers
    peers=$("$WG_BIN" show wg-office peers) || die 'Cannot inspect existing WireGuard peers.'
    for role in router test; do
        [[ -s "$BASE/server/$role.key" ]] || die "Missing managed $role client key."
        private=$(cat "$BASE/server/$role.key")
        public=$(printf '%s\n' "$private" | "$WG_BIN" pubkey) || die 'Invalid saved client key.'
        grep -Fxq -- "$public" <<< "$peers" || die "The saved $role identity is no longer a live server peer. No peers were replaced."
    done
}

health_check() {
    systemctl is-active --quiet office-wg.service || die 'office-wg service is not active.'
    systemctl is-enabled --quiet office-wg.service || die 'office-wg service is not enabled.'
    ip -4 address show dev wg-office | grep -Fq " $VPN_PREFIX.1/24 " || die 'WireGuard server address is missing.'
    [[ $("$WG_BIN" show wg-office listen-port) = "$WG_PORT" ]] || die 'WireGuard listen port differs from metadata.'
    [[ $("$WG_BIN" show wg-office public-key) = "$("$WG_BIN" pubkey < "$BASE/server/server.key")" ]] || die 'Saved server key does not match the running interface.'
    [[ $(cat /proc/sys/net/ipv4/ip_forward) = 1 ]] || die 'IPv4 forwarding is disabled.'
    "$BASE/firewall.sh" check || die 'One or more managed firewall rules are missing.'
    validate_existing_profiles
    log 'Service, interface, forwarding, two client identities and firewall rules passed local checks.'
    log 'A real client handshake, DNS, HTTPS and speed test are still required; local checks do not establish line quality.'
}

export_profiles() {
    local server_public router_private test_private role output
    server_public=$("$WG_BIN" pubkey < "$BASE/server/server.key")
    router_private=$(cat "$BASE/server/router.key"); test_private=$(cat "$BASE/server/test.key")
    render_profiles "$BASE/clients" "$server_public" "$router_private" "$test_private"
    unset router_private test_private
    if ((EXPORT_STDOUT)); then
        for role in router test; do
            output=$(base64 < "$BASE/clients/wg-$role.conf" | tr -d '\r\n')
            printf '__WG_PROFILE__wg-%s.conf:%s\n' "$role" "$output"
        done
        unset output
    else
        output="$SCRIPT_DIR/output"
        [[ ! -L $output ]] || die 'Output path is a symlink; refusing to copy private profiles.'
        mkdir -p "$output"; chmod 0700 "$output"
        for role in router test; do
            [[ ! -L "$output/wg-$role.conf" ]] || die 'A profile output path is a symlink.'
            install -m 0600 "$BASE/clients/wg-$role.conf" "$output/wg-$role.conf"
        done
        log "Two private client profiles saved in $output and $BASE/clients."
    fi
}

if load_existing; then
    if [[ $MODE = check ]]; then health_check; exit 0; fi
    if [[ $MODE = deploy ]]; then
        # Never rewrite server.conf or use setconf on a running existing installation.
        health_check
    fi
    export_profiles
    exit 0
fi
[[ $MODE != export ]] || die 'No deployment metadata found; there is nothing to export.'
guard_new_install
if [[ $MODE = check ]]; then
    log "Inputs and conflict checks passed. WAN=$WAN_INTERFACE, UDP=$WG_PORT, network=$VPN_SUBNET."
    missing=''
    for dependency in wg iptables ss curl tar xz sha256sum make gcc sysctl; do
        command -v "$dependency" >/dev/null 2>&1 || missing+=" $dependency"
    done
    if [[ -n $missing ]]; then
        log "Not installed:$missing. Deployment will attempt distribution packages or the pinned official source build."
    fi
    log 'Check mode made no changes. Kernel/userspace choice, package availability and actual client connectivity have not been tested.'
    exit 0
fi

# Fixed lock serializes two installers without putting a lock in the upload folder.
exec 9>/run/lock/office-wg-deploy.lock
flock -n 9 || die 'Another Office WireGuard deployment is running.'
# Recheck after acquiring the lock before creating any owned files.
guard_new_install
OLD_FORWARD=$(cat /proc/sys/net/ipv4/ip_forward)

rollback() {
    local status=$?
    trap - EXIT INT TERM
    if ((NEW_INSTALL && !COMMITTED)); then
        log 'Installation failed; removing only this new service, interface and its firewall rules.'
        systemctl stop office-wg.service >/dev/null 2>&1 || true
        [[ ! -x "$BASE/firewall.sh" ]] || "$BASE/firewall.sh" down >/dev/null 2>&1 || true
        ip link delete dev wg-office >/dev/null 2>&1 || true
        systemctl disable office-wg.service >/dev/null 2>&1 || true
        rm -f -- "$UNIT" "$SYSCTL_FILE"
        if [[ -n $OLD_FORWARD ]]; then sysctl -w "net.ipv4.ip_forward=$OLD_FORWARD" >/dev/null 2>&1 || true; fi
        # BASE is a fixed, checked path created by this execution only.
        rm -rf -- /opt/office-wg
        systemctl daemon-reload >/dev/null 2>&1 || true
        log 'Installed distribution packages were left installed. No existing firewall rules were flushed.'
    fi
    exit "$status"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -m 0700 -- "$BASE"; NEW_INSTALL=1
mkdir -m 0700 "$BASE/server" "$BASE/clients"
[[ -r "$SCRIPT_DIR/lib/install-runtime.sh" ]] || die 'Missing lib/install-runtime.sh; upload the entire package.'
# This is the installer-owned library, never user configuration.
# shellcheck source=lib/install-runtime.sh
source "$SCRIPT_DIR/lib/install-runtime.sh"
install_runtime
# Packages may activate a firewall manager; refuse if integration mode changed.
OLD_FIREWALL_MODE=$FIREWALL_MODE; detect_firewall
[[ $OLD_FIREWALL_MODE = "$FIREWALL_MODE" ]] || die 'Firewall manager changed during dependency installation.'
if ss -H -lun | awk -v p=":$WG_PORT" '$5 ~ (p"$") || $4 ~ (p"$") {found=1} END{exit !found}'; then
    die "UDP $WG_PORT became occupied during setup."
fi

for role in server router test; do
    "$WG_BIN" genkey > "$BASE/server/$role.key"
    "$WG_BIN" pubkey < "$BASE/server/$role.key" > "$BASE/server/$role.pub"
    chmod 0600 "$BASE/server/$role.key" "$BASE/server/$role.pub"
done
cat > "$BASE/server/server.conf" <<SERVER
[Interface]
PrivateKey = $(cat "$BASE/server/server.key")
ListenPort = $WG_PORT

[Peer]
# Dedicated router identity; do not share with another active device.
PublicKey = $(cat "$BASE/server/router.pub")
AllowedIPs = $VPN_PREFIX.2/32

[Peer]
# Independent computer/phone test identity.
PublicKey = $(cat "$BASE/server/test.pub")
AllowedIPs = $VPN_PREFIX.3/32
SERVER
chmod 0600 "$BASE/server/server.conf"

# Only validated constants are embedded. No supplied file is ever executed.
{
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
    printf 'WAN=%q\nPORT=%q\nSUBNET=%q\nMODE=%q\n' "$WAN_INTERFACE" "$WG_PORT" "$VPN_SUBNET" "$FIREWALL_MODE"
    cat <<'FIREWALL'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
action=${1:?up/down/check required}
case "$action" in up|down|check) ;; *) exit 2 ;; esac
direct_rule() {
    local table=$1 chain=$2; shift 2
    local scope
    local -a options
    for scope in runtime permanent; do
        options=(); [[ $scope = runtime ]] || options+=(--permanent)
        if [[ $action = up ]]; then
            firewall-cmd "${options[@]}" --direct --query-rule ipv4 "$table" "$chain" 0 "$@" >/dev/null 2>&1 ||
                firewall-cmd "${options[@]}" --direct --add-rule ipv4 "$table" "$chain" 0 "$@" >/dev/null
        elif [[ $action = check ]]; then
            firewall-cmd "${options[@]}" --direct --query-rule ipv4 "$table" "$chain" 0 "$@" >/dev/null 2>&1 || return 1
        else
            firewall-cmd "${options[@]}" --direct --remove-rule ipv4 "$table" "$chain" 0 "$@" >/dev/null 2>&1 || true
        fi
    done
}
ipt() { iptables -w 5 "$@"; }
ensure_rule() {
    local table=$1 chain=$2; shift 2
    if [[ $action = check ]]; then ipt -t "$table" -C "$chain" "$@" >/dev/null 2>&1
    else ipt -t "$table" -C "$chain" "$@" >/dev/null 2>&1 || ipt -t "$table" -A "$chain" "$@"; fi
}
if [[ $MODE = firewalld ]]; then
    direct_rule filter INPUT -i "$WAN" -p udp --dport "$PORT" -m comment --comment office-wg-v1-input -j ACCEPT
    direct_rule filter FORWARD -i wg-office -o "$WAN" -s "$SUBNET" -m comment --comment office-wg-v1-forward -j ACCEPT
    direct_rule filter FORWARD -i "$WAN" -o wg-office -d "$SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment office-wg-v1-return -j ACCEPT
    direct_rule nat POSTROUTING -s "$SUBNET" -o "$WAN" -m comment --comment office-wg-v1-nat -j MASQUERADE
    direct_rule mangle FORWARD -i wg-office -p tcp --tcp-flags SYN,RST SYN -m comment --comment office-wg-v1-mss-in -j TCPMSS --clamp-mss-to-pmtu
    direct_rule mangle FORWARD -o wg-office -p tcp --tcp-flags SYN,RST SYN -m comment --comment office-wg-v1-mss-out -j TCPMSS --clamp-mss-to-pmtu
    exit 0
fi
for item in filter:INPUT:OWG_INPUT filter:FORWARD:OWG_FWD nat:POSTROUTING:OWG_NAT mangle:FORWARD:OWG_MSS; do
    IFS=: read -r table parent chain <<< "$item"
    if [[ $action = down ]]; then
        while ipt -t "$table" -C "$parent" -m comment --comment office-wg-v1 -j "$chain" >/dev/null 2>&1; do
            ipt -t "$table" -D "$parent" -m comment --comment office-wg-v1 -j "$chain" || break
        done
        # These four names were required absent before our first installation.
        ipt -t "$table" -F "$chain" >/dev/null 2>&1 || true
        ipt -t "$table" -X "$chain" >/dev/null 2>&1 || true
    elif [[ $action = up ]]; then
        ipt -t "$table" -S "$chain" >/dev/null 2>&1 || ipt -t "$table" -N "$chain"
        ipt -t "$table" -C "$parent" -m comment --comment office-wg-v1 -j "$chain" >/dev/null 2>&1 ||
            ipt -t "$table" -I "$parent" 1 -m comment --comment office-wg-v1 -j "$chain"
    else
        ipt -t "$table" -C "$parent" -m comment --comment office-wg-v1 -j "$chain" >/dev/null 2>&1
    fi
done
[[ $action != down ]] || exit 0
ensure_rule filter OWG_INPUT -i "$WAN" -p udp --dport "$PORT" -j ACCEPT
ensure_rule filter OWG_FWD -i wg-office -o "$WAN" -s "$SUBNET" -j ACCEPT
ensure_rule filter OWG_FWD -i "$WAN" -o wg-office -d "$SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
ensure_rule nat OWG_NAT -s "$SUBNET" -o "$WAN" -j MASQUERADE
ensure_rule mangle OWG_MSS -i wg-office -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ensure_rule mangle OWG_MSS -o wg-office -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
FIREWALL
} > "$BASE/firewall.sh"
chmod 0700 "$BASE/firewall.sh"

{
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
    printf 'BASE=%q\nWG=%q\nRUNTIME=%q\nADDRESS=%q\nMTU=%q\n' "$BASE" "$WG_BIN" "$RUNTIME" "$VPN_PREFIX.1/24" "$MTU"
    cat <<'SERVICE_SCRIPT'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
case ${1:-} in
    start)
        ip link add dev wg-office type wireguard
        "$0" configure
        ;;
    configure)
        if [[ $RUNTIME = userspace ]]; then
            for _ in {1..100}; do
                [[ ! -S /var/run/wireguard/wg-office.sock ]] || break
                sleep 0.1
            done
            [[ -S /var/run/wireguard/wg-office.sock ]]
        fi
        "$WG" setconf wg-office "$BASE/server/server.conf"
        ip -4 address replace "$ADDRESS" dev wg-office
        ip link set dev wg-office mtu "$MTU" up
        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        "$BASE/firewall.sh" up
        ;;
    cleanup)
        "$BASE/firewall.sh" down || true
        ip link delete dev wg-office >/dev/null 2>&1 || true
        ;;
    *) exit 2 ;;
esac
SERVICE_SCRIPT
} > "$BASE/service.sh"
chmod 0700 "$BASE/service.sh"
{
    cat <<'UNIT_HEAD'
# Managed-By: office-wg-bundle-v1
[Unit]
Description=Office WireGuard IPv4 exit
Wants=network-online.target
After=network-online.target firewalld.service

[Service]
UMask=0077
UNIT_HEAD
    if [[ $RUNTIME = kernel ]]; then
        printf 'Type=oneshot\nRemainAfterExit=yes\nExecStart=%s/service.sh start\n' "$BASE"
    else
        printf 'Type=simple\nEnvironment=LOG_LEVEL=error\nExecStart=%s -f wg-office\nExecStartPost=%s/service.sh configure\nRestart=on-failure\nRestartSec=3\n' "$GO_BIN" "$BASE"
    fi
    printf 'ExecStopPost=%s/service.sh cleanup\nTimeoutStartSec=40\nTimeoutStopSec=20\n\n[Install]\nWantedBy=multi-user.target\n' "$BASE"
} > "$UNIT"
chmod 0644 "$UNIT"
printf '# Managed-By: %s\nnet.ipv4.ip_forward = 1\n' "$MANAGER" > "$SYSCTL_FILE"
chmod 0644 "$SYSCTL_FILE"
{
    printf 'MANAGED_BY=%s\n' "$MANAGER"
    for key in ENDPOINT WG_PORT VPN_SUBNET DNS MTU WAN_INTERFACE RUNTIME WG_BIN GO_BIN FIREWALL_MODE; do
        printf '%s=%s\n' "$key" "${!key}"
    done
} > "$BASE/metadata.env"
chmod 0600 "$BASE/metadata.env"
systemctl daemon-reload
systemctl enable office-wg.service >&2
systemctl start office-wg.service
health_check
export_profiles
COMMITTED=1
log 'Deployment complete. Allow the chosen UDP port in the cloud security group if the provider has one.'
