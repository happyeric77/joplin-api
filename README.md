# joplin-api

Headless Joplin Data API server with WebDAV sync support.

Run [Joplin](https://joplinapp.org/) in headless mode as a REST API server, with periodic WebDAV sync to keep notes synchronized with your storage backend.

## Architecture

```
┌─────────────────────────────────────────────────┐
│                  joplin-api                      │
│                                                  │
│  ┌──────────────────────────────────────────┐    │
│  │       Joplin CLI (Headless)               │    │
│  │       Data API on 0.0.0.0:41184           │    │
│  │       + event-driven sync loop            │    │
│  └────────┬────────────────────────┬─────────┘    │
│           │                        │              │
└───────────┼────────────────────────┼──────────────┘
            │                        │
            ▼                        ▼
     ┌──────────────┐      ┌────────────────┐
     │  REST API     │      │  WebDAV        │
     │  /ping        │      │  (Synology)    │
     │  /notes       │      └────────────────┘
     │  /folders     │
     └──────────────┘
```

## Features

- **Headless Joplin** — Run Joplin without GUI, perfect for servers and containers
- **REST API** — Full access to Joplin Data API (notes, folders, tags, resources)
- **WebDAV Sync** — Periodic sync to WebDAV-compatible storage (Synology, Nextcloud, etc.)
- **Event-Driven Sync** — Polls Joplin for changes and syncs to WebDAV with configurable debounce
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

3. Start the server — choose one option:

   **Option A: Build locally** (default)

   ```bash
   docker-compose up -d
   ```

   **Option B: Use the prebuilt image**
   Edit `docker-compose.yml` to replace `build: .` with `image: ghcr.io/happyeric77/joplin-api:latest`, then:

   ```bash
   docker-compose up -d
   ```

4. Verify it's running:

```bash
curl http://localhost:41184/ping
# Should return: JoplinClipperServer
```

### Using the prebuilt image (GHCR)

Skip the local build and pull directly from GitHub Container Registry:

```bash
docker pull ghcr.io/happyeric77/joplin-api:latest

docker run -d \
  --name joplin-api \
  -p 41184:41184 \
  -v joplin-profile:/data/joplin-profile \
  -e JOPLIN_WEBDAV_URL="https://your-synology:5006/remote.php/dav/files/user/Notes" \
  -e JOPLIN_WEBDAV_USER="your-username" \
  -e JOPLIN_WEBDAV_PASS="your-password" \
  -e JOPLIN_API_TOKEN="your-api-token" \
  ghcr.io/happyeric77/joplin-api:latest
```

### Building and running locally

```bash
docker build -t joplin-api .

docker run -d \
  --name joplin-api \
  -p 41184:41184 \
  -v joplin-profile:/data/joplin-profile \
  -e JOPLIN_WEBDAV_URL="https://your-synology:5006/remote.php/dav/files/user/Notes" \
  -e JOPLIN_WEBDAV_USER="your-username" \
  -e JOPLIN_WEBDAV_PASS="your-password" \
  -e JOPLIN_API_TOKEN="your-api-token" \
  joplin-api
```

## Environment Variables

| Variable                                | Required | Default                | Description                                                                             |
| --------------------------------------- | -------- | ---------------------- | --------------------------------------------------------------------------------------- |
| `JOPLIN_WEBDAV_URL`                     | Yes      | —                      | WebDAV server URL for sync                                                              |
| `JOPLIN_WEBDAV_USER`                    | Yes      | —                      | WebDAV username                                                                         |
| `JOPLIN_WEBDAV_PASS`                    | Yes      | —                      | WebDAV password                                                                         |
| `JOPLIN_API_TOKEN`                      | Yes      | —                      | Token for Joplin Data API authentication                                                |
| `JOPLIN_PROFILE_DIR`                    | No       | `/data/joplin-profile` | Joplin profile/data directory                                                           |
| `JOPLIN_SYNC_INTERVAL`                  | No       | `10`                   | Legacy sync interval in minutes (overridden by `JOPLIN_PERIODIC_SYNC_INTERVAL_SECONDS`) |
| `JOPLIN_PERIODIC_SYNC_INTERVAL_SECONDS` | No       | —                      | Periodic sync interval in seconds (overrides legacy `JOPLIN_SYNC_INTERVAL`)             |
| `JOPLIN_EVENT_POLL_INTERVAL_SECONDS`    | No       | `15`                   | Seconds between event polls                                                             |
| `JOPLIN_EVENT_SYNC_DEBOUNCE_SECONDS`    | No       | `30`                   | Debounce window before triggering sync after events are detected                        |

## API Usage

Once running, access the Joplin Data API on port 41184:

```bash
# Health check
curl http://localhost:41184/ping

# List notes
curl "http://localhost:41184/notes?token=your-api-token"

# Create a note
curl -X POST "http://localhost:41184/notes?token=your-api-token" \
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

## Development

### Build the image

```bash
docker build --platform linux/arm64 -t joplin-api:local .
```

### Manual smoke test

```bash
# Start the server
docker-compose up -d

# Wait for startup
sleep 5

# Test API
curl http://localhost:41184/ping
# Expected: JoplinClipperServer

# Cleanup
docker-compose down
```

## License

[MIT](LICENSE)
