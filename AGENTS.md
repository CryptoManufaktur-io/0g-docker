# Repository instructions

See README.md for project overview, setup, ports, and runtime commands.

## Project Structure

- `0g.yml` is the primary compose file; keep service names `init`, `geth`, and `0gchaind`.
- `rpc-shared.yml` exposes loopback RPC/debug ports; `ext-network.yml` attaches runtime services to Traefik.
- `node/Dockerfile.binary` builds from the pinned Aristotle release archive.
- `node/entrypoint.sh` owns `init`, `run-geth`, and `run-0gchaind` modes.
- `scripts/check_sync.sh` compares local geth JSON-RPC to `PUBLIC_RPC`.
- `ethd` is the canonical wrapper; `0gd` is a symlink to `ethd`.
- `CLAUDE.md` is a symlink to this file; update `AGENTS.md` only.

## Validation

- Run `shellcheck -x ethd scripts/check_sync.sh node/entrypoint.sh` after shell edits.
- Run `pre-commit run --all-files` before committing.
- Run `docker compose --env-file default.env -f 0g.yml config` after compose/env edits.
- Run `docker compose --env-file default.env -f 0g.yml -f rpc-shared.yml config` after port edits.
- Run `docker compose --env-file default.env -f 0g.yml -f ext-network.yml config` after Traefik/network edits.
- Run `cp default.env .env && ./ethd update --debug --non-interactive` after env or migration changes when Docker is available.
- Use a Linux Docker host for image smoke tests; upstream binaries are linux/amd64.

## Code Style

- Keep `set -Eeuo pipefail` in `ethd`; keep `set -euo pipefail` or stricter in other scripts.
- Use `SCREAMING_SNAKE_CASE` env vars; never use dashes.
- Use `ZEROG_*` for 0G release variables; env var names must not start with a digit.
- Use `_TAG`, `_REPO`, or `_DOCKERFILE` only for build targets reset by `--refresh-targets`.
- Use `_PORT` suffixes for port variables.

## Critical Rules

- Do not edit core infrastructure functions in `ethd`; change only protocol-specific sections.
- Increment `ENV_VERSION` in `default.env` when adding or renaming env vars.
- Every env var consumed by `node/entrypoint.sh` must be present in `0g.yml` environment.
- Keep `ZEROG_RELEASE_SHA256` pinned and update it whenever `ZEROG_VERSION` changes.
- Keep `AUTH_RPC_PORT` wired to geth `AuthPort` and 0gchaind `--chaincfg.engine.rpc-dial-url`.
- Keep `GETH_ENGINE_HOST=geth` unless compose service names change.
- `P2P_EXTERNAL_IP` must be empty, `auto`, or a public IPv4 address; never set it to a Docker service name.
- Port variables set both container listen ports and host-published ports.
- Do not add a source-build Dockerfile unless a compose path uses and validates it.
