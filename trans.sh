#!/bin/ash
# shellcheck shell=dash
# shellcheck disable=SC2086,SC3047,SC3036,SC3010,SC3001,SC3060,SC3015
# alpine uses busybox ash by default
# note that bash and ash give different results for the statement below
# [[ a = '*a' ]] && echo 1

# Stop on error and drop to the login prompt, so the machine is not left unreachable
set -eE

# Used to check that reinstall.sh and trans.sh are compatible
# shellcheck disable=SC2034
SCRIPT_VERSION=4BACD833-A585-23BA-6CBB-9AA4E08E0004

TRUE=0
FALSE=1
EFI_UUID=C12A7328-F81F-11D2-BA4B-00A0C93EC93B

error() {
    color='\e[31m'
    plain='\e[0m'
    echo -e "${color}***** ERROR *****${plain}" >&2
    echo -e "${color}$*${plain}" >&2
}

info() {
    color='\e[32m'
    plain='\e[0m'
    local msg

    if [ "$1" = false ]; then
        shift
        msg=$*
    else
        msg=$(echo "$*" | to_upper)
    fi

    echo -e "${color}***** $msg *****${plain}" >&2
}

warn() {
    color='\e[33m'
    plain='\e[0m'
    echo -e "${color}Warning: $*${plain}" >&2
}

error_and_exit() {
    error "$@"

    if is_have_cmd sudo; then
        sudo_='sudo '
    elif is_have_cmd doas; then
        sudo_='doas '
    else
        sudo_=
    fi

    echo "Run '$sudo_/trans.sh' to retry." >&2
    echo "Run '$sudo_/trans.sh alpine' to install Alpine Linux instead." >&2

    # unlock, so the user can log in and fix the problem
    # passwd -u "$username" >/dev/null

    # not needed: a locked alpine account cannot log in over ssh anyway,
    # so it is never locked

    exit 1
}

trap_err() {
    line_no=$1
    ret_no=$2

    error_and_exit "$(
        echo "Line $line_no return $ret_no"
        if [ -f "/trans.sh" ]; then
            sed -n "$line_no"p /trans.sh
        fi
    )"
}

is_run_from_locald() {
    [[ "$0" = "/etc/local.d/*" ]]
}

# reinstall.sh has the same function, add_community_repo_for_alpine
add_community_repo() {
    local ver mirror

    # first check whether the existing repo is edge or latest-stable
    if grep -q "^http.*/edge/main$" /etc/apk/repositories; then
        ver=edge
    elif grep -q "^http.*/latest-stable/main$" /etc/apk/repositories; then
        ver=latest-stable
    else
        ver=v$(cut -d. -f1,2 </etc/alpine-release)
    fi

    if ! grep -q "^http.*/$ver/community$" /etc/apk/repositories; then
        mirror=$(grep '^http.*/main$' /etc/apk/repositories | sed 's,/[^/]*/main$,,' | head -1)
        echo $mirror/$ver/community >>/etc/apk/repositories
    fi
}

# Network problems sometimes make a download fail and abort the script,
# so retry
apk() {
    retry 5 command apk "$@" >&2
}

show_url_in_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
        [Hh][Tt][Tt][Pp][Ss]://* | [Hh][Tt][Tt][Pp]://* | [Mm][Aa][Gg][Nn][Ee][Tt]:*) echo "$1" ;;
        esac
        shift
    done
}

killall() {
    # killall is asynchronous, so wait a moment
    local ret=0
    if ! command killall "$@"; then
        ret=$?
    fi
    sleep 5
    return $ret
}

# Without set +o pipefail, limiting the download size behaves as follows:
# retry 5 command wget | head -c 1048576 triggers the retry and downloads 5 times
# command wget "$@" --tries=5 | head -c 1048576 does not trigger wget\'s own retry and downloads once
wget() {
    show_url_in_args "$@" >&2
    if command wget 2>&1 | grep -q BusyBox; then
        # busybox wget has no retry support
        # and seems never to time out by default
        retry 5 command wget "$@" -T 10
    else
        # the real wget has retry support
        command wget --tries=5 --progress=bar:force "$@"
    fi
}

is_have_cmd() {
    # command -v also finds functions defined in this script
    is_have_cmd_on_disk / "$1"
}

is_have_cmd_on_disk() {
    local os_dir=$1
    local cmd=$2

    for bin_dir in /bin /sbin /usr/bin /usr/sbin; do
        if [ -f "$os_dir$bin_dir/$cmd" ]; then
            return
        fi
    done
    return 1
}

is_num() {
    echo "$1" | grep -Exq '[0-9]*\.?[0-9]*'
}

retry() {
    local max_try=$1
    shift

    if is_num "$1"; then
        local interval=$1
        shift
    else
        local interval=5
    fi

    local i
    for i in $(seq $max_try); do
        if "$@"; then
            return
        else
            ret=$?
            # wget -O- | grep -m1 closes the pipe early on success, causing error 141
            # that is expected, so filter it out
            if [ $ret -eq 141 ]; then
                return
            fi
            if [ $i -ge $max_try ]; then
                return $ret
            fi
            sleep $interval
        fi
    done
}

get_url_type() {
    if [[ "$1" = magnet:* ]]; then
        echo bt
    else
        echo http
    fi
}

is_magnet_link() {
    [[ "$1" = magnet:* ]]
}

create_alpine_rootfs() {
    local os_dir=$1
    local init_now=${2:-false}

    # Copy the /etc/apk folder of the current system
    mkdir -p "$os_dir"
    cp -a --parents /etc/apk "$os_dir"
    rm -f "$os_dir/etc/apk/world"

    # Install alpine
    apk add --root "$os_dir" --initdb \
        alpine-base openssl ca-certificates

    if $init_now; then
        cp_resolv_conf "$os_dir"
        mount_pseudo_fs "$os_dir"
    fi
}

create_alpine_rootfs_with_arch_install_scripts() {
    local os_dir=$1
    local init_now=${2:-false}
    local parent_os_dir=$3

    create_alpine_rootfs "$os_dir" $init_now

    # write the alpine-base dependencies into world, then remove alpine-base and alpine-conf
    # the order of --installed and --depends matters
    # without --installed it shows both the installed and the newest versions
    alpine_base_depends=$(chroot "$os_dir" apk info --installed --depends alpine-base | sed '/depends on:/d')
    chroot "$os_dir" apk add $alpine_base_depends
    chroot "$os_dir" apk del alpine-base alpine-conf
    chroot "$os_dir" apk add arch-install-scripts

    if [ -n "$parent_os_dir" ]; then
        mkdir -p "$os_dir/parent"
        mount --rbind "$parent_os_dir" "$os_dir/parent"
    fi
}

remove_alpine_rootfs() {
    local os_dir=$1

    umount_pseudo_fs "$os_dir"
    rm -rf "$os_dir"
}

download_via_browser() {
    local url=$1
    local path=$2

    local os_dir=/os/alpine_for_browser
    mkdir_clear "$os_dir"

    # install chromium-headless-shell and npm to disk to reduce memory use
    create_alpine_rootfs "$os_dir" true
    apk add --root "$os_dir" chromium-headless-shell npm

    # install playwright
    # shellcheck disable=SC2046
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
        chroot "$os_dir" \
        npm install \
        --no-save --no-package-lock \
        --prefix "/work" \
        playwright

    # download the file
    # shellcheck disable=SC2154
    wget "$confhome/download-via-browser.js" -O "$os_dir/work/download-via-browser.js"
    retry 5 chroot "$os_dir" node /work/download-via-browser.js "$url" "/work/download_file"
    cp "$os_dir/work/download_file" "$path"

    # clean up
    remove_alpine_rootfs "$os_dir"
}

download() {
    local url=$1
    local path=$2

    # with an ipv4 address but no ipv4 gateway, aria2 may download over ipv4 instead of ipv6
    # axel uses a lot of cpu on lightsail
    # https://download.opensuse.org/distribution/leap/15.5/appliances/openSUSE-Leap-15.5-Minimal-VM.x86_64-kvm-and-xen.qcow2
    # https://aria2.github.io/manual/en/html/aria2c.html#cmdoption-o

    # some mirrors rate-limit and block axel/aria2 by user-agent
    # aria2 defaults to --max-tries 5

    # the default is --max-tries=5, but in the case below the server errors and aria2 returns immediately instead of retrying,
    # hence the for loop
    #     [ERROR] CUID#7 - Download aborted. URI=https://aka.ms/manawindowsdrivers
    # Exception: [AbstractCommand.cc:351] errorCode=1 URI=https://aka.ms/manawindowsdrivers
    #   -> [SocketCore.cc:1019] errorCode=1 SSL/TLS handshake failure:  `not signed by known authorities or invalid'

    # with if, an error would not abort the script
    # if aria2c xxx; then
    #     return
    # fi

    # --user-agent=Wget/1.21.1 \
    # --retry-wait 5

    # the torrent was already downloaded while checking the size
    if [ "$(get_url_type "$url")" = bt ]; then
        torrent="$(get_torrent_path_by_magnet $url)"
        if ! [ -f "$torrent" ]; then
            download_torrent_by_magnet "$url" "$torrent"
        fi
        url=$torrent
    fi

    # intel blocks aria2 from downloading drivers
    # intel blocks wget from downloading page content
    # the tencent cloud virtio driver also blocks aria2

    # -o sets the http download filename
    # -O sets the filename of the first bt file
    set -- \
        -d "$(dirname "$path")" \
        -o "$(basename "$path")" \
        -O "1=$(basename "$path")" \
        -U curl/7.54.1

    if ! aria2c "$url" "$@"; then
        error_and_exit "Failed to download $url"
    fi

    # the official opensuse mirror supports metalink
    # aria2 cannot rename a file downloaded via metalink,
    # so rename it as follows
    if head -c 1024 "$path" | grep -Fq 'urn:ietf:params:xml:ns:metalink'; then
        real_file=$(tr -d '\n' <"$path" | sed -E 's|.*<file[[:space:]]+name="([^"]*)".*|\1|')
        mv "$(dirname "$path")/$real_file" "$path"
    fi
}

update_part() {
    sleep 1
    sync

    # partprobe
    # a mounted partition causes a Resource busy error
    if is_have_cmd partprobe; then
        partprobe /dev/$xda 2>/dev/null || true
    fi

    # partx
    # https://access.redhat.com/solutions/199573
    if is_have_cmd partx; then
        partx -u /dev/$xda
    fi

    # mdev
    # mdev does not remove the old partitions under /dev/disk/, so remove them by hand
    # if mdev happens to be creating a link during rm -rf, rm -rf fails with Directory not empty,
    # so stop the mdev service first
    # should /dev/$xda* be removed too?
    ensure_service_stopped mdev
    # even with mdev stopped it sometimes still reports Directory not empty, hence the retry
    retry 5 rm -rf /dev/disk/*

    # a warning is printed when modloop is not mounted,
    # modprobe: can't change directory to '/lib/modules': No such file or directory
    # so suppress it
    mdev -sf 2>/dev/null
    ensure_service_started mdev 2>/dev/null
    sleep 1
}

is_efi() {
    if [ -n "$force_boot_mode" ]; then
        [ "$force_boot_mode" = efi ]
    else
        [ -d /sys/firmware/efi/ ]
    fi
}

is_use_cloud_image() {
    [ -n "$cloud_image" ] && [ "$cloud_image" = 1 ]
}

is_allow_ping() {
    [ -n "$allow_ping" ] && [ "$allow_ping" = 1 ]
}

setup_nginx() {
    apk add nginx
    # shellcheck disable=SC2154
    wget $confhome/logviewer.html -O /logviewer.html
    wget $confhome/logviewer-nginx.conf -O /etc/nginx/http.d/default.conf

    sed -i "s/@WEB_PORT@/$web_port/gi" /etc/nginx/http.d/default.conf

    # rc-service -q nginx start
    if pgrep nginx >/dev/null; then
        nginx -s reload
    else
        nginx
    fi
}

setup_websocketd() {
    apk add websocketd
    wget $confhome/logviewer.html -O /tmp/index.html
    apk add coreutils

    killall -q websocketd || true
    # websocketd only pushes on \n, so convert \r to \n
    websocketd --port "$web_port" --loglevel=fatal --staticdir=/tmp \
        stdbuf -oL -eL sh -c "tail -fn+0 /reinstall.log | tr '\r' '\n' | grep -Fiv -e password -e token" &
}

get_approximate_ram_size() {
    # lsmem needs util-linux
    if false && is_have_cmd lsmem; then
        ram_size=$(lsmem -b 2>/dev/null | grep 'Total online memory:' | awk '{ print $NF/1024/1024 }')
    fi

    if [ -z $ram_size ]; then
        ram_size=$(free -m | awk '{print $2}' | sed -n '2p')
    fi

    echo "$ram_size"
}

setup_web_if_enough_ram() {
    total_ram=$(get_approximate_ram_size)
    # only install with 512 of memory
    if [ "$total_ram" -ge 400 ]; then
        # lighttpd uses little memory at run time but a lot of space to install
        # setup_lighttpd
        # setup_nginx
        setup_websocketd
    fi
}

setup_lighttpd() {
    apk add lighttpd
    ln -sf /reinstall.html /var/www/localhost/htdocs/index.html
    rc-service -q lighttpd start
}

get_ttys() {
    prefix=$1
    # shellcheck disable=SC2154
    wget $confhome/ttys.sh -O- | sh -s $prefix
}

find_xda() {
    # if the script is re-run after an error the disk may already be formatted, making the recorded partition table id invalid,
    # so save xda to /configs/xda once it is found

    # read the previously saved value first
    if xda=$(get_config xda 2>/dev/null) && [ -n "$xda" ]; then
        return
    fi

    # guard against an empty $main_disk
    if [ -z "$main_disk" ]; then
        error_and_exit "cmdline main_disk is empty."
    fi

    # busybox fdisk/lsblk/blkid do not show the mbr partition table id
    # these tools can be used instead:
    # fdisk lives in util-linux-misc, which is large
    # sfdisk is small
    # lsblk
    # blkid

    tool=sfdisk

    is_have_cmd $tool && need_install_tool=false || need_install_tool=true
    if $need_install_tool; then
        apk add $tool
    fi

    if [ "$tool" = sfdisk ]; then
        # sfdisk
        for disk in $(get_all_disks); do
            if sfdisk --disk-id "/dev/$disk" | sed 's/0x//' | grep -ix "$main_disk"; then
                xda=$disk
                break
            fi
        done
    else
        # lsblk
        xda=$(lsblk --nodeps -rno NAME,PTUUID | grep -iw "$main_disk" | awk '{print $1}')
    fi

    if [ -n "$xda" ]; then
        set_config xda "$xda"
    else
        error_and_exit "Could not find xda: $main_disk"
    fi

    if $need_install_tool; then
        apk del $tool
    fi
}

get_all_disks() {
    # shellcheck disable=SC2010
    ls /sys/block/ | grep -Ev '^(loop|sr|nbd)'
}

extract_env_from_cmdline() {
    # Extract finalos/extra into variables
    for prefix in finalos extra; do
        while read -r line; do
            if [ -n "$line" ]; then
                key=$(echo $line | cut -d= -f1)
                value=$(echo $line | cut -d= -f2-)
                eval "$key='$value'"
            fi
        done < <(xargs -n1 </proc/cmdline | grep "^${prefix}_" | sed "s/^${prefix}_//")
    done

    # set the default when blank
    if [ "$distro" = windows ]; then
        username=${username:-administrator}
    else
        username=${username:-root}
    fi
    ssh_port=${ssh_port:-22}
    rdp_port=${rdp_port:-3389}
    web_port=${web_port:-80}
}

ensure_service_started() {
    local service=$1

    if ! rc-service -q "$service" start; then
        for i in $(seq 10); do
            if [ "$service" = modloop ]; then
                # guard against an incomplete modloop download causing an error
                # * Failed to verify signature of !
                # mount: mounting /dev/loop0 on /.modloop failed: Invalid argument
                rm -f /lib/modloop-lts /lib/modloop-virt
            fi
            if rc-service -q "$service" start; then
                return
            fi
            sleep 5
        done
        error_and_exit "Failed to start $service."
    fi
}

ensure_service_stopped() {
    local service=$1

    if ! retry 10 5 rc-service -q "$service" stop; then
        error_and_exit "Failed to stop $service."
    fi
}

mod_motd() {
    # restore the defaults after alpine is installed
    # alpine may have been installed manually after an automatic install failed, so do not check $distro
    file=/etc/motd
    if ! [ -e $file.orig ]; then
        cp $file $file.orig
        # shellcheck disable=SC2016
        echo "mv "\$mnt$file.orig" "\$mnt$file"" |
            insert_into_file "$(which setup-disk)" before 'cleanup_chroot_mounts "\$mnt"'

        cat <<EOF >$file
Reinstalling...
To view logs run:
tail -fn+1 /reinstall.log
EOF
    fi
}

umount_all() {
    dirs="/mnt /os /iso /wim /wim-tmp /installer /nbd /nbd-boot /nbd-efi /nbd-test /root /nix"
    regex=$(echo "$dirs" | sed 's, ,|,g')
    if mounts=$(mount | grep -Ew "on $regex" | awk '{print $3}' | tac); then
        for mount in $mounts; do
            echo "umount $mount"
            umount $mount
        done
    fi
}

# The script may not be running for the first time, so clean up any leftovers
clear_previous() {
    if is_have_cmd vgchange; then
        umount -R /os /nbd || true
        vgchange -an
        apk add device-mapper
        dmsetup remove_all
    fi
    disconnect_qcow
    # installing arch leaves a gpg-agent process running
    # aborting the script by hand during an aria2c download leaves aria2c downloading in the background
    killall -q gpg-agent aria2c || true
    rc-service -q --ifexists --ifstarted nix-daemon stop
    swapoff -a
    umount_all

    # in the following case umount -R /1 reports busy
    # mount /file1 /1
    # mount /1/file2 /2
}

# virt-what pulls in dmidecode, so cache both together
cache_dmi_and_virt() {
    if ! [ "$_dmi_and_virt_cached" = 1 ]; then
        apk add virt-what

    # distinguish kvm from virtio, because:
    # 1. virt-what does not report kvm on alibaba cloud c8y
    # 2. not every kvm needs the virtio driver, e.g. aws nitro
    # 3. virt-what does not detect virtio
        _virt=$(
            virt-what

            # under hyper-v, modprobe virtio_scsi also creates /sys/bus/virtio/drivers/virtio_scsi
            # so checking devices is more accurate: /sys/bus/virtio/drivers/* only exists when a device does
            # or should lspci be used as well?

            # do not use ls /sys/bus/virtio/devices/* && echo virtio
            # because a non-zero exit status would abort the script
            if ls /sys/bus/virtio/devices/* >/dev/null 2>&1; then
                echo virtio
            fi
        )

        _dmi=$(dmidecode | grep -E '(Manufacturer|Asset Tag|Vendor): ' | awk -F': ' '{print $2}')
        _dmi_and_virt_cached=1
        apk del virt-what
    fi
}

is_virt() {
    cache_dmi_and_virt
    [ -n "$_virt" ]
}

is_virt_contains() {
    cache_dmi_and_virt
    echo "$_virt" | grep -Eiwq "$1"
}

is_dmi_contains() {
    # Manufacturer: Alibaba Cloud
    # Manufacturer: Tencent Cloud
    # Manufacturer: Huawei Cloud
    # Asset Tag: OracleCloud.com
    # Vendor: Amazon EC2
    # Manufacturer: Amazon EC2
    # Asset Tag: Amazon EC2
    cache_dmi_and_virt
    echo "$_dmi" | grep -Eiwq "$1"
}

cache_lspci() {
    if [ -z "$_lspci" ]; then
        apk add pciutils
        _lspci=$(lspci)
        apk del pciutils
    fi
}

is_lspci_contains() {
    cache_lspci
    echo "$_lspci" | grep -Eiwq "$1"
}

get_config() {
    cat "/configs/$1"
}

set_config() {
    printf '%s' "$2" >"/configs/$1"
}

# the ubuntu and el/ol installer editions do not use this password
get_password_linux_sha512() {
    get_config password-linux-sha512
}

get_password_windows_administrator_base64() {
    get_config password-windows-administrator-base64
}

get_password_windows_user_base64() {
    get_config password-windows-user-base64
}

get_password_plaintext() {
    get_config password-plaintext
}

is_password_plaintext() {
    get_password_plaintext >/dev/null 2>&1
}

show_netconf() {
    grep -r . /dev/netconf/
}

get_ra_to() {
    if [ -z "$_ra" ]; then
        apk add ndisc6
        # it is sometimes received more than once, so exit after the first
        echo "Gathering network info..."
        # shellcheck disable=SC2154
        _ra="$(rdisc6 -1 "$ethx")"
        apk del ndisc6

        # show the network configuration
        info "Network info:"
        echo
        echo "$_ra" | cat -n
        echo
        ip addr | cat -n
        echo
        show_netconf | cat -n
        echo
    fi
    eval "$1='$_ra'"
}

get_netconf_to() {
    case "$1" in
    slaac | dhcpv6 | rdnss | other) get_ra_to ra ;;
    esac

    # shellcheck disable=SC2154
    # the debian initrd has no xargs
    case "$1" in
    slaac) echo "$ra" | grep 'Autonomous address conf' | grep -q Yes && res=1 || res=0 ;;
    dhcpv6) echo "$ra" | grep 'Stateful address conf' | grep -q Yes && res=1 || res=0 ;;
    rdnss) res=$(echo "$ra" | grep 'Recursive DNS server' | cut -d: -f2-) ;;
    other) echo "$ra" | grep 'Stateful other conf' | grep -q Yes && res=1 || res=0 ;;
    *) res=$(cat /dev/netconf/$ethx/$1) ;;
    esac

    eval "$1='$res'"
}

is_any_ipv4_has_internet() {
    grep -q 1 /dev/netconf/*/ipv4_has_internet
}

# having dhcpv4 does not mean there is a gateway, e.g. vultr pure ipv6
# not having dhcpv4 does not mean the ip is static; there may be no ip at all
is_dhcpv4() {
    if ! is_ipv4_has_internet || should_disable_dhcpv4; then
        return 1
    fi

    get_netconf_to dhcpv4
    # shellcheck disable=SC2154
    [ "$dhcpv4" = 1 ]
}

is_staticv4() {
    if ! is_ipv4_has_internet; then
        return 1
    fi

    if ! is_dhcpv4; then
        get_netconf_to ipv4_addr
        get_netconf_to ipv4_gateway
        if [ -n "$ipv4_addr" ] && [ -n "$ipv4_gateway" ]; then
            return 0
        fi
    fi
    return 1
}

is_staticv6() {
    if ! is_ipv6_has_internet; then
        return 1
    fi

    if ! is_slaac && ! is_dhcpv6; then
        get_netconf_to ipv6_addr
        get_netconf_to ipv6_gateway
        if [ -n "$ipv6_addr" ] && [ -n "$ipv6_gateway" ]; then
            return 0
        fi
    fi
    return 1
}

is_dhcpv6_or_slaac() {
    get_netconf_to dhcpv6_or_slaac
    # shellcheck disable=SC2154
    [ "$dhcpv6_or_slaac" = 1 ]
}

is_ipv4_has_internet() {
    get_netconf_to ipv4_has_internet
    # shellcheck disable=SC2154
    [ "$ipv4_has_internet" = 1 ]
}

is_ipv6_has_internet() {
    get_netconf_to ipv6_has_internet
    # shellcheck disable=SC2154
    [ "$ipv6_has_internet" = 1 ]
}

should_disable_dhcpv4() {
    get_netconf_to should_disable_dhcpv4
    # shellcheck disable=SC2154
    [ "$should_disable_dhcpv4" = 1 ]
}

should_disable_accept_ra() {
    get_netconf_to should_disable_accept_ra
    # shellcheck disable=SC2154
    [ "$should_disable_accept_ra" = 1 ]
}

should_disable_autoconf() {
    get_netconf_to should_disable_autoconf
    # shellcheck disable=SC2154
    [ "$should_disable_autoconf" = 1 ]
}

is_slaac() {
    # if static (including an auto-assigned IP switched to static because it had no connectivity), return 1 immediately and ignore ra
    # this stops machines whose slaac/dhcpv6 ip/gateway cannot reach the internet

    # the ra dhcpv6/slaac flags may be on while no ipv6 address is actually obtained
    # is_dhcpv6_or_slaac reflects the real result, so return 1 when that fails too

    # do not test is_staticv6 here: it would cause infinite recursion
    if ! is_ipv6_has_internet || ! is_dhcpv6_or_slaac || should_disable_accept_ra || should_disable_autoconf; then
        return 1
    fi
    get_netconf_to slaac
    # shellcheck disable=SC2154
    [ "$slaac" = 1 ]
}

is_dhcpv6() {
    # if static (including an auto-assigned IP switched to static because it had no connectivity), return 1 immediately and ignore ra
    # this stops machines whose slaac/dhcpv6 ip/gateway cannot reach the internet

    # the ra dhcpv6/slaac flags may be on while no ipv6 address is actually obtained
    # is_dhcpv6_or_slaac reflects the real result, so return 1 when that fails too

    # do not test is_staticv6 here: it would cause infinite recursion
    if ! is_ipv6_has_internet || ! is_dhcpv6_or_slaac || should_disable_accept_ra || should_disable_autoconf; then
        return 1
    fi
    get_netconf_to dhcpv6

    # shellcheck disable=SC2154
    # on Oracle the RA DHCPv6 flag is set even when no IPv6 address was added
    # some systems then wait for a DHCPv6 timeout at boot,
    # so DHCPv6 must be disabled in that case
    if [ "$dhcpv6" = 1 ] && ! ip -6 -o addr show scope global dev "$ethx" | grep -q .; then
        echo 'DHCPv6 flag is on, but DHCPv6 is not working.'
        return 1
    fi

    [ "$dhcpv6" = 1 ]
}

is_have_ipv6() {
    is_slaac || is_dhcpv6 || is_staticv6
}

is_enable_other_flag() {
    get_netconf_to other
    # shellcheck disable=SC2154
    [ "$other" = 1 ]
}

is_have_rdnss() {
    # there may be several rdnss entries
    get_netconf_to rdnss
    [ -n "$rdnss" ]
}

# this function is overwritten when the dd image is detected as windows
is_windows() {
    [ "$distro" = windows ]
}

# rdnss is only supported on 15063 and later
is_windows_support_rdnss() {
    [ "$build_ver" -ge 15063 ]
}

get_windows_version_from_windows_drive() {
    local os_dir=$1

    # https://wiki.tcl-lang.org/page/Windows+OS+name
    # https://nsis.sourceforge.io/Get_Windows_version

    # only win10+ has CurrentMajorVersionNumber and CurrentMinorVersionNumber
    # CurrentVersion            6.3
    # CurrentMajorVersionNumber  10
    # CurrentMinorVersionNumber   0

    apk add hivex-perl
    hive=$(find_file_ignore_case $os_dir/Windows/System32/config/SOFTWARE)

    get_current_version_key() {
        hivexget "$hive" "Microsoft\Windows NT\CurrentVersion" "$1"
    }

    # nt_ver
    if { nt_ver_major=$(get_current_version_key CurrentMajorVersionNumber) &&
        nt_ver_minor=$(get_current_version_key CurrentMinorVersionNumber); } 2>/dev/null; then
        nt_ver="$nt_ver_major.$nt_ver_minor"
    else
        # en_windows_vista_sp2_x64_dvd_342267.iso
        # before install, CurrentVersion is 6.0
        # after install, CurrentVersion is 6.0

        # en_windows_vista_sp2_with_update_6003.23713_aio_7in1_x64_v26.01.13_by_adguard.iso
        # before install, CurrentVersion is 6.0.6002.18005
        # after install, CurrentVersion is 6.0

        # cut is added to handle both cases
        nt_ver=$(get_current_version_key CurrentVersion | cut -d. -f1-2)
    fi

    # build_ver
    # the exe/dll version of win10 22h2 19045 is still 19041, so read it from the registry
    # after installing KB4474419 on a vista sp2 iso, CurrentBuild is 6002 and CurrentBuildNumber is 6003
    build_ver=$(get_current_version_key CurrentBuildNumber)

    # rev_ver
    # in practice win10 winver reads the revision from UBR
    # a vista sp2 iso has no UBR; it only appears once a monthly rollup is installed
    if ! rev_ver=$(get_current_version_key UBR 2>/dev/null); then
        rev_ver=$(get_current_version_key BuildLabEx | cut -d. -f2)
    fi

    echo "Version: $nt_ver.$build_ver.$rev_ver" >&2
    apk del hivex-perl
}

is_elts() {
    [ -n "$elts" ] && [ "$elts" = 1 ]
}

is_need_set_ssh_keys() {
    [ -s /configs/ssh_keys ]
}

is_need_change_ssh_port() {
    [ -n "$ssh_port" ] && ! [ "$ssh_port" = 22 ]
}

is_need_change_rdp_port() {
    [ -n "$rdp_port" ] && ! [ "$rdp_port" = 3389 ]
}

is_need_manual_set_dnsv6() {
    # is it possible to be static and still have rdnss?
    ! is_have_ipv6 && return $FALSE
    is_dhcpv6 && return $FALSE
    is_staticv6 && return $TRUE
    is_slaac && ! is_enable_other_flag &&
        { ! is_have_rdnss || { is_have_rdnss && is_windows && ! is_windows_support_rdnss; }; }
}

get_current_dns() {
    mark=$(
        case "$1" in
        4) echo . ;;
        6) echo : ;;
        esac
    )
    # the debian 11 initrd has no xargs or awk
    # the debian 12 initrd has no xargs
    if false; then
        grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | grep -F "$mark" | cut -d '%' -f1
    else
        grep '^nameserver' /etc/resolv.conf | cut -d' ' -f2 | grep -F "$mark" | cut -d '%' -f1
    fi
}

to_upper() {
    tr '[:lower:]' '[:upper:]'
}

to_lower() {
    tr '[:upper:]' '[:lower:]'
}

del_cr() {
    sed 's/\r$//'
}

del_comment_lines() {
    sed '/^[[:space:]]*#/d'
}

del_empty_lines() {
    sed '/^[[:space:]]*$/d'
}

del_head_empty_lines_inplace() {
    # from the first line until ^[:space:] is found,
    # delete every blank line in that range
    sed -i '1,/[^[:space:]]/ { /^[[:space:]]*$/d }' "$@"
}

get_part_num_by_part() {
    dev_part=$1
    echo "$dev_part" | grep -o '[0-9]*' | tail -1
}

get_fallback_efi_file_name() {
    case $(arch) in
    x86_64) echo bootx64.efi ;;
    aarch64) echo bootaa64.efi ;;
    *) error_and_exit ;;
    esac
}

del_invalid_efi_entry() {
    info "del invalid EFI entry"
    apk add lsblk efibootmgr

    efibootmgr --quiet --remove-dups

    while read -r line; do
        part_uuid=$(echo "$line" | awk -F ',' '{print $3}')
        efi_index=$(echo "$line" | grep_efi_index)
        if ! lsblk -o PARTUUID | grep -q "$part_uuid"; then
            echo "Delete invalid EFI Entry: $line"
            efibootmgr --quiet --bootnum "$efi_index" --delete-bootnum
        fi
    done < <(efibootmgr | grep 'HD(.*,GPT,')
}

# reinstall.sh has a function of the same name
grep_efi_index() {
    awk '{print $1}' | sed -e 's/Boot//' -e 's/\*//'
}

# some machines may not fall back to bootx64.efi
# the alibaba cloud ECS boot menu has an EFI Shell entry
# appending bootx64.efi last would boot into the EFI Shell,
# so prepend it instead
add_default_efi_to_nvram() {
    info "add default EFI to nvram"

    apk add lsblk efibootmgr

    if efi_row=$(lsblk /dev/$xda -ro NAME,PARTTYPE,PARTUUID | grep -i "$EFI_UUID"); then
        efi_part_uuid=$(echo "$efi_row" | awk '{print $3}')
        efi_part_name=$(echo "$efi_row" | awk '{print $1}')
        efi_part_num=$(get_part_num_by_part "$efi_part_name")
        efi_file=$(get_fallback_efi_file_name)

        # create the entry, checking first whether it already exists
        # the check may not be necessary
        if true || ! efibootmgr | grep -i "HD($efi_part_num,GPT,$efi_part_uuid,.*)/File(\\\EFI\\\boot\\\\$efi_file)"; then
            efibootmgr --create \
                --disk "/dev/$xda" \
                --part "$efi_part_num" \
                --label "$efi_file" \
                --loader "\\EFI\\boot\\$efi_file"
        fi
    else
        # shellcheck disable=SC2154
        if [ "$confirmed_no_efi" = 1 ]; then
            echo 'Confirmed no EFI in previous step.'
        else
            # reinstall.sh already checked this, but could it be missed when the logical sector is larger than 512?
            # this check should take the logical sector size into account
            echo "
Warning: This machine is currently using EFI boot, but the main hard drive does not have an EFI partition.
If this machine supports Legacy BIOS boot (CSM), you can safely restart into the new system by running the reboot command.
If this machine does not support Legacy BIOS boot (CSM), you will not be able to enter the new system after rebooting.
"
            exit
        fi
    fi
}

unix2dos() {
    target=$1

    # try unix2dos in place first and fall back to cat, which preserves file permissions as far as possible
    if ! command unix2dos $target 2>/tmp/unix2dos.log; then
        # on error, remove the temp file unix2dos created
        rm "$(awk -F: '{print $2}' /tmp/unix2dos.log | xargs)"
        tmp=$(mktemp)
        cp $target $tmp
        command unix2dos $tmp
        # cat preserves the permissions
        cat $tmp >$target
        rm $tmp
    fi
}

insert_into_file() {
    local file=$1
    local location=$2
    local regex_to_find=$3
    shift 3

    if ! [ -f "$file" ]; then
        error_and_exit "File not found: $file"
    fi

    # grep -E by default
    if [ $# -eq 0 ]; then
        set -- -E
    fi

    if [ "$location" = head ]; then
        bak=$(mktemp)
        cp $file $bak
        cat - $bak >$file
    else
        line_num=$(grep "$@" -n "$regex_to_find" "$file" | cut -d: -f1)

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

get_eths() {
    (
        cd /dev/netconf
        ls
    )
}

is_distro_like_debian() {
    [ "$distro" = debian ] || [ "$distro" = kali ]
}

create_ifupdown_config() {
    conf_file=$1

    rm -f $conf_file

    if is_distro_like_debian; then
        cat <<EOF >>$conf_file
source /etc/network/interfaces.d/*

EOF
    fi

    # Generate the lo configuration
    cat <<EOF >>$conf_file
auto lo
iface lo inet loopback
EOF

    # ethx
    for ethx in $(get_eths); do
        mode=auto
        # shellcheck disable=SC2154
        if false; then
            if { [ "$distro" = debian ] && [ "$releasever" -ge 12 ]; } ||
                [ "$distro" = kali ]; then
                # alice + allow-hotplug is problematic
                # problem 1, debian 9/10/11/12:
                # if ethx in /etc/networking/interfaces differs at first boot from what it was at install time,
                # the NIC does not come up even when fix-eth-name.sh ran successfully before the networking service
                # to reproduce: during install, rename enp3s0 in /etc/networking/interfaces to something else
                # problem 2, debian 9/10/11:
                # the NIC comes up automatically after a reboot, but systemctl restart networking takes it down
                # likely cause: /lib/systemd/system/networking.service has nothing hotplug related, while debian 12+ does
                if [ -f /etc/network/devhotplug ] && grep -wo "$ethx" /etc/network/devhotplug; then
                    mode=allow-hotplug
                fi
            fi

            # if is_have_cmd udevadm; then
            #     enpx=$(udevadm test-builtin net_id /sys/class/net/$ethx 2>&1 | grep ID_NET_NAME_PATH= | cut -d= -f2)
            # fi
        fi

        # on dmit debian the NIC name differs between the normal and cloud kernels, so a rename is needed
        # at install time  ens18
        # normal kernel    ens18
        # cloud kernel     enp6s18
        # https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=928923

        # header
        get_netconf_to mac_addr
        {
            echo
            # this is a marker used by fix-eth-name; do not remove it
            # shellcheck disable=SC2154
            echo "# mac $mac_addr"
            echo $mode $ethx
        } >>$conf_file

        # ipv4
        if is_dhcpv4; then
            echo "iface $ethx inet dhcp" >>$conf_file

        elif is_staticv4; then
            get_netconf_to ipv4_addr
            get_netconf_to ipv4_gateway
            cat <<EOF >>$conf_file
iface $ethx inet static
    address $ipv4_addr
    gateway $ipv4_gateway
EOF
            # dns
            if list=$(get_current_dns 4); then
                for dns in $list; do
                    cat <<EOF >>$conf_file
    dns-nameservers $dns
EOF
                done
            fi
        fi

        # ipv6
        has_ipv6_iface=false
        if is_slaac; then
            echo "iface $ethx inet6 auto" >>$conf_file
            has_ipv6_iface=true
        elif is_dhcpv6; then
            # debian 13 uses ifupdown + dhcpcd-base
            # with both inet and inet6 set to dhcp, dhcpv4 is lost after a reboot
            # a manual systemctl restart networking fixes it
            # removing dhcpcd-base and installing isc-dhcp-client (as a debian 12 to 13 upgrade does) loses dhcpv6 instead
            if { [ "$distro" = debian ] && [ "$releasever" -ge 13 ]; } ||
                [ "$distro" = kali ]; then
                echo "iface $ethx inet6 auto" >>$conf_file
            else
                echo "iface $ethx inet6 dhcp" >>$conf_file
            fi
            has_ipv6_iface=true
        elif is_staticv6; then
            get_netconf_to ipv6_addr
            get_netconf_to ipv6_gateway
            cat <<EOF >>$conf_file
iface $ethx inet6 static
    address $ipv6_addr
    gateway $ipv6_gateway
EOF
            has_ipv6_iface=true
            # debian 9
            # ipv4 supports a static onlink gateway
            # ipv6 does not; it must be added with post-up. The dynamic case is untested
            # ipv6 also does not support ip route add default via xxx onlink directly
            if [ "$distro" = debian ] && [ "$releasever" -le 9 ]; then
                # debian skips post-up when adding the gateway fails,
                # so it must be either gateway or post-up, not both

                # comment out the last line, which is the gateway
                sed -Ei '$s/^( *)/\1# /' "$conf_file"
                cat <<EOF >>$conf_file
    post-up ip route add $ipv6_gateway dev $ethx
    post-up ip route add default via $ipv6_gateway dev $ethx
EOF
            fi

            # extra IPv6 addresses (those whose subnet does not contain the gateway)
            get_netconf_to ipv6_extra_addrs
            if [ -n "$ipv6_extra_addrs" ]; then
                (
                    IFS=','
                    for _addr in $ipv6_extra_addrs; do
                        echo "    post-up ip -6 addr add $_addr dev $ethx" >>$conf_file
                    done
                )
            fi
        fi
        # accept_ra/autoconf are iface options
        # if no IPv6 iface stanza was generated for this NIC,
        # add a manual stanza first so ifupdown does not report a misplaced option
        if ! $has_ipv6_iface &&
            { should_disable_accept_ra || should_disable_autoconf; } &&
            [ "$distro" != alpine ]; then
            echo "iface $ethx inet6 manual" >>$conf_file
        fi
        # dns
        # the case where ipv6 exists but dns still needs setting
        if is_need_manual_set_dnsv6; then
            for dns in $(get_current_dns 6); do
                cat <<EOF >>$conf_file
    dns-nameserver $dns
EOF
            done
        fi

        # disable ra
        if should_disable_accept_ra; then
            if [ "$distro" = alpine ]; then
                cat <<EOF >>$conf_file
    pre-up echo 0 >/proc/sys/net/ipv6/conf/$ethx/accept_ra
EOF
            else
                cat <<EOF >>$conf_file
    accept_ra 0
EOF
            fi
        fi

        # disable autoconf
        if should_disable_autoconf; then
            if [ "$distro" = alpine ]; then
                cat <<EOF >>$conf_file
    pre-up echo 0 >/proc/sys/net/ipv6/conf/$ethx/autoconf
EOF
            else
                cat <<EOF >>$conf_file
    autoconf 0
EOF
            fi
        fi
    done
}

newline_to_comma() {
    tr '\n' ','
}

space_to_newline() {
    sed 's/ /\n/g'
}

trim() {
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

quote_word() {
    sed -E 's/([^[:space:]]+)/"\1"/g'
}

quote_line() {
    awk '{print "\""$0"\""}'
}

add_space() {
    space_count=$1

    spaces=$(printf '%*s' "$space_count" '')
    sed "s/^/$spaces/"
}

# Not rigorous; use with care
nix_replace() {
    local key=$1
    local value=$2
    local type=$3
    local file=$4
    local key_ value_

    key_=$(echo "$key" | sed 's \. \\\. g') # change . into \.

    if [ "$type" = array ]; then
        local value_="[ $value ]"
    fi

    sed -i "s/$key_ =.*/$key = $value_;/" "$file"
}

install_alpine() {
    info "install alpine"

    need_ram=512
    swap_size=$(get_need_swap_size $need_ram)
    [ "$swap_size" -gt 0 ] && hack_lowram=true || hack_lowram=false

    # alpine detects the firmware it needs during installation
    # https://github.com/alpinelinux/alpine-conf/blob/3.18.1/setup-disk.in#L421
    # but it cannot do so without modloop,
    # so record the firmware packages in use before deleting modloop
    fw_pkgs=$(get_alpine_firmware_pkgs)

    if $hack_lowram; then
        # preload the required modules
        if rc-service -q modloop status; then
            modules="ext4 vfat nls_utf8 nls_cp437"
            for mod in $modules; do
                modprobe $mod
            done
        # crc32c is the same as crc32c-intel
        # loading crc32c on a machine without sse4.2 fails with modprobe: ERROR: could not insert 'crc32c_intel': No such device
            modprobe crc32c || modprobe crc32c-generic
        fi

        # remove modloop to free memory
        ensure_service_stopped modloop
        rm -f /lib/modloop-lts /lib/modloop-virt
    fi

    # on a bios machine, automatic partitioning by setup-disk creates a boot partition,
    # so partition manually instead
    create_part
    mount_part_basic_layout /os /os/boot/efi

    # Create swap
    if $hack_lowram; then
        create_swap $swap_size /os/swapfile
    fi

    # Network configuration
    create_ifupdown_config /etc/network/interfaces
    echo
    cat -n /etc/network/interfaces
    echo

    # in the arm netboot initramfs init,
    # an hwclock service is added when rtc hardware is detected, otherwise swclock is used
    # that choice is copied into the installed system as well
    # but once chrooted from the initramfs into the real system, the rtc hardware is detectable
    # so switch to hwclock manually to fix this
    rc-update del swclock boot || true
    rc-update add hwclock boot

    # installing via setup-alpine enables the following services
    # https://github.com/alpinelinux/alpine-conf/blob/3.18.1/setup-alpine.in#L229

    # boot
    rc-update add networking boot
    rc-update add seedrng boot

    # default
    rc-update add crond
    if [ -e /dev/input/event0 ]; then
        rc-update add acpid
    fi

    # use the virt kernel on a VM
    if is_virt; then
        kernel_flavor="virt"
    else
        kernel_flavor="lts"
    fi

    # Reset to the official repository configuration
    # some machines cannot reach the mirror list and error out
    if false; then
        true >/etc/apk/repositories
        setup-apkrepos -1
    fi

    # setup-disk installs grub but skips adding the boot entry to nvram
    # this stops machines that do not fall back to bootx64.efi from failing
    if is_efi; then
        apk add efibootmgr
        sed -i 's/--no-nvram//' "$(which setup-disk)"
    fi

    # Install to disk
    # alpine defaults to syslinux (except under efi); force grub so the script can reinstall again later
    KERNELOPTS="$(get_ttys console=)"
    export KERNELOPTS
    export BOOTLOADER="grub"
    setup-disk -m sys -k $kernel_flavor /os

    # Remove the packages setup-disk pulled in automatically
    apk del e2fsprogs dosfstools efibootmgr grub*

    # if /proc is not mounted:

    # 1. chroot /os setup-keymap us us fails
    # grep: /proc/filesystems: No such file or directory

    # 2. installing firmware microcode triggers grub-probe, which fails when not mounted
    # Executing grub-2.12-r5.trigger
    # /usr/sbin/grub-probe: error: failed to get canonical path of `/dev/vda1'.
    # ERROR: grub-2.12-r5.trigger: script exited with error 1

    mount_pseudo_fs /os

    # the initramfs of an azure nvme instance needs the pci_hyperv driver added
    if [ -d /sys/module/pci_hyperv ] &&
        get_drivers "/sys/block/$xda" | grep -qx pci_hyperv; then
        echo 'kernel/drivers/pci/controller/pci-hyperv.ko*' >/os/etc/mkinitfs/features.d/pci-hyperv.modules
        if ! grep -q 'pci-hyperv' /os/etc/mkinitfs/mkinitfs.conf; then
            # find the line starting with features=" and change the final " into pci-hyperv"
            sed -i '/features="/s/"$/ pci-hyperv"/' /os/etc/mkinitfs/mkinitfs.conf
        fi
        chroot /os mkinitfs -k "$(basename /os/lib/modules/*-*)"
    fi

    # Install the applications only after installing to disk,
    # to avoid using up Live OS memory

    # Network
    # udhcpc
    # trap 1: ip -4 addr cannot tell whether the address came from dhcp
    # trap 2: the networking service does not run udhcpc6
    # trap 3: udhcpc6 cannot obtain dhcpv6 on h3c cloud desktops

    # dhcpcd
    # trap 1: slaac enables privacy extensions by default, so the ip differs from the provider panel

    # slaac option 1: udhcpc + rdnssd
    # slaac option 2: dhcpcd + privacy extensions disabled
    # dhcpv6 option: dhcpcd

    # use the dhcpcd option for everything:
    # 1 no change to /etc/network/interfaces is needed; it follows the ra and uses slaac and dhcpv6 automatically
    # 2 rdnss support is built in
    # 3 the only thing left to do is disable privacy extensions

    # Install dhcpcd
    chroot /os apk add dhcpcd
    chroot /os sed -i '/^slaac private/s/^/#/' /etc/dhcpcd.conf
    chroot /os sed -i '/^#slaac hwaddr/s/^#//' /etc/dhcpcd.conf

    # Install the other components
    chroot /os setup-keymap us us
    chroot /os setup-timezone -i Asia/Shanghai
    # 3.21 defaults to chrony
    # 3.22 defaults to busybox ntp
    printf '\n' | chroot /os setup-ntp || true

    # Set the public key
    add_user_if_need /os
    if is_need_set_ssh_keys; then
        set_ssh_keys_and_del_password /os
    fi

    # alpine 3.24+
    # the extra tty0 must be removed from /etc/inittab
    # otherwise vnc shows two login prompts at boot, one on tty0 and one on tty1

    # sed finds the "# enable login on alternative console" line,
    # N reads the next line into the pattern space,
    # then \ntty0: is matched
    sed -i '
/^# enable login on alternative console$/{
    N
    /\ntty0:/d
}
' /os/etc/inittab

    # Download fix-eth-name
    download "$confhome/fix-eth-name.sh" /os/fix-eth-name.sh
    download "$confhome/fix-eth-name.initd" /os/etc/init.d/fix-eth-name
    chmod +x /os/etc/init.d/fix-eth-name
    chroot /os rc-update add fix-eth-name boot

    # Install frpc
    if ls /configs/frpc.* >/dev/null 2>&1; then
        chroot /os apk add frp
        # chroot rc-update add defaults to sysinit
        # but without chroot it defaults to default
        chroot /os rc-update add frpc boot
        cp -f /configs/frpc.* /os/etc/frp/
    fi

    # setup-disk selects the firmware automatically, but perhaps not the microcode?
    # https://github.com/alpinelinux/alpine-conf/blob/3.18.1/setup-disk.in#L421
    if fw_pkgs="$fw_pkgs $(get_ucode_firmware_pkgs)" && [ -n "$fw_pkgs" ]; then
        chroot /os apk add $fw_pkgs
    fi

    # on 3.19 and later, a non-efi system needs grub installed manually
    if ! is_efi; then
        chroot /os grub-install --target=i386-pc /dev/$xda
    fi

    # add an fwsetup entry to the efi grub
    chroot /os update-grub

    # whether to keep swap
    if [ -e /os/swapfile ]; then
        if false; then
            echo "/swapfile swap swap defaults 0 0" >>/os/etc/fstab
            ln -sf /etc/init.d/swap /os/etc/runlevels/boot/swap
        else
            swapoff -a
            rm /os/swapfile
        fi
    fi
}

get_cpu_vendor() {
    cpu_vendor=$(grep 'vendor_id' /proc/cpuinfo | head -1 | awk '{print $NF}')
    case "$cpu_vendor" in
    GenuineIntel) echo intel ;;
    AuthenticAMD) echo amd ;;
    *) echo other ;;
    esac
}

min() {
    printf "%d\n" "$@" | sort -n | head -n 1
}

# Set the thread count
# take the smaller of the cpu core count and the memory per thread
get_build_threads() {
    threads_per_mb=$1

    threads_by_core=$(nproc)
    threads_by_ram=$(($(get_approximate_ram_size) / threads_per_mb))
    [ $threads_by_ram -eq 0 ] && threads_by_ram=1
    min $threads_by_ram $threads_by_core
}

add_newline() {
    # shellcheck disable=SC1003
    case "$1" in
    head | start) sed -e '1s/^/\n/' ;;
    tail | end) sed -e '$a\\' ;;
    both) sed -e '1s/^/\n/' -e '$a\\' ;;
    esac
}

add_systemd_service() {
    local os_dir=$1
    local service_name=$2

    download "$confhome/$service_name.service" "$os_dir/etc/systemd/system/$service_name.service"
    chroot "$os_dir" systemctl enable "$service_name.service"

    # aosc runs preset-all on first boot,
    # so the preset state of fix-eth-name must be set
    # otherwise /etc/systemd/system/multi-user.target.wants/fix-eth-name.service is removed at first boot
    # /etc/systemd/system-preset/ usually has to be created, so do not put it there

    # it may be /usr/lib/systemd/system-preset/ or /lib/systemd/system-preset/
    if [ -d "$os_dir/usr/lib/systemd/system-preset" ]; then
        echo "enable $service_name.service" >"$os_dir/usr/lib/systemd/system-preset/01-$service_name.preset"
    else
        echo "enable $service_name.service" >"$os_dir/lib/systemd/system-preset/01-$service_name.preset"
    fi
}

add_fix_eth_name_systemd_service() {
    local os_dir=$1

    # systemctl daemon-reload is unnecessary,
    # because under chroot it just prints Running in chroot, ignoring command 'daemon-reload'
    download "$confhome/fix-eth-name.sh" "$os_dir/fix-eth-name.sh"
    add_systemd_service "$os_dir" fix-eth-name
}

get_frpc_url() {
    wget "$confhome/get-frpc-url.sh" -O- | sh -s "$@"
}

add_frpc_systemd_service_if_need() {
    local os_dir=$1

    if ls /configs/frpc.* >/dev/null 2>&1; then
        mkdir -p "$os_dir/usr/local/bin"
        mkdir -p "$os_dir/usr/local/etc/frpc"

        # Download frpc
        # note the downloaded frpc is not owned by root:root
        frpc_url=$(get_frpc_url linux)
        basename=$(echo "$frpc_url" | awk -F/ '{print $NF}' | sed 's/\.tar\.gz//')
        download "$frpc_url" "$os_dir/frpc.tar.gz"
        # busybox tar does not support wildcards
        # tar: */frpc: not found in archive
        tar xzf "$os_dir/frpc.tar.gz" "$basename/frpc" -O >"$os_dir/usr/local/bin/frpc"
        rm -f "$os_dir/frpc.tar.gz"
        chmod a+x "$os_dir/usr/local/bin/frpc"

        # frpc conf
        cp -f /configs/frpc.* "$os_dir/usr/local/etc/frpc/"

        # Add the service
        add_systemd_service "$os_dir" frpc
    fi
}

get_fs_of_mount_point() {
    local mount_point=$1

    if ! [ "$mount_point" = / ]; then
        # remove any trailing /
        mount_point=$(printf "%s" "$mount_point" | sed 's,/*$,,')
    fi

    # findmnt must be installed
    # findmnt "$mount_point" -rno FSTYPE
    mount | awk -v mp="$1" '$3==mp {print $5}' | grep .
}

basic_init() {
    local os_dir=$1

    # not usable at this point
    # chroot $os_dir timedatectl set-timezone Asia/Shanghai
    # Failed to create bus connection: No such file or directory

    # debian 11 has no systemd-firstboot
    if is_have_cmd_on_disk $os_dir systemd-firstboot; then
        if chroot $os_dir systemd-firstboot --help | grep -wq '\--force'; then
            chroot $os_dir systemd-firstboot --timezone=Asia/Shanghai --force
        else
            chroot $os_dir systemd-firstboot --timezone=Asia/Shanghai
        fi
    fi

    # gentoo does not create machine-id automatically
    clear_machine_id $os_dir

    # sshd
    chroot $os_dir ssh-keygen -A

    sshd_enabled=false
    sshs="sshd.service ssh.service sshd.socket ssh.socket"
    for i in $sshs; do
        if chroot $os_dir systemctl -q is-enabled $i; then
            sshd_enabled=true
            break
        fi
    done
    if ! $sshd_enabled; then
        for i in $sshs; do
            if chroot $os_dir systemctl -q enable $i; then
                break
            fi
        done
    fi

    if is_need_change_ssh_port; then
        change_ssh_port $os_dir $ssh_port
    fi

    # public key / password
    add_user_if_need "$os_dir"
    if is_need_set_ssh_keys; then
        set_ssh_keys_and_del_password $os_dir
        change_ssh_conf_for_key_login $os_dir
    else
        change_user_password $os_dir
        change_ssh_conf_for_password_login $os_dir
    fi

    # Download fix-eth-name.service
    # needed even with net.ifnames=0,
    # because the NIC order may differ between alpine live and the target system
    add_fix_eth_name_systemd_service $os_dir

    # frpc
    add_frpc_systemd_service_if_need $os_dir
}

install_arch_family() {
    info "install $distro"

    network_app=systemd-networkd

    set_locale() {
        echo "C.UTF-8 UTF-8" >>$os_dir/etc/locale.gen
        chroot $os_dir locale-gen
    }

    # shellcheck disable=SC2317
    install_arch() {
        # Add swap
        create_swap_if_ram_less_than 1024 $os_dir/swapfile

        if false; then
            local alpine_rootfs=/
            apk add arch-install-scripts
        else
            local alpine_rootfs=$os_dir/alpine
            create_alpine_rootfs_with_arch_install_scripts "$alpine_rootfs" true "$os_dir"
        fi

        # so that /etc/pacman.conf is unmodified on a second run
        if [ -f $alpine_rootfs/etc/pacman.conf.orig ]; then
            cp $alpine_rootfs/etc/pacman.conf.orig $alpine_rootfs/etc/pacman.conf
        else
            cp $alpine_rootfs/etc/pacman.conf $alpine_rootfs/etc/pacman.conf.orig
        fi

        # Configure the repo
        insert_into_file $alpine_rootfs/etc/pacman.conf before '\[core\]' <<EOF
SigLevel = Never
ParallelDownloads = 5
EOF
        cat <<EOF >>$alpine_rootfs/etc/pacman.conf
[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
EOF
        mkdir -p $alpine_rootfs/etc/pacman.d
        # shellcheck disable=SC2016
        case "$(uname -m)" in
        x86_64) dir='$repo/os/$arch' ;;
        aarch64) dir='$arch/$repo' ;;
        esac
        # shellcheck disable=SC2154
        echo "Server = $mirror/$dir" >$alpine_rootfs/etc/pacman.d/mirrorlist

        # Install the system
        # partition tools (including fsck.xxx) are needed so the initramfs can check the partition data
        pkgs="base grub openssh"

        # efi fs
        if is_efi; then
            pkgs="$pkgs efibootmgr dosfstools"
        fi

        # root fs
        case $(get_fs_of_mount_point "$os_dir") in
        xfs) pkgs="$pkgs xfsprogs" ;;
        ext4) pkgs="$pkgs e2fsprogs" ;;
        btrfs) pkgs="$pkgs btrfs-progs" ;;
        esac

        if [ "$(uname -m)" = aarch64 ]; then
            pkgs="$pkgs archlinuxarm-keyring"
        fi
        if ! [ "$username" = root ]; then
            pkgs="$pkgs sudo"
        fi

        # retry to survive network problems
        if [ "$alpine_rootfs" = / ]; then
            retry 5 pacstrap -K "$os_dir" $pkgs
            killall -q gpg-agent || true
            apk del arch-install-scripts
        else
            retry 5 chroot "$alpine_rootfs" pacstrap -K "/parent" $pkgs
            killall -q gpg-agent || true
            umount -R "$alpine_rootfs/parent"
            remove_alpine_rootfs "$alpine_rootfs"
        fi

        # dns
        cp_resolv_conf $os_dir

        # Mount the pseudo filesystems
        mount_pseudo_fs $os_dir

        # the locale must be set before installing the kernel, otherwise this appears:
        # ==> Creating gzip-compressed initcpio image: '/boot/initramfs-linux.img'
        # bsdtar: bsdtar: Failed to set default locale
        # Failed to set default locale
        set_locale
        if [ "$(uname -m)" = aarch64 ]; then
            chroot $os_dir pacman-key --lsign-key builder@archlinuxarm.org
        fi

        # firmware + microcode
        if fw_pkgs=$(get_ucode_firmware_pkgs) && [ -n "$fw_pkgs" ]; then
            chroot $os_dir pacman -Syu --noconfirm $fw_pkgs
        fi

        # arm has several kernel choices and defaults to linux-aarch64, so --noconfirm is required
        chroot $os_dir pacman -Syu --noconfirm linux
    }

    # shellcheck disable=SC2317
    local os_dir=/os

    # Mount the partitions
    mount_part_basic_layout /os /os/efi

    # Install the system
    install_$distro

    # installing arch leaves a gpg-agent process running
    killall -q gpg-agent || true

    # Initialize
    if false; then
        # preset-all adds many services and increases memory use by tens of MB
        chroot $os_dir systemctl preset-all
    fi

    # Network configuration
    case "$network_app" in
    systemd-networkd)
        chroot $os_dir systemctl enable systemd-networkd
        chroot $os_dir systemctl enable systemd-resolved

        apk add cloud-init
        # a second run would error out
        useradd systemd-network || true
        create_cloud_init_network_config net.cfg
        cat -n net.cfg
        # -D gentoo would be correct, but alpine's cloud-init package has no gentoo config
        cloud-init devel net-convert -p net.cfg -k yaml -d out -D alpine -O networkd

        # note the name is 10-cloud-init-eth*.network; fix-eth-name.sh looks the config file up by that name
        cp out/etc/systemd/network/10-cloud-init-eth*.network $os_dir/etc/systemd/network/

        # remove the NIC name match
        sed -i '/^Name=/d' $os_dir/etc/systemd/network/10-cloud-init-eth*.network

        # remove "Generated by cloud-init. Changes will be lost."
        # and remove the leading blank line
        sed -i '/^# Generated by cloud-init/d' $os_dir/etc/systemd/network/10-cloud-init-eth*.network
        del_head_empty_lines_inplace $os_dir/etc/systemd/network/10-cloud-init-eth*.network

        # Clean up
        rm -rf net.cfg out
        apk del cloud-init

        # Show the network configuration
        cat -n $os_dir/etc/systemd/network/10-cloud-init-eth*.network
        ;;
    network-manager)
        chroot $os_dir systemctl enable NetworkManager

        # alpine's cloud-init can generate the Network Manager configuration directly
        create_cloud_init_network_config /net.cfg
        create_network_manager_config /net.cfg "$os_dir"
        rm /net.cfg
        ;;
    esac

    # the arch network configuration is generated by the alpine cloud-init
    # that cloud-init is new enough, so the onlink gateway needs no fixing

    basic_init $os_dir

    # use the ntp built into systemd
    # TODO: vm agent + random number generator

    # grub
    if is_efi; then
        # arch recommends mounting efi at /efi
        chroot $os_dir grub-install --efi-directory=/efi
        chroot $os_dir grub-install --efi-directory=/efi --removable
    else
        chroot $os_dir grub-install /dev/$xda
    fi

    # cmdline + generate grub.cfg
    if [ -d $os_dir/etc/default/grub.d ]; then
        file=$os_dir/etc/default/grub.d/tty.cfg
    else
        file=$os_dir/etc/default/grub
    fi
    ttys_cmdline=$(get_ttys console=)
    echo GRUB_CMDLINE_LINUX=\"\$GRUB_CMDLINE_LINUX $ttys_cmdline\" >>$file
    chroot $os_dir grub-mkconfig -o /boot/grub/grub.cfg

    # fstab
    # the efi entry can be left out of fstab; systemd automount handles it
    # fstab starts with usage notes, so append with >>
    local alpine_rootfs=$os_dir/alpine
    create_alpine_rootfs_with_arch_install_scripts "$alpine_rootfs" true "$os_dir"
    # genfstab needs findmnt and similar tools
    retry 5 chroot "$alpine_rootfs" apk add util-linux
    chroot "$alpine_rootfs" genfstab -U /parent | sed '/swap/d' >>$os_dir/etc/fstab
    umount -R "$alpine_rootfs/parent"
    remove_alpine_rootfs "$alpine_rootfs"

    # remove resolv.conf, otherwise systemd-resolved cannot create the symlink
    rm_resolv_conf $os_dir

    # remove swap
    swapoff -a
    rm -rf $os_dir/swapfile
}

get_http_file_size() {
    url=$1

    # a url redirect may yield several Content-Length headers; take the last
    wget --spider -S "$url" 2>&1 | grep 'Content-Length:' |
        tail -1 | awk '{print $2}' | grep .
}

get_url_hash() {
    url=$1

    echo "$url" | md5sum | awk '{print $1}'
}

aria2c() {
    if ! is_have_cmd aria2c; then
        apk add aria2
    fi

    # stdbuf is in the coreutils package
    if ! is_have_cmd stdbuf; then
        apk add coreutils
    fi

    # show the url
    show_url_in_args "$@" >&2

    # Download the tracker list
    # variables cannot be saved from a subshell, so write to a file
    if echo "$@" | grep -Eq 'magnet:|\.torrent' && ! [ -f "/tmp/trackers" ]; then
        # download on its own line, otherwise a failure would not be reported
        # it contains blank lines
        # txt=$(wget -O- https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt | grep .)
        # txt=$(wget -O- https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt | grep .)
        txt=$(wget -O- https://cf.trackerslist.com/best.txt | grep .)
        # sed removes the trailing comma
        echo "$txt" | newline_to_comma | sed 's/,$//' >/tmp/trackers
    fi

    # --dht-entry-point=router.bittorrent.com:6881 \
    # --dht-entry-point=dht.transmissionbt.com:6881 \
    # --dht-entry-point=router.utorrent.com:6881 \
    retry 5 5 stdbuf -oL -eL aria2c \
        -x4 \
        --seed-time=0 \
        --allow-overwrite=true \
        --summary-interval=0 \
        --max-tries 1 \
        --bt-tracker="$([ -f "/tmp/trackers" ] && cat /tmp/trackers)" \
        "$@"
}

download_torrent_by_magnet() {
    url=$1
    dst=$2

    url_hash=$(get_url_hash "$url")

    mkdir -p /tmp/bt/$url_hash

    # -o bt.torrent cannot be used to set the filename
    aria2c "$url" \
        --bt-metadata-only=true \
        --bt-save-metadata=true \
        -d /tmp/bt/$url_hash

    mv /tmp/bt/$url_hash/*.torrent "$dst"
    rm -rf /tmp/bt/$url_hash
}

get_torrent_path_by_magnet() {
    echo "/tmp/bt/$(get_url_hash "$1").torrent"
}

get_bt_file_size() {
    url=$1

    torrent="$(get_torrent_path_by_magnet $url)"
    download_torrent_by_magnet "$url" "$torrent" >&2

    # list the size of the first file
    # idx|path/length
    # ===+===========================================================================
    #   1|./zh-cn_windows_11_consumer_editions_version_24h2_updated_jan_2025_x64_dvd_7a8e5a29.iso
    #    |6.1GiB (6,557,558,784)

    aria2c --show-files=true "$torrent" |
        grep -F -A1 '  1|./' | tail -1 | grep -o '(.*)' | sed -E 's/[(),]//g' | grep .
}

get_link_file_size() {
    if is_magnet_link "$1" >&2; then
        get_bt_file_size "$1"
    else
        get_http_file_size "$1"
    fi
}

pipe_extract() {
    # alpine busybox ships gzip, but the official build may perform better
    case "$img_type_warp" in
    xz | gzip | zstd)
        apk add $img_type_warp
        "$img_type_warp" -dc
        ;;
    tar)
        apk add tar
        tar x -O
        ;;
    tar.*)
        type=$(echo "$img_type_warp" | cut -d. -f2)
        apk add tar "$type"
        tar x "--$type" -O
        ;;
    '') cat ;;
    *) error_and_exit "Not supported img_type_warp: $img_type_warp" ;;
    esac
}

dd_raw_with_extract() {
    info "dd raw"

    # use the real wget: it shows a progress bar and has retry support
    apk add wget

    if ! wget $img -O- | pipe_extract >/dev/$xda 2>/tmp/dd_stderr; then
        # a vhd file has 512 bytes of trailing metadata that can be ignored
        if grep -iq 'No space' /tmp/dd_stderr; then
            apk add parted
            disk_size=$(get_disk_size /dev/$xda)
            disk_end=$((disk_size - 1))

            # an error here probably means the image is larger than the disk
            if last_part_end=$(parted -sf /dev/$xda 'unit b print' ---pretend-input-tty |
                del_empty_lines | tail -1 | awk '{print $3}' | sed 's/B//' | grep .); then

                echo "Last part end: $last_part_end"
                echo "Disk end:      $disk_end"

                if [ "$last_part_end" -le "$disk_end" ]; then
                    echo "Safely ignore no space error."
                    return
                fi
            fi
        fi
        error_and_exit "$(cat /tmp/dd_stderr)"
    fi
}

get_disk_sector_count() {
    # cat /proc/partitions
    blockdev --getsz "$1"
}

get_disk_size() {
    blockdev --getsize64 "$1"
}

get_disk_logic_sector_size() {
    blockdev --getss "$1"
}

is_4kn() {
    [ "$(blockdev --getss "/dev/$xda")" = 4096 ]
}

is_xda_gt_2t() {
    disk_size=$(get_disk_size /dev/$xda)
    disk_2t=$((2 * 1024 * 1024 * 1024 * 1024))
    [ "$disk_size" -gt "$disk_2t" ]
}

is_ends_with_digit() {
    [[ "$1" =~ [0-9]$ ]]
}

xda() {
    if [ -n "$1" ]; then
        if is_ends_with_digit "$xda"; then
            echo "${xda}p$1"
        else
            echo "${xda}$1"
        fi
    else
        echo "$xda"
    fi
}

create_part() {
    # used by everything except dd
    info "Create Part"

    # Partition tools
    apk add parted e2fsprogs
    if is_efi; then
        apk add dosfstools
    fi

    # Wipe the partition table
    # https://github.com/bin456789/reinstall/issues/638
    apk add wipefs
    wipefs -a -f /dev/$xda
    apk del wipefs

    # shellcheck disable=SC2154
    if [ "$distro" = windows ]; then
        if ! size_bytes=$(get_link_file_size "$iso"); then
            # default value; the largest iso today is under 8g
            size_bytes=$((8 * 1024 * 1024 * 1024))
        fi

        # size the partition from the iso size
        # 200m covers the driver/filesystem overhead plus the pagefile
        # in theory boot.wim could be deleted from the installer partition, removing the need for the extra 200m, but
        # 1. vista/2008 cannot delete boot.wim
        # 2. we do not know it is vista/2008 before downloading the image, since --image-name is free-form
        # so the extra 200m is added regardless
        # note the unit must be MiB here, because border is calculated in MiB below
        part_size="$((size_bytes / 1024 / 1024 + 200))MiB"

        apk add ntfs-3g-progs
        # ntfs3 does not need fuse, but wimmount does, so keep it
        modprobe fuse ntfs3
        if is_efi; then
            # efi
            parted /dev/$xda -s -- \
                mklabel gpt \
                mkpart '" "' fat32 1MiB 1025MiB \
                mkpart '" "' fat32 1025MiB 1041MiB \
                mkpart '" "' ntfs 1041MiB -${part_size} \
                mkpart '" "' ntfs -${part_size} 100% \
                set 1 boot on \
                set 2 msftres on \
                set 3 msftdata on
            update_part

            mkfs.fat -n efi "/dev/$(xda 1)"                   #1 efi
            dd if=/dev/zero of="/dev/$(xda 2)" bs=1M count=16 #2 msr
            mkfs.ntfs -f -F -L os "/dev/$(xda 3)"             #3 os
            mkfs.ntfs -f -F -L installer "/dev/$(xda 4)"      #4 installer
        else
            # a bios + mbr boot disk can use at most 2t
            if is_xda_gt_2t; then
                border=$((2 * 1024 * 1024 - ${part_size%MiB}))MiB
                max_usable_size=2TiB
            else
                border=-${part_size}
                max_usable_size=100%
            fi
            parted /dev/$xda -s -- \
                mklabel msdos \
                mkpart primary ntfs 1MiB ${border} \
                mkpart primary ntfs ${border} ${max_usable_size} \
                set 1 boot on
            update_part

            mkfs.ntfs -f -F -L os "/dev/$(xda 1)"        #1 os
            mkfs.ntfs -f -F -L installer "/dev/$(xda 2)" #2 installer
        fi
    elif is_use_cloud_image; then
        installer_part_size="$(get_cloud_image_part_size)"
        # these systems copy files rather than using dd
        if [ "$distro" = centos ] || [ "$distro" = almalinux ] || [ "$distro" = rocky ] ||
            [ "$distro" = oracle ] || [ "$distro" = redhat ] ||
            [ "$distro" = anolis ] || [ "$distro" = opencloudos ] || [ "$distro" = openeuler ] ||
            [ "$distro" = ubuntu ]; then
            # the fs here is unused; the target system\'s own tool does the formatting
            fs=ext4
            if is_efi; then
                parted /dev/$xda -s -- \
                    mklabel gpt \
                    mkpart '" "' fat32 1MiB 101MiB \
                    mkpart '" "' $fs 101MiB -$installer_part_size \
                    mkpart '" "' ext4 -$installer_part_size 100% \
                    set 1 esp on
                update_part

                mkfs.fat -n efi "/dev/$(xda 1)"           #1 efi
                echo                                      #2 os uses the target system's own formatting tool
                mkfs.ext4 -F -L installer "/dev/$(xda 3)" #3 installer
            else
                parted /dev/$xda -s -- \
                    mklabel gpt \
                    mkpart '" "' ext4 1MiB 2MiB \
                    mkpart '" "' $fs 2MiB -$installer_part_size \
                    mkpart '" "' ext4 -$installer_part_size 100% \
                    set 1 bios_grub on
                update_part

                echo                                      #1 bios_boot
                echo                                      #2 os uses the target system's own formatting tool
                mkfs.ext4 -F -L installer "/dev/$(xda 3)" #3 installer
            fi
        else
            # use dd with qcow2
            # fedora debian opensuse arch gentoo
            parted /dev/$xda -s -- \
                mklabel gpt \
                mkpart '" "' ext4 1MiB -$installer_part_size \
                mkpart '" "' ext4 -$installer_part_size 100%
            update_part

            mkfs.ext4 -F -L os "/dev/$(xda 1)"        #1 os
            mkfs.ext4 -F -L installer "/dev/$(xda 2)" #2 installer
        fi
    elif [ "$distro" = alpine ] || [ "$distro" = arch ]; then
        # alpine itself disables 64bit ext4
        # https://gitlab.alpinelinux.org/alpine/alpine-conf/-/blob/3.18.1/setup-disk.in?ref_type=tags#L908
        # and alpine's extlinux is incompatible with 64bit ext4
        [ "$distro" = alpine ] && ext4_opts="-O ^64bit" || ext4_opts=
        if is_efi; then
            # efi
            parted /dev/$xda -s -- \
                mklabel gpt \
                mkpart '" "' fat32 1MiB 101MiB \
                mkpart '" "' ext4 101MiB 100% \
                set 1 boot on
            update_part

            mkfs.fat "/dev/$(xda 1)"                #1 efi
            mkfs.ext4 -F $ext4_opts "/dev/$(xda 2)" #2 os
        elif is_xda_gt_2t; then
            # bios > 2t
            parted /dev/$xda -s -- \
                mklabel gpt \
                mkpart '" "' ext4 1MiB 2MiB \
                mkpart '" "' ext4 2MiB 100% \
                set 1 bios_grub on
            update_part

            echo                                    #1 bios_boot
            mkfs.ext4 -F $ext4_opts "/dev/$(xda 2)" #2 os
        else
            # bios
            parted /dev/$xda -s -- \
                mklabel msdos \
                mkpart primary ext4 1MiB 100% \
                set 1 boot on
            update_part

            mkfs.ext4 -F $ext4_opts "/dev/$(xda 1)" #1 os
        fi
    else
        # install a red hat derivative or ubuntu
        # for red hat this is a temporary partition table: at install time every partition except installer is recreated at its default size
        # for ubuntu it is the final table, because the ubuntu installer cannot resize individual partitions, only rebuild the whole table
        # a 2g installer partition formatted fat just fits the ubuntu-22.04.3 iso, whereas ext4 does not without tuning
        if [ "$distro" = ubuntu ]; then
            if ! size_bytes=$(get_http_file_size "$iso"); then
                # default value, assuming a 3g iso
                size_bytes=$((3 * 1024 * 1024 * 1024))
            fi
            installer_part_size="$(get_part_size_mb_for_file_size_b $size_bytes)MiB"
        else
            # redhat
            installer_part_size=2GiB
        fi

        # centos 7 cannot mount an ext4 formatted by alpine,
        # so this feature must be disabled
        ext4_opts="-O ^metadata_csum"
        apk add dosfstools

        if is_efi; then
            # efi
            parted /dev/$xda -s -- \
                mklabel gpt \
                mkpart '" "' fat32 1MiB 1025MiB \
                mkpart '" "' ext4 1025MiB -$installer_part_size \
                mkpart '" "' ext4 -$installer_part_size 100% \
                set 1 boot on
            update_part

            mkfs.fat -n efi "/dev/$(xda 1)"                      #1 efi
            mkfs.ext4 -F -L os "/dev/$(xda 2)"                   #2 os
            mkfs.ext4 -F -L installer $ext4_opts "/dev/$(xda 3)" #2 installer
        elif is_xda_gt_2t; then
            # bios > 2t
            parted /dev/$xda -s -- \
                mklabel gpt \
                mkpart '" "' ext4 1MiB 2MiB \
                mkpart '" "' ext4 2MiB -$installer_part_size \
                mkpart '" "' ext4 -$installer_part_size 100% \
                set 1 bios_grub on
            update_part

            echo                                                 #1 bios_boot
            mkfs.ext4 -F -L os "/dev/$(xda 2)"                   #2 os
            mkfs.ext4 -F -L installer $ext4_opts "/dev/$(xda 3)" #3 installer
        else
            # bios
            parted /dev/$xda -s -- \
                mklabel msdos \
                mkpart primary ext4 1MiB -$installer_part_size \
                mkpart primary ext4 -$installer_part_size 100% \
                set 1 boot on
            update_part

            mkfs.ext4 -F -L os "/dev/$(xda 1)"                   #1 os
            mkfs.ext4 -F -L installer $ext4_opts "/dev/$(xda 2)" #2 installer
        fi
        update_part
    fi

    update_part

    # alpine removes the partition tools to stop a 256M machine running out of memory
    # setup-disk /dev/sda keeps the formatting tools, so keep them too
    if [ "$distro" = alpine ]; then
        apk del parted
    fi
}

umount_pseudo_fs() {
    local os_dir
    os_dir=$(realpath "$1")

    dirs="/proc /sys /dev /run"
    regex=$(echo "$dirs" | sed 's, ,|,g')
    if mounts=$(mount | grep -Ew "on $os_dir($regex)" | awk '{print $3}' | tac); then
        for mount in $mounts; do
            echo "umount $mount"
            umount $mount
        done
    fi
}

mount_pseudo_fs() {
    local os_dir=$1

    mkdir -p $os_dir/proc/ $os_dir/sys/ $os_dir/dev/ $os_dir/run/

    # https://wiki.archlinux.org/title/Chroot#Using_chroot
    mount -t proc /proc $os_dir/proc/
    mount -t sysfs /sys $os_dir/sys/
    mount --rbind /dev $os_dir/dev/
    mount --rbind /run $os_dir/run/
    if is_efi; then
        mount --rbind /sys/firmware/efi/efivars $os_dir/sys/firmware/efi/efivars/
    fi
}

create_cloud_init_network_config() {
    ci_file=$1
    recognize_static6=${2:-true}
    recognize_ipv6_types=${3:-true}

    info "Create Cloud-init network config"

    # guard against the file not being created
    mkdir -p "$(dirname "$ci_file")"
    touch "$ci_file"

    apk add yq-go

    need_set_dns4=false
    need_set_dns6=false

    config_id=0
    for ethx in $(get_eths); do
        get_netconf_to mac_addr

        # shellcheck disable=SC2154
        yq -i ".network.version=1 |
           .network.config[$config_id].type=\"physical\" |
           .network.config[$config_id].name=\"$ethx\" |
           .network.config[$config_id].mac_address=(\"$mac_addr\" | . style=\"single\")
           " $ci_file

        subnet_id=0

        # ipv4
        if is_dhcpv4; then
            yq -i ".network.config[$config_id].subnets[$subnet_id] = {\"type\": \"dhcp4\"}" $ci_file
            subnet_id=$((subnet_id + 1))
        elif is_staticv4; then
            need_set_dns4=true
            get_netconf_to ipv4_addr
            get_netconf_to ipv4_gateway
            yq -i ".network.config[$config_id].subnets[$subnet_id] = {
                    \"type\": \"static\",
                    \"address\": \"$ipv4_addr\",
                    \"gateway\": \"$ipv4_gateway\" }
                    " $ci_file

            # older cloud-init versions have a bug:
            # some read dns only from the first form of the config, others from the second,
            # so write both
            # https://github.com/canonical/cloud-init/commit/1b8030e0c7fd6fbff7e38ad1e3e6266ae50c83a5
            for cur in $(get_current_dns 4); do
                yq -i ".network.config[$config_id].subnets[$subnet_id].dns_nameservers += [\"$cur\"]" $ci_file
            done
            subnet_id=$((subnet_id + 1))
        fi

        # ipv6
        # slaac:  ipv6_slaac
        # └─enable_other_flag: ipv6_dhcpv6-stateless
        # dhcpv6: ipv6_dhcpv6-stateful

        # ipv6
        if is_slaac; then
            if $recognize_ipv6_types; then
                if is_enable_other_flag; then
                    type=ipv6_dhcpv6-stateless
                else
                    type=ipv6_slaac
                fi
            else
                type=dhcp6
            fi
            yq -i ".network.config[$config_id].subnets[$subnet_id] = {\"type\": \"$type\"}" $ci_file

        elif is_dhcpv6; then
            if $recognize_ipv6_types; then
                type=ipv6_dhcpv6-stateful
            else
                type=dhcp6
            fi
            yq -i ".network.config[$config_id].subnets[$subnet_id] = {\"type\": \"$type\"}" $ci_file

        elif is_staticv6; then
            get_netconf_to ipv6_addr
            get_netconf_to ipv6_gateway
            if $recognize_static6; then
                type_ipv6_static=static6
            else
                type_ipv6_static=static
            fi
            yq -i ".network.config[$config_id].subnets[$subnet_id] = {
                    \"type\": \"$type_ipv6_static\",
                    \"address\": \"$ipv6_addr\",
                    \"gateway\": \"$ipv6_gateway\" }
                    " $ci_file
        fi
        # autoconf = false cannot be set?
        if should_disable_accept_ra; then
            yq -i ".network.config[$config_id].accept-ra = false" $ci_file
        fi

        # the case where ipv6 exists but dns still needs setting
        if is_need_manual_set_dnsv6; then
            need_set_dns6=true
            for cur in $(get_current_dns 6); do
                yq -i ".network.config[$config_id].subnets[$subnet_id].dns_nameservers += [\"$cur\"]" $ci_file
            done
        fi

        config_id=$((config_id + 1))
    done

    if $need_set_dns4 || $need_set_dns6; then
        yq -i ".network.config[$config_id].type=\"nameserver\"" $ci_file
        if $need_set_dns4; then
            for cur in $(get_current_dns 4); do
                yq -i ".network.config[$config_id].address += [\"$cur\"]" $ci_file
            done
        fi
        if $need_set_dns6; then
            for cur in $(get_current_dns 6); do
                yq -i ".network.config[$config_id].address += [\"$cur\"]" $ci_file
            done
        fi
        # if network.config[$config_id] has no address, remove it so older cloud-init does not error
        yq -i "del(.network.config[$config_id] | select(has(\"address\") | not))" $ci_file
    fi

    apk del yq-go

    # Show the file
    info "Cloud-init network config"
    cat -n $ci_file >&2
}

# Proved useless in practice: the generated machine-id is always the same
# and the lightsail centos 9 template has an identical machine-id too, so a shared id is clearly not a problem
clear_machine_id() {
    local os_dir=$1

    # https://www.freedesktop.org/software/systemd/man/latest/machine-id.html
    # gentoo does not create this file automatically
    echo uninitialized >$os_dir/etc/machine-id

    # https://build.opensuse.org/projects/Virtualization:Appliances:Images:openSUSE-Leap-15.5/packages/kiwi-templates-Minimal/files/config.sh?expand=1
    rm -f $os_dir/var/lib/systemd/random-seed
}

# note that anolis 7 has this file, which may interfere with our configuration?
# /etc/cloud/cloud.cfg.d/aliyun_cloud.cfg -> /sys/firmware/qemu_fw_cfg/by_name/etc/cloud-init/vendor-data/raw
download_cloud_init_config() {
    local os_dir=$1
    recognize_static6=$2
    recognize_ipv6_types=$3

    ci_file=$os_dir/etc/cloud/cloud.cfg.d/99_fallback.cfg
    download $confhome/deprecated/cloud-init.yaml $ci_file
    # remove the comment lines except the first
    sed -i '1!{/^[[:space:]]*#/d}' $ci_file

    # Change the password
    # sed cannot be used to substitute it, because it contains special characters
    content=$(cat $ci_file)
    echo "${content//@PASSWORD@/$(get_password_linux_sha512)}" >$ci_file

    # Change the ssh port
    if is_need_change_ssh_port; then
        sed -i "s/@SSH_PORT@/$ssh_port/g" $ci_file
    else
        sed -i "/@SSH_PORT@/d" $ci_file
    fi

    # swapfile
    # skip when the partition table already has a swapfile, e.g. arch
    if ! grep -w swap $os_dir/etc/fstab; then
        cat <<EOF >>$ci_file
swap:
  filename: /swapfile
  size: auto
EOF
    fi

    create_cloud_init_network_config "$ci_file" "$recognize_static6" "$recognize_ipv6_types"
}

get_image_state() {
    local os_dir=$1
    local image_state=

    # if the dd image trimmed State.ini, read it from the registry instead
    if state_ini=$(find_file_ignore_case $os_dir/Windows/Setup/State/State.ini); then
        image_state=$(grep -i '^ImageState=' $state_ini | cut -d= -f2 | tr -d '\r')
    fi
    if [ -z "$image_state" ]; then
        apk add hivex-perl
        hive=$(find_file_ignore_case $os_dir/Windows/System32/config/SOFTWARE)
        image_state=$(hivexget $hive '\Microsoft\Windows\CurrentVersion\Setup\State' ImageState)
        apk del hivex-perl
    fi

    if [ -n "$image_state" ]; then
        echo "$image_state"
    else
        error_and_exit "Cannot get ImageState."
    fi
}

modify_windows() {
    local os_dir=$1
    info "Modify Windows"

    # https://learn.microsoft.com/windows-hardware/manufacture/desktop/windows-setup-states
    # https://learn.microsoft.com/troubleshoot/azure/virtual-machines/reset-local-password-without-agent
    # https://learn.microsoft.com/windows-hardware/manufacture/desktop/add-a-custom-script-to-windows-setup

    # decide between SetupComplete and group policy
    image_state=$(get_image_state "$os_dir")
    echo "ImageState: $image_state"

    if [ "$image_state" = IMAGE_STATE_COMPLETE ]; then
        use_gpo=true
    else
        use_gpo=false
    fi

    # bat list
    bats=

    # 1. rdp port
    if is_need_change_rdp_port; then
        create_win_change_rdp_port_script $os_dir/windows-change-rdp-port.bat "$rdp_port"
        bats="$bats windows-change-rdp-port.bat"
    fi

    # 2. allow ping
    if is_allow_ping; then
        download $confhome/windows-allow-ping.bat $os_dir/windows-allow-ping.bat
        bats="$bats windows-allow-ping.bat"
    fi

    # 3. merge partitions
    # unattend.xml may already set ExtendOSPartition, but running resize does no harm
    download $confhome/windows-resize.bat $os_dir/windows-resize.bat
    bats="$bats windows-resize.bat"

    # 4. network settings
    for ethx in $(get_eths); do
        create_win_set_netconf_script $os_dir/windows-set-netconf-$ethx.bat
        bats="$bats windows-set-netconf-$ethx.bat"
    done

    # 5. set the user password to never expire (iso install only)
    #    on an Azure Windows instance the initial password also never expires
    #    administrator accounts do not expire by default
    if [ "$distro" = "windows" ] && ! is_administrator_username "$username"; then
        # both forms work, but the syntax is peculiar

        # the second line must have no leading space
        cat <<EOF >$os_dir/windows-set-user-password-never-expires.bat
wmic useraccount where name="$username" set passwordexpires=false || ^
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Set-LocalUser -Name '$username' -PasswordNeverExpires \$true"
del "%~f0"
EOF
        # the second line must have a space before ||
        cat <<EOF >$os_dir/windows-set-user-password-never-expires.bat
wmic useraccount where name="$username" set passwordexpires=false ^
  || powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Set-LocalUser -Name '$username' -PasswordNeverExpires \$true"
del "%~f0"
EOF
        unix2dos $os_dir/windows-set-user-password-never-expires.bat
        bats="$bats windows-set-user-password-never-expires.bat"
    fi

    # 6. frp
    if ls /configs/frpc.* >/dev/null 2>&1; then
        if [ "$(get_windows_arch_from_windows_drive "$os_dir" | to_lower)" = x86 ]; then
            os_bit=32
        else
            os_bit=64
        fi
        mkdir -p "$os_dir/frpc/"
        url=$(get_frpc_url windows "$nt_ver" "$os_bit")
        download "$url" $os_dir/frpc/frpc.zip
        # -j strips the folder
        # -C matches filenames case-insensitively, but busybox zip does not support it
        unzip -o -j "$os_dir/frpc/frpc.zip" '*/frpc.exe' -d "$os_dir/frpc/"
        rm -f "$os_dir/frpc/frpc.zip"
        cp -f /configs/frpc.* "$os_dir/frpc/"
        download "$confhome/windows-frpc.xml" "$os_dir/frpc/frpc.xml"
        download "$confhome/windows-frpc.bat" "$os_dir/frpc/frpc.bat"
        bats="$bats frpc\frpc.bat"
    fi

    if $use_gpo; then
        # use group policy
        scripts_ini=$(get_path_in_correct_case $os_dir/Windows/System32/GroupPolicy/Machine/Scripts/scripts.ini)
        mkdir -p "$(dirname $scripts_ini)"
        gpt_ini=$(get_path_in_correct_case $os_dir/Windows/System32/GroupPolicy/gpt.ini)

        # back up the ini
        for file in $gpt_ini $scripts_ini; do
            if [ -f $file ]; then
                cp $file $file.orig
            fi
        done

        # gpt.ini
        cat >$gpt_ini <<EOF
[General]
gPCFunctionalityVersion=2
gPCMachineExtensionNames=[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]
Version=1
EOF
        unix2dos $gpt_ini

        # scripts.ini
        if ! [ -e $scripts_ini ]; then
            touch $scripts_ini
        fi

        if ! grep -F '[Startup]' $scripts_ini; then
            echo '[Startup]' >>$scripts_ini
        fi

        # note that without pipefail the exit code comes from the last command in the pipe
        if num=$(grep -Eo '^[0-9]+' $scripts_ini | sort -n | tail -1 | grep .); then
            num=$((num + 1))
        else
            num=0
        fi

        bats="$bats windows-del-gpo.bat"
        for bat in $bats; do
            echo "${num}CmdLine=%SystemDrive%\\$bat" >>$scripts_ini
            echo "${num}Parameters=" >>$scripts_ini
            num=$((num + 1))
        done
        cat $scripts_ini
        unix2dos $scripts_ini

        # windows-del-gpo.bat
        download $confhome/windows-del-gpo.bat $os_dir/windows-del-gpo.bat
    else
        # use SetupComplete
        setup_complete=$(get_path_in_correct_case $os_dir/Windows/Setup/Scripts/SetupComplete.cmd)
        mkdir -p "$(dirname $setup_complete)"

        # prepend to C:\Setup\Scripts\SetupComplete.cmd
        # call stops a child bat deleting itself and aborting the main script
        setup_complete_mod=$(mktemp)
        for bat in $bats; do
            echo "if exist %SystemDrive%\\$bat (call %SystemDrive%\\$bat)" >>$setup_complete_mod
        done

        # copy the original content
        if [ -f $setup_complete ]; then
            cat $setup_complete >>$setup_complete_mod
        fi

        unix2dos $setup_complete_mod

        # cat preserves the permissions
        cat $setup_complete_mod >$setup_complete

        # show the final content
        cat -n $setup_complete
    fi
}

get_axx64() {
    case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64) echo arm64 ;;
    esac
}

is_file_or_link() {
    # -e / -f return false for a broken symlink
    # -L returns true for a broken symlink
    [ -f $1 ] || [ -L $1 ]
}

cp_resolv_conf() {
    local os_dir=$1
    if is_file_or_link $os_dir/etc/resolv.conf &&
        ! is_file_or_link $os_dir/etc/resolv.conf.orig; then
        mv $os_dir/etc/resolv.conf $os_dir/etc/resolv.conf.orig
    fi
    cp -f /etc/resolv.conf $os_dir/etc/resolv.conf
}

rm_resolv_conf() {
    local os_dir=$1
    rm -f $os_dir/etc/resolv.conf $os_dir/etc/resolv.conf.orig
}

restore_resolv_conf() {
    local os_dir=$1
    if is_file_or_link $os_dir/etc/resolv.conf.orig; then
        mv -f $os_dir/etc/resolv.conf.orig $os_dir/etc/resolv.conf
    fi
}

keep_now_resolv_conf() {
    local os_dir=$1
    rm -f $os_dir/etc/resolv.conf.orig
}

# Adapted from https://github.com/alpinelinux/alpine-conf/blob/3.18.1/setup-disk.in#L421
get_alpine_firmware_pkgs() {
    # modloop must be present, otherwise modinfo errors out
    ensure_service_started modloop >&2

    # if it is not in its own folder, use linux-firmware-other
    # if it is in its own folder, use linux-firmware-xxx
    # if no firmware is needed, use linux-firmware-none
    firmware_pkgs=$(
        cd /sys/module && modinfo -F firmware -- * 2>/dev/null |
            awk -F/ '{print $1 == $0 ? "linux-firmware-other" : "linux-firmware-"$1}' |
            sort -u
    )

    # use command, because apk is overridden here to add >&2
    retry 5 command apk search --quiet --exact ${firmware_pkgs:-linux-firmware-none}
}

get_ucode_firmware_pkgs() {
    is_virt && return

    case "$distro" in
    centos | almalinux | rocky | oracle | redhat | anolis | opencloudos | openeuler) os=elol ;;
    *) os=$distro ;;
    esac

    case "$os-$(get_cpu_vendor)" in
    # alpine's linux-firmware is split into per-folder packages
    # setup-alpine installs the required firmware automatically (which does not work without modloop mounted)
    # https://github.com/alpinelinux/alpine-conf/blob/3.18.1/setup-disk.in#L421
    alpine-intel) echo intel-ucode ;;
    alpine-amd) echo amd-ucode ;;
    alpine-*) ;;

    debian-intel) echo firmware-linux intel-microcode ;;
    debian-amd) echo firmware-linux amd64-microcode ;;
    debian-*) echo firmware-linux ;;

    ubuntu-intel) echo linux-firmware intel-microcode ;;
    ubuntu-amd) echo linux-firmware amd64-microcode ;;
    ubuntu-*) echo linux-firmware ;;

    # kernel-firmware and kernel-firmware-intel cannot both be installed
    opensuse-intel) echo kernel-firmware ucode-intel ;;
    opensuse-amd) echo kernel-firmware ucode-amd ;;
    opensuse-*) echo kernel-firmware ;;

    arch-intel) echo linux-firmware intel-ucode ;;
    arch-amd) echo linux-firmware amd-ucode ;;
    arch-*) echo linux-firmware ;;



    fedora-intel) echo linux-firmware microcode_ctl ;;
    fedora-amd) echo linux-firmware amd-ucode-firmware microcode_ctl ;;
    fedora-*) echo linux-firmware microcode_ctl ;;

    elol-intel) echo linux-firmware microcode_ctl ;;
    elol-amd) echo linux-firmware microcode_ctl ;;
    elol-*) echo linux-firmware microcode_ctl ;;
    esac
}

chroot_systemctl_disable() {
    local os_dir=$1
    shift

    for unit in "$@"; do
        # if the argument has no dot, turn x into x.service
        if ! [[ "$unit" = "*.*" ]]; then
            unit=$i.service
        fi

        # debian 10 always exits 0
        if ! chroot $os_dir systemctl list-unit-files "$unit" 2>&1 | grep -Eq '^0 unit'; then
            chroot $os_dir systemctl disable "$unit"
        fi
    done
}

remove_or_disable_cloud_init() {
    local os_dir=$1

    if ! is_have_cmd_on_disk $os_dir cloud-init; then
        return
    fi

    info "Remove or Disable Cloud-Init"

    # ubuntu-server-minimal and ubuntu-cloud-minimal both include cloud-init
    # ubuntu installed from an iso has cloud-init as well
    # so do not remove ubuntu's cloud-init, just disable it

    # on an iso install, the first boot initializes the system via /etc/cloud/cloud.cfg.d/99-installer.cfg, which:
    #     1. creates the normal user and password and adds the ssh public key
    #     2. creates /etc/cloud/cloud-init.disabled

    if grep -iq ubuntu $os_dir/etc/os-release; then
        # mimic an iso-installed ubuntu: only create cloud-init.disabled, do not disable the services
        touch $os_dir/etc/cloud/cloud-init.disabled
    else
        # systemctl is-enabled cloud-init-hotplugd.service reports static
        # disable prints a pile of messages and cannot disable it anyway
        for unit in $(
            chroot $os_dir systemctl list-unit-files |
                grep -E '^(cloud-init|cloud-init-.*|cloud-config|cloud-final)\.(service|socket)' | grep enabled | awk '{print $1}'
        ); do
            # errors out when the service does not exist
            if chroot $os_dir systemctl -q is-enabled "$unit"; then
                chroot $os_dir systemctl disable "$unit"
            fi
        done

        for pkg_mgr in dnf yum zypper apt-get; do
            if is_have_cmd_on_disk $os_dir $pkg_mgr; then
                case $pkg_mgr in
                dnf | yum)
                    chroot $os_dir $pkg_mgr remove -y cloud-init
                    rm -f $os_dir/etc/cloud/cloud.cfg.rpmsave
                    ;;
                zypper)
                    # stop sudo being removed along with cloud-init
                    if ! [ "$username" = root ]; then
                        sed -i '/^sudo$/d' "$os_dir/var/lib/zypp/AutoInstalled"
                    fi
                    # -u is required for dependencies to be removed
                    chroot $os_dir zypper remove -y -u cloud-init cloud-init-config-suse
                    ;;
                apt-get)
                    # ubuntu 25.04 introduced cloud-init-base
                    chroot_apt_remove $os_dir cloud-init cloud-init-base
                    chroot_apt_autoremove $os_dir
                    ;;
                esac
                break
            fi
        done
    fi
}

disable_jeos_firstboot() {
    local os_dir=$1
    info "Disable JeOS Firstboot"

    # both methods work
    # https://github.com/openSUSE/jeos-firstboot?tab=readme-ov-file#usage

    rm -rf $os_dir/var/lib/YaST2/reconfig_system

    for name in jeos-firstboot jeos-firstboot-snapshot; do
        # errors out when the service does not exist
        chroot $os_dir systemctl disable "$name.service" 2>/dev/null || true
    done

    # optional
    # chroot $os_dir zypper remove -y -u jeos-firstboot
}

create_network_manager_config() {
    local source_cfg=$1
    local os_dir=$2
    info "Create Network-Manager config"

    # alpine's cloud-init can generate the Network Manager configuration directly
    apk add cloud-init
    cloud-init devel net-convert -p "$source_cfg" -k yaml -d /out -D alpine -O network-manager

    # the docs state explicitly that ipv6.method=dhcp cannot obtain a gateway
    # https://networkmanager.dev/docs/api/latest/nm-settings-nmcli.html#:~:text=false/no/off-,ipv6,-.method
    sed -i -e '/^may-fail=/d' -e 's/^method=dhcp/method=auto/' \
        /out/etc/NetworkManager/system-connections/cloud-init-eth*.nmconnection

    # remove "# Generated by cloud-init. Changes will be lost."
    # remove org.freedesktop.NetworkManager.origin=cloud-init
    # and remove the leading blank line
    sed -i \
        -e '/^# Generated by cloud-init/d' \
        -e '/^org\.freedesktop\.NetworkManager\.origin=cloud-init/d' \
        /out/etc/NetworkManager/system-connections/cloud-init-eth*.nmconnection
    del_head_empty_lines_inplace /out/etc/NetworkManager/system-connections/cloud-init-eth*.nmconnection

    cp /out/etc/NetworkManager/system-connections/cloud-init-eth*.nmconnection \
        $os_dir/etc/NetworkManager/system-connections/

    # Clean up
    rm -rf /out
    apk del cloud-init

    # Show the final file
    for file in "$os_dir"/etc/NetworkManager/system-connections/cloud-init-eth*.nmconnection; do
        cat -n "$file" >&2
    done
}

modify_linux() {
    local os_dir=$1
    info "Modify Linux"

    find_and_mount() {
        mount_point=$1
        mount_dev=$(awk "\$2==\"$mount_point\" {print \$1}" $os_dir/etc/fstab)
        mount_opts=$(awk "\$2==\"$mount_point\" {print \$4}" $os_dir/etc/fstab)
        if [ -n "$mount_dev" ]; then
            mount -o "$mount_opts" "$mount_dev" "$os_dir$mount_point"
        fi
    }

    # Fix the onlink gateway
    add_onlink_script_if_need() {
        for ethx in $(get_eths); do
            if is_staticv4 || is_staticv6; then
                fix_sh=cloud-init-fix-onlink.sh
                download "$confhome/deprecated/$fix_sh" "$os_dir/$fix_sh"
                insert_into_file "$ci_file" after '^runcmd:' <<EOF
  - bash "/$fix_sh" && rm -f "/$fix_sh"
EOF
                break
            fi
        done
    }

    # some images ship a default configuration, e.g. centos
    del_exist_sysconfig_NetworkManager_config $os_dir

    # fedora only (el/ol and their forks use the file-copy method)
    # 1. disable selinux and kdump
    # 2. add microcode and firmware
    if [ -f $os_dir/etc/redhat-release ]; then
        # avoid running out of memory while removing cloud-init / installing firmware
        create_swap_if_ram_less_than 2048 $os_dir/swapfile

        mount_pseudo_fs $os_dir

        # find_and_mount /boot
        # find_and_mount /boot/efi
        # the fedora fstab also has /home and /var, so use mount -a
        # otherwise the ssh public key cannot be written to /home/$username
        chroot $os_dir mount -a

        cp_resolv_conf $os_dir

        # alpine's cloud-init can generate the Network Manager configuration directly
        create_cloud_init_network_config /net.cfg
        create_network_manager_config /net.cfg "$os_dir"
        rm /net.cfg

        # TODO: remove once fedora 43 is EOL
        # removing cloud-init also removes its dependency netcat,
        # but removing netcat errors out,
        # so keep the netcat package
        # >>> Running %preun scriptlet: netcat-0:1.229-3.fc43.x86_64
        # >>> Error in %preun scriptlet: netcat-0:1.229-3.fc43.x86_64
        # >>> Scriptlet output:
        # >>> failed to create admindir: No such file or directory
        # >>> [RPM] %preun(netcat-1.229-3.fc43.x86_64) scriptlet failed, exit status 2
        # >>> [RPM] netcat-1.229-3.fc43.x86_64: erase failed
        if [ "$distro" = fedora ] && [ "$releasever" = 43 ]; then
            chroot $os_dir dnf mark user netcat -y
        fi
        remove_or_disable_cloud_init $os_dir

        disable_selinux $os_dir
        disable_kdump $os_dir

        if fw_pkgs=$(get_ucode_firmware_pkgs) && [ -n "$fw_pkgs" ]; then
            is_have_cmd_on_disk $os_dir dnf && mgr=dnf || mgr=yum
            chroot $os_dir $mgr install -y $fw_pkgs
        fi

        restore_resolv_conf $os_dir
    fi

    # debian
    # 1. switch repos when EOL
    # 2. fix network problems
    # 3. add microcode and firmware
    # note that ubuntu also has /etc/debian_version
    if [ "$distro" = debian ]; then
        # Fix the onlink gateway
        # add_onlink_script_if_need

        mount_pseudo_fs $os_dir
        cp_resolv_conf $os_dir
        find_and_mount /boot
        find_and_mount /boot/efi

        remove_or_disable_cloud_init $os_dir

        # get the currently enabled Components, needed below
        if [ -f $os_dir/etc/apt/sources.list.d/debian.sources ]; then
            comps=$(grep ^Components: $os_dir/etc/apt/sources.list.d/debian.sources | head -1 | cut -d' ' -f2-)
        else
            comps=$(grep '^deb ' $os_dir/etc/apt/sources.list | head -1 | cut -d' ' -f4-)
        fi

        # ELTS repo handling
        if is_elts; then
            # ELTS
            wget https://deb.freexian.com/extended-lts/archive-key.gpg \
                -O $os_dir/etc/apt/trusted.gpg.d/freexian-archive-extended-lts.gpg

            # shellcheck disable=SC1091
            codename=$({ . "$os_dir/etc/os-release" && echo "$VERSION_CODENAME"; })
            if [ -f $os_dir/etc/apt/sources.list.d/debian.sources ]; then
                cat <<EOF >$os_dir/etc/apt/sources.list.d/debian.sources
Types: deb
URIs: http://$deb_mirror
Suites: $codename
Components: $comps
Signed-By: /etc/apt/trusted.gpg.d/freexian-archive-extended-lts.gpg
EOF
            else
                echo "deb http://$deb_mirror $codename $comps" >$os_dir/etc/apt/sources.list
            fi
        fi

        # mark every kernel as automatically installed
        pkgs=$(chroot $os_dir apt-mark showmanual linux-image* linux-headers*)
        chroot $os_dir apt-mark auto $pkgs

        # install the appropriate kernel
        kernel_package=$kernel
        # shellcheck disable=SC2046
        # check whether the machine can use the cloud kernel
        if [[ "$kernel_package" = 'linux-image-cloud-*' ]] &&
            ! sh /can_use_cloud_kernel.sh "$xda" $(get_eths); then
            kernel_package=$(echo "$kernel_package" | sed 's/-cloud//')
        fi

        # this function already does apt-mark manual
        chroot_apt_install $os_dir "$kernel_package"

        # use autoremove to drop the non-optimal kernels
        chroot_apt_autoremove $os_dir

        # microcode + firmware
        if fw_pkgs=$(get_ucode_firmware_pkgs) && [ -n "$fw_pkgs" ]; then
            #  on debian 10 and 11, iucode-tool is in contrib
            #  on debian 12, iucode-tool is in main
            [ "$releasever" -ge 12 ] &&
                comps_to_add=non-free-firmware ||
                comps_to_add="contrib non-free"

            if [ -f $os_dir/etc/apt/sources.list.d/debian.sources ]; then
                file=$os_dir/etc/apt/sources.list.d/debian.sources
                search='^[# ]*Components:'
            else
                file=$os_dir/etc/apt/sources.list
                search='^[# ]*deb'
            fi

            for c in $comps_to_add; do
                if ! echo "$comps" | grep -wq "$c"; then
                    sed -Ei "/$search/s/$/ $c/" $file
                fi
            done

            chroot_apt_install $os_dir $fw_pkgs
        fi

        # on genericcloud the grub menu only appears at boot once these files are removed
        # https://salsa.debian.org/cloud-team/debian-cloud-images/-/tree/master/config_space/bookworm/files/etc/default/grub.d
        rm -f $os_dir/etc/default/grub.d/10_cloud.cfg
        rm -f $os_dir/etc/default/grub.d/15_timeout.cfg
        chroot $os_dir update-grub

        if true; then
            # when using the nocloud image
            chroot_apt_install $os_dir openssh-server
        else
            # when using the genericcloud image

            # restore the default configuration and create the key
            # cat $os_dir/usr/share/openssh/sshd_config $os_dir/etc/ssh/sshd_config
            # chroot $os_dir ssh-keygen -A
            rm -rf $os_dir/etc/ssh/sshd_config
            UCF_FORCE_CONFFMISS=1 chroot $os_dir dpkg-reconfigure openssh-server
        fi

        # the network manager shipped in the image
        # debian 11 ifupdown
        # debian 12 netplan + networkd + resolved
        # ifupdown dhcp does not support a /24 mask with an irregular gateway?

        # force the use of netplan
        if false && is_have_cmd_on_disk $os_dir netplan; then
            chroot_apt_install $os_dir netplan.io
            # errors out when the service does not exist
            chroot $os_dir systemctl disable networking resolvconf 2>/dev/null || true
            chroot $os_dir systemctl enable systemd-networkd systemd-resolved
            rm_resolv_conf $os_dir
            ln -sf ../run/systemd/resolve/stub-resolv.conf $os_dir/etc/resolv.conf
            if [ -f "$os_dir/etc/cloud/cloud.cfg.d/99_fallback.cfg" ]; then
                insert_into_file $os_dir/etc/cloud/cloud.cfg.d/99_fallback.cfg after '#cloud-config' <<EOF
system_info:
  network:
    renderers: [netplan]
    activators: [netplan]
EOF
            fi
        fi

        create_ifupdown_config $os_dir/etc/network/interfaces

        # ifupdown does not support rdnss
        # an iso install does not install rdnssd; it reads rdnss during installation and writes it to resolv.conf
        if false; then
            chroot_apt_install $os_dir rdnssd
        fi

        # the debian 10 and 11 cloud images install resolvconf
        # the debian 12 cloud image installs netplan and systemd-resolved
        # the cloud images configure the network through cloud-init, which is invisible to the user, so the official images can pick any network manager
        # but our users may want to configure the network by hand afterwards, so go back to ifupdown, the one an iso install uses

        # errors out when the service does not exist
        chroot $os_dir systemctl disable resolvconf systemd-networkd systemd-resolved 2>/dev/null || true

        chroot_apt_install $os_dir ifupdown
        chroot_apt_remove $os_dir resolvconf netplan.io systemd-resolved
        chroot_apt_autoremove $os_dir
        chroot $os_dir systemctl enable networking

        # when static, the networking service does not update resolv.conf from /etc/network/interfaces
        # when dynamic, isc-dhcp-client is used and updates resolv.conf automatically
        # note also that the debian iso does not install rdnssd
        keep_now_resolv_conf $os_dir
    fi

    # opensuse
    # 1. kernel-default-base lacks the nvme, gve, mlx5 and mana drivers, so switch to kernel-default
    # 2. add microcode and firmware
    # https://documentation.suse.com/smart/virtualization-cloud/html/minimal-vm/index.html
    if grep -q opensuse $os_dir/etc/os-release; then
        create_swap_if_ram_less_than 1024 $os_dir/swapfile
        mount_pseudo_fs $os_dir
        cp_resolv_conf $os_dir
        find_and_mount /boot
        find_and_mount /boot/efi

        disable_jeos_firstboot $os_dir

        # disable selinux
        disable_selinux $os_dir

        # opensuse leap 16.0 / tumbleweed use NetworkManager
        # alpine's cloud-init can generate the Network Manager configuration directly
        create_cloud_init_network_config /net.cfg
        create_network_manager_config /net.cfg "$os_dir"
        rm /net.cfg

        # pick the new kernel
        # only leap has kernel-azure
        if grep -iq leap $os_dir/etc/os-release && [ "$(get_cloud_vendor)" = azure ]; then
            target_kernel='kernel-azure'
        else
            target_kernel='kernel-default'
        fi

        # rpm -qi does not support wildcards
        origin_kernel=$(chroot $os_dir rpm -qa 'kernel-*' --qf '%{NAME}\n' | grep -v firmware)
        if ! [ "$(echo "$origin_kernel" | wc -l)" -eq 1 ]; then
            error_and_exit "Unexpected kernel installed: $origin_kernel"
        fi

        # 16.0 can have kernel-default-base and kernel-default installed together
        # tumbleweed cannot
        # so --force-resolution is needed to remove kernel-default-base automatically
        if ! [ "$origin_kernel" = "$target_kernel" ]; then
            # x86 requires a password to be set or it errors out; arm does not have this problem
            # Failed to get root password hash
            # Failed to import /etc/uefi/certs/76B6A6A0.crt
            # warning: %post(kernel-default-5.14.21-150500.55.83.1.x86_64) scriptlet failed, exit status 255
            need_password_workaround=false
            if grep -q '^root:[:!*]' $os_dir/etc/shadow; then
                need_password_workaround=true
            fi

            if $need_password_workaround; then
                echo "root:$(mkpasswd '')" | chroot $os_dir chpasswd -e
            fi
            # install the new kernel
            chroot $os_dir zypper install -y --force-resolution $target_kernel
            # remove the old kernel
            if chroot $os_dir rpm -q $origin_kernel; then
                chroot $os_dir zypper remove -y --force-resolution $origin_kernel
            fi
            if $need_password_workaround; then
                chroot $os_dir passwd -d -l root
            fi
        fi

        # firmware + microcode
        if fw_pkgs=$(get_ucode_firmware_pkgs) && [ -n "$fw_pkgs" ]; then
            chroot $os_dir zypper install -y $fw_pkgs
        fi

        # remove cloud-init last,
        # because generating the sysconfig network configuration needs the target system's cloud-init
        remove_or_disable_cloud_init $os_dir

        restore_resolv_conf $os_dir
    fi

    # arch cloud image
    if false && [ -f $os_dir/etc/arch-release ]; then
        # Fix the onlink gateway
        add_onlink_script_if_need

        # sync the certificates
        cp_resolv_conf $os_dir
        mount_pseudo_fs $os_dir
        chroot $os_dir pacman-key --init
        chroot $os_dir pacman-key --populate
        rm_resolv_conf $os_dir
    fi

    basic_init $os_dir

    # this should check whether basic_init ran and the network configuration files were created
    # if not, fall back to cloud-init

    # Show the final cloud-init configuration
    if [ -f "$ci_file" ]; then
        cat -n "$ci_file"
    fi

    # Remove swap
    swapoff -a
    rm -f $os_dir/swapfile
}

setup_nocloud() {
    local os_dir=$1
    info "Setup NoCloud"

    # 1. configure a NoCloud-only datasource
    mkdir -p "$os_dir/etc/cloud/cloud.cfg.d"
    cat >"$os_dir/etc/cloud/cloud.cfg.d/99-datasource.cfg" <<'EOF'
datasource_list: [ NoCloud, None ]
datasource:
  NoCloud:
    seedfrom: /var/lib/cloud/seed/nocloud/
    fs_label: null
EOF

    # 2. copy the seed files (already prepared on the host and packed into the initrd)
    mkdir -p "$os_dir/var/lib/cloud/seed/nocloud"
    cp /configs/cloud-data/* "$os_dir/var/lib/cloud/seed/nocloud/"

    # 3. make sure cloud-init is not disabled
    rm -f "$os_dir/etc/cloud/cloud-init.disabled"

    # 4. clear the old cloud-init state so it runs again on first boot
    rm -rf "$os_dir/var/lib/cloud/instance"
    rm -rf "$os_dir/var/lib/cloud/instances"
}

modify_os_on_disk() {
    only_process=$1
    info "Modify disk if is $only_process"

    update_part

    # when dd-ing linux there is no need to modify the disk contents (except in nocloud mode)
    if [ "$distro" = "dd" ] && [ "$only_process" != "nocloud" ] && ! lsblk -f /dev/$xda | grep ntfs; then
        return
    fi

    mkdir -p /os
    # Look for the system partition from the largest to the smallest
    # lsblk /dev/mmcblk0* lists mmcblk0boot0 and mmcblk0boot1
    # lsblk /dev/mmcblk0  does not
    for part in $(lsblk /dev/$xda --filter 'TYPE == "part"' --sort SIZE -no NAME | tac); do
        # btrfs mounts the default subvolume, or the root directory when there is none
        # the fedora cloud image has no default subvolume and the system lives in the root subvolume
        if mount -o ro /dev/$part /os; then
            if [ "$only_process" = linux ] || [ "$only_process" = nocloud ]; then
                if etc_dir=$({ ls -d /os/etc/ || ls -d /os/*/etc/; } 2>/dev/null); then
                    local os_dir
                    os_dir=$(dirname $etc_dir)
                    # remount read-write
                    mount -o remount,rw /os
                    if [ "$only_process" = nocloud ]; then
                        setup_nocloud $os_dir
                    else
                        modify_linux $os_dir
                    fi
                    return
                fi
            elif [ "$only_process" = windows ]; then
                # find is not very clever
                # find /mnt/c -iname windows -type d -maxdepth 1
                # find: /mnt/c/pagefile.sys: Permission denied
                # find: /mnt/c/swapfile.sys: Permission denied
                # shellcheck disable=SC1090
                # find_file_ignore_case is in this file too
                . <(wget -O- $confhome/windows-driver-utils.sh)
                if find_file_ignore_case /os/Windows/System32/ntoskrnl.exe >/dev/null 2>&1; then
                    # used elsewhere
                    is_windows() { true; }
                    # remount read-write, ignoring case
                    umount /os
                    if ! { mount -t ntfs3 -o nocase,rw /dev/$part /os &&
                        mount | grep -w 'on /os type' | grep -wq rw; }; then
                        # show a warning
                        warn "Can't normally mount windows partition /dev/$part as rw."
                        dmesg | grep -F "ntfs3($part):" || true
                        # the fallback may have mounted it read-only, so unmount first
                        if mount | grep -wq 'on /os type'; then
                            umount /os
                        fi
                        # try to repair it and force the mount
                        apk add ntfs-3g-progs
                        ntfsfix /dev/$part
                        apk del ntfs-3g-progs
                        mount -t ntfs3 -o nocase,rw,force /dev/$part /os
                    fi
                    # get the version number, used elsewhere
                    get_windows_version_from_windows_drive /os
                    modify_windows /os
                    return
                fi
            fi
            umount /os
        fi
    done
    error_and_exit "Can't find os partition."
}

get_need_swap_size() {
    need_ram=$1
    phy_ram=$(get_approximate_ram_size)

    if [ $need_ram -gt $phy_ram ]; then
        echo $((need_ram - phy_ram))
    else
        echo 0
    fi
}

create_swap_if_ram_less_than() {
    need_ram=$1
    swapfile=$2

    swapsize=$(get_need_swap_size $need_ram)
    if [ $swapsize -gt 0 ]; then
        create_swap $swapsize $swapfile
    fi
}

create_swap() {
    swapsize=$1
    swapfile=$2

    if ! grep $swapfile /proc/swaps; then
        # create the swapfile in a btrfs-compatible way
        truncate -s 0 $swapfile
        # a partition that does not support chattr +C prints an error but still exits 0
        chattr +C $swapfile 2>/dev/null
        fallocate -l ${swapsize}M $swapfile
        chmod 0600 $swapfile
        mkswap $swapfile
        swapon $swapfile
    fi
}

del_user_password_and_lock() {
    local os_dir=$1
    local username=$2

    # can a locked user still log in over ssh?
    # alpine         no
    # other systems  yes

    # with an empty root password and root not locked, can another user switch with su - root?
    # alpine         no
    # other systems  yes

    # centos 7 does not accept -d and -l in the same command
    # passwd: Only one of -l, -u, -d, -S may be specified.

    # Remove the password
    chroot "$os_dir" passwd -d "$username"

    # Lock the user
    if ! [ -e "$os_dir/etc/alpine-release" ]; then
        chroot "$os_dir" passwd -l "$username"
    fi

    # on alpine a locked user cannot log in over ssh,
    # because alpine does not enable pam by default
    # other systems do

    # without pam, a locked user cannot log in over ssh
    # with pam enabled, they can

    # alpine enables pam by installing openssh-server-pam
    # UsePAM yes need not be set, and would not be recognized anyway
    # localhost:~# sshd -G | grep -i pam
    # /etc/ssh/sshd_config line 88: Unsupported option UsePAM
}

set_ssh_keys_and_del_password() {
    local os_dir=$1

    info 'set ssh keys'

    if [ "$username" = root ]; then
        local user_home="/root"
    else
        local user_home="/home/$username"
    fi

    # Add the public key
    if true; then
        (
            umask 077
            mkdir -p "$os_dir/$user_home/.ssh"
            cat /configs/ssh_keys >"$os_dir/$user_home/.ssh/authorized_keys"
        )
        # chroot is required, otherwise the uid/gid are those of the alpine live os
        chroot "$os_dir" chown "$username:$username" "$user_home"
        chroot "$os_dir" chown "$username:$username" "$user_home/.ssh"
        chroot "$os_dir" chown "$username:$username" "$user_home/.ssh/authorized_keys"
    else
        (
            # if a bsd that cannot be chrooted is ever added, this could be used
            umask 077
            read -r owner group < \
                <(awk -F: -v user="$username" '$1==user {print $3,$4}' "$os_dir/etc/passwd")
            install -D \
                -m 600 \
                -o "$owner" \
                -g "$group" \
                /configs/ssh_keys \
                "$os_dir/$user_home/.ssh/authorized_keys"
        )
    fi

    # Remove the password / lock the user
    del_user_password_and_lock "$os_dir" "$username"

    # in the debian cloud image the root entry of /etc/shadow is
    # root:!unprovisioned:20591:0:99999:7:::
    # the first boot then stops at the set-root-password prompt and blocks the ssh service,
    # so clear the root password and lock it here
    if ! [ "$username" = root ] && is_have_cmd_on_disk "$os_dir" systemd-firstboot; then
        del_user_password_and_lock "$os_dir" root
    fi
}

_is_ssh_kv_effective() {
    local os_dir=$1
    local key=$2
    local value=$3

    # Work around a ubuntu 22.04 error
    # Missing privilege separation directory: /run/sshd
    if [ -d "$os_dir/run/sshd" ]; then
        we_create_run_sshd_dir=false
    else
        we_create_run_sshd_dir=true
        mkdir -p "$os_dir/run/sshd"
    fi

    # centos 7 / ubuntu 22.04 do not support -G
    if res=$(chroot "$os_dir" sshd -G 2>/dev/null || chroot "$os_dir" sshd -T 2>/dev/null); then
        # remove the one we created, to avoid leaving the permissions wrong
        if $we_create_run_sshd_dir; then
            rm -rf "$os_dir/run/sshd"
        fi
        printf "%s\n" "$res" | grep -Fxiq "$key $value"
    else
        error_and_exit "Failed to verify sshd config."
    fi
}

is_ssh_kv_effective() {
    local os_dir=$1
    local key=$2
    local value=$3

    if _is_ssh_kv_effective "$os_dir" "$key" "$value"; then
        return 0
    fi

    # with prohibit-password on centos 7, sshd -T reports without-password
    if [ "$(echo "$key" | to_lower)" = "permitrootlogin" ] && {
        [ "$(echo "$value" | to_lower)" = "prohibit-password" ] ||
            [ "$(echo "$value" | to_lower)" = "without-password" ]
    }; then
        if _is_ssh_kv_effective "$os_dir" "permitrootlogin" "prohibit-password" ||
            _is_ssh_kv_effective "$os_dir" "permitrootlogin" "without-password"; then
            return 0
        fi
    fi

    return 1
}

change_ssh_conf_if_different() {
    local os_dir=$1
    local key=$2
    local value=$3
    local sub_conf=$4
    if [ -z "$sub_conf" ]; then
        sub_conf=$(echo "01-$key.conf" | to_lower)
    fi

    # some distros ship certain settings already, e.g.
    # ubuntu:
    # cat /etc/ssh/sshd_config.d/60-cloudimg-settings.conf | grep -i PasswordAuthentication
    # PasswordAuthentication no

    # gentoo:
    # cat /etc/ssh/sshd_config.d/9999999gentoo-pam.conf | grep -i PasswordAuthentication
    # PasswordAuthentication no

    # 0. if the setting is already present, leave it alone to avoid needless changes
    if is_ssh_kv_effective "$os_dir" "$key" "$value"; then
        return
    fi

    if line="^$key .*" && grep -Exiq "$line" $os_dir/etc/ssh/sshd_config 2>/dev/null; then
        # 1. if sshd_config has this key uncommented, replace it
        sed -Ei "s/$line/$key $value/" $os_dir/etc/ssh/sshd_config
    elif include_line='^Include .*/etc/ssh/sshd_config.d' &&
        # 2. if sshd_config is set up to read sshd_config.d,
        #    write to sshd_config.d/01-xxx.conf

        # arch has no /etc/ssh/sshd_config.d/ folder
        # opensuse tumbleweed has no /etc/ssh/sshd_config
        #                       but does have /etc/ssh/sshd_config.d/
        #                       and /usr/etc/ssh/sshd_config
        { grep -iq "$include_line" $os_dir/etc/ssh/sshd_config ||
            grep -iq "$include_line" $os_dir/usr/etc/ssh/sshd_config; } 2>/dev/null; then
        mkdir -p $os_dir/etc/ssh/sshd_config.d/
        echo "$key $value" >"$os_dir/etc/ssh/sshd_config.d/$sub_conf"
    else
        # 3. write to sshd_config
        #    if sshd_config has this key (commented or not), replace it and drop the comment
        #    otherwise append
        line="^[# ]*$key .*"
        if grep -Exiq "$line" $os_dir/etc/ssh/sshd_config; then
            sed -Ei "s/$line/$key $value/" $os_dir/etc/ssh/sshd_config
        else
            echo "$key $value" >>$os_dir/etc/ssh/sshd_config
        fi
    fi

    # Verify that it worked
    if ! is_ssh_kv_effective "$os_dir" "$key" "$value"; then
        error_and_exit "Failed to set sshd config $key $value."
    fi
}

change_ssh_conf_for_key_login() {
    local os_dir=$1

    change_ssh_conf_if_different "$os_dir" PasswordAuthentication no

    # on centos 7 PermitRootLogin defaults to yes rather than prohibit-password
    if [ "$username" = root ]; then
        change_ssh_conf_if_different "$os_dir" PermitRootLogin prohibit-password
    fi
}

change_ssh_conf_for_password_login() {
    local os_dir=$1

    # installing openssh-server-config-rootlogin on opensuse 16/tumbleweed
    # generates /usr/etc/ssh/sshd_config.d/50-permit-root-login.conf
    # but if the user deletes that file, a package update may recreate it
    # so avoid this approach for now
    if false &&
        [ -f $os_dir/etc/os-release ] &&
        grep -iq opensuse $os_dir/etc/os-release; then
        chroot $os_dir zypper install -y openssh-server-config-rootlogin
    fi

    # PasswordAuthentication defaults to yes
    # but some distros set PasswordAuthentication no in sshd_config.d
    change_ssh_conf_if_different "$os_dir" PasswordAuthentication yes

    if [ "$username" = root ]; then
        change_ssh_conf_if_different "$os_dir" PermitRootLogin yes
    fi
}

change_ssh_port() {
    local os_dir=$1
    local ssh_port=$2

    change_ssh_conf_if_different "$os_dir" Port "$ssh_port"
}

# Not needed for now
add_user_if_need_for_alpine() {
    local os_dir=$1

    if ! grep -q "^$username:" "$os_dir/etc/passwd"; then
        #  -a  Create admin user. Add to wheel group and set up doas
        #  -u  Unlock the user automatically (eg. creating the user non-interactively
        #      with an ssh key for login)
        if is_need_set_ssh_keys; then
            chroot "$os_dir" setup-user -a -u -k "$(cat /configs/ssh_keys)" "$username"
        else
            chroot "$os_dir" setup-user -a -u "$username"
            change_user_password $os_dir
        fi
    fi
}

add_user_if_need() {
    local os_dir=$1

    # Add the user
    if ! grep -q "^$username:" "$os_dir/etc/passwd"; then
        # debian recommends adduser over useradd
        # https://manpages.debian.org/trixie/passwd/useradd.8.en.html
        # useradd is a low level utility for adding users.
        # On Debian, administrators should usually use adduser(8) instead.

        # adduser reads the default groups from /etc/adduser.conf,
        # but that value is usually blank

        # alpine
        if is_have_cmd_on_disk "$os_dir" adduser &&
            chroot "$os_dir" adduser --help 2>&1 | grep -Fq -- BusyBox; then
            chroot "$os_dir" adduser --disabled-password "$username"

        # debian/ubuntu
        elif is_have_cmd_on_disk "$os_dir" adduser &&
            chroot "$os_dir" adduser --help 2>&1 | grep -Fq -- '--disabled-password'; then
            chroot "$os_dir" adduser --disabled-password --comment '' "$username"

        # el
        elif is_have_cmd_on_disk "$os_dir" adduser &&
            chroot "$os_dir" adduser --help 2>&1 | grep -Fq -- '--password'; then
            chroot "$os_dir" adduser --password ! "$username"

        # arch/gentoo have no adduser by default
        else
            chroot "$os_dir" useradd -m "$username"
        fi
    fi

    # Add to the wheel/sudo group
    if ! [ "$username" = root ]; then
        if [ -e "$os_dir/etc/alpine-release" ]; then
            # alpine
            # https://github.com/alpinelinux/alpine-conf/blob/master/setup-user.in#L168

            # install doas
            chroot "$os_dir" apk add doas doas-sudo-shim
            mkdir -p "$os_dir/etc/doas.d"

            # add the user to the group
            chroot "$os_dir" addgroup "$username" wheel

            # doas: add the wheel group
            local file="$os_dir/etc/doas.d/20-wheel.conf"
            local content="permit persist :wheel"
            if ! grep -q "^$content" "$file" 2>/dev/null; then
                echo "$content" >>"$file"
            fi

            # doas: add a single nopass user
            echo "permit nopass $username" >"$os_dir/etc/doas.d/99-$username.conf"
        else
            # the wheel group is the usual one
            # debian/ubuntu have no wheel group, only sudo

            # tested on aws lightsail to see which groups the default user joins
            # debian       admin : admin adm dialout cdrom floppy sudo audio dip video plugdev
            # ubuntu       ubuntu : ubuntu adm cdrom sudo dip lxd
            # almalinux    ec2-user : ec2-user adm systemd-journal
            # opensuse     ec2-user : ec2-user

            # add the user to the group
            for group in \
                wheel sudo \
                adm dialout cdrom floppy audio dip video plugdev lxd systemd-journal; do
                if grep -q "^$group:" "$os_dir/etc/group"; then
                    # chroot "$os_dir" addgroup "$username" "$group"
                    chroot "$os_dir" usermod -aG "$group" "$username"
                fi
            done

            # sudo: gentoo has no /etc/sudoers.d even after installing sudo
            if ! [ -d "$os_dir/etc/sudoers.d" ]; then
                install -d -m 0750 "$os_dir/etc/sudoers.d"
            fi

            # sudo: add a single NOPASSWD user
            # https://wiki.archlinux.org/title/Sudo#Sudoers_default_file_permissions
            local file="$os_dir/etc/sudoers.d/99-$username"
            printf '%s\n' "$username ALL=(ALL) NOPASSWD:ALL" >"$file"
            chmod 0440 "$file"
        fi
    fi
}

change_user_password() {
    local os_dir=$1

    info 'change user password'

    if is_password_plaintext; then
        pam_d=$os_dir/etc/pam.d

        [ -f $pam_d/chpasswd ] && has_pamd_chpasswd=true || has_pamd_chpasswd=false

        if $has_pamd_chpasswd; then
            cp $pam_d/chpasswd $pam_d/chpasswd.orig

            # cat /etc/pam.d/chpasswd
            # @include common-password

            # cat /etc/pam.d/chpasswd
            # #%PAM-1.0
            # auth       include      system-auth
            # account    include      system-auth
            # password   substack     system-auth
            # -password   optional    pam_gnome_keyring.so use_authtok
            # password   substack     postlogin

            # follow /etc/pam.d/chpasswd to /etc/pam.d/system-auth,
            # then find the line with password and pam_unix.so, drop use_authtok and write it to /etc/pam.d/chpasswd
            files=$(grep -E '^(password|@include)' $pam_d/chpasswd | awk '{print $NF}' | sort -u)
            for file in $files; do
                if [ -f "$pam_d/$file" ] && line=$(grep ^password "$pam_d/$file" | grep -F pam_unix.so); then
                    echo "$line" | sed 's/use_authtok//' >$pam_d/chpasswd
                    break
                fi
            done
        fi

        # write it as two lines, otherwise an error would not stop execution
        plaintext=$(get_password_plaintext)
        printf '%s\n' "$username:$plaintext" | chroot $os_dir chpasswd

        if $has_pamd_chpasswd; then
            mv $pam_d/chpasswd.orig $pam_d/chpasswd
        fi
    else
        printf '%s\n' "$username:$(get_password_linux_sha512)" | chroot $os_dir chpasswd -e
    fi
}

disable_selinux() {
    local os_dir=$1

    # https://access.redhat.com/solutions/3176
    # centos7 also recommends putting the selinux switch on the cmdline
    # grep selinux=0 /usr/lib/dracut/modules.d/98selinux/selinux-loadpolicy.sh
    #     warn "To disable selinux, add selinux=0 to the kernel command line."
    if [ -f $os_dir/etc/selinux/config ]; then
        sed -i 's/^SELINUX=enforcing/SELINUX=disabled/g' $os_dir/etc/selinux/config
    fi

    # opensuse does not install grubby
    if is_have_cmd_on_disk $os_dir grubby; then
        # grubby only handles GRUB_CMDLINE_LINUX, not GRUB_CMDLINE_LINUX_DEFAULT
        # rocky has crashkernel=auto in GRUB_CMDLINE_LINUX_DEFAULT
        chroot $os_dir grubby --update-kernel ALL --args selinux=0

        # on el7 the grubby command above cannot set /etc/default/grub
        sed -i 's/selinux=1/selinux=0/' $os_dir/etc/default/grub
    else
        # there may be no selinux parameter, though current images do not have this problem
        # sed -Ei 's/[[:space:]]?(security|selinux|enforcing)=[^ ]*//g' $os_dir/etc/default/grub
        sed -i 's/selinux=1/selinux=0/' $os_dir/etc/default/grub

        # transactional-update grub.cfg can be used when a snapshot is needed
        chroot $os_dir grub2-mkconfig -o /boot/grub2/grub.cfg
    fi
}

disable_kdump() {
    local os_dir=$1

    # grubby only handles GRUB_CMDLINE_LINUX, not GRUB_CMDLINE_LINUX_DEFAULT
    # rocky has crashkernel=auto in GRUB_CMDLINE_LINUX_DEFAULT

    # a freshly installed kernel still has crashkernel, which looks like a bug
    # https://forums.rockylinux.org/t/how-do-i-remove-crashkernel-from-cmdline/13346
    # how this was verified:
    # yum remove --oldinstallonly   # remove the old kernels
    # rm -rf /boot/loader/entries/* # remove the boot entries
    # yum reinstall kernel-core     # reinstall the new kernel
    # cat /boot/loader/entries/*    # still has crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M

    chroot $os_dir grubby --update-kernel ALL --args crashkernel=no
    # on el7 the grubby command above cannot set /etc/default/grub
    sed -i 's/crashkernel=[^ "]*/crashkernel=no/' $os_dir/etc/default/grub
    if chroot $os_dir systemctl -q is-enabled kdump; then
        chroot $os_dir systemctl disable kdump
    fi
}

download_qcow() {
    apk add qemu-img
    info "Download qcow2 image"

    mkdir -p /installer
    mount /dev/disk/by-label/installer /installer

    qcow_file=/installer/cloud_image.qcow2
    if [ -n "$img_type_warp" ]; then
        # decompress while downloading, single-threaded
        # use the real wget for its progress bar
        apk add wget
        wget $img -O- | pipe_extract >$qcow_file
    else
        # multi-threaded download
        download "$img" "$qcow_file"
    fi
}

connect_qcow() {
    modprobe nbd nbds_max=1
    qemu-nbd -c /dev/nbd0 $qcow_file

    # a short wait is needed
    # https://github.com/canonical/cloud-utils/blob/main/bin/mount-image-callback
    while ! blkid /dev/nbd0; do
        echo "Waiting for qcow file to be mounted..."
        sleep 5
    done
}

disconnect_qcow() {
    if [ -f /sys/block/nbd0/pid ]; then
        qemu-nbd -d /dev/nbd0

        # a short wait is needed
        while fuser -sm $qcow_file; do
            echo "Waiting for qcow file to be unmounted..."
            sleep 5
        done
    fi
}

get_part_size_mb_for_file_size_b() {
    local file_b=$1
    local file_mb=$((file_b / 1024 / 1024))

    # with the default ext4 parameters:
    #  partition   usable     efficiency
    #  100 MiB      86 MiB   86.0%
    #  200 MiB     177 MiB   88.5%
    #  500 MiB     454 MiB   90.8%
    #  512 MiB     476 MiB   92.9%
    # 1024 MiB     957 MiB   93.4%
    # 2000 MiB    1914 MiB   95.7%
    # 2048 MiB    1929 MiB   94.1% note this actually drops
    # 5120 MiB    4938 MiB   96.4%

    # the filesystem takes roughly 5% of the space

    # for a 1929M file the calculation suggests a 2031M partition,
    # but in practice a 2048M partition is needed to hold a 1929M file
    # so top the reserve up to 150M whenever it is less than that
    local reserve_mb=$((file_mb * 100 / 95 - file_mb))
    if [ $reserve_mb -lt 150 ]; then
        reserve_mb=150
    fi

    part_mb=$((file_mb + reserve_mb))
    echo "File size:      $file_mb MiB" >&2
    echo "Part size need: $part_mb MiB" >&2
    echo $part_mb
}

get_cloud_image_part_size() {
    # 7
    # https://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud-2211.qcow2c 400m

    # 8
    # https://repo.almalinux.org/almalinux/8/cloud/x86_64/images/AlmaLinux-8-GenericCloud-latest.x86_64.qcow2 600m
    # https://download.rockylinux.org/pub/rocky/8/images/x86_64/Rocky-8-GenericCloud-Base.latest.x86_64.qcow2 1.8g
    # https://yum.oracle.com/templates/OracleLinux/OL8/u9/x86_64/OL8U9_x86_64-kvm-b219.qcow2 1g
    # https://rhel-8.10-x86_64-kvm.qcow2 1g

    # 9
    # https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2 1.2g
    # https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2 600m
    # https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2 600m
    # https://yum.oracle.com/templates/OracleLinux/OL9/u3/x86_64/OL9U3_x86_64-kvm-b220.qcow2 600m
    # https://rhel-9.4-x86_64-kvm.qcow2 900m

    # 10
    # https://cloud.centos.org/centos/10-stream/x86_64/images/CentOS-Stream-GenericCloud-10-latest.x86_64.qcow2 900m

    # https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/cloud/nocloud_alpine-3.19.1-x86_64-uefi-cloudinit-r0.qcow2 200m
    # https://kali.download/cloud-images/current/kali-linux-2024.1-cloud-genericcloud-amd64.tar.xz 200m
    # https://download.opensuse.org/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud.qcow2 300m
    # https://download.opensuse.org/distribution/leap/15.5/appliances/openSUSE-Leap-15.5-Minimal-VM.aarch64-Cloud.qcow2 300m
    # https://mirror.fcix.net/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-Generic.x86_64-40-1.14.qcow2 400m
    # https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2 500m
    # https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2 500m
    # https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img 500m
    # https://gentoo.osuosl.org/experimental/amd64/openstack/gentoo-openstack-amd64-systemd-latest.qcow2 800m

    # openeuler ships .qcow2.xz, so the qcow2 size is only known after decompression
    if [ "$distro" = openeuler ]; then
        echo 3GiB
    elif size_bytes=$(get_http_file_size "$img"); then
        # shrinking btrfs writes to the qcow2; in practice it only grows by 1M, so no special handling is needed
        echo "$(get_part_size_mb_for_file_size_b $size_bytes)MiB"
    else
        # if the file size could not be determined
        echo "Could not get cloud image size in http response." >&2
        echo 2GiB
    fi
}

chroot_dnf() {
    if is_have_cmd_on_disk /os/ dnf; then
        chroot /os/ dnf -y "$@"
    else
        chroot /os/ yum -y "$@"
    fi
}

chroot_apt_update() {
    local os_dir=$1

    current_hash=$(cat $os_dir/etc/apt/sources.list $os_dir/etc/apt/sources.list.d/*.sources 2>/dev/null | md5sum)
    if ! [ "$saved_hash" = "$current_hash" ]; then
        chroot $os_dir apt-get update
        saved_hash="$current_hash"
    fi
}

chroot_apt_install() {
    local os_dir=$1
    shift

    # Only install packages that are not present,
    # to avoid wasting time on upgrades
    local pkg='' pkgs=''
    for pkg in "$@"; do
        if chroot $os_dir dpkg -s "$pkg" >/dev/null 2>&1; then
            # if already installed, mark it manual so autoremove does not drop it
            chroot $os_dir apt-mark manual "$pkg"
        else
            pkgs="$pkgs $pkg"
        fi
    done

    # Install everything at once to avoid running update-initramfs repeatedly
    if [ -n "$pkgs" ]; then
        chroot_apt_update $os_dir
        DEBIAN_FRONTEND=noninteractive chroot $os_dir apt-get install -y $pkgs
    fi
}

chroot_apt_remove() {
    local os_dir=$1
    shift

    # on the minimal image, removing grub-pc installs grub-efi-amd64,
    # so the index must be updated first
    chroot_apt_update $os_dir

    # apt remove --purge -y xxx yyy cannot be used,
    # because if one of them is missing from the index it errors out and the other is not removed either
    local pkgs=
    for pkg in "$@"; do
        # apt list warns: WARNING: apt does not have a stable CLI interface. Use with caution in scripts.
        # but apt-get list does not exist
        if chroot $os_dir apt list --installed "$pkg" | grep -q installed; then
            pkgs="$pkgs $pkg"
        fi
    done

    # removing resolvconf prompts to reboot, hence noninteractive
    DEBIAN_FRONTEND=noninteractive chroot $os_dir apt-get remove --purge --allow-remove-essential -y $pkgs
}

chroot_apt_autoremove() {
    local os_dir=$1

    change_confs() {
        action=$1

        file=$os_dir/etc/apt/apt.conf.d/01autoremove
        case "$action" in
        change)
            if [ -f $file ]; then
                sed -i.orig 's/VersionedKernelPackages/x/; s/NeverAutoRemove/x/' $file
            fi
            ;;
        restore)
            if [ -f $file.orig ]; then
                mv $file.orig $file
            fi
            ;;
        esac
    }

    change_confs change
    DEBIAN_FRONTEND=noninteractive chroot $os_dir apt-get autoremove --purge -y
    change_confs restore
}

del_default_user() {
    local os_dir=$1

    local user
    while read -r user; do
        if grep ^$user':\$' "$os_dir/etc/shadow"; then
            echo "Deleting user $user"
            chroot "$os_dir" userdel -rf "$user"
        fi
    done < <(grep -v nologin$ "$os_dir/etc/passwd" | cut -d: -f1 | grep -v root)
}

is_el7_family() {
    is_have_cmd_on_disk "$1" yum &&
        ! is_have_cmd_on_disk "$1" dnf
}

del_exist_sysconfig_NetworkManager_config() {
    local os_dir=$1

    # Remove the dhcp configuration shipped in the cloud image, to avoid ambiguity
    rm -rf $os_dir/etc/NetworkManager/system-connections/*.nmconnection
    rm -rf $os_dir/etc/sysconfig/network-scripts/ifcfg-*

    # 1. fix cloud-init adding IPV*_FAILURE_FATAL / may-fail=false
    #    on Oracle, a dhcpv6 failure is treated as fatal and the existing ipv4 address is removed too
    # 2. fix ifcfg adding IPV6_AUTOCONF=no under dhcpv6, which prevents obtaining a gateway
    # 3. fix NM method=dhcp under dhcpv6, which prevents obtaining a gateway
    if false; then
        ci_file=$os_dir/etc/cloud/cloud.cfg.d/99_fallback.cfg

        insert_into_file $ci_file after '^runcmd:' <<EOF
  - sed -i '/^IPV[46]_FAILURE_FATAL=/d' /etc/sysconfig/network-scripts/ifcfg-* || true
  - sed -i '/^may-fail=/d' /etc/NetworkManager/system-connections/*.nmconnection || true
  - for f in /etc/sysconfig/network-scripts/ifcfg-*; do grep -q '^DHCPV6C=yes' "\$f" && sed -i '/^IPV6_AUTOCONF=no/d' "\$f"; done
  - sed -i 's/^method=dhcp/method=auto/' /etc/NetworkManager/system-connections/*.nmconnection || true
  - systemctl is-enabled NetworkManager && systemctl restart NetworkManager || true
EOF
    fi
}

install_qcow_by_copy() {
    info "Install qcow2 by copy"

    modify_el_ol() {
        info "Modify el ol"
        local os_dir=/os

        # resolv.conf
        cp_resolv_conf /os

        # some images ship a default configuration, e.g. centos
        del_exist_sysconfig_NetworkManager_config /os

        # remove the default account from the image, so nobody can ssh in with its default password
        del_default_user /os

        # selinux kdump
        disable_selinux /os
        disable_kdump /os

        # el7 does not recreate machine-id after it is removed
        clear_machine_id /os

        # special handling for the el7 forks
        if is_el7_family /os; then
            # switch repos now that centos 7 is EOL
            if [ -f /os/etc/yum.repos.d/CentOS-Base.repo ]; then
                # keep the default http, because the bundled ssl certificate may have expired
                mirror=vault.centos.org
                sed -Ei -e 's,(mirrorlist=),#\1,' \
                    -e "s,#(baseurl=http://)mirror.centos.org,\1$mirror," /os/etc/yum.repos.d/CentOS-Base.repo
            fi

            # el7 yum may use ipv6 even when there is no ipv6 network
            if [ "$(cat /dev/netconf/*/ipv6_has_internet | sort -u)" = 0 ]; then
                echo 'ip_resolve=4' >>/os/etc/yum.conf
            fi

            # el7 installs NetworkManager
            # the anolis 7 image ships NetworkManager
            if ! [ -f /os/usr/lib/systemd/system/NetworkManager.service ]; then
                chroot_dnf install NetworkManager
            fi
            # errors out when the service does not exist
            chroot /os systemctl disable network 2>/dev/null || true
            chroot /os systemctl enable NetworkManager
        fi

        # firmware + microcode
        if fw_pkgs=$(get_ucode_firmware_pkgs) && [ -n "$fw_pkgs" ]; then
            chroot_dnf install $fw_pkgs
        fi

        # Remove the extra partitions from fstab
        # the almalinux/rocky images have a boot partition
        # the oracle image has a swap partition
        sed -i '/[[:space:]]\/boot[[:space:]]/d' /os/etc/fstab
        sed -i '/[[:space:]]swap[[:space:]]/d' /os/etc/fstab

        # os_part variable:
        # mapper/vg_main-lv_root
        # mapper/opencloudos-root

        # switch the oracle/opencloudos system disk from lvm to uuid mounting
        sed -i "s,/dev/$os_part,UUID=$os_part_uuid," /os/etc/fstab
        if ls /os/boot/loader/entries/*.conf 2>/dev/null; then
            # options root=/dev/mapper/opencloudos-root ro console=ttyS0,115200n8 no_timer_check net.ifnames=0 crashkernel=1800M-64G:256M,64G-128G:512M,128G-486G:768M,486G-972G:1024M,972G-:2048M rd.lvm.lv=opencloudos/root rhgb quiet
            sed -i "s,/dev/$os_part,UUID=$os_part_uuid," /os/boot/loader/entries/*.conf
        fi

        # remove the lvm cmdline for oracle/opencloudos
        chroot /os grubby --update-kernel ALL --remove-args "resume rd.lvm.lv"
        # on el7 the grubby command above cannot set /etc/default/grub
        sed -i 's/rd.lvm.lv=[^ "]*//g' /os/etc/default/grub

        # Add the efi partition to fstab
        if is_efi; then
            # centos/oracle need an efi entry created
            if ! grep /boot/efi /os/etc/fstab; then
                efi_part_uuid=$(lsblk "/dev/$(xda 1)" -no UUID)
                echo "UUID=$efi_part_uuid /boot/efi vfat $efi_mount_opts 0 0" >>/os/etc/fstab
            fi
        else
            # remove the efi entry
            sed -i '/[[:space:]]\/boot\/efi[[:space:]]/d' /os/etc/fstab
        fi

        remove_grub_conflict_files() {
            # delete it before converting between bios and efi

            # bios to efi failure:
            # the centos and oracle x86_64 images are bios-only, and /boot/grub2/grubenv is the real file
            # installing grub-efi turns grubenv into a symlink to the efi partition grubenv
            # if the original grubenv is not removed first it stays put, and the new symlink becomes grubenv.rpmnew
            # later grubenv changes then never reach the efi partition, breaking grub2-setdefault

            # efi to bios failure:
            # if it is a symlink into the efi directory (e.g. el8), remove it first or grub2-install errors out
            rm -rf /os/boot/grub2/grubenv /os/boot/grub2/grub.cfg
        }

        # the openeuler arm image has grub.cfg at /os/grub.cfg, probably for an external grub to read; we do not need it
        # centos7 has a grub1 configuration
        rm -rf /os/grub.cfg /os/boot/grub/grub.conf /os/boot/grub/menu.lst

        # Install the bootloader
        if is_efi; then
            # only the centos and oracle x86_64 images lack efi; for other images the files were already copied from the efi partition
            # openeuler ships grub2-efi-ia32, so installing grub2-efi reports grub2-efi-ia32 as already installed and never installs grub2-efi-x64

            # in the extreme case where the qcow2 was built with grub2-efi-x64 installed without the efi partition mounted, the efi files end up on the system partition
            # but we mount /boot/efi when copying the system partition, so the efi files are copied to the efi partition correctly
            # so there is no need to check whether the qcow2 efi is a separate partition

            # the rhel image has no repositories, so a plain yum install may fail
            # therefore skip yum install when the required package is already present
            need_install=false
            need_remove_grub_conflict_files=false

            [ "$(uname -m)" = x86_64 ] && arch=x64 || arch=aa64
            if ! chroot $os_dir rpm -qi grub2-efi-$arch; then
                need_install=true
                need_remove_grub_conflict_files=true
            elif ! chroot $os_dir rpm -qi shim-$arch || ! chroot $os_dir rpm -qi efibootmgr; then
                need_install=true
            fi

            if $need_install; then
                if $need_remove_grub_conflict_files; then
                    remove_grub_conflict_files
                fi
                chroot_dnf install efibootmgr grub2-efi-$arch shim-$arch
            fi
            # the grubaa64.efi inside the openeuler arm 25.09 cloud image targets an mbr table, where $root is hd0,msdos1
            # so re-download a grubaa64.efi whose $root is hd0,gpt1
            if $need_reinstall_grub_efi; then
                chroot_dnf reinstall grub2-efi-$arch
            fi
        else
            # bios
            remove_grub_conflict_files
            chroot /os/ grub2-install /dev/$xda
        fi

        # blscfg boot entries
        # the rocky/almalinux images have a separate boot partition, but we do not,
        # so the boot directory must be added
        if ls /os/boot/loader/entries/*.conf 2>/dev/null &&
            ! grep -q 'initrd /boot/' /os/boot/loader/entries/*.conf; then

            sed -i -E 's,((linux|initrd) /),\1boot/,g' /os/boot/loader/entries/*.conf
        fi

        # the grub-efi-x64 package contains /etc/grub2-efi.cfg
        # pointing at /boot/efi/EFI/xxx/grub.cfg or /boot/grub2/grub.cfg
        # wherever it points is where grub2-mkconfig should write its output
        # grubby also uses /etc/grub2-efi.cfg to locate grub.cfg
        # openeuler 24.03 x64 and aa64 point at different files
        if is_efi; then
            grub_o_cfg=$(chroot /os readlink -f /etc/grub2-efi.cfg)
        else
            grub_o_cfg=/boot/grub2/grub.cfg
        fi

        # efi partition grub.cfg
        # https://github.com/rhinstaller/anaconda/blob/346b932a26a19b339e9073c049b08bdef7f166c3/pyanaconda/modules/storage/bootloader/efi.py#L198
        # https://github.com/rhinstaller/anaconda/commit/15c3b2044367d375db6739e8b8f419ef3e17cae7
        if is_efi && ! echo "$grub_o_cfg" | grep -q '/boot/efi/EFI'; then
            # the oracle linux folder is called redhat
            # shellcheck disable=SC2010
            distro_efi=$(cd /os/boot/efi/EFI/ && ls -d -- * | grep -Eiv BOOT)
            cat <<EOF >/os/boot/efi/EFI/$distro_efi/grub.cfg
search --no-floppy --fs-uuid --set=dev $os_part_uuid
set prefix=(\$dev)/boot/grub2
export \$prefix
configfile \$prefix/grub.cfg
EOF
        fi

        # main grub.cfg
        if ls /os/boot/loader/entries/*.conf >/dev/null 2>&1 &&
            chroot /os/ grub2-mkconfig --help | grep -q update-bls-cmdline; then
            chroot /os/ grub2-mkconfig -o "$grub_o_cfg" --update-bls-cmdline
        else
            chroot /os/ grub2-mkconfig -o "$grub_o_cfg"
        fi

        # Network configuration
        # el7/8 sysconfig
        # el9 network-manager
        if [ -f $os_dir/etc/sysconfig/network-scripts/ifup-eth ]; then
            # sysconfig
            info 'sysconfig'

            # anolis/openeuler/opencloudos may need cloud-init installed
            # opencloudos cannot use chroot $os_dir command -v xxx
            # chroot: failed to run command ‘command’: No such file or directory
            # note the cloud-init service must be disabled as well
            if ! is_have_cmd_on_disk $os_dir cloud-init; then
                chroot_dnf install cloud-init
            fi

            # cloud-init path
            # /usr/lib/python2.7/site-packages/cloudinit/net/
            # /usr/lib/python3/dist-packages/cloudinit/net/
            # /usr/lib/python3.9/site-packages/cloudinit/net/

            # el7 does not know static6, but static works the same way
            recognize_static6=true
            if ls $os_dir/usr/lib/python*/*-packages/cloudinit/net/sysconfig.py 2>/dev/null &&
                ! grep -q static6 $os_dir/usr/lib/python*/*-packages/cloudinit/net/sysconfig.py; then
                recognize_static6=false
            fi

            # the configuration below needs cloud-init 20.1 or newer
            # https://cloudinit.readthedocs.io/en/20.4/topics/network-config-format-v1.html#subnet-ip
            # https://cloudinit.readthedocs.io/en/21.1/topics/network-config-format-v1.html#subnet-ip
            # ipv6_dhcpv6-stateful: Configure this interface with dhcp6
            # ipv6_dhcpv6-stateless: Configure this interface with SLAAC and DHCP
            # ipv6_slaac: Configure address with SLAAC

            # newest cloud-init version on el7
            # centos 7         19.4-7.0.5.el7_9.6  has ipv6_xxx backported
            # openeuler 20.03  19.4-15.oe2003sp4   has ipv6_xxx backported
            # anolis 7         19.1.17-1.0.1.an7   not updated to the centos7 version and no ipv6_xxx backport, a trap

            # ideally IPV6_AUTOCONF in ifcfg-eth* would also be changed,
            # but in practice anolis7 cloud-init dhcp6 does not generate IPV6_AUTOCONF, so leave it for now
            # https://www.redhat.com/zh/blog/configuring-ipv6-rhel-7-8
            recognize_ipv6_types=true
            if ls -d $os_dir/usr/lib/python*/*-packages/cloudinit/net/ 2>/dev/null &&
                ! grep -qr ipv6_slaac $os_dir/usr/lib/python*/*-packages/cloudinit/net/; then
                recognize_ipv6_types=false
            fi

            # Generate the cloud-init network configuration
            create_cloud_init_network_config $os_dir/net.cfg "$recognize_static6" "$recognize_ipv6_types"

            # Convert it to the target system network configuration
            chroot $os_dir cloud-init devel net-convert \
                -p /net.cfg -k yaml -d out -D rhel -O sysconfig
            cp $os_dir/out/etc/sysconfig/network-scripts/ifcfg-eth* $os_dir/etc/sysconfig/network-scripts/

            # Clean up
            rm -rf $os_dir/net.cfg $os_dir/out

            # remove "# Created by cloud-init on instance boot automatically, do not edit."
            # fix the network configuration issues and show the file
            sed -i -e '/^IPV[46]_FAILURE_FATAL=/d' -e '/^#/d' $os_dir/etc/sysconfig/network-scripts/ifcfg-*
            for file in "$os_dir/etc/sysconfig/network-scripts/ifcfg-"*; do
                if grep -q '^DHCPV6C=yes' "$file"; then
                    sed -i '/^IPV6_AUTOCONF=no/d' "$file"
                fi
                cat -n "$file"
            done
        else
            # Network Manager
            info 'Network Manager'

            create_cloud_init_network_config /net.cfg
            create_network_manager_config /net.cfg "$os_dir"

            # Clean up
            rm /net.cfg
        fi

        # without removing it the network manager may not write dns
        rm_resolv_conf /os
    }

    modify_ubuntu() {
        local os_dir=/os
        info "Modify Ubuntu"

        cp_resolv_conf $os_dir

        # turn os-prober off, because it is sometimes very slow
        cp $os_dir/etc/default/grub $os_dir/etc/default/grub.orig
        echo 'GRUB_DISABLE_OS_PROBER=true' >>$os_dir/etc/default/grub

        # Change the repositories

        # stop do-release-upgrade auto-running dpkg-reconfigure grub-xx and failing because the efi/biosgrub partition does not exist
        # shellcheck disable=SC2046
        chroot_apt_remove $os_dir $(is_efi && echo 'grub-pc' || echo 'grub-efi*' 'shim*')
        chroot_apt_autoremove $os_dir

        # Install the mbr
        if ! is_efi; then
            if false; then
                # debconf-show grub-pc
                # the disk name can differ between boots, but a debian netboot install also sets grub-pc/install_devices
                echo grub-pc grub-pc/install_devices multiselect /dev/$xda | chroot $os_dir debconf-set-selections # 22.04
                echo grub-pc grub-pc/cloud_style_installation boolean true | chroot $os_dir debconf-set-selections # 24.04
                chroot $os_dir dpkg-reconfigure -f noninteractive grub-pc
            else
                chroot $os_dir grub-install /dev/$xda
            fi
        fi

        # bundled kernels:
        # normal releases        generic
        # minimal 20.04/22.04    kvm      # nothing shown on the vnc console
        # minimal 24.04       virtual

        # the debian cloud kernel has no ahci support; the ubuntu virtual one does

        # Mark every kernel as automatically installed
        # note that linux-base must be excluded
        # this always exits 0
        pkgs=$(chroot $os_dir apt-mark showmanual \
            linux-generic linux-virtual linux-kvm \
            linux-image* linux-headers*)
        chroot $os_dir apt-mark auto $pkgs

        # Install the best kernel
        flavor=$(get_ubuntu_kernel_flavor)
        echo "Use kernel flavor: $flavor"

        # side note
        # if a package is in the auto state and has an update available,
        # apt install PKG only upgrades it and does not mark it manual
        # apt install PKG must be run a second time to mark it manual

        # this function already does apt-mark manual
        chroot_apt_install $os_dir "linux-image-$flavor"

        # use autoremove to drop the surplus kernels
        chroot_apt_autoremove $os_dir

        # Install firmware and microcode
        if fw_pkgs=$(get_ucode_firmware_pkgs) && [ -n "$fw_pkgs" ]; then
            chroot_apt_install $os_dir $fw_pkgs
        fi

        # Network configuration
        # 18.04+ netplan
        # stop netplan.io on the minimal image being autoremoved after cloud-init is removed
        chroot $os_dir apt-mark manual netplan.io

        # Generate the cloud-init network configuration
        create_cloud_init_network_config $os_dir/net.cfg

        # ubuntu 18.04 ships cloud-init 23.1.2, so onlink needs no handling

        # 50-cloud-init.yaml is only generated when the output goes to /
        # note what extra files appear
        if false; then
            chroot $os_dir cloud-init devel net-convert \
                -p /net.cfg -k yaml -d /out -D ubuntu -O netplan
            sed -Ei "/^[[:space:]]+set-name:/d" $os_dir/out/etc/netplan/50-cloud-init.yaml
            cp $os_dir/out/etc/netplan/50-cloud-init.yaml $os_dir/etc/netplan/

            # Clean up
            rm -rf $os_dir/net.cfg $os_dir/out
        else
            chroot $os_dir cloud-init devel net-convert \
                -p /net.cfg -k yaml -d / -D ubuntu -O netplan
            sed -Ei "/^[[:space:]]+set-name:/d" $os_dir/etc/netplan/50-cloud-init.yaml

            # Clean up
            rm -rf $os_dir/net.cfg
        fi

        # the bundled 60-cloudimg-settings.conf disables PasswordAuthentication
        # it can be removed or kept, since the effective sshd config is now read before being modified
        # if 60-cloudimg-settings.conf is to be removed, do it before change_ssh_conf_if_different
        if false; then
            file=$os_dir/etc/ssh/sshd_config.d/60-cloudimg-settings.conf
            if [ -f $file ]; then
                sed -i '/^PasswordAuthentication/d' $file
                if [ -z "$(cat $file)" ]; then
                    rm -f $file
                fi
            fi
        fi

        # Fix the hard-coded fsuuid in the efi directory grub.cfg,
        # because on 24.04 that fsuuid refers to the boot partition
        efi_grub_cfg=$os_dir/boot/efi/EFI/ubuntu/grub.cfg
        if is_efi; then
            os_uuid=$(lsblk -rno UUID "/dev/$(xda 2)")
            sed -Ei "s|[0-9a-f-]{36}|$os_uuid|i" $efi_grub_cfg

            # once the 24.04 boot partition is removed, the /boot path must be added
            if grep "'/grub'" $efi_grub_cfg; then
                sed -i "s|'/grub'|'/boot/grub'|" $efi_grub_cfg
            fi
        fi

        # Handle 40-force-partuuid.cfg
        force_partuuid_cfg=$os_dir/etc/default/grub.d/40-force-partuuid.cfg
        if [ -e $force_partuuid_cfg ]; then
            if is_virt; then
                # change the hard-coded partuuid
                os_part_uuid=$(lsblk -rno PARTUUID "/dev/$(xda 2)")
                sed -i "s/^GRUB_FORCE_PARTUUID=.*/GRUB_FORCE_PARTUUID=$os_part_uuid/" $force_partuuid_cfg
            else
                # a dedicated server should not use initrdless boot
                sed -i "/^GRUB_FORCE_PARTUUID=/d" $force_partuuid_cfg
            fi
        fi

        # grub.cfg must be regenerated, because
        # 1 we removed the boot partition
        # 2 we changed /etc/default/grub.d/40-force-partuuid.cfg
        chroot $os_dir update-grub

        # Restore the grub configuration (os prober)
        mv $os_dir/etc/default/grub.orig $os_dir/etc/default/grub

        # fstab
        # the 24.04 image has a boot partition, which we do not need
        sed -i '/[[:space:]]\/boot[[:space:]]/d' $os_dir/etc/fstab
        if ! is_efi; then
            # bios: remove the efi entry
            sed -i '/[[:space:]]\/boot\/efi[[:space:]]/d' $os_dir/etc/fstab
        fi

        restore_resolv_conf $os_dir
    }

    efi_mount_opts=$(
        case "$distro" in
        ubuntu) echo "umask=0077" ;;
        *) echo "defaults,uid=0,gid=0,umask=077,shortname=winnt" ;;
        esac
    )

    # total memory needed while yum/apt installs packages
    need_ram=$(
        case "$distro" in
        ubuntu) echo 1024 ;;
        *) echo 2048 ;;
        esac
    )

    connect_qcow

    # image partition format
    # centos/rocky/almalinux/rhel: xfs
    # oracle x86_64:          lvm + xfs
    # oracle aarch64 cloud:   xfs
    # alibaba cloud linux 3:  ext4

    is_lvm_image=false
    if lsblk -f /dev/nbd0p* | grep LVM2_member; then
        is_lvm_image=true
        apk add lvm2
        lvscan
        vg=$(pvs | grep /dev/nbd0p | awk '{print $2}')
        lvchange -ay "$vg"
    fi

    mount_nouuid() {
        part_fstype=
        for arg in "$@"; do
            case "$arg" in
            /dev/*)
                part_fstype=$(lsblk -no FSTYPE "$arg")
                break
                ;;
            esac
        done

        case "$part_fstype" in
        xfs) mount -o nouuid "$@" ;;
        *) mount "$@" ;;
        esac
    }

    # could the last partition simply be taken as the system partition?
    # the almalinux9 boot partition does not use the standard type uuid
    # the openeuler boot partition is vfat
    # openeuler arm 25.09 uses an mbr table where efi and boot are the same vfat partition

    info "qcow2 Partitions check"

    # Detect the partition table type
    partition_table_format=$(get_partition_table_format /dev/nbd0)
    need_reinstall_grub_efi=false
    if is_efi && [ "$partition_table_format" = "msdos" ]; then
        need_reinstall_grub_efi=true
    fi

    # Identify each partition by the files it contains
    os_part='' boot_part='' efi_part=''
    mkdir -p /nbd-test
    for part in $(lsblk /dev/nbd0p* --sort SIZE -no NAME,FSTYPE |
        grep -E ' (ext4|xfs|fat|vfat)$' | awk '{print $1}' | tac); do
        mapper_part=$part
        if $is_lvm_image && [ -e /dev/mapper/$part ]; then
            mapper_part=mapper/$part
        fi

        if mount_nouuid -o ro /dev/$mapper_part /nbd-test; then
            if { ls /nbd-test/etc/os-release || ls /nbd-test/*/etc/os-release; } 2>/dev/null; then
                os_part=$mapper_part
            fi
            # shellcheck disable=SC2010
            # when boot is a separate partition, vmlinuz and friends are in the root directory
            # when it is not, they are in /boot
            if ls /nbd-test/ /nbd-test/boot/ 2>/dev/null | grep -Ei '^(vmlinuz|initrd|initramfs)'; then
                boot_part=$mapper_part
            fi
            # with mbr + efi boot, the partition table has no esp guid,
            # so the efi files are used to identify the efi partition
            # those files may sit in a subdirectory of efi, at an unpredictable depth
            if find /nbd-test/ -type f -ipath '/nbd-test/EFI/*.efi' 2>/dev/null | grep .; then
                efi_part=$mapper_part
            fi
            umount /nbd-test
        fi
    done

    info "qcow2 Partitions"
    lsblk -f /dev/nbd0 -o +PARTTYPE
    # Show which partition holds the OS/EFI/Boot files
    echo "---"
    echo "Table:     $partition_table_format"
    echo "Part OS:   $os_part"
    echo "Part EFI:  $efi_part"
    echo "Part Boot: $boot_part"
    echo "---"

    # How the partitions are located
    # system/partition     cmdline:root   fstab:efi
    # rocky             LABEL=rocky   LABEL=EFI
    # ubuntu            PARTUUID      LABEL=UEFI
    # other el/ol          UUID           UUID

    IFS=, read -r os_part_uuid os_part_label os_part_fstype \
        < <(lsblk /dev/$os_part -rno UUID,LABEL,FSTYPE | tr ' ' ,)

    if [ -n "$efi_part" ]; then
        IFS=, read -r efi_part_uuid efi_part_label \
            < <(lsblk /dev/$efi_part -rno UUID,LABEL | tr ' ' ,)
    fi

    mkdir -p /nbd /nbd-boot /nbd-efi

    # Use the target system's own formatting tool
    # if xfs is formatted by alpine on centos8, neither grub2-mkconfig nor grub2 can read the xfs partition
    mount_nouuid /dev/$os_part /nbd/
    mount_pseudo_fs /nbd/
    case "$os_part_fstype" in
    ext4) chroot /nbd mkfs.ext4 -F -L "$os_part_label" -U "$os_part_uuid" "/dev/$(xda 2)" ;;
    xfs) chroot /nbd mkfs.xfs -f -L "$os_part_label" -m uuid=$os_part_uuid "/dev/$(xda 2)" ;;
    esac
    umount -R /nbd/

    # TODO: does the ubuntu image lack mkfs.fat/vfat/dosfstools? does the initrd not need an fs integrity check?

    # Create and mount /os
    mkdir -p /os
    mount -o noatime "/dev/$(xda 2)" /os/

    # create /os/boot/efi when this is efi
    # also create it when the image has an efi partition, to copy that partition\'s files
    if is_efi || [ -n "$efi_part" ]; then
        mkdir -p /os/boot/efi/

        # Mount /os/boot/efi
        # mount it in advance, because boot and efi may be the same partition (openeuler 24.03 arm)
        # in which case copying boot also copies the efi files
        if is_efi; then
            mount -o $efi_mount_opts "/dev/$(xda 1)" /os/boot/efi/
        fi
    fi

    # Copy the system partition
    echo Copying os partition...
    mount_nouuid -o ro /dev/$os_part /nbd/
    cp -a /nbd/* /os/
    umount /nbd/

    # Copy the separate boot partition, if there is one
    if [ -n "$boot_part" ] && ! [ "$boot_part" = "$os_part" ]; then
        echo Copying boot partition...
        mount_nouuid -o ro /dev/$boot_part /nbd-boot/
        cp -a /nbd-boot/* /os/boot/
        umount /nbd-boot/
    fi

    # Copy the separate efi partition, if there is one
    # if efi and boot are the same partition, the efi files were already copied with boot
    if [ -n "$efi_part" ] && ! [ "$efi_part" = "$os_part" ] && ! [ "$efi_part" = "$boot_part" ]; then
        echo Copying efi partition...
        mount -o ro /dev/$efi_part /nbd-efi/
        cp -a /nbd-efi/* /os/boot/efi/
        umount /nbd-efi/
    fi

    # Disconnect qcow and remove qemu-img
    info "Disconnecting qcow2"
    if is_have_cmd vgchange; then
        vgchange -an
        apk del lvm2
    fi
    disconnect_qcow
    apk del qemu-img

    # Unmount the disk
    info "Unmounting disk"
    if is_efi; then
        umount /os/boot/efi/
    fi
    umount /os/
    umount /installer/

    # if the image has a separate efi partition (including efi+boot combined), copy its uuid
    # a fat partition with the same uuid cannot be mounted,
    # so copy the efi partition first, disconnect nbd, then copy the uuid
    # the efi partition must be unmounted before copying the uuid
    if is_efi && [ -n "$efi_part_uuid" ] && ! [ "$efi_part" = "$os_part" ]; then
        info "Copy efi partition uuid"
        apk add mtools
        mlabel -N "$(echo $efi_part_uuid | sed 's/-//')" -i "/dev/$(xda 1)" ::$efi_part_label
        apk del mtools
        update_part
    fi

    # Remove the installer partition and grow the filesystem
    info "Delete installer partition"
    apk add parted
    parted /dev/$xda -s -- rm 3
    update_part
    resize_after_install_cloud_image

    # Remount /os and /boot/efi
    info "Re-mount disk"
    mount -o noatime "/dev/$(xda 2)" /os/
    if is_efi; then
        mount -o $efi_mount_opts "/dev/$(xda 1)" /os/boot/efi/
    fi

    # Create swap
    create_swap_if_ram_less_than $need_ram /os/swapfile

    # Mount the pseudo filesystems
    mount_pseudo_fs /os/

    case "$distro" in
    ubuntu) modify_ubuntu ;;
    *) modify_el_ol ;;
    esac

    # Basic configuration
    basic_init /os

    # Remove cloud-init last,
    # because generating the netplan/sysconfig network configuration needs the target system's cloud-init
    remove_or_disable_cloud_init /os

    # Remove the swapfile
    swapoff -a
    rm -f /os/swapfile
}

get_partition_table_format() {
    apk add parted
    parted "$1" -s print | grep 'Partition Table:' | awk '{print $NF}'
}

dd_qcow() {
    info "DD qcow2"

    if true; then
        connect_qcow

        partition_table_format=$(get_partition_table_format /dev/nbd0)
        orig_nbd_virtual_size=$(get_disk_size /dev/nbd0)

        # Check whether the last partition is btrfs
        # awk exits 0 even with empty output, so grep . checks for an empty result
        if part_num=$(parted /dev/nbd0 -s print | awk NF | tail -1 | grep btrfs | awk '{print $1}' | grep .); then
            apk add btrfs-progs
            mkdir -p /mnt/btrfs
            mount /dev/nbd0p$part_num /mnt/btrfs

            # reclaim the empty data blocks
            btrfs device usage /mnt/btrfs
            btrfs balance start -dusage=0 /mnt/btrfs
            btrfs device usage /mnt/btrfs

            # calculate how much space can be freed
            free_bytes=$(btrfs device usage /mnt/btrfs -b | grep Unallocated: | awk '{print $2}')
            reserve_bytes=$((100 * 1024 * 1024)) # reserve 100M of free space
            skrink_bytes=$((free_bytes - reserve_bytes))

            if [ $skrink_bytes -gt 0 ]; then
                # shrink the filesystem
                btrfs filesystem resize -$skrink_bytes /mnt/btrfs
                # shrink the partition
                part_start=$(parted /dev/nbd0 -s 'unit b print' | awk "\$1==$part_num {print \$2}" | sed 's/B//')
                part_size=$(btrfs filesystem usage /mnt/btrfs -b | grep 'Device size:' | awk '{print $3}')
                part_end=$((part_start + part_size - 1))
                umount /mnt/btrfs
                printf "yes" | parted /dev/nbd0 resizepart $part_num ${part_end}B ---pretend-input-tty

                # shrink the qcow2
                disconnect_qcow
                qemu-img resize --shrink $qcow_file $((part_end + 1))

                # reconnect
                connect_qcow
            else
                umount /mnt/btrfs
            fi
        fi

        # Show the partitions
        lsblk -o NAME,SIZE,FSTYPE,LABEL /dev/nbd0

        # dd the first 1M into memory
        dd if=/dev/nbd0 of=/first-1M bs=1M count=1

        # dd everything after 1M to disk
        # shellcheck disable=SC2194
        case 3 in
        1)
            # BusyBox dd
            dd if=/dev/nbd0 of=/dev/$xda bs=1M skip=1 seek=1
            ;;
        2)
            # the real dd with status=progress, but no percentage or time remaining
            apk add coreutils
            dd if=/dev/nbd0 of=/dev/$xda bs=1M skip=1 seek=1 status=progress
            ;;
        3)
            # use pv
            apk add pv
            echo "Start DD Cloud Image..."
            pv -f /dev/nbd0 | dd of=/dev/$xda bs=1M skip=1 seek=1 iflag=fullblock
            ;;
        esac

        disconnect_qcow
    else
        # dd the first 1M into memory and everything after 1M to disk
        qemu-img dd if=$qcow_file of=/first-1M bs=1M count=1
        qemu-img dd if=$qcow_file of=/dev/disk/by-label/os bs=1M skip=1
    fi

    # the qcow has been dd-ed and disconnected, so qemu-img can be removed
    apk del qemu-img

    # dd the first 1M from memory to disk
    umount /installer/
    dd if=/first-1M of=/dev/$xda
    rm -f /first-1M

    # A gpt table records the location of the backup table at the start of the disk
    # if the qcow2 virtual size exceeds the real disk size,
    # the backup table location falls beyond the end of the real disk
    # and partprobe errors out
    # Error: Invalid argument during seek for read on /dev/vda
    # parted also stops working
    # so the partition table must be repaired first

    # this is the only such case, since other qcow2 images are at most 5g, the supported size
    # openSUSE-Leap-15.5-Minimal-VM.x86_64-kvm-and-xen.qcow2 is 25g
    # after shrinking the btrfs partition it is dd-ed onto a 10g machine,
    # where the backup table location is still 25g
    # and must be repaired to the 10g position,
    # otherwise neither partprobe nor parted works

    # only this case is repaired with sgdisk
    if [ "$partition_table_format" = gpt ] &&
        [ "$orig_nbd_virtual_size" -gt "$(get_disk_size /dev/$xda)" ]; then
        fix_gpt_backup_partition_table_by_sgdisk
    fi
    update_part
}

fix_gpt_backup_partition_table_by_sgdisk() {
    # when the backup table lies beyond the real disk, only sgdisk can repair the table
    # scenario: the image is larger than the disk, but fits once the partition is shrunk, so the DD can succeed
    # example: openSUSE-Leap-15.5-Minimal-VM.x86_64-kvm-and-xen.qcow2

    # parted cannot repair it
    # parted /dev/$xda -f -s print

    # fdisk/sfdisk report the primary table as corrupt
    # echo write | sfdisk /dev/$xda
    # GPT PMBR size mismatch (50331647 != 20971519) will be corrected by write.
    # The primary GPT table is corrupt, but the backup appears OK, so that will be used.

    # every other scenario should be repaired with parted

    apk add sgdisk

    # both methods work, but neither repairs the GUID of the backup table
    # sgdisk -v /dev/vda then warns that the primary and backup table guids differ
    # localhost:~# sgdisk -v /dev/$xda
    # Problem: main header's disk GUID (A24485F3-2C02-43BD-BF4E-F52E42B00DEA) doesn't
    # match the backup GPT header's disk GUID (ADAF57BC-B4F5-4E04-BCBA-BDDCD796C388)
    # You should use the 'b' or 'd' option on the recovery & transformation menu to
    # select one or the other header.
    if false; then
        sgdisk --backup /gpt-partition-table /dev/$xda
        sgdisk --load-backup /gpt-partition-table /dev/$xda
    else
        sgdisk --move-second-header /dev/$xda
    fi

    # so the guid has to be set once
    if new_guid=$(sgdisk -v /dev/$xda | grep GUID | head -1 | grep -Eo '[0-9A-F-]{36}'); then
        sgdisk --disk-guid $new_guid /dev/$xda
    fi

    update_part

    apk del sgdisk
}

# Used to repair the gpt backup table after a DD
fix_gpt_backup_partition_table_by_parted() {
    apk add parted
    parted /dev/$xda -f -s print
    update_part
}

resize_after_install_cloud_image() {
    # Grow it in advance to
    # 1 fix the kernel panic on first boot of vultr 512m debian 11 generic/genericcloud
    # 2 stop the gentoo cloud image running out of space during websync
    info "Resize after dd"
    lsblk -f /dev/$xda

    # Print the partition table, repairing the backup table automatically
    fix_gpt_backup_partition_table_by_parted

    disk_size=$(get_disk_size /dev/$xda)
    disk_end=$((disk_size - 1))

    # the trailing _ must not be dropped, or the whole sixth field goes to last_part_fs
    IFS=: read -r last_part_num _ last_part_end _ last_part_fs _ \
        < <(parted -msf /dev/$xda 'unit b print' | tail -1)
    last_part_end=$(echo $last_part_end | sed 's/B//')

    if [ $((disk_end - last_part_end)) -ge 0 ]; then
        printf "yes" | parted /dev/$xda resizepart $last_part_num 100% ---pretend-input-tty
        update_part

        mkdir -p /os

        # lvm ?
        # use cloud-utils-growpart?
        case "$last_part_fs" in
        ext4)
            # debian ci
            apk add e2fsprogs-extra
            e2fsck -p -f "/dev/$(xda $last_part_num)"
            resize2fs "/dev/$(xda $last_part_num)"
            apk del e2fsprogs-extra
            ;;
        xfs)
            # opensuse ci
            apk add xfsprogs-extra
            mount "/dev/$(xda $last_part_num)" /os
            xfs_growfs "/dev/$(xda $last_part_num)"
            umount /os
            apk del xfsprogs-extra
            ;;
        btrfs)
            # fedora ci
            apk add btrfs-progs
            mount "/dev/$(xda $last_part_num)" /os
            btrfs filesystem resize max /os
            umount /os
            apk del btrfs-progs
            ;;
        ntfs)
            # windows dd
            apk add ntfs-3g-progs
            echo y | ntfsresize "/dev/$(xda $last_part_num)"
            ntfsfix -d "/dev/$(xda $last_part_num)"
            apk del ntfs-3g-progs
            ;;
        esac
        update_part
        parted /dev/$xda -s print
    fi
}

mount_part_basic_layout() {
    local os_dir=$1
    local efi_dir=$2

    if is_efi || is_xda_gt_2t; then
        os_part_num=2
    else
        os_part_num=1
    fi

    # Mount the system partition
    mkdir -p $os_dir
    mount -t ext4 "/dev/$(xda $os_part_num)" $os_dir

    # Mount the efi partition
    if is_efi; then
        mkdir -p $efi_dir
        mount -t vfat -o umask=077 "/dev/$(xda 1)" $efi_dir
    fi
}

mount_part_for_iso_installer() {
    info "Mount part for iso installer"

    if [ "$distro" = windows ]; then
        mount_args="-t ntfs3 -o nocase"
    else
        mount_args=
    fi

    # Mount the main partition
    mkdir -p /os
    mount $mount_args /dev/disk/by-label/os /os

    # Mount the other partitions
    if is_efi; then
        mkdir -p /os/boot/efi
        mount /dev/disk/by-label/efi /os/boot/efi
    fi
    mkdir -p /os/installer
    mount $mount_args /dev/disk/by-label/installer /os/installer
}

get_dns_list_for_win() {
    if dns_list=$(get_current_dns $1); then
        i=0
        for dns in $dns_list; do
            i=$((i + 1))
            echo "set ipv${1}_dns$i=$dns"
        done
    fi
}

create_win_set_netconf_script() {
    target=$1
    info "Create win netconf script"

    if is_staticv4 || is_staticv6 || is_need_manual_set_dnsv6; then
        get_netconf_to mac_addr
        echo "set mac_addr=$mac_addr" >$target

        # Generate the static ipv4 configuration
        if is_staticv4; then
            get_netconf_to ipv4_addr
            get_netconf_to ipv4_gateway
            cat <<EOF >>$target
set ipv4_addr=$ipv4_addr
set ipv4_gateway=$ipv4_gateway
$(get_dns_list_for_win 4)
EOF
        fi

        # Generate the static ipv6 configuration
        if is_staticv6; then
            get_netconf_to ipv6_addr
            get_netconf_to ipv6_gateway
            cat <<EOF >>$target
set ipv6_addr=$ipv6_addr
set ipv6_gateway=$ipv6_gateway
EOF
        fi

        # the case where ipv6 exists but dns still needs setting
        if is_need_manual_set_dnsv6; then
            cat <<EOF >>$target
$(get_dns_list_for_win 6)
EOF
        fi

        cat -n $target
    fi

    # the script also turns off ipv6 privacy addresses, so it cannot be skipped
    # Merge the scripts
    wget $confhome/windows-set-netconf.bat -O- >>$target
    unix2dos $target
}

create_win_change_rdp_port_script() {
    target=$1
    rdp_port=$2

    info "Create win change rdp port script"

    echo "set RdpPort=$rdp_port" >$target
    wget $confhome/windows-change-rdp-port.bat -O- >>$target
    unix2dos $target
}

# virt-what must be the latest version
# vultr 1G High Frequency LAX is really kvm
# debian 11 virt-what 1.19 reports hyperv qemu
# debian 11 systemd-detect-virt reports microsoft
# alpine virt-what 1.25 reports kvm
# so do not determine the exact virtualization environment on the original system

# lscpu can also show the virtualization environment, but alpine on lightsail reports Microsoft
# presumably lscpu only consults cpuid and not dmi
# virt-what may output several lines, hence the grep

get_aws_repo() {
    echo https://s3.amazonaws.com/ec2-windows-drivers-downloads
}

# Convert an AC/SAC version number into an LTSC version number
# used for driver lookup
get_windows_name_by_version() {
    local nt_ver=$1
    local build_ver=$2
    local windows_type=$3

    local windows_name
    windows_name=$(
        case "$windows_type" in
        client)
            case "$nt_ver" in
            10.0)
                if [ "$build_ver" -ge 22000 ]; then
                    echo 11
                else
                    echo 10
                fi
                ;;
            6.3) echo 8.1 ;;
            6.2) echo 8 ;;
            6.1) echo 7 ;;
            6.0) echo vista ;;
            esac
            ;;

        server)
            case "$nt_ver" in
            10.0)
                if [ "$build_ver" -ge 26100 ]; then
                    echo 2025
                elif [ "$build_ver" -ge 20348 ]; then
                    echo 2022
                elif [ "$build_ver" -ge 17763 ]; then
                    echo 2019
                else
                    echo 2016
                fi
                ;;
            6.3) echo '2012 r2' ;;
            6.2) echo '2012' ;;
            6.1) echo '2008 r2' ;;
            6.0) echo '2008' ;;
            esac
            ;;
        esac
    )

    if [ -n "$windows_name" ]; then
        echo "$windows_name"
    else
        error_and_exit "Unknown Windows Version: $nt_ver $build_ver $windows_type"
    fi
}

is_nt_ver_ge() {
    local orig sorted
    orig=$(printf '%s\n' "$1" "$nt_ver")
    sorted=$(echo "$orig" | sort -V)
    [ "$orig" = "$sorted" ]
}

# reinstall.sh has a function of the same name
is_administrator_username() {
    username_in_lower=$(printf "%s" "$1" | to_lower)

    for builtin_username in \
        administrator \
        administrador \
        administrateur \
        administratör \
        администратор \
        järjestelmänvalvoja \
        rendszergazda; do
        if [ "$username_in_lower" = "$builtin_username" ]; then
            return 0
        fi
    done

    return 1
}

get_cloud_vendor() {
    # busybox blkid does not show the UUID of sr0
    apk add lsblk

    # http://git.annexia.org/?p=virt-what.git;a=blob;f=virt-what.in;hb=HEAD
    # virt-what can identify the vendor: aws google_cloud alibaba_cloud alibaba_cloud-ebm
    if is_dmi_contains "Amazon EC2" || is_virt_contains aws; then
        echo aws
    elif is_dmi_contains "Google Compute Engine" || is_dmi_contains "GoogleCloud" || is_virt_contains google_cloud; then
        echo gcp
    elif is_dmi_contains "OracleCloud"; then
        echo oracle
    elif is_dmi_contains "7783-7084-3265-9085-8269-3286-77"; then
        echo azure
    elif lsblk -o UUID,LABEL | grep -i 9796-932E | grep -iq config-2; then
        echo ibm
    elif is_dmi_contains 'Huawei Cloud'; then
        echo huawei
    elif is_dmi_contains 'Alibaba Cloud'; then
        echo aliyun
    elif is_dmi_contains 'Tencent Cloud'; then
        echo qcloud
    fi
}

get_filesize_mb() {
    du -m "$1" | awk '{print $1}'
}

mkdir_clear() {
    local dir=$1

    if [ -z "$dir" ] || [ "$dir" = / ]; then
        return
    fi

    rm -rf "$dir"
    mkdir -p "$dir"
}

# Note the calling convention is list=$(list_add "$list" "$item_to_add")
list_add() {
    local list=$1
    local item_to_add=$2
    if [ -n "$list" ]; then
        echo "$list"
    fi
    echo "$item_to_add"
}

is_list_has() {
    local list=$1
    local item=$2
    echo "$list" | grep -qFx "$item"
}

# reinstall.sh has a function of the same name
get_drivers() {
    (
        cd "$(readlink -f $1)"
        while ! [ "$(pwd)" = / ]; do
            if [ -d driver ]; then
                if [ -d driver/module ]; then
                    basename "$(readlink -f driver/module)"
                else
                    basename "$(readlink -f driver)"
                fi
            fi
            cd ..
        done
    )
}

get_windows_type_from_windows_drive() {
    local os_dir=$1

    apk add hivex-perl
    system_hive=$(find_file_ignore_case $os_dir/Windows/System32/config/SYSTEM)
    product_type=$(hivexget $system_hive '\ControlSet001\Control\ProductOptions' ProductType)
    apk del hivex-perl

    # ProductType and InstallationType both distinguish client from server systems
    # for drivers, ProductType is the one used
    # https://learn.microsoft.com/windows-hardware/drivers/install/inf-manufacturer-section
    # NTamd64.10.0       # no ProductType restriction
    # NTamd64.10.0.1     # only accepts systems whose ProductType is 1

    # testing confirms ProductType is used
    # after right-clicking e1d.inf to install the driver on win11 and forcing a driver for any NIC in task manager, the list shows:
    # win11 enterprise    has     i218-V/i-219V, has i218-LM/i219-LM
    # win11 multi-session has not  i218-V/i-219V, has i218-LM/i219-LM

    case "$product_type" in
    WinNT) echo client ;;
    LanmanNT | ServerNT) echo server ;;
    *) error_and_exit "Unexpected Product Type: $product_type" ;;
    esac
}

get_windows_arch_from_windows_drive() {
    local os_dir=$1

    apk add hivex-perl
    hive=$(find_file_ignore_case $os_dir/Windows/System32/config/SYSTEM)
    # no CurrentControlSet
    hivexget $hive 'ControlSet001\Control\Session Manager\Environment' PROCESSOR_ARCHITECTURE
    apk del hivex-perl
}

get_intel_download_url() {
    local id=$1
    local file_regex=$2

    local url=https://www.intel.com/content/www/us/en/download/$id.html

    # Replace the double quotes with newlines so each link is on its own line
    # intel blocks wget from downloading the page
    wget -U curl/7.54.1 "$url" -O- | sed 's,",\n,g' |
        grep -Eio -m1 "https://.+/$file_regex" | grep .
}

apk_add_from_edge() {
    # Download the newer package from the edge/community repository
    # not needed at the moment
    local alpine_mirror
    alpine_mirror=$(grep '^http.*/main$' /etc/apk/repositories | sed 's,/[^/]*/main$,,' | head -1)
    apk add --repository "$alpine_mirror/edge/community" \
        --force-non-repository \
        --virtual edge \
        "$@"
}

apk_del_edge() {
    apk del edge
}

install_windows() {
    get_wim_prop() {
        wim=$1
        property=$2

        wiminfo "$wim" | grep -i "^$property:" | cut -d: -f2- | trim
    }

    get_image_prop() {
        wim=$1
        index=$2
        property=$3

        wiminfo "$wim" "$index" | grep -i "^$property:" | cut -d: -f2- | trim
    }

    info "Process windows iso"
    mkdir -p /iso /wim

    # find_file_ignore_case is in this file too
    # shellcheck disable=SC1090
    . <(wget -O- $confhome/windows-driver-utils.sh)

    apk add wimlib

    download $iso /os/windows.iso
    mount -o ro /os/windows.iso /iso

    sources_boot_wim=$(
        cd /iso
        find_file_ignore_case sources/boot.wim 2>/dev/null ||
            error_and_exit "can't find boot.wim"
    )

    # most images use install.wim
    # en_server_install_disc_windows_home_server_2011_x64_dvd_658487.iso uses Install.wim
    # en_windows_vista_sp2_with_update_6003.23713_aio_7in1_x64_v26.01.13_by_adguard.iso uses swm
    source_install_wim=$(
        cd /iso
        {
            find_file_ignore_case sources/install.wim ||
                find_file_ignore_case sources/install.esd ||
                find_file_ignore_case sources/install.swm
        } 2>/dev/null || error_and_exit "can't find install.wim, install.esd or install.swm"
    )

    is_swm=false
    if [[ $(echo "$source_install_wim" | to_lower) = '*.swm' ]]; then
        is_swm=true
        swm_ref=$(
            IFS=. read -r name ext < <(basename "$source_install_wim")
            echo "$name*.$ext"
        )
    fi

    # guard against an iso of an incompatible architecture
    boot_index=$(get_wim_prop "/iso/$sources_boot_wim" 'Boot Index')
    arch_wim=$(get_image_prop "/iso/$sources_boot_wim" "$boot_index" 'Architecture' | to_lower)
    if ! {
        { [ "$(uname -m)" = "x86_64" ] && [ "$arch_wim" = x86_64 ]; } ||
            { [ "$(uname -m)" = "x86_64" ] && [ "$arch_wim" = x86 ]; } ||
            { [ "$(uname -m)" = "aarch64" ] && [ "$arch_wim" = arm64 ]; }
    }; then
        error_and_exit "The machine is $(uname -m), but the iso is $arch_wim."
    fi

    # an efi machine cannot install 32-bit windows
    if is_efi && [ "$arch_wim" = x86 ]; then
        error_and_exit "EFI machine can't install 32-bit Windows."
    fi

    iso_install_wim=/iso/$source_install_wim
    install_wim=/os/installer/$source_install_wim

    # Match the image edition
    # the whole line must match, to tell Windows 10 Pro from Windows 10 Pro for Workstations
    image_count=$(wiminfo $iso_install_wim | grep "^Image Count:" | cut -d: -f2 | trim)
    all_image_names=$(wiminfo $iso_install_wim | grep ^Name: | sed 's/^Name: *//')
    info "Images Count: $image_count"
    echo "$all_image_names"
    echo

    if [ "$image_count" = 1 ]; then
        # with only one edition, use it
        image_name=$all_image_names
        iso_image_index=1
    else
        while true; do
            # matched
            # correct the letter case
            if matched_image_name=$(printf '%s\n' "$all_image_names" | grep -Fix "$image_name"); then
                image_name=$matched_image_name
                iso_image_index=$(wiminfo "$iso_install_wim" "$image_name" | grep 'Index:' | awk '{print $NF}')
                break
            fi

            # no match
            file=/image-name
            error "Invalid image name: $image_name"
            echo "Choose a correct image name by one of follow command in ssh to continue:"
            while read -r line; do
                echo "  echo '$line' >$file"
            done < <(echo "$all_image_names")

            # sleep until there is input
            true >$file
            while ! { [ -s $file ] && image_name=$(cat $file) && [ -n "$image_name" ]; }; do
                sleep 1
            done
        done
    fi

    get_selected_image_prop() {
        get_image_prop "$iso_install_wim" "$iso_image_index" "$1"
    }

    # does ProductType become LanmanNT when Windows Server acts as a domain server?
    # https://cloud.tencent.com/developer/article/2465206
    # https://github.com/search?q=InstallationType+Client+Embedded+Server+Core&type=code
    # https://learn.microsoft.com/azure/virtual-desktop/windows-multisession-faq#why-does-my-application-report-windows-enterprise-multi-session-as-a-server-operating-system

    # the information comes from the registry, because some install.wim files lack the attributes
    # Azure offers Windows 10/11 Enterprise multi-session
    # HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\InstallationType
    # HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\ProductOptions\ProductType
    # HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\ProductOptions\ProductSuite

    # system                                InstallationType    ProductType    ProductSuite
    # Windows Client (ordinary Windows)     Client              WinNT          Terminal Server
    # Windows 10/11 Enterprise multi-session  Client              ServerNT       Terminal Server
    # Windows Server 2012 R2 Desktop Exp.   Server              ServerNT       Terminal Server and DataCenter (two lines)
    # Windows Server 2012 R2 Core           Server Core         ServerNT       Terminal Server and DataCenter (two lines)
    # Windows Server 2025 Desktop Exp.      Server              ServerNT       Enterprise
    # Windows Server 2025 Core              Server Core         ServerNT       Enterprise
    # WES7 / Thin PC                         Embedded           WinNT        Terminal Server

    mount_iso_install_wim_to() {
        local dir=$1

        mkdir -p "$dir"
        # shellcheck disable=SC2046
        wimmount "$iso_install_wim" "$iso_image_index" "$dir" \
            $($is_swm && echo "--ref=$(dirname "$iso_install_wim")/$swm_ref")
    }

    # Mount install.wim and check
    # 1. whether it ships the sac component
    # 2. whether it ships an nvme driver
    # 3. whether it supports sha256
    # 4. Installation Type
    mount_iso_install_wim_to /wim

    # Get the version number
    get_windows_version_from_windows_drive /wim

    # Detect client/server and convert to the standard windows name
    # used to map Hyper-V Server / Azure Stack HCI / Windows Server AC versions onto the matching LTSC version for driver lookup
    windows_type=$(get_windows_type_from_windows_drive /wim)
    product_ver=$(get_windows_name_by_version "$nt_ver" "$build_ver" "$windows_type")

    # Detect sac and nvme
    {
        find_file_ignore_case /wim/Windows/System32/sacsess.exe && has_sac=true || has_sac=false
        find_file_ignore_case /wim/Windows/System32/drivers/stornvme.sys && has_stornvme=true || has_stornvme=false
    } >/dev/null 2>&1

    # Detect whether sha256-signed drivers are supported
    support_sha256=false
    if is_nt_ver_ge 6.2; then
        support_sha256=true
    else
        # in the install environment drvload.exe does not verify signatures and can load a sha256 driver,
        # but after a reboot it reports: Windows cannot verify the digital signature for this file.

        # winload.exe/efi contains this string
        # Windows cannot verify the digital signature for this file.
        # strings -e l winload.exe | grep -i signature
        # strings -e l winload.efi | grep -i signature

        # disk controller drivers are boot-start drivers, whose signature winload.exe/efi verifies
        # NIC drivers are not boot-start drivers; ci.dll verifies those

        # the win7 sp1 iso does not support sha256 drivers, yet
        # ci.dll      contains the 8+64 constants and oids 0609608648016503040201 0102040365014886600906
        # winload.exe contains the 8+64 constants and oids 0609608648016503040201 0102040365014886600906
        # winload.efi contains the 8+64 constants and oid      608648016503040201

        # the docs mention KB3033929 and KB4039648, presumably the earliest sha256 patches for 2008r2 and 2008
        # https://support.microsoft.com/kb/4472027#:~:text=KB3033929%20%E5%92%8C%20KB4039648
        # https://support.drweb.cn/sha2
        # https://support.kaspersky.com/common/compatibility/15761
        # https://www.internetdownloadmanager.com/register/new_faq/sha256-support-for-outdated-versions-of-Windows.html
        # https://www.catalog.update.microsoft.com/

        # vista sp2 iso
        # testing KB4039648 and KB4090450 installed on their own, the registry shows no trace of the other KB
        # many later patches that include winload.exe/efi also carry sha256 support, so the KB number cannot be used to decide
        # HKEY_LOCAL_MACHINE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Package
        # HKEY_LOCAL_MACHINE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackageDetect

        # installing the following patches individually on a vista sp2 iso:
        # patch          released    BuildLabEx           ubr   winload.exe   winload.efi   ci.dll
        # KB4039648 old  2018/2/21   6002.18005(unchanged) no   6002.24259    6002.24283    6002.24259
        # KB4039648 new  2018/3/22   6002.18005(unchanged) no   6002.24259    6002.24298    6002.24259
        # KB4039648-v2   2018/6/12   6002.24381            no   6002.24362    6002.24381    6002.24259
        # KB4474419-v4   2019/10/8   6003.20555            no   6003.20505    6003.20555    6003.20593

        # installing the following patches individually on a win7 sp1 iso:
        # KB3033929      2015/3/10   7601.18741            no   18649/22854   18741/22948   18519/22730
        # KB4474419-v3   2019/9/10   7601.24384            no        24149         24384         24158

        # the earliest KB4039648 and KB3033929 both support sha256
        # the winload.exe/efi version is >= the ci.dll version,
        # so use the winload.exe/efi version to decide whether sha256 is supported

        apk add pev
        local maj min build rev
        winload=$(find_file_ignore_case "/wim/Windows/System32/winload.$(is_efi && echo efi || echo exe)")
        IFS=. read -r maj min build rev \
            < <(peres -v "$winload" | grep 'Product Version:' | awk '{print $NF}')
        apk del pev

        # vista/2008
        # https://support.microsoft.com/kb/KB4039648
        # https://catalog.update.microsoft.com/Search.aspx?q=KB4039648

        # the win7/2008r2 page lists the file version numbers
        # https://support.microsoft.com/kb/KB3033929
        # https://catalog.update.microsoft.com/Search.aspx?q=KB3033929

        # rev 1xxxx is the GDR branch
        # rev 2xxxx is the LDR branch

        # for vista/2008 the version goes from 6002 to 6003 and the rev drops by 4000
        # https://support.microsoft.com/topic/1335e4d4-c155-52eb-4a45-b85bd1909ca8

        if is_efi; then
            if { [ "$maj.$min" = 6.1 ] && [ "$build" -eq 7601 ] && [ "$rev" -ge 22948 ]; } ||
                { [ "$maj.$min" = 6.1 ] && [ "$build" -eq 7601 ] && [ "$rev" -ge 18741 ] && [ "$rev" -lt 20000 ]; } ||
                { [ "$maj.$min" = 6.0 ] && [ "$build" -eq 6003 ] && [ "$rev" -ge 20283 ]; } ||
                { [ "$maj.$min" = 6.0 ] && [ "$build" -eq 6002 ] && [ "$rev" -ge 24283 ]; }; then
                support_sha256=true
            fi
        else
            if { [ "$maj.$min" = 6.1 ] && [ "$build" -eq 7601 ] && [ "$rev" -ge 22854 ]; } ||
                { [ "$maj.$min" = 6.1 ] && [ "$build" -eq 7601 ] && [ "$rev" -ge 18649 ] && [ "$rev" -lt 20000 ]; } ||
                { [ "$maj.$min" = 6.0 ] && [ "$build" -eq 6003 ] && [ "$rev" -ge 20259 ]; } ||
                { [ "$maj.$min" = 6.0 ] && [ "$build" -eq 6002 ] && [ "$rev" -ge 24259 ]; }; then
                support_sha256=true
            fi
        fi
    fi

    wimunmount /wim/

    info "Selected image info"
    echo "Image Name: $image_name"
    echo "Product Version: $product_ver"
    echo "Windows Type: $windows_type"
    echo "NT Version: $nt_ver"
    echo "Build Version: $build_ver"
    echo "Revision Version: $rev_ver"
    echo "-------------------------"
    echo "Has SAC: $has_sac"
    echo "Has StorNVMe: $has_stornvme"
    echo "Support SHA256: $support_sha256"
    echo "-------------------------"
    echo

    # Copy boot.wim into /os for temporary editing
    if [ -n "$boot_wim" ]; then
        # custom boot.wim link
        download "$boot_wim" /os/boot.wim
    else
        cp /iso/$sources_boot_wim /os/boot.wim
    fi

    # for efi the boot directory is the efi partition
    # for bios it is the os partition
    if is_efi; then
        boot_dir=/os/boot/efi
    else
        boot_dir=/os
    fi

    # Copy the files starting with boot from the iso root
    echo 'Copying boot files...'
    find /iso -maxdepth 1 -iname 'boot*' -exec cp -r {} "$boot_dir" \;

    # for efi, also copy the efi folder from the iso root
    if is_efi; then
        echo 'Copying efi files...'
        find /iso -maxdepth 1 -type d -iname efi -exec cp -r {} "$boot_dir" \;
    fi

    # Copy every iso file (except boot.wim) to the installer partition
    echo 'Copying installer files...'
    if false; then
        # case must be ignored as well
        rsync -rv \
            --exclude=/sources/boot.wim \
            --exclude=/sources/install.wim \
            --exclude=/sources/install.esd \
            --exclude='/sources/install*.swm' \
            /iso/* /os/installer/
    else
        (
            cd /iso
            find . -type f \
                -not -iname boot.wim \
                -not -iname install.wim \
                -not -iname install.esd \
                -not -iname 'install*.swm' \
                -exec cp -r --parents {} /os/installer/ \;
        )
    fi

    # $iso_image_index is the image wim index inside the original iso
    # $image_index is the image wim index after copying to installer

    # a swm must be merged into a wim before it can be edited
    if $is_swm; then
        install_wim=$(echo "$install_wim" | sed 's/\.swm$/.wim/i')
        # avoid the "file already exists" error on a second run without reformatting
        rm -f "$install_wim"
        wimexport --ref="$(dirname "$iso_install_wim")/$swm_ref" "$iso_install_wim" "$iso_image_index" "$install_wim"
        # only the image being installed was exported, so image_index is 1
        image_index=1
    elif false; then
        # Optimize install.wim
        # upside: saves 200M~600M that can be used for the pagefile
        #         (of little value, since boot.wim was already deleted for that purpose, except on vista)
        # downside: if install.wim holds only one image, it shrinks by just 10M or so
        time wimexport --threads "$(get_build_threads 512)" "$iso_install_wim" "$iso_image_index" "$install_wim"
        # only the image being installed was exported, so image_index is 1
        image_index=1
        info "install.wim size"
        echo "Original:  $(get_filesize_mb "$iso_install_wim")"
        echo "Optimized: $(get_filesize_mb "$install_wim")"
        echo
    else
        cp "$iso_install_wim" "$install_wim"
        image_index="$iso_image_index"
    fi

    # win11 requires 1GHz and 2 cores (one core with hyperthreading also counts)
    # the check uses the Installation Type in the install.wim metadata, not the one in its registry
    # 7601.24214.180801-1700.win7sp1_ldr_escrow_CLIENT_ULTIMATE_x64FRE_en-us.iso has no Installation Type in the wim
    # Vista has InstallationType in neither the wim nor the registry
    installation_type_from_install_wim_metadata=$(get_selected_image_prop "Installation Type" 2>/dev/null || true)

    # the registry cannot be used to bypass this during installation
    # https://github.com/pbatard/rufus/issues/1990
    # https://learn.microsoft.com/windows/iot/iot-enterprise/Hardware/System_Requirements
    # older win11 installers (before 24h2) cannot skip the core-count check with setup.exe /product server, so it is lifted in the xml

    # windows 11 multi-session is identified as server 2022 from the registry for driver matching, so "$product_ver" is 2022 rather than 11
    # hence the condition here is not [ "$product_ver" = "11" ]
    if [ "$build_ver" -ge 22000 ] &&
        [ "$(echo "$installation_type_from_install_wim_metadata" | to_lower)" = "client" ] &&
        [ "$(nproc)" -le 1 ]; then
        wiminfo "$install_wim" "$image_index" --image-property WINDOWS/INSTALLATIONTYPE=Server
    fi

    # variable    where it is used
    # arch_uname  the arch command / uname -m           x86_64   aarch64
    # arch_wim   wiminfo                             x86  x86_64   ARM64
    # arch       virtio iso / unattend.xml / .inf    x86  amd64    arm64
    # arch_xdd    virtio msi / xen drivers        x86      x64
    # arch_dd     huawei cloud drivers            32       64

    # Convert the wim arch into the arch used by drivers and the answer file
    case "$arch_wim" in
    x86)
        arch=x86
        arch_xdd=x86
        arch_dd=32
        ;;
    x86_64)
        arch=amd64
        arch_xdd=x64
        arch_dd=64
        ;;
    arm64)
        arch=arm64
        arch_xdd= # xen has no arm64 driver, and virtio has no arm64 msi either
        arch_dd=  # huawei cloud has no arm64 driver
        ;;
    esac

    # win7 drvload can load sha256-signed drivers,
    # but after the install completes the reboot fails with: windows cannot verify the digital signature for this file
    # F8 must be pressed to disable driver signature enforcement

    add_drivers() {
        info "Add drivers"

        # temporary folder for driver downloads
        drv=/os/drivers
        mkdir_clear "$drv"

        # a trap here:
        # $(get_cloud_vendor) calls cache_dmi_and_virt
        # but $(get_cloud_vendor) runs in a subshell,
        # and the variables set inside vanish when the subshell exits,
        # so run cache_dmi_and_virt first
        cache_dmi_and_virt
        vendor="$(get_cloud_vendor)"

        # virtio
        if is_virt_contains virtio; then
            if [ "$vendor" = aliyun ] && is_nt_ver_ge 6.1 && [ "$arch_wim" = x86_64 ]; then
                add_driver_aliyun_virtio
            elif [ "$vendor" = qcloud ] && is_nt_ver_ge 6.1 && [ "$arch_wim" = x86_64 ]; then
                add_driver_qcloud_virtio
            # untested whether a dedicated driver is required
            elif false && [ "$vendor" = huawei ] && is_nt_ver_ge 6.0 && { [ "$arch_wim" = x86 ] || [ "$arch_wim" = x86_64 ]; }; then
                add_driver_huawei_virtio

            # the official gcp drivers are incomplete, so fill the gaps with the generic ones
            # the official windows server template has no viorng device, but the linux template does
            elif [ "$vendor" = gcp ] && is_nt_ver_ge 6.1 && [ "$arch_wim" = x86 ] && $support_sha256; then
                add_driver_gcp_virtio
                add_driver_generic_virtio \( -iname viorng.inf -or -iname pvpanic.inf \)

            elif [ "$vendor" = gcp ] && is_nt_ver_ge 6.1 && [ "$arch_wim" = x86_64 ] && $support_sha256; then
                add_driver_gcp_virtio
                add_driver_generic_virtio -iname viorng.inf

            elif [ "$vendor" = gcp ] && [ "$nt_ver" = 6.1 ] && [ "$arch_wim" = x86_64 ] && ! $support_sha256; then
                add_driver_gcp_virtio_win6_1_sha1_x64
                add_driver_generic_virtio \( -iname viorng.inf -or -iname balloon.inf \)

            else
                # fallback
                add_driver_generic_virtio
            fi
        fi

        # xen
        if is_virt_contains xen; then
            # generic_xen as a fallback, but it is unsigned, so it is disabled for now
            if is_nt_ver_ge 6.1 && [ "$arch_wim" = x86_64 ]; then
                add_driver_aws_xen
            elif is_nt_ver_ge 6.0 && { [ "$arch_wim" = x86 ] || [ "$arch_wim" = x86_64 ]; }; then
                add_driver_citrix_xen
            fi
        fi

        # vmd
        # RST v17 does not support vmd
        # the RST v18 inf requires 15063 or newer
        # the RST v19 inf requires 15063 or newer and covers every hardware id in v18
        # the RST v20 inf requires 19041 or newer
        # the RST v21 inf requires 19041 or newer
        if [ -d /sys/module/vmd ] && [ "$build_ver" -ge 15063 ] && [ "$arch_wim" = x86_64 ]; then
            add_driver_vmd
        fi

        # the primary NIC, which has an IP address
        # root@localhost:~# get_drivers /sys/class/net/eth0
        # hv_netvsc

        # the accelerated NIC, which has no IP address
        # root@localhost:~# get_drivers /sys/class/net/enP30832s1
        # mana
        # pci_hyperv

        # vpci
        # the equivalent of pci_hyperv on linux
        # the win10 ltsc 2021 boot.wim has no vpci.sys, so the azure nvme disk is not found
        # it has to be extracted from install.wim
        # PE needs no network, so there is no need to check whether the NIC uses pci_hyperv
        if [ -d /sys/module/pci_hyperv ] &&
            get_drivers "/sys/block/$xda" | grep -qx pci_hyperv &&
            ! find_file_ignore_case /wim/Windows/System32/drivers/vpci.sys >/dev/null 2>&1; then
            add_driver_vpci
        fi

        # vendor drivers
        case "$vendor" in
        aws)
            if is_nt_ver_ge 6.1 && { [ "$arch_wim" = x86_64 ] || [ "$arch_wim" = arm64 ]; }; then
                add_driver_aws
            fi
            ;;
        azure)
            # the inf has no version restriction; untested
            if [ "$arch_wim" = x86 ] || [ "$arch_wim" = x86_64 ]; then
                add_driver_azure
            fi
            ;;
        gcp)
            # the inf has no version restriction; 6.0 installs but does not work
            # available for x86, x86_64 and arm64
            add_driver_gcp
            ;;
        esac

        # intel NIC drivers
        # the official site offers no vista/2008 driver
        # the win7 driver inf/ndis does not support vista/2008
        if is_nt_ver_ge 6.1 && { [ "$arch_wim" = x86 ] || [ "$arch_wim" = x86_64 ]; } &&
            grep -iq 8086 /sys/class/net/e*/device/vendor; then
            add_driver_intel_nic
        fi

        # custom drivers
        add_driver_custom
    }

    add_driver_intel_nic() {
        info "Add drivers: Intel NIC"

        arch_intel=$(
            case "$arch_wim" in
            x86) echo 32 ;;
            x86_64) echo x64 ;;
            esac
        )

        url=$(
            case "$product_ver" in
            '7' | '2008 r2')
                # the official site now only has 25.0
                # 25.0 only updates the ProSet software over 24.5; the drivers are identical
                # some 25.0 files are sha256 signed
                # every 24.3 file is sha1 signed
                # https://web.archive.org/web/20250405130938/https://www.intel.com/content/www/us/en/download/15590/29323/intel-network-adapter-driver-for-windows-7-final-release.html
                echo https://downloadmirror.intel.com/18713/eng/prowin${arch_intel}legacy.exe
                ;;
            '8' | '8.1')
                # there used to be Intel(R) Network Adapter Driver for Windows 8* - Final Release, version 22.7.1,
                # but it was removed for reasons unknown
                # https://web.archive.org/web/20250501043104/https://www.intel.com/content/www/us/en/download/16765/intel-network-adapter-driver-for-windows-8-final-release.html
                # 27.8 has an NDIS63 folder, which means Windows 8 is supported
                # 27.8 may drop support for some older devices compared with 22.7.1, but that is acceptable
                echo https://downloadmirror.intel.com/764813/Wired_driver_27.8_${arch_intel}.zip
                ;;
            '2012' | '2012 r2')
                echo https://downloadmirror.intel.com/772074/Wired_driver_28.0_${arch_intel}.zip
                ;;
            # 2016 2019 2022 2025 win10 win11
            *) case "${arch_intel}" in
                32)
                    echo https://downloadmirror.intel.com/849483/Wired_driver_30.0.1_${arch_intel}.zip
                    ;;
                x64)
                    id=$(
                        case "$product_ver" in
                        10) echo 18293 ;;
                        11) echo 727998 ;;
                        2016) echo 18737 ;;
                        2019) echo 19372 ;;
                        2022) echo 706171 ;;
                        2025) echo 838943 ;;
                        esac
                    )
                    get_intel_download_url "$id" "(Wired_driver|prowin).*${arch_intel}(legacy)?\.(zip|exe)"
                    ;;
                esac ;;
            esac
        )

        # note that intel blocks aria2 downloads
        # and uses aws waf, so a browser must fetch the aws-waf-token cookie via js before downloading
        download_via_browser "$url" $drv/intel.zip

        # the inf may be UTF-16 LE, hence searching with rg
        # extracting the win10 driver with busybox unzip glues the path and filename together
        # and extracting the 28.0 driver still hits the same problem,
        # so convert_backslashes is needed
        apk add unzip ripgrep

        # https://superuser.com/questions/1382839/zip-files-expand-with-backslashes-on-linux-no-subdirectories
        convert_backslashes() {
            for file in "$1"/*\\*; do
                if [ -f "$file" ]; then
                    target="${file//\\//}"
                    mkdir -p "${target%/*}"
                    mv -v "$file" "$target"
                fi
            done
        }

        # the win7 driver is an .exe and extracts without error
        # the win10 driver is a .zip and errors out instead; the zip file looks malformed
        # extracting the win8 driver on windows reports a checksum error
        unzip -o -d $drv/intel/ $drv/intel.zip || true
        convert_backslashes $drv/intel

        is_have_inf_in_intel_dir() {
            find $drv/intel -ipath "*/*.inf" | grep . >/dev/null
        }

        # Wired_driver_28.0_x64.zip needs extracting twice
        if ! is_have_inf_in_intel_dir; then
            unzip -o -d $drv/intel/ $drv/intel/Wired_driver_*.exe || true
            convert_backslashes $drv/intel
        fi

        # since || true was used above, confirm an inf file actually appeared
        if ! is_have_inf_in_intel_dir; then
            error_and_exit "No .inf file found in intel driver package"
        fi

        # Vista RTM is version 6000    NDIS 6.0
        # 2008  RTM is version 6001    NDIS 6.1

        # Work out the lowest system version each driver folder supports
        # 1. a driver may restrict itself to windows client or server, but we do not distinguish
        #    if it will not install, no harm done; if it installs but does not load, the user can force it in device manager
        # 2. the site says the win10 driver needs RS5 1809, but the package has an NDIS65 folder, i.e. 10240 is supported
        # 3. the NDIS65 folder may really require NDIS 6.51, but leave that for now
        # https://learn.microsoft.com/en-us/windows-hardware/drivers/network/overview-of-ndis-versions
        min_support_map=$(cat <<EOF |
6000  NDIS60
6001  NDIS61
7600  NDIS62
9200  NDIS63
9600  NDIS64
10240 NDIS65
14393 NDIS66
15063 NDIS67
16299 NDIS68
20348 WS2022
22000 W11
26100 WS2025
EOF
            case "$windows_type" in
            client) grep -E ' (NDIS|W)[0-9]' ;;
            server) grep -E ' (NDIS|WS)[0-9]' ;;
            esac)

        for ethx in $(get_eths); do
            sys_dir=$(get_sys_dir_for_eth $ethx)
            ven=$(cat $sys_dir/vendor | sed 's/^0x//')
            dev=$(cat $sys_dir/device | sed 's/^0x//')
            subsys=$(cat $sys_dir/subsystem_device $sys_dir/subsystem_vendor | sed 's/^0x//' | tr -d '\n')
            rev=$(cat $sys_dir/revision | sed 's/^0x//')

            info "intel nic"
            echo "Ethernet: $ethx"
            echo "Vendor: $ven"
            echo "Device: $dev"
            echo "Subsystem: $subsys"
            echo "Revision: $rev"

            compatible_ids="VEN_$ven&DEV_$dev&SUBSYS_$subsys&REV_$rev"
            compatible_ids="$compatible_ids|VEN_$ven&DEV_$dev&SUBSYS_$subsys"
            compatible_ids="$compatible_ids|VEN_$ven&DEV_$dev&REV_$rev"
            compatible_ids="$compatible_ids|VEN_$ven&DEV_$dev"

            while read -r min_ver ndis; do
                if [ "$build_ver" -ge "$min_ver" ]; then
                    # PE only?
                    # present:  intel\Release_30.0.zip\PROXGB\Win32\NDIS68\WinPE\*.inf
                    # absent:   intel\Release_30.0.zip\PROXGB\Win32\NDIS68\*.inf

                    # find exits 0 as long as $drv/intel exists
                    # rg does not need -E
                    # prefer the non-WinPE one
                    if infs=$(find $drv/intel -ipath "*/Win$arch_intel/$ndis/*.inf" -exec rg -iwl "$compatible_ids" {} \; | grep . ||
                        find $drv/intel -ipath "*/Win$arch_intel/$ndis/WinPE/*.inf" -exec rg -iwl "$compatible_ids" {} \; | grep .); then
                        for inf in $infs; do
                            cp_drivers $inf
                        done
                        break
                    fi
                fi
            done < <(echo "$min_support_map" | tac) # reverse order
        done

        apk del unzip ripgrep
    }

    # aws nitro
    # https://docs.aws.amazon.com/AWSEC2/latest/WindowsGuide/aws-nvme-drivers.html
    # https://docs.aws.amazon.com/AWSEC2/latest/WindowsGuide/enhanced-networking-ena.html
    add_driver_aws() {
        info "Add drivers: AWS"

        # an unpatched win7 cannot use sha256-signed drivers
        nvme_ver=$(
            case "$nt_ver" in
            6.1) echo 1.3.2 ;; # sha1 signature
            6.2 | 6.3) echo 1.5.1 ;;
            *) echo Latest ;;
            esac
        )

        ena_ver=$(
            case "$nt_ver" in
            6.1) $support_sha256 && echo 2.2.3 || echo 2.1.4 ;;
            6.2 | 6.3) echo 2.6.0 ;;
            *) echo Latest ;;
            esac
        )

        [ "$arch_wim" = arm64 ] && arch_dir=/ARM64 || arch_dir=

        # the arm64 AWSNVMe.zip has been removed from the server
        if ! [ "$arch_wim" = arm64 ]; then
            download "$(get_aws_repo)/NVMe$arch_dir/$nvme_ver/AWSNVMe.zip" $drv/AWSNVMe.zip
            unzip -o -d $drv/aws/ $drv/AWSNVMe.zip
        fi

        download "$(get_aws_repo)/ENA$arch_dir/$ena_ver/AwsEnaNetworkDriver.zip" $drv/AwsEnaNetworkDriver.zip
        unzip -o -d $drv/aws/ $drv/AwsEnaNetworkDriver.zip

        cp_drivers $drv/aws
    }

    # citrix xen
    add_driver_citrix_xen() {
        info "Add drivers: Citrix Xen"

        apk add 7zip
        download https://s3.amazonaws.com/ec2-downloads-windows/Drivers/Citrix-Win_PV.zip $drv/Citrix-Win_PV.zip
        unzip -o -d $drv $drv/Citrix-Win_PV.zip
        case "$arch_wim" in
        x86) override=s ;;    # skip
        x86_64) override=a ;; # always
        esac
        # exclude $PLUGINSDIR and $TEMP
        exclude='$*'
        7z x $drv/Citrix_xensetup.exe -o$drv/xen/ -ao$override -x!$exclude

        cp_drivers $drv/xen
    }

    # aws xen
    # https://docs.aws.amazon.com/AWSEC2/latest/WindowsGuide/xen-drivers-overview.html
    add_driver_aws_xen() {
        info "Add drivers: AWS Xen"

        apk add msitools

        # the 8.4.3+ xenbus driver is picky about the OS the instance was created with
        # instances created from windows support 8.4.3+
        # instances created from linux do not

        # created from linux + installing 8.4.3:
        # installing via msi does not enable xenbus, so it boots but has no network
        # installing via inf does enable xenbus, so it does not boot at all

        apk add lscpu
        hypervisor_vendor=$(lscpu | grep 'Hypervisor vendor:' | awk '{print $3}')
        apk del lscpu

        aws_pv_ver=$(
            case "$nt_ver" in
            6.1) $support_sha256 && echo 8.3.5 || echo 8.3.2 ;;
            6.2 | 6.3)
                case "$hypervisor_vendor" in
                Xen) echo 8.3.5 ;;       # instance originally created from Linux
                Microsoft) echo 8.4.3 ;; # instance originally created from Windows
                esac
                ;;
            *)
                case "$hypervisor_vendor" in
                Xen) echo 8.3.5 ;;        # instance originally created from Linux
                Microsoft) echo Latest ;; # instance originally created from Windows
                esac
                ;;
            esac
        )

        url=$(
            case "$aws_pv_ver" in
            8.3.2) echo https://web.archive.org/web/20221016194548/https://s3.amazonaws.com/ec2-windows-drivers-downloads/AWSPV/$aws_pv_ver/AWSPVDriver.zip ;; # win7 sha1
            *) echo "$(get_aws_repo)/AWSPV/$aws_pv_ver/AWSPVDriver.zip" ;;
            esac
        )

        download "$url" $drv/AWSPVDriver.zip

        unzip -o -d $drv $drv/AWSPVDriver.zip
        mkdir -p $drv/xen/
        msiextract $drv/AWSPVDriverSetup.msi -C $drv/xen/

        cp_drivers $drv/xen/.Drivers
    }

    # citrix xen
    # https://pvupdates.vmd.citrix.com/updates.json 7.2.0.1555
    # https://pvupdates.vmd.citrix.com/updates.v9.json 9.3.3.125
    # https://pvupdates.vmd.citrix.com/autoupdate.v1.json 9.3.3.125
    # https://pvupdates.vmd.citrix.com/autoupdate.v2.json 9.4.0.146
    # https://support.citrix.com/s/article/CTX235403-updates-to-xenserver-vm-tools-for-windows-for-xenserver-and-citrix-hypervisor

    # highest version
    # 2012 r2   9.3.1
    # 2012      9.3.0
    # 2008 (r2) 7.2.0.1555

    # 9.3.1
    # https://downloads.xenserver.com/vm-tools-windows/9.3.1/managementagentx64.msi
    # http://downloadns.citrix.com.edgesuite.net/17461/managementagentx64.msi

    # 7.2.0.1555
    # http://downloadns.citrix.com.edgesuite.net/14656/managementagentx64.msi
    # http://downloadns.citrix.com.edgesuite.net/14655/managementagentx86.msi

    # xen
    # unsigned, so the aws driver is used instead for now
    # https://lore.kernel.org/xen-devel/E1qKMmq-00035B-SS@xenbits.xenproject.org/
    # https://xenbits.xenproject.org/pvdrivers/win/
    # tested on aws t2: installing xenbus blue-screens; with the other seven drivers it boots but has no network
    # but aws should use the official aws xen drivers, so this test is only indicative
    add_driver_generic_xen() {
        info "Add drivers: Generic Xen"

        parts='xenbus xencons xenhid xeniface xennet xenvbd xenvif xenvkbd'
        mkdir -p $drv/xen/
        for part in $parts; do
            download https://xenbits.xenproject.org/pvdrivers/win/$part.tar $drv/$part.tar
            tar -xf $drv/$part.tar -C $drv/xen/
        done

        cp_drivers $drv/xen -ipath "*/$arch_xdd/*"
    }

    # virtio
    # https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/
    add_driver_generic_virtio() {
        info "Add drivers: Generic virtio"

        # the win10 and win11 drivers must be distinguished: their NT version is both 10.0, but the driver files differ
        # https://github.com/virtio-win/kvm-guest-drivers-windows/commit/9af43da9e16e2d4bf4ea4663cdc4f29275fff48f
        # vista >>> 2k8
        # 10 >>> w10
        # 2012 r2 >>> 2k12R2
        virtio_sys=$(
            # there is no vista folder
            if [ "$product_ver" = vista ]; then
                echo 2k8

            # the 2k16, 2k19 and 2k22 folders have no arm64 drivers
            elif { [ "$product_ver" = 2016 ] || [ "$product_ver" = 2019 ] || [ "$product_ver" = 2022 ]; } &&
                [ "$arch_wim" = arm64 ]; then
                echo w10

            else
                case "$windows_type" in
                client) echo "w$product_ver" ;;
                server) echo "$product_ver" | sed -E -e 's/ //' -e 's/^200?/2k/' -e 's/r2/R2/' ;;
                esac
            fi
        )

        # on the win7-drivers branch the win7 folder has a single commit, i.e. the 173 bundle
        # 1. 2020.1.24 https://github.com/virtio-win/virtio-win-pkg-scripts/tree/win7-drivers/data/old-drivers/Win7

        # on master the win7 folder has 3 commits, oldest to newest:
        # https://github.com/virtio-win/virtio-win-pkg-scripts/commits/master/data/old-drivers/Win7
        # 1. 2020/6/4  sha256, the 176 bundle, equivalent to the unreleased 176 iso
        # 2. 2020/8/10 some files downgraded to 17400, equivalent to the 189~215 isos
        # 3. 2022/4/14 some files downgraded, equivalent to the 217~latest isos

        # could this download the win7 173(sha1) and 176(sha256) bundles straight from a github commit?

        # 2k12
        # https://github.com/virtio-win/virtio-win-pkg-scripts/issues/61
        # 217 ~ 271    the 2k12 certificate is broken; red hat virtio-win-1.9.45 is fine

        # win7
        # https://fedorapeople.org/groups/virt/virtio-win/repo/stable/
        # https://github.com/virtio-win/virtio-win-pkg-scripts/issues/40
        # 171-1     sha1   stable
        # 173-9     sha1   matches the win7-drivers branch above, the last win7 + sha1 build, but not a stable release?
        # 176       sha256 matches master-1, the last win7 build and the first sha256 one; no iso was published, but the files appear in later isos
        # 185 ~ 187 sha256 works correctly, the win7 files come from 176
        # 189 ~ 215 sha1   matches master-2, balloon version 17400, hangs on vultr
        # 217 ~ 271 sha1   matches master-3, the Oracle vioscsi is unusable because its hardware ID differs, as is red hat virtio-win-1.9.45

        # the Oracle vioscsi hardware ID is PCI\VEN_1AF4&DEV_1004&SUBSYS_0008108E&REV_00
        # where the SUBSYS vendor ID is Oracle

        # virtio-win-0.1.173-9
        # %VirtioScsi.DeviceDesc% = scsi_inst, PCI\VEN_1AF4&DEV_1004&SUBSYS_00081AF4&REV_00, PCI\VEN_1AF4&DEV_1004
        # %VirtioScsi.DeviceDesc% = scsi_inst, PCI\VEN_1AF4&DEV_1048&SUBSYS_11001AF4&REV_01, PCI\VEN_1AF4&DEV_1048

        # stable-virtio
        # %RHELScsi.DeviceDesc% = rhelscsi_inst, PCI\VEN_1AF4&DEV_1004&SUBSYS_00081AF4&REV_00
        # %RHELScsi.DeviceDesc% = rhelscsi_inst, PCI\VEN_1AF4&DEV_1048&SUBSYS_11001AF4&REV_01

        local baseurl=https://fedorapeople.org/groups/virt/virtio-win/direct-downloads

        add_driver_virtio_from_rpm() {
            # fedorapeople may reject or timeout on some VPS IPs, and DaoCloud may still fetch from it.
            # The CentOS Stream x86_64 repo publishes this noarch RPM with Windows x86/x64 virtio drivers.
            local url=https://mirror.stream.centos.org/10-stream/AppStream/x86_64/os/Packages/virtio-win-1.9.45-1.el10.noarch.rpm
            local cpio_file

            info "Add drivers: Generic virtio rpm"
            apk add 7zip

            download "$url" $drv/virtio.rpm

            mkdir -p $drv/virtio-rpm/stage $drv/virtio-rpm/root
            7z x $drv/virtio.rpm -o$drv/virtio-rpm/stage -y -bb1
            cpio_file=$(find $drv/virtio-rpm/stage -maxdepth 1 -name '*.cpio' | head -1)
            [ -n "$cpio_file" ] || error_and_exit "Failed to extract virtio-win rpm."
            7z x "$cpio_file" -o$drv/virtio-rpm/root -y -bb1 \
                -i'!./usr/share/virtio-win/drivers/by-driver/*/'"$virtio_sys"'/'"$arch"'/*'
            find $drv/virtio-rpm/root -type f -ipath "*/$virtio_sys/$arch/*.inf" "$@" | grep . >/dev/null ||
                error_and_exit "Can't find $virtio_sys/$arch drivers in virtio-win rpm."
            cp_drivers $drv/virtio-rpm/root "$@"
        }

        get_latest_virtio_dir() {
            local checksum=$1/stable-virtio/CHECKSUM
            local dir

            # reading CHECKSUM directly works with both the fedorapeople redirect and mirrors that serve the content
            if dir=$(wget "$checksum" -O- |
                grep -Eo -m1 'virtio-win-[0-9][^[:space:]]+\.noarch\.rpm' |
                sed -E 's,^virtio-win-(.*)\.noarch\.rpm$,archive-virtio/virtio-win-\1,' |
                grep .); then
                echo "$dir"
                return
            fi

            # keep the Location parsing as a compatibility path
            if dir=$(wget --spider -S "$checksum" 2>&1 >/dev/null |
                grep -E '^  Location: ' | grep -Ewo -m1 'archive-virtio/virtio-win-[^/]+'); then
                echo "$dir"
                return
            fi

            return 1
        }

        case "$nt_ver" in
        6.0 | 6.1) $support_sha256 &&
            dir=archive-virtio/virtio-win-0.1.187-1 ||
            dir=archive-virtio/virtio-win-0.1.173-9 ;;        # vista|w7|2k8|2k8R2
        6.2 | 6.3) dir=archive-virtio/virtio-win-0.1.215-2 ;; # w8|w8.1|2k12|2k12R2
        *)
            # get the latest version number first, then download
            # with stable-virtio a mirror may serve a cached older build

            # https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/
            # this path is a web page and may trigger an anubis challenge

            # https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/CHECKSUM
            # this path is a file and should not trigger an anubis challenge?
            if ! dir=$(get_latest_virtio_dir "$baseurl"); then
                if [ "$arch_wim" = x86 ] || [ "$arch_wim" = x86_64 ]; then
                    add_driver_virtio_from_rpm "$@"
                    return
                else
                    error_and_exit "Failed to get latest virtio-win version."
                fi
            fi
            # dir=stable-virtio
            ;;
        esac


            # vista|w7|2k8|2k8R2|arm64 must take the driver from the iso
        if [ "$nt_ver" = 6.0 ] || [ "$nt_ver" = 6.1 ] || [ "$arch_wim" = arm64 ]; then
            virtio_source=iso
        else
            virtio_source=msi
        fi

        if [ "$virtio_source" = iso ]; then
            download $baseurl/$dir/virtio-win.iso $drv/virtio.iso
            mkdir -p $drv/virtio
            mount -o ro $drv/virtio.iso $drv/virtio

                # installing the balloon driver on vista errors with: windows could not configure one or more system components
                # the balloon driver installed on 2008 does not work until the device is reinstalled in device manager; no driver update is needed
            if [ "$product_ver" = vista ]; then
                cp_drivers $drv/virtio -ipath "*/$virtio_sys/$arch/*" "$@" -not -ipath "*/balloon/*"
            else
                cp_drivers $drv/virtio -ipath "*/$virtio_sys/$arch/*" "$@"
            fi
        else
            apk add 7zip file
            download $baseurl/$dir/virtio-win-gt-$arch_xdd.msi $drv/virtio.msi
            match="FILE_*_${virtio_sys}_${arch}*"
            7z x $drv/virtio.msi -o$drv/virtio -i!$match -y -bb1
            (
                cd $drv/virtio

                # give the extension-less files an extension
                echo "Recognizing file extension..."
                for file in *"${virtio_sys}_${arch}"; do
                    recognized=false
                    maybe_exts=$(file -b --extension "$file")

                    # exe/sys -> sys
                    # exe/com -> exe
                    # dll/cpl/tlb/ocx/acm/ax/ime -> dll
                    for ext in sys exe dll; do
                        if echo $maybe_exts | grep -qw $ext; then
                            recognized=true
                            mv -v "$file" "$file.$ext"
                            break
                        fi
                    done

                    # if the extension cannot be determined, delete the file,
                    # since it is unusable and only takes up space
                    if ! $recognized; then
                        rm -fv "$file"
                    fi
                done

                # rename
                # FILE_netkvm_netkvmco_w8.1_amd64.dll
                # FILE_netkvm_w8.1_amd64.cat
                # to
                # netkvmco.dll
                # netkvm.cat
                echo "Renaming files..."
                for file in *; do
                    new_file=$(echo "$file" | sed "s|FILE_||; s|_${virtio_sys}_${arch}||; s|.*_||")
                    mv -v "$file" "$new_file"
                done
            )
            cp_drivers $drv/virtio "$@"
        fi
    }

    add_driver_qcloud_virtio() {
        info "Add drivers: QCloud virtio"

        # a beta build?
        # https://mirrors.tencent.com/install/cts/windows/Drivers.zip

        apk add 7zip
        download https://mirrors.tencent.com/install/windows/virtio_64_1.0.9.exe $drv/virtio.exe
        exclude='$*' # exclude $PLUGINSDIR
        override=u   # A(u)to rename all
        7z x $drv/virtio.exe -o$drv/qcloud/ -ao$override -x!$exclude

        # balloon     6.2
        # balloon_1   6.1

        # netkvm      10.0
        # netkvm_1    6.1
        # netkvm_2    6.3

        # viostor     10.0
        # viostor_1   6.1
        # viostor_2   6.2

        drivers=$(
            case "$nt_ver" in
            6.1) echo balloon_1 netkvm_1 viostor_1 ;; # sha1
            6.2) echo balloon netkvm_1 viostor_2 ;;
            6.3) echo balloon netkvm_2 viostor_2 ;;
            *) echo balloon netkvm viostor ;;
            esac
        )

        for old_name in $drivers; do
            part=${old_name%%_*}
            if ! [ "$old_name" = "$part" ]; then
                find $drv/qcloud/$part -type f -iname "$old_name.*" | while read -r file; do
                    ext="${file##*.}"
                    mv -v "$file" "$drv/qcloud/$part/$part.$ext"
                done
            fi
            cp_drivers $drv/qcloud/$part/$part.inf
        done
    }

    add_driver_huawei_virtio() {
        info "Add drivers: Huawei virtio"

        huawei_sys=$(
            case "$(echo "$product_ver" | to_lower)" in
            vista) echo Vista2008 ;;
            7) echo 7 ;;
            8) [ "$arch_wim" = x86 ] && echo 7 || echo 2012 ;;      # there is no win8 32/64
            8.1) [ "$arch_wim" = x86 ] && echo 7 || echo 2012_R2 ;; # there is no win8.1 32/64
            10 | 11) echo 10 ;;
            2008) echo Vista2008 ;;
            '2008 r2') echo 2008_R2 ;;
            2012) [ "$arch_wim" = x86 ] && echo 2008_R2 || echo 2012 ;; # there is no 2012 32
            '2012 r2') echo 2012_R2 ;;
            2016 | 2019 | 202*) echo 2016 ;;
            esac
        )

        download https://ecs-instance-driver.obs.cn-north-1.myhuaweicloud.com/vmtools-windows.zip $drv/vmtools-windows.zip
        unzip -o -d $drv $drv/vmtools-windows.zip
        mkdir -p $drv/huawei
        mount -o ro $drv/vmtools-windows.iso $drv/huawei

        cp_drivers $drv/huawei -ipath "*/upgrade/windows ${huawei_sys}_${arch_dd}/drivers/*"
    }

    add_driver_aliyun_virtio() {
        info "Add drivers: Aliyun virtio"

        aliyun_sys=$(
            case "$nt_ver" in
            6.1) echo 2008R2 ;;
            6.2 | 6.3) echo 2012R2 ;; # really the 2012 driver
            *) echo 2016 ;;
            esac
        )

        subdir=
        if [ "$nt_ver" = 6.1 ] && ! $support_sha256; then
            subdir=58017/ # sha1
        fi

        region=cn-hangzhou

        download https://windows-driver-$region.oss-$region.aliyuncs.com/virtio/${subdir}AliyunVirtio_WIN$aliyun_sys.zip \
            $drv/AliyunVirtio.zip
        unzip -o -d $drv $drv/AliyunVirtio.zip

        apk add innoextract
        innoextract -d $drv/aliyun/ $drv/AliyunVirtio_*_WIN${aliyun_sys}_$arch_xdd.exe
        apk del innoextract

        cp_drivers $drv/aliyun -ipath "*/C$/Program Files/AliyunVirtio/*/drivers/*"
    }

    # gcp virtio win7 x64 sha1
    # missing balloon and viorng
    add_driver_gcp_virtio_win6_1_sha1_x64() {
        info "Add drivers: GCP virtio win6.1 sha1 x64"

        # only download the nvme driver when nvme is in use,
        # because win7 can obtain an nvme driver through Windows Update
        # and google recommends the microsoft nvme driver
        # (google-compute-engine-driver-nvme 2.0.0 removed the google nvme driver)
        mkdir -p $drv/gce/win6.1sha1
        for file in \
            WdfCoInstaller01009.dll WdfCoInstaller01011.dll \
            netkvm.inf netkvm.cat netkvm.sys netkvmco.dll \
            pvpanic.inf pvpanic.sys pvpanic.cat \
            vioscsi.inf vioscsi.sys vioscsi.cat \
            $([ -d /sys/module/nvme ] && ! $has_stornvme && echo nvme.inf nvme64.cat nvme.sys); do
            download https://storage.googleapis.com/gce-windows-drivers-public/win6.1sha1/$file $drv/gce/win6.1sha1/$file
        done
        cp_drivers $drv/gce/win6.1sha1
    }

    # gcp virtio win7+ sha256
    # x86 is missing viorng and pvpanic
    # x64 is missing viorng
    # https://github.com/GoogleCloudPlatform/compute-image-tools/tree/master/daisy_workflows/image_build/windows
    # officially the drivers come from https://console.cloud.google.com/storage/browser/gce-windows-drivers-public and are updated with googet after install
    # we download them from googet directly instead
    add_driver_gcp_virtio() {
        info "Add drivers: GCP virtio"

        mkdir -p $drv/gce
        gce_repo=https://packages.cloud.google.com/yuck
        download $gce_repo/repos/google-compute-engine-stable/index $drv/gce/gce.json
        for part in balloon netkvm pvpanic vioscsi; do
            # the pvpanic gcp provides has no x86 driver
            if [ "$part" = pvpanic ] && [ "$arch_wim" = x86 ]; then
                continue
            fi

            mkdir -p $drv/gce/$part
            link=$(grep -o "/pool/.*-google-compute-engine-driver-$part.*\.goo" $drv/gce/gce.json)
            wget $gce_repo$link -O- | tar xz -C $drv/gce/$part

            [ "$arch_wim" = x86 ] && suffix=-32 || suffix=
            cp_drivers $drv/gce/$part -ipath "*/win$nt_ver$suffix/*"
        done
    }

    # gcp
    # available for x86, x86_64 and arm64
    # the win7 driver is sha256 signed
    add_driver_gcp() {
        info "Add drivers: GCP"

        # https://packages.cloud.google.com/yuck/repos/google-compute-engine-stable/index
        # https://packages.cloud.google.com/yuck/repos/google-compute-engine-driver-gvnic-gq-stable/index
        # the gvnic in the official image comes from gvnic-gq-stable: slightly older, but more stable?

        mkdir -p $drv/gce
        gce_repo=https://packages.cloud.google.com/yuck
        download $gce_repo/repos/google-compute-engine-stable/index $drv/gce/gce.json
        for part in gvnic gga; do
            # gvnic has no arm64 build
            if [ "$part" = gvnic ] && [ "$arch_wim" = arm64 ]; then
                continue
            fi

            mkdir -p $drv/gce/$part
            link=$(grep -o "/pool/.*-google-compute-engine-driver-$part.*\.goo" $drv/gce/gce.json)
            wget $gce_repo$link -O- | tar xz -C $drv/gce/$part

            # the inf has no version restriction,
            # but the win7 gvnic ndis version is 6.2, so vista/2008 installs it without it working
            # https://github.com/GoogleCloudPlatform/compute-virtual-ethernet-windows/blob/cad1edf7a05465f4972a81f2c015952fd228b5e3/src/gvnic.vcxproj#L298
            if false; then
                for suffix in '' '-32'; do
                    if [ -d "$drv/gce/$part/win6.1$suffix" ]; then
                        cp -r "$drv/gce/$part/win6.1$suffix" "$drv/gce/$part/win6.0$suffix"
                    fi
                done
            fi

            case "$part" in
            gvnic)
                [ "$arch_wim" = x86 ] && suffix=-32 || suffix=
                cp_drivers $drv/gce/gvnic -ipath "*/win$nt_ver$suffix/*"
                ;;
            gga)
                cp_drivers $drv/gce/gga -ipath "*/win$nt_ver/*"
                ;;
            esac
        done
    }

    # azure
    # https://learn.microsoft.com/azure/virtual-network/accelerated-networking-mana-windows
    add_driver_azure() {
        info "Add drivers: Azure"

        download https://aka.ms/manawindowsdrivers $drv/azure.zip
        unzip $drv/azure.zip -d $drv/azure/
        cp_drivers $drv/azure
    }

    # vpci
    add_driver_vpci() {
        info "Add drivers: vpci"

        mount_iso_install_wim_to /wim-tmp

        # Check whether the install.wim image has the vpci driver
        if vpci_sys=$(find_file_ignore_case /wim-tmp/Windows/System32/drivers/vpci.sys) &&
            wvpci_inf=$(find_file_ignore_case /wim-tmp/Windows/INF/wvpci.inf); then

            # registry file
            from_system_hive="$(find_file_ignore_case /wim-tmp/Windows/System32/config/SYSTEM)"
            from_software_hive="$(find_file_ignore_case /wim-tmp/Windows/System32/config/SOFTWARE)"
            to_system_hive="$(find_file_ignore_case /wim/Windows/System32/config/SYSTEM)"
            to_software_hive="$(find_file_ignore_case /wim/Windows/System32/config/SOFTWARE)"

            apk add hivex-perl

            # get the wvpci.inf file currently in effect,
            # which gives a filename such as wvpci.inf_amd64_86afbe8940682d27
            wvpci_inf_filename_with_hash=$(hivexget "$from_system_hive" 'DriverDatabase\DriverInfFiles\wvpci.inf' Active)

            # .inf .sys
            cp -fv "$vpci_sys" "$(get_path_in_correct_case /wim/Windows/System32/drivers/)"
            cp -fv "$wvpci_inf" "$(get_path_in_correct_case /wim/Windows/INF/)"
            cp -rfv "$(get_path_in_correct_case "/wim-tmp/Windows/System32/DriverStore/FileRepository/$wvpci_inf_filename_with_hash/")" \
                "$(get_path_in_correct_case /wim/Windows/System32/DriverStore/FileRepository/)"

            # .cat
            apk add binutils
            for file in "$(get_path_in_correct_case '/wim-tmp/Windows/System32/CatRoot/{F750E6C3-38EE-11D1-85E5-00C04FC295EE}/')"*; do
                if strings -e l "$file" | grep -Fiq vpci.sys; then
                    cp -fv "$file" "$(get_path_in_correct_case '/wim/Windows/System32/CatRoot/{F750E6C3-38EE-11D1-85E5-00C04FC295EE}/')"
                fi
            done
            apk del binutils

            mkdir -p "$drv/vpci"

            # SOFTWARE
            reg=$drv/vpci/software.reg
            # shellcheck disable=SC2043
            for key in \
                "Microsoft\Windows\CurrentVersion\Setup\PnpLockdownFiles\%SystemRoot%/System32/drivers/vpci.sys"; do
                hivexregedit --export "$from_software_hive" "$key" >>"$reg"
            done
            hivexregedit --merge "$to_software_hive" "$reg"

            # SYSTEM
            # strictly the ControlSet number should come from Current/Default under HKEY_LOCAL_MACHINE\SYSTEM\Select
            reg=$drv/vpci/system.reg
            for key in \
                "ControlSet001\Services\EventLog\System\vpci" \
                "ControlSet001\Services\vpci" \
                "DriverDatabase\DeviceIds\VMBUS\{44C4F61D-4444-4400-9D52-802E27EDE19F}" \
                "DriverDatabase\DriverInfFiles\wvpci.inf" \
                "DriverDatabase\DriverPackages\\$wvpci_inf_filename_with_hash"; do
                hivexregedit --export "$from_system_hive" "$key" >>"$reg"
            done
            # this registry location records the driver load order in Tag
            # HKEY_LOCAL_MACHINE\System\ControlSet001\Control\GroupOrderList, System Bus Extender
            # so the vpci tag must be removed, or it would clash with another driver and break things
            cat <<EOF >>"$reg"
[\ControlSet001\Services\vpci]
"Tag"=-
EOF
            hivexregedit --merge "$to_system_hive" "$reg"

            apk del hivex-perl
        else
            error_and_exit "vpci driver not found."
        fi

        wimunmount /wim-tmp
    }

    add_driver_vmd() {
        info "Add drivers: VMD"

        local id=
        for d in /sys/bus/pci/devices/*; do
            if [ "$(cat "$d/vendor" 2>/dev/null)" = "0x8086" ] &&
                device=$(sed 's/^0x//' "$d/device" 2>/dev/null); then

                # v21
                if [ "$build_ver" -ge 19041 ] &&
                    [ "$device" = "b06f" ]; then
                    id=920456
                    break

                # v20
                elif [ "$build_ver" -ge 19041 ] &&
                    { [ "$device" = "467f" ] ||
                        [ "$device" = "a77f" ] ||
                        [ "$device" = "7d0b" ] ||
                        [ "$device" = "ad0b" ]; }; then
                    id=849936
                    break

                # v19
                elif [ "$build_ver" -ge 15063 ] &&
                    { [ "$device" = "9a0b" ] ||
                        [ "$device" = "467f" ] ||
                        [ "$device" = "a77f" ]; }; then
                    id=849933
                    break
                fi
            fi
        done

        if [ -n "$id" ]; then
            local url
            url=$(get_intel_download_url "$id" "SetupRST\.exe")

            # note that intel blocks aria2 downloads
            download_via_browser $url $drv/SetupRST.exe
            apk add 7zip
            7z x $drv/SetupRST.exe -o$drv/SetupRST -i!.text
            7z x $drv/SetupRST/.text -o$drv/vmd
            apk del 7zip
            cp_drivers $drv/vmd
        else
            # if vmd is enabled but the disk is not behind it, does linux load the vmd module automatically?
            # whether the main disk is behind vmd should also be checked: if it is not, the install can proceed without a vmd driver
            # so do not abort the script for now
            : error_and_exit "can't find suitable vmd driver"
        fi
    }

    # Automatic driver detection can get this wrong.
    # Consider a win7-era NIC: the vendor ships no win10 driver and the system has none built in,
    # but win10 can in fact use the win7 driver.
    # In that case downloading the win10 driver package automatically will not include it;
    # the win7 package is the one needed.
    # So this is left to the user to add manually.

    add_driver_custom() {
        if [ -d /custom_drivers/ ]; then
            cp_drivers custom /custom_drivers/
            # do not delete after copying, since the script may run again
        fi
    }

    # Edit the answer file
    apk add xmlstarlet
    download $confhome/windows.xml /tmp/autounattend.xml
    locale=$(get_selected_image_prop 'Default Language')
    use_default_rdp_port=$(is_need_change_rdp_port && echo false || echo true)

    # 7601.24214.180801-1700.win7sp1_ldr_escrow_CLIENT_ULTIMATE_x64FRE_en-us.iso has an empty Image Name
    # setting the xml Image Name value to empty installs correctly
    sed -i \
        -e "s|%arch%|$arch|" \
        -e "s|%image_name%|$image_name|" \
        -e "s|%locale%|$locale|" \
        -e "s|%use_default_rdp_port%|$use_default_rdp_port|" \
        /tmp/autounattend.xml

    # Account and password
    if is_administrator_username "$username"; then
        # Administrator
        password_base64=$(get_password_windows_administrator_base64)
        xmlstarlet ed -L -N x="urn:schemas-microsoft-com:unattend" \
            -d "//x:LocalAccounts" \
            /tmp/autounattend.xml
        sed -i \
            -e "s|%enable_administrator%|1|gi" \
            -e "s|%administrator_password%|$password_base64|gi" \
            /tmp/autounattend.xml
    else
        # a normal account
        password_base64=$(get_password_windows_user_base64)
        xmlstarlet ed -L -N x="urn:schemas-microsoft-com:unattend" \
            -d "//x:AdministratorPassword" \
            /tmp/autounattend.xml
        sed -i \
            -e "s|%enable_administrator%|0|gi" \
            -e "s|%user_username%|$username|gi" \
            -e "s|%user_password%|$password_base64|gi" \
            /tmp/autounattend.xml
    fi

    # Edit the answer file: partition configuration
    if is_efi; then
        sed -i "s|%installto_partitionid%|3|" /tmp/autounattend.xml
    else
        sed -i "s|%installto_partitionid%|1|" /tmp/autounattend.xml
    fi

    # this line makes a vista/2008 install fail
    if [ "$nt_ver" = 6.0 ]; then
        sed -i "/EnableFirewall/d" /tmp/autounattend.xml
    fi

    # 2012 r2: removing the key field fails with "Windows cannot read the <ProductKey> setting from the unattend answer file", even with an ei.cfg
    # ltsc 2021: has ei.cfg, a blank key works
    # ltsc 2021 n: has ei.cfg, a blank key fails with "Windows Cannot find Microsoft software license terms"
    # an evaluation iso has EVAL in ei.cfg, and a blank key fails with "Windows Cannot find Microsoft software license terms"

    # key
    if [ "$product_ver" = vista ]; then
        # an unattended vista install needs a key, which need not match the edition
        # https://learn.microsoft.com/en-us/windows-server/get-started/kms-client-activation-keys
        # take the default key from the image
        setup_cfg=$(get_path_in_correct_case /os/installer/sources/inf/setup.cfg)
        key=$(del_cr <"$setup_cfg" | grep -Eix 'Value=([A-Z0-9]{5}-){4}[A-Z0-9]{5}' | cut -d= -f2 | grep .)
        sed -i "s/%key%/$key/" /tmp/autounattend.xml
    else
        if [ -f "$(get_path_in_correct_case /os/installer/sources/ei.cfg)" ]; then
            # the image has ei.cfg, so remove the key field
            sed -i "/%key%/d" /tmp/autounattend.xml
        else
            # the image has no ei.cfg, so use a blank key
            sed -i "s/%key%//" /tmp/autounattend.xml
        fi
    fi

    # Mount boot.wim
    info "mount boot.wim"
    wimmountrw /os/boot.wim "$boot_index" /wim/

    # avoid duplicates
    copyed_infs=
    cp_drivers() {
        if [ "$1" = custom ]; then
            shift
            dst=$(get_path_in_correct_case "/wim/custom_drivers")
        else
            dst=$(get_path_in_correct_case "/wim/drivers")
        fi

        src=$1
        shift

        # -not -iname "*.pdb" \
        # -not -iname "dpinst.exe" \

        # $copyed_infs has to be modified inside the while loop, so find | while cannot be used
        while read -r inf; do
            if ! is_list_has "$copyed_infs" "$inf"; then
                parse_inf_and_cp_driever "$inf" "$dst" "$arch" false
                copyed_infs=$(list_add "$copyed_infs" "$inf")
            fi
        done < <(find $src -type f -iname "*.inf" "$@")
    }

    # Add the drivers
    add_drivers

    # win7 needs bootx64.efi added to the efi directory
    if is_efi; then
        [ $arch = amd64 ] && boot_efi=bootx64.efi || boot_efi=bootaa64.efi

        local src dst
        dst=$(get_path_in_correct_case /os/boot/efi/EFI/boot/$boot_efi)
        if ! [ -f $dst ]; then
            mkdir -p "$(dirname $dst)"
            src=$(get_path_in_correct_case /wim/Windows/Boot/EFI/bootmgfw.efi)
            cp "$src" "$dst"
        fi
    fi

    # Copy the answer file
    # strip the comments, otherwise the autounattend.xml regenerated by windows-setup.bat is malformed
    wim_autounattend_xml=$(get_path_in_correct_case /wim/autounattend.xml)
    wim_windows_xml=$(get_path_in_correct_case /wim/windows.xml)
    wim_setup_exe=$(get_path_in_correct_case /wim/setup.exe)

    xmlstarlet ed -d '//comment()' /tmp/autounattend.xml >$wim_autounattend_xml
    unix2dos $wim_autounattend_xml
    info "autounattend.xml"
    # Show the final file with the password masked
    xmlstarlet ed -d '//*[name()="AdministratorPassword" or name()="Password"]' $wim_autounattend_xml | cat -n

    apk del xmlstarlet

    # stop setup.exe installing automatically when run without arguments
    mv $wim_autounattend_xml $wim_windows_xml

    # Copy the install script
    # https://slightlyovercomplicated.com/2016/11/07/windows-pe-startup-sequence-explained/
    # https://learn.microsoft.com/previous-versions/windows/it-pro/windows-vista/cc721977(v=ws.10)
    mv $wim_setup_exe $wim_setup_exe.disabled

    # a duplicate Windows/System32 folder makes it report a missing winload.exe and fail to boot
    # win7 and win10: boot.wim has Windows/System32, install.wim has Windows/System32
    # win2016:        boot.wim has windows/system32, install.wim has Windows/System32
    # wimmount cannot mount case-insensitively

    startnet_cmd=$(get_path_in_correct_case /wim/Windows/System32/startnet.cmd)
    winpeshl_ini=$(get_path_in_correct_case /wim/Windows/System32/winpeshl.ini)

    download $confhome/windows-setup.bat $startnet_cmd
    # used when releasing the image manually with dism
    # sed -i "s|@image_name@|$image_name|" "$startnet.cmd"

    # shellcheck disable=SC2154
    if [ "$force_old_windows_setup" = 1 ]; then
        sed -i 's/ForceOldSetup=0/ForceOldSetup=1/i' $startnet_cmd
    fi

    # Enable EMS when the SAC component is present
    if $has_sac; then
        sed -i 's/EnableEMS=0/EnableEMS=1/i' $startnet_cmd
    fi

    # a 4kn EFI partition must be at least 260M
    # https://learn.microsoft.com/windows-hardware/manufacture/desktop/hard-drives-and-partitions
    if is_4kn; then
        sed -i 's/is4kn=0/is4kn=1/i' $startnet_cmd
    fi

    # Windows Thin PC has Windows\System32\winpeshl.ini
    # [LaunchApps]
    # %SYSTEMDRIVE%\windows\system32\drvload.exe, %SYSTEMDRIVE%\windows\inf\sdbus.inf
    # %SYSTEMDRIVE%\setup.exe
    if [ -f "$winpeshl_ini" ]; then
        info "mod winpeshl.ini"
        # https://learn.microsoft.com/previous-versions/windows/it-pro/windows-vista/cc721977(v=ws.10)
        # both methods work; the first is the original command
        sed -i 's|setup.exe|windows\\system32\\cmd.exe, "/k %SYSTEMROOT%\\system32\\startnet.cmd"|i' "$winpeshl_ini"
        # sed -i 's|setup.exe|windows\\system32\\startnet.cmd|i' "$winpeshl_ini"
        cat -n "$winpeshl_ini"
    fi

    # Commit the boot.wim changes
    info "Unmount boot.wim"
    wimunmount --commit /wim/

    # in-place optimization can use one of the following commands
    # wimdelete /os/boot.wim 1
    # wimoptimize /os/boot.wim

    # Optimize boot.wim and copy it into place
    if is_nt_ver_ge 6.1; then
        # on win7 and later, deleting image 1 from boot.wim does not error,
        # because the win7 winre image lives in install.wim at Windows\System32\Recovery\winRE.wim
        images=$boot_index
    else
        # on vista, deleting image 1 from boot.wim does error,
        # Windows cannot access the required file Drive:\Sources\Boot.wim.
        # Make sure all files required for installation are available and restart the installation.
        # Error code: 0x80070491
        # because the vista install.wim has no Windows\System32\Recovery\winRE.wim
        images=all
    fi
    mkdir -p "$(get_path_in_correct_case "$(dirname $boot_dir/$sources_boot_wim)")"
    # avoid the "file already exists" error on a second run without reformatting
    rm -f $boot_dir/$sources_boot_wim
    wimexport --boot /os/boot.wim "$images" $boot_dir/$sources_boot_wim
    info "boot.wim size"
    echo "Original:      $(get_filesize_mb /iso/$sources_boot_wim)"
    echo "Added Drivers: $(get_filesize_mb /os/boot.wim)"
    echo "Optimized:     $(get_filesize_mb "$boot_dir/$sources_boot_wim")"
    echo

    # vista needs boot.wim during installation; see above for why
    if [ "$nt_ver" = 6.0 ] &&
        ! [ -e /os/installer/$sources_boot_wim ]; then
        cp $boot_dir/$sources_boot_wim /os/installer/$sources_boot_wim
    fi

    # windows 7 has no invoke-webrequest
    # the installer partition is not necessarily drive D,
    # so copy resize.bat into install.wim
    if true; then
        info "mount install.wim"
        wimmountrw $install_wim "$image_index" /wim/
        if false; then
            # use autounattend.xml
            # win7 cannot find the NIC at this stage
            download $confhome/windows-resize.bat /wim/windows-resize.bat
            for ethx in $(get_eths); do
                create_win_set_netconf_script /wim/windows-set-netconf-$ethx.bat
            done
        else
            modify_windows /wim
        fi

        info "Unmount install.wim"
        wimunmount --commit /wim/
    fi

    # Add the boot entry
    if is_efi; then
        # add_default_efi_to_nvram() now prepends bootx64.efi,
        # so this is redundant
        if false; then
            apk add efibootmgr
            efibootmgr -c -L "Windows Installer" -d /dev/$xda -p1 -l "\\EFI\\boot\\$boot_efi"
        fi
    else
        # or use ms-sys
        apk add grub-bios
        # under efi, forcing an mbr boot install requires --target i386-pc
        grub-install --target i386-pc --boot-directory="$(get_path_in_correct_case /os/boot)" /dev/$xda
        cat <<EOF >"$(get_path_in_correct_case /os/boot/grub/grub.cfg)"
            set timeout=5
            menuentry "reinstall" {
                insmod search
                insmod ntldr
                search --no-floppy --label --set=root os
                ntldr /$(cd /os && get_path_in_correct_case bootmgr)
            }
EOF
    fi
}

# Add netboot.efi as a fallback
download_netboot_xyz_efi() {
    dir=$1
    info "download netboot.xyz.efi"

    file=$dir/netboot.xyz.efi
    if [ "$(uname -m)" = aarch64 ]; then
        download https://boot.netboot.xyz/ipxe/netboot.xyz-arm64.efi $file
    else
        download https://boot.netboot.xyz/ipxe/netboot.xyz.efi $file
    fi
}

refind_main_disk() {
    if true; then
        apk add sfdisk
        main_disk=$(sfdisk --disk-id /dev/$xda | sed 's/0x//')
    else
        apk add lsblk
        # main_disk=$(blkid --match-tag PTUUID -o value /dev/$xda)
        main_disk=$(lsblk --nodeps -rno PTUUID /dev/$xda)
    fi
}

sync_time() {
    if false; then
        # arm must sync the time from hardware manually, or https requests fail
        # a second run on a do machine errors out
        hwclock -s || true
    fi

    # can ntp fail to sync when the time is too far off?
    # the http time may be inaccurate, since it is not a dedicated time server
    #      and there may be no date header at all?
    method=http

    case "$method" in
    ntp)
        ntp_server=pool.ntp.org
        # -d[d]   Verbose
        # -n      Run in foreground
        # -q      Quit after clock is set
        # -p      PEER
        ntpd -d -n -q -p "$ntp_server"
        ;;
    http)
        url="$(grep -m1 ^http /etc/apk/repositories)/$(uname -m)/APKINDEX.tar.gz"
        # there may be several lines, so take the first
        date_header=$(wget -S --no-check-certificate --spider "$url" 2>&1 | grep -m1 '^  Date:')
        # gnu date does not support -D
        busybox date -u -D "  Date: %a, %d %b %Y %H:%M:%S GMT" -s "$date_header"
        ;;
    esac

    # alpine writes to the hardware clock automatically on reboot, so skip it here
    # hwclock -w
}

is_ubuntu_lts() {
    IFS=. read -r major minor < <(echo "$releasever")
    [ $((major % 2)) = 0 ] && [ $minor = 04 ]
}

get_ubuntu_kernel_flavor() {
    # the 20.04/22.04 kvm kernel shows nothing on the vnc console
    # 24.04 kvm = virtual
    # linux-image-virtual = linux-image-6.x-generic
    # linux-image-generic = linux-image-6.x-generic + amd64-microcode + intel-microcode + linux-firmware + linux-modules-extra-generic

    # TODO: with the ISO virtual-hwe-24.04, linux-image-extra-virtual-hwe-24.04 must be installed or the display is corrupted

    # https://github.com/systemd/systemd/blob/main/src/basic/virt.c
    # https://github.com/canonical/cloud-init/blob/main/tools/ds-identify
    # http://git.annexia.org/?p=virt-what.git;a=blob;f=virt-what.in;hb=HEAD

    # a trap here:
    # $(get_cloud_vendor) calls cache_dmi_and_virt
    # but $(get_cloud_vendor) runs in a subshell,
    # and the variables set inside vanish when the subshell exits,
    # so run cache_dmi_and_virt first
    cache_dmi_and_virt
    vendor="$(get_cloud_vendor)"
    case "$vendor" in
    aws | gcp | oracle | azure | ibm) echo $vendor ;;
    *)
        is_ubuntu_lts && suffix=-hwe-$releasever || suffix=
        if is_virt; then
            echo virtual$suffix
        else
            echo generic$suffix
        fi
        ;;
    esac
}

install_redhat_ubuntu() {
    info "Download iso installer"

    # Install grub2
    if is_efi; then
        # note that an older grub cannot boot the f38 arm kernel
        # https://forums.fedoraforum.org/showthread.php?330104-aarch64-pxeboot-vmlinuz-file-format-changed-broke-PXE-installs
        apk add grub-efi efibootmgr
        grub-install --efi-directory=/os/boot/efi --boot-directory=/os/boot
    else
        apk add grub-bios
        grub-install --boot-directory=/os/boot /dev/$xda
    fi

    # Rebuild extra, because grub strips the quotes and they must be re-added
    extra_cmdline=''
    for var in $(grep -o '\bextra_[^ ]*' /proc/cmdline | xargs); do
        if [[ "$var" = "extra_main_disk=*" ]]; then
            # record the main disk again
            refind_main_disk
            extra_cmdline="$extra_cmdline extra_main_disk=$main_disk"
        else
            extra_cmdline="$extra_cmdline $(echo $var | sed -E "s/(extra_[^=]*)=(.*)/\1='\2'/")"
        fi
    done

    # when installing a red hat derivative, only the last one shows an installer UI
    # https://anaconda-installer.readthedocs.io/en/latest/boot-options.html#console
    console_cmdline=$(get_ttys console=)
    grub_cfg=/os/boot/grub/grub.cfg

    # newer grub does not distinguish linux from linuxefi
    # shellcheck disable=SC2154
    if [ "$distro" = "ubuntu" ]; then
        download $iso /os/installer/ubuntu.iso
        mkdir -p /iso
        mount -o ro /os/installer/ubuntu.iso /iso

        # kernel flavour
        kernel=$(get_ubuntu_kernel_flavor)

        # the version to install
        # https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html#id
        # 20.04 cannot select minimal and has no install-sources.yaml
        source_id=
        if [ -f /iso/casper/install-sources.yaml ]; then
            ids=$(grep id: /iso/casper/install-sources.yaml | awk '{print $2}')
            if [ "$(echo "$ids" | wc -l)" = 1 ]; then
                source_id=$ids
            else
                [ "$minimal" = 1 ] && v= || v=-v
                source_id=$(echo "$ids" | grep $v '\-minimal')

                if [ "$(echo "$source_id" | wc -l)" -gt 1 ]; then
                    error_and_exit "find multi source id."
                fi
            fi
        fi

        # the normal form would be ds="nocloud-net;s=https://xxx/", but the Oracle Cloud ds takes priority and ours is never even requested
        # $seed is https://xxx/
        cat <<EOF >$grub_cfg
        set timeout=5
        menuentry "reinstall" {
            # https://bugs.launchpad.net/ubuntu/+source/grub2/+bug/1851311
            # rmmod tpm
            insmod all_video
            insmod search
            insmod loopback
            search --no-floppy --label --set=root installer
            loopback loop /ubuntu.iso
            linux (loop)/casper/vmlinuz iso-scan/filename=/ubuntu.iso autoinstall noprompt noeject cloud-config-url=$ks $extra_cmdline extra_kernel=$kernel extra_source_id=$source_id --- $console_cmdline
            initrd (loop)/casper/initrd
        }
EOF
    else
        download $vmlinuz /os/vmlinuz
        download $initrd /os/initrd.img
        download $squashfs /os/installer/install.img

        cat <<EOF >$grub_cfg
        set timeout=5
        menuentry "reinstall" {
            insmod all_video
            insmod search
            search --no-floppy --label --set=root os
            linux /vmlinuz inst.stage2=hd:LABEL=installer:/install.img inst.ks=$ks $extra_cmdline $console_cmdline
            initrd /initrd.img
        }
EOF
    fi

    cat "$grub_cfg"
}

trans() {
    info "start trans"

    mod_motd

    # Check that modloop is healthy first,
    # so a missing ext4 module does not make mount fail after the disk is formatted
    # https://github.com/bin456789/reinstall/issues/136
    ensure_service_started modloop

    cat /proc/cmdline
    clear_previous
    add_community_repo

    # The main disk must be found before repartitioning
    # xda can be specified when re-running the script
    # xda=sda ash trans.start
    if [ -z "$xda" ]; then
        find_xda
    fi

    if [ "$distro" != "alpine" ]; then
        setup_web_if_enough_ram
        # util-linux provides lsblk
        # util-linux can auto-detect the mount format
        apk add util-linux
    fi

    # dd qemu switches to cloud image mode; not used at the moment
    # shellcheck disable=SC2154
    if [ "$distro" = "dd" ] && [ "$img_type" = "qemu" ]; then
        # move this into reinstall.sh?
        distro=any
        cloud_image=1
    fi

    if is_use_cloud_image; then
        case "$img_type" in
        qemu)
            create_part
            download_qcow
            case "$distro" in
            centos | almalinux | rocky | oracle | redhat | anolis | opencloudos | openeuler)
                # the cloud images of these systems use an 8~9g xfs system partition, while we target 5g disks, so copy the system files instead
                install_qcow_by_copy
                ;;
            ubuntu)
                # the 24.04 cloud image has a boot partition before the system partition, so do not dd the cloud image directly
                install_qcow_by_copy
                ;;
            *)
                # debian fedora opensuse arch gentoo any
                dd_qcow
                resize_after_install_cloud_image
                modify_os_on_disk linux
                ;;
            esac
            ;;
        raw)
            # raw cloud images are not used at the moment
            dd_raw_with_extract
            resize_after_install_cloud_image
            modify_os_on_disk linux
            ;;
        esac
    elif [ "$distro" = "dd" ]; then
        case "$img_type" in
        raw)
            dd_raw_with_extract
            if false; then
                # linux cannot easily shrink after growing, e.g. xfs
                # windows growth is done from within windows
                resize_after_install_cloud_image
            fi
            if [ -d /configs/cloud-data ]; then
                modify_os_on_disk nocloud
            else
                modify_os_on_disk windows
            fi
            ;;
        qemu) # dd qemu can never reach here, it was handled above
            ;;
        esac
    else
        # installer mode
        case "$distro" in
        alpine)
            install_alpine
            ;;
        arch)
            create_part
            install_arch_family
            ;;
        *)
            create_part
            mount_part_for_iso_installer
            case "$distro" in
            centos | almalinux | rocky | fedora | ubuntu | redhat) install_redhat_ubuntu ;;
            windows) install_windows ;;
            esac
            ;;
        esac
    fi

    # lsblk and efibootmgr are needed, which is only about 1M,
    # so alpine needs no special handling
    if is_efi; then
        del_invalid_efi_entry
        add_default_efi_to_nvram
    fi

    info 'done'
    # let the web output show everything
    sleep 5
}

# Script entry point
# the debian initrd looks for main
# and calls create_ifupdown_config from this file
: main

# Copy the script,
# used to print the error or to run it again
# no copy is needed when the paths are the same
# important: copy it before deleting the script
if ! [ "$(readlink -f "$0")" = /trans.sh ]; then
    cp -f "$0" /trans.sh
fi
trap 'trap_err $LINENO $?' ERR

# Delete this script, otherwise it would be copied into the new system
rm -f /etc/local.d/trans.start
rm -f /etc/runlevels/default/local

# Extract the variables
extract_env_from_cmdline

# The part that runs with arguments
# re-download and exec the new script
if [ "$1" = "update" ]; then
    info 'update script'
    # shellcheck disable=SC2154
    wget -O /trans.sh "$confhome/trans.sh"
    chmod +x /trans.sh
    exec /trans.sh
elif [ "$1" = "alpine" ]; then
    info 'switch to alpine'
    distro=alpine
    # many later steps use this, e.g. the partition layout
    cloud_image=0
elif [ -n "$1" ]; then
    error_and_exit "unknown option $1"
fi

# The part that runs without arguments
# allow the ramdisk to use all memory; the default is 50%
mount / -o remount,size=100%

# Sync the time
# 1. prevents https errors
# 2. prevents https://github.com/bin456789/reinstall/issues/223
#    E: Release file for http://security.ubuntu.com/ubuntu/dists/noble-security/InRelease is not valid yet (invalid for another 5h 37min 18s).
#    Updates for this repository will not be applied.
# 3. the rtc cannot be read directly, because windows keeps it in local time and linux in utc
# 4. a failure here is tolerated, since it is not a critical step
sync_time || true

# Install ssh and change the port
apk add openssh-server
if is_need_change_ssh_port; then
    change_ssh_port / $ssh_port
fi

# Set the password, add the startup entry and enable the ssh service
add_user_if_need /
if is_need_set_ssh_keys; then
    set_ssh_keys_and_del_password /
    change_ssh_conf_for_key_login /
    printf '\n' | setup-sshd
else
    change_user_password /
    change_ssh_conf_for_password_login /
    printf '\nyes' | setup-sshd
fi

# Set up frpc
# and guard against running twice
if ls /configs/frpc.* >/dev/null 2>&1 && ! pidof frpc >/dev/null; then
    info 'run frpc'
    add_community_repo
    apk add frp
    while true; do
        frpc -c /configs/frpc.* || true
        sleep 5
    done &
fi

# shellcheck disable=SC2154
if [ "$hold" = 1 ]; then
    if is_run_from_locald; then
        info "hold"
        exit
    fi
fi

# Start the actual reinstall
# shellcheck disable=SC2046,SC2194
case 1 in
1)
    # this form performs best
    exec > >(exec tee $(get_ttys /dev/) /reinstall.log) 2>&1
    trans
    ;;
2)
    exec > >(tee $(get_ttys /dev/) /reinstall.log) 2>&1
    trans
    ;;
3)
    trans 2>&1 | tee $(get_ttys /dev/) /reinstall.log
    ;;
esac

if [ "$hold" = 2 ]; then
    info "hold 2"
    exit
fi

# swapoff -a
# umount ?
sync
reboot
