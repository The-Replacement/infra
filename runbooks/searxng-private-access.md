# SearxNG: private access path

SearxNG is a search backend used by the workstation's OpenCode MCP integration.
It must not be reachable from the local network.

## Desired state

| Where | Binding | Who may reach it |
|---|---|---|
| Mainframe container | `127.0.0.1:8080` | the mainframe itself, and SSH-forwarded clients |
| Workstation | `127.0.0.1:8080` | local processes only |

The workstation reaches the mainframe service through a loopback SSH forward.
There is no LAN listener and no authentication to manage on the service itself,
because the service is never exposed beyond loopback.

## Components

- Mainframe: a compose project for the SearxNG service. The image is pinned by
  digest. The published port is bound to `127.0.0.1` only.
- Workstation: a user unit, `searxng-tunnel.service`, that forwards
  `127.0.0.1:8080` on the workstation to `127.0.0.1:8080` on the mainframe over
  SSH. It is long-running and reconnects on failure.
- OpenCode: the SearxNG MCP server reads its endpoint from the local loopback
  address. No project configuration carries the address.

## Verify

```sh
# On the mainframe: the listener must be loopback only.
ss -tlnp | grep 8080
# Expected: 127.0.0.1:8080

# On the workstation: the LAN path must fail, the tunnel must answer.
curl -s -o /dev/null -w '%{http_code}\n' http://<mainframe-lan-address>:8080/   # expect 000
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/                   # expect 200
opencode mcp list | grep searxng                                               # expect connected
```

## Change procedure

The compose file for the service lives outside version control on the host, so
every change to it must be followed by a runbook update in this repository.

1. Back up the compose file before editing it.
2. Keep the image pinned by digest.
3. Keep the published port bound to `127.0.0.1`.
4. Recreate only that service; do not restart unrelated containers.
5. Re-run the verification above, including a real search through the MCP server.

## Deliberate re-exposure

If SearxNG must become reachable from another host, do not publish it on
`0.0.0.0`. Give that host its own SSH forward and keep the service on
loopback. A LAN listener needs a documented owner, a reason and an expiry.
