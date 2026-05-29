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

### Local DNS
- Custom domain-to-IP mappings (A, AAAA, CNAME records)
- ETS-backed lookup — resolved before upstream forwarding
- Admin UI at `/admin/local-dns` with CRUD, search, pagination
- Bulk import from Pi-hole `custom.list` / `/etc/hosts` format
- Included in teleporter export/import

### Blocking
- **Exact match** — `ads.example.com`
- **Wildcard match** — `*.example.com` blocks all subdomains
- **Regex match** — `/(ads|tracking)\..*\.com/`
- ETS-backed lookup for sub-millisecond blocking decisions
- Manual blocklist entry CRUD with search and pagination
- Bulk import from hosts-file or domain-list formats

### Whitelist
- **Allowlist** — whitelisted domains always bypass the blocklist, even when a blocklist rule matches
- Same matching modes as blocking: exact / wildcard / regex
- ETS-backed lookup, evaluated before serving a blocked response
- Admin UI at `/admin/whitelist` with CRUD, search, pagination, bulk domain import
- Included in teleporter export/import and cluster sync

### Gravity (Adlist Sync)
- Subscribe to remote adlist URLs (same format as Pi-hole)
- Scheduled auto-update every 24 hours
- Manual "Update Now" from admin UI
- Concurrent download (up to 4 lists in parallel)
- Deduplication via `ON CONFLICT DO NOTHING`
- Per-adlist domain count tracking

### Cluster (Master-Slave)
- **Push-based replication** — master pushes config to slaves on change
- **Stats aggregation** — slaves push query stats to master every 30s
- **Auto-registration** — slaves register with master on startup, get initial config
- **Debounced sync** — rapid config changes coalesced into single push (3s window)
- **Health monitoring** — master tracks slave status, marks offline after 120s
- **Synced data**: adlists, custom blocklist entries, local DNS records, upstreams, cache TTL
- Slaves run gravity independently with synced adlist URLs
- Admin UI at `/admin/cluster` — add/remove nodes, view status, trigger manual push
- API key auth via `X-Cluster-Key` header
- Roles: `standalone` (default), `master`, `slave` — set via `INSTANCE_ROLE` env var

### Teleporter (Import/Export)
- Import Pi-hole teleporter backups (`.tar.gz`)
  - Blacklists (exact + regex), whitelists (exact + regex), DNS providers, adlists, local DNS (`custom.list`)
  - Reports skipped items (clients, groups)
- Import EliHole's own backups (blocklist + whitelist + providers + local DNS)
- Export current config as `.tar.gz` (blocklist + whitelist entries + providers + local DNS)
- Auto-detect backup format (Pi-hole vs EliHole)

### Admin Panel (LiveView)
- **Dashboard** (`/admin`) — total queries, resolved/blocked/failed counts, queries/sec, top domains, top clients, cache stats, fastest upstream
- **Query Log** (`/admin/queries`) — real-time query stream via PubSub, per-query status/timing/upstream
- **Blocklist** (`/admin/blocklist`) — search, add/edit/delete entries, toggle enable/disable, pagination
- **Whitelist** (`/admin/whitelist`) — allowlist domains that bypass the blocklist; search, CRUD, bulk import, pagination
- **Gravity** (`/admin/gravity`) — adlist management, add/remove URLs, trigger update, view status
- **Local DNS** (`/admin/local-dns`) — custom domain records (A/AAAA/CNAME), bulk import, search
- **Cluster** (`/admin/cluster`) — master: add/remove slave nodes, view stats, push config; slave: connection status; standalone: setup instructions
- **Settings** (`/admin/settings`) — upstream DNS providers (presets: Google/Cloudflare/Quad9 + custom), cache TTL, flush cache, upstream speed table, teleporter import/export

### Auth
- Admin user via `ADMIN_USERNAME` / `ADMIN_PASSWORD` env vars (min 8 chars for password)
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
| `PHX_SCHEME` | `http` | URL scheme (`http` or `https` behind reverse proxy) |
| `DATABASE_URL` | (dev default) | PostgreSQL connection string |
| `SECRET_KEY_BASE` | (required) | Phoenix secret key |
| `ADMIN_USERNAME` | (none) | Admin username (created on startup) |
| `ADMIN_PASSWORD` | (none) | Admin password (min 8 characters) |
| `FORCE_SSL` | `false` | Set `true` behind TLS-terminating reverse proxy |
| `SENTRY_DSN` | (none) | GlitchTip/Sentry DSN for error tracking |
| `INSTANCE_ROLE` | `standalone` | Cluster role: `master`, `slave`, or `standalone` |
| `CLUSTER_API_KEY` | (none) | Shared secret for cluster API auth |
| `CLUSTER_MASTER_URL` | (none) | Master URL (slave only), e.g. `http://master:4000` |
| `INSTANCE_NAME` | auto | Node name for cluster identification |
| `INSTANCE_URL` | (none) | This instance's URL reachable by master (slave only) |

## Architecture

```
Client DNS query (UDP)
        |
  DNS.Server (GenServer, :gen_udp)
        |
  DNS.Blocklist (ETS: exact + wildcard + regex)
        |  blocked? --> return 0.0.0.0 / NXDOMAIN
        |  allowed? v
  DNS.LocalDNS (ETS: custom A/AAAA/CNAME records)
        |  local match? --> return custom response
        |  no match? v
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
| `EliHole.DNS.Whitelist` | ETS-backed allowlist; bypasses blocklist (exact/wildcard/regex) |
| `EliHole.DNS.SpeedTracker` | Upstream latency tracking + weighted selection |
| `EliHole.DNS.Gravity` | Scheduled adlist download and sync |
| `EliHole.DNS.QueryLog` | ETS query history + PubSub broadcast |
| `EliHole.DNS.LocalDNS` | Custom local domain records (ETS GenServer) |
| `EliHole.DNS.Teleporter` | Pi-hole/EliHole backup import/export |
| `EliHole.DNS.Providers` | Upstream DNS provider CRUD |
| `EliHole.DNS.Cluster` | Cluster context: config export/import, node CRUD, push logic |
| `EliHole.DNS.ClusterManager` | Master GenServer: PubSub → debounced push to slaves, stats ETS |
| `EliHole.DNS.ClusterSync` | Slave GenServer: register with master, push stats periodically |
| `EliHole.Accounts` | Admin user management |

## Docker

App runs with `network_mode: host` for low-latency UDP — binds directly to host ports.

```bash
cp .env.example .env
# edit .env: set SECRET_KEY_BASE, ADMIN_USERNAME, ADMIN_PASSWORD

# Start app + Postgres
docker compose up -d
```

Migrations run automatically on startup. Ports are configured via `.env`:

| Variable | Default | Description |
|---|---|---|
| `PHX_PORT` | `4410` | Web UI port on host |
| `DNS_PORT` | `5354` | DNS UDP port on host |

Postgres binds to `127.0.0.1:5432` only (not exposed externally).

Default admin credentials: `admin` / `administrator` — change via env vars for production.

### Cluster Demo (Master + 2 Slaves)

```bash
docker compose -f docker-compose.demo.yml up --build
```

Opens 3 instances on a bridge network:

| Instance | Web UI | DNS |
|---|---|---|
| Master | http://localhost:4410 | `dig @127.0.0.1 -p 5354 google.com` |
| Slave 1 | http://localhost:4411 | `dig @127.0.0.1 -p 5355 google.com` |
| Slave 2 | http://localhost:4412 | `dig @127.0.0.1 -p 5356 google.com` |

Login: `admin` / `administrator`. Open `/admin/cluster` on each instance to see cluster status.

**Demo flow:**
1. Add an adlist or blocklist entry on master
2. Config auto-pushes to both slaves (~3s debounce)
3. Query DNS on slaves → stats appear on master's Cluster page

### Redirect port 53 to EliHole

Standard DNS uses port 53. To redirect external DNS traffic to EliHole without running as root:

```bash
# Redirect incoming port 53 to EliHole (exclude Docker subnet)
sudo iptables -t nat -A PREROUTING -p udp --dport 53 ! -s 172.16.0.0/12 -j REDIRECT --to-port 5354

# Make persistent
sudo apt install iptables-persistent -y
sudo netfilter-persistent save
```

Then set your router's DHCP DNS to the host IP.

### Set as system DNS (Linux)

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
echo -e "[Resolve]\nDNS=192.168.12.135\nDNSOverTLS=no" | sudo tee /etc/systemd/resolved.conf.d/elihole.conf
sudo systemctl restart systemd-resolved
```

## Production (bare metal)

```bash
DNS_PORT=53 PHX_SERVER=true bin/eli_hole start
```

Note: binding to port 53 requires root or `CAP_NET_BIND_SERVICE`.

## TODO

### Core DNS
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
