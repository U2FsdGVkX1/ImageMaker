#!/bin/bash

set -ex

[ "$(id -u)" -ne 0 ] && echo "This script must be run as root" && exit 1
command -v genfstab >/dev/null 2>&1 || { echo >&2 "genfstab command not found, exiting."; exit 2; }

chroot_rootfs() {
	mount --bind /etc/resolv.conf $rootfs/etc/resolv.conf
	mount -t proc none $rootfs/proc
	mount -t sysfs none $rootfs/sys
	mount -t devtmpfs none $rootfs/dev
	chroot $rootfs bash -c "$*"
	umount $rootfs/dev $rootfs/sys $rootfs/proc $rootfs/etc/resolv.conf
}

prepare_boardconfig() {
	local configpath=$shellpath/boards/$1
	local inheritpath=$configpath/inherit
	if [ -f $inheritpath ]; then
		prepare_boardconfig $(cat $inheritpath)
	fi

	boardpath=$tmp/config
	mkdir -p $boardpath
	cp -rf $configpath/* $boardpath
}

prepare_partitions() {
	local partitions=(
		"rootfs,/rootfs,16G,mkfs.ext4"
		"boot,/rootfs/boot,500M,mkfs.ext4"
		"efi,/rootfs/boot/efi,100M,mkfs.vfat"
	)
	for partition in "${partitions[@]}"; do
		IFS="," read -r name mountpoint size cmd <<< $partition
		mountpoint=$tmp$mountpoint
		eval "$name=$mountpoint"

		fallocate -l $size $name.img && $cmd $name.img
		mkdir -p $mountpoint && mount $name.img $mountpoint
	done
}

prepare_rootfs() {
	local packages=$1
	dnf5 --forcearch=$arch \
	     --disablerepo "*" --repofrompath=base,"$repourl" \
	     --installroot=$rootfs \
	     install -y $packages
}

prepare_repos() {
	rm -f $rootfs/etc/yum.repos.d/*.repo
	chroot_rootfs "dnf config-manager addrepo \
		--id='fedora-riscv' \
		--set=name='Fedora RISC-V' \
		--set=baseurl=$repourl"

	local repospath=$boardpath/repos
	if [ ! -d $repospath ]; then
		return
	fi

	cp -v $repospath/*.repo $rootfs/etc/yum.repos.d
}

install_pkgs() {
	local pkgspath=$boardpath/packages
	if [ ! -f $pkgspath ]; then
		return
	fi

	local pkgs=""
	while read -r line; do
		if [[ "$line" =~ ^# ]]; then
			continue
		fi
		if [ -z "$line" ]; then
			continue
		fi
		pkgs+="$line "
	done < $pkgspath
	chroot_rootfs dnf install -y $pkgs
}

download_sources() {
	local sourcespath=$boardpath/sources
	if [ ! -f $sourcespath ]; then
		return
	fi

	while read -r line; do
		filename=$(basename $line)
		wget -O $filename $line
		if [[ "$filename" =~ \.tar(\.xz|\.gz)?$ ]]; then
			tar xf $filename -C $rootfs --no-same-owner
			rm -rf $filename
		fi
        done < $sourcespath
}

overlay_rootfs() {
	local overlaypath=$boardpath/overlay
	if [ ! -d $overlaypath ]; then
		return
	fi

	cp -rfv $overlaypath/* $rootfs
}

install_bootloader() {
	# pre
	local prepath=$boardpath/pre
	if [ -d $prepath ]; then
		for script in $prepath/*; do
			source $script
		done
	fi

	# theme
	wget -O theme.tar.gz http://openkoji.iscas.ac.cn/pub/dist-repos/dl/grubtheme.tar.gz
	tar xf theme.tar.gz -C $rootfs --no-same-owner
	rm -rf theme.tar.gz

	# config
	echo 'GRUB_CMDLINE_LINUX="rootwait clk_ignore_unused splash plymouth.ignore-serial-consoles selinux=0"' >> $rootfs/etc/default/grub
	echo 'GRUB_THEME=/boot/grub2/themes/fedoravforce/theme.txt' >> $rootfs/etc/default/grub
	echo 'GRUB_TIMEOUT=3' >> $rootfs/etc/default/grub

	# install
	rm -rf $rootfs/etc/grub.d/30_os-prober
	chroot_rootfs kernel-install add-all
	chroot_rootfs grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg
}

finalize() {
	# fstab
	genfstab -U $rootfs > $rootfs/etc/fstab
	perl -i -pe 's/iocharset=.+?,//' $rootfs/etc/fstab
	perl -i -ne 'print unless /zram/' $rootfs/etc/fstab

	# gnome-initial
	mkdir -p $rootfs/etc/gnome-initial-setup
	touch $rootfs/etc/gnome-initial-setup/vendor.conf

	# issue
	cat << EOF | tee $rootfs/etc/issue $rootfs/etc/issue.net
Welcome to the Fedora RISC-V disk image
https://openkoji.iscas.ac.cn/koji/

Build date: $(date --utc)

Kernel \r on an \m (\l)

The root password is 'riscv'.
root password logins are disabled in SSH starting Fedora.

If DNS isn’t working, try editing ‘/etc/yum.repos.d/fedora-riscv.repo’.

For updates and latest information read:
https://fedoraproject.org/wiki/Architectures/RISC-V

Fedora RISC-V
-------------
EOF

	# others
	chroot_rootfs "echo 'root:riscv' | chpasswd"
	chroot_rootfs dnf clean all

	# post
	local postpath=$boardpath/post
	if [ -d $postpath ]; then
		for script in $postpath/*; do
			source $script
		done
	fi
}

generate_image() {
	./genimage-bin --inputpath $tmp --outputpath $PWD --rootpath $tmp --config $boardpath/genimage.cfg
}

shellpath=$PWD
arch="riscv64"
repourl="http://openkoji.iscas.ac.cn/kojifiles/repos/f41-build-side-1/latest/riscv64"
board=
while getopts "b:" opt; do
	case $opt in
	b)
		board=$OPTARG
		;;
	esac
done
shift $((OPTIND - 1))

tmp=$(mktemp -d -p $PWD)
pushd $tmp
prepare_boardconfig $board
prepare_partitions
prepare_rootfs "@workstation-product @gnome-desktop @hardware-support grub2-efi-riscv64"
prepare_repos
install_pkgs
download_sources
overlay_rootfs
install_bootloader
finalize
popd

grep $tmp /proc/mounts | cut -d" " -f2 | sort -r | xargs umount
generate_image
