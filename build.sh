#!/bin/bash

set -ex

[ "$(id -u)" -ne 0 ] && echo "This script must be run as root" && exit 1

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

	pushd $tmp
	while read -r line; do
		filename=$(basename $line)
		wget -O $filename $line
		if [[ "$filename" =~ \.tar(\.xz|\.gz)?$ ]]; then
			tar xf $filename -C $rootfs
			rm -rf $filename
		fi
        done < $sourcespath
	popd
}

finalize() {
	local postshpath=$boardpath/post.sh
	if [ -f $postshpath ]; then
		source $postshpath
	fi
	chroot_rootfs dracut -f --regenerate-all
	chroot_rootfs dnf clean all
}

generate_image() {
	./genimage --inputpath $tmp --rootpath $tmp --config $boardpath/genimage.cfg
	local imagepath=$PWD/images/sdcard.img
}

arch="riscv64"
repourl="http://openkoji.iscas.ac.cn/kojifiles/repos/f41-build-side-1/latest/riscv64"
tmp=$(mktemp -d)
rootfs="$tmp/rootfs"
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

mkdir -p $tmp/boot && mkdir -p $rootfs/boot
mount --bind $tmp/boot $rootfs/boot
prepare_rootfs "@core glibc-all-langpacks"
prepare_repos
install_pkgs
download_sources
finalize

umount $rootfs/boot
generate_image
rm -rf $tmp
