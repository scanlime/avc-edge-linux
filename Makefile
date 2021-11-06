PREFIX=avc-edge-linux

.PHONY: build
build:
	mkdir -p build
	docker rm ${PREFIX}-tmp || true
	docker build -t ${PREFIX} .
	docker create --name ${PREFIX}-tmp ${PREFIX}

.PHONY: clean
clean:
	rm -Rf ./build

build/debugroot: build
	docker cp ${PREFIX}-tmp:/debugroot build/

build/netroot.img: build
	docker cp ${PREFIX}-tmp:/work/netroot.img build/
	chmod a-w build/netroot.img

build/disk.img: build
	docker cp ${PREFIX}-tmp:/work/disk.img build/
	chmod a-w build/disk.img

build/rw-netroot.img: build build/netroot.img
	cp -f build/netroot.img build/rw-netroot.img
	chmod 0600 build/rw-netroot.img

build/rw-disk.img: build build/disk.img
	cp -f build/disk.img build/rw-disk.img
	chmod 0600 build/rw-disk.img

.PHONY: nbd
nbd: build build/rw-netroot.img
	nbd-server 19999 `pwd`/build/rw-netroot.img -d -M 1 -C /dev/null

.PHONY: run
run: build build/rw-disk.img
	qemu-system-i386 -curses \
		-machine isapc -cpu 486 -m 32 \
		-drive if=ide,index=0,format=raw,file=build/rw-disk.img \
		-chardev socket,id=debug,host=127.0.0.1,port=1234,server=on,wait=off \
		-device isa-serial,iobase=0x3e8,chardev=debug,id=com3

.PHONY: flash
flash: build build/disk.img
	scp build/disk.img crouton:tmp/disk.img
	ssh crouton lsblk /dev/sda '&&' sudo dd if=tmp/disk.img of=/dev/sda bs=64K

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

