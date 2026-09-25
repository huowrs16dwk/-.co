---
layout: post
title: ghidra debugging with lldb
date: 2023-11-18
---

# {{ title }}

The Ghidra project added debugger support in version 10.  To setup lldb support you need to compile lldb-java (liblldb-java.so) 

To start, you'll need ghidra and some support packages

```
sudo pacman -S ghidra gradle swig lldb
```

BlackArch installs ghidra to /opt/ghidra.  In that directory there is a build.gradle file for lldb-java:

```
cd /opt/ghidra/Ghidra/Debug/Debugger-swig-lldb
cat InstructionsForBuildingLLDBInterface.txt
```

The instructions are pretty good, but there are some gotchas.  For starters, you won't have permission since ghidra and it's directories are all owned by root.  So, you'll need to be root to do the build or change the permissions on the folders.  Then we can begin.

You'll need the source code to lldb. You don't need to build lldb as you have the pacman pre-built version which should be 16, but you do need the headers.

```
git clone https://github.com/llvm/llvm-project.git
git checkout release/16.x
export LLVM_HOME=./llvm-project/
export LLVM_BUILD=/usr/lib
```

Next we need to do the gradle build

```
gradle generateSwig
gradle build
```

Next, install it to /usr/lib

```
cd /opt/ghidra/Ghidra/Debug/Debugger-swig-lldb/build/os/linux_x86_64
cp liblldb-java.so /usr/lib
```

Then finally we need to adjust the launch.properties file

```
echo "VMARGS=-Djava.library.path=/usr/lib" >> /opt/ghidra/support/launch.properties
```

Now launch ghidra and start debugging something
