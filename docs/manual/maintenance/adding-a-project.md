# Adding a project

A project is somewhere for an application to live: a namespace per environment,
the limits it runs inside, the policy it is isolated by, and the ArgoCD
`Application` that deploys it. All of it comes from one file.

For why it is shaped this way, see
[GitOps with ArgoCD](../../concepts/gitops.md).

## 1. Writing the file

One file per project, `gitops/applications/catalog/<name>.yaml`. It is passed
to the `project` chart as its values, so what you write here is what that chart
reads:

```yaml
name: blog

environments:
  - name: prod
    sync:
      repo_url: https://github.com/you/blog
      revision: main
      path: deploy/prod
```

| Field | Required | Meaning |
| --- | --- | --- |
| `name` | yes | The project. Names its namespaces, its AppProject and its Applications |
| `environments[].name` | yes | `prod` or `dev`, and nothing else |
| `environments[].sync` | yes | Where the workload comes from: `repo_url`, `revision`, `path` |
| `environments[].quotas` | no | `cpu`, `memory`, `storage`, `persistentvolumeclaims` |
| `environments[].podSecurity` | no | The namespace's Pod Security level |

Anything optional falls back to `defaults` in
`gitops/charts/project/values.yaml`.

**`prod` and `dev` are the only environment names that work.** The Gateways
select namespaces on exactly those, so any other name produces a namespace
whose routes are refused. The chart refuses to render instead, which is why
step 3 catches it.

## 2. What appears

Per environment, in a namespace named `project-<name>-<environment>`:

| Object | What it does |
| --- | --- |
| `Namespace` | Labelled `env`, `tier: applications` and a Pod Security level |
| `ResourceQuota` | Caps cpu, memory, storage and PVCs |
| `NetworkPolicy` ×6 | Denies everything, then allows DNS, metric scraping, the CloudNativePG operator, traffic within the environment, and the environment's Gateways |
| `Application` | Deploys `sync` into the namespace |

Plus one `AppProject` for the whole project, limiting it to the repositories
its environments name and the namespaces it owns.

## 3. Checking it before you commit

```bash
task cluster:render
```

```
All overlays render, and every project in the catalog.
```

This renders the chart against your file, so a bad environment name, a missing
`sync` or a broken template fails here rather than in the cluster.

## 4. After pushing

```bash
kubectl -n argocd get applications -l tier=applications
```

The project's `Application` per environment, `Synced` and `Healthy`.

```bash
kubectl get ns project-<name>-prod -o jsonpath='{.metadata.labels}'
```

`env`, `tier` and `pod-security.kubernetes.io/enforce`, all present.

## What will surprise you

**A pod with no `resources` is refused.** The quota names `requests.cpu` and
`limits.memory`, and once it does, the API server requires every pod to set
them. There is no `LimitRange` filling them in. The error names the missing
resource.

**Everything is denied, except inside the environment.** The chart's
`default-deny` policy blocks all traffic in and out, and `allow-environment`
then opens every port between namespaces of the same environment. So a dev API
reaches its dev database with no policy of its own, and never a prod one. To
narrow it further, a project writes its own `NetworkPolicy` beside its
manifests.

**The Gateways can already reach the workload; nothing routes to it yet.** The
chart's `allow-gateways` policy lets in the Gateways that serve the namespace's
environment: `gw-internal-dev` for dev,
`gw-internal-prod` and `gw-public` for prod. A workload is exposed by writing
an `HTTPRoute` for it, and needs no `NetworkPolicy` of its own for that. See
[Exposing a service](./exposing-a-service.md).

**Deleting the file deletes the project.** Namespaces and volumes included, and
volumes here are node-local with no backup.
