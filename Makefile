PREFIX=avc-edge-linux

.PHONY: all
all: clean build debug flash nbd

.PHONY: build
build:
	mkdir -p build
	docker rm ${PREFIX}-tmp || true
	docker build -t ${PREFIX} .
	docker create --name ${PREFIX}-tmp ${PREFIX}

.PHONY: clean
clean:
	rm -Rf ./build

.PHONY: debug
debug: build build/debugroot build/rw-rootfs.img build/bootdisk.img

build/debugroot: build
	docker cp ${PREFIX}-tmp:/build/debugroot build/

build/rootfs.img: build
	docker cp ${PREFIX}-tmp:/build/rootfs.img build/
	chmod a-w build/rootfs.img

build/bootdisk.img: build
	docker cp ${PREFIX}-tmp:/build/bootdisk.img build/
	chmod a-w build/bootdisk.img

build/rw-rootdisk.img: build/rootfs.img
	fallocate -l 8G $@
	echo label: dos | sfdisk $@ 
	echo 1 : start=2048, size=8388608, type=83 | sfdisk $@
	dd if=build/rootfs.img of=$@ conv=notrunc bs=512 seek=2048

build/rw-bootdisk.img: build/bootdisk.img
	cp -f build/bootdisk.img build/rw-bootdisk.img
	chmod 0600 build/rw-bootdisk.img

.PHONY: nbd
nbd: build/rw-rootfs.img
	nbd-server 19999 `pwd`/build/rw-rootfs.img -d -M 1 -C /dev/null

.PHONY: run
run: build build/rw-rootdisk.img build/rw-bootdisk.img
	qemu-system-i386 -curses \
		-machine isapc -cpu 486 -m 32 \
		-drive if=ide,index=0,format=raw,file=build/rw-bootdisk.img \
		-drive if=ide,index=2,format=raw,file=build/rw-rootdisk.img \
		-chardev socket,id=debug,host=127.0.0.1,port=1234,server=on,wait=off \
		-device isa-serial,iobase=0x3e8,chardev=debug,id=com3

.PHONY: flash
flash: build build/bootdisk.img
	scp build/bootdisk.img crouton:tmp/disk.img
	ssh crouton lsblk /dev/sda '&&' sudo dd if=tmp/disk.img of=/dev/sda bs=4K oflag=direct status=progress

.PHONY: grubdebug
grubdebug: build/debugroot
	cd grub && gdb -x grub-gdb-experiment

.PHONY: menuconfig
menuconfig:
	docker rm ${PREFIX}-tmp || true
	docker build -t ${PREFIX}-kbuild --target kernel_builder .
	docker run -it --name ${PREFIX}-tmp ${PREFIX}-kbuild \
	 	make menuconfig
	docker cp ${PREFIX}-tmp:/home/builder/linux/.config kernel/config
	docker rm ${PREFIX}-tmp

