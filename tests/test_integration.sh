#!/usr/bin/env bash
# Destructive integration test, exclusively for an ephemeral GitHub-hosted Linux VM.
# Never run this on a developer computer or any real/user-owned VPS.
set -Eeuo pipefail
umask 077

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# These checks precede mktemp, package installation and all system mutations.
[[ ${GITHUB_ACTIONS:-} = true ]] || fail 'Integration is restricted to GITHUB_ACTIONS=true.'
[[ ${RUNNER_ENVIRONMENT:-} = github-hosted ]] || fail 'Self-hosted runners, developer computers and user VPSs are forbidden.'
[[ $EUID = 0 ]] || fail 'Integration requires root on an ephemeral GitHub-hosted VM.'
[[ $(uname -s) = Linux && -d /run/systemd/system ]] || fail 'Integration requires a running systemd Linux VM.'
[[ -d /home/runner && -d /opt/hostedtoolcache ]] || fail 'Expected GitHub-hosted runner directories are absent.'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PACKAGE_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
BASE=/opt/office-wg
UNIT=/etc/systemd/system/office-wg.service
SYSCTL_FILE=/etc/sysctl.d/90-office-wg.conf
NS=owg-ci-client
HOST_LINK=owg-ci-host
CLIENT_LINK=owg-ci-eth
CLIENT_WG=owg-ci-wg
PORT=51820
TEMP_DIR=''
GO_PID=''
WG_BIN=''
GO_BIN=''
SERVER_RUNTIME=''
OWN_DEPLOYMENT=0
OWN_NAMESPACE=0
ALLOW_OUTER=0
ALLOW_INNER=0
ORIGINAL_FORWARD=$(cat /proc/sys/net/ipv4/ip_forward)

# Refuse even on a hosted runner if this job would overlap somebody else's state.
[[ ! -e $BASE && ! -L $BASE && ! -e $UNIT && ! -e $SYSCTL_FILE ]] || fail 'Runner is not fresh: managed paths already exist.'
! systemctl cat office-wg.service >/dev/null 2>&1 || fail 'office-wg service already exists.'
! systemctl cat office-wireguard.service >/dev/null 2>&1 || fail 'Legacy Office WireGuard service already exists.'
! ip link show dev wg-office >/dev/null 2>&1 || fail 'wg-office already exists.'
! ip link show dev "$HOST_LINK" >/dev/null 2>&1 || fail 'Test veth name is already in use.'
! ip netns list | grep -Eq "^${NS}([[:space:]]|$)" || fail 'Test namespace already exists.'

cleanup() {
    local result=$?
    trap - EXIT INT TERM
    set +e
    if [[ -n $GO_PID ]]; then kill "$GO_PID" >/dev/null 2>&1; wait "$GO_PID" >/dev/null 2>&1; fi
    if ((ALLOW_OUTER)); then
        iptables -w 5 -D INPUT -i "$HOST_LINK" -p udp --dport "$PORT" \
            -m comment --comment office-wg-ci-outer -j ACCEPT >/dev/null 2>&1
    fi
    if ((ALLOW_INNER)); then
        iptables -w 5 -D INPUT -i wg-office -s 10.66.66.4/32 -p icmp --icmp-type echo-request \
            -m comment --comment office-wg-ci-inner -j ACCEPT >/dev/null 2>&1
    fi
    if ((OWN_NAMESPACE)); then ip netns delete "$NS" >/dev/null 2>&1; fi
    ip link delete dev "$HOST_LINK" >/dev/null 2>&1
    if ((OWN_DEPLOYMENT)); then
        systemctl stop office-wg.service >/dev/null 2>&1
        [[ ! -x "$BASE/firewall.sh" ]] || "$BASE/firewall.sh" down >/dev/null 2>&1
        systemctl disable office-wg.service >/dev/null 2>&1
        ip link delete dev wg-office >/dev/null 2>&1
        rm -f -- "$UNIT" "$SYSCTL_FILE"
        # This fixed path was required absent and created only by this CI execution.
        rm -rf -- /opt/office-wg
        systemctl daemon-reload >/dev/null 2>&1
        sysctl -w "net.ipv4.ip_forward=$ORIGINAL_FORWARD" >/dev/null 2>&1
    fi
    case "$TEMP_DIR" in /tmp/office-wg-ci.*) rm -rf -- "$TEMP_DIR" ;; esac
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

TEMP_DIR=$(mktemp -d /tmp/office-wg-ci.XXXXXXXX)
mkdir -m 0700 "$TEMP_DIR/package" "$TEMP_DIR/package/lib" "$TEMP_DIR/exported"
install -m 0700 "$PACKAGE_DIR/deploy.sh" "$TEMP_DIR/package/deploy.sh"
install -m 0600 "$PACKAGE_DIR/lib/install-runtime.sh" "$TEMP_DIR/package/lib/install-runtime.sh"
CONFIG="$TEMP_DIR/server.env"
cat > "$CONFIG" <<'CONFIG_DATA'
SSH_HOST=203.0.113.10
SSH_PORT=22
SSH_USER=root
SSH_IDENTITY_FILE=
ENDPOINT=203.0.113.10
WG_PORT=51820
VPN_SUBNET=10.66.66.0/24
DNS=1.1.1.1,9.9.9.9
MTU=1420
WAN_INTERFACE=auto
CONFIG_DATA

# 203.0.113.10 is documentation data only; no SSH or outbound client connection
# to that address occurs. The third test client uses a local veth endpoint below.
OWN_DEPLOYMENT=1
if ! sh "$TEMP_DIR/package/deploy.sh" "$CONFIG" > "$TEMP_DIR/deploy.stdout" 2> "$TEMP_DIR/deploy.log"; then
    # Installer logs intentionally exclude private material. Print a bounded tail
    # to make package/systemd failures diagnosable without dumping profiles.
    tail -n 50 "$TEMP_DIR/deploy.log" >&2
    fail 'Fresh VPS deployment failed.'
fi
[[ ! -s "$TEMP_DIR/deploy.stdout" ]] || fail 'Ordinary deployment unexpectedly wrote to stdout.'
systemctl is-active --quiet office-wg.service || fail 'Service is not active.'
systemctl is-enabled --quiet office-wg.service || fail 'Service is not enabled.'
[[ $(stat -c '%a' "$BASE") = 700 ]] || fail 'Private state directory permissions differ from 0700.'
for directory in server clients; do
    [[ $(stat -c '%a' "$BASE/$directory") = 700 ]] || fail 'A private subdirectory is not 0700.'
done
for item in server/server.conf server/server.key server/router.key server/test.key metadata.env clients/wg-router.conf clients/wg-test.conf; do
    [[ $(stat -c '%a' "$BASE/$item") = 600 ]] || fail 'A secret file is not 0600.'
    [[ $(stat -c '%u' "$BASE/$item") = 0 ]] || fail 'A secret file is not owned by root.'
done
for role in router test; do
    [[ $(stat -c '%a' "$TEMP_DIR/package/output/wg-$role.conf") = 600 ]] || fail 'A copied output profile is not 0600.'
    cmp -s "$TEMP_DIR/package/output/wg-$role.conf" "$BASE/clients/wg-$role.conf" || fail 'Output profile differs from persistent profile.'
done
pass 'Fresh deployment starts an enabled service and writes root-only state and two import profiles.'

# Read only known metadata fields as data; never source a configuration file.
WG_BIN=$(sed -n 's/^WG_BIN=//p' "$BASE/metadata.env")
GO_BIN=$(sed -n 's/^GO_BIN=//p' "$BASE/metadata.env")
SERVER_RUNTIME=$(sed -n 's/^RUNTIME=//p' "$BASE/metadata.env")
[[ -x $WG_BIN ]] || fail 'Installed wg executable is unavailable.'
[[ $SERVER_RUNTIME = kernel || $SERVER_RUNTIME = userspace ]] || fail 'Installer selected an unknown runtime.'
server_public=$("$WG_BIN" pubkey < "$BASE/server/server.key")
router_public=$("$WG_BIN" pubkey < "$BASE/server/router.key")
test_public=$("$WG_BIN" pubkey < "$BASE/server/test.key")
[[ $router_public != "$test_public" && $router_public != "$server_public" && $test_public != "$server_public" ]] || fail 'Server and client identities are not independent.'
[[ $("$WG_BIN" show wg-office public-key) = "$server_public" ]] || fail 'Server live key does not match its private key.'
[[ $("$WG_BIN" show wg-office peers | wc -l) -eq 2 ]] || fail 'Fresh server must have exactly two peers.'
"$WG_BIN" show wg-office allowed-ips | awk -v p="$router_public" '$1==p && $2=="10.66.66.2/32" {found=1} END{exit !found}' || fail 'Router peer address is wrong.'
"$WG_BIN" show wg-office allowed-ips | awk -v p="$test_public" '$1==p && $2=="10.66.66.3/32" {found=1} END{exit !found}' || fail 'Independent test peer address is wrong.'
for role in router test; do
    [[ $(awk -F' = ' '$1=="PrivateKey" {print $2}' "$BASE/clients/wg-$role.conf") = "$(cat "$BASE/server/$role.key")" ]] || fail 'An exported client private key is wrong.'
    [[ $(awk -F' = ' '$1=="PublicKey" {print $2}' "$BASE/clients/wg-$role.conf") = "$server_public" ]] || fail 'An exported server public key is wrong.'
    grep -Fxq 'Endpoint = 203.0.113.10:51820' "$BASE/clients/wg-$role.conf" || fail 'Exported endpoint differs from input.'
done
pass 'Both client profiles contain distinct genuine keys and matching live server peers.'

# Add an independent CI-only third identity to BOTH persistent and live state.
# Re-running the installer must preserve this later-added peer byte for byte.
"$WG_BIN" genkey > "$TEMP_DIR/client.key"
client_public=$("$WG_BIN" pubkey < "$TEMP_DIR/client.key")
"$WG_BIN" set wg-office peer "$client_public" allowed-ips 10.66.66.4/32
printf '\n[Peer]\n# Independent CI client, added after initial deployment.\nPublicKey = %s\nAllowedIPs = 10.66.66.4/32\n' "$client_public" >> "$BASE/server/server.conf"
snapshot() {
    sha256sum "$BASE/server/server.conf" "$BASE/server/server.key" \
        "$BASE/server/router.key" "$BASE/server/test.key" "$BASE/metadata.env" "$UNIT"
}
snapshot > "$TEMP_DIR/before.sha256"
bash "$TEMP_DIR/package/deploy.sh" "$CONFIG" > "$TEMP_DIR/repeat.stdout" 2> "$TEMP_DIR/repeat.log" || fail 'Same-parameter repeated deployment failed.'
[[ ! -s "$TEMP_DIR/repeat.stdout" ]] || fail 'Repeat deployment unexpectedly wrote to stdout.'
snapshot > "$TEMP_DIR/after.sha256"
cmp -s "$TEMP_DIR/before.sha256" "$TEMP_DIR/after.sha256" || fail 'Repeat deployment rewrote server configuration, keys, metadata or service.'
[[ $("$WG_BIN" show wg-office peers | wc -l) -eq 3 ]] || fail 'Repeat deployment lost an additional peer.'
"$WG_BIN" show wg-office peers | grep -Fxq -- "$client_public" || fail 'Third peer was removed by repeat deployment.'
bash "$TEMP_DIR/package/deploy.sh" --check "$CONFIG" > "$TEMP_DIR/check.stdout" 2> "$TEMP_DIR/check.log" || fail 'Read-only health check failed.'
snapshot > "$TEMP_DIR/after-check.sha256"
cmp -s "$TEMP_DIR/before.sha256" "$TEMP_DIR/after-check.sha256" || fail 'Check mode rewrote managed configuration.'
pass 'Same-parameter repeat and check preserve original keys, server configuration and a later-added third peer.'

bash "$TEMP_DIR/package/deploy.sh" --export --export-stdout "$CONFIG" > "$TEMP_DIR/markers.txt" 2> "$TEMP_DIR/export.log" || fail 'Marker export failed.'
[[ $(wc -l < "$TEMP_DIR/markers.txt") -eq 2 ]] || fail 'Export protocol must contain exactly two lines.'
router_count=0; test_count=0
while IFS= read -r line; do
    [[ $line =~ ^__WG_PROFILE__wg-(router|test)\.conf:[A-Za-z0-9+/]+=*$ ]] || fail 'Unexpected stdout or malformed profile marker.'
    name=${line#__WG_PROFILE__}; name=${name%%:*}; encoded=${line#*:}
    case "$name" in wg-router.conf) router_count=$((router_count+1)) ;; wg-test.conf) test_count=$((test_count+1)) ;; *) fail 'Unknown profile name.' ;; esac
    printf '%s' "$encoded" | base64 --decode > "$TEMP_DIR/exported/$name" || fail 'Profile marker is not valid base64.'
    cmp -s "$TEMP_DIR/exported/$name" "$BASE/clients/$name" || fail 'Decoded profile differs from its persistent source.'
done < "$TEMP_DIR/markers.txt"
[[ $router_count = 1 && $test_count = 1 ]] || fail 'Export did not deliver one profile for each identity.'
pass 'Stdout contains only the two exact, decodable Windows profile markers.'

ip netns add "$NS"; OWN_NAMESPACE=1
ip link add dev "$HOST_LINK" type veth peer name "$CLIENT_LINK"
ip link set dev "$CLIENT_LINK" netns "$NS"
ip address add 192.0.2.1/30 dev "$HOST_LINK"
ip link set dev "$HOST_LINK" up
ip -n "$NS" link set dev lo up
ip -n "$NS" address add 192.0.2.2/30 dev "$CLIENT_LINK"
ip -n "$NS" link set dev "$CLIENT_LINK" up

# These CI-only rules authorize the isolated veth and one tunnel ping to the VM.
# They do not weaken the installer rules or expose an additional public port.
iptables -w 5 -I INPUT 1 -i "$HOST_LINK" -p udp --dport "$PORT" \
    -m comment --comment office-wg-ci-outer -j ACCEPT; ALLOW_OUTER=1
iptables -w 5 -I INPUT 1 -i wg-office -s 10.66.66.4/32 -p icmp --icmp-type echo-request \
    -m comment --comment office-wg-ci-inner -j ACCEPT; ALLOW_INNER=1

if [[ $SERVER_RUNTIME = kernel ]]; then
    ip -n "$NS" link add dev "$CLIENT_WG" type wireguard || fail 'Kernel WireGuard client cannot be created.'
else
    [[ -n $GO_BIN && -x $GO_BIN ]] || fail 'Userspace runtime path is unavailable.'
    ip netns exec "$NS" env LOG_LEVEL=error "$GO_BIN" -f "$CLIENT_WG" > "$TEMP_DIR/client-runtime.log" 2>&1 &
    GO_PID=$!
    ready=0
    for _ in {1..100}; do
        if ip -n "$NS" link show dev "$CLIENT_WG" >/dev/null 2>&1; then ready=1; break; fi
        kill -0 "$GO_PID" >/dev/null 2>&1 || fail 'Userspace WireGuard client exited before startup.'
        sleep 0.2
    done
    ((ready)) || fail 'Userspace WireGuard client did not become ready.'
fi
cat > "$TEMP_DIR/client-wireguard.conf" <<CLIENT_CONFIG
[Interface]
PrivateKey = $(cat "$TEMP_DIR/client.key")

[Peer]
PublicKey = $server_public
AllowedIPs = 10.66.66.1/32
Endpoint = 192.0.2.1:$PORT
PersistentKeepalive = 1
CLIENT_CONFIG
ip netns exec "$NS" "$WG_BIN" setconf "$CLIENT_WG" "$TEMP_DIR/client-wireguard.conf"
ip -n "$NS" address add 10.66.66.4/32 dev "$CLIENT_WG"
ip -n "$NS" link set dev "$CLIENT_WG" mtu 1420 up
ip -n "$NS" route add 10.66.66.1/32 dev "$CLIENT_WG"

connected=0
for _ in {1..12}; do
    if ip netns exec "$NS" ping -n -q -c 1 -W 1 10.66.66.1 >/dev/null 2>&1; then connected=1; break; fi
    sleep 0.5
done
((connected)) || fail 'Real isolated client could not ping the server through WireGuard.'
"$WG_BIN" show wg-office latest-handshakes | awk -v p="$client_public" '$1==p && $2>0 {found=1} END{exit !found}' || fail 'Server did not record a genuine client handshake.'
ip netns exec "$NS" "$WG_BIN" show "$CLIENT_WG" latest-handshakes | awk -v p="$server_public" '$1==p && $2>0 {found=1} END{exit !found}' || fail 'Client did not record a genuine server handshake.'
"$WG_BIN" show wg-office transfer | awk -v p="$client_public" '$1==p && $2>0 && $3>0 {found=1} END{exit !found}' || fail 'Server did not exchange tunnel traffic in both directions.'
pass "Real $SERVER_RUNTIME WireGuard client completes a handshake and exchanges an ICMP packet through the tunnel."
printf 'Integration passed on a disposable GitHub-hosted VM. No user VPS was contacted and no throughput claim was made.\n'
