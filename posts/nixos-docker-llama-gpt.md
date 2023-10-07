---
layout: post
title: nixos docker llama-gpt
date: 2023-10-07
---

# {{ title }}

Configuring nixos can be difficult because the parameters are not always obvious.  This assumes an x86 cpu and an nvidia gpu with cuda 12 support

## configuring nixos

Add the following to /etc/nixos/configuration.nix

```

  environment.systemPackages = with pkgs; [
    ...

    # gpu
    cudatoolkit
  ];


  # nvidia
  hardware.nvidia.modesetting.enable = true;
  hardware.opengl.driSupport32Bit = true;

  services.xserver.videoDrivers = [ "nvidia" ];

  nixpkgs.config.cudaSupport = true;

  boot.extraModulePackages = [ config.boot.kernelPackages.nvidia_x11 ];
  boot.kernelParams = [ "module_blacklist=i915" ];

  # docker

  virtualisation.docker.enable = true;
  virtualisation.docker.enableNvidia = true;
  virtualisation.docker.extraOptions = "--add-runtime nvidia=/run/current-system/sw/bin/nvidia-container-runtime";

```

The upgrade will potentially take a very long time as it needs to compile several modules.
You will need to reboot after the upgrade.

```
sudo nixos-rebuild switch && sudo reboot
```

## testing

Ensure that nvidia-smi command works on the host machine and shows CUDA Version 12.x

```
nvidia-smi
```

Ensure the docker nvidia runtime is working correctly and that nvidia-smi can be run from inside a container

```
docker run --rm -it --gpus all nvidia/cuda:12.2.0-devel-ubuntu20.04 nvidia-smi
```

## running the project

```
git clone https://github.com/getumbrel/llama-gpt
cd llama-gpt
./run.sh --model 7b --with-cuda
```

Now access port 3000 from a browser.


Overall the system setup isn't complex but it can be confusing especially if you don't have the correct nix options setup.
