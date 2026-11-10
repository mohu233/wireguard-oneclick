#!/usr/bin/env bash
# Sourced only by deploy.sh. All downloads are official HTTPS origins.
# WireGuard archive digests below were locked from the official HTTPS snapshots;
# Go digests are the values published by go.dev/dl/?mode=json.

runtime_package_install() {
    local id='' version='' key value
    if [[ -r /etc/os-release ]]; then
        while IFS='=' read -r key value; do
            value=${value#\"}; value=${value%\"}
            case "$key" in ID) id=$value ;; VERSION_ID) version=$value ;; esac
        done < /etc/os-release
    fi
    if [[ "$id" = centos && "$version" = 7* ]]; then
        [[ $(uname -m) = x86_64 ]] || die 'CentOS 7 archive support is x86_64 only.'
        [[ -f /etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7 ]] || die 'CentOS signing key is missing.'
        mkdir -p "$BASE/build/yum.repos.d"
        cat > "$BASE/build/yum.repos.d/centos-vault.repo" <<'REPO'
[office-wg-vault-base]
name=CentOS 7.9 official archive
baseurl=https://vault.centos.org/7.9.2009/os/x86_64/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
[office-wg-vault-updates]
name=CentOS 7.9 official archive updates
baseurl=https://vault.centos.org/7.9.2009/updates/x86_64/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
REPO
        log 'CentOS 7 compatibility: installing dependencies from its official archive.'
        yum --setopt="reposdir=$BASE/build/yum.repos.d" --disablerepo='*' \
            --enablerepo='office-wg-vault-*' -y install \
            gcc make curl ca-certificates tar xz iproute iptables kmod procps-ng >&2
    elif command -v apt-get >/dev/null 2>&1; then
        log 'Installing distribution packages (no system upgrade).'
        apt-get -q update >&2
        DEBIAN_FRONTEND=noninteractive apt-get -q -y --no-install-recommends install \
            wireguard-tools iproute2 iptables kmod curl ca-certificates tar xz-utils gcc make procps >&2
    elif command -v dnf >/dev/null 2>&1; then
        dnf -y install wireguard-tools iproute iptables kmod curl ca-certificates tar xz gcc make procps-ng >&2
    elif command -v yum >/dev/null 2>&1; then
        yum -y install wireguard-tools iproute iptables kmod curl ca-certificates tar xz gcc make procps-ng >&2
    else
        die 'Unsupported package manager. Install wg, ip, iptables, curl, tar, xz, gcc and make first.'
    fi
}

runtime_download_checked() {
    local url=$1 digest=$2 destination=$3
    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
        --connect-timeout 15 --max-time 600 --retry 2 "$url" -o "$destination"
    printf '%s  %s\n' "$digest" "$destination" | sha256sum --check --status || \
        die 'Downloaded archive checksum mismatch; nothing from it was executed.'
    printf '%s  %s\n' "$digest" "${destination##*/}" >> "$BASE/build/SHA256SUMS.lock"
    printf '%s\n' "$url" >> "$BASE/build/SOURCES.txt"
}

runtime_build_tools() {
    local version=1.0.20260223 archive="$BASE/build/wireguard-tools.tar.xz"
    runtime_download_checked \
        "https://git.zx2c4.com/wireguard-tools/snapshot/wireguard-tools-$version.tar.xz" \
        af459827b80bfd31b83b08077f4b5843acb7d18ad9a33a2ef532d3090f291fbf "$archive"
    mkdir -p "$BASE/build/wireguard-tools"
    tar -xJf "$archive" --strip-components=1 -C "$BASE/build/wireguard-tools"
    make -C "$BASE/build/wireguard-tools/src" -j2 >&2
    install -m 0755 "$BASE/build/wireguard-tools/src/wg" "$BASE/bin/wg"
    WG_BIN="$BASE/bin/wg"
}

runtime_build_go() {
    local arch digest archive version=0.0.20250522
    case $(uname -m) in
        x86_64) arch=amd64; digest=65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40 ;;
        aarch64|arm64) arch=arm64; digest=a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49 ;;
        *) die 'Userspace build supports Linux amd64 and arm64 only.' ;;
    esac
    archive="$BASE/build/go.tar.gz"
    runtime_download_checked "https://go.dev/dl/go1.27.3.linux-$arch.tar.gz" "$digest" "$archive"
    tar -xzf "$archive" -C "$BASE/build"
    archive="$BASE/build/wireguard-go.tar.xz"
    runtime_download_checked \
        "https://git.zx2c4.com/wireguard-go/snapshot/wireguard-go-$version.tar.xz" \
        c7eeffb13e5eb43b93e54a21d78dd71414771af9e07112da5275690493695c9c "$archive"
    mkdir -p "$BASE/build/wireguard-go"
    tar -xJf "$archive" --strip-components=1 -C "$BASE/build/wireguard-go"
    # Keep module verification enabled; never disable sumdb or use unofficial mirrors.
    (cd "$BASE/build/wireguard-go" || exit 1
     GOTOOLCHAIN=local CGO_ENABLED=0 GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org \
        "$BASE/build/go/bin/go" build -trimpath -ldflags='-s -w' -o "$BASE/bin/wireguard-go" .) >&2
    GO_BIN="$BASE/bin/wireguard-go"
}

install_runtime() {
    local need_packages=0 command probe="owgp$$"
    mkdir -p "$BASE/bin" "$BASE/build"
    for command in ip iptables ss curl tar xz sha256sum make gcc sysctl; do
        command -v "$command" >/dev/null 2>&1 || need_packages=1
    done
    command -v wg >/dev/null 2>&1 || need_packages=1
    if ((need_packages)); then runtime_package_install; fi
    for command in ip iptables ss curl tar xz sha256sum make gcc sysctl; do
        command -v "$command" >/dev/null 2>&1 || die "Required dependency is unavailable: $command"
    done
    if command -v wg >/dev/null 2>&1; then WG_BIN=$(command -v wg); else runtime_build_tools; fi
    "$WG_BIN" --version >&2
    # A temporary, unaddressed interface tests the running kernel, not its version string.
    if ip link add dev "$probe" type wireguard >/dev/null 2>&1; then
        ip link delete dev "$probe"
        RUNTIME=kernel; GO_BIN=''
        log 'Using kernel WireGuard.'
    else
        [[ -c /dev/net/tun ]] || die 'Kernel WireGuard is unavailable and /dev/net/tun is missing.'
        RUNTIME=userspace
        if command -v wireguard-go >/dev/null 2>&1; then GO_BIN=$(command -v wireguard-go); else runtime_build_go; fi
        "$GO_BIN" --version >&2
        log 'Using official WireGuard Go compatibility runtime.'
    fi
    # Return these values to the calling deploy.sh, which renders the service unit.
    export RUNTIME WG_BIN GO_BIN
}
