# The image is built for amd64 and arm64 — a VPS, and a Raspberry Pi or a NAS at home. The build
# stage runs on the machine doing the building and cross-compiles, rather than under QEMU: emulated,
# the arm64 half of a Rust build takes the better part of an hour; cross-compiled, a few minutes.
FROM --platform=$BUILDPLATFORM rust:1-bookworm AS build
ARG BUILDARCH
ARG TARGETARCH
WORKDIR /src

# Which Rust target this is, and — only when it is not the builder's own — the C cross-compiler
# that ring and secp256k1 need for their C parts. Written to /env and sourced by the build below.
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) triple=x86_64-unknown-linux-gnu; gnu=x86_64-linux-gnu ;; \
      arm64) triple=aarch64-unknown-linux-gnu; gnu=aarch64-linux-gnu ;; \
      *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    echo "export TRIPLE=$triple" > /env; \
    if [ "$TARGETARCH" != "$BUILDARCH" ]; then \
      apt-get update; \
      apt-get install -y --no-install-recommends "gcc-$gnu" "libc6-dev-$TARGETARCH-cross"; \
      rm -rf /var/lib/apt/lists/*; \
      upper=$(echo "$triple" | tr 'a-z-' 'A-Z_'); \
      echo "export CARGO_TARGET_${upper}_LINKER=$gnu-gcc" >> /env; \
      echo "export CC_$(echo "$triple" | tr '-' '_')=$gnu-gcc" >> /env; \
    fi

# The toolchain file first, so the target is added to the toolchain it pins, not to whichever
# happens to be the image's default.
COPY rust-toolchain.toml ./
RUN . /env && rustup target add "$TRIPLE"

COPY . .
RUN . /env \
 && cargo build --release --locked -p iskra-bridge --target "$TRIPLE" \
 && cp "target/$TRIPLE/release/iskra-bridge" /iskra-bridge

# Run
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# The bridge holds other people's access tokens in memory. It has no business being root, and the
# one thing it writes to disk is its own key, in /data.
RUN useradd --system --create-home --uid 10001 bridge \
 && mkdir /data \
 && chown bridge:bridge /data
USER bridge
COPY --from=build /iskra-bridge /usr/local/bin/iskra-bridge

# The key is the bridge's address — the npub people type into the app — so it lives on a volume:
# made on the first start, and the same after every upgrade and every recreated container. Without
# a volume it would still work, and change address the first time anybody ran `docker compose pull`.
ENV BRIDGE_KEY_FILE=/data/bridge-key
VOLUME /data

ENV RUST_LOG=info
ENTRYPOINT ["/usr/local/bin/iskra-bridge"]
