---
layout: post
title: encrypted usb sticks
date: 2023-08-25
---

# {{ title }}

Most desktop environments and their file managers have some level of support for encrypted removable media.
It turns out encrypting a usb stick is actually pretty simple with a few commands.


First, you'll need the `cryptsetup` package

```
sudo pacman -S cryptsetup
```


To create a single primary partition on the disk, we can use fdisk.  Careful, this will blow away everything.  You can of course use `cfdisk` or `parted` instead if you prefer a gui

```
sudo fdisk /dev/sda <<EOF
o
n
p
1


w
EOF
```

Next we need to format the partition with luks

```
sudo cryptsetup luksFormat /dev/sda1
```

Next we need to unlock the luks partition:

```
sudo cryptsetup luksOpen /dev/sda1 usbstick
```

This creates a new device at `/dev/mapper/usbstick` we can now format with a user file system and mount

```
sudo mkfs -t ext4 /dev/mapper/usbstick
sudo mount /dev/mapper/usbstick /mnt
```

GUI file managers like Nautilus, Dolphin, and Thunar should see the usb stick is encrypted and prompt for a password when mounting


To lock the disk again, we can close it using luks

```
sudo cryptsetup luksClose usbstick
```
