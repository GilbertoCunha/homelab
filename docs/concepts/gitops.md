# GitOps with ArgoCD

Everything inside the cluster is described in `gitops/` and applied by ArgoCD.
OpenTofu stops at the cluster's edge: it builds six Talos guests and installs a
CNI, and nothing else. To run the bootstrap, see
[Bootstrapping GitOps](../manual/provisioning/4-bootstrap-gitops.md).

## The layout

```
gitops/
├── crds/        CRDs, which nothing else may install
└── system/      everything else
    ├── base/            one directory per component
    └── overlays/        which branch and path each environment reads
```

Both trees have `base/` and `overlays/production/`. `base` says what a component
is; the overlay says where this cluster reads it from. There is one overlay
today, and the split is what keeps a second cluster from being a rewrite.

`system/base/applications/` holds the two ArgoCD `Application`s. That is the
app-of-apps: syncing `system` creates them, and they sync everything else.

## A component owns its manifests

`system/base/<component>/` holds **everything** that component needs, whatever
kind it is:

```
system/base/cilium/          chart, LB address pool, L2 announcement,
                             the kube-system label, Hubble's route
system/base/cert-manager/    chart, ClusterIssuer, its Cloudflare token
system/base/kgateway/        chart, gateway-system, GatewayParameters,
                             the Gateways, their certificates
system/base/grafana/         chart, namespace, route
system/base/victoria-logs/   chart, collector, namespace, route
```

So exposing a service is one file added next to the service, not one file added
to a directory of unrelated routes. The same goes for a component's encrypted
secret.

The alternative — a directory per *kind*, so every `HTTPRoute` together and
every `SopsSecret` together — is what this repo used to do. It meant a change to
one component touched three directories, and reading a component told you
nothing about how it was exposed.

CRDs are the one exception, and only because the bootstrap has to apply them and
wait before anything else is applied at all.

## The bootstrap is not a special case

ArgoCD cannot install itself, so something has to apply the overlay once. That
is `task cluster:bootstrap`, and it applies **the same manifests ArgoCD then
syncs** — not a separate installer.

This has one useful consequence: the task is repeatable. Running it a second
time changes nothing, and running it against a cluster whose ArgoCD is broken
repairs ArgoCD. There is no state that only exists because of how the cluster
was first built.

Two details make that true:

| Flag | Why |
| --- | --- |
| `--server-side` | The Gateway API and ArgoCD CRDs are larger than the annotation a client-side apply tries to store the previous configuration in. |
| `--force-conflicts` | After the first run those fields belong to ArgoCD's field manager. Without this, every later run fails on a conflict. |

CRDs are applied first and separately, with a wait between. The system overlay
creates `Application` objects, and that is a kind the API server does not know
until the CRD apply is accepted.

## Sync waves

Any resource carries `argocd.argoproj.io/sync-wave`, and ArgoCD finishes a wave
before starting the next. Since a component's manifests sit together rather than
in a tree of their own, the wave is what orders them. This is the dependency
order:

| Wave | What | Depends on |
| --- | --- | --- |
| -1 | `crds` | — |
| 0 | kgateway CRDs, sops-secrets-operator, local-path-provisioner | — |
| 1 | kgateway, cert-manager, grafana, victoria-logs, victoria-metrics | Their CRDs established, and a default storage class |
| 2 | Gateways, `GatewayParameters`, address pool, `ClusterIssuer`, certificates, every `HTTPRoute`, external-dns | `GatewayParameters` is a kind kgateway registers |
| 3 | every `SopsSecret` | The operator, and the namespaces the Secrets land in |
| 4 | `cloudflared` | Its credentials, and `gw-public` to dial |

Within a wave the order is undefined, so anything that must come first needs a
wave of its own.

## One thing is not in git

The age key. Every secret this cluster needs is committed to `gitops/system/base/`
encrypted, and sops-secrets-operator decrypts each into a plain `Secret`. The
key that does the decrypting is what cannot be committed alongside them.

`task cluster:sops-key` puts it in, and it is the only step to repeat after a
rebuild. [Secrets with SOPS](./sops.md) covers what that key can reach.

## ArgoCD owns part of kube-system

Only one field of it: the `env: prod` label, so Hubble's UI can attach a route
to the prod Gateway. Two things keep that from being reckless:

| Guard | What it stops |
| --- | --- |
| Server-side apply | ArgoCD owns the fields it names and no others, so nothing else on the namespace is disturbed |
| `Prune=false` | Deleting the manifest can never delete `kube-system`, which would take the control plane's workload with it |

Adding any other field to `gitops/system/base/cilium/kube-system.yaml` hands ArgoCD
ownership of that field too. Do not.

## CRDs are never pruned

The `crds` Application sets `prune: false`. Deleting a CRD deletes every custom
resource of that kind, cluster-wide and without confirmation. Removing one stays
a deliberate manual act.

Helm charts are also told not to install their own CRDs, because Helm does not
upgrade CRDs on a chart upgrade: it installs them once and then ignores them
forever. Pulling them into `gitops/crds/` is what makes an upgrade actually
upgrade them. The version pinned there must move with the chart version.

## ArgoCD manages itself

`system/overlays/production/argocd/` inflates the ArgoCD Helm chart through
kustomize, and the `system` Application syncs that same directory. So the
running install and git converge, and an upgrade is a version bump in
`kustomization.yaml`.

This needs `kustomize.buildOptions: --enable-helm` in `argocd-cm`. Without it
ArgoCD cannot render a kustomization that inflates a chart, which is exactly
what it does to manage itself.

The chart is vendored under `charts/`, so a render does not depend on a remote
repository being up.

## Access

The UI is on the mesh at `argocd.k8s.homelab.grncunha.com`, not on the public
zone. Anonymous access is enabled and everyone starts read-only, which is
reasonable for devices that already had to join the mesh to get there and would
not be on the internet.

The Gateway speaks plain HTTP to the ArgoCD Service, so `server.insecure` is on.
Left at its default the server would serve TLS and redirect, and the two would
argue in a loop.
