# zevm-stateless ere-server
#
# Build stage: compile the ere-server binary
FROM debian:bookworm-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
        wget xz-utils ca-certificates git cmake make \
        libsecp256k1-dev libssl-dev \
        pkg-config gcc g++ clang libc++-dev libc++abi-dev libgmp-dev libc-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Zig
ARG ZIG_VERSION=0.15.1
ARG TARGETARCH
RUN case "${TARGETARCH:-amd64}" in \
        amd64) ZIG_ARCH=x86_64 ;; \
        arm64) ZIG_ARCH=aarch64 ;; \
        *) ZIG_ARCH=x86_64 ;; \
    esac && \
    wget -q "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
    && tar xf "zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
    && mv "zig-${ZIG_ARCH}-linux-${ZIG_VERSION}" /usr/local/zig \
    && rm "zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz"
ENV PATH="/usr/local/zig:${PATH}"

# Build blst → /usr/local/lib/libblst.a
RUN git clone --depth=1 https://github.com/supranational/blst.git /tmp/blst && \
    cd /tmp/blst && \
    ./build.sh && \
    cp libblst.a /usr/local/lib/libblst.a && \
    cp bindings/blst.h bindings/blst_aux.h /usr/local/include/ && \
    rm -rf /tmp/blst

# Build mcl → /usr/local/lib/libmcl.so
RUN git clone --depth=1 https://github.com/herumi/mcl.git /tmp/mcl && \
    cd /tmp/mcl && \
    mkdir build && cd build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_CXX_FLAGS="-stdlib=libc++" && \
    make -j$(nproc) mcl && \
    cp lib/libmcl.so* /usr/local/lib/ && \
    ldconfig && \
    cp -r ../include/mcl /usr/local/include/ && \
    rm -rf /tmp/mcl

WORKDIR /src
COPY zevm-stateless/ .
COPY zevm/ /zevm

# Workarounds for two Zig 0.15.1 Linux/amd64 issues when building under emulation:
# 1. shuffleWithIndex panic in build_runner — shuffle only randomises dep-traversal
#    order; removing it is safe and makes the build deterministic.
# 2. Options step: faccessat returns ENOSYS (38) under QEMU/Rosetta amd64 emulation.
#    Treat error.Unexpected the same as error.FileNotFound so the file is recreated
#    rather than propagating the error.
RUN grep -v "rand.shuffle" /usr/local/zig/lib/compiler/build_runner.zig \
    > /tmp/build_runner_patched.zig \
    && sed -i 's/error\.FileNotFound => {/error.FileNotFound, error.Unexpected => {/' \
    /usr/local/zig/lib/std/Build/Step/Options.zig

# Build the ere-server binary (ReleaseFast for container use)
RUN zig build --build-runner /tmp/build_runner_patched.zig ere-server -Doptimize=ReleaseFast

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        libsecp256k1-dev libssl-dev libc++1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/lib/libmcl.so* /usr/local/lib/
RUN ldconfig
COPY --from=build /src/zig-out/bin/ere-server /ere-server

EXPOSE 50051

ENTRYPOINT ["/ere-server"]
