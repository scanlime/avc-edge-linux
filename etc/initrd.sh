#!/bin/sh
while true; do
        (
                set -ve

                mount -t proc none /proc
                mount -t sysfs none /sys
                mkdir -p /new_root

                /lib/udev/pcmcia-socket-startup 0
                /lib/udev/pcmcia-socket-startup 1

                mount /dev/sdb1 /new_root
        )
        if [ $? -eq 0 ]; then
                break
        else
                echo initrd failed, dropping to local shell. Exit to retry.
                /bin/sh
        fi
done

exec /bin/busybox switch_root /new_root /sbin/init

