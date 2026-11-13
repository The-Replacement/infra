# Runbook: credential rotation

Five distinct things can leak, and they do not have the same blast radius. Do
not rotate everything because one thing leaked; do rotate the one thing before
you finish reading this page.

| Secret | Where it lives | What it grants | Blast radius |
|---|---|---|---|
| Listener token + cookie | `secrets/tokens.txt`, `caddy/tokens.caddy` (host, mode 0600) | One listener's access to stream, camera, playlist | That listener, nothing else |
| `ICECAST_SOURCE_PASSWORD` | host `.env` + Icecast env | Ability to *publish* to the stream | Anyone who has it can hijack the broadcast |
| `ICECAST_ADMIN_PASSWORD` | host `.env` + Icecast env | Icecast admin endpoints | Kick sources, read stats |
| Cloudflare API token | CI secret / workstation | Publish the page | Defacement of `radio.daza.ar` |
| SSH key / deploy key | workstation, GitHub repo settings | Shell on the host, or read access to a repo | The host itself |

## Listener credentials (the common case)

```bash
./scripts/token.sh ls                    # who has access
./scripts/token.sh rotate <name>         # revoke this person's token and cookie, issue new
./scripts/token.sh rm <name>             # revoke without issuing
./scripts/token.sh prune                 # drop expired entries from storage
```

`rotate` writes both stores and regenerates Caddy's matcher. It ends with a
Caddy reload; verify it happened:

```bash
docker compose -f ~/servers/radio/docker-compose.yml logs --tail=20 caddy | grep -i reload
```

Rotation invalidates the old token **and** the old cookie in one step — a
listener who is mid-playback is cut on their next request, not at the end of the
track.

## Icecast passwords

If `ICECAST_SOURCE_PASSWORD` leaked, assume the stream can be hijacked until
rotated. On the host:

1. Edit `.env` (mode 0600), change `ICECAST_SOURCE_PASSWORD`.
2. `docker compose up -d icecast` — Icecast reads its passwords from the
   environment at start, so this is a recreate, not a restart.
3. Liquidsoap reconnects on its own; confirm the source is connected:
   `docker compose logs --tail=30 liquidsoap | grep -i connected`.

This **does** interrupt the stream for a few seconds. Do it deliberately, not in
the middle of something.

## Cloudflare API token

Cannot be created with the wrong scope and then fixed in place: create the new
one, update the secret, deploy once, then delete the old one. If it is being
rotated because of exposure, delete **before** deploying the replacement.

## SSH / deploy keys

```bash
# On the host: what is authorised right now
cat ~/.ssh/authorized_keys

# GitHub side: deploy keys and their state
gh api /repos/The-Replacement/radio/keys --jq '.[] | {id, title, read_only, enabled, last_used}'
```

The `mainframe-radio-deploy` deploy key exists, is read-only and is currently
**disabled**. Either it is a leftover from the migration or it is the intended
mechanism and was never enabled. Decide which before deleting it: removing a key
that the host uses to fetch will break the next deploy in a way that looks like
a network problem.

## After any rotation

1. Update the place the secret is *used* (host `.env`, CI secret), not just the
   place it is stored.
2. Confirm the old value is rejected — try it once, on purpose.
3. If the leak came from a git commit, the credential is compromised even after
   rotation: rewrite history or accept that it is public. Assume public.
