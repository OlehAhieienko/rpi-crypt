# About

Script builds flashable images for Raspberry Pi (4/5/Zero 2) with LUKS-encrypted root partition.

Uses nspawn with debootstrap under the hood.

:warning: Software still in beta - **do not** use for prod or critical systems :warning:


# Usage

- Clone repository
```shell
git clone --recurse-submodules https://github.com/OlehAhieienko/rpi-crypt.git
```

- Edit variables in `conf` file for your Raspberry Pi version (`rpi0.conf`, `rpi4.conf` or `rpi5.conf`) and run `rpi-crypt.sh` script with profile name:
```shell
cd rpi-crypt
sudo ./rpi-crypt.sh rpi5.conf
```


# Post installation

- Expand root partition
```shell
parted --script --fix --align=opt /dev/mmcblk0 resizepart 2 100%
cryptsetup resize cryptroot
resize2fs /dev/mapper/cryptroot
```

- Remote LUKS unlock via SSH
```shell
# Install dropbear-initramfs
apt install dropbear-initramfs

# Update `initramfs.conf`
# Format:         'ip=<client-ip>:<server-ip>:<gw-ip>:<netmask>:<hostname>:<device>:<autoconf>:<dns0-ip>:<dns1-ip>:<ntp0-ip>'
# Example DHCP:   'ip=::::rpiX.local:eth0:dhcp'
# Example static: 'ip=192.168.88.2::192.168.88.1:255.255.255.0:rpiX.local:eth0:none'
# https://www.kernel.org/doc/Documentation/filesystems/nfs/nfsroot.txt
echo 'ip=::::rpiX.local:eth0:dhcp' >> /etc/initramfs-tools/initramfs.conf

# Update `dropbear.conf`
echo 'DROPBEAR_OPTIONS="-I 180 -j -k -p 2222 -s -c cryptroot-unlock"' >> /etc/dropbear/initramfs/dropbear.conf

# If there is no SSH keys - generate new one
ssh-keygen
cat "${HOME}/.ssh/id_ed25519.pub" >> '/etc/dropbear/initramfs/authorized_keys'

# Rebuild initramfs
# Make sure there is no `Invalid authorized_keys file, SSH login to initramfs won't work!` warnings
update-initramfs -k all -u
```


# Documentation
- https://gitlab.mister-muffin.de/josch/mmdebstrap/
- https://salsa.debian.org/installer-team/debootstrap
- https://www.freedesktop.org/software/systemd/man/latest/systemd-nspawn.html
- https://wiki.debian.org/Debootstrap
- https://wiki.debian.org/nspawn
- https://wiki.archlinux.org/title/Dm-crypt/Encrypting_an_entire_system
