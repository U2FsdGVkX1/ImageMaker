#!/bin/bash

set -ex

[ "$(id -u)" -ne 0 ] && echo "This script must be run as root" && exit 1
command -v genfstab >/dev/null 2>&1 || { echo >&2 "genfstab command not found, exiting."; exit 2; }

chroot_rootfs() {
	mount --bind /etc/resolv.conf $rootfs/etc/resolv.conf
	mount -t proc none $rootfs/proc
	mount -t sysfs none $rootfs/sys
	mount -t devtmpfs none $rootfs/dev
	chroot $rootfs "$@"
	umount $rootfs/dev $rootfs/sys $rootfs/proc $rootfs/etc/resolv.conf
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
	chroot_rootfs dnf config-manager addrepo \
		--id="fedora-riscv" \
		--set=name="Fedora RISC-V" \
		--set=baseurl="$repourl"

	local repospath=$boardpath/repos
	if [ ! -d $repospath ]; then
		return
	fi

	cp $repospath/*.repo $rootfs/etc/yum.repos.d
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
			tar xf $filename -C $rootfs
			rm -rf $filename
		fi
        done < $sourcespath
}

finalize() {
	local postshpath=$boardpath/post
	if [ -f $postshpath ]; then
		source $postshpath
	fi
	genfstab -U $rootfs > $rootfs/etc/fstab
	chroot_rootfs dracut -f --regenerate-all
	chroot_rootfs dnf clean all
}

generate_image() {
	./genimage-bin --inputpath $tmp --rootpath $tmp --config $boardpath/genimage.cfg
}

arch="riscv64"
repourl="http://openkoji.iscas.ac.cn/kojifiles/repos/f41-build-side-1/latest/riscv64"
board=
boardpath=
while getopts "b:" opt; do
	case $opt in
	b)
		board=$OPTARG
		boardpath=$PWD/boards/$board
		;;
	esac
done
shift $((OPTIND - 1))

# tmp=$(mktemp -d -p $PWD)
tmp=$PWD/test
partitions=(
	"rootfs,/rootfs,16G,mkfs.ext4"
	"boot,/rootfs/boot,500M,mkfs.ext4"
	"efi,/rootfs/boot/efi,100M,mkfs.vfat"
)
pushd $tmp
for partition in "${partitions[@]}"; do
	IFS="," read -r name mountpoint size cmd <<< $partition
	mountpoint=$tmp$mountpoint
	eval "$name=$mountpoint"

	fallocate -l $size $name.img && $cmd $name.img
	mkdir -p $mountpoint && mount $name.img $mountpoint
done
# prepare_rootfs "@core @gnome-desktop glibc-all-langpacks"
prepare_rootfs "@core glibc-all-langpacks"
prepare_repos
install_pkgs
download_sources
finalize
popd

grep $tmp /proc/mounts | cut -d' ' -f2 | sort -r | xargs umount
generate_image
