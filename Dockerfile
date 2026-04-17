FROM debian:bookworm-slim
RUN apt-get update -qq && apt-get install -y -qq curl xz-utils > /dev/null 2>&1 \
    && curl -sL https://ziglang.org/builds/zig-x86_64-linux-0.16.0-dev.3153+d6f43caad.tar.xz | tar xJ -C /opt \
    && ln -s /opt/zig-x86_64-linux-0.16.0-dev.3153+d6f43caad/zig /usr/local/bin/zig \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
