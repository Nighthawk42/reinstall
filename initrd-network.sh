#!/bin/ash
# shellcheck shell=dash
# Shared by the alpine and debian initrds

# accept_ra  accept RAs and auto-configure the gateway
# autoconf   auto-configure the address; depends on accept_ra

mac_addr=$1
ipv4_addr=$2
ipv4_gateway=$3
ipv6_addr=$4
ipv6_gateway=$5
ipv6_extra_addrs=$6

DHCP_TIMEOUT=15
DNS_FILE_TIMEOUT=5
TEST_TIMEOUT=10

# Connectivity is detected by checking whether these IPs have the ports open,
# because the debian initrd has no nslookup
# switch to generate_204? but resolv.conf may be empty when we test
# HTTP 80
# HTTPS/DOH 443
# DOT 853
ipv4_dns1='1.1.1.1'
ipv4_dns2='8.8.8.8' # port 80 not open
ipv6_dns1='2606:4700:4700::1111'
ipv6_dns2='2001:4860:4860::8888' # port 80 not open

# Find the primary NIC
    # the debian 11 initrd has no xargs or awk
    # the debian 12 initrd has no xargs
get_ethx() {
    # filter out azure VFs (they have a master ethx)
    # 2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP qlen 1000\    link/ether 60:45:bd:21:8a:51 brd ff:ff:ff:ff:ff:ff
    # 3: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP800> mtu 1500 qdisc mq master eth0 state UP qlen 1000\    link/ether 60:45:bd:21:8a:51 brd ff:ff:ff
    if false; then
        ip -o link | grep -i "$mac_addr" | grep -v master | awk '{print $2}' | cut -d: -f1 | grep .
    else
        ip -o link | grep -i "$mac_addr" | grep -v master | cut -d' ' -f2 | cut -d: -f1 | grep .
    fi
}

get_ipv4_gateway() {
    # the debian 11 initrd has no xargs or awk
    # the debian 12 initrd has no xargs
    ip -4 route show default dev "$ethx" | head -1 | cut -d ' ' -f3
}

get_ipv6_gateway() {
    # the debian 11 initrd has no xargs or awk
    # the debian 12 initrd has no xargs
    ip -6 route show default dev "$ethx" | head -1 | cut -d ' ' -f3
}

get_first_ipv4_addr() {
    # the debian 11 initrd has no xargs or awk
    # the debian 12 initrd has no xargs
    if false; then
        ip -4 -o addr show scope global dev "$ethx" | head -1 | awk '{print $4}'
    else
        ip -4 -o addr show scope global dev "$ethx" | head -1 | grep -o '[0-9\.]*/[0-9]*'
    fi
}

get_first_ipv4_gateway() {
    # the debian 11 initrd has no xargs or awk
    # the debian 12 initrd has no xargs
    if false; then
        ip -4 route show default dev "$ethx" | head -1 | awk '{print $3}'
    else
        ip -4 route show default dev "$ethx" | head -1 | cut -d' ' -f3
    fi
}

remove_netmask() {
    cut -d/ -f1
}

get_first_ipv6_addr() {
    # the debian 11 initrd has no xargs or awk
    # the debian 12 initrd has no xargs
    if false; then
        ip -6 -o addr show scope global dev "$ethx" | head -1 | awk '{print $4}'
    else
        ip -6 -o addr show scope global dev "$ethx" | head -1 | grep -o '[0-9a-f\:]*/[0-9]*'
    fi
}

get_first_ipv6_gateway() {
    # the debian 11 initrd has no xargs or awk
    # the debian 12 initrd has no xargs
    if false; then
        ip -6 route show default dev "$ethx" | head -1 | awk '{print $3}'
    else
        ip -6 route show default dev "$ethx" | head -1 | cut -d' ' -f3
    fi
}

is_have_ipv4_addr() {
    ip -4 addr show scope global dev "$ethx" | grep -q inet
}

is_have_ipv6_addr() {
    ip -6 addr show scope global dev "$ethx" | grep -q inet6
}

is_have_ipv4_gateway() {
    ip -4 route show default dev "$ethx" | grep -q .
}

is_have_ipv6_gateway() {
    ip -6 route show default dev "$ethx" | grep -q .
}

is_have_ipv4() {
    is_have_ipv4_addr && is_have_ipv4_gateway
}

is_have_ipv6() {
    is_have_ipv6_addr && is_have_ipv6_gateway
}

is_have_ipv4_dns() {
    [ -f /etc/resolv.conf ] && grep -q '^nameserver .*\.' /etc/resolv.conf
}

is_have_ipv6_dns() {
    [ -f /etc/resolv.conf ] && grep -q '^nameserver .*:' /etc/resolv.conf
}

add_missing_ipv4_config() {
    if [ -n "$ipv4_addr" ] && [ -n "$ipv4_gateway" ]; then
        if ! is_have_ipv4_addr; then
            ip -4 addr add "$ipv4_addr" dev "$ethx"
        fi

        if ! is_have_ipv4_gateway; then
            # if dhcp could not set the onlink gateway, set it here
            # debian 9 does not recognize onlink for ipv6, but does for ipv4
            if true; then
                ip -4 route add "$ipv4_gateway" dev "$ethx"
                ip -4 route add default via "$ipv4_gateway" dev "$ethx"
            else
                ip -4 route add default via "$ipv4_gateway" dev "$ethx" onlink
            fi
        fi
    fi
}

add_missing_ipv6_config() {
    if [ -n "$ipv6_addr" ] && [ -n "$ipv6_gateway" ]; then
        if ! is_have_ipv6_addr; then
            ip -6 addr add "$ipv6_addr" dev "$ethx"
        fi

        if ! is_have_ipv6_gateway; then
            # if dhcp could not set the onlink gateway, set it here
            # debian 9 does not recognize onlink for ipv6
            if true; then
                ip -6 route add "$ipv6_gateway" dev "$ethx"
                ip -6 route add default via "$ipv6_gateway" dev "$ethx"
            else
                ip -6 route add default via "$ipv6_gateway" dev "$ethx" onlink
            fi
        fi

        # add the extra IPv6 addresses (comma separated)
        if [ -n "$ipv6_extra_addrs" ]; then
            printf '%s\n' "$ipv6_extra_addrs" | tr ',' '\n' | while IFS= read -r addr; do
                if [ -n "$addr" ]; then
                    ip -6 addr add "$addr" dev "$ethx" 2>/dev/null || true
                fi
            done
        fi
    fi
}

is_need_test_ipv4() {
    is_have_ipv4 && ! $ipv4_has_internet
}

is_need_test_ipv6() {
    is_have_ipv6 && ! $ipv6_has_internet
}

# Test methods:
# ping   blocked on some machines
# nc     tests whether the dot/doh ports are open
# wget   tests an actual download

# Whether the initrd's versions support binding a source IP / interface
# tool     nc  wget  nslookup
# debian9  no   yes  not present
# alpine   √    ×      ×

test_by_wget() {
    src=$1
    dst=$2

    # ipv6 must be wrapped in []
    if echo "$dst" | grep -q ':'; then
        url="https://[$dst]"
    else
        url="https://$dst"
    fi

    # a successful tcp 443 connection counts, even if http returns 404
    # grep -m1 returns early
    wget -T "$TEST_TIMEOUT" \
        --bind-address="$src" \
        --no-check-certificate \
        --max-redirect 0 \
        --tries 1 \
        -O /dev/null \
        "$url" 2>&1 | grep -iq -m1 connected
}

test_by_nc() {
    src=$1
    dst=$2

    # a successful tcp 443 connection counts
    nc -z -v \
        -w "$TEST_TIMEOUT" \
        -s "$src" \
        "$dst" 443
}

is_debian_kali() {
    [ -f /etc/lsb-release ] && grep -Eiq 'Debian|Kali' /etc/lsb-release
}

test_connect() {
    if is_debian_kali; then
        test_by_wget "$1" "$2"
    else
        test_by_nc "$1" "$2"
    fi
}

test_internet() {
    for i in $(seq 5); do
        echo "Testing Internet Connection. Test $i... "
        if is_need_test_ipv4 &&
            current_ipv4_addr="$(get_first_ipv4_addr | remove_netmask)" &&
            { test_connect "$current_ipv4_addr" "$ipv4_dns1" ||
                test_connect "$current_ipv4_addr" "$ipv4_dns2"; } >/dev/null 2>&1; then
            echo "IPv4 has internet."
            ipv4_has_internet=true
        fi
        if is_need_test_ipv6 &&
            current_ipv6_addr="$(get_first_ipv6_addr | remove_netmask)" &&
            { test_connect "$current_ipv6_addr" "$ipv6_dns1" ||
                test_connect "$current_ipv6_addr" "$ipv6_dns2"; } >/dev/null 2>&1; then
            echo "IPv6 has internet."
            ipv6_has_internet=true
        fi
        if ! is_need_test_ipv4 && ! is_need_test_ipv6; then
            break
        fi
        sleep 1
    done
}

flush_ipv4_config() {
    ip -4 addr flush scope global dev "$ethx"
    ip -4 route flush dev "$ethx"
    # when the DHCP-assigned IP differs from the pre-reinstall IP, drop the DHCP DNS too in case it is invalid
    sed -i "/\./d" /etc/resolv.conf
}

should_disable_dhcpv4=false
should_disable_accept_ra=false
should_disable_autoconf=false

flush_ipv6_config() {
    if $should_disable_accept_ra; then
        echo 0 >"/proc/sys/net/ipv6/conf/$ethx/accept_ra"
    fi
    if $should_disable_autoconf; then
        echo 0 >"/proc/sys/net/ipv6/conf/$ethx/autoconf"
    fi
    ip -6 addr flush scope global dev "$ethx"
    ip -6 route flush dev "$ethx"
    # when the DHCP-assigned IP differs from the pre-reinstall IP, drop the DHCP DNS too in case it is invalid
    sed -i "/:/d" /etc/resolv.conf
}

for i in $(seq 20); do
    if ethx=$(get_ethx); then
        break
    fi
    sleep 1
done

if [ -z "$ethx" ]; then
    echo "Not found network card: $mac_addr"
    exit
fi

echo "Configuring $ethx ($mac_addr)..."

# without lo up, frp cannot connect to 127.0.0.1 22
ip link set dev lo up

# Bring ethx up
ip link set dev "$ethx" up
sleep 1

# Start dhcpv4/v6
# debian / kali
if [ -f /usr/share/debconf/confmodule ]; then
    # shellcheck source=/dev/null
    . /usr/share/debconf/confmodule

    db_progress STEP 1

    # dhcpv4
    # no need to wait for dns here; we wait during dhcpv6
    db_progress INFO netcfg/dhcp_progress
    udhcpc -i "$ethx" -f -q -n || true
    db_progress STEP 1

    # slaac + dhcpv6
    db_progress INFO netcfg/slaac_wait_title
    # https://salsa.debian.org/installer-team/netcfg/-/blob/master/autoconfig.c#L148
    cat <<EOF >/var/lib/netcfg/dhcp6c.conf
interface $ethx {
    send ia-na 0;
    request domain-name-servers;
    request domain-name;
    script "/lib/netcfg/print-dhcp6c-info";
};

id-assoc na 0 {
};
EOF
    dhcp6c -c /var/lib/netcfg/dhcp6c.conf "$ethx" || true
    sleep $DHCP_TIMEOUT # wait for the IP and for dns to be written
    # kill-all-dhcp
    kill -9 "$(cat /var/run/dhcp6c.pid)" || true
    db_progress STEP 1

    # static + connectivity-check notice
    db_subst netcfg/link_detect_progress interface "$ethx"
    db_progress INFO netcfg/link_detect_progress
else
    # alpine
    # on h3c cloud desktops udhcpc repeats "sending select", so add a timeout to force it to stop
    # dhcpcd honours the lease and drops the IP when it expires, but we do not keep dhcpcd running, so use udhcpc
    method=udhcpc

    case "$method" in
    udhcpc)
        timeout $DHCP_TIMEOUT udhcpc -i "$ethx" -f -q -n || true
        timeout $DHCP_TIMEOUT udhcpc6 -i "$ethx" -f -q -n || true
        sleep $DNS_FILE_TIMEOUT # probably no need to wait for dns, but just in case
        ;;
    dhcpcd)
        # https://gitlab.alpinelinux.org/alpine/aports/-/blob/master/main/dhcpcd/dhcpcd.pre-install
        grep -q dhcpcd /etc/group || addgroup -S dhcpcd
        grep -q dhcpcd /etc/passwd || adduser -S -D -H \
            -h /var/lib/dhcpcd \
            -s /sbin/nologin \
            -G dhcpcd \
            -g dhcpcd \
            dhcpcd

        # --noipv4ll prevents generating 169.254.x.x
        if false; then
            # wait for the whole DHCP exchange
            timeout $DHCP_TIMEOUT \
                dhcpcd --persistent --noipv4ll --nobackground "$ethx"
        else
            # wait for DNS
            dhcpcd --persistent --noipv4ll "$ethx" # backgrounds itself as soon as it has an IP
            sleep $DNS_FILE_TIMEOUT                # must wait for dns to be written
            dhcpcd -x "$ethx"                      # stop it
        fi
        # dhcpcd turns autoconf and accept_ra off, so turn them back on
        # without that, re-running dhcpcd still generates the slaac address and route correctly
        sysctl -w "net.ipv6.conf.$ethx.autoconf=1"
        sysctl -w "net.ipv6.conf.$ethx.accept_ra=1"
        ;;
    esac
fi

# Wait for slaac
# skip once there is an ipv6 address, whether from slaac or dhcpv6
# because trans checks it later
# 5 seconds is enough here, since the earlier dhcp6 attempt already took a while
for i in $(seq 5 -1 0); do
    is_have_ipv6 && break
    echo "waiting slaac for ${i}s"
    sleep 1
done

# Record whether a dynamic address exists
# no static IP has been set yet, so any entry means a dynamic address
is_have_ipv4_addr && dhcpv4=true || dhcpv4=false
is_have_ipv6_addr && dhcpv6_or_slaac=true || dhcpv6_or_slaac=false
is_have_ipv6_gateway && ra_has_gateway=true || ra_has_gateway=false

# If the auto-assigned IP differs from the pre-reinstall one, switch to static using the old IP
# Only the IP is compared, not the netmask/gateway, because
# 1. if the netmask/gateway breaks connectivity, that is detected later and switched to static anyway
# 2. openSUSE wicked dhcpv6 uses a /64, as does the aws lightsail template, while other dhcpv6 clients use /128
if $dhcpv4 && [ -n "$ipv4_addr" ] && [ -n "$ipv4_gateway" ] &&
    ! [ "$(echo "$ipv4_addr" | cut -d/ -f1)" = "$(get_first_ipv4_addr | cut -d/ -f1)" ]; then
    echo "IPv4 address obtained from DHCP is different from old system."
    should_disable_dhcpv4=true
    flush_ipv4_config
fi
if $dhcpv6_or_slaac && [ -n "$ipv6_addr" ] && [ -n "$ipv6_gateway" ] &&
    ! [ "$(echo "$ipv6_addr" | cut -d/ -f1)" = "$(get_first_ipv6_addr | cut -d/ -f1)" ]; then
    echo "IPv6 address obtained from SLAAC/DHCPv6 is different from old system."
    should_disable_accept_ra=true
    should_disable_autoconf=true
    flush_ipv6_config
fi

# Set the static address, or the gateway that debian 9's udhcpc cannot set
add_missing_ipv4_config
add_missing_ipv6_config

# Check whether ipv4/ipv6 have connectivity
ipv4_has_internet=false
ipv6_has_internet=false
test_internet

# If there is no connectivity and the auto-assigned netmask/gateway differs from before, switch to static
# ip_addr includes IP/netmask, so it can tell whether the netmask differs
# a differing IP was already switched to static above
if ! $ipv4_has_internet &&
    $dhcpv4 && [ -n "$ipv4_addr" ] && [ -n "$ipv4_gateway" ] &&
    ! { [ "$ipv4_addr" = "$(get_first_ipv4_addr)" ] && [ "$ipv4_gateway" = "$(get_first_ipv4_gateway)" ]; }; then
    echo "IPv4 netmask/gateway obtained from DHCP is different from old system."
    should_disable_dhcpv4=true
    flush_ipv4_config
    add_missing_ipv4_config
    test_internet
fi
# IPv6 may be static yet still learn a gateway from an RA, hence the || $ra_has_gateway
if ! $ipv6_has_internet &&
    { $dhcpv6_or_slaac || $ra_has_gateway; } &&
    [ -n "$ipv6_addr" ] && [ -n "$ipv6_gateway" ] &&
    ! { [ "$ipv6_addr" = "$(get_first_ipv6_addr)" ] && [ "$ipv6_gateway" = "$(get_first_ipv6_gateway)" ]; }; then
    echo "IPv6 netmask/gateway obtained from SLAAC/DHCPv6 is different from old system."
    should_disable_accept_ra=true
    should_disable_autoconf=true
    flush_ipv6_config
    add_missing_ipv6_config
    test_internet
fi

# Remove addresses for protocols with no connectivity, because
# 1 adding then cancelling an ipv6 address in the Oracle Cloud panel
#   still assigns an ipv6 address, but with no ipv6 connectivity
#   alpine then downloads apks over ipv6 only and never falls back to ipv4
# 2 with an ipv4 address but no ipv4 gateway (vultr $2.5 ipv6-only), aria2 downloads over ipv4

# If ipv4 and ipv6 are on different NICs and only ipv4 works, ipv6 must be removed too
# ipv4_has_internet && ! ipv6_has_internet cannot be used, because that tests a single NIC
if ! $ipv4_has_internet; then
    if $dhcpv4; then
        should_disable_dhcpv4=true
    fi
    flush_ipv4_config
fi
if ! $ipv6_has_internet; then
    # stop SLAAC handing the IPv6 address straight back after removal
    # no need for || $ra_has_gateway: an IPv6 gateway without an IPv6 address causes no download problems
    if $dhcpv6_or_slaac; then
        should_disable_accept_ra=true
        should_disable_autoconf=true
    fi
    flush_ipv6_config
fi

# If online but no default DNS was obtained, add ours

# One case: with multiple NICs, the working NIC finishes this script before the non-working one
# the non-working NIC then removes its IP and dns via flush_ipv4_config
# (the plan was to remove only the dhcp4 dns of the non-working NIC, but they cannot be told apart)
# so add the dns unconditionally, without checking connectivity
if ! is_have_ipv4_dns; then
    echo "nameserver $ipv4_dns1" >>/etc/resolv.conf
    echo "nameserver $ipv4_dns2" >>/etc/resolv.conf
fi
if ! is_have_ipv6_dns; then
    echo "nameserver $ipv6_dns1" >>/etc/resolv.conf
    echo "nameserver $ipv6_dns2" >>/etc/resolv.conf
fi

# Pass the parameters on to trans.start
netconf="/dev/netconf/$ethx"
mkdir -p "$netconf"
$dhcpv4 && echo 1 >"$netconf/dhcpv4" || echo 0 >"$netconf/dhcpv4"
$dhcpv6_or_slaac && echo 1 >"$netconf/dhcpv6_or_slaac" || echo 0 >"$netconf/dhcpv6_or_slaac"
$should_disable_dhcpv4 && echo 1 >"$netconf/should_disable_dhcpv4" || echo 0 >"$netconf/should_disable_dhcpv4"
$should_disable_accept_ra && echo 1 >"$netconf/should_disable_accept_ra" || echo 0 >"$netconf/should_disable_accept_ra"
$should_disable_autoconf && echo 1 >"$netconf/should_disable_autoconf" || echo 0 >"$netconf/should_disable_autoconf"
echo "$ethx" >"$netconf/ethx"
echo "$mac_addr" >"$netconf/mac_addr"
echo "$ipv4_addr" >"$netconf/ipv4_addr"
echo "$ipv4_gateway" >"$netconf/ipv4_gateway"
echo "$ipv6_addr" >"$netconf/ipv6_addr"
echo "$ipv6_gateway" >"$netconf/ipv6_gateway"
echo "$ipv6_extra_addrs" >"$netconf/ipv6_extra_addrs"
$ipv4_has_internet && echo 1 >"$netconf/ipv4_has_internet" || echo 0 >"$netconf/ipv4_has_internet"
$ipv6_has_internet && echo 1 >"$netconf/ipv6_has_internet" || echo 0 >"$netconf/ipv6_has_internet"
