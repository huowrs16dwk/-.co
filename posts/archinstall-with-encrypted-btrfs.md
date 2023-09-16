---
layout: post
title: archinstall with encrypted btrfs
date: 2023-09-14
---

# {{ title }}

Installing btrfs and getting snapshots working with encrypted disks can be tricky.
There are several bugs in the archinstall script still and the recommended way to install arch continues to be following the guide and doing it manually.
After doing this a few times I have found it's easier to run archinstall and then clean up the mess after than do everything by hand.


## first boot

Most modern motherboards are using EFI these days, so if you are using ventoy you'll want to boot with grub2 not "normal".

## archinstall

Go get the [arch iso](https://archlinux.org/download/) and load it up on your favorite usb drive.
I like to use [ventoy](https://www.ventoy.net/en/download.html).

Boot from the iso and run `archinstall` then select the following options:

- select your language
- mirrors > mirror region > select your region
- disk configuration > use best effort
    - select primary hard drive > btrfs > use default structure > compression on
- disk encryption > encryption password > use something that isn't easily cracked by hashcat
    - partitions > select the primary partition
    - use hsm if you have the hardware for it
- bootloader > grub
- swap > true
- set your hostname
- set a root password
- do not create a user account
- select a profile that makes sense, for example desktop
- audio server > pipewire
- kernels > linux-lts
- network > select network manager if you are using gnome or kde
- select your timezone


Then choose `install`. If you don't choose the options above it is highly likely it will blow up midway through. When it prompts you at the end to enter the environment select `yes`

## post-install cleanup

Now we have some cleanup to do.  First things first, we need to set the correct uuid for the primary disk in the grub configuration.

```bash
# append the block id info to the end of the grub template as commentary
blkid | sed 's/^/#/' >> /etc/default/grub

# edit the grub template
vim /etc/default/grub
```

If you've never used vim before, let's take this as an opportunity to learn a little now.
Jump to the end of the file with `G` you'll find the UUID info for the drives you have installed.  In my case I have two partitions `/dev/sda1` which is my EFI boot partition and `/dev/sda2` which is the luks volume.
Navigate to the UUID value for `/dev/sda2` and yank it to register 0 with `y9w`.
Jump to the beginning of the file with `gg` and then navigate to the `cryptdevice` entry.
Visually select the broken UUID value with `v9wh` and then paste the correct value with `P`.
When you are done press `ESC` then use `:x` to write the file and quit out of vim.

That changes the template, but that does not fix the actual grub configuration.  Now we need to regenerate the grub config.
Since we want to take advantage of snapshots anyway, we may as well just set that up now.

The easiest way to have automatic snapshots with rollbacks is with the [snap-pac-grub](https://aur.archlinux.org/packages/snap-pac-grub) AUR package.  Let's install that now.  I like to use [yay](https://aur.archlinux.org/packages/yay) for managing AUR packages.  Unfortnately `makepkg` won't let you bulid as root, so we'll need to create a user first.

```bash
# install git and golang
pacman -S git go

# create a local user
useradd -m -U -G wheel yourusername
passwd yourusername

# allow user sudo access
visudo
# jump to the "%wheel" entry with `/wheel` then navigate to the `#` and delete it with `x`
# save and quit with `ESC` then `:x`

# login as that user
su - yourusername

# install yay
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg
makepkg -i

# use yay to install snap-pac-grub
yay -S snap-pac-grub

# logout (back to root user)
exit
```

You can ignore the library error, it's because snapper isn't setup yet. We will fix that after we reboot. Don't forget to eject the arch iso before rebooting.

```
shutdown -r now
```

## second boot

If everything went well with the grub menu you won't experience any issues during boot, you'll be prompted for the luks encryption password to unlock the disk and the btrfs sub-volumes will mount correctly.

Login as root.

Now we can setup snapper correctly.  You can refer to the [arch wiki](https://wiki.archlinux.org/title/Snapper) for more info.

```
snapper list
```

You should see a single entry at `0`. Let's create a baseline snapshot.

```
snapper create --description 'fresh install'
```

snap-pac-grub automatically creates pre and post hooks into pacman and grub boot entries for the snapshots.  Try installing something and you'll see it in action.  If you take manual snapshots, you may want to regenerate the grub config at times.

```
grub-mkconfig -o /boot/grub/grub.cfg
```


