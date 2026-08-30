#!/bin/sh
prefix=$1

# Do not use on Windows: the result is inaccurate
# May also be inaccurate on the original system, e.g. Oracle with a cloud kernel?

# Note: the debian initrd has no xargs

# The last tty is the primary one and shows the most complete output
if [ "$(uname -m)" = "aarch64" ]; then
    ttys="ttyS0 ttyAMA0 tty0"
else
    ttys="ttyS0 tty0"
fi

# Not all ttys necessarily exist in the install environment
# hytron has ttyS0 but it is not writable
# As a cmdline boot parameter, explicitly exclude non-writable ttys so getty does not restart in a loop
# https://github.com/bin456789/reinstall/issues/620

if [ "$prefix" = "console=" ]; then
    is_for_cmdline=true
else
    is_for_cmdline=false
fi

# Purpose       Condition
# Install log   Exists and is writable
# console       Exists and is writable, or absent (not all ttys exist in the install environment)

is_first=true
for tty in $ttys; do
    if { [ -c "/dev/$tty" ] && stty -g -F "/dev/$tty" >/dev/null 2>&1; } ||
        { $is_for_cmdline && ! [ -c "/dev/$tty" ]; }; then
        if $is_first; then
            is_first=false
        else
            printf " "
        fi

        printf "%s" "$prefix$tty"

        if $is_for_cmdline &&
            { [ "$tty" = ttyS0 ] || [ "$tty" = ttyAMA0 ]; }; then
            printf ",115200n8"
        fi
    fi
done
