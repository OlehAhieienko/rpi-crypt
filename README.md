# About

Script builds flashable images for Raspberry Pi (4/5/Zero 2) with LUKS-encrypted root partition.
Uses debootstrap+nspawn under the hood.

:warning::warning::warning: Software is on early development stage - **do not** use for prod or critical systems :warning::warning::warning:


# Usage

Edit variable at the top of `rpi-debootstrap-luks.sh` script and run it:
```shell
sudo ./rpi-debootstrap-luks.sh
```


# Post installation

After flashing image and booting, you can:

- To expand root partition (can be done on live system):
```shell
parted --script --fix --align=opt /dev/mmcblk0 resizepart 2 100%
cryptsetup resize cryptroot 100%
resize2fs /dev/mapper/cryptroot
```

- Install desktop
```shell
# TODO
```


# Documentation
- https://wiki.debian.org/Debootstrap
- https://wiki.debian.org/nspawn
- https://wiki.archlinux.org/title/Dm-crypt/Encrypting_an_entire_system
