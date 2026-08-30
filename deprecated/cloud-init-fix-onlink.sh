#!/bin/bash
# Fix cloud-init not rendering an onlink gateway correctly

set -eE
os_dir=$1

# This script is also called under alpine live
# Guard against systemctl/netplan errors when running under alpine live
systemctl() {
    if systemd-detect-virt --chroot; then
        return
    fi
    command systemctl "$@"
}

netplan() {
    if systemd-detect-virt --chroot; then
        return
    fi
    command netplan "$@"
}

insert_into_file() {
    file=$1
    location=$2
    regex_to_find=$3

    if [ "$location" = head ]; then
        bak=$(mktemp)
        cp "$file" "$bak"
        cat - "$bak" >"$file"
    else
        line_num=$(grep -E -n "$regex_to_find" "$file" | cut -d: -f1)

        found_count=$(echo "$line_num" | wc -l)
        if [ ! "$found_count" -eq 1 ]; then
            return 1
        fi

        case "$location" in
        before) line_num=$((line_num - 1)) ;;
        after) ;;
        *) return 1 ;;
        esac

        sed -i "${line_num}r /dev/stdin" "$file"
    fi
}

fix_netplan_conf() {
    # before
    # gateway4: 1.1.1.1
    # gateway6: ::1

    # after
    # routes:
    #   - to: 0.0.0.0/0
    #     via: 1.1.1.1
    #     on-link: true
    # routes:
    #   - to: ::/0
    #     via: ::1
    #     on-link: true
    conf=$os_dir/etc/netplan/50-cloud-init.yaml
    if ! [ -f "$conf" ]; then
        return
    fi

    # check whether the bug is already fixed
    if grep -q 'on-link:' "$conf"; then
        return
    fi

    # get the gateway
    gateways=$(grep 'gateway[4|6]:' "$conf" | awk '{print $2}')
    if [ -z "$gateways" ]; then
        return
    fi

    # get the indentation
    spaces=$(grep 'gateway[4|6]:' "$conf" | head -1 | grep -o '^[[:space:]]*')

    {
        # gateway header
        cat <<EOF
${spaces}routes:
EOF
        # gateway entry
        for gateway in $gateways; do
            # netplan on debian 11 does not support "to: default"
            case $gateway in
            *.*) to='0.0.0.0/0' ;;
            *:*) to='::/0' ;;
            esac

            cat <<EOF
${spaces}  - to: $to
${spaces}    via: $gateway
${spaces}    on-link: true
EOF
        done
    } | insert_into_file "$conf" before 'match:'

    # remove the original entry
    sed -i '/gateway[4|6]:/d' "$conf"

    # re-apply the configuration
    if command -v netplan && {
        systemctl -q is-enabled systemd-networkd || systemctl -q is-enabled NetworkManager
    }; then
        netplan apply
    fi
}

fix_networkd_conf() {
    # before (gentoo)
    # [Route]
    # Gateway=1.1.1.1
    # Gateway=2602::1

    # before (arch)
    # [Route]
    # Gateway=1.1.1.1
    #
    # [Route]
    # Gateway=2602::1

    # after
    # [Route]
    # Gateway=1.1.1.1
    # GatewayOnLink=yes
    #
    # [Route]
    # Gateway=2602::1
    # GatewayOnLink=yes

    if ! confs=$(ls "$os_dir"/etc/systemd/network/10-cloud-init-*.network 2>/dev/null); then
        return
    fi

    for conf in $confs; do
        # check whether the bug is already fixed
        if grep -q '^GatewayOnLink=' "$conf"; then
            return
        fi

        # get the gateway
        gateways=$(grep '^Gateway=' "$conf" | cut -d= -f2)
        if [ -z "$gateways" ]; then
            return
        fi

        # remove the original entry
        sed -i '/^\[Route\]/d; /^Gateway=/d; /^GatewayOnLink=/d' "$conf"

        # create the new entry
        for gateway in $gateways; do
            echo "
[Route]
Gateway=$gateway
GatewayOnLink=yes
"
        done >>"$conf"
    done

    # re-apply the configuration
    # networkctl reload has no effect
    if systemctl -q is-enabled systemd-networkd; then
        systemctl restart systemd-networkd
    fi
}

# ubuntu 18.04 ships cloud-init 23.1.2, so nothing to do

# the debian 10/11 cloud images used ifupdown + resolvconf; this switches them to netplan + networkd/resolved
# debian 12 cloud image: netplan + networkd/resolved
# fixed in 23.1.1
fix_netplan_conf

# arch: networkd/resolved
# gentoo: networkd/resolved
# fixed in 24.2
# only the cloud images need this
# a normal install uses alpine's cloud-init, which is new enough
fix_networkd_conf
