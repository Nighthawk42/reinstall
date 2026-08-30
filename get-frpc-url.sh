#!/bin/ash
# shellcheck shell=dash
# Shared by trans.sh and debian.cfg

# debian 9 does not support set -E
set -e

is_ipv6_only() {
    ! grep -q 1 /dev/netconf/*/ipv4_has_internet
}

get_frpc_url() {
    # Pass either windows or linux
    local os_type=$1
    local nt_ver=$2
    local os_bit=${3:-64}

    get_old_version() {
        # This script cannot install 32-bit Linux, so ignore that case
        if [ "$os_type" = windows ]; then
            # 0.52.0 is the first version supporting toml

            # 0.29.0 is the last version supporting vista
            # 0.51.3 is the last version supporting 32-bit
            # 0.54.0 is the last version supporting win7
            case "$os_bit" in
            32)
                case "$nt_ver" in
                6.0) echo 0.29.0 ;; # vista
                *) echo 0.51.3 ;;   # win7+
                esac
                ;;
            64)
                case "$nt_ver" in
                6.0) echo 0.29.0 ;; # vista
                6.1) echo 0.54.0 ;; # win7
                # The current v0.66.0 still runs on win8
                esac
                ;;
            esac
        fi
    }

    is_need_old_version() {
        [ -n "$(get_old_version)" ]
    }

    version=$(
        if is_need_old_version; then
            get_old_version
        else
            # the debian 11 initrd has no xargs or awk
            # the debian 12 initrd has no xargs
            # github has no IPv6
            # https://api.github.com/repos/fatedier/frp/releases/latest is rate limited

            # root@localhost:~# wget --spider -S https://github.com/fatedier/frp/releases/latest 2>&1 | grep Location:
            #   Location: https://github.com/fatedier/frp/releases/tag/v0.62.0
                # Location: https://github.com/fatedier/frp/releases/tag/v0.62.0 [following]  # upstream wget prints this extra line

            wget --spider -S https://github.com/fatedier/frp/releases/latest 2>&1 |
                grep -m1 '^  Location:' | sed 's,.*/tag/v,,'
        fi
    )

    if [ -z "$version" ]; then
        echo 'cannot find version' >&2
        return 1
    fi

    suffix=$(
        case "$os_type" in
        linux) echo tar.gz ;;
        windows) echo zip ;;
        esac
    )

    mirror=$(
        # github.com has no IPv6; the only IPv6-capable frp release
        # mirrors were China-only, so IPv6-only hosts are unsupported
        if is_ipv6_only; then
            echo 'NOT_SUPPORT' >&2
            return 1
        else
            echo https://github.com/fatedier/frp/releases/download
        fi
    )

    arch=$(
        case "$(uname -m)" in
        x86_64)
            case "$os_bit" in
            32) echo 386 ;;
            64) echo amd64 ;;
            esac
            ;;
        aarch64) echo arm64 ;;
        esac
    )

    filename=frp_${version}_${os_type}_${arch}.$suffix

    echo "${mirror}/v${version}/${filename}"
}

get_frpc_url "$@"
