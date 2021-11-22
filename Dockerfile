ARG I386_BASE_IMAGE=i386/alpine:3.14.3
ARG LINUX_URL=https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-5.15.2.tar.xz
ARG GRUB_URL=https://git.savannah.gnu.org/git/grub.git
ARG GRUB_VERSION=50aace6bdb918150ba47e3c16146dcca271c134a

# The BIOS cares about CHS geometry, heads and sectors should match your disk
ARG BOOT_DISK_CYLINDERS=60
ARG BOOT_DISK_HEADS=4
ARG BOOT_DISK_SECTORS=32

###############################################################
FROM $I386_BASE_IMAGE as kernel_builder
ARG LINUX_URL

RUN apk add \
  gcc make linux-headers libc-dev \
  patch wget less bc zstd xz flex bison perl \
  openssl-dev elfutils-dev ncurses-dev

RUN adduser -D builder
USER builder
WORKDIR /home/builder

RUN wget -q -O linux.tar.xz $LINUX_URL
RUN mkdir linux && tar Jxf linux.tar.xz --strip-components=1 -C linux
WORKDIR /home/builder/linux

COPY kernel/config .config
RUN make -j16
RUN make INSTALL_MOD_PATH=/home/builder modules_install
RUN rm vmlinux-gdb.py && ln -s scripts/gdb/vmlinux-gdb.py .

###############################################################
FROM $I386_BASE_IMAGE as aports_builder

RUN apk add abuild sudo gdb
RUN adduser -G abuild -D builder
RUN echo "%abuild ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers && chmod 440 /etc/sudoers
COPY --chown=builder:abuild aports /home/builder/
USER builder
WORKDIR /home/builder
RUN abuild-keygen -ain

RUN cd xorg-server && abuild checksum && abuild -rK
RUN cd xf86-video-chips && abuild checksum && abuild -rK
RUN cd linuxconsoletools && abuild checksum && abuild -rK
RUN cd barrier && abuild -rK

###############################################################
FROM $I386_BASE_IMAGE as xdaliclock_builder

RUN apk add wget make gcc libc-dev libx11-dev libxt-dev libxext-dev
RUN adduser -D builder
USER builder
WORKDIR /home/builder

RUN wget -q -O xdaliclock.tar.gz https://www.jwz.org/xdaliclock/xdaliclock-2.44.tar.gz
RUN tar zxf xdaliclock.tar.gz
WORKDIR /home/builder/xdaliclock-2.44/X11
RUN ./configure
RUN make -j16

###############################################################
FROM $I386_BASE_IMAGE as micropolis_builder

RUN apk add \
        wget make gcc git patch bison \
        libc-dev libx11-dev libxpm-dev libxext-dev

RUN adduser -D builder
USER builder
WORKDIR /home/builder

RUN git clone https://github.com/SimHacker/micropolis.git
WORKDIR /home/builder/micropolis/micropolis-activity
RUN git checkout b0c5a3f495ebabbc51d5e45dac948d8e40fc53ee

COPY micropolis/ ./
RUN patch -p2 -i tcl-build-fix.patch
RUN make
RUN make DESTDIR=/home/builder install

###############################################################
FROM $I386_BASE_IMAGE as bootloader_installer
ARG DISK_SIZE_HEADS
ARG DISK_SIZE_SECTORS
ARG GRUB_URL
ARG GRUB_VERSION

RUN apk add e2fsprogs-extra git make gcc automake \
        libc-dev linux-headers autoconf coreutils patch \
        bison flex xz-dev lvm2-dev fuse-dev automake \
        autoconf libtool python3 freetype-dev unifont \
        gettext-dev pkgconf-dev

RUN adduser -D builder
USER builder
WORKDIR /home/builder

RUN git clone $GRUB_URL grub
WORKDIR /home/builder/grub
RUN git pull && git checkout $GRUB_VERSION
RUN ./bootstrap
RUN ./configure

# Patch grub to remove relocator code to disable PAE mode, it faults on Am486.
COPY grub/no-pae-mode.patch .
RUN patch -p1 -i no-pae-mode.patch

# The BIOS has an incorrect disk cylinder count, patch grub not to care
COPY grub/no-bios-disk-bounds-check.patch .
RUN patch -p1 -i no-bios-disk-bounds-check.patch

# We want to use PATA disks (via PCMCIA and SuperIO) but grub's driver assumes PCI
COPY grub/pata-without-pci.patch .
RUN patch -p1 -i pata-without-pci.patch

# GRUB uses a 1ms timer delay in its PATA which isn't practical on
# systems without high res timers or TSC, swap it for an I/O delay.
COPY grub/pata-io-delay.patch .
RUN patch -p1 -i pata-io-delay.patch

RUN make -j16
USER root
RUN make install

COPY grub/setup.sh /setup.sh
RUN dd if=/dev/urandom bs=512 count=4 of=/setup_done
RUN mkdir -p /boot/grub && touch /boot/grub/grub.cfg

RUN rm \
        /usr/local/share/grub/unicode.pf2 \
        /usr/local/lib/grub/i386-pc/gcry* \
        /usr/local/lib/grub/i386-pc/gfx* \
        /usr/local/lib/grub/i386-pc/zstd* \
        /usr/local/lib/grub/i386-pc/pgp* \
        /usr/local/lib/grub/i386-pc/btrfs* \
        /usr/local/lib/grub/i386-pc/regexp*

###############################################################
FROM $I386_BASE_IMAGE as base_with_packages

COPY --from=aports_builder /home/builder/.abuild/*.pub /etc/apk/keys/
COPY --from=aports_builder /home/builder/packages/builder/ /usr/local/pkg/
RUN echo @custom /usr/local/pkg >> /etc/apk/repositories

###############################################################
FROM base_with_packages as debugroot

RUN apk --update-cache add \
        musl-dbg libstdc++ \
        xorg-server@custom \
        xorg-server-dbg@custom \
        xf86-video-chips@custom

COPY --from=aports_builder \
        /home/builder/xf86-video-chips/src/xf86-video-chips-1.4.0/src/.libs/chips_drv.so \
        /usr/lib/xorg/modules/drivers/chips_drv.so

###############################################################
FROM base_with_packages as rootfs_common

COPY --from=kernel_builder /home/builder/linux/arch/x86/boot/bzImage /boot/bzImage
COPY --from=kernel_builder /home/builder/lib/ /lib/
COPY --from=aports_builder /usr/bin/gdbserver /usr/bin/

COPY etc/fstab /etc/
COPY etc/pcmcia/config.opts /etc/pcmcia/
COPY etc/network/interfaces /etc/network/interfaces
COPY grub/grub-linux.cfg /boot/grub/grub.cfg

# Serial console by default
RUN echo ttyS2 >> /etc/securetty && \
  echo ttyS2::respawn:/sbin/getty -L ttyS2 115200 vt100 >> /etc/inittab

RUN echo "root:vote" | chpasswd

###############################################################
FROM $I386_BASE_IMAGE as initfs

RUN apk --update-cache add \
	pcmciautils

COPY etc/fstab /etc/
COPY etc/pcmcia/config.opts /etc/pcmcia/
COPY etc/network/interfaces /etc/network/interfaces
COPY etc/initrd.sh /init

###############################################################
FROM rootfs_common as rootfs_large

RUN apk --update-cache add \
        e2fsprogs linuxconsoletools@custom \
        pcmciautils nbd dhclient \
        minicom vim tmux gdb \
        cmatrix figlet fortune htop wireshark \
        util-linux bash coreutils binutils findutils grep \
        musl-locales mandoc man-pages docs \
        make gcc build-base \
        alpine-base eudev udev-init-scripts-openrc \
        dropbear dropbear-openrc \
        libx11 libxt libxext libxpm libstdc++ \
        xset xhost xterm twm fvwm xeyes xdpyinfo \
        xfce4 xfce4-terminal wine \
        xorg-server@custom xf86-video-chips@custom \
        barrier@custom

COPY --from=xdaliclock_builder /home/builder/xdaliclock-2.44/X11/xdaliclock /usr/local/bin/
COPY --from=micropolis_builder /home/builder/usr/ /usr/
COPY etc/xorg.conf /etc/xorg.conf

RUN setup-keymap us us
RUN setup-hostname am486
RUN rc-update add udev

###############################################################
FROM $I386_BASE_IMAGE as boot_disk_builder
ARG BOOT_DISK_CYLINDERS
ARG BOOT_DISK_HEADS
ARG BOOT_DISK_SECTORS
ARG GRUB_RESERVED_TRACKS=2

RUN apk add \
  qemu-system-i386 util-linux e2fsprogs wget less xxd bash

SHELL ["/bin/bash", "-c"]
RUN mkdir /work
WORKDIR /work

# Partition with careful attention to DOS CHS geometry
RUN echo $[ $BOOT_DISK_CYLINDERS * $BOOT_DISK_HEADS * $BOOT_DISK_SECTORS ] > total.sectors && \
  echo $[ $GRUB_RESERVED_TRACKS * $BOOT_DISK_SECTORS ] > rootfs.sector && \
  echo $[ ( `cat total.sectors` - `cat rootfs.sector` ) / 2 ] > rootfs.kilobytes && \
  dd if=/dev/zero of=disk.img bs=512 count=`cat total.sectors` && \
  echo -ne "o\nn\np\n1\n`cat rootfs.sector`\n\na\nw\n" > fdisk.command && \
  fdisk -cdos -walways -C$BOOT_DISK_CYLINDERS -H$BOOT_DISK_HEADS -S$BOOT_DISK_SECTORS disk.img < fdisk.command

COPY grub/grub-startup.cfg /rootfs/boot/grub/grub.cfg
RUN mkfs.ext2 -d /rootfs/ -b 1024 -m 0 -v rootfs.img `cat rootfs.kilobytes` && \
  dd if=rootfs.img of=disk.img bs=512 seek=`cat rootfs.sector` conv=notrunc

# Bootloader installer runs inside qemu so we can write and mount block devices.
# Image is sized automatically to twice the size of the copied source directory.
COPY --from=bootloader_installer / /bootloader_installer/
RUN mkfs.ext4 -d /bootloader_installer/ -m 0 -v \
  bootloader_installer.img \
  $[ 2 * `du -s /bootloader_installer/ | cut -f1` ]

COPY --from=kernel_builder /home/builder/linux/arch/x86/boot/bzImage /boot/bzImage
RUN qemu-system-i386 \
  -machine isapc -cpu 486 -no-reboot \
  -drive if=ide,index=0,format=raw,file=disk.img \
  -drive if=ide,index=1,format=raw,file=bootloader_installer.img \
  -nographic -kernel /boot/bzImage -append \
  "console=ttyS0,115200 root=/dev/sdb panic=-1 init=/setup.sh"

# Check that we completed setup.sh
RUN diff <(xxd bootloader_installer.img | head) <(xxd /bootloader_installer/setup_done | head)

###############################################################
FROM $I386_BASE_IMAGE as root_image_builder
ARG ROOT_SIZE=1G

WORKDIR /work
RUN apk add e2fsprogs cpio

COPY --from=rootfs_large / /rootfs/
COPY --from=initfs / /initfs/
RUN (cd /initfs; find . | sort | cpio --quiet --renumber-inodes	-o -H newc | gzip) > /rootfs/boot/initramfs.gz
RUN mkfs.ext4 -d /rootfs/ -b 4096 -m 0 -v rootfs.img $ROOT_SIZE

###############################################################
FROM $I386_BASE_IMAGE as outputs

# Prepare userspace debug symbols
COPY --from=debugroot /bin /build/debugroot/bin
COPY --from=debugroot /usr /build/debugroot/usr
COPY --from=debugroot /lib /build/debugroot/lib
COPY --from=aports_builder /home/builder/xorg-server/src /build/debugroot/src
COPY --from=aports_builder /home/builder/xf86-video-chips/src /build/debugroot/src
COPY --from=kernel_builder /home/builder/linux /build/debugroot/linux
COPY --from=bootloader_installer /home/builder/grub/grub-core /build/debugroot/grub-core

COPY --from=root_image_builder /work/rootfs.img /build/rootfs.img
COPY --from=boot_disk_builder /work/disk.img /build/bootdisk.img
