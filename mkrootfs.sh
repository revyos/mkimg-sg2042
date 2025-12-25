#!/usr/bin/env bash

set -euo pipefail

MODEL=${MODEL:-pioneer} # pioneer, pisces, sg2044
DEVICE=/dev/loop101
CHROOT_TARGET=rootfs
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ROOT_IMG=revyos-${MODEL}-${TIMESTAMP}.img

# == kernel variables ==
KERNEL_pioneer="linux-headers-6.18-revyos linux-image-6.18-revyos"
KERNEL_sg2044="linux-headers-6.18-revyos linux-image-6.18-revyos"
KERNEL_pisces="linux-headers-6.6-pisces linux-image-6.6-pisces"
KERNEL=$(eval echo '$'"KERNEL_${MODEL}")

if [ "$MODEL" = "pioneer" ]; then
  echo "Model is pioneer."
elif [ "$MODEL" = "pisces" ]; then
  echo "Model is pisces."
elif [ "$MODEL" = "sg2044" ]; then
  echo "Model is sg2044."
else
  echo "Model ???? ${MODEL}"
  exit 1
fi

# == packages ==
BASE_TOOLS="binutils file tree sudo bash-completion network-manager dnsmasq-base libpam-systemd ppp wireless-regdb wpasupplicant libengine-pkcs11-openssl iptables usbutils libgles2 parted"
#XFCE_DESKTOP="xorg xfce4 desktop-base lightdm xfce4-terminal tango-icon-theme xfce4-notifyd xfce4-power-manager network-manager-gnome xfce4-goodies pulseaudio alsa-utils dbus-user-session rtkit pavucontrol thunar-volman eject gvfs gvfs-backends udisks2 dosfstools e2fsprogs e2fsprogs libblockdev-crypto3 ntfs-3g polkitd exfat-fuse "
#GNOME_DESKTOP="gnome-core avahi-daemon desktop-base file-roller gnome-tweaks gstreamer1.0-libav gstreamer1.0-plugins-ugly libgsf-bin libproxy1-plugin-networkmanager network-manager-gnome"
KDE_DESKTOP="task-kde-desktop task-ssh-server task-english"
BENCHMARK_TOOLS="glmark2 mesa-utils vulkan-tools iperf3 stress-ng"
#FONTS="fonts-crosextra-caladea fonts-crosextra-carlito fonts-dejavu fonts-liberation fonts-liberation2 fonts-linuxlibertine fonts-noto-core fonts-noto-cjk fonts-noto-extra fonts-noto-mono fonts-noto-ui-core fonts-sil-gentium-basic"
FONTS="fonts-noto-core fonts-noto-cjk fonts-noto-mono fonts-noto-ui-core"
INCLUDE_APPS="firefox vlc gimp chromium"
EXTRA_TOOLS="i2c-tools net-tools ethtool wget python3-ruyi cloud-init cloud-guest-utils u-boot-menu initramfs-tools"
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
ADDONS="systemd-timesyncd vim firmware-amd-graphics firmware-nvidia-graphics firmware-intel-graphics firmware-intel-misc firmware-realtek"

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
    fallocate -l 12G $ROOT_IMG
}

install_deps() {
    apt install -y gdisk dosfstools g++-riscv64-linux-gnu build-essential \
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
    parted -s -a optimal -- "${DEVICE}" mkpart primary fat32 0% 512MiB
    parted -s -a optimal -- "${DEVICE}" mkpart primary ext4 512MiB 2048MiB
    parted -s -a optimal -- "${DEVICE}" mkpart primary ext4 2048MiB 100%

    partprobe "${DEVICE}"

    sleep 5

    mkfs.vfat "${DEVICE}p1" -n EFI
    mkfs.ext4 -F -L revyos-boot "${DEVICE}p2"
    mkfs.ext4 -F -L revyos-root "${DEVICE}p3"

    sleep 5

    mount "${DEVICE}p3" "$CHROOT_TARGET"
    mkdir -p "$CHROOT_TARGET"/boot
    mount "${DEVICE}p2" "$CHROOT_TARGET"/boot
    mkdir -p "$CHROOT_TARGET"/boot/efi
    mount "${DEVICE}p1" "$CHROOT_TARGET"/boot/efi
}

make_rootfs() {
    mmdebstrap --architectures=riscv64 \
    --skip=check/empty \
    --include="ca-certificates debian-archive-keyring revyos-keyring locales locales-all dosfstools" \
    trixie "$CHROOT_TARGET" \
    "deb https://mirror.iscas.ac.cn/revyos/revyos-kernels/ revyos-kernels main" \
    "deb https://mirror.iscas.ac.cn/revyos/trixie/revyos-addons/ trixie main" \
    "deb https://mirror.iscas.ac.cn/revyos/trixie/revyos-base/ trixie main contrib non-free non-free-firmware"
}

after_mkrootfs() {
    # Set up fstab
    cat > "$CHROOT_TARGET"/etc/fstab << EOF
LABEL=revyos-root   /		    ext4	defaults,noatime,x-systemd.device-timeout=300s,x-systemd.mount-timeout=300s 0 0
LABEL=revyos-boot   /boot		ext4	defaults,noatime,x-systemd.device-timeout=300s,x-systemd.mount-timeout=300s 0 0
LABEL=EFI           /boot/efi	vfat    defaults,noatime,x-systemd.device-timeout=300s,x-systemd.mount-timeout=300s 0 0
EOF

    # Add timestamp file in /etc
    if [ ! -f revyos-release ]; then
        echo "$TIMESTAMP" > rootfs/etc/revyos-release
    else
        cp -v revyos-release rootfs/etc/revyos-release
    fi

    # clean up source.list
    cat > $CHROOT_TARGET/etc/apt/sources.list << EOF
deb https://mirror.iscas.ac.cn/revyos/revyos-kernels/ revyos-kernels main
deb https://mirror.iscas.ac.cn/revyos/trixie/revyos-addons/ trixie main
deb https://mirror.iscas.ac.cn/revyos/trixie/revyos-base/ trixie main contrib non-free non-free-firmware
EOF

    sudo chroot $CHROOT_TARGET /bin/bash << EOF
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y $KDE_DESKTOP $FONTS $EXTRA_TOOLS $ADDONS $BENCHMARK_TOOLS $INCLUDE_APPS
#"$BASE_TOOLS $KDE_DESKTOP $BENCHMARK_TOOLS $FONTS $INCLUDE_APPS $EXTRA_TOOLS $ADDONS"
EOF
    # Add update-u-boot config
if [ "$MODEL" = "pioneer" ]; then
    cat > $CHROOT_TARGET/etc/default/u-boot << EOF
U_BOOT_PROMPT="2"
U_BOOT_MENU_LABEL="RevyOS GNU/Linux"
U_BOOT_PARAMETERS="console=ttyS0,115200 earlycon nvme_core.io_timeout=240 pcie_ports=compat pcie_aspm=off"
U_BOOT_ROOT="root=LABEL=revyos-root"
EOF
elif [ "$MODEL" = "pisces" ]; then
    cat > $CHROOT_TARGET/etc/default/u-boot << EOF
U_BOOT_PROMPT="2"
U_BOOT_MENU_LABEL="RevyOS GNU/Linux"
U_BOOT_PARAMETERS="console=ttyS0,115200 earlycon nvme_core.io_timeout=240 pcie_ports=compat pcie_aspm=off"
U_BOOT_ROOT="root=LABEL=revyos-root"
EOF
elif [ "$MODEL" = "sg2044" ]; then
U_BOOT_PROMPT="2"
U_BOOT_MENU_LABEL="RevyOS GNU/Linux"
U_BOOT_PARAMETERS="console=ttyS1,115200 earlycon no5lvl pcie_aspm=off"
U_BOOT_ROOT="root=LABEL=revyos-root"
fi

    # Install kernel
    sudo chroot $CHROOT_TARGET /bin/bash << EOF
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y $KERNEL
u-boot-update
EOF

    cp -rp addons/etc/cloud/cloud.cfg.d/00_nocloud.cfg "$CHROOT_TARGET"/etc/cloud/cloud.cfg.d/00_nocloud.cfg
    cp -rp addons/etc/cloud/revyos-data "$CHROOT_TARGET"/etc/cloud/
    sed -i "s/hostname: .*$/hostname: revyos-${MODEL}/g" "$CHROOT_TARGET"/etc/cloud/revyos-data/user-data

    umount -l "$CHROOT_TARGET"
}


machine_info
init
#install_deps
#qemu_setup
img_setup
make_rootfs
after_mkrootfs

losetup -d "${DEVICE}"
