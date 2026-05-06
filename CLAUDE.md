# CLAUDE.md - Claude Code instructions

See README.md for project overview, customization guide, and setup.

## Build & Validate

```bash
shellcheck -x ethd scripts/check_sync.sh
pre-commit run --all-files
cp default.env .env && ./ethd update --debug --non-interactive
```

## Code Style

- Shell: `set -Eeuo pipefail` in ethd, `set -euo pipefail` in other scripts
- Env vars: `SCREAMING_SNAKE_CASE`, no dashes (breaks bash)
- Env var suffixes: `_TAG` / `_REPO` / `_DOCKERFILE` = build targets (reset by `--refresh-targets`)
- Env var suffixes: `_PORT` for network ports
- Compose services: kebab-case; CLI commands: kebab-case; bash functions: snake_case

## Critical Rules

- Do NOT modify core infrastructure functions in `ethd` — customize only protocol-specific sections marked with comments
- Increment `ENV_VERSION` in `default.env` when adding or renaming variables
- check_sync.sh exit codes: 0=synced, 1=syncing, 2=diverged, 3=local RPC error, 4=public RPC error, 5=config error, 6=dependency error, 7=container error
- New env vars consumed by entrypoint.sh must also be added to the compose `environment:` block
- Test update flow after any env/migration changes: `cp default.env .env && ./ethd update --debug`
- 0G release variables use `ZEROG_*`; do not create env vars starting with a digit.
- Keep the release archive SHA256 pinned when changing `ZEROG_VERSION`.

## Key Customization Points in ethd

- Header vars: `__project_name`, `__app_name`, `__sample_service`
- Functions: `version()`, `__prep_conffiles()`, `start()`, `__env_migrate()`

## Production References

- `sei-docker` — Cosmos/Tendermint with cosmovisor
- `optimism-docker` — L2 rollup, multi-service
- `polygon-docker` — Multi-client EVM
