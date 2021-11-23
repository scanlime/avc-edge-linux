#!/bin/sh
while true; do
        (
                set -ve

		mount -t devtmpfs none /dev || true
		mount -t proc none /proc || true
		mount -t sysfs none /sys || true
		mount -t debugfs none /sys/kernel/debug || true
		mkdir -p /new_root

		echo Waiting before socket re-init
		sleep 2
                /lib/udev/pcmcia-socket-startup 0
		/lib/udev/pcmcia-socket-startup 1

		echo Waiting before mounting root from pcmcia
		echo 2
                mount /dev/sdb1 /new_root

		echo ' -p' > /sys/kernel/debug/dynamic_debug/control
        )
        if [ $? -eq 0 ]; then
                break
        else
                echo initrd failed, dropping to local shell. Exit to retry.
                /bin/sh
        fi
done

exec /bin/busybox switch_root /new_root /sbin/init

