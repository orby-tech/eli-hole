# EliHole

DNS sinkhole built with Elixir and Phoenix. Like Pi-hole, but in Elixir.

## Features

- UDP DNS server with upstream forwarding (Google DNS by default)
- DNS response caching with configurable TTL (default 300s)
- Real-time query log with LiveView admin panel
- Query statistics (total / resolved / failed)
- Cache management from admin UI (set TTL, flush cache)
- Cache hits show original upstream: `cache (8.8.8.8)`

## Quick Start

```bash
mix setup
mix phx.server
```

- Web UI: http://localhost:4000
- Admin panel: http://localhost:4000/admin/queries
- DNS server listens on UDP port **5354** by default

Test DNS resolution:

```bash
dig @127.0.0.1 -p 5354 google.com
# second request serves from cache
dig @127.0.0.1 -p 5354 google.com
```

## Configuration

Environment variables:

| Variable | Default | Description |
|---|---|---|
| `DNS_PORT` | `5354` | UDP port for DNS server |
| `DNS_UPSTREAMS` | `8.8.8.8:53,8.8.4.4:53` | Comma-separated upstream DNS servers |
| `PHX_PORT` / `PORT` | `4000` | Web UI port |
| `DATABASE_URL` | (dev default) | PostgreSQL connection string |
| `SENTRY_DSN` | (none) | GlitchTip/Sentry DSN for error tracking |

Cache TTL is configurable at runtime from the admin panel (`/admin/queries`).

Example with custom upstreams:

```bash
DNS_PORT=53 DNS_UPSTREAMS="1.1.1.1:53,9.9.9.9:53" mix phx.server
```

## Architecture

```
Client DNS query (UDP)
        |
  DNS.Server (GenServer, :gen_udp)
        |
  DNS.Cache (ETS, configurable TTL)
        |  hit? → return cached response
        |  miss? ↓
  DNS.Resolver (forward to upstream, cache response)
        |
  DNS.QueryLog (ETS, PubSub broadcast)
        |
  QueryLogLive (real-time LiveView)
```

## Production

```bash
DNS_PORT=53 PHX_SERVER=true bin/eli_hole start
```

Note: binding to port 53 requires root or `CAP_NET_BIND_SERVICE`.
