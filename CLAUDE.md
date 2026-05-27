## Startup

- **Always** read `AGENTS.md` before starting work on this project

## Project

EliHole — DNS sinkhole on Elixir/Phoenix (Pi-hole analog). UDP DNS server + LiveView admin panel.

## Key modules

- `EliHole.DNS.Server` — UDP listener (GenServer, `:gen_udp`)
- `EliHole.DNS.Resolver` — upstream forwarding + cache integration
- `EliHole.DNS.Cache` — ETS cache with configurable TTL
- `EliHole.DNS.QueryLog` — ETS query history + PubSub broadcast
- `EliHoleWeb.QueryLogLive` — real-time admin panel at `/admin/queries`

## Dev

- `make server` — start with hot reload (loads `.env`)
- `make precommit` — **always** run after finishing changes, fix all issues before reporting done
- **Never** run `mix` commands directly — use `make` targets (they load `.env` with DB credentials)
- DNS default port: 5354 (avoid 5353 = mDNS)
- Test: `dig @127.0.0.1 -p 5354 google.com`

## Docs maintenance

- Keep `README.md` and `AGENTS.md` up to date when adding/changing features
