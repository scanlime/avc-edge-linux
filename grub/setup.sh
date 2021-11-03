#!/bin/sh
set -ve

mount -t proc none /proc
mount -o remount,rw /
mkdir -p /mnt /boot
mount /dev/sda1 /mnt
mount -o bind /mnt/boot /boot

/usr/local/sbin/grub-install /dev/sda

df -h /mnt
umount /mnt
sync
tune2fs -j /dev/sda1

sync
dd if=/setup_done of=/dev/sdb bs=512 oflag=direct

# Bootloader setup done, there will be an emulated kernel panic now on purpose.
