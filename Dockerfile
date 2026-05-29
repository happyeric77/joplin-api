FROM node:22-slim

# Install runtime dependencies:
#   cron      - periodic sync scheduling
#   socat     - TCP proxy for Joplin's localhost-only Data API
#   util-linux - provides flock(1) for sync lock
#   curl      - healthcheck/testing utility
RUN apt-get update && apt-get install -y \
    cron \
    socat \
    util-linux \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Joplin CLI with pinned version (3.2.2 verified working)
RUN npm install -g joplin@3.2.2

# Create Joplin profile directory (runtime data persisted via PVC)
RUN mkdir -p /data/joplin-profile

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Joplin Data API binds to 127.0.0.1:41184 internally.
# socat proxy exposes 0.0.0.0:41185 for same-pod sidecar access.
EXPOSE 41185

ENTRYPOINT ["/entrypoint.sh"]
