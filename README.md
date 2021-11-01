AVC Edge Linux
==============

Builds a tiny linux distro for the 486-based voting machine.

Software Parts list:
- Linux 5.14.15 kernel, compiled for i486
- Alpine Linux 3.14.2 userspace
- Custom built grub from git, patched for 486 compatibility
- Xorg 1.20.11, patched to resurrect ISA/VLB bus support

Hardware Parts list:
- Am486 CPU core at 66Mhz
- 3 serial ports (touchscreen, two general purpose)
- 1 parallel port (thermal printer)
- 2D graphics accelerator (24-bit 1024x768, Chips & Technologies 65550 over VLB)
- Dual 16-bit PCMCIA card slots
- 3M Dynapro touchscreen controller
- Compact flash acting as IDE hard disk
- Custom power management hardware
- Custom front panel peripherals including text LCD, smart card slot
- Custom interface to EEPROM storage

The BIOS has limited options for disk geometry and it uses CHS addressing exclusively. You'll need to pick a BIOS geometry with the same number of heads and sectors-per-track as your CF card actually reports, but the number of cylinders may be different. You'll need to put your CF card's CHS disk geometry in the Dockerfile so the partition layout can be generated correctly.

Status:
- Grub works, linux works, boots to busybox.
- Most hardware still untested
- PC Card controller recognized but not tested
- Working on getting Xorg running

