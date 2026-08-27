# The cluster's networking

Kubernetes does not ship a network. A CNI plugin provides one, and every pod
depends on it. This explains which one this cluster uses, why, and why it is
installed in an unusual way. To upgrade it, see
[Upgrading Cilium](../manual/maintenance/upgrading-cilium.md).

## What is used

**Cilium**, with **kube-proxy replaced** and **Hubble** enabled.

Talos installs Flannel by default. Flannel is small and dependable, but it does
not implement NetworkPolicy: a policy applied under Flannel is accepted by the
API server and then quietly does nothing, which is worse than not supporting it.
Cilium enforces them.

Being honest about the reasons, because they are not the usual ones:

| Reason | Does it apply here? |
| --- | --- |
| Faster datapath, less iptables overhead | **No.** All six nodes are guests on one host, on one bridge. There is no network to speed up. |
| NetworkPolicy that actually works | Yes. |
| Hubble: seeing what talks to what | Yes, and it is the strongest reason on a homelab. |

Replacing kube-proxy is likewise not about throughput at this size. It is about
having one thing implement Services rather than two.

## Talos creates it, ArgoCD owns it

Turning Flannel off means nodes come up **NotReady** and stay there until a CNI
exists. The run ends with `data.talos_cluster_health`, which is what makes
`tofu apply` mean "the cluster is up" rather than "the guests exist".

So installing Cilium as a step after the cluster was built would deadlock. Health
would wait for nodes that cannot become Ready until Cilium is installed, and the
apply would fail before ever getting to the step that installs it. ArgoCD cannot
do it either: ArgoCD runs on the network Cilium provides.

Instead the chart is rendered at plan time and handed to the control planes as a
`cluster.inlineManifests` entry in their machine configuration. Talos creates it
while the control plane comes up, nodes go Ready on their own, and the health
check passes as it always did.

```
tofu plan   → helm renders the chart to a string
tofu apply  → the string is part of the control plane machine configuration
Talos boots → creates it before the cluster is finished coming up
ArgoCD      → owns it from then on
```

Only the three control planes carry it. Workers never apply inline manifests, and
the render is some 75 KB.

**Talos only ever creates.** Its manifest controller checks whether each object
exists and skips it if it does; it never updates one. So the inline manifest is
what a cluster is born with, and it can never be what a cluster is changed with.
Editing the render and running `tofu apply` writes a new machine configuration
that no running cluster will ever read — a change that looks applied and is not.

That is also what makes the handoff safe. Because Talos cannot update, it cannot
revert, so ArgoCD can own Cilium outright with nothing fighting it. The
`Application` at `gitops/system/base/cilium/cilium.yaml` holds the chart version
and every value, and `cilium.tf` reads that same file to produce the bootstrap
render. One definition, two deliveries:

| When | Who | Reads |
| --- | --- | --- |
| Cluster is born | Talos, once | The render OpenTofu made from the Application |
| Every change after | ArgoCD | The Application itself |

## KubePrism, and the bootstrap problem

Cilium needs to reach the API server. Normally that is the `kubernetes` Service,
which is implemented by kube-proxy. Cilium is what replaced kube-proxy, and it is
not running yet. Nothing can resolve that Service.

Talos runs **KubePrism** for exactly this: a local load balancer on
`localhost:7445`, on every node, that reaches the API server without Kubernetes
Services existing. Cilium is pointed at it. It is enabled by default, and the
port is written once — as Cilium's `k8sServicePort` in the Application, which
`cluster.tf` reads back to pin it in the machine configuration.

## Talos-specific settings

Two chart defaults assume a normal Linux distribution and are wrong on Talos:

| Setting | Why |
| --- | --- |
| `cgroup.autoMount.enabled: false` | Talos mounts the cgroup filesystem itself. |
| `securityContext.capabilities` | Talos grants named capabilities instead of blanket privilege. |

## Hubble's certificates are minted in the cluster

The chart would rather generate Hubble's TLS material while rendering. That
cannot be used here, for two reasons that are really the same reason:

1. The rendered manifest goes into the machine configuration, which goes into
   OpenTofu state. A generated private key would be a **secret in the state**.
2. It is generated fresh on every render, so **every plan would show a change**
   and every apply would rewrite the control planes' configuration.

Setting `hubble.tls.auto.method: cronJob` moves certificate generation into the
cluster. The render is then byte-identical every time, and carries no secrets.

## Load balancer addresses

`l2announcements` is on. That is what lets a `Service` of `type: LoadBalancer`
get a real address on the guest bridge, instead of sitting `<pending>` forever
with no cloud to ask.

| Setting | Why |
| --- | --- |
| `l2announcements.enabled: true` | One agent wins a lease and answers ARP for each assigned address. |
| `k8sClientRateLimit` | Leases are renewed constantly, and the chart's default limit is too low for that. Left alone, the agent logs throttle warnings. |

Cilium's own `gatewayAPI` is deliberately **off**: kgateway is the Gateway API
implementation here. These are separate features, and
[Getting traffic into the cluster](./ingress.md) explains why turning one off
does not remove the need for the other.

## What this costs

Cilium is the network *and* the Service implementation. When it is broken, both
are, and the blast radius is the whole cluster rather than one workload. That is
the trade for the policy enforcement and the visibility, and it is why upgrading
it has [its own procedure](../manual/maintenance/upgrading-cilium.md).

Where the pieces live:

| What | Where |
| --- | --- |
| Chart version and values | `gitops/system/base/cilium/cilium.yaml` |
| The bootstrap render, from that file | `opentofu/project/cilium.tf` |
| Address pool, L2 announcement policy | `gitops/network/base/` |
| CNI off, kube-proxy off | `opentofu/project/cluster.tf` |
