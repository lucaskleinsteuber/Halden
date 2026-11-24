# The Halden server in a container.
#
#   docker build -f packaging/docker/Dockerfile -t halden .        (from the repository's root)
#
# The default target builds the program from source. Release images use the target `release`,
# which takes the program from the signed release package (put it at dist/<amd64|arm64>/halden),
# so the image runs exactly what was signed.

FROM rust:1-trixie AS build
WORKDIR /src
COPY server/ ./
RUN cargo build --release --locked && cp target/release/halden /halden

FROM debian:trixie-slim AS runtime
# ffmpeg and libheif make thumbnails of videos and HEIC photos and convert formats; tini passes
# stop signals on and reaps child processes.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg libheif-examples libheif-plugin-libde265 \
      libheif-plugin-x265 ca-certificates tini \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --user-group --home-dir /data --shell /usr/sbin/nologin halden \
 && mkdir -p /config /data /library \
 && chown halden:halden /config /data /library
COPY packaging/docker/entrypoint.sh /usr/local/bin/halden-entrypoint
# Updates come with a new image; the server and the apps know that from this. Two malloc arenas
# keep memory under load at a quarter, just as fast (see docs/TESTING.md).
ENV HALDEN_IN_DOCKER=1 \
    HALDEN_CONFIG=/config/config.toml \
    MALLOC_ARENA_MAX=2
VOLUME ["/config", "/data", "/library"]
EXPOSE 47130/tcp 5353/udp
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 CMD ["halden", "health"]
USER halden
ENTRYPOINT ["/usr/bin/tini", "--", "halden-entrypoint"]

FROM runtime AS release
ARG TARGETARCH
COPY --chmod=755 dist/${TARGETARCH}/halden /usr/local/bin/halden

FROM runtime AS source
COPY --from=build --chmod=755 /halden /usr/local/bin/halden
