#!/usr/bin/env bash
# Offline tests only. Never connects to a server or starts a tunnel.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_rejection() {
    local expected=$1 logfile=$2
    shift 2
    if "$@" >"$logfile" 2>&1; then
        fail 'command unexpectedly succeeded'
    fi
    if ! grep -Fq -- "$expected" "$logfile"; then
        cat "$logfile" >&2
        fail "command failed for the wrong reason; expected: $expected"
    fi
}

conf_value() {
    local name=$1 file=$2
    awk -v wanted="$name" '
        /^[[:space:]]*[#;]/ { next }
        {
            key=$0
            sub(/=.*/, "", key)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key == wanted) {
                value=$0
                sub(/^[^=]*=[[:space:]]*/, "", value)
                sub(/[[:space:]]+$/, "", value)
                print value
                exit
            }
        }
    ' "$file"
}

while IFS= read -r -d '' script; do
    bash -n "$script"
done < <(find "$ROOT" -type f -name '*.sh' -not -path '*/.git/*' -print0)
pass 'Bash syntax'

# On Ubuntu /bin/sh is dash: this also exercises the POSIX-to-Bash entry point.
demo_dir="$WORK/output with spaces"
if ! sh "$ROOT/deploy.sh" --render-demo "$demo_dir" >"$WORK/demo.log" 2>&1; then
    cat "$WORK/demo.log" >&2
    fail 'sh deploy.sh --render-demo failed'
fi

for name in wg-router wg-test; do
    file="$demo_dir/$name.conf"
    [[ -s $file ]] || fail "missing demo $name.conf"
    [[ ${#name} -le 15 && $name =~ ^[a-zA-Z0-9_=+.-]+$ ]] || fail 'invalid WireGuard tunnel name'
    grep -q '^\[Interface\]' "$file" || fail "missing Interface in $name"
    grep -q '^\[Peer\]' "$file" || fail "missing Peer in $name"
    [[ -n $(conf_value PrivateKey "$file") ]] || fail "missing private-key placeholder in $name"
    [[ -n $(conf_value PublicKey "$file") ]] || fail "missing public-key placeholder in $name"
    [[ -n $(conf_value Endpoint "$file") ]] || fail "missing endpoint in $name"
    [[ $(conf_value PrivateKey "$file") =~ ^\<DEMO_[A-Z_]+_NOT_USABLE\>$ ]] || fail "demo unexpectedly contains a real-looking key in $name"
done
count=$(find "$demo_dir" -maxdepth 1 -type f -name '*.conf' | wc -l)
[[ $count -eq 2 ]] || fail "expected exactly two client configurations, got $count"
router_address=$(conf_value Address "$demo_dir/wg-router.conf")
test_address=$(conf_value Address "$demo_dir/wg-test.conf")
[[ -n $router_address && -n $test_address && $router_address != "$test_address" ]] || fail 'client addresses must be independent'
router_key=$(conf_value PrivateKey "$demo_dir/wg-router.conf")
test_key=$(conf_value PrivateKey "$demo_dir/wg-test.conf")
[[ $router_key != "$test_key" ]] || fail 'client key placeholders must be independent'
pass 'sh entry point renders two short-name configurations with independent clients'

before=$(cksum "$demo_dir/wg-router.conf" "$demo_dir/wg-test.conf")
expect_rejection 'Demo refuses to overwrite existing profiles.' "$WORK/overwrite.log" \
    sh "$ROOT/deploy.sh" --render-demo "$demo_dir"
[[ $(cksum "$demo_dir/wg-router.conf" "$demo_dir/wg-test.conf") = "$before" ]] || fail 'existing demo profiles were changed'
pass 'existing output files are not overwritten'

cat >"$WORK/valid.env" <<'CONFIG'
ENDPOINT=203.0.113.10
WG_PORT=51820
VPN_SUBNET=10.66.66.0/24
DNS=1.1.1.1,9.9.9.9
MTU=1420
WAN_INTERFACE=auto
CONFIG

# Shell metacharacters in a recognized, ignored SSH setting must remain data.
# This case must SUCCEED, so rejecting the whole file cannot mask accidental eval.
cp "$WORK/valid.env" "$WORK/inert.env"
printf 'SSH_HOST=%s(touch "%s")\n' '$' "$WORK/command-substitution-ran" >>"$WORK/inert.env"
printf 'SSH_IDENTITY_FILE=%stouch "%s"%s\n' '`' "$WORK/backtick-ran" '`' >>"$WORK/inert.env"
if ! sh "$ROOT/deploy.sh" --render-demo "$WORK/inert demo" "$WORK/inert.env" >"$WORK/inert.log" 2>&1; then
    cat "$WORK/inert.log" >&2
    fail 'literal shell syntax in ignored SSH settings was not treated as data'
fi
[[ ! -e "$WORK/command-substitution-ran" && ! -e "$WORK/backtick-ran" ]] || fail 'configuration executed shell code'

printf 'ENDPOINT=%s(touch "%s")\n' '$' "$WORK/endpoint-ran" >"$WORK/attack.env"
expect_rejection 'ENDPOINT must be a plain hostname' "$WORK/attack.log" \
    sh "$ROOT/deploy.sh" --render-demo "$WORK/attack demo" "$WORK/attack.env"
[[ ! -e "$WORK/endpoint-ran" ]] || fail 'ENDPOINT executed shell code'
cp "$WORK/valid.env" "$WORK/unknown.env"
printf 'ARBITRARY_COMMAND=%s(touch "%s")\n' '$' "$WORK/unknown-ran" >>"$WORK/unknown.env"
expect_rejection 'Unknown setting' "$WORK/unknown.log" \
    sh "$ROOT/deploy.sh" --render-demo "$WORK/unknown demo" "$WORK/unknown.env"
[[ ! -e "$WORK/unknown-ran" ]] || fail 'unknown setting executed shell code'
pass 'KEY=VALUE parsing does not execute command substitutions or backticks'

expect_rejection 'Demo cannot export real profile markers.' "$WORK/demo-markers.log" \
    sh "$ROOT/deploy.sh" --render-demo "$WORK/no-export" --export-stdout "$WORK/valid.env"
! grep -q '^__WG_PROFILE__' "$WORK/demo-markers.log" || fail 'demo emitted deployment export markers'
pass 'demo is explicitly separated from real-profile export'

if [[ $(uname -s) = Linux ]] && ((EUID != 0)); then
    expect_rejection 'Run as root on the target Linux VPS.' "$WORK/nonroot.log" \
        bash "$ROOT/deploy.sh" --check "$WORK/valid.env"
    pass 'non-root deployment precheck is rejected explicitly'
else
    printf 'SKIP: non-root rejection (requires a non-root Linux process)\n'
fi

# The following fixture changes only private mount-namespace tmpfs mounts.
# Its BASH_ENV mocks read-only system queries and rejects every unexpected call.
# No root/filesystem override is added to the production installer.
cat >"$WORK/mock-queries.bash" <<'MOCK'
unexpected() { printf 'UNEXPECTED MUTATING/UNKNOWN CALL: %s\n' "$*" >&2; return 99; }
uname() { [[ $* = -s ]] && printf 'Linux\n' || unexpected "uname $*"; }
ip() {
    case "$*" in
        '-4 route show default')
            [[ $MOCK_SCENARIO = no-route ]] || printf 'default via 198.51.100.1 dev fixture0\n' ;;
        'link show dev fixture0') return 0 ;;
        'link show dev wg-office') return 1 ;;
        '-4 route show scope link') printf '198.51.100.0/24 dev fixture0\n' ;;
        *) unexpected "ip $*" ;;
    esac
}
systemctl() {
    case "$*" in
        'is-active --quiet firewalld'|'cat office-wireguard.service'|'cat office-wg.service') return 1 ;;
        *) unexpected "systemctl $*" ;;
    esac
}
ufw() { [[ $* = status ]] && printf 'Status: inactive\n' || unexpected "ufw $*"; }
nft() { [[ $* = 'list tables' ]] || unexpected "nft $*"; }
ss() { [[ $* = '-H -lun' ]] || unexpected "ss $*"; }
iptables() {
    case "$*" in
        '-w 5 -t filter -S OWG_INPUT'|'-w 5 -t filter -S OWG_FWD'|'-w 5 -t nat -S OWG_NAT'|'-w 5 -t mangle -S OWG_MSS') return 1 ;;
        *) unexpected "iptables $*" ;;
    esac
}
apt-get() { unexpected "apt-get $*"; }
dnf() { unexpected "dnf $*"; }
yum() { unexpected "yum $*"; }
sysctl() { unexpected "sysctl $*"; }
flock() { unexpected "flock $*"; }
MOCK
cat >"$WORK/namespace-fixture.bash" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
root=$1
work=$2
scenario=$3
mount -t tmpfs -o size=4m tmpfs /opt
mount -t tmpfs -o size=4m tmpfs /run
mkdir -p /run/systemd/system
if [[ $scenario = existing ]]; then
    mkdir /opt/office-wg
    printf 'existing user-owned state\n' >/opt/office-wg/sentinel
fi
set +e
env BASH_ENV="$work/mock-queries.bash" MOCK_SCENARIO="$scenario" \
    bash "$root/deploy.sh" --check "$work/valid.env" >"$work/$scenario.log" 2>&1
status=$?
set -e
if [[ $scenario = clean ]]; then
    [[ $status = 0 ]] || { cat "$work/$scenario.log"; exit 1; }
    grep -Fq 'Check mode made no changes.' "$work/$scenario.log"
    [[ ! -e /opt/office-wg && ! -e /run/lock/office-wg-deploy.lock ]]
else
    [[ $status != 0 ]] || exit 1
    case "$scenario" in
        no-route) grep -Fq 'No IPv4 default route.' "$work/$scenario.log" ;;
        existing)
            grep -Fq 'already exists without valid metadata' "$work/$scenario.log"
            [[ $(cat /opt/office-wg/sentinel) = 'existing user-owned state' ]]
            [[ $(find /opt/office-wg -mindepth 1 | wc -l) -eq 1 ]] ;;
        *) exit 1 ;;
    esac
fi
! grep -q 'UNEXPECTED MUTATING/UNKNOWN CALL' "$work/$scenario.log"
FIXTURE

if [[ $(uname -s) = Linux ]] && command -v unshare >/dev/null 2>&1 && \
    command -v sudo >/dev/null 2>&1 && sudo -n unshare --mount --propagation private true 2>/dev/null; then
    for scenario in no-route existing clean; do
        if ! sudo -n unshare --mount --propagation private \
            bash "$WORK/namespace-fixture.bash" "$ROOT" "$WORK" "$scenario"; then
            [[ ! -f "$WORK/$scenario.log" ]] || cat "$WORK/$scenario.log" >&2
            fail "isolated $scenario fixture failed"
        fi
    done
    pass 'isolated precheck rejects absent routes and existing deployments, and clean check makes no changes'
else
    if [[ ${CI:-} = true && $(uname -s) = Linux ]]; then
        fail 'Linux CI must provide sudo -n and mount namespaces for isolated precheck coverage'
    fi
    printf 'SKIP: Linux mount-namespace prechecks (requires Linux, sudo -n and unshare)\n'
fi

printf 'Offline server tests passed. Demo files do not verify a real WireGuard handshake.\n'
