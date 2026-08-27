# Getting traffic into the cluster

Two questions this answers: how a workload becomes reachable, and why that takes
both Cilium and kgateway when either one looks like it could do the job alone.

To expose a workload once this is running, see
[Exposing a service](../manual/maintenance/exposing-a-service.md).

## Two paths

| Path | Names | Who can reach it |
| --- | --- | --- |
| Mesh, prod | `<app>.k8s.homelab.grncunha.com` | Devices on the mesh |
| Mesh, dev | `<app>.dev.k8s.homelab.grncunha.com` | Devices on the mesh |
| Public | `<app>.apps.homelab.grncunha.com` | Anyone |

```
internet ──▶ Cloudflare edge ──▶ tunnel ──▶ cloudflared (in cluster)
                                              └──▶ gw-public  (ClusterIP)

your laptop ──▶ mesh ──▶ 10.10.10.0/24 (routed by the server)
                          ├──▶ 10.10.10.200  gw-internal-prod
                          └──▶ 10.10.10.201  gw-internal-dev
```

Nothing new listens on the host. The server still accepts `22`, `80` and `443`
and nothing else, and Caddy learns nothing about the cluster.

## The two layers, and the one place they meet

This is the part that reads as a contradiction. Cilium is the CNI *and* can be a
Gateway API implementation. kgateway is a Gateway API implementation. Picking
kgateway looks like it should remove the need for Cilium here, and it does not.

Cilium ships two separate features:

| Cilium feature | What it does | Used here |
| --- | --- | --- |
| LB IPAM and L2 announcement | Fills in `EXTERNAL-IP` on a `Service` of `type: LoadBalancer`, and answers ARP for that address | **Yes** |
| `gatewayAPI` | Reconciles `Gateway` and `HTTPRoute` into proxy configuration | **No.** kgateway does this |

Only the second is turned off. A load balancer address is not a Gateway API
feature, so replacing the Gateway API implementation does not replace it.

They meet at exactly one object, and kgateway never talks to Cilium:

1. You write a `Gateway` with `gatewayClassName: kgateway`.
2. kgateway provisions an Envoy `Deployment` **and a `Service`** for it.
3. That Service asks to be a `LoadBalancer`.
4. Cilium's LB IPAM sees an unfilled request, takes `10.10.10.200` from the
   `CiliumLoadBalancerIPPool`, and one `cilium-agent` wins a lease and answers
   ARP for it on `vmbr1`.
5. A mesh device reaches that address. It is Envoy. Envoy matches the `Host`
   header against the `HTTPRoute`s attached to that Gateway.

So the whole integration is: **what type of Service does this Gateway get, and
what annotations does it carry.** `HTTPRoute` is untouched by any of it.

```
HTTPRoute ──attaches to──▶ Gateway ──kgateway provisions──▶ Envoy Deployment
                                                          + Service
                                                              │
                                            type: LoadBalancer│  type: ClusterIP
                                                              ▼        ▼
                                          Cilium assigns .200/.201  cloudflared
                                          + answers ARP on vmbr1    dials it
```

`GatewayParameters` is where that is written, in
`gitops/network/base/gateway-parameters.yaml`. The public Gateway takes
`ClusterIP` and no address, because nothing outside the cluster dials it
directly.

## Why L2 announcement and not BGP

A `Service` of `type: LoadBalancer` has no meaning on bare metal until something
claims the address on the network. There is no cloud to call.

The address is claimed by ARP. One `cilium-agent` wins a lease and answers for
`10.10.10.200` on the guest bridge, and the address is live with no appliance
and no routing protocol. The server at `10.10.10.1` already advertises
`10.10.10.0/24` into the mesh, that route is already approved, and the firewall
rules are written against interfaces rather than addresses. So an address in
this pool is reachable from the mesh the moment it exists: no ACL change, no
firewall change, no new mesh plumbing.

BGP peering with the host would fail over in under a second instead of the
fifteen or so a lease timeout takes. It also means running a routing daemon on
the server for six guests on one bridge. Not worth it here.

Two consequences worth knowing before you debug this at two in the morning:

- **The announcement policy names an interface, and a wrong name fails
  silently.** There is no error. The Service gets its address and the address
  never answers. On these workers it is `eth0`; confirm with
  `talosctl --nodes 10.10.10.21 get addresses`.
- **Addresses are pinned, not allocated.** LB IPAM gives no ordering guarantee,
  so each Gateway asks for its address by name with the
  `lbipam.cilium.io/ips` annotation. Without that, prod and dev could swap
  addresses across a rebuild and the DNS records would quietly follow.

## Why `externalTrafficPolicy: Local`

The mesh address of whoever is calling survives to the backend, so a
NetworkPolicy can be written against it. The cost is that Cilium only announces
a `Local` service from nodes that are running one of its pods. Each Gateway
therefore runs two Envoy replicas; with one, the address goes dark whenever that
node reboots.

## Why the public Gateway needs no certificate

Cloudflare terminates TLS at the edge. `cloudflared` makes an outbound
connection and carries its own TLS inside it. The last hop is inside the
cluster. So the public path has no certificate to manage, and the only
certificates this cluster issues are the two mesh wildcards.

Wildcards do not nest: `*.k8s.homelab.grncunha.com` does not cover
`app.dev.k8s.homelab.grncunha.com`. Two are genuinely needed.

## How prod and dev stay apart

Each Gateway listener uses `allowedRoutes.namespaces.from: Selector` against a
label on the namespace, `env: prod` or `env: dev`. A namespace without the
matching label **cannot** attach a route, and the API server is what refuses it,
not a convention. Cilium NetworkPolicy denying dev to prod traffic backs it up
at the packet level.

Adding a namespace to an environment is therefore one label. Forgetting it shows
up as `NotAllowedByListeners` on the route, not as traffic going somewhere it
should not.

## Where the pieces live

| What | Where |
| --- | --- |
| `l2announcements`, client rate limit | `opentofu/project/cilium.tf` |
| Address pool, announcement policy | `gitops/network/base/` |
| Service type per Gateway | `gitops/network/base/gateway-parameters.yaml` |
| The Gateways | `gitops/network/base/gateways.yaml` |
| kgateway itself | `gitops/system/base/kgateway/` |
| Address allocation table | [`README.md`](../../README.md) |
