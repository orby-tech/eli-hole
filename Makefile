SHELL := /bin/bash
export PATH := $(HOME)/.asdf/bin:$(HOME)/.asdf/shims:$(PATH)

define load_env
	set -a && [ -f .env ] && source .env && set +a
endef

.PHONY: setup server iex deps db.create db.migrate db.rollback db.reset db.seed test test.watch routes clean gen.secret gen.migration gen.context gen.live precommit lint dialyzer

setup: deps hooks.install db.create db.migrate

dev.validate:
	dig @127.0.0.1 -p 5354 google.com
	dig @127.0.0.1 -p 5354 glitchtip.orby-tech.space


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
