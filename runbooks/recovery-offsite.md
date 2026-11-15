# Runbook: out-of-machine recovery

**What you are trying to avoid:** a single disk failure taking the repository,
the decryption key and every non-derivable secret with it.

The password file and the repository both live on the workstation's disk.
That was true after the first backup and is unacceptable on its own. Two things
fix it without needing anyone to do anything on a future day:

1. **The decryption key is escrowed off-machine** — `deploy/recovery`.
2. **An encrypted archive is mirrored off-machine** — the private repository
   `The-Replacement/radio-backup`, plus a LAN copy on the box.

## 1. How the escrow works

```
deploy/recovery/public.pem                 public RSA-4096 key. Not secret.
deploy/recovery/restic-password.enc        the repo password, RSA-encrypted to
                                           that public key. Ciphertext; safe
                                           to commit.
GitHub secret RADIO_STATE_RECOVERY_KEY     the matching RSA private key.
```

`public.pem` does not decrypt anything. `restic-password.enc` is only ciphertext.
The private half lives on GitHub, not on the workstation or the mainframe.

There is no local copy of the recovery private key. If this workstation dies,
nothing here can decrypt — that is the point. You decrypt *on GitHub*, from any
machine with the account and an Actions permission on this repository.

If you must rotate, do it in one sitting and delete the local private art:

```bash
umask 077; cd "$(mktemp -d)"
openssl genrsa -out new.pem 4096
openssl rsa -in new.pem -pubout -out newpub.pem
gh secret set RADIO_STATE_RECOVERY_KEY -R The-Replacement/infra < new.pem
openssl pkeyutl -encrypt -pubin -inkey newpub.pem \
  -in ~/.config/radio-backup/restic-password \
  -out restic-password.enc
# replace repo copies:
cp newpub.pem ~/Repositories/infra/deploy/recovery/public.pem
cp restic-password.enc ~/Repositories/infra/deploy/recovery/restic-password.enc
shred -u new.pem
```

Then run a `RECOVER` dispatch and confirm the fingerprint matches the live
password before assuming the rotation worked.

## 2. Decrypt, when you actually need it

The only listener is `workflow_dispatch`, and it requires the literal word
`RECOVER`:

```bash
gh workflow run recover-restic-password.yml \
  -R The-Replacement/infra -f confirm=RECOVER
gh run watch --repo The-Replacement/infra --exit-status   # or watch in the browser
```

The run will:

- write the private key to `/tmp/recovery.pem` inside the runner, decrypt the
  blob to `restic-password.txt`, delete the key,
- mask the value (`::add-mask::`), so nothing in the log prints it,
- print only the SHA-256 fingerprint — compare against
  `sha256sum ~/.config/radio-backup/restic-password` if you still have it,
  which proves the recovery key is the correct one without revealing it,
- upload the decrypted text as artifact `restic-password-recovery`,
  **retention 1 day**.

Download it with the repository CLI while it is live:

```bash
gh run download <run-id> -n restic-password-recovery -R The-Replacement/infra
```

Use the file as `RESTIC_PASSWORD_FILE` when restoring. Delete it afterwards —
artifacts are deleted by the runner after a day, but your local copy is a copy.

Never echo the decrypted value into a ticket, a commit or a PR body. If it lands
in one, the only fix is a password rotation plus a new archive.

## 3. The two archive mirrors

| Where | When | Transport |
|---|---|---|
| local repo `~/.local/share/restic-radio` | every backup (03:15 nightly) | n/a |
| LAN copy `mainframe:~/restic-radio-state` | nightly after the backup | `deploy/offsite-sync.sh box` (rsync --delete) |
| off-house GitHub release `nightly` in `The-Replacement/radio-backup` | weekly (`deploy/offsite-sync.sh github`) | `gh release upload --clobber` |

Mainframe copy is plaintext-ciphertext only: restic encrypts everything first, so
what ships out is ciphertext either way. Purposely no SSH password in this
repository. All three `box`, `github` and `all` commands stop with a non-zero exit
on error; if they skip quietly, so does the backup.

## 4. Recovery from a totally different machine

```bash
# 1. have: this GitHub account, a fresh machine.
# 2. clone the archive and the encrypted key blob.
curl -LO "$(gh api repos/The-Replacement/radio-backup/releases/latest \
              | jq -r '.assets[] | select(.name=="radio-state.tar.gz") | .browser_download_url')"
tar xzf radio-state.tar.gz                   # produces .../restic-radio
# 3. get the password via section 2 into a 0600 file; then
restic -r restic-radio --password-file restic-password.txt check
restic -r restic-radio --password-file restic-password.txt restore latest --target /restore-here
```

## Scope and one explicit concession

This puts ciphertext on GitHub — the radio's hosting, stream delivery and
metadata rules forbid SaaS for *the station*, not for the custody of its
backups. Deliberate, because the alternative is "offsite never exists".

Still true and not fixed by this runbook:

- a compromise of the GitHub account compromises both the key escrow and the
  archive; 2FA on the account is required, and that is outside this machine;
- the backup copy on the mainframe is local to the same house. House-scale
  loss relies on the GitHub copy. You are storing trust in a third party by
  choice, openly.
