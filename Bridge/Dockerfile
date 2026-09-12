# Build
FROM rust:1-bookworm AS build
WORKDIR /src
COPY . .
RUN cargo build --release -p iskra-bridge

# Run
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# The bridge holds other people's access tokens in memory. It has no business being root, and it
# writes nothing to disk at all.
RUN useradd --system --create-home --uid 10001 bridge
USER bridge
COPY --from=build /src/target/release/iskra-bridge /usr/local/bin/iskra-bridge
ENV RUST_LOG=info
ENTRYPOINT ["/usr/local/bin/iskra-bridge"]
