# In-Tree Kernel Module Builder

Provides an "easy" way to build an in-tree kernel module for balenaOS.

## How it works

- Downloads the kernel headers from s3 for the balenaOS versions specified
- For each kernel version, it clones the linux source
- Builds modules from the directory specified

## Usage

_Dockerfile.template_

```Dockerfile
FROM balenaplayground/balenablocks-in-tree-module-builder:%%BALENA_ARCH%% AS base

ENV VERSION '2.53.12+rev1.dev'
ENV BALENA_MACHINE_NAME=%%BALENA_MACHINE_NAME%%

WORKDIR /usr/src/app

RUN itkm_builder build --os-version "$VERSION" --modules-list 'MMA7660' --src "drivers/iio/accel"
```

The image contains the script `itkm_builder` which takes the following arguments:

```bash
usage: build.sh [build|list] [options]

commands:
  list: list available devices and versions.
  build: build kernel module for specified device and OS versions.

build options:
  --device=""    Balena machine name.
  --os-version="-version"   Space separated list of OS versions.
  --src=""     Where to find kernel module source.
  --dest-dir="output"     Destination directory, defaults to "output".
  --modules-list=""   Space separated list of modules to build.
  --linux-src=""     Where to find linux kernel source for respective OS version.
```
