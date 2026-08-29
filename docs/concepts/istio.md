# Istio in ambient mode

**"Mesh" means two different things in this repo.** Everywhere else it is the
Headscale WireGuard overlay that reaches the cluster from a laptop or a phone:
[The mesh network](./mesh.md). Here it means the *service* mesh, which is inside
the cluster and unrelated. This document never uses the word on its own.

## What it is for

Until this, one pod talking to another was plain TCP. Nothing proved who the
caller was, nothing encrypted what it said, and the only record was Hubble's
live flow view. A NetworkPolicy could say *which namespace* may connect, and
nothing finer, because an address is all Cilium has to go on.

Istio gives every pod a cryptographic identity taken from its service account,
and puts mutual TLS between them. To upgrade it, see
[Upgrading Istio](../manual/maintenance/upgrading-istio.md).

## Ambient, not sidecars

Classic Istio injects an Envoy container into every pod. Ambient mode does not.

| | Sidecar | Ambient |
| --- | --- | --- |
| Per pod | An extra container, extra memory, and a restart to enrol | Nothing |
| Per node | — | One `ztunnel` pod |
| Enrolling a namespace | Restarts every pod in it | One label, no restart |
| L7 | Always, whether wanted or not | Only where a waypoint is added |

On six small guests, a container per pod is a real cost and a restart of every
workload is a real risk. Ambient is the reason this is worth having here at all.

## The two proxies

**ztunnel** is a DaemonSet in `istio-system`, one pod per node, in the host
network namespace. It handles L4: identity, mutual TLS, and L4 authorization.
It is the whole data plane as this cluster is configured.

**A waypoint** is a proxy for L7 — HTTP routing, retries, per-path policy. There
are none here yet. One is added per namespace or per service when something
actually needs L7, and nothing has to change elsewhere when it is.

**istiod** is the control plane. It issues the certificates ztunnel presents and
programs what it does with them. It also registers the `istio-waypoint`
GatewayClass, which is what a waypoint would be created from.

**istio-cni** is a DaemonSet that sets up traffic redirection inside a pod's
network namespace when that pod joins. It is not a CNI plugin of its own: it
chains onto Cilium's.

## Joining is one label

```yaml
metadata:
  labels:
    istio.io/dataplane-mode: ambient
```

on a namespace. Every pod in it is redirected through the node's ztunnel from
that moment, with no restart. Removing the label takes it back out, just as
fast. That is the rollback for everything below.

What is enrolled:

| Namespace | Where it is set |
| --- | --- |
| Every project namespace | `gitops/charts/project/templates/namespace.yaml` |
| `gateway-system` | `gitops/system/base/kgateway/namespace.yaml` |
| `homepage` | `gitops/applications/base/homepage/namespace.yaml` |

`gateway-system` holds the Envoy pods kgateway provisions for the Gateways.
Enrolling it is what makes traffic encrypted from the edge rather than only
between workloads, and what lets a future policy name the Gateway's identity
instead of an address. Traffic arriving from outside the cluster is unaffected:
an unenrolled caller is passed through as it is.

## Cilium had to give up three things

Cilium and Istio both want to touch the same packets. Three values in
`gitops/system/base/cilium/cilium.yaml` are what keeps them out of each other's
way.

| Value | Why |
| --- | --- |
| `socketLB.hostNamespaceOnly: true` | Cilium's socket load balancer rewrites a connection's destination inside the pod's own network namespace, before ztunnel's redirect can see it. Limiting it to the host namespace leaves ambient traffic intact; pods still reach Services, one hop later. |
| `cni.exclusive: false` | Cilium's default is to delete any CNI configuration it did not write. istio-cni's would be removed on every agent restart. |
| `bpf.masquerade` left off | The default, iptables masquerading, works. The BPF implementation does not handle Istio's link-local probe address the same way, and pod health checks start failing. |

`kubeProxyReplacement` stays **true**. Cilium's documentation calls turning it
off the simpler path for Istio, and it is not an option here: L2 announcements
require it, and L2 announcements are how the Gateways get `10.10.10.200` and
`.201`. See [Getting traffic into the cluster](./ingress.md).

## What enrolling does to NetworkPolicy

This is the part that surprises people, so it gets its own section.

Between two enrolled pods, the connection no longer arrives on the
application's port. It arrives on **port 15008**, the HBONE port, carrying the
real connection inside mutual TLS. Cilium sees 15008 and nothing else.

Three consequences:

1. **The default-deny NetworkPolicy every project gets drops all of it.** The
   `allow-hbone` policy beside it opens 15008 in both directions. Without it an
   enrolled namespace looks like a broken network.
2. **Port-level NetworkPolicy stops meaning anything east-west.** A rule
   allowing port 8080 and denying 5432 no longer distinguishes them, because
   both are 15008 now. Cilium still keeps a namespace off the rest of the
   cluster; what it can no longer do is be specific inside the mesh.
3. **That specificity moves to Istio.** An `AuthorizationPolicy` can still say
   who may talk to whom, and says it better: by service account identity rather
   than by address. There are none yet.

`allow-hbone` allows 15008 to and from namespaces in the same environment, and
nothing else. That is the one distinction still worth drawing at this port: it
keeps dev and prod apart at the packet level, which is what
[Getting traffic into the cluster](./ingress.md) says they are. Inside an
environment it is wide open, and narrowing it further would look like security
and provide none — every connection is 15008 and the port no longer says what
the caller asked for.

It has no rule for `gateway-system`. A workload is exposed by writing a policy
for it, exactly as before; the only change is that the policy names port 15008
rather than the application's own. See
[Exposing a service](../manual/maintenance/exposing-a-service.md).

Kubelet's health probes reach an enrolled pod SNAT-ed from a link-local address
Istio picks, which Cilium has no way to exempt from policy. The
`CiliumClusterwideNetworkPolicy` in `gitops/system/base/istio/host-probes.yaml`
is that exemption. Without it an enrolled pod passes no probe and never becomes
Ready.

## Cilium L7 policy is off-limits

Cilium can enforce HTTP rules, and so can Istio. Running both is a split brain:
two proxies with two ideas of what a request is allowed to do, and no way to
tell which one dropped it. Cilium's L7 policy is not used anywhere in this repo,
and while ambient is on it must stay that way. An L7 rule written against port
15008 in particular breaks all traffic, since the HTTP inside is encrypted.

To take a workload back for Cilium L7, remove it from ambient first.

## How it is installed

Four Applications, in `gitops/system/base/istio/`, all pinned to the same
version.

| Wave | Application | Chart |
| --- | --- | --- |
| 0 | `istio-base` | `base` — CRDs and cluster roles |
| 1 | `istiod` | `istiod`, with `profile: ambient` |
| 2 | `istio-cni` | `cni`, with `profile: ambient` |
| 2 | `ztunnel` | `ztunnel` |

The CRDs come from the `base` chart rather than from
`gitops/crds/base/kustomization.yaml`, where the rest of the cluster's CRDs
live. Istio publishes them nowhere else. The rule that a chart's CRDs are never
upgraded is a Helm rule, and ArgoCD is not Helm: it renders the chart and
applies what comes out, CRDs included, on every sync.

An `ambient` umbrella chart exists upstream and is not used. It hides the CRDs
in a subchart and gives no ordering between the four, which is what the waves
are for.

## Talos-specific settings

There are none, which is worth stating because it is not obvious:

- Talos puts CNI binaries in `/opt/cni/bin` and configuration in
  `/etc/cni/net.d`. Those are the chart's defaults, so `cniBinDir` and
  `cniConfDir` are deliberately not set.
- There is no `global.platform` value for Talos. It stays unset.

Two things do need saying explicitly:

- `istio-system` carries `pod-security.kubernetes.io/enforce: privileged`.
  ztunnel and istio-cni are host-network and hold `NET_ADMIN` and `SYS_ADMIN`.
  Talos enforces `baseline` on any namespace that does not say otherwise, and
  baseline rejects both.
- `istio-system` carries a ResourceQuota scoped to `system-node-critical`.
  Without it the two DaemonSets are refused at admission, report no error of
  their own, and simply never place a pod.

## What this costs

A DaemonSet on every node in the path of every packet between enrolled pods.
When ztunnel is unhealthy on a node, the pods on that node lose connectivity to
the rest of the mesh, and the failure looks like a network fault rather than
like Istio. It is a second thing that can break the network, on top of Cilium.

The trade is identity: knowing, and being able to prove, which workload opened a
connection. Nothing else in this cluster can answer that.

Where the pieces live:

| What | Where |
| --- | --- |
| The four Applications, the namespace, the probe policy | `gitops/system/base/istio/` |
| The three Cilium values it depends on | `gitops/system/base/cilium/cilium.yaml` |
| `allow-hbone`, and the label every project gets | `gitops/charts/project/templates/` |
