# Keeping versions current

Almost everything here is pinned to a version: charts, images, providers, Talos,
Kubernetes. Pinned versions go stale without anyone noticing. This explains what
notices, and what it does and does not do for you. For what to do with an
update once it arrives, see
[Updating a component](../manual/maintenance/updating-a-component.md).

## What is used

**Renovate**, as the GitHub app. It reads the repo, compares every pinned
version with the newest release, and opens a pull request for each one that is
behind.

It never merges. ArgoCD deploys whatever reaches `main`, so a merge is a
deployment, and that stays a person's decision.

| Renovate does | You do |
| --- | --- |
| Opens one pull request per update, early on Monday | Read it |
| Puts the release notes in the pull request | Decide |
| Keeps a **Dependency Dashboard** issue listing every update | Merge, and do any step the merge does not |

Its settings are in `.github/renovate.json5`, with a comment on each rule.

## What a pull request tells you

Three things, in the order worth reading them:

| Where | What |
| --- | --- |
| The description | Release notes, a link to the release, and a note when merging is not the whole job |
| The **check** | Whether everything still builds: `task cluster:render`, `task secrets:check`, `tofu validate` |
| The comment from the check | What the cluster would run afterwards, as a diff |

The diff is the one that matters. A chart bump is one changed line in git, and
ArgoCD turns it into the chart's templates. The check does the same thing, for
the old version and the new, and posts the difference. A default that changed
or a field that was renamed shows there even when the release notes leave it
out.

To see the same diff for a change of your own:

```bash
task cluster:render:diff
```

It prints the diff against `origin/main`, and nothing at all when nothing
differs. `.github/render.sh` is what renders each side.

## What none of this proves

**That the change works.** A green check means the manifests build. There is no
second cluster to try them on, so the first real test of an update is merging
it.

Three settings keep that risk small:

| Setting | Why |
| --- | --- |
| A release must be 7 days old | Someone else finds the bad ones first |
| One component per pull request | When something breaks, the cause is the last merge, and the fix is one revert |
| A new major version is always its own pull request | Those are the ones that break things |

## Versions that move together

Some versions are two halves of one thing. Renovate puts each set in one pull
request:

| Set | Why |
| --- | --- |
| The cert-manager chart and its CRDs | Helm never upgrades a CRD, so they are fetched separately, in `gitops/crds/` |
| kgateway and its CRD chart | Same |
| The ArgoCD chart and ArgoCD's CRDs | Same. The two carry different version numbers |
| The CloudNativePG chart and its CRDs | Same. The two carry different version numbers |

For the last two, Renovate cannot tell which chart goes with which CRDs. The
pull request says so, and says what to check.

## When merging is not the whole job

| Update | What merging does | What is left |
| --- | --- | --- |
| A chart or an image | ArgoCD applies it within minutes | Check it is healthy |
| Cilium | ArgoCD upgrades the running cluster | [Upgrading Cilium](../manual/maintenance/upgrading-cilium.md), which ends with a `tofu apply` |
| Talos, Kubernetes | Nothing on a running node | `task tofu:apply`, which does the upgrade: [Upgrading Talos and Kubernetes](../manual/maintenance/upgrading-talos-and-kubernetes.md) |
| An OpenTofu provider | Nothing until OpenTofu next runs | `task tofu:init -- -upgrade`, then a plan |
| Headscale | Nothing on the server | `task ansible:role -- headscale` |
| Proxmox | Nothing on the server. The pull request is the notice that a newer one is out | [Upgrading it by hand](../manual/maintenance/updating-a-component.md#proxmox), which ends with the merge |

Each of these pull requests carries a note saying the same.

## What is not covered

| What | Why | How it is updated |
| --- | --- | --- |
| The server's own packages | Not in git | Debian's packages, Caddy and Tailscale upgrade themselves daily. Proxmox does not: its version is recorded in git, so Renovate says when a newer one is out, and it is upgraded by hand |
| The sops-secrets-operator CRD | It is a copy of a file, and Renovate changes version numbers, not files | By hand, when the chart's pull request says the CRD changed |
| Ansible collections | Floors, not pins | The newest is installed anyway |

Two things look like they would be on this list and are not. grafana.com has
no release feed Renovate knows, so `renovate.json5` teaches it to read the
site's own API:

| What | Its version |
| --- | --- |
| Grafana dashboards pulled by id | The revision number. All of them arrive in one pull request |
| The VictoriaLogs plugin for Grafana | Pinned as `id@version` in Grafana's values |

## Where the pieces live

| What | Where |
| --- | --- |
| Renovate's rules | `.github/renovate.json5` |
| The pull request check | `.github/workflows/check.yaml` |
| What renders each side of the diff | `.github/render.sh` |
| The diff, by hand | `task cluster:render:diff` |
