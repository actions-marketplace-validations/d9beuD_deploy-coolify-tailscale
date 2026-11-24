# Deploy to Coolify over Tailscale

A GitHub Action that deploys your apps to a [Coolify](https://coolify.io) instance reachable only from your [Tailscale](https://tailscale.com) network.

It does three things:

1. **Joins your tailnet** as an ephemeral node, using [`tailscale/github-action`](https://github.com/tailscale/github-action). The node is removed when the job ends.
2. **Triggers the deployment** through the Coolify API, by resource UUID, by tag or with the deploy webhook URL Coolify gives you.
3. **Waits for the deployment to finish**, prints the Coolify build logs if it fails, and writes a summary with links to each deployment.

Your Coolify dashboard and API stay private. No port needs to be opened to the internet.

```yaml
- uses: d9beuD/deploy-coolify-tailscale@v1
  with:
    tailscale-oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
    tailscale-audience: ${{ secrets.TS_AUDIENCE }}
    coolify-url: https://coolify.tail1234.ts.net
    coolify-token: ${{ secrets.COOLIFY_TOKEN }}
    uuid: ${{ vars.COOLIFY_APP_UUID }}
```

## Contents

- [Requirements](#requirements)
- [Setup](#setup)
  - [1. Tailscale](#1-tailscale)
  - [2. Coolify](#2-coolify)
  - [3. GitHub](#3-github)
- [Usage examples](#usage-examples)
- [Inputs](#inputs)
- [Outputs](#outputs)
- [How it works](#how-it-works)
- [Troubleshooting](#troubleshooting)
- [Security](#security)
- [Versions](#versions)
- [Changelog](#changelog)
- [Development](#development)

## Requirements

- A Linux or macOS runner (`ubuntu-latest`, `macos-latest`, or a self-hosted runner with `bash`, `curl` and `jq`).
- Coolify v4 with the API enabled.
- A Tailscale tailnet where you can create tags, ACL rules and an OAuth client or federated identity.

## Setup

### 1. Tailscale

**Create a tag for your CI runners and let it reach Coolify.** In the [access controls](https://login.tailscale.com/admin/acls) of your tailnet, declare a tag (here `tag:ci`) and allow it to reach the machine running Coolify, on the port Coolify listens on:

```jsonc
{
  "tagOwners": {
    "tag:ci":      ["autogroup:admin"],
    "tag:coolify": ["autogroup:admin"]
  },
  "grants": [
    // CI runners can reach the Coolify dashboard/API, nothing else.
    { "src": ["tag:ci"], "dst": ["tag:coolify"], "ip": ["tcp:443", "tcp:8000"] }
  ]
}
```

Adapt the ports to your setup: `8000` is Coolify's default port, `443` is used if you serve it over HTTPS (with `tailscale serve`, for example).

**Create credentials for the runner.** Pick one of the following options:

| Option | What to create | Inputs to set |
| --- | --- | --- |
| **Workload identity federation** (recommended, no long-lived secret) | A [federated identity](https://tailscale.com/kb/1581/workload-identity-federation) with the `auth_keys` write scope and the `tag:ci` tag. Use GitHub as the issuer and restrict the subject to your repository, e.g. `repo:my-org/my-app:ref:refs/heads/main`. The job needs `permissions: id-token: write`. | `tailscale-oauth-client-id`, `tailscale-audience` |
| **OAuth client** | An [OAuth client](https://tailscale.com/kb/1215/oauth-clients) with the `auth_keys` write scope and the `tag:ci` tag. | `tailscale-oauth-client-id`, `tailscale-oauth-secret` |
| **Auth key** (not recommended) | A reusable, ephemeral, pre-approved [auth key](https://tailscale.com/kb/1085/auth-keys). | `tailscale-authkey` |

If you use a tag other than `tag:ci`, set the `tailscale-tags` input.

### 2. Coolify

1. **Enable the API.** In Coolify, go to **Settings → Advanced** and turn on API access. If you restrict the API to allowed IPs, add the Tailscale range `100.64.0.0/10`, or the IPs your runners get.
2. **Create an API token.** Go to **Keys & Tokens → API tokens** and create a token with the `deploy` permission. Add `read` too if you want the action to wait for the deployment (the default).
3. **Find what to deploy.** Choose one of:
   - the **UUID** of the application or service, shown in its URL and in its **Webhooks** tab;
   - a **tag** set on one or more resources;
   - the **deploy webhook** URL shown in the resource's **Webhooks** tab, e.g. `https://coolify.tail1234.ts.net/api/v1/deploy?uuid=abc123&force=false`.
4. **Find the URL of Coolify inside your tailnet.** Use the MagicDNS name (`http://coolify:8000`, `https://coolify.tail1234.ts.net`) or the Tailscale IP (`http://100.101.102.103:8000`).

### 3. GitHub

In your repository, go to **Settings → Secrets and variables → Actions**. Add:

- secrets: `COOLIFY_TOKEN`, plus `TS_OAUTH_CLIENT_ID` and `TS_AUDIENCE` (or `TS_OAUTH_SECRET`, or `TS_AUTHKEY`);
- variables (or secrets if you prefer): `COOLIFY_URL` and `COOLIFY_APP_UUID`, or a `COOLIFY_DEPLOY_WEBHOOK` secret.

## Usage examples

### Build an image, push it, then deploy

```yaml
name: Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions: {}

concurrency:
  group: deploy-production
  cancel-in-progress: false

jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    env:
      IMAGE: ghcr.io/${{ github.repository }}
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - name: Build and push the image
        env:
          GHCR_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          docker build --tag "$IMAGE:$GITHUB_SHA" --tag "$IMAGE:latest" .
          printf '%s' "$GHCR_TOKEN" | docker login ghcr.io --username "$GITHUB_ACTOR" --password-stdin
          docker push "$IMAGE:$GITHUB_SHA"
          docker push "$IMAGE:latest"

  deploy:
    needs: publish
    runs-on: ubuntu-latest
    timeout-minutes: 20
    permissions:
      id-token: write # for Tailscale workload identity federation
    environment: production
    steps:
      - uses: d9beuD/deploy-coolify-tailscale@v1
        with:
          tailscale-oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          tailscale-audience: ${{ secrets.TS_AUDIENCE }}
          tailscale-tags: tag:ci
          tailscale-ping: ${{ vars.COOLIFY_TAILSCALE_HOST }}
          webhook: ${{ secrets.COOLIFY_DEPLOY_WEBHOOK }}
          coolify-token: ${{ secrets.COOLIFY_TOKEN }}
```

### Deploy by UUID with an OAuth client

```yaml
- uses: d9beuD/deploy-coolify-tailscale@v1
  with:
    tailscale-oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
    tailscale-oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
    coolify-url: ${{ vars.COOLIFY_URL }}
    coolify-token: ${{ secrets.COOLIFY_TOKEN }}
    uuid: ${{ vars.COOLIFY_APP_UUID }}
```

### Deploy several resources

```yaml
- uses: d9beuD/deploy-coolify-tailscale@v1
  with:
    tailscale-oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
    tailscale-audience: ${{ secrets.TS_AUDIENCE }}
    coolify-url: ${{ vars.COOLIFY_URL }}
    coolify-token: ${{ secrets.COOLIFY_TOKEN }}
    # Either a list of UUIDs...
    uuid: |
      abc123
      def456
    # ...or every resource with a Coolify tag:
    # tag: production
```

### Deploy a pull request preview

```yaml
on:
  pull_request:

jobs:
  preview:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
    steps:
      - uses: d9beuD/deploy-coolify-tailscale@v1
        with:
          tailscale-oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          tailscale-audience: ${{ secrets.TS_AUDIENCE }}
          coolify-url: ${{ vars.COOLIFY_URL }}
          coolify-token: ${{ secrets.COOLIFY_TOKEN }}
          uuid: ${{ vars.COOLIFY_APP_UUID }}
          pr: ${{ github.event.pull_request.number }}
          cancel-previous: building
```

Preview deployments must be enabled for the application in Coolify.

### Queue the deployment without waiting

```yaml
- uses: d9beuD/deploy-coolify-tailscale@v1
  id: deploy
  with:
    tailscale-oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
    tailscale-audience: ${{ secrets.TS_AUDIENCE }}
    coolify-url: ${{ vars.COOLIFY_URL }}
    coolify-token: ${{ secrets.COOLIFY_TOKEN }}
    uuid: ${{ vars.COOLIFY_APP_UUID }}
    wait: 'false'
- run: echo "Queued ${{ steps.deploy.outputs.deployment-uuids }}"
```

### Runner already in the tailnet

On a self-hosted runner that is already connected to Tailscale, skip the Tailscale step:

```yaml
- uses: d9beuD/deploy-coolify-tailscale@v1
  with:
    connect-tailscale: 'false'
    coolify-url: http://coolify:8000
    coolify-token: ${{ secrets.COOLIFY_TOKEN }}
    uuid: ${{ vars.COOLIFY_APP_UUID }}
```

## Inputs

### Coolify

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `coolify-token` | yes | | Coolify API token with the `deploy` permission, plus `read` to wait for the deployment. |
| `coolify-url` | yes, unless `webhook` is set | | URL of Coolify inside the tailnet, e.g. `https://coolify.tail1234.ts.net` or `http://100.101.102.103:8000`. A trailing `/api/v1` is accepted. |
| `uuid` | one of `uuid`, `tag`, `webhook` | | Resource UUID(s), separated by commas, spaces or new lines. |
| `tag` | one of `uuid`, `tag`, `webhook` | | Coolify tag name(s): every resource with one of these tags is deployed. |
| `webhook` | one of `uuid`, `tag`, `webhook` | | Deploy webhook URL from the resource's **Webhooks** tab. The Coolify URL and the resource are read from it. |
| `force` | no | `false` | Rebuild without the build cache. |
| `pr` | no | | Pull request number, to deploy a preview. Cannot be used with `tag`. |
| `cancel-previous` | no | `none` | Cancel older API/webhook deployments of the same application: `none`, `queued` (waiting in the queue) or `building` (also stops running builds). Needs a recent Coolify version. |
| `wait` | no | `true` | Wait for the deployment(s) to finish, and fail the step if one fails. |
| `timeout` | no | `900` | Maximum time to wait, in seconds. |
| `interval` | no | `10` | Time between two status checks, in seconds. |
| `show-logs` | no | `on-failure` | When to print the Coolify build logs: `on-failure`, `always` or `never`. |
| `connect-timeout` | no | `120` | How long to wait for Coolify to become reachable through Tailscale, in seconds. |

### Tailscale

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `connect-tailscale` | no | `true` | Set to `false` to skip joining the tailnet. |
| `tailscale-oauth-client-id` | see [setup](#1-tailscale) | | OAuth client ID, or federated identity client ID. |
| `tailscale-oauth-secret` | see [setup](#1-tailscale) | | OAuth client secret. |
| `tailscale-audience` | see [setup](#1-tailscale) | | Workload identity federation audience. Requires `permissions: id-token: write`. |
| `tailscale-authkey` | see [setup](#1-tailscale) | | Auth key, if you do not use OAuth or workload identity federation. |
| `tailscale-tags` | no | `tag:ci` | Comma-separated tags of the runner node. |
| `tailscale-version` | no | `latest` | Tailscale version to install, e.g. `1.104.5`. Pin it for reproducible runs. |
| `tailscale-hostname` | no | generated | Hostname of the runner node. |
| `tailscale-args` | no | | Extra arguments for `tailscale up`. |
| `tailscale-ping` | no | | Comma-separated tailnet hosts to `tailscale ping` before deploying. |
| `tailscale-use-cache` | no | `true` | Cache the Tailscale binaries between runs. |

## Outputs

| Output | Description |
| --- | --- |
| `deployment-uuids` | Comma-separated UUIDs of the queued deployments. |
| `status` | `finished`, `failed`, `timeout`, or `queued` when `wait` is `false`. |
| `response` | Raw JSON response of the Coolify deploy endpoint. |

## How it works

1. If `connect-tailscale` is `true`, the action runs `tailscale/github-action@v4`. The runner joins your tailnet as an ephemeral node with the given tags and logs out at the end of the job.
2. It calls `GET /api/v1/health` on Coolify until it answers, for up to `connect-timeout` seconds. A new node can take a few seconds to be reachable by the rest of the tailnet.
3. It calls `POST /api/v1/deploy` with `uuid`, `tag`, `force`, `pr` and `cancel_previous`. Older Coolify versions only accept `GET` on this endpoint. The action then retries with `GET`.
4. If `wait` is `true`, it polls `GET /api/v1/deployments/{uuid}` for every queued deployment until each one is `finished`, `failed`, `cancelled-by-user` or `skipped`, or until `timeout`.
5. It writes a job summary with a link to each deployment in Coolify and sets the step outputs. The step fails if a deployment failed, was cancelled or timed out.

Services and databases have no deployment to follow: Coolify starts them directly, and the action succeeds once Coolify accepts the request.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `Could not reach Coolify` | Check `coolify-url`. Check that your ACLs let the runner's tag reach the Coolify machine on that port. Set `tailscale-ping` to the Coolify host to debug connectivity. If the MagicDNS name does not resolve, use the Tailscale IP. |
| `API is disabled.` | Enable the API in Coolify: **Settings → Advanced**. |
| `You are not allowed to access the API.` | The Coolify API is restricted to allowed IPs. Add `100.64.0.0/10`, or your runners' Tailscale IPs. |
| `Missing required permissions: deploy` | Create a token with the `deploy` permission. |
| `The API token cannot read deployments` | Add the `read` permission to the token, or set `wait: 'false'`. |
| `Nothing to deploy (HTTP 404)` | Check the UUID or tag, and that the token belongs to the team that owns the resource. |
| `Timed out` | The deployment may still be running in Coolify. Increase `timeout`, and the job's `timeout-minutes` with it. |
| Tailscale fails to connect | Check that the OAuth client or federated identity has the `auth_keys` write scope and owns the tags in `tailscale-tags`. With workload identity federation, the job needs `permissions: id-token: write`. |

## Security

- Keep the Coolify token, the deploy webhook URL and the Tailscale credentials in [GitHub secrets](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions). Prefer workload identity federation: no long-lived Tailscale secret is stored.
- Restrict the ACL grant of the CI tag to the Coolify host and port.
- Use a GitHub [environment](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment) with protection rules for production secrets.
- To protect yourself against a moved tag, pin the action to a commit SHA: `uses: d9beuD/deploy-coolify-tailscale@<sha> # v1.x.y`.

## Versions

This action follows [semantic versioning](https://semver.org). Each release has an exact tag (`v1.0.0`). The major tag (`v1`) moves to the latest release of that major version.

| Reference | What you get |
| --- | --- |
| `@v1` | The latest `v1.x.y` release: bug fixes and new inputs, never a breaking change. Recommended. |
| `@v1.0.0` | Exactly this release. Update it yourself, or with [Dependabot](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/keeping-your-actions-up-to-date-with-dependabot). |
| `@<commit-sha>` | Exactly this commit, even if a tag is moved. The safest choice. |

A breaking change, such as a removed or renamed input or a changed default, comes with a new major version (`v2`).

To let Dependabot update the action, add `.github/dependabot.yml` to your repository:

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
```

## Changelog

See [`CHANGELOG.md`](CHANGELOG.md) and the [GitHub releases](https://github.com/d9beuD/deploy-coolify-tailscale/releases). Both are generated by [release-please](https://github.com/googleapis/release-please) from the commit messages.

## Development

The deploy logic lives in [`scripts/deploy.sh`](scripts/deploy.sh). It is tested against a small fake Coolify API ([`test/mock_coolify.py`](test/mock_coolify.py)):

```bash
bash test/run-tests.sh
```

You need `bash`, `curl`, `jq` and `python3`. CI also runs ShellCheck and actionlint, and runs the action itself against the fake API.

### Commit messages

Commit messages (or pull request titles, when you squash-merge) follow [Conventional Commits](https://www.conventionalcommits.org). They decide the next version and fill the changelog:

| Commit message | Example | Next version |
| --- | --- | --- |
| `fix: ...` | `fix: retry when Coolify returns a 502` | patch (`v1.0.1`) |
| `feat: ...` | `feat: add a cancel-on-timeout input` | minor (`v1.1.0`) |
| `feat!: ...`, or a `BREAKING CHANGE:` footer | `feat!: remove the tailscale-authkey input` | major (`v2.0.0`) |
| `docs:`, `ci:`, `test:`, `chore:`, `refactor:` | `docs: fix a typo in the README` | no release on its own |

`docs:` commits appear in the changelog; the other types without a release are hidden.

### Releasing

Releases are automated with [release-please](https://github.com/googleapis/release-please) in [`.github/workflows/release.yml`](.github/workflows/release.yml):

1. Each push to `main` opens or updates a **release pull request**, titled like `chore(main): release 1.1.0`. It updates the version in [`.release-please-manifest.json`](.release-please-manifest.json) and adds the new entry to [`CHANGELOG.md`](CHANGELOG.md).
2. Merge that pull request when you want to release. The workflow then:
   - creates the `vX.Y.Z` tag and the GitHub release, with the changelog entry as release notes;
   - moves the major tag (`v1`) to the new release, so that `@v1` users get it.

The configuration lives in [`release-please-config.json`](release-please-config.json), and the last released version in [`.release-please-manifest.json`](.release-please-manifest.json).

Do not create releases or `vX.Y.Z` tags by hand: release-please does not see them, and would later try to create the same version again. To publish a release to the GitHub Marketplace, edit the release that release-please created.

To force a specific version, add a `Release-As: 1.2.3` footer to a commit message.

#### One-time setup

- In **Settings → Actions → General**, under **Workflow permissions**, tick **Allow GitHub Actions to create and approve pull requests**. Without it, release-please cannot open its pull request.
- Optional: pull requests opened with the default `GITHUB_TOKEN` do not trigger other workflows, so CI does not run on the release pull requests. If you require CI checks before merging, create a [fine-grained personal access token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) for this repository, with read and write access to **Contents**, **Issues** and **Pull requests**. Save it as the `RELEASE_PLEASE_TOKEN` secret. The workflow uses it when it exists.
- To list the action on the GitHub Marketplace, edit a release on GitHub and tick **Publish this Action to the GitHub Marketplace**. This step is manual: GitHub does not offer it to workflows.
