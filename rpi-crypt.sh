#!/bin/bash


# For debug:
# set -ux
set -u


# Checks
if [[ "${#}" -ne 1 ]]; then
    echo "Usage: ${0} <profile.conf>"
    exit 1
fi

if [[ "${1}" == *.conf ]]; then
    PROFILE_PATH="${1}"
else
    PROFILE_PATH="${1}.conf"
fi
if [[ -f "${PROFILE_PATH}" ]]; then
    source "${PROFILE_PATH}"
else
    echo "Profile ${PROFILE_PATH} does not exist"
    exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
    echo 'Must be root' | tee --append "${BUILD_LOG}"
    exit 1
fi

if [[ $(uname -m) != 'aarch64' ]]; then
    echo 'Script only works on ARM64/aarch64 for now' | tee --append "${BUILD_LOG}"
    exit 1
fi

if [[ -f "${TARGET_IMAGE}" ]]; then
    echo "Target ${TARGET_IMAGE} already exist" | tee --append "${BUILD_LOG}"
    exit 1
fi

if [[ -e "/dev/mapper/${LUKS_DEV}" ]]; then
    echo "Target /dev/mapper/${LUKS_DEV} already exist" | tee --append "${BUILD_LOG}"
    exit 1
fi

if [[ "${LUKS_PASSWORD}" == 'changeme' ]] || [[ "${ROOT_PASSWORD}" == 'changeme' ]]; then
    echo 'Change default passwords for LUKS and root user in configuration file'
    exit 1
fi


cleanup() {
    echo 'Unmount image' | tee --append "${BUILD_LOG}"
    # shellcheck disable=SC2129
    umount "${_mnt_dir}/boot/firmware" &>>"${BUILD_LOG}"
    umount "${_mnt_dir}" &>>"${BUILD_LOG}"
    cryptsetup close "${LUKS_DEV}" &>>"${BUILD_LOG}"
    sync; udevadm settle

    losetup --detach "${_loop_dev}" &>>"${BUILD_LOG}"
    sync; udevadm settle
}
trap 'cleanup' ERR INT


_time_start=$(date +'%Y-%m-%d %H:%M:%S')
echo -e "\nBuild started at ${_time_start}" | tee "${BUILD_LOG}"
echo -e '\nBuild options:' | tee --append "${BUILD_LOG}"
echo "TARGET_IMAGE:         ${TARGET_IMAGE}" | tee --append "${BUILD_LOG}"
echo "BUILD_LOG:            ${BUILD_LOG}" | tee --append "${BUILD_LOG}"
echo "DEBOOTSTRAP_SUITE:    ${DEBOOTSTRAP_SUITE}" | tee --append "${BUILD_LOG}"
echo "LUKS_DEV:             ${LUKS_DEV}" | tee --append "${BUILD_LOG}"
echo "LUKS_FORMAT_ARGS:     ${LUKS_FORMAT_ARGS}" | tee --append "${BUILD_LOG}"
echo "DEBOOTSTRAP_PACKAGES: ${DEBOOTSTRAP_PACKAGES}" | tee --append "${BUILD_LOG}"
echo "RPI_PACKAGES:         ${RPI_PACKAGES}" | tee --append "${BUILD_LOG}"
echo ''


echo 'Install dependencies' | tee --append "${BUILD_LOG}"
apt-get install \
    --yes --no-install-recommends --no-install-suggests \
    cryptsetup debootstrap parted systemd-container &>>"${BUILD_LOG}"


echo 'Create image (takes some time)' | tee --append "${BUILD_LOG}"
_mnt_dir=$(mktemp --directory)
echo "_mnt_dir: ${_mnt_dir}" &>>"${BUILD_LOG}"
dd if=/dev/zero of="${TARGET_IMAGE}" bs=1M count=3000 oflag=direct &>>"${BUILD_LOG}"
sync; udevadm settle


echo 'Partition image' | tee --append "${BUILD_LOG}"
# shellcheck disable=SC2129
parted --script --fix --align=opt "${TARGET_IMAGE}" mklabel gpt &>>"${BUILD_LOG}"
parted --script --fix --align=opt "${TARGET_IMAGE}" mkpart primary fat32 8M   512M &>>"${BUILD_LOG}"
parted --script --fix --align=opt "${TARGET_IMAGE}" mkpart primary ext4  512M 100% &>>"${BUILD_LOG}"
sync; udevadm settle


echo 'Configure loopback device' | tee --append "${BUILD_LOG}"
_loop_dev=$(losetup --find --partscan --show "${TARGET_IMAGE}")
sync; udevadm settle


echo 'Format LUKS partition' | tee --append "${BUILD_LOG}"
# shellcheck disable=SC2086
echo "${LUKS_PASSWORD}" | cryptsetup luksFormat --batch-mode ${LUKS_FORMAT_ARGS} "${_loop_dev}p2"
sync; udevadm settle

# Just to make sure
if ! cryptsetup --batch-mode isLuks "${_loop_dev}p2"; then
    echo "Unable to format ${_loop_dev}p2 as LUKS device" | tee --append "${BUILD_LOG}"
    losetup --detach "${_loop_dev}" &>>"${BUILD_LOG}"
    exit 1
fi


echo "${LUKS_PASSWORD}" | cryptsetup open "${_loop_dev}p2" "${LUKS_DEV}"
sync; udevadm settle


mkfs.fat "${_loop_dev}p1" &>>"${BUILD_LOG}"
mkfs.ext4 -q "/dev/mapper/${LUKS_DEV}" &>>"${BUILD_LOG}"
sync; udevadm settle

_boot_part_partuuid=$(blkid --match-tag PARTUUID --output value "${_loop_dev}p1") # Goes into fstab
_root_part_uuid=$(blkid --match-tag UUID --output value "${_loop_dev}p2") # Goes into crypttab and cmdline.txt

mount "/dev/mapper/${LUKS_DEV}" "${_mnt_dir}" &>>"${BUILD_LOG}"
sync; udevadm settle

mkdir --parents "${_mnt_dir}/boot/firmware" 2>/dev/null || true
mount "${_loop_dev}p1" "${_mnt_dir}/boot/firmware" &>>"${BUILD_LOG}"
sync; udevadm settle


# From man:
# 'The default, with no --variant=X argument, is to create a base Debian installation with all packages of priority required and important, including apt.'
# Use '--variant minbase' for 'only includes required packages and apt'
echo 'Debootstrap Debian' | tee --append "${BUILD_LOG}"
debootstrap \
            --arch arm64 \
            --include="${DEBOOTSTRAP_PACKAGES}" \
            --components='main,contrib,non-free,non-free-firmware' \
            "${DEBOOTSTRAP_SUITE}" \
            "${_mnt_dir}" \
            'https://deb.debian.org/debian/' &>>"${BUILD_LOG}"


echo 'Add raspberrypi.com repository' | tee --append "${BUILD_LOG}"
echo "Types: deb
URIs: https://archive.raspberrypi.com/debian/
Suites: ${DEBOOTSTRAP_SUITE}
Components: main
Signed-By: /usr/share/keyrings/raspberrypi-archive-keyring.pgp
" | tee "${_mnt_dir}/etc/apt/sources.list.d/raspi.sources"

# TODO: Download key to make script work on vanilla Debian
install --mode=0644 --owner=root --group=root \
        /usr/share/keyrings/raspberrypi-archive-keyring.pgp \
        "${_mnt_dir}/usr/share/keyrings/raspberrypi-archive-keyring.pgp"


echo 'Update fstab' | tee --append "${BUILD_LOG}"
echo "proc            /proc           proc    defaults          0       0
PARTUUID=${_boot_part_partuuid}  /boot/firmware  vfat    defaults          0       2
/dev/mapper/${LUKS_DEV}  /               ext4    defaults,noatime  0       1" | tee "${_mnt_dir}/etc/fstab"

echo 'Update crypttab' | tee --append "${BUILD_LOG}"
echo "${LUKS_DEV} UUID=${_root_part_uuid} none luks" | tee "${_mnt_dir}/etc/crypttab"

# To avoid same mistake again: 'cryptdevice=...' does not work on Debian+initramfs
# https://wiki.archlinux.org/title/Dm-crypt/System_configuration#cryptdevice
echo 'Update cmdline.txt' | tee --append "${BUILD_LOG}"
echo "console=serial0,115200 console=tty1 root=/dev/mapper/${LUKS_DEV} cryptopts=target=${LUKS_DEV},source=UUID=${_root_part_uuid},luks rootfstype=ext4 fsck.repair=yes rootwait" | tee "${_mnt_dir}/boot/firmware/cmdline.txt"

echo 'Update config.txt' | tee --append "${BUILD_LOG}"
echo 'dtparam=audio=on
camera_auto_detect=1
display_auto_detect=1
auto_initramfs=1
dtoverlay=vc4-kms-v3d
max_framebuffers=2
disable_fw_kms_setup=1
arm_64bit=1
disable_overscan=1
arm_boost=1
[all]' | tee "${_mnt_dir}/boot/firmware/config.txt"

# TODO: Check if we need it
echo 'CRYPTSETUP=y' | tee --append "${_mnt_dir}/etc/cryptsetup-initramfs/conf-hook"

echo 'Update locale' | tee --append "${BUILD_LOG}"
echo 'en_US.UTF-8 UTF-8
en_GB.UTF-8 UTF-8
uk_UA.UTF-8 UTF-8
' | tee "${_mnt_dir}/etc/locale.gen"


echo 'LANG=en_US.UTF-8
LC_TIME=en_US.UTF-8
LC_NUMERIC=en_US.UTF-8
LC_PAPER=en_US.UTF-8
LC_MEASUREMENT=en_US.UTF-8
LC_NAME=en_US.UTF-8
LC_TELEPHONE=en_US.UTF-8
LC_MONETARY=en_US.UTF-8
LC_ADDRESS=en_US.UTF-8
LC_IDENTIFICATION=en_US.UTF-8
' | tee "${_mnt_dir}/etc/default/locale"

echo 'Enable predictable network interface names'
ln -sf /dev/null "${_mnt_dir}/etc/systemd/network/99-default.link"
ln -sf /dev/null "${_mnt_dir}/etc/systemd/network/73-usb-net-by-mac.link"


# TODO: Check if we need it
systemd-nspawn --quiet --no-pager --directory="${_mnt_dir}" locale-gen &>>"${BUILD_LOG}"


echo 'Update system and install Raspberry Pis specific packages' | tee --append "${BUILD_LOG}"
# shellcheck disable=SC2129
systemd-nspawn --quiet --no-pager --directory="${_mnt_dir}" apt-get update &>>"${BUILD_LOG}"
systemd-nspawn --quiet --no-pager --directory="${_mnt_dir}" apt-get dist-upgrade --yes &>>"${BUILD_LOG}"
# shellcheck disable=SC2086
systemd-nspawn --quiet --no-pager --directory="${_mnt_dir}" apt-get install --yes --no-install-recommends --no-install-suggests ${RPI_PACKAGES} &>>"${BUILD_LOG}"


echo 'Set hostname' | tee --append "${BUILD_LOG}"
echo 'raspberrypi' | tee "${_mnt_dir}/etc/hostname"
echo '127.0.0.1       localhost       raspberrypi' | tee "${_mnt_dir}/etc/hosts"


echo 'Set root password' | tee --append "${BUILD_LOG}"
echo "root:${ROOT_PASSWORD}" | chpasswd --crypt-method YESCRYPT --root "${_mnt_dir}" &>>"${BUILD_LOG}"


# Initramfs rebuilt during packages installation - no need to do it manually
# Note: this will work only if linux-image-rpi-* already installed
# echo 'Build initramfs' | tee --append "${BUILD_LOG}"
# for _kernel_path in "${_mnt_dir}/usr/lib/modules/"*; do
#     _kernel=$(echo "${_kernel_path}" | awk -F'/' '{print $NF}')
#     systemd-nspawn --quiet --no-pager --directory="${_mnt_dir}" --setenv=MODULES=most \
#         update-initramfs -k "${_kernel}" -c -b '/boot/firmware' &>>"${BUILD_LOG}"
# done


echo -e "\nImage mounted as ${_mnt_dir} - you can customize it now or press any key to continue"
echo 'To chroot:'
echo "sudo systemd-nspawn --quiet --no-pager --directory=${_mnt_dir} /bin/bash"
read -N 1 -r


cleanup


echo -e '\nDone' | tee --append "${BUILD_LOG}"
echo "Time start  : ${_time_start}" | tee --append "${BUILD_LOG}"
echo "Time finish : $(date +'%Y-%m-%d %H:%M:%S')" | tee --append "${BUILD_LOG}"
echo '' | tee --append "${BUILD_LOG}"
