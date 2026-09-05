FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bc \
        binutils-arm-linux-gnueabihf \
        bison \
        build-essential \
        ca-certificates \
        cpio \
        debian-archive-keyring \
        debootstrap \
        device-tree-compiler \
        e2fsprogs \
        file \
        flex \
        gcc-arm-linux-gnueabihf \
        git \
        kmod \
        libelf-dev \
        libssl-dev \
        make \
        python3 \
        qemu-user-static \
        rsync \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
CMD ["bash"]
