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
| `Namespace` | Labelled `env`, `tier: applications`, a Pod Security level, and into the mesh |
| `ResourceQuota` | Caps cpu, memory, storage and PVCs |
| `NetworkPolicy` ×4 | Denies everything, then allows DNS, metric scraping and mesh traffic |
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

**The namespace is in the mesh, and that changes what a `NetworkPolicy` can
say.** Traffic between this namespace and any other pod arrives on port 15008
under mutual TLS, not on the application's port, so a rule naming a port no
longer distinguishes anything. Write access rules as an Istio
`AuthorizationPolicy` instead, which can name a service account rather than an
address. [Istio in ambient mode](../../concepts/istio.md) explains why.

**Nothing can reach the workload yet.** The default-deny still drops all
ingress from `gateway-system`, so an `HTTPRoute` will be `Accepted: True` and
the backend still unreachable. Add a `NetworkPolicy` allowing ingress from
`gateway-system` in the project's own repository — exposure is meant to be a
decision, not a side effect. Because both namespaces are in the mesh, that
policy names **port 15008**, not the application's port. See
[Exposing a service](./exposing-a-service.md).

**Deleting the file deletes the project.** Namespaces and volumes included, and
volumes here are node-local with no backup.
