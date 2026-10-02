# Updating a component

What to do with a pull request from Renovate. How the arrangement works, and
what it does not cover, is in
[Keeping versions current](../../concepts/updates.md).

## Turning it on

Once per repository. Until this is done, nothing opens pull requests.

1. Open the [Renovate app](https://github.com/apps/renovate) on GitHub and
   install it for this repository only.
2. Wait for an issue named **Dependency Dashboard** to appear. That is Renovate
   saying it has read `.github/renovate.json5`.

The first pull requests arrive the following Monday morning. To get one sooner,
tick its box on the Dependency Dashboard.

Worth doing at the same time, in the repository's settings: require the `check`
status before a pull request can merge. Without that, a red check is only a
suggestion.

## 1. Reading the pull request

Do these in order, and stop at the first one that worries you.

| Look at | Asking |
| --- | --- |
| The note at the top of the description, if there is one | Is merging the whole job? If not, read [the matching section below](#3-finishing-the-ones-a-merge-does-not-finish) first |
| The release notes | Does anything say "breaking", "removed", "renamed" or "migration"? |
| The **check** | Is it green? Red means it no longer builds. Do not merge |
| The comment titled **What the cluster would run** | Is every changed line one you expected? |

A diff that changes only image tags and version labels is a routine update. A
diff that adds, removes or renames things deserves the release notes read
properly.

A major version is always worth the release notes, however small the diff.

## 2. Merging, and watching it land

Merge one pull request at a time, and finish this section before the next one.
If two updates land together and something breaks, you no longer know which.

After merging, watch ArgoCD pick it up:

```bash
kubectl -n argocd get applications
```

```
NAME                      SYNC STATUS   HEALTH STATUS
cert-manager              Synced        Healthy
cilium                    Synced        Healthy
...
```

Every row should read `Synced` and `Healthy` within a few minutes. One that
stays `Progressing` or turns `Degraded` is the update you just merged.

Then check nothing is failing to start:

```bash
kubectl get pods -A | grep -vE 'Running|Completed'
```

```
NAMESPACE   NAME   READY   STATUS   RESTARTS   AGE
```

Only the header means every pod is up.

**If it broke:** open the merged pull request on GitHub and press **Revert**.
That opens a pull request undoing it. Merge that one, and ArgoCD puts the old
version back.

## 3. Finishing the ones a merge does not finish

Most updates are done after section 2. These are not.

### Cilium

The pull request is steps 1 to 3 of [Upgrading Cilium](./upgrading-cilium.md):
the version bump, the render and the commit. Read **Before you start** there
before merging. Then merge, and carry on from step 4.

### Talos and Kubernetes

Merging changes no running node. It only records the version a rebuilt cluster
would be born with, so it comes last. Follow
[Upgrading Talos and Kubernetes](./upgrading-talos-and-kubernetes.md), which
ends with the merge.

### An OpenTofu provider

Nothing changes until OpenTofu next runs. After merging:

```bash
git pull
task tofu:init -- -upgrade
task tofu:plan
```

```
No changes. Your infrastructure matches the configuration.
```

Any other plan means the new provider reads something differently. Read the
plan before applying anything.

### Headscale

Headscale runs on the server, so Ansible installs it.

The pull request must change two lines in
`ansible/roles/headscale/defaults/main.yaml`: `headscale_version` and
`headscale_deb_sha256`. The checksum is what proves the package installed is
the one that was reviewed.

If only the version changed, read the new checksum:

```bash
curl -sSL https://github.com/juanfont/headscale/releases/download/v<version>/checksums.txt \
  | grep linux_amd64.deb
```

```
1f65364716ae...  headscale_<version>_linux_amd64.deb
```

Set `headscale_deb_sha256` in `ansible/roles/headscale/defaults/main.yaml` to
it, in the same pull request. With the old one, the run stops at
`Download the headscale package` with `The checksum ... did not match`.

After merging:

```bash
git pull
task ansible:role -- headscale
```

The run should end with `failed=0`. Then, on the **server**:

```bash
systemctl is-active headscale
```

```
active
```

### ArgoCD

The chart and ArgoCD's CRDs arrive in one pull request, with different version
numbers. Before merging, check they belong together:

| Compare | With |
| --- | --- |
| The chart's `appVersion`, in its release notes | The `?ref=` on the ArgoCD line of `gitops/crds/base/kustomization.yaml` |

They should be the same version. CloudNativePG is checked the same way.
