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
	if [ -n "$2" ]; then
		configpath=$configpath/tags/$2
	fi

	local inheritpath=$configpath/inherit
	if [ -f $inheritpath ]; then
		read -r board tag < $inheritpath
		prepare_boardconfig $board $tag
	fi

	if [ ! -d $boardpath ]; then
		mkdir -p $boardpath
		local templatepath=$shellpath/templates/$arch
		if [ -d $templatepath ]; then
			cp -rfvL $templatepath/* $boardpath
		fi
	fi
	cp -rfvL $configpath/* $boardpath
}

prepare_partitions() {
	local -a partitions
	mapfile -t partitions < $boardpath/partitions
	for partition in "${partitions[@]}"; do
		IFS="," read -r name mountpoint size cmd <<< $partition
		mountpoint=$(realpath $tmp/rootfs/$mountpoint)
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
	while read -r uuid mountpoint fstype; do
		mountpoint="${mountpoint#$rootfs}"
		if [ -z "$mountpoint" ]; then
			mountpoint="/"
		fi
		echo -e "UUID=${uuid}\t${mountpoint}\t${fstype}\tdefaults\t0 0" >> $rootfs/etc/fstab
	done < <(findmnt -Rln -o UUID,TARGET,FSTYPE $rootfs)

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
repourl=
loader=grub2
desktop=Minimal
tag=
board=
while getopts "a:r:l:d:t:b:R" opt; do
	case $opt in
	a)
		arch=$OPTARG
		;;
	r)
		repourl=$OPTARG
		;;
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
	R)
		if [ $(basename $0) != "resume" ]; then
			exec bash $shellpath/resume $@
		else
			rm -rf $shellpath/resume
		fi
		;;
	esac
done
shift $((OPTIND - 1))

rootfspkgs="@core @hardware-support glibc-all-langpacks"
if [ "$desktop" = "Minimal" ]; then
	rootfspkgs+=""
elif [ "$desktop" = "GNOME" ]; then
	rootfspkgs+=" fedora-release-workstation"
	rootfspkgs+=" @workstation-product @gnome-desktop"
elif [ "$desktop" = "Xfce" ]; then
	rootfspkgs+=" fedora-release-xfce"
	rootfspkgs+=" @xfce-desktop @xfce-apps"
	rootfspkgs+=" -x NetworkManager-l2tp-gnome"
fi

tmp=$(mktemp -d -p $shellpath)
boardpath=$tmp/config
trap 'save_context' ERR SIGINT

pushd $tmp
prepare_boardconfig $board $tag
prepare_partitions
prepare_rootfs "$rootfspkgs"
prepare_repos
install_pkgs
download_sources
overlay_rootfs
finalize
generate_image
popd
