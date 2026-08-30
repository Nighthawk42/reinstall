#!/bin/ash
# shellcheck shell=dash
# shellcheck disable=SC3001,SC3003,SC3010,SC3015
# Shared by reinstall.sh and trans.sh

# grep cannot handle UTF-16LE encoded inf files; the options are:
# 1. use ripgrep (rg) or ugrep, but cygwin has neither
# 2. grep -a a.b.c.d
# 3. iconv -f UTF-16 -t UTF-8

del_inf_comment() {
    sed 's/;.*//'
}

simply_inf() {
    convert_file_to_utf8 "$1" | del_cr | del_inf_comment | trim | del_empty_lines
}

convert_file_to_utf8() {
    # comparing strings with * is unreliable in ash
    # [[ $'\xEF\xBB' = $'\xEF\xBB*' ]] && echo 1

    # should UTF-16LE without a BOM be handled? does windows support inf files in that encoding?

    # UTF-16LE with BOM
    if [ "$(head -c2 "$1")" = $'\xFF\xFE' ]; then
        # -f UTF-16LE -t UTF-8 adds a UTF-8 BOM
        iconv -f UTF-16 -t UTF-8 "$1"

    # UTF-8 with BOM
    elif [ "$(head -c3 "$1")" = $'\xEF\xBB\xBF' ]; then
        # not supported by busybox sed
        # sed '1s/^\xEF\xBB\xBF//' "$1"
        tail -c +4 "$1"

    # everything else
    else
        cat "$1"
    fi
}

simply_inf_word() {
    # 1 remove double quotes
    # 2 trim surrounding spaces
    # 3 replace \ and .\ with /
    # 4 collapse repeated / into a single /
    # 5 strip the leading /
    sed -E \
        -e 's,",,g' \
        -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' \
        -e 's,\.?\\,/,g' \
        -e 's,/+,/,g' \
        -e 's,^/,,'
}

# under reinstall.sh we cannot tell whether the iso is 32- or 64-bit, so mix_x86_x86_64 is true
# under trans.sh we can tell, so mix_x86_x86_64 is false
list_files_from_inf() {
    local inf=$1
    local arch=$2 # x86 amd64 arm64
    local mix_x86_x86_64=$3

    # all fields are case-insensitive
    inf_txts=$(simply_inf "$inf" | to_lower)

    is_match_section() {
        local section=$1

        [ "$line" = "[$section]" ] || [ "$line" = "[$section.$arch]" ] ||
            { $mix_x86_x86_64 && [ "$arch" = x86 ] && [ "$line" = "[$section.amd64]" ]; } ||
            { $mix_x86_x86_64 && [ "$arch" = amd64 ] && [ "$line" = "[$section.x86]" ]; }
    }

    is_match_catalogfile() {
        local left
        left=$(echo "$line" | awk -F= '{print $1}' | simply_inf_word)

        # does catalogfile.nt mean every nt variant?
        [ "$left" = "catalogfile" ] ||
            [ "$left" = "catalogfile.nt" ] ||
            [ "$left" = "catalogfile.nt$arch" ] ||
            { $mix_x86_x86_64 && [ "$arch" = x86 ] && [ "$left" = "catalogfile.ntamd64" ]; } ||
            { $mix_x86_x86_64 && [ "$arch" = amd64 ] && [ "$left" = "catalogfile.ntx86" ]; }
    }

    is_match_manufacturer_arch() {
        # x86 may be written NT or NTx86; other architectures must be explicit
        # https://learn.microsoft.com/en-us/windows-hardware/drivers/install/inf-manufacturer-section
        case "$arch" in
        x86) $mix_x86_x86_64 && regex='NT|NTx86|NTamd64' || regex='NT|NTx86' ;;
        amd64) $mix_x86_x86_64 && regex='NT|NTx86|NTamd64' || regex='NTamd64' ;;
        arm64) regex='NTarm64' ;;
        esac

        # note that cut and awk give different results here
        # although it makes no difference in this case
        # echo 1 | cut -d, -f2-
        # 1
        # echo 1 | awk -F, '{print $2}'
        # blank

        echo "$line" | awk -F, '{for(i=2;i<=NF;i++) print $i}' | grep -Eiwq "$regex"
    }

    # do we also need to read strings from [Strings]?

    # 0. check whether the inf matches the current architecture
    # version numbers are not compared yet

    ##############################################
    # note this case: an empty NTamd64.6.0 means 6.0 is not supported

    # [Manufacturer]
    # %V_INTEL%   = Intel, NTamd64.6.0, NTamd64.6.1.1

    # [Intel.NTamd64.6.0]
    # ; Empty section.

    # if this is ever changed to read supported architectures from the [] sections rather than Manufacturer, watch out for this case
    # [Intel.NTamd64.10.0.1..22000]
    ##############################################

    # example 1
    # [Manufacturer]
    # %Amazon% = AWSNVME, NTamd64, NTARM64

    # example 2
    # [Manufacturer]
    # %MyName% = MyName,NTx86.6.0,NTx86.5.1,
    # .
    # [MyName.NTx86.6.0] ; Empty section, so this INF does not support
    # .                  ; NT 6.0 and later.
    # .
    # [MyName.NTx86.5.1] ; Used for NT 5.1 and later
    # .                  ; (but not NT 6.0 and later due to the NTx86.6.0 entry)
    # %MyDev% = InstallB,hwid
    # .
    # [MyName]           ; Empty section, so this INF does not support
    # .                  ; Win2000
    # .

    # example 3
    # a driver shipped with the system, which has no [Manufacturer]

    # example 4
    # C:\Windows\INF\wfcvsc.inf
    # %StdMfg%=Standard,NTamd64...0x0000001,NTamd64...0x0000002,NTamd64...0x0000003

    in_section=false
    arch_matched=false
    has_manufacturer=false
    # without IFS=, read strips leading and trailing whitespace
    while read -r line; do
        if [[ "$line" = "["* ]]; then
            is_match_section manufacturer && has_manufacturer=true && in_section=true || in_section=false
            continue
        fi

        if $in_section; then
            if is_match_manufacturer_arch; then
                arch_matched=true
                break
            fi
        fi
    done < <(echo "$inf_txts")

    if $has_manufacturer && ! $arch_matched; then
        return 10
    fi

    # 1. print the .inf filename
    basename "$inf"

    # 2. print the .cat relative path
    # example
    # [version]
    # CatalogFile = "xxxxx.cat"
    # CatalogFile.NTAMD64=Balloon.cat
    in_section=false
    # without IFS=, read strips leading and trailing whitespace
    while read -r line; do
        if [[ "$line" = "["* ]]; then
            is_match_section version && in_section=true || in_section=false
            continue
        fi

        if $in_section && is_match_catalogfile; then
            echo "$line" | awk -F= '{print $2}' | simply_inf_word
        fi
    done < <(echo "$inf_txts")

    # 3. read SourceDisksNames
    # example
    # [SourceDisksNames]
    # 1 = "Windows NT CD-ROM",file.tag,, "\common"
    SourceDisksNames=
    in_section=false
    # without IFS=, read strips leading and trailing whitespace
    while read -r line; do
        if [[ "$line" = "["* ]]; then
            is_match_section sourcedisksnames && in_section=true || in_section=false
            continue
        fi
        # note there may be spaces and quotes

        if $in_section; then
            local num dir
            num=$(echo "$line" | awk -F= '{print $1}' | simply_inf_word)
            dir=$(echo "$line" | awk -F, '{print $4}' | simply_inf_word)
            # one record per line
            if [ -n "$SourceDisksNames" ]; then
                SourceDisksNames=$SourceDisksNames$'\n'
            fi
            SourceDisksNames="$SourceDisksNames$num:$dir"
        fi
    done < <(echo "$inf_txts")

    # 4. print the absolute paths from SourceDisksFiles
    # example
    # [SourceDisksFiles]
    # aha154x.sys = 1 , "\x86" ,,
    in_section=false
    # without IFS=, read strips leading and trailing whitespace
    while read -r line; do
        if [[ "$line" = "["* ]]; then
            is_match_section sourcedisksfiles && in_section=true || in_section=false
            continue
        fi

        if $in_section; then
            file=$(echo "$line" | awk -F= '{print $1}' | simply_inf_word)
            num=$(echo "$line" | awk -F'=|,' '{print $2}' | simply_inf_word)
            sub_dir=$(echo "$line" | awk -F, '{print $2}' | simply_inf_word)
            # there may be several
            while IFS= read -r parent_dir; do
                echo "$parent_dir/$sub_dir/$file" | simply_inf_word
            done < <(echo "$SourceDisksNames" | awk -F: "\$1==\"$num\" {print \$2}")
        fi
    done < <(echo "$inf_txts")
}

is_x_starts_with_y() {
    [[ "$1" =~ ^"$2" ]]
}

is_x_ends_with_y() {
    [[ "$1" =~ "$2"$ ]]
}

is_absolute_path() {
    # check whether the path starts with /

    # works in alpine ash
    # [[ "$1" = "/*" ]]

    # works in bash
    # [[ "$1" = /* ]]

    # works in both
    is_x_starts_with_y "$1" /
}

# windows only installs driver files matching its own architecture, even if the inf lists others
# so a DISM driver export does not contain the other architectures' files either

# best-effort matching of a path's letter case
get_path_in_correct_case() {
    # accepts both an argument and stdin
    local path
    path=$({ if [ -n "$1" ]; then echo "$1"; else cat; fi; })

    # split the path on / into a list
    # e.g. ///a///b/c.inf -> a b c.inf
    # shellcheck disable=SC2046
    set -- $(echo "$path" | grep -o '[^/]*')
    (
        local output=
        if is_absolute_path "$path"; then
            cd /
            output=/
        fi

        stop_find=false

        while [ $# -gt 0 ]; do
            local part=$1
            local tmp
            # shellcheck disable=SC2010
            if ! $stop_find; then
                if tmp=$(ls -1 | grep -Fix "$part"); then
                    part=$tmp
                    # greater than 1 means the current part is a directory
                    if [ $# -gt 1 ]; then
                        if ! cd "$part" 2>/dev/null; then
                            warn "Can't cd $path"
                            stop_find=true
                        fi
                    fi
                else
                    stop_find=true
                fi
            fi

            if [ $# -gt 1 ]; then
                output="$output$part/"
            else
                # the final part
                if is_x_ends_with_y "$path" /; then
                    output="$output$part/"
                else
                    output="$output$part"
                fi
            fi
            shift
        done

        echo "$output"
    )
}

is_file_or_link() {
    # -e / -f return false for a broken symlink
    # -L returns true for a broken symlink
    [ -f "$1" ] || [ -L "$1" ]
}

find_file_ignore_case() {
    # accepts both an argument and stdin
    local path
    path=$({ if [ -n "$1" ]; then echo "$1"; else cat; fi; })

    path=$(get_path_in_correct_case "$path")
    if is_file_or_link "$path"; then
        echo "$path"
    else
        warn "Can't find $path" >&2
        return 1
    fi
}

parse_inf_and_cp_driever() {
    local inf=$1
    local dst=$2
    local arch=$3
    local mix_x86_x86_64=$4

    info false "Add driver: $inf"

    # create the directory first, otherwise the ls file count cannot give us the index
    mkdir -p "$dst"
    # shellcheck disable=SC2012
    inf_index=$(($(ls -1 "$dst" | wc -l) + 1))
    inf_old_dir=$(dirname "$inf")
    inf_new_dir=$dst/$inf_index
    if driver_files=$(list_files_from_inf "$inf" "$arch" "$mix_x86_x86_64"); then
        mkdir -p "$inf_new_dir"
        (
            cd "$inf_old_dir" || error_and_exit "Can't cd $inf_old_dir"
            while read -r file; do
                if file=$(find_file_ignore_case "$file"); then
                    cp -v --parents "$file" "$inf_new_dir"
                fi
            done < <(echo "$driver_files")
        )
    else
        if [ $? -eq 10 ]; then
            warn "$inf arch not match."
        else
            error_and_exit "Unknown error while parse $inf."
        fi
    fi
}

get_sys_dir_for_eth() {
    (
        cd "$(readlink -f "/sys/class/net/$1")" || error_and_exit "Can't cd to $1"
        while ! [ "$(pwd)" = / ]; do
            # DRIVER=virtio-pci
            # PCI_CLASS=20000            # a leading 2 means a network device
            # PCI_ID=1AF4:1041
            # PCI_SUBSYS_ID=1AF4:1100
            # PCI_SLOT_NAME=0000:03:00.0
            if [ -f uevent ] && grep -q 'PCI_CLASS=2' uevent && grep -q 'PCI_ID' uevent; then
                pwd
                return
            fi
            cd ..
        done
        return 1
    )
}
