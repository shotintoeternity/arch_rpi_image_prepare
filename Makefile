# Default build variables, they may be passed via command line
ARCH?=rpi
BUILD?=$(shell date +%d-%m-%Y)
VERSION?="devBuild"
SOURCE?="piratebox"
BRANCH=master

ifeq ($(ARCH),rpi)
## based on http://archlinuxarm.org/platforms/armv6/raspberry-pi
ARCH_URL=http://archlinuxarm.org/os/ArchLinuxARM-rpi-latest.tar.gz
ARCH_FILE:=ArchLinuxARM-rpi-latest.tar.gz
endif

ifeq ($(ARCH),rpi2)
## based on http://archlinuxarm.org/platforms/armv7/broadcom/raspberry-pi-2
ARCH_URL=http://archlinuxarm.org/os/ArchLinuxARM-rpi-2-latest.tar.gz
ARCH_FILE:=ArchLinuxARM-rpi-2-latest.tar.gz
endif

PIRATEBOX_WS_GIT:=https://github.com/PirateBox-Dev/PirateBoxScripts_Webserver.git

PIRATEBOX_PACKAGE_FOLDER=piratebox-ws

# Name of the generated image file
IMAGE_FILENAME=./$(SOURCE)_$(ARCH)_$(VERSION)-$(BUILD).img
ZIPPED_FILENAME=$(IMAGE_FILENAME).zip

# Mount points
MOUNT_FOLDER:=./mount
BOOT_FOLDER:=$(MOUNT_FOLDER)/boot
ROOT_FOLDER:=$(MOUNT_FOLDER)/root

SRC_PACKAGE_FOLDER:="./packages/prebuild"
TGT_PACKAGE_FOLDER:=$(ROOT_FOLDER)/prebuild

SRC_CHROOT_FOLDER:=./chroot
TGT_CHROOT_FOLDER:=$(ROOT_FOLDER)/root/chroot

# Imagesize should be 2GB
IMAGESIZE:=$(shell echo "2 * 1024 * 1024 * 1024" | bc)
BLOCKSIZE=512
NEEDED_SECTOR_COUNT=$(shell echo ${IMAGESIZE} / ${BLOCKSIZE} | bc )

LO_DEVICE=

all: $(ARCH_FILE) $(IMAGE_FILENAME) partition format mount_image  \
	install_files chroot_install copy_helpers \
	 chroot_cleanup umount free_lo package

$(MOUNT_FOLDER) $(BOOT_FOLDER) $(ROOT_FOLDER):
	@mkdir -p $@

$(IMAGE_FILENAME):
	@echo "## Creating $(ARCH) image file"
	@echo "* Filename\t$(IMAGE_FILENAME)"
	@echo "* Blocksize\t$(BLOCKSIZE)"
	@echo "* Sectors\t$(NEEDED_SECTOR_COUNT)"
	@echo "* Total size\t$(IMAGESIZE) Bytes (2GB)"
	@dd if=/dev/zero bs=$(BLOCKSIZE) count=$(NEEDED_SECTOR_COUNT) status=none | pv --size $(IMAGESIZE) | dd of=$@ bs=$(BLOCKSIZE) count=$(NEEDED_SECTOR_COUNT) status=none
	@echo ""

get_lodevice:
	$(eval LO_DEVICE=$(shell sudo losetup --partscan --find --show $(IMAGE_FILENAME)))

## Partitions
# as it is no blockdevice, we need to specify the blocksize
# Empty Partionts
# Then with first n -> 100MB dos partition
# 2nd n -> fill the rest with another primary partition
partition:
	@echo "## Creating partitions..."
	cat ./config/fdisk_cmd.txt | sudo fdisk $(IMAGE_FILENAME) > /dev/null
	@sync
	@echo ""

format: get_lodevice
	@echo "## Formatting partitions..."
	sudo  mkfs.vfat "$(LO_DEVICE)p1" > /dev/null
	sudo  mkfs.ext4 "$(LO_DEVICE)p2" > /dev/null
	@echo ""

free_lo:
ifneq ("$(wildcard $(LO_DEVICE))", "")
	sudo losetup -d $(LO_DEVICE)
endif

$(ARCH_FILE):
	@echo "## Obtaining root filesystem..."
	@wget -q --show-progress -c $(ARCH_URL)
	@echo ""

$(PIRATEBOX_PACKAGE_FOLDER):
	@echo "## Obtaining piratebox scripts..."
	git clone $(PIRATEBOX_WS_GIT) $(PIRATEBOX_PACKAGE_FOLDER) > /dev/null
	cd $(PIRATEBOX_PACKAGE_FOLDER) && git checkout $(BRANCH) > /dev/null
	@echo ""

build_piratebox: $(PIRATEBOX_PACKAGE_FOLDER)
	@echo "# Building piratebox package..."
	cd $(PIRATEBOX_PACKAGE_FOLDER) && make
	@echo ""

mount_image: $(BOOT_FOLDER) $(ROOT_FOLDER) get_lodevice
	@echo "## Mounting image..."
	sudo mount "$(LO_DEVICE)p1" $(BOOT_FOLDER)
	sudo mount "$(LO_DEVICE)p2" $(ROOT_FOLDER)
	@echo ""

umount:
	@echo "## Unmounting image..."
	- sudo umount $(BOOT_FOLDER)
	- sudo umount $(ROOT_FOLDER)
	@echo ""

install_files: build_piratebox
	@echo "## Moving files to their place..."
	sudo mkdir -p $(TGT_PACKAGE_FOLDER) > /dev/null
	sudo mkdir -p $(TGT_CHROOT_FOLDER) > /dev/null
	sudo tar -xf $(ARCH_FILE) -C $(ROOT_FOLDER) --warning=none
	sudo cp -rv $(SRC_PACKAGE_FOLDER)/rpi/* $(TGT_PACKAGE_FOLDER) > /dev/null
	sudo cp $(PIRATEBOX_PACKAGE_FOLDER)/BuildScripts/*.service "$(ROOT_FOLDER)/etc/systemd/system"
	sudo cp $(PIRATEBOX_PACKAGE_FOLDER)/BuildScripts/RPi_motd.txt "$(ROOT_FOLDER)/etc/motd"
	sudo cp $(PIRATEBOX_PACKAGE_FOLDER)/*.tar.gz "$(ROOT_FOLDER)/root"
	sudo cp -rv $(SRC_CHROOT_FOLDER)/* $(TGT_CHROOT_FOLDER) > /dev/null
	sudo mv $(ROOT_FOLDER)/boot/* $(BOOT_FOLDER) > /dev/null
	sudo cp chroot/wpa_supplicant.conf $(BOOT_FOLDER)/ > /dev/null
	sudo cp /usr/bin/qemu-arm-static $(ROOT_FOLDER)/usr/bin > /dev/null
	sudo sh -c 'echo "/dev/mmcblk0p1 /boot vfat defaults,nofail 0 0" > $(ROOT_FOLDER)/etc/fstab'
	@sync
	@echo ""

chroot_install:
	@echo "## chroot'ing to RPi environment..."
	- sudo mv -f $(ROOT_FOLDER)/etc/resolv.conf $(ROOT_FOLDER)/etc/resolv.conf.bak > /dev/null
	sudo cp /etc/resolv.conf $(ROOT_FOLDER)/etc/resolv.conf > /dev/null
	sudo mount -t proc proc $(ROOT_FOLDER)/proc/ > /dev/null
	@echo ""
	@echo "# Installing packages..."
	sudo chroot $(ROOT_FOLDER) sh -c "/root/chroot/install_packages.sh > /dev/null"
	@echo ""
	@echo "# Configuring sudo..."
	sudo chroot $(ROOT_FOLDER) sh -c "/root/chroot/configure_sudo.sh > /dev/null"
	@echo ""
	@echo "# Installing PirateBox..."
	sudo chroot $(ROOT_FOLDER) sh -c "/root/chroot/install_piratebox.sh > /dev/null"
	@echo ""

copy_helpers:
	sudo cp ./helpers/99-wifi.rules $(ROOT_FOLDER)/etc/udev/rules.d/
	sudo cp ./helpers/detect-wifi.sh $(ROOT_FOLDER)/opt/piratebox/bin/
	sudo cp ./helpers/pi-starter.sh $(ROOT_FOLDER)/opt/piratebox/bin/

chroot_cleanup:
	@echo "## Cleaning up chroot..."
	- sudo mv $(ROOT_FOLDER)/etc/resolv.conf.bak $(ROOT_FOLDER)/etc/resolv.conf
	- sudo umount $(ROOT_FOLDER)/proc/ > /dev/null
	@echo ""

clean: chroot_cleanup umount free_lo
	@echo "## Cleaning up..."
	rm -f $(IMAGE_FILENAME) > /dev/null
	rm -f $(ZIPPED_FILENAME) > /dev/null
	sudo rm -rf $(MOUNT_FOLDER) > /dev/null
	@echo ""

cleanall: clean
	rm -rf $(PIRATEBOX_PACKAGE_FOLDER) > /dev/null
	rm -f $(ARCH_FILE) > /dev/null

package:
	@echo "## Packaging image for distribution..."
	zip $(ZIPPED_FILENAME) $(IMAGE_FILENAME)
	@echo ""

#format_only: get_lodevice format free_lo
#create_arch_image: $(IMAGE_FILENAME) partitions get_lodevice format prepare_environment install_files umount free_lo
