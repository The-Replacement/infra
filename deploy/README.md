# deploy

Bootstrap and inventory for the production host (`mainframe`, `192.168.100.148`).

Nothing in this directory runs automatically. There is no CI on the host and no
agent with a key to it.

## Contents

| File | What it does |
|---|---|
| `audit-mainframe.sh` | Read-only inventory of the host: hardware, thermal, memory, systemd, Docker, cron, disk, network. Run it first. |
| `measure-runtime.sh` | Samples per-container CPU/memory for a bounded window while the stack runs. Produces the input for the resource budget. |
| `compose.env.template` | The variable names the radio stack needs, with no values. |

## Order of operations, when the box comes back

1. **Physical check before power.** Dust, fan spin by hand, cables seated. The
   box went down hot; a restart into the same airflow problem measures nothing.
2. Boot, wait for the fans to settle, leave it idle for ten minutes.
3. `./audit-mainframe.sh > audit-$(date +%F).txt`
4. `./measure-runtime.sh 300 > runtime-$(date +%F).txt` — the stack must be up
   for this one.
5. Only then decide what stays, what moves and what gets capped. The
   `appliance/` documents in `The-Replacement/docs` say what the numbers mean.

## Why the audit is not part of the deploy

The deploy path is `git push mainframe master` (see
`../runbooks/deploy.md`). The audit is the opposite: it looks at the host as it
actually is, including everything that did not come from this repository. Keeping
it out of the deploy hook means it can be run without changing anything.
