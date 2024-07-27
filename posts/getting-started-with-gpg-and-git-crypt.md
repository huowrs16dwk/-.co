---
layout: post
title: getting started with gpg and git-crypt
date: 2024-07-27
---

# {{ title }}

First, you'll need a gpg key

```
gpg --full-gen-key

gpg (GnuPG) 2.4.5; Copyright (C) 2024 g10 Code GmbH
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.

Please select what kind of key you want:
   (1) RSA and RSA
   (2) DSA and Elgamal
   (3) DSA (sign only)
   (4) RSA (sign only)
   (9) ECC (sign and encrypt) *default*
  (10) ECC (sign only)
  (14) Existing key from card
Your selection? 9
Please select which elliptic curve you want:
   (1) Curve 25519 *default*
   (4) NIST P-384
   (6) Brainpool P-256
Your selection? 1
Please specify how long the key should be valid.
         0 = key does not expire
      <n>  = key expires in n days
      <n>w = key expires in n weeks
      <n>m = key expires in n months
      <n>y = key expires in n years
Key is valid for? (0) 1y
Key expires at Sun 27 Jul 2025 10:55:35 AM EDT
Is this correct? (y/N) y

GnuPG needs to construct a user ID to identify your key.

Real name: ronin
Email address: huowrs16dwk@proton.me
Comment:
You selected this USER-ID:
    "ronin <huowrs16dwk@proton.me>"

Change (N)ame, (C)omment, (E)mail or (O)kay/(Q)uit? o
We need to generate a lot of random bytes. It is a good idea to perform
some other action (type on the keyboard, move the mouse, utilize the
disks) during the prime generation; this gives the random number
generator a better chance to gain enough entropy.
We need to generate a lot of random bytes. It is a good idea to perform
some other action (type on the keyboard, move the mouse, utilize the
disks) during the prime generation; this gives the random number
generator a better chance to gain enough entropy.
gpg: directory '/home/ronin/.gnupg/openpgp-revocs.d' created
gpg: revocation certificate stored as '/home/ronin/.gnupg/openpgp-revocs.d/7B4D7ED421EF3D928046780D06C65FB66D9760C4.rev'
public and secret key created and signed.

pub   ed25519 2024-07-27 [SC] [expires: 2025-07-27]
      7B4D7ED421EF3D928046780D06C65FB66D9760C4
uid                      ronin <huowrs16dwk@proton.me>
sub   cv25519 2024-07-27 [E] [expires: 2025-07-27]
```

next in the git repo, initialize git crypt

```
git crypt init
git crypt add-gpg-user huowrs16dwk@proton.me
```

To add encrypted files to the repo, you need to set the attributes

```
echo 'secret-file.txt filter=git-crypt diff=git-crypt' >> .gitattributes
git add .gitattributes

echo 'super secret spy stuff' > secret-file.txt
git add secret-file.txt

git commit -m 'adding secret file'
```

You can export your key to use on another machine

```
gpg --list-secret-keys

[keyboxd]
---------
sec   ed25519 2024-07-27 [SC] [expires: 2025-07-27]
      7B4D7ED421EF3D928046780D06C65FB66D9760C4
uid           [ultimate] ronin <huowrs16dwk@proton.me>
ssb   cv25519 2024-07-27 [E] [expires: 2025-07-27]

gpg --export-secret-keys -a 7B4D7ED421EF3D928046780D06C65FB66D9760C4 > private.key
```

On the second machine you can import the gpg key

```
gpg --import private.key
```

And unlock the repo

```
git crypt unlock
```

To share your gpg key with other developers or services like github and gitlab you'll need the public key

```
gpg --armor --export 7B4D7ED421EF3D928046780D06C65FB66D9760C4 > public.key
```

You can also use this same key to sign git commits


```
gpg --list-secret-keys --keyid-format LONG
[keyboxd]
---------
sec   ed25519/06C65FB66D9760C4 2024-07-27 [SC] [expires: 2025-07-27]
      7B4D7ED421EF3D928046780D06C65FB66D9760C4
uid                 [ultimate] ronin <huowrs16dwk@proton.me>
ssb   cv25519/0437E185D1FC2FE9 2024-07-27 [E] [expires: 2025-07-27]

git config --global user.signingkey 06C65FB66D9760C4
```

To sign a commit, use -S

```
git commit -S -m "My commit message"
```

To sign all commits by default:

```
git config --global commit.gpgsign true
```


