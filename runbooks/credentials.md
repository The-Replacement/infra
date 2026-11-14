# Credentials: the map

Five credentials exist. Four of them can act on production. This file is the
index, not the storage: values live on disk at 0600 or in a password manager,
never here.

| Credential | Scope | Lives | Can do | Expires |
|---|---|---|---|---|
| GitHub CLI token (`gh`) | `repo`, `workflow`, `project`, `read:org` | `~/.config/gh/hosts.yml` | push, merge, run workflows, edit issues and the board | n/a (OAuth) |
| SSH key → mainframe | shell as `kbdejavu` | `~/.ssh/id_ed25519_new` | deploy (`git push mainframe`), read the station | n/a |
| Cloudflare master token | 28 permission groups incl. `account_api_tokens: edit` | `~/.config/radio/cf-token` | **anything**, including minting more tokens | set at creation |
| Cloudflare `pages-ci` | `Pages: Write` only | `~/.config/radio/cf-pages-ci` | create/deploy Pages projects | 2027-02-12 |
| Cloudflare MCP OAuth | `user:read`, `account:read` | opencode MCP store | read account metadata. **Not Pages** | token lifetime |

Two dead ends worth knowing, because they look alive:

- **The Cloudflare MCP** is connected with 3042 tools and refuses `pages_*` with
  `requires user authorization`. Its scopes are dictated by the MCP server
  (`user:read account:read`); `opencode mcp auth` has no flag to widen them.
  Useful for reading the account, useless for Pages.
- **The wrangler OAuth login** on the workstation expires and fails with
  `Authentication error` mid-session. It is not a fallback for CI.

There is also a **disabled, read-only GitHub deploy key** titled
`mainframe-radio-deploy` on `radio`. Deploys work by pushing to the host over
SSH, not by that key. Decide whether it is a leftover and delete it, or the
intended mechanism and enable it.

## Rules

1. **The master token is used once, then put away.** Its only job is to mint
   narrow tokens. It never goes into CI, a repo, a `.env`, or a chat log.
2. **CI gets the narrowest token that works.** `pages-ci` cannot mint tokens and
   cannot touch DNS. Verified: `GET /accounts/<id>/tokens` returns `9109`.
3. **A token that expires during an incident is worse than no token.** Record the
   expiry next to the credential, and let `deploy/health.sh` warn before it lapses.
4. **Rotation is a rotation, not an addition.** Create the new one, deploy it,
   then delete the old one — in that order, or twice in a row.

## Minting the next narrow token

```bash
# list permission groups (needs a token with account API Tokens: Read)
curl -s -H "Authorization: Bearer $(cat ~/.config/radio/cf-token)" \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT/tokens/permission_groups" |
  jq -r '.result[] | select(.name|test("Pages|DNS|Tunnel")) | "\(.id)  \(.name)"'
```

Useful IDs on this account:

| Permission group | ID |
|---|---|
| Pages Write | `8d28297797f24fb8a0c332fe0866ec89` |
| Pages Read | `e247aedd66bd41cc9193af0213416666` |
| Account API Tokens Write | `5bc3f8b21c554832afc660159ab75fa4` |
| Account Settings Write | `1af1fa2adc104452b74a9a3364202f20` |

## Reading the state without a secret

`deploy/health.sh` verifies every `cf-*` file under `~/.config/radio/` and prints
`OK`/`RED` per credential. It never prints a value.
