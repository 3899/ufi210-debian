FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        bc \
        binutils-arm-linux-gnueabihf \
        binfmt-support \
        bison \
        ca-certificates \
        cpio \
        curl \
        debootstrap \
        device-tree-compiler \
        dosfstools \
        e2fsprogs \
        file \
        flex \
        g++-arm-linux-gnueabihf \
        gcc-arm-none-eabi=15:10.3-2021.07-4 \
        gcc-arm-linux-gnueabihf \
        git \
        kmod \
        libelf-dev \
        libssl-dev \
        lz4 \
        make \
        mtools \
        openssl \
        python3 \
        qemu-user-static \
        rsync \
        xz-utils \
        zstd \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/build_firmware.sh /usr/local/bin/msm8909-build
RUN chmod +x /usr/local/bin/msm8909-build

WORKDIR /work
ENV MSM8909_IN_CONTAINER=1
ENTRYPOINT ["/usr/local/bin/msm8909-build"]
