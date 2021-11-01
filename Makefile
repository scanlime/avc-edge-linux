PREFIX=avc-edge-linux

build:
	mkdir -p build
	docker rm ${PREFIX}-tmp || true
	docker build -t ${PREFIX} .
	docker create --name ${PREFIX}-tmp ${PREFIX}
	docker cp ${PREFIX}-tmp:/work/disk.img build/
	docker cp ${PREFIX}-tmp:/bootloader_installer/home/builder/grub/grub-core build/
	docker cp ${PREFIX}-tmp:/debugroot build/
	docker rm ${PREFIX}-tmp
	chmod a-w build/disk.img

run: build
	cp build/disk.img build/rw-disk.img
	qemu-system-i386 \
		-machine isapc -cpu 486 -m 32 \
		-drive if=ide,index=0,format=raw,file=build/rw-disk.img \
		-chardev socket,id=debug,host=127.0.0.1,port=1234,server=on,wait=off \
		-device isa-serial,iobase=0x3e8,chardev=debug,id=com3

flash: build
	scp build/disk.img crouton:tmp/disk.img
	ssh crouton lsblk /dev/sda '&&' sudo dd if=tmp/disk.img of=/dev/sda bs=64K

grubdebug:
	cd grub && gdb -x grub-gdb-experiment

menuconfig:
	docker rm ${PREFIX}-tmp || true
	docker build -t ${PREFIX}-kbuild --target kernel_builder .
	docker run -it --name ${PREFIX}-tmp ${PREFIX}-kbuild \
	 	make menuconfig
	docker cp ${PREFIX}-tmp:/home/builder/linux/.config kernel/config
	docker rm ${PREFIX}-tmp

clean:
	rm -Rf ./build

.PHONY: run build flash grubdebug menuconfig clean
