# EliHole

DNS sinkhole built with Elixir and Phoenix. Like Pi-hole, but in Elixir.

## Features

### DNS Engine
- UDP DNS server with upstream forwarding via `:gen_udp`
- **Race resolution** — queries 2 upstreams in parallel, returns fastest response
- Fallback to remaining upstreams if racers fail
- DNS response caching with configurable TTL (ETS, default 300s)
- Blocked domains return `0.0.0.0` for A records, NXDOMAIN for others
- Upstream speed tracking with weighted random selection

### Blocking
- **Exact match** — `ads.example.com`
- **Wildcard match** — `*.example.com` blocks all subdomains
- **Regex match** — `/(ads|tracking)\..*\.com/`
- ETS-backed lookup for sub-millisecond blocking decisions
- Manual blocklist entry CRUD with search and pagination
- Bulk import from hosts-file or domain-list formats

### Gravity (Adlist Sync)
- Subscribe to remote adlist URLs (same format as Pi-hole)
- Scheduled auto-update every 24 hours
- Manual "Update Now" from admin UI
- Concurrent download (up to 4 lists in parallel)
- Deduplication via `ON CONFLICT DO NOTHING`
- Per-adlist domain count tracking

### Teleporter (Import/Export)
- Import Pi-hole teleporter backups (`.tar.gz`)
  - Blacklists (exact + regex), DNS providers, adlists
  - Reports skipped items (whitelists, clients, groups, local DNS)
- Import EliHole's own backups
- Export current config as `.tar.gz` (blocklist entries + providers)
- Auto-detect backup format (Pi-hole vs EliHole)

### Admin Panel (LiveView)
- **Dashboard** (`/admin`) — total queries, resolved/blocked/failed counts, queries/sec, top domains, top clients, cache stats, fastest upstream
- **Query Log** (`/admin/queries`) — real-time query stream via PubSub, per-query status/timing/upstream
- **Blocklist** (`/admin/blocklist`) — search, add/edit/delete entries, toggle enable/disable, pagination
- **Gravity** (`/admin/gravity`) — adlist management, add/remove URLs, trigger update, view status
- **Settings** (`/admin/settings`) — upstream DNS providers (presets: Google/Cloudflare/Quad9 + custom), cache TTL, flush cache, upstream speed table, teleporter import/export

### Auth
- Admin user via `ADMIN_USER` / `ADMIN_PASSWORD` env vars
- Session-based login with password hashing (bcrypt)
- First-run setup page at `/setup`
- Auth-protected `/admin/*` routes

### Observability
- Sentry/GlitchTip integration for error tracking
- Phoenix LiveDashboard in dev mode (`/dev/dashboard`)
- Telemetry metrics

## Quick Start

```bash
cp .env.example .env
# edit .env with your DATABASE_URL and generate SECRET_KEY_BASE
make setup
make server
```

- Web UI: http://localhost:4410
- Admin panel: http://localhost:4410/admin
- DNS server listens on UDP port **5354** by default

Test DNS resolution:

```bash
dig @127.0.0.1 -p 5354 google.com
# second request serves from cache
dig @127.0.0.1 -p 5354 google.com
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `DNS_PORT` | `5354` | UDP port for DNS server |
| `DNS_UPSTREAMS` | `8.8.8.8:53,8.8.4.4:53` | Comma-separated upstream DNS servers |
| `PHX_PORT` / `PORT` | `4410` | Web UI port |
| `PHX_HOST` | `localhost` | Hostname for URL generation |
| `DATABASE_URL` | (dev default) | PostgreSQL connection string |
| `SECRET_KEY_BASE` | (required) | Phoenix secret key |
| `ADMIN_USERNAME` | (none) | Admin username (created on startup) |
| `ADMIN_PASSWORD` | (none) | Admin password |
| `SENTRY_DSN` | (none) | GlitchTip/Sentry DSN for error tracking |

## Architecture

```
Client DNS query (UDP)
        |
  DNS.Server (GenServer, :gen_udp)
        |
  DNS.Blocklist (ETS: exact + wildcard + regex)
        |  blocked? --> return 0.0.0.0 / NXDOMAIN
        |  allowed? v
  DNS.Cache (ETS, configurable TTL)
        |  hit? --> return cached response
        |  miss? v
  DNS.Resolver (race 2 upstreams, fallback to rest)
        |
  DNS.SpeedTracker (weighted upstream selection)
        |
  DNS.QueryLog (ETS, PubSub broadcast)
        |
  LiveView admin panel (real-time updates)
```

### Key Modules

| Module | Role |
|---|---|
| `EliHole.DNS.Server` | UDP listener (GenServer, `:gen_udp`) |
| `EliHole.DNS.Resolver` | Race resolution + fallback forwarding |
| `EliHole.DNS.Cache` | ETS response cache with TTL |
| `EliHole.DNS.Blocklist` | ETS-backed domain blocking (exact/wildcard/regex) |
| `EliHole.DNS.SpeedTracker` | Upstream latency tracking + weighted selection |
| `EliHole.DNS.Gravity` | Scheduled adlist download and sync |
| `EliHole.DNS.QueryLog` | ETS query history + PubSub broadcast |
| `EliHole.DNS.Teleporter` | Pi-hole/EliHole backup import/export |
| `EliHole.DNS.Providers` | Upstream DNS provider CRUD |
| `EliHole.Accounts` | Admin user management |

## Docker

```bash
# Generate secret key (no local Elixir needed)
export SECRET_KEY_BASE=$(openssl rand -base64 48)

# Start app + Postgres
docker compose up -d

# Run migrations (required on first start)
docker compose exec app bin/eli_hole eval "EliHole.Release.migrate()"
```

Ports: `4000` (web), `53/udp` (DNS, mapped from container's 5354).

Override admin credentials (default `admin`/`admin` — change for production):

```bash
ADMIN_USERNAME=myadmin ADMIN_PASSWORD=secret docker compose up -d
```

> **Note:** The default prod config assumes HTTPS via reverse proxy. For local Docker testing without TLS, LiveView websockets may fail. Use a reverse proxy (Caddy/nginx/Traefik) or adjust `PHX_HOST` accordingly.

## Production (bare metal)

```bash
DNS_PORT=53 PHX_SERVER=true bin/eli_hole start
```

Note: binding to port 53 requires root or `CAP_NET_BIND_SERVICE`.

## TODO

### Core DNS
- [ ] **Whitelist** — allow specific domains to bypass blocklist
- [ ] **CNAME deep inspection** — detect blocked domains hiding behind CNAMEs
- [ ] **DNS-over-HTTPS (DoH)** — accept DoH queries
- [ ] **DNS-over-TLS (DoT)** — accept DoT queries
- [ ] **DNSSEC validation** — validate/proxy DNSSEC responses
- [ ] **Rate limiting** — per-client query throttling
- [ ] **Conditional forwarding** — route specific domains to specific upstreams

### Admin Panel
- [ ] **Query log filtering** — filter by client, domain, status, type
- [ ] **Time-series chart** — queries over time on dashboard
- [ ] **Pause blocking** — "disable for N minutes" toggle
- [ ] **Client groups** — group clients with different blocklist rules
- [ ] **Query log persistence** — store history in Postgres (currently ETS, lost on restart)
- [ ] **Long-term statistics** — daily/weekly/monthly aggregates

### Operations
- [x] **Dockerfile** — multi-stage build with docker-compose (app + Postgres)
- [ ] **Health check endpoint** — `GET /api/health`
- [ ] **Prometheus metrics** — export via `/metrics`
- [ ] **Systemd unit** — production service file
- [ ] **LiveView tests** — currently zero LiveView test coverage
- [ ] **CI pipeline** — GitHub Actions / Forgejo Actions

### Polish
- [ ] **Dark/light theme toggle** — currently dark only
- [ ] **Mobile responsive nav** — hamburger menu for small screens
- [ ] **Notification on gravity failure** — alert when adlist download fails
- [ ] **API for external integrations** — REST/JSON API for blocklist/stats
