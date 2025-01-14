#!/bin/bash

set -Eex

[ "$(id -u)" -ne 0 ] && echo "This script must be run as root." && exit 1
[ "$(getenforce)" == "Enforcing" ] && echo "SELinux is enabled, The script will not run." && exit 2
[ ! -f genimage-bin ] && echo "genimage-bin file not found, Please obtain it by getgenimage.sh." && exit 3

save_context() {
	if [ -n "$resume" ]; then
		return
	fi
	resume="y"

	local len=${#FUNCNAME[@]}
	local except=${FUNCNAME[$((len - 2))]}
	grep $tmp /proc/mounts | cut -d" " -f2 | sort -r | xargs umount
	popd

	sed -e "/^tmp=/c tmp=$tmp" $shellpath/build.sh > $shellpath/resume
	local startline=$(grep -En "^prepare_partitions$" $shellpath/resume | awk -F: '{print $1}')
	local endline=$(grep -En "^$except($| )" $shellpath/resume | awk -F: '{print $1}')
	if (( startline + 1 < endline )); then
		sed -i "$((startline + 1)),$((endline - 1))d" $shellpath/resume
	fi
}

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

	if [ ! -d $boardpath ]; then
		mkdir -p $boardpath
		local templatepath=$shellpath/templates/$arch
		if [ -d $templatepath ]; then
			cp -rfv $templatepath/* $boardpath
		fi
	fi

	cp -rfv $configpath/* $boardpath
	if [ -n "$tag" ]; then
		local tagpath=$configpath/tags/$tag
		if [ -d $tagpath]; then
			cp -rfv $tagpath/* $boardpath
		fi
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

		if [ ! -f $name.img ]; then
			fallocate -l $size $name.img && $cmd $name.img
		fi
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

finalize() {
	# pre
	local prepath=$boardpath/pre
	if [ -d $prepath ]; then
		for script in $prepath/*; do
			source $script
		done
	fi

	# fstab
	while read -r uuid mountpoint fstype _; do
		newmountpoint="${mountpoint#$rootfs}"
		if [ "$mountpoint" == "$newmountpoint" ]; then
			continue
		fi
		if [ -z "$newmountpoint" ]; then
			newmountpoint="/"
		fi
		echo -e "UUID=${uuid}\t${newmountpoint}\t${fstype}\tdefaults\t0 0" >> $rootfs/etc/fstab
	done < <(lsblk -n -o UUID,MOUNTPOINT,FSTYPE)

	# clean
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

shellpath=$(dirname $(realpath $0))
arch="riscv64"
repourl="http://openkoji.iscas.ac.cn/kojifiles/repos/f41-build/latest/riscv64"
loader=grub2
desktop=gnome
tag=
board=
while getopts "l:d:t:b:r" opt; do
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
	r)
		if [ $(basename $0) != "resume" ]; then
			exec bash $shellpath/resume $@
		else
			rm -rf $shellpath/resume
		fi
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

tmp=$(mktemp -d -p $shellpath)
boardpath=$tmp/config
trap 'save_context' ERR SIGINT

pushd $tmp
prepare_boardconfig $board
prepare_partitions
prepare_rootfs "$rootfspkgs"
prepare_repos
install_pkgs
download_sources
overlay_rootfs
finalize
generate_image
popd
