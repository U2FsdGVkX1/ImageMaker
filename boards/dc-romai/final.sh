cat << EOF > $rootfs/usr/share/X11/xorg.conf.d/10-starfive.conf
Section "OutputClass"
Identifier "Starfive Display"
MatchDriver "starfive"
Driver "modesetting"
Option "PrimaryGPU" "true"
#Option "AccelMethod" "no"
Option "SWcursor" "false"
Option "NoCursor" "true"
Option "ShadowFB" "true"
Option "Atomic" "true"
Option "DoubleShadow" "true"
Option "PageFlip" "true"
Option "VariableRefresh" "true"
Option "AsyncFlipSecondaries" "true"
EndSection
#Section "Extensions"
#Option "glx" "Disable"
#Option "Composite" "Disable"
#EndSection
EOF

cat << EOF > $rootfs/etc/environment
COGL_DRIVER=gles2
GST_GL_API=gles2
CLUTTER_PAINT="disable-clipped-redraws"
XWAYLAND_NO_GLAMOR=1
SDL_VIDEODRIVER=wayland
MESA_LOADER_DRIVER_OVERRIDE=pvr
EOF

cat << EOF > $rootfs/etc/udev/rules.d/61-mutter-primary-gpu.rules
ENV{DEVNAME}=="/dev/dri/card1", TAG+="mutter-device-preferred-primary"
EOF

cat << EOF > $rootfs/etc/udev/rules.d/91-soft_3rdpart.rules
KERNEL=="jpu", OWNER="root", GROUP="video", MODE="0660"
KERNEL=="vdec", OWNER="root", GROUP="video", MODE="0660"
KERNEL=="venc", OWNER="root", GROUP="video", MODE="0660"
EOF

cat << EOF > $rootfs/etc/dracut.conf.d/pvr.conf
install_items+=" /lib/firmware/rgx.fw.36.50.54.182 /lib/firmware/rgx.sh.36.50.54.182 "
EOF

cat << EOF >> $rootfs/etc/gdm/custom.conf
WaylandEnable=true
EOF

chroot_rootfs bash -c "ls /usr/lib/modules | xargs -L1 depmod"
