#!/bin/sh
while true; do
        (
                set -ve

                mount -t proc none /proc
                mount -o remount,rw /
                mount -a
                mkdir -p /netroot
                if [ ! -b /dev/nbd0 ]; then
                        mknod /dev/nbd0 b 43 0
                fi

                /lib/udev/pcmcia-socket-startup 0
                /lib/udev/pcmcia-socket-startup 1

                modprobe 3c589_cs
                modprobe pata_pcmcia
                dhclient eth0
                ip addr
                ntpd -qndp 10.0.0.1
                date

                nbd-client 10.0.0.16 19999 /dev/nbd0

                mount /dev/nbd0 /netroot
                cat /etc/resolv.conf* > /netroot/etc/resolv.conf
                mount -o bind /dev /netroot/dev
                mount -o bind /sys /netroot/sys
                mount -o bind /proc /netroot/proc
        )
        if [ $? -eq 0 ]; then
                echo Ready to switch to network root
                break
        else
                echo Failed network boot, dropping to local shell. Exit to retry.
                /bin/sh
        fi
done

exec chroot /netroot /sbin/init
