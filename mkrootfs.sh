#!/usr/bin/env bash

set -euo pipefail

DEVICE=/dev/loop100
CHROOT_TARGET=rootfs
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ROOT_IMG=revyos-sg2042-${TIMESTAMP}.img

machine_info() {
    uname -a
    echo $(nproc)
    lscpu
    whoami
    env
    fdisk -l
    df -h
}

init() {
    # Init out folder & rootfs
    mkdir -p rootfs

    apt update

    # create flash image
    fallocate -l 7G $ROOT_IMG
}

install_deps() {
    apt install -y gdisk dosfstools g++-12-riscv64-linux-gnu build-essential \
        libncurses-dev gawk flex bison openssl libssl-dev \
        dkms libelf-dev libudev-dev libpci-dev libiberty-dev autoconf mkbootimg \
        fakeroot genext2fs genisoimage libconfuse-dev mtd-utils mtools qemu-utils squashfs-tools \
        device-tree-compiler rauc u-boot-tools f2fs-tools swig mmdebstrap parted
}

qemu_setup() {
    apt install -y binfmt-support qemu-user-static curl wget
    update-binfmts --display
}

img_setup() {
    losetup -P "${DEVICE}" $ROOT_IMG
    parted -s -a optimal -- "${DEVICE}" mktable msdos
    parted -s -a optimal -- "${DEVICE}" mkpart primary fat32 0% 256MiB
    parted -s -a optimal -- "${DEVICE}" mkpart primary ext4 256MiB 1280MiB
    parted -s -a optimal -- "${DEVICE}" mkpart primary ext4 1280MiB 100%

    partprobe "${DEVICE}"

    mkfs.vfat "${DEVICE}p1" -n EFI
	mkfs.ext4 -F -L revyos-boot "${DEVICE}p2"
	mkfs.ext4 -F -L revyos-root "${DEVICE}p3"

    mount "${DEVICE}p3" rootfs
    mkdir -p rootfs/boot
    mount "${DEVICE}p2" rootfs/boot
    mkdir -p rootfs/boot/efi
    mount "${DEVICE}p1" rootfs/boot/efi
}


machine_info
init
install_deps
qemu_setup
img_setup

KERNEL="linux-headers-6.1.52-sg2042 linux-image-6.1.52-sg2042 linux-perf-sg2042"
BASE_TOOLS="binutils file tree sudo bash-completion u-boot-menu initramfs-tools openssh-server network-manager dnsmasq-base libpam-systemd ppp wireless-regdb wpasupplicant libengine-pkcs11-openssl iptables systemd-timesyncd vim usbutils libgles2 parted"
XFCE_DESKTOP="xorg xfce4 desktop-base lightdm xfce4-terminal tango-icon-theme xfce4-notifyd xfce4-power-manager network-manager-gnome xfce4-goodies pulseaudio alsa-utils dbus-user-session rtkit pavucontrol thunar-volman eject gvfs gvfs-backends udisks2 dosfstools e2fsprogs e2fsprogs libblockdev-crypto2 ntfs-3g polkitd exfat-fuse "
GNOME_DESKTOP="gnome-core avahi-daemon desktop-base file-roller gnome-tweaks gstreamer1.0-libav gstreamer1.0-plugins-ugly libgsf-bin libproxy1-plugin-networkmanager network-manager-gnome"
KDE_DESKTOP="kde-plasma-desktop"
BENCHMARK_TOOLS="glmark2 mesa-utils vulkan-tools iperf3 stress-ng"
#FONTS="fonts-crosextra-caladea fonts-crosextra-carlito fonts-dejavu fonts-liberation fonts-liberation2 fonts-linuxlibertine fonts-noto-core fonts-noto-cjk fonts-noto-extra fonts-noto-mono fonts-noto-ui-core fonts-sil-gentium-basic"
FONTS="fonts-noto-core fonts-noto-cjk fonts-noto-mono fonts-noto-ui-core"
INCLUDE_APPS="firefox vlc gimp gimp-data-extras gimp-plugin-registry gimp-gmic"
EXTRA_TOOLS="i2c-tools net-tools ethtool"
LIBREOFFICE="libreoffice-base \
libreoffice-calc \
libreoffice-core \
libreoffice-draw \
libreoffice-impress \
libreoffice-math \
libreoffice-report-builder-bin \
libreoffice-writer \
libreoffice-nlpsolver \
libreoffice-report-builder \
libreoffice-script-provider-bsh \
libreoffice-script-provider-js \
libreoffice-script-provider-python \
libreoffice-sdbc-mysql \
libreoffice-sdbc-postgresql \
libreoffice-wiki-publisher \
"
DOCKER="docker.io apparmor ca-certificates cgroupfs-mount git needrestart xz-utils"
ADDONS="initramfs-tools firmware-amd-graphics"

make_rootfs() {
    mmdebstrap --architectures=riscv64 \
    --skip=check/empty \
    --include="ca-certificates debian-ports-archive-keyring revyos-keyring locales dosfstools \
        $BASE_TOOLS $XFCE_DESKTOP $BENCHMARK_TOOLS $FONTS $INCLUDE_APPS $EXTRA_TOOLS $LIBREOFFICE $ADDONS" \
    sid "$CHROOT_TARGET" \
    "deb [trusted=yes] https://mirror.iscas.ac.cn/revyos/revyos-base/ sid main contrib non-free non-free-firmware" \
    "deb [trusted=yes] https://mirror.iscas.ac.cn/revyos/revyos-addons/ revyos-addons main" \
    "deb [trusted=yes] https://mirror.iscas.ac.cn/revyos/revyos-kernels/ revyos-kernels main"
}

after_mkrootfs() {
    # Set up fstab
    cat > "$CHROOT_TARGET"/etc/fstab << EOF
LABEL=revyos-root   /		    ext4	defaults,noatime,x-systemd.device-timeout=300s,x-systemd.mount-timeout=300s 0 0
LABEL=revyos-boot   /boot		ext4	defaults,noatime,x-systemd.device-timeout=300s,x-systemd.mount-timeout=300s 0 0
LABEL=EFI           /boot/efi	vfat    defaults,noatime,x-systemd.device-timeout=300s,x-systemd.mount-timeout=300s 0 0
EOF
    
    sudo chroot $CHROOT_TARGET /bin/bash << EOF
# apt update
apt update

# Add user
useradd -m -s /bin/bash -G adm,sudo debian
echo 'debian:debian' | chpasswd

# Change hostname
echo revyos-sg2042 > /etc/hostname
echo 127.0.1.1 revyos-sg2042 >> /etc/hosts

exit
EOF

    # Add timestamp file in /etc
    echo "$TIMESTAMP" > rootfs/etc/revyos-release

    # clean up source.list
    cat > $CHROOT_TARGET/etc/apt/sources.list << EOF
deb https://mirror.iscas.ac.cn/revyos/revyos-base/ sid main contrib non-free non-free-firmware
deb https://mirror.iscas.ac.cn/revyos/revyos-addons/ revyos-addons main
deb https://mirror.iscas.ac.cn/revyos/revyos-kernels/ revyos-kernels main
EOF
    
    # remove openssh keys
    rm -v $CHROOT_TARGET/etc/ssh/ssh_host_*
    
    cp -rvp addons/etc/systemd/system/firstboot.service $CHROOT_TARGET/etc/systemd/system/
    cp -rvp addons/opt/firstboot.sh $CHROOT_TARGET/opt/
    chroot "$CHROOT_TARGET" sh -c "systemctl enable firstboot"

    # Add update-u-boot config
    cat > $CHROOT_TARGET/etc/default/u-boot << EOF
U_BOOT_PROMPT="2"
U_BOOT_MENU_LABEL="RevyOS GNU/Linux"
U_BOOT_PARAMETERS="console=ttyS0,115200 root=LABEL=revyos-root rootfstype=ext4 rootwait rw earlycon selinux=0 LANG=en_US.UTF-8"
U_BOOT_ROOT="root=LABEL=revyos-root"
EOF

    # Install kernel
    sudo chroot $CHROOT_TARGET /bin/bash << EOF
apt install -y $KERNEL
u-boot-update
EOF

    # clean source
    rm -vrf $CHROOT_TARGET/var/lib/apt/lists/*

    # cp bootloader
    cp -vr bootloader/* $CHROOT_TARGET/boot/efi/

    umount -l "$CHROOT_TARGET"
}

make_rootfs
after_mkrootfs

losetup -d "${DEVICE}"
