# 0G Docker

Dockerized 0G Aristotle mainnet archive RPC node for Chainlink/CCIP.

This is 0g-docker v1.0.0

## Network

| Field | Value |
| --- | --- |
| Network | 0G Aristotle mainnet |
| Chain ID | `16661` |
| Native token | `0G` |
| Public RPC | `https://evmrpc.0g.ai` |
| Explorer | `https://chainscan.0g.ai` |

The container runs both upstream 0G clients from the pinned Aristotle release archive:

- `0gchaind` consensus client
- `geth` execution client with archive config

## Requirements

Recommended production host capacity:

- 16 CPU
- 64 GiB RAM
- At least 1 TiB free disk; several TiB is preferred for archive growth

The upstream archive snapshot is large. Use a host with enough free space before setting `SNAPSHOT`.

## Quick Start

```bash
cp default.env .env
nano .env
./0gd up
```

For local RPC access through loopback ports:

```bash
COMPOSE_FILE=0g.yml:rpc-shared.yml ./0gd up
```

For production with Traefik:

```bash
COMPOSE_FILE=0g.yml:ext-network.yml ./0gd up
```

## Configuration

Key variables in `.env`:

| Variable | Description | Default |
| --- | --- | --- |
| `ZEROG_VERSION` | Aristotle release tag without the leading `v` | `1.0.4` |
| `ZEROG_RELEASE_SHA256` | SHA256 for the release archive | pinned in `default.env` |
| `SNAPSHOT` | Optional initial archive snapshot URL | empty |
| `MONIKER` | 0gchaind node moniker | `0g-node` |
| `P2P_EXTERNAL_IP` | Public IPv4 advertised for geth and 0gchaind P2P | empty |
| `RPC_HOST` | Traefik HTTP RPC hostname prefix | `0g` |
| `WS_HOST` | Traefik WebSocket hostname prefix | `0gws` |
| `PUBLIC_RPC` | Reference endpoint used by `check-sync` | `https://evmrpc.0g.ai` |

Production inventory should set `P2P_EXTERNAL_IP` to the host public IP.

## Ports

| Variable | Container Port | Purpose |
| --- | ---: | --- |
| `RPC_PORT` | `8545` | geth HTTP JSON-RPC |
| `WS_PORT` | `8546` | geth WebSocket JSON-RPC |
| `AUTH_RPC_PORT` | `8551` | engine auth RPC |
| `GETH_P2P_PORT` | `30303` | geth P2P TCP/UDP |
| `GETH_METRICS_PORT` | `9001` | geth Prometheus metrics |
| `CL_RPC_PORT` | `26657` | 0gchaind RPC |
| `CL_P2P_PORT` | `26656` | 0gchaind P2P |
| `CL_METRICS_PORT` | `26660` | 0gchaind Prometheus metrics |

Only P2P ports are published by the base compose file. Use `rpc-shared.yml` for local-only RPC/debug ports and `ext-network.yml` for Traefik. Port variables set both the container listen port and the published host port.

## Commands

| Command | Description |
| --- | --- |
| `./0gd up` | Start the node |
| `./0gd down` | Stop the node |
| `./0gd restart` | Restart the node |
| `./0gd logs -f` | Follow logs |
| `./0gd update` | Update images and configuration |
| `./0gd check-sync` | Compare local latest block to public RPC |
| `./0gd version` | Show geth and 0gchaind versions |
| `./0gd space` | Show Docker volume usage |
| `./0gd terminate` | Stop and delete all Docker volumes |

## Sync Check

`./0gd check-sync` defaults to the running `node` compose service and compares geth against `https://evmrpc.0g.ai`.

```bash
./0gd check-sync
./0gd check-sync --block-lag 10
./scripts/check_sync.sh --local-rpc http://127.0.0.1:8545
```

Exit codes:

- `0`: in sync
- `1`: syncing
- `2`: error

## Snapshot Restore

Set `SNAPSHOT` to a supported `.tar.lz4`, `.tar.gz`, `.tar.zst`, or `.tar` archive before first start. The entrypoint extracts it into `/data`, then initializes any missing config, keys, JWT, and geth genesis state.

Snapshot extraction is guarded by `/data/.snapshot-restored`; full initialization is guarded by `/data/.initialized`.

## Validation

```bash
shellcheck -x ethd scripts/check_sync.sh
pre-commit run --all-files
cp default.env .env
./ethd update --debug --non-interactive
```

Use a Linux Docker host for image smoke tests because the upstream binaries are linux/amd64.
