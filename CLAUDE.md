## Startup

- **Always** read `AGENTS.md` before starting work on this project

## Project

EliHole — DNS sinkhole on Elixir/Phoenix (Pi-hole analog). UDP DNS server + LiveView admin panel.

## Key modules

- `EliHole.DNS.Server` — UDP listener (GenServer, `:gen_udp`)
- `EliHole.DNS.Resolver` — upstream forwarding + cache integration
- `EliHole.DNS.Cache` — ETS cache with configurable TTL
- `EliHole.DNS.QueryLog` — ETS query history + PubSub broadcast
- `EliHole.DNS.Whitelist` — ETS allowlist, `allowed?/1` bypasses blocklist
- `EliHoleWeb.QueryLogLive` — real-time admin panel at `/admin/queries`

## Dev

- `make server` — start with hot reload (loads `.env`)
- `make precommit` — **always** run after finishing changes, fix all issues before reporting done
- **Never** run `mix` commands directly — use `make` targets (they load `.env` with DB credentials)
- DNS default port: 5354 (avoid 5353 = mDNS)
- Test: `dig @127.0.0.1 -p 5354 google.com`

## Feature workflow

Each feature (often a `README.md` TODO line) follows this loop:

1. **Read context first** — inspect the modules the feature touches (resolver/cache/blocklist/etc.) before writing code. Find the exact integration point.
2. **Implement** at the right layer; reuse existing helpers/components instead of duplicating (e.g. extract a shared predicate, reuse the `nav_item`/`theme_toggle` components).
3. **Add tests** — new `test/.../*_test.exs`, DB-backed via `EliHole.DataCase`. Cover happy path, the override/negative cases, AND the real integration path (e.g. spin an ephemeral UDP upstream — don't only test the cache-hit shortcut).
4. **`make precommit`** — must be green (format + credo + sobelow + full test suite). Pre-existing sobelow warnings (CSP, settings_live path traversal) are not from new work; don't chase them.
5. **`task-reviewer`** (Task tool) — mandatory before reporting done on any code change. Address findings; minor/nit may be deferred with justification.
6. **Update docs** — remove the done TODO line, add a feature bullet to `README.md`, update the module description in `AGENTS.md`.

Conventions:
- Resolver return tuple is `{status, upstream, response}` where status ∈ `:ok | :blocked | :error`; `EliHoleWeb` Server destructures it for QueryLog. Keep new code-paths to this shape.
- Whitelist always overrides blocklist — route block decisions through a single `blocked_domain?/1`-style predicate (`blocked? and not allowed?`).
- DNS packets: build/decode with `:inet_dns`; `:inet_dns.encode/1` may return a bare binary OR `{:ok, binary}` — handle both.
