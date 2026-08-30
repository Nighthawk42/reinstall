#!/usr/bin/env bash
# shellcheck shell=dash
# shellcheck disable=SC3001,SC3010
# alpine uses busybox ash

set -eE

# This script runs on the first boot into the new system
# It rewrites the NIC name (eth0) in the config generated during the trans stage to the real name. Also covers:
# 1. alpine needs it, because the installed kernel may have drivers the netboot kernel lacks
# 2. on dmit debian the NIC name differs between the normal (install-time) kernel and the cloud kernel
#    https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=928923

# on openeuler we must wait for udev to rename the NIC from eth0 to enp3s0
# enp3s0 only shows up a second after this script starts
# systemd-analyze plot >a.svg shows sys-subsystem-net-devices-enp3s0.device also appears after NetworkManager

# sometimes the NIC name changes back and forth a few times
# so wait until it settles

# not sure whether this helps
if false; then
    if command -v udevadm >/dev/null; then
        # udevadm trigger
        udevadm settle || true
    elif command -v mdev >/dev/null; then
        mdev -sf || true
    fi
    sleep 1
fi

has_eth=false  # whether a NIC was found
check_count=0  # total checks performed
stable_count=0 # consecutive checks with an unchanged name
old_state=
while true; do
    check_count=$((check_count + 1))

    new_state=$(ip -o link | awk '$2 != "lo:"')
    if [ -n "$new_state" ]; then
        has_eth=true
    fi

    if $has_eth && [ "$old_state" = "$new_state" ]; then
        stable_count=$((stable_count + 1))
    else
        stable_count=0
    fi

    old_state=$new_state

    # leave the loop after 10 stable seconds
    if $has_eth && [ "$stable_count" -ge 10 ]; then
        break
    fi

    # give up if no NIC appears within 60 seconds
    if ! $has_eth && [ "$check_count" -ge 60 ]; then
        exit 1
    fi

    sleep 1
done

to_lower() {
    tr '[:upper:]' '[:lower:]'
}

get_ethx_by_mac() {
    mac=$(echo "$1" | to_lower)

    flag=$2
    if [ -z "$flag" ]; then
        flag=master
    fi

    if true; then
        if [ "$flag" = master ]; then
            # master
            # filter out azure VFs (they have a master ethx)
            ip -o link | grep -i "$mac" | grep -v master | awk '{print $2}' | cut -d: -f1 | grep .
        else
            # slave
            # has a master ethx
            ip -o link | grep -i "$mac" | grep -w master | awk '{print $2}' | cut -d: -f1 | grep .
        fi
    else
        for i in $(cd /sys/class/net && echo *); do
            if [ "$(cat "/sys/class/net/$i/address")" = "$mac" ]; then
                if [ $(($(cat "/sys/class/net/$i/flags") & 0x800)) -ne 0 ]; then
                    fact_flag=slave
                else
                    fact_flag=master
                fi
                if [ "$flag" = "$fact_flag" ]; then
                    echo "$i"
                    return
                fi
            fi
        done
        return 1
    fi
}

fix_rh_sysconfig() {
    for file in /etc/sysconfig/network-scripts/ifcfg-eth*; do
        # this runs once even when there is no ifcfg-eth*, so check the file exists
        [ -f "$file" ] || continue
        mac=$(grep ^HWADDR= "$file" | cut -d= -f2 | grep .) || continue
        ethx=$(get_ethx_by_mac "$mac") || continue

        proper_file=/etc/sysconfig/network-scripts/ifcfg-$ethx
        if [ "$file" != "$proper_file" ]; then
            # rewrite the file contents
            sed -i "s/^DEVICE=.*/DEVICE=$ethx/" "$file"

            # do not rename in place: it could overwrite an existing file
            mv "$file" "$proper_file.tmp"
        fi
    done

    # rename the file
    for tmp_file in /etc/sysconfig/network-scripts/ifcfg-e*.tmp; do
        if [ -f "$tmp_file" ]; then
            mv "$tmp_file" "${tmp_file%.tmp}"
        fi
    done
}

fix_suse_sysconfig() {
    for file in /etc/sysconfig/network/ifcfg-eth*; do
        [ -f "$file" ] || continue

        # may be wrapped in quotes
        mac=$(grep ^LLADDR= "$file" | cut -d= -f2 | sed "s/'//g" | grep .) || continue
        ethx=$(get_ethx_by_mac "$mac") || continue

        old_ethx=${file##*-}
        if ! [ "$old_ethx" = "$ethx" ]; then
            # do not rename in place: it could overwrite an existing file
            for type in ifcfg ifroute; do
                old_file=/etc/sysconfig/network/$type-$old_ethx
                new_file=/etc/sysconfig/network/$type-$ethx.tmp
                # do not abort the script when there is no ifroute-eth*
                if [ -f "$old_file" ]; then
                    mv "$old_file" "$new_file"
                fi
            done
        fi
    done

    # once the loop above finishes, promote the tmp files to the real ones
    for tmp_file in \
        /etc/sysconfig/network/ifcfg-e*.tmp \
        /etc/sysconfig/network/ifroute-e*.tmp; do
        if [ -f "$tmp_file" ]; then
            mv "$tmp_file" "${tmp_file%.tmp}"
        fi
    done
}

fix_network_manager() {
    for file in /etc/NetworkManager/system-connections/cloud-init-eth*.nmconnection; do
        [ -f "$file" ] || continue
        mac=$(grep ^mac-address= "$file" | cut -d= -f2 | grep .) || continue
        ethx=$(get_ethx_by_mac "$mac") || continue

        proper_file=/etc/NetworkManager/system-connections/$ethx.nmconnection

        # rewrite the file contents
        sed -i "s/^id=.*/id=$ethx/" "$file"

        # rename the file
        mv "$file" "$proper_file"

        # NetworkManager does not ignore Azure slave NICs by itself; set it manually
        # the method in the azure docs is azure-specific and not general enough
        # https://learn.microsoft.com/zh-cn/azure/virtual-network/accelerated-networking-overview

        # so use Red Hat's approach instead
        # https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/8/html/configuring_and_managing_networking/configuring-networkmanager-to-ignore-certain-devices_configuring-and-managing-networking
        if slave_ethx=$(get_ethx_by_mac "$mac" slave); then
            cat >"/etc/NetworkManager/conf.d/99-$slave_ethx-unmanaged.conf" <<EOF
[device-$slave_ethx-unmanaged]
match-device=interface-name:$slave_ethx
managed=0
EOF
        fi

        # unmanaged-devices would also work, but the official docs advise against it
        # https://networkmanager.pages.freedesktop.org/NetworkManager/NetworkManager/NetworkManager.conf.html#:~:text=may%20be%20a-,better%20choice,-.
    done
}

# an IPv6 onlink route on debian 9 needs post-up

# auto lo
# iface lo inet loopback

# # mac 11:22:33:44:55:66    # this line is used to match the NIC
# auto eth0
# iface eth0 inet static
#     address 1.1.1.1/25
#     gateway 1.1.1.1
#     dns-nameservers 1.1.1.1
#     dns-nameservers 8.8.8.8
# iface eth0 inet6 static
#     address 2602:1:0:80::100/64
#     gateway 2602:1:0:80::1
#     post-up ip route add 2602:1:0:80::1 dev eth0
#     post-up ip route add default via 2602:1:0:80::1 dev eth0
#     dns-nameserver 2606:4700:4700::1111
#     dns-nameserver 2001:4860:4860::8888

fix_ifupdown() {
    file=/etc/network/interfaces
    tmp_file=$file.tmp

    rm -f "$tmp_file"

    if [ -f "$file" ]; then
        while IFS= read -r line; do
            del_this_line=false
            if [[ "$line" = "# mac "* ]]; then
                ethx=
                if mac=$(echo "$line" | awk '{print $NF}'); then
                    ethx=$(get_ethx_by_mac "$mac") || true
                fi
                del_this_line=true
            elif [[ "$line" = "iface e"* ]] ||
                [[ "$line" = "auto e"* ]] ||
                [[ "$line" = "allow-hotplug e"* ]]; then
                if [ -n "$ethx" ]; then
                    line=$(echo "$line" | awk "{\$2=\"$ethx\"; print \$0}")
                fi
            elif [[ "$line" = *" dev e"* ]]; then
                if [ -n "$ethx" ]; then
                    # awk strips the leading spaces
                    line=$(echo "$line" | sed -E "s/[^ ]*$/$ethx/")
                fi
            fi
            if ! $del_this_line; then
                echo "$line" >>"$tmp_file"
            fi
        done <"$file"

        mv "$tmp_file" "$file"
    fi
}

fix_netplan() {
    file=/etc/netplan/50-cloud-init.yaml
    tmp_file=$file.tmp

    rm -f "$tmp_file"

    if [ -f "$file" ]; then
        while IFS= read -r line; do
            if echo "$line" | grep -Eq '^[[:space:]]+macaddress:'; then
                # obtain the correct NIC name
                mac=$(echo "$line" | awk '{print $NF}' | sed 's/"//g')
                ethx=$(get_ethx_by_mac "$mac") || true
            elif echo "$line" | grep -Eq '^[[:space:]]+eth[0-9]+:'; then
                # replace it with the correct NIC name
                if [ -n "$ethx" ]; then
                    line=$(echo "$line" | sed -E "s/[^[:space:]]+/$ethx:/")
                fi
            fi
            echo "$line" >>"$tmp_file"

            # remove set-name, although the trans stage already did this
            # because netplan-generator renames the NIC during the systemd generator stage,
            # which runs earlier than both this script and systemd-networkd

            # reverse order
        done < <(grep -Ev "^[[:space:]]+set-name:" "$file" | tac)

        # reverse it back
        tac "$tmp_file" >"$file"
        rm -f "$tmp_file"

        # the systemd netplan generator produces /run/systemd/network/10-netplan-enp3s0.network
        systemctl daemon-reload
    fi
}

fix_systemd_networkd() {
    for file in /etc/systemd/network/10-cloud-init-eth*.network; do
        [ -f "$file" ] || continue
        mac=$(grep ^MACAddress= "$file" | cut -d= -f2 | grep .) || continue
        ethx=$(get_ethx_by_mac "$mac") || continue

        proper_file=/etc/systemd/network/10-$ethx.network

        # rewrite the file contents
        sed -Ei "s/^Name=eth[0-9]+/Name=$ethx/" "$file"

        # rename the file
        mv "$file" "$proper_file"
    done
}

fix_rh_sysconfig
fix_suse_sysconfig
fix_network_manager
fix_ifupdown
fix_netplan
fix_systemd_networkd
