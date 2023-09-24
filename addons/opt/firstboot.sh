#!/bin/bash

# use all nvme free space for rootfs
dev=$(mount | grep " / " | cut -d " " -f 1 | cut -d 'p' -f 1)
dev_num=$(mount | grep " / " | cut -d " " -f 1 | cut -d 'p' -f 2)

parted ${dev} ---pretend-input-tty <<EOF
resizepart
${dev_num}
Yes
100%
quit
EOF
# resize root filesystem
resize2fs /dev/disk/by-label/revyos-root

# regenerate openssh host keys
dpkg-reconfigure openssh-server
systemctl restart ssh
