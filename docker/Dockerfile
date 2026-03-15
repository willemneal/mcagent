FROM rust:1.82-bookworm AS builder

WORKDIR /build

COPY Cargo.toml Cargo.lock ./
COPY bin/ bin/
COPY crates/ crates/

RUN cargo build --release --bin mcagent-server

FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates libssl3 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /build/target/release/mcagent-server /app/mcagent-server

ENTRYPOINT ["/app/mcagent-server"]
