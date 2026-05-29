# joplin-api

Headless Joplin Data API server with WebDAV sync support.

Run [Joplin](https://joplinapp.org/) in headless mode as a REST API server, with periodic WebDAV sync to keep notes synchronized with your storage backend.

## Architecture

```
┌─────────────────────────────────────────────────┐
│                  joplin-api                      │
│                                                  │
│  ┌──────────────┐    ┌──────────────────────┐   │
│  │  Joplin CLI   │◄──►│   socat proxy        │   │
│  │  (127.0.0.1   │    │   (0.0.0.0:41185)   │   │
│  │   :41184)     │    │                      │   │
│  └──────┬───────┘    └──────────┬───────────┘   │
│         │                        │               │
│  ┌──────▼───────┐               │               │
│  │  cron sync    │               │               │
│  │  (flock lock) │               │               │
│  └──────┬───────┘               │               │
│         │                        │               │
└─────────┼────────────────────────┼───────────────┘
          │                        │
          ▼                        ▼
   ┌──────────────┐      ┌────────────────┐
   │  WebDAV       │      │  REST API      │
   │  (Synology)   │      │  /ping         │
   └──────────────┘      │  /notes        │
                          │  /folders      │
                          └────────────────┘
```

## Features

- **Headless Joplin** — Run Joplin without GUI, perfect for servers and containers
- **REST API** — Full access to Joplin Data API (notes, folders, tags, resources)
- **WebDAV Sync** — Periodic sync to WebDAV-compatible storage (Synology, Nextcloud, etc.)
- **Sync Lock** — Uses `flock` to prevent overlapping sync operations
- **ARM64 Support** — Built on `node:22-slim`, works on Raspberry Pi, Apple Silicon, and x86

## Quick Start

### Using docker-compose (recommended)

1. Clone the repo:
```bash
git clone https://github.com/happyeric77/joplin-api.git
cd joplin-api
```

2. Create your `.env` file:
```bash
cp .env.example .env
# Edit .env with your WebDAV credentials
```

3. Start the server:
```bash
docker-compose up -d
```

4. Verify it's running:
```bash
curl http://localhost:41185/ping
# Should return: JoplinClipperServer
```

### Using docker run

```bash
docker build -t joplin-api .

docker run -d \
  --name joplin-api \
  -p 41185:41185 \
  -v joplin-profile:/data/joplin-profile \
  -e JOPLIN_WEBDAV_URL="https://your-synology:5006/remote.php/dav/files/user/Notes" \
  -e JOPLIN_WEBDAV_USER="your-username" \
  -e JOPLIN_WEBDAV_PASS="your-password" \
  -e JOPLIN_API_TOKEN="your-api-token" \
  joplin-api
```

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `JOPLIN_WEBDAV_URL` | Yes | — | WebDAV server URL for sync |
| `JOPLIN_WEBDAV_USER` | Yes | — | WebDAV username |
| `JOPLIN_WEBDAV_PASS` | Yes | — | WebDAV password |
| `JOPLIN_API_TOKEN` | Yes | — | Token for Joplin Data API authentication |
| `JOPLIN_API_PORT` | No | `41184` | Internal Joplin API port (don't change unless you know what you're doing) |
| `JOPLIN_SYNC_INTERVAL` | No | `1` | Sync interval in minutes |

## API Usage

Once running, access the Joplin Data API through the proxy port (41185):

```bash
# Health check
curl http://localhost:41185/ping

# List notes
curl "http://localhost:41185/notes?token=your-api-token"

# Create a note
curl -X POST "http://localhost:41185/notes?token=your-api-token" \
  -H "Content-Type: application/json" \
  -d '{"title": "Hello", "body": "World"}'
```

For full API documentation, see [Joplin Data API](https://joplinapp.org/api/overview/).

## Kubernetes Deployment

This image is designed for Kubernetes deployments with:

- **StatefulSet** with 1 replica (single writer)
- **Longhorn PVC** for persistent profile storage
- **ClusterIP Service** for internal access
- **NetworkPolicy** for restricted access

See [k3s-homelab](https://github.com/happyeric77/k3s-homelab) for GitOps manifests.

## Development

### Build the image

```bash
docker build --platform linux/arm64 -t joplin-api:local .
```

### Run tests

```bash
# Start the server
docker-compose up -d

# Wait for startup
sleep 5

# Test API
curl http://localhost:41185/ping
# Expected: JoplinClipperServer

# Cleanup
docker-compose down
```

## License

[MIT](LICENSE)
