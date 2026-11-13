# Runbook: the player page stopped publishing

**Symptom:** `radio.daza.ar` serves an old build. Player changes are merged but
listeners never receive them.

## What serves the page

The player is static (`radio/web/`), published by a **Cloudflare Pages** project
named `radio`, aliased to `radio.daza.ar`. The API is not Caddy: Caddy runs on
the host and serves the stream. The page and the stream have separate failure
modes — a broken Pages deploy does not stop the audio.

## Diagnosis, in order

1. **Did Pages deploy the merge commit?**

   ```bash
   wrangler pages deployment list --project-name radio | head -5
   ```

   Compare the `Source` column (short commit hash) with the tip of
   `The-Replacement/radio` master. If the newest deployment is older than the
   merge, the integration is not firing.

2. **Can Cloudflare still see the repository?**

   An empty-body POST asks Pages to redeploy the production branch:

   ```bash
   curl -s -X POST -H "Authorization: Bearer $CF_API_TOKEN" \
     -H "Content-Type: application/json" -d '{}' \
     "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/pages/projects/radio/deployments"
   ```

   - `success: true` → the integration works; the webhook did not fire. Check
     the repository's webhook deliveries (Settings → Webhooks) and re-push.
   - `8000032 Unable to find a branch with the provided name` → the GitHub App
     installation can no longer see the repository. This is what happens to a
     Pages project when the repository is transferred to another owner and the
     App is installed on the old one. Go to the fix below.

3. **Is the page itself fine, and only the alias stale?**

   ```bash
   curl -sI https://radio.daza.ar/ | head -5
   curl -s https://radio-27p.pages.dev/ | head -5
   ```

   If `<project>.pages.dev` is current and the custom domain is not, the problem
   is the domain mapping, not the build.

## Fix A — re-link the git integration (keeps the current design)

Cloudflare dashboard → Workers & Pages → `radio` → Settings → Build.

1. Disconnect the GitHub connection.
2. Connect again, authorising the Cloudflare GitHub App on the
   **`The-Replacement`** organisation.
3. Select `The-Replacement/radio`.
4. Keep: production branch `master`, build command `exit 0`, output directory
   `web`, no root directory.

Verify by pushing a no-op commit and watching the deployment appear.

**Cost:** the App installation is the fragile part. Any future transfer of the
repository breaks it again, silently, exactly the same way.

## Fix B — deploy from GitHub Actions (removes the App from the path)

Switch the project to Direct Upload and deploy with Wrangler from CI:

1. Create a scoped API token: *Account → Cloudflare Pages → Edit*, restricted to
   the account that owns the project.
2. Store `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` as repository
   secrets.
3. In the Cloudflare project: Settings → Build → disconnect the git integration
   (Direct Upload projects are not git-linked).
4. Add `.github/workflows/pages.yml`:

   ```yaml
   name: pages
   on:
     push:
       branches: [master]
       paths: ["web/**", ".github/workflows/pages.yml"]
   jobs:
     deploy:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
         - uses: cloudflare/wrangler-action@v3
           with:
             apiToken: ${{ secrets.CLOUDFLARE_API_TOKEN }}
             accountId: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
             command: pages deploy web --project-name radio
   ```

**Tradeoff:** one more secret and one more workflow, in exchange for deploys
that appear in the repository's own Actions history and cannot be silently
severed by an ownership change. For a project whose whole point is that every
claim is checkable, this is the better trade.

## Not a fix

- Pointing the custom domain at `<project>.pages.dev` by hand: hides the stale
  build instead of publishing the new one.
- Publishing `web/` from the host through Caddy: reintroduces the coupling the
  split was made to remove, and puts the page behind a box that overheats.
