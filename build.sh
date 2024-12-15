#!/bin/bash

set -ex

[ "$(id -u)" -ne 0 ] && echo "This script must be run as root." && exit 1
[ "$(getenforce)" == "Enforcing" ] && echo "SELinux is enabled, The script will not run." && exit 2
[ ! -f genimage-bin ] && echo "genimage-bin file not found, please obtain it by getgenimage.sh." && exit 3
command -v genfstab >/dev/null 2>&1 || { echo >&2 "genfstab command not found, exiting."; exit 4; }

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
		prepare_boardconfig $(cat $inheritpath) $tag
	fi

	boardpath=$tmp/config
	mkdir -p $boardpath
	cp -rfv $configpath/* $boardpath

	local tagpath=$configpath/tags/$tag
	if [ -n "$tag" ] && [ -d $tagpath ]; then
		find $tagpath -mindepth 1 -maxdepth 1 -printf "%f\n" | while read -r name; do
			rm -rfv $boardpath/$name
		done
		cp -rfv $tagpath/* $boardpath
	fi
}

prepare_partitions() {
	local partitions=(
		"rootfs,/rootfs,15G,mkfs.ext4"
		"boot,/rootfs/boot,1G,mkfs.ext4"
		"efi,/rootfs/boot/efi,500M,mkfs.fat -F 32"
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
	local pkgs=$1
	dnf5 --forcearch=$arch \
	     --disablerepo "*" --repofrompath=base,"$repourl" \
	     --installroot=$rootfs \
	     install -y $pkgs
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

	echo 'BOOT_ROOT=/boot' >> $rootfs/etc/kernel/install.conf
	echo 'layout=bls' >> $rootfs/etc/kernel/install.conf
	if [ $loader = 'grub2' ]; then
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
		chroot_rootfs grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg
	else
		# config
		mkdir -p $rootfs/boot/loader/entries

		# install
		chroot_rootfs SYSTEMD_RELAX_ESP_CHECKS=1 bootctl install --esp-path=/boot/efi || true
	fi
	chroot_rootfs kernel-install add-all
	chroot_rootfs dracut -f --regenerate-all --no-hostonly
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
	grep $tmp /proc/mounts | cut -d" " -f2 | sort -r | xargs umount
	$shellpath/genimage-bin --inputpath $tmp --outputpath $shellpath --rootpath $tmp --config $boardpath/genimage.cfg
}

shellpath=$PWD
arch="riscv64"
repourl="http://openkoji.iscas.ac.cn/kojifiles/repos/f41-build-side-1/latest/riscv64"
loader=grub2
desktop=gnome
tag=
board=
while getopts "l:d:t:b:" opt; do
	case $opt in
	l)
		loader=$OPTARG
		;;
	d)
		desktop=$OPTARG
		;;
	t)
		tag=$OPTARG
		;;
	b)
		board=$OPTARG
		;;
	esac
done
shift $((OPTIND - 1))

rootfspkgs="@hardware-support"
if [ "$desktop" = "core" ]; then
	rootfspkgs+=" @core glibc-all-langpacks"
elif [ "$desktop" = "gnome" ]; then
	rootfspkgs+=" @workstation-product @gnome-desktop"
fi
if [ "$loader" = "grub2" ]; then
	rootfspkgs+=" grub2-efi-riscv64"
elif [ "$loader" = "systemd" ]; then
	rootfspkgs+=" systemd-boot-unsigned sdubby"
fi

tmp=$(mktemp -d -p $PWD)
pushd $tmp
prepare_boardconfig $board
prepare_partitions
prepare_rootfs "$rootfspkgs"
prepare_repos
install_pkgs
download_sources
overlay_rootfs
install_bootloader
finalize
generate_image
popd
