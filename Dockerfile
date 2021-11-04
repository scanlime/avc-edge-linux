ARG I386_BASE_IMAGE=i386/alpine:3.14.2
ARG LINUX_URL=https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-5.14.15.tar.xz
ARG GRUB_URL=https://git.savannah.gnu.org/git/grub.git
ARG GRUB_VERSION=50aace6bdb918150ba47e3c16146dcca271c134a

ARG DISK_SIZE_CYLINDERS=978
ARG DISK_SIZE_HEADS=4
ARG DISK_SIZE_SECTORS=32

###############################################################
FROM $I386_BASE_IMAGE as kernel_builder
ARG LINUX_URL

RUN apk add \
  gcc make linux-headers libc-dev \
  wget less bc zstd xz flex bison \
  openssl-dev elfutils-dev ncurses-dev

RUN adduser -D builder
USER builder
WORKDIR /home/builder

RUN wget -q -O linux.tar.xz $LINUX_URL
RUN mkdir linux && tar Jxf linux.tar.xz --strip-components=1 -C linux
WORKDIR /home/builder/linux

COPY kernel/config .config
RUN make -j16

###############################################################
FROM $I386_BASE_IMAGE as aports_builder

RUN apk add abuild sudo gdb
RUN adduser -G abuild -D builder
RUN echo "%abuild ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers && chmod 440 /etc/sudoers
COPY --chown=builder:abuild aports /home/builder/
USER builder
RUN abuild-keygen -ain

WORKDIR /home/builder/xorg-server
RUN abuild checksum && abuild -rK

WORKDIR /home/builder/xf86-video-chips
RUN abuild checksum && abuild -rK

USER root
RUN mkdir /src && mv /home/builder/*/src/* /src/

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

RUN make -j16
USER root
RUN make install

COPY grub/setup.sh /setup.sh
RUN dd if=/dev/urandom bs=512 count=4 of=/setup_done
RUN mkdir -p /boot/grub && touch /boot/grub/grub.cfg
RUN rm /usr/local/share/grub/unicode.pf2

###############################################################
FROM $I386_BASE_IMAGE as debugroot

COPY --from=aports_builder /home/builder/packages/builder/ /packages/
RUN echo @custom /packages >> /etc/apk/repositories

RUN apk --update-cache --allow-untrusted add \
        musl-dbg libstdc++ \
        xorg-server@custom \
        xorg-server-dbg@custom \
        xf86-video-chips@custom

COPY --from=aports_builder \
        /src/xf86-video-chips-1.4.0/src/.libs/chips_drv.so \
        /usr/lib/xorg/modules/drivers/chips_drv.so

###############################################################
FROM $I386_BASE_IMAGE as rootfs

COPY --from=kernel_builder /home/builder/linux/arch/x86/boot/bzImage /boot/bzImage
COPY --from=aports_builder /usr/bin/gdbserver /usr/bin/
COPY --from=xdaliclock_builder /home/builder/xdaliclock-2.44/X11/xdaliclock /usr/bin/
COPY --from=micropolis_builder /home/builder/usr/ /usr/
COPY --from=aports_builder /home/builder/packages/builder/ /packages/
RUN echo @custom /packages >> /etc/apk/repositories

RUN apk --update-cache --allow-untrusted add \
        alpine-base libstdc++ \
        tmux minicom ltrace strace socat \
        libx11 libxt libxext libxpm \
        setxkbmap xkeyboard-config xdpyinfo xset xhost \
        xterm xclock twm \
        xorg-server@custom xf86-video-chips@custom

COPY etc/fstab /etc/
COPY etc/xorg.conf /etc/
COPY grub/grub.cfg /boot/grub/
RUN setup-alpine -q -f /etc/setup-alpine.conf
RUN echo "root:vote" | chpasswd

# Serial console by default
RUN echo ttyS2 >> /etc/securetty && \
  echo ttyS2::respawn:/sbin/getty -L ttyS2 115200 vt100 >> /etc/inittab

# Trim out large things we aren't using
RUN rm -R \
        /packages \
        /sbin/apk \
        /etc/apk \
        /usr/share/X11/xkb/symbols \
        /var/cache \
        /var/log/* \
        /usr/lib/pkgconfig \
        /etc/ssl \
        /lib/libapk.* \
        /usr/lib/engines-* \
        /usr/lib/dri \
        /usr/lib/vdpau \
        /usr/lib/libGL* \
        /usr/lib/libwayland* \
        /usr/lib/libepoxy.* \
        /usr/lib/libglapi.* \
        /usr/lib/libdrm_* \
        /usr/share/fonts/misc/10x20.pcf.gz \
        /usr/share/fonts/misc/k14.pcf.gz \
        /usr/share/fonts/misc/12x13ja.pcf.gz \
        /usr/share/fonts/misc/18x18ja.pcf.gz \
        /usr/share/fonts/misc/18x18ko.pcf.gz

###############################################################
FROM $I386_BASE_IMAGE as image_builder
ARG DISK_SIZE_CYLINDERS
ARG DISK_SIZE_HEADS
ARG DISK_SIZE_SECTORS
ARG GRUB_RESERVED_TRACKS=2

RUN apk add \
  qemu-system-i386 util-linux e2fsprogs wget less xxd bash

SHELL ["/bin/bash", "-c"]
RUN mkdir /work
WORKDIR /work

# Partition with careful attention to DOS CHS geometry
RUN echo $[ $DISK_SIZE_CYLINDERS * $DISK_SIZE_HEADS * $DISK_SIZE_SECTORS ] > total.sectors && \
  echo $[ $GRUB_RESERVED_TRACKS * $DISK_SIZE_SECTORS ] > rootfs.sector && \
  echo $[ ( `cat total.sectors` - `cat rootfs.sector` ) / 2 ] > rootfs.kilobytes && \
  dd if=/dev/zero of=disk.img bs=512 count=`cat total.sectors` && \
  echo -ne "o\nn\np\n1\n`cat rootfs.sector`\n\na\nw\n" > fdisk.command && \
  fdisk -cdos -walways -C$DISK_SIZE_CYLINDERS -H$DISK_SIZE_HEADS -S$DISK_SIZE_SECTORS disk.img < fdisk.command

# Build main rootfs as ext2 then add a journal after setting up grub
COPY --from=rootfs / /rootfs/
RUN mkfs.ext2 -d /rootfs/ -b 1024 -m 0 -v rootfs.img `cat rootfs.kilobytes` && \
  dd if=rootfs.img of=disk.img bs=512 seek=`cat rootfs.sector` conv=notrunc

# Bootloader installer runs inside qemu so we can write and mount block devices.
# Image is sized automatically to twice the size of the copied source directory.
COPY --from=bootloader_installer / /bootloader_installer/
RUN mkfs.ext4 -d /bootloader_installer/ -m 0 -v \
  bootloader_installer.img \
  $[ 2 * `du -s /bootloader_installer/ | cut -f1` ]
RUN qemu-system-i386 \
  -machine isapc -cpu 486 -no-reboot \
  -drive if=ide,index=0,format=raw,file=disk.img \
  -drive if=ide,index=1,format=raw,file=bootloader_installer.img \
  -nographic -kernel /rootfs/boot/bzImage -append \
  "console=ttyS0,115200 root=/dev/sdb panic=-1 init=/setup.sh"

# Check that we completed setup.sh
RUN diff <(xxd bootloader_installer.img | head) <(xxd /bootloader_installer/setup_done | head)

# Prepare userspace debug symbols
COPY --from=debugroot /bin /debugroot/bin
COPY --from=debugroot /usr /debugroot/usr
COPY --from=debugroot /lib /debugroot/lib
COPY --from=aports_builder /src /debugroot/src
