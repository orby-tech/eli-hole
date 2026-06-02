SHELL := /bin/bash
export PATH := $(HOME)/.asdf/bin:$(HOME)/.asdf/shims:$(PATH)

define load_env
	set -a && [ -f .env ] && source .env && set +a
endef

.PHONY: setup server iex deps db.create db.migrate db.rollback db.reset db.seed test test.watch routes clean gen.secret gen.migration gen.context gen.live precommit lint dialyzer dev.validate dev.validate.encrypted git.pull deploy.build deploy.build.nocache deploy.up deploy.prune deploy.ps deploy.logs deploy.restart deploy.migrate deploy.down update update.hard update.nobuild update.restart redeploy redeploy.hard redeploy.nobuild redeploy.restart

# Compose binary: v2 plugin by default. Override: make update COMPOSE=docker-compose
COMPOSE ?= docker compose
# Service to (re)build/restart on deploy.
APP_SERVICE ?= app

setup: deps hooks.install db.create db.migrate

# ── Deploy building blocks (compose into update variants below) ─────────────
git.pull:
	git pull --ff-only

deploy.build:
	$(COMPOSE) build $(APP_SERVICE)

deploy.build.nocache:
	$(COMPOSE) build --no-cache --pull $(APP_SERVICE)

deploy.up:
	$(COMPOSE) up -d

deploy.prune:
	docker image prune -f

deploy.ps:
	$(COMPOSE) ps

deploy.restart:
	$(COMPOSE) restart $(APP_SERVICE)

# Run migrations inside the running app container. Normally redundant — the
# entrypoint runs EliHole.Release.migrate() on every (re)start — but useful to
# apply migrations WITHOUT a restart, or after a `*.nobuild` no-op `up -d`.
deploy.migrate:
	$(COMPOSE) exec $(APP_SERVICE) bin/eli_hole eval "EliHole.Release.migrate()"

deploy.down:
	$(COMPOSE) down

# Follow app logs (e.g. after an update).
deploy.logs:
	$(COMPOSE) logs -f $(APP_SERVICE)

# ── Update variants (migrations auto-run on release boot via rel/overlays) ──
# Default: pull code, rebuild app image (layer cache), recreate, prune dangling.
update: git.pull deploy.build deploy.up deploy.prune deploy.ps

# Clean rebuild: no Docker layer cache, re-pull base images. Use when cache stale.
update.hard: git.pull deploy.build.nocache deploy.up deploy.prune deploy.ps

# Pull code + recreate WITHOUT rebuilding (e.g. image comes from a registry).
# Explicit migrate: a no-op `up -d` won't recreate the container → no entrypoint.
update.nobuild: git.pull deploy.up deploy.migrate deploy.ps

# Pull code + just restart the app container (config/env-only change, no rebuild).
update.restart: git.pull deploy.restart deploy.ps

# ── Redeploy variants (no git pull — use current working tree / pushed image) ─
# Rebuild app image from current tree, recreate, prune dangling.
redeploy: deploy.build deploy.up deploy.prune deploy.ps

# Clean rebuild (no cache) from current tree.
redeploy.hard: deploy.build.nocache deploy.up deploy.prune deploy.ps

# Recreate WITHOUT rebuild (e.g. pull newer image from registry first).
redeploy.nobuild: deploy.up deploy.migrate deploy.ps

# Restart only — no pull, no rebuild (env/config-only change already on disk).
redeploy.restart: deploy.restart deploy.ps

dev.validate:
	dig @127.0.0.1 -p 5354 google.com
	dig @127.0.0.1 -p 5354 glitchtip.orby-tech.space
	dig @127.0.0.1 -p 5354 getnodejs.com
	dig @127.0.0.1 -p 5354 banne4s.ero-advertising.com
	dig @127.0.0.1 -p 5354 analytics.google.com
	# DNSSEC-signed → expect "secure" in the admin DNSSEC column
	dig @127.0.0.1 -p 5354 cloudflare.com
	dig @127.0.0.1 -p 5354 ietf.org
	dig @127.0.0.1 -p 5354 nlnetlabs.nl
	dig @127.0.0.1 -p 5354 internetsociety.org

# Smoke-test the encrypted transports (DoH over PHX_PORT, DoT over DOT_PORT).
# DoT requires DOT_CERT_PATH/DOT_KEY_PATH set + server restarted; needs kdig.
dev.validate.encrypted:
	@$(load_env) && ./scripts/validate-encrypted-dns.sh

server:
	@$(load_env) && mix phx.server

iex:
	@$(load_env) && iex -S mix phx.server

deps:
	mix deps.get
	mix assets.setup

db.create:
	@$(load_env) && mix ecto.create

db.migrate:
	@$(load_env) && mix ecto.migrate

db.rollback:
	@$(load_env) && mix ecto.rollback

db.reset:
	@$(load_env) && mix ecto.reset

db.seed:
	@$(load_env) && mix run priv/repo/seeds.exs

test:
	@$(load_env) && mix test

test.watch:
	@$(load_env) && mix test --stale --listen-on-stdin

# Run a single test file/dir: make test.one FILE=test/path/to_test.exs
test.one:
	@$(load_env) && mix test $(FILE)

# Run tests writing full output to a file we control (bypasses stdout wrappers).
# Usage: make test.log ARGS="--seed 123"  -> reads /tmp/claude/elixir_test.log
test.log:
	@$(load_env) && set -o pipefail && mix test $(ARGS) 2>&1 | tee /tmp/claude/elixir_test.log

routes:
	@$(load_env) && mix phx.routes

clean:
	mix clean
	rm -rf _build deps

gen.secret:
	mix phx.gen.secret

gen.migration:
	@$(load_env) && mix ecto.gen.migration $(NAME)

gen.context:
	@$(load_env) && mix phx.gen.context $(ARGS)

gen.live:
	@$(load_env) && mix phx.gen.live $(ARGS)

hooks.install:
	cp scripts/pre-commit .git/hooks/pre-commit
	chmod +x .git/hooks/pre-commit

precommit:
	@$(load_env) && mix precommit

lint:
	@$(load_env) && mix format --check-formatted
	@$(load_env) && mix compile --warnings-as-errors
	@$(load_env) && mix credo --strict
	@$(load_env) && mix sobelow --config

dialyzer:
	@$(load_env) && mix dialyzer

dnssec.demo:
	@$(load_env) && mix run priv/dnssec/demo.exs
