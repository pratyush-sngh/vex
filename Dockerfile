FROM debian:bookworm-slim
RUN apt-get update -qq && apt-get install -y -qq curl xz-utils ca-certificates > /dev/null 2>&1 \
    && arch="$(dpkg --print-architecture)" \
    && if [ "$arch" = "arm64" ]; then zig_pkg="zig-aarch64-linux-0.17.0-dev.314+eae06cf5c"; else zig_pkg="zig-x86_64-linux-0.17.0-dev.314+eae06cf5c"; fi \
    && curl -sL "https://ziglang.org/builds/${zig_pkg}.tar.xz" | tar xJ -C /opt \
    && ln -s "/opt/${zig_pkg}/zig" /usr/local/bin/zig \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
