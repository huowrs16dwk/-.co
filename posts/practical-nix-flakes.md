---
layout: post
title: practical nix flakes
date: 2023-11-09
---

# {{ title }}

If you are running nixos, you already have the nix build system.  Otherwise, you'll need to install it

```bash
curl -L https://nixos.org/nix/install | sh
```

Now you'll need to enable flakes

```bash
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" > ~/.config/nix/nix.conf

# now nix flake command should work
nix flake --help
```

For setup, that's pretty much all you need to do.  If you already have a project with a working `flake.nix`
file then you are off to the races.

```bash
# build the default target
nix build

# enter quick shell with dependencies available
nix shell

# enter development shell for reproducable builds
nix develop
```

But what if you don't have a flake file yet?  Here are some examples for various programming languages.


## ruby

To generate the gemset.nix you'll need to use bundix:  `nix-shell -p bundix`

```
{
  description = "A Ruby on Rails project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux"; # Adjust the system if necessary
      pkgs = import nixpkgs {
        inherit system;
      };

      # Specify the Ruby version you want to use
      ruby = pkgs.ruby_3_2; # As an example, using Ruby 3.2

      # Define the Ruby on Rails environment
      railsEnv = pkgs.bundlerEnv {
        name = "my-rails-app";
        inherit ruby;
        gemfile = ./Gemfile;
        lockfile = ./Gemfile.lock;
        gemset = ./gemset.nix; # Generated from Gemfile.lock
      };
    in
    {
      packages.${system}.default = railsEnv;

      defaultPackage.${system} = railsEnv;

      # Define a development shell environment
      devShells.${system} = pkgs.mkShell {
        buildInputs = [
          railsEnv # This provides the Ruby environment with all gems specified in Gemfile
          # Include other build inputs like databases, etc.
        ];
      };
    };
}
```

## python

```
{
  description = "A Python project with Numpy and Pandas";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";

      # Obtain the package set from nixpkgs
      pkgs = import nixpkgs {
        inherit system;
      };

      # Function to create a Python environment
      pythonEnv = pkgs.python3.withPackages (ps: with ps; [
        numpy
        pandas
        # You can add more Python packages here, e.g., matplotlib, scipy, etc.
      ]);

    in
    {
      packages.${system}.default = pythonEnv;

      defaultPackage.${system} = pythonEnv;

      # Define a development shell for `nix develop`
      devShells.${system} = pkgs.mkShell {
        buildInputs = [ pythonEnv ];

        # Set PYTHONPATH to make sure Python can find the installed packages
        shellHook = ''
            export PYTHONPATH=${pythonEnv}/${pkgs.python3.sitePackages}
        '';
      };
    };
}
```

## nodejs

```
{
  description = "A Node.js project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
      };

      nodePackages = pkgs.nodePackages // {
        package = pkgs.nodePackages.package.override {
          src = self;
        };
      };

      # Create the development environment
      devShell = pkgs.mkShell {
        buildInputs = [
          pkgs.nodejs_20
        ];

        # The following line can be uncommented to automatically install npm dependencies
        # shellHook = ''
        #   npm install
        # '';
      };
    in
    {
      packages.${system}.default = nodePackages;
      devShells.${system}.default = devShell;
    };
}
```

## java

```
{
  description = "A simple Java project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # Import nixpkgs
      pkgs = import nixpkgs {
        system = "x86_64-linux";
      };

      # Define the Java environment
      javaEnv = pkgs.mkShell {
        buildInputs = [ pkgs.jdk19_headless pkgs.maven ];
      };
    in
    {
      packages.x86_64-linux.default = pkgs.stdenv.mkDerivation {
        pname = "my-java-app";
        version = "1.0";
        src = self;

        # Set JAVA_HOME
        buildInputs = [ pkgs.jdk19_headless pkgs.maven ];

        # The build phase
        buildPhase = ''
          mvn compile
        '';

        # The install phase
        installPhase = ''
          mvn package
        '';
      };

      # Define a development shell for `nix develop`
      devShells.x86_64-linux = javaEnv;
    };
}
```

Note: `nix build` will not have internet access to the maven repo, so you'll need to download the packages with `mvn dependency:go-offline`

## rust

```
{
  description = "A basic Rust application";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # Import nixpkgs for the x86_64-linux system
      pkgs = import nixpkgs {
        system = "x86_64-linux";
      };

      # Define the Rust package
      rustPackage = pkgs.rustPlatform.buildRustPackage {
        pname = "my-rust-app";
        version = "0.1.0";
        src = pkgs.lib.cleanSource ./.;

        # The hash for Cargo.lock
        cargoSha256 = "w9sBUL9eYOjFDNBhB35JImFjexnKM0nY7C7idCXNyKg=";

        # Set release mode explicitly, though it is the default
        cargoBuildFlags = [ "--release" ];
      };
    in
    {
      packages.x86_64-linux.default = rustPackage;

      defaultPackage.x86_64-linux = rustPackage;

      # Define a development environment for this project
      devShells.x86_64-linux = pkgs.mkShell {
        buildInputs = [
          pkgs.rustc
          pkgs.cargo
          # Include any other dependencies here
        ];
      };
    };
}
```


## c++

```
{
  description = "A C++ project with CMake and GCC";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # Import the nixpkgs for the specified system
      system = "x86_64-linux"; # Change this to your specific system if needed
      pkgs = import nixpkgs {
        inherit system;
      };

      # Create the development environment
      devEnv = pkgs.mkShell {
        nativeBuildInputs = [
          pkgs.cmake
          pkgs.gcc
          pkgs.make
          # Add any other dependencies your project may need, e.g.:
          # pkgs.boost
          # pkgs.eigen
          # etc.
        ];

        # Optionally set environment variables, like:
        # CXXFLAGS="-O3"
        # LDFLAGS="-flto"
      };
    in
    {
      # The default package to build
      packages.${system}.default = pkgs.stdenv.mkDerivation {
        pname = "my-cpp-app";
        version = "1.0";
        src = self; # or ./. if you want to point to the root of the project

        nativeBuildInputs = [ pkgs.cmake pkgs.gcc ];

        # The build phase (CMake in this case)
        buildPhase = ''
          cmake .
          make
        '';

        # The install phase
        installPhase = ''
          mkdir -p $out/bin
          cp my-cpp-app $out/bin/
        '';

        # You can specify more phases like checkPhase for tests, if necessary.
      };

      # Define the development shell for `nix develop`
      devShells.${system} = devEnv;

      # The default application when running `nix run`
      defaultApp.${system} = self.packages.${system}.default;
    };
}
```

## c++ cross compiling for x86 and aarch64

```
{
  description = "A C++ project with cross-compilation for aarch64-linux";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # Cross-compilation target
      crossSystem = "aarch64-linux";

      # Import nixpkgs for the host system
      hostPkgs = import nixpkgs {
        system = "x86_64-linux";
        overlays = [];
      };

      # Import nixpkgs with cross-compilation support
      crossPkgs = import nixpkgs {
        system = "x86_64-linux";
        crossSystem = {
          config = crossSystem;
          # Additional cross-compilation configuration goes here
        };
      };
    in {
      packages.x86_64-linux = {
        my-cpp-app = hostPkgs.stdenv.mkDerivation {
          pname = "my-cpp-app";
          version = "1.0";
          src = self;

          nativeBuildInputs = with hostPkgs; [ cmake pkg-config ];

          buildInputs = with hostPkgs; [
            # Dependencies for the target architecture
          ];

          buildPhase = ''
            cmake .
            make
          '';

          installPhase = ''
            mkdir -p $out/bin/x86
            cp my-cpp-app $out/bin/x86
          '';
        };

        my-cpp-app-aarch64 = crossPkgs.stdenv.mkDerivation {
          pname = "my-cpp-app";
          version = "1.0";
          src = self;

          nativeBuildInputs = with hostPkgs; [ cmake pkg-config ];

          buildInputs = with crossPkgs; [
            # Dependencies for the target architecture
          ];

          buildPhase = ''
            cmake .
            make
          '';

          installPhase = ''
            mkdir -p $out/bin/arm
            cp my-cpp-app $out/bin/arm
          '';
        };
      };

      # Define the development shell for `nix develop`
      devShells.x86_64-linux = hostPkgs.mkShell {
        nativeBuildInputs = with hostPkgs; [ cmake pkg-config ];
      };
    };
}
```

The arm target can be compiled by specifying the target

```bash
# build for x86
nix build .\#my-cpp-app

# build for arm
nix build .\#my-cpp-app-aarch64
```
