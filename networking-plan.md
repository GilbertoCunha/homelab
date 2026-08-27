# Exposing cluster workloads: public and mesh-only

## Context

The six-node Talos cluster runs, but **nothing can be exposed from it**. Cilium
is the CNI and the kube-proxy replacement, and nothing more: there is no
LoadBalancer implementation, no L2 or BGP announcement, no Gateway API, no
ingress controller. A `Service` of `type: LoadBalancer` would sit `<pending>`
forever. `README.md` claims "Public Access: Cloudflare tunnels", but no tunnel
exists anywhere in the repo.

Today the only public ingress is Caddy on the host, serving two names it owns by
hand. That does not extend to the cluster: the guests have no public address, and
adding one per app would mean the host firewall and the Caddyfile grow with every
workload.

This plan builds both exposure paths, one prod environment and one dev, with
certificates and DNS records created automatically so that adding a service is a
single `HTTPRoute` and nothing else.

## Decisions taken

| Decision | Choice |
| --- | --- |
| Gateway API implementation | **kgateway**, not Cilium's. Cilium's `gatewayAPI` stays off. |
| Bare-metal LoadBalancer | **Cilium LB IPAM + L2 announcements** |
| Public path | **Cloudflare Tunnel**, `cloudflared` in-cluster |
| Deployment | **Argo CD**, this plan only defines what it syncs |
| Cluster secrets | **`sops-secrets-operator`**, second age key, no Sealed Secrets |
| Dev environment | **mesh only** — no public dev zone, no dev tunnel |

## How a LoadBalancer works here

This is the piece with no cloud equivalent, so it is worth stating plainly.

1. A `CiliumLoadBalancerIPPool` reserves `10.10.10.200`–`10.10.10.250` out of the
   guest bridge subnet. That range is the load balancer's address space. Node
   addresses at `.11`–`.13` and `.21`–`.23` are untouched — these are extra
   addresses that belong to Services, not to machines.
2. A `Service` of `type: LoadBalancer` is assigned one from the pool.
3. A `CiliumL2AnnouncementPolicy` makes one `cilium-agent` win a lease and
   **answer ARP for that address on the guest bridge**. That is the whole
   mechanism: the address becomes live on `vmbr1` with no appliance and no BGP.
4. The server is `10.10.10.1`, the gateway for that bridge. It already advertises
   `10.10.10.0/24` into Headscale, the route is already approved, and the ACL
   already permits `{{ headscale_user }}@ → 10.10.10.0/24:*`.

So a mesh device reaches `10.10.10.200` the moment the address exists. **No new
mesh plumbing, no ACL change, no firewall change** — the nftables forward rules
are written against interfaces (`tailscale0 ↔ vmbr1`), not addresses.

Failover is a lease timeout, roughly fifteen seconds. BGP peering with the host
would be faster and is what a larger site would do, but it means running FRR on
the server for six VMs on one bridge. Not worth it here.

## Names

| Environment | Public | Mesh only |
| --- | --- | --- |
| prod | `<app>.apps.homelab.grncunha.com` | `<app>.k8s.homelab.grncunha.com` → `.200` |
| dev | — | `<app>.dev.k8s.homelab.grncunha.com` → `.201` |

Three Gateways, one tunnel, two wildcard certificates.

**The public Gateways need no certificate.** Cloudflare terminates TLS at the
edge, `cloudflared` dials out over its own TLS tunnel, and the last hop is inside
the cluster. cert-manager therefore issues only the two mesh wildcards.

Wildcards do not nest, so `*.k8s.homelab.grncunha.com` does not cover
`app.dev.k8s.homelab.grncunha.com`. Two certificates are genuinely needed.

## Architecture

```
internet ──▶ Cloudflare edge ──▶ tunnel ──▶ cloudflared (in cluster)
                                              └──▶ gw-public  (ClusterIP)
                                                     └──▶ HTTPRoute ──▶ prod apps

your laptop ──▶ mesh ──▶ 10.10.10.0/24 (routed by the server)
                          ├──▶ 10.10.10.200  gw-internal-prod ──▶ prod apps
                          └──▶ 10.10.10.201  gw-internal-dev  ──▶ dev apps
```

Nothing new listens on the host. Ports stay `22, 80, 443`; `cloudflared` only
makes outbound connections. Caddy keeps serving Headscale and Proxmox and learns
nothing about the cluster.

### Environment isolation

Each Gateway listener sets `allowedRoutes.namespaces.from: Selector`, matching a
label on the namespace (`env: prod` / `env: dev`). A dev namespace **cannot**
attach a route to a prod Gateway; the API server rejects it. This is the primary
isolation boundary, backed by `CiliumNetworkPolicy` denying dev → prod traffic —
which is the NetworkPolicy enforcement `docs/concepts/cilium.md` chose Cilium for.

## Changes

### 1. Cilium — `opentofu/project/cilium.tf`

The only OpenTofu change. Add to the rendered values:

```hcl
l2announcements = { enabled = true }

# L2 leases are renewed constantly; the chart's default client rate limit is
# too low and the agent starts logging throttle warnings.
k8sClientRateLimit = { qps = 20, burst = 100 }
```

Leave `gatewayAPI` and `ingressController` **off** — kgateway is the
implementation, and two of them would fight over the same CRDs.

This is an inline manifest, so it reaches the nodes as a control-plane machine
config change. Expect exactly three changed resources and no VM replacement, the
same shape as `docs/manual/maintenance/upgrading-cilium.md` describes.

### 2. Address allocation — `README.md`

Amend the guest address table:

| Address | Guest |
| --- | --- |
| `10.10.10.100`-`.199` | Free, for anything that is not a cluster node |
| `10.10.10.200`-`.250` | Kubernetes LoadBalancer pool, assigned by Cilium |
| `10.10.10.251`-`.254` | Free |

Also update the names table with the two new wildcards, correct the architecture
diagram, and make the "Public Access: Cloudflare tunnels" line true.

### 3. Cluster secrets — `.sops.yaml`, `Taskfile.yaml`

A second age key, so the master key never enters the cluster.

- `task secrets:init` gains `age-keygen` for a cluster key and a second
  `creation_rule` in `.sops.yaml` for `k8s/**/*.sops.yaml`, listing **both**
  recipients. `secrets.enc.yaml` keeps only the personal recipient, so the
  cluster key cannot decrypt it.
- A new `task cluster:sops-key` creates the age Secret with `kubectl`. It runs
  once per cluster build and is the one bootstrap step outside git. It is
  deliberately not an OpenTofu resource: that would put the key in state.
- New key names in `secrets.enc.yaml`: `CLOUDFLARE_API_TOKEN` (scoped to
  `Zone:DNS:Edit` on `grncunha.com` only) and the tunnel credentials.
  `task secrets:init` owns the list, per `AGENTS.md`.

Everything after this point is a `SopsSecret` in git, decrypted in-cluster.

### 4. What Argo CD syncs — new `k8s/` tree

Argo CD is yours to configure; this is the dependency order it must respect,
expressed as sync waves.

| Wave | Component | Notes |
| --- | --- | --- |
| 0 | Gateway API CRDs (standard channel), `sops-secrets-operator`, cert-manager | kgateway will not install without the CRDs |
| 1 | `SopsSecret` for the Cloudflare token, `CiliumLoadBalancerIPPool`, `CiliumL2AnnouncementPolicy` | |
| 2 | kgateway, external-dns, cloudflared | |
| 3 | The three Gateways, the two `Certificate` resources | |
| 4 | Applications | |

**`CiliumL2AnnouncementPolicy`**: `loadBalancerIPs: true`, `externalIPs: false`,
node selector restricted to workers, and an `interfaces` regex matching the
virtio interface. Confirm the real name on a node first — Talos with
`driver = "virtio_net"` typically gives `ens18` or `eth0`, and a wrong regex
fails silently with the address simply never answering ARP.

**external-dns**: one instance, Cloudflare provider, writing into `grncunha.com`.
Two `--domain-filter` values, `apps.homelab.grncunha.com` and
`k8s.homelab.grncunha.com`, so the hand-made records for `homelab`,
`vpn.homelab` and `proxmox.homelab` are outside its reach by construction, not
by TXT ownership alone. Source `gateway-httproute`, plus a distinct
`--txt-owner-id`.

Record type is decided by annotations on each Gateway:

| Gateway | Annotations | Result |
| --- | --- | --- |
| `gw-public` | `target: <tunnel-id>.cfargotunnel.com`, `cloudflare-proxied: "true"` | `CNAME`, proxied. A tunnel CNAME only works proxied. |
| `gw-internal-*` | `cloudflare-proxied: "false"` | `A` → the LB IP, DNS only |

The internal records hold a private address in public DNS. That is fine and
deliberate: the name resolves for everyone, and only a mesh device can route to
it. It also means no split-horizon entry in Headscale's `extra-records.json`,
which stays owned by the `mesh_node` role.

**cert-manager**: one `ClusterIssuer`, ACME with a **DNS-01** solver against
Cloudflare. DNS-01 rather than HTTP-01 because the names point at an
unroutable-from-the-internet address, and because it is the only challenge that
issues wildcards.

**cloudflared**: `Deployment`, two replicas, locally-managed config in a
ConfigMap so the routing table lives in git rather than the Cloudflare dashboard.
Credentials come from the `SopsSecret`. A single catch-all ingress rule:
`*.apps.homelab.grncunha.com` → `http://gw-public.gateway-system.svc:80`, Host
header preserved. Adding a public app never touches this config.

**kgateway**: provisions an Envoy `Deployment` and `Service` per Gateway.
`GatewayParameters` sets `gw-public` to `ClusterIP` and the two internal Gateways
to `LoadBalancer`, which is what draws from the Cilium pool. Give the internal
ones `externalTrafficPolicy: Local` so the client's mesh address survives to the
backend and can be used in policy.

First tenants, both on `gw-internal-prod`: the Argo CD UI and Hubble UI.

### 5. Documentation

Per `AGENTS.md`, the explanation and the procedure are separate documents.

| File | Contents |
| --- | --- |
| `docs/concepts/ingress.md` | New. The two paths, why LB IPAM + L2 rather than BGP, why kgateway over Cilium's Gateway API, why the public Gateway needs no certificate |
| `docs/concepts/gitops.md` | New. Argo CD layout, sync waves, why `SopsSecret` and not Sealed Secrets |
| `docs/manual/provisioning/4-bootstrap-gitops.md` | New. Cluster age key, Argo CD install, the root Application |
| `docs/manual/maintenance/exposing-a-service.md` | New. The day-to-day procedure: pick a Gateway, write an `HTTPRoute`, commit |
| `docs/concepts/cilium.md` | Add the L2 announcement values and what they are for |
| `docs/concepts/sops.md` | Add the cluster key, the second recipient, and why the master key stays out |
| `docs/manual/index.md`, `docs/cheatsheet.md` | Link the new documents; add `kubectl get ciliuml2announcementpolicy`, `cilium status`, and the certificate check |

## Verification

Run in order. Each step gates the next.

1. **Cilium change applies cleanly.**
   `task tofu:plan` shows exactly three control-plane machine config changes and
   no VM replacement. After apply, `cilium status` reports all pods ready and
   `L2 Announcer: Enabled`.

2. **An address becomes live on the bridge.** With the pool and policy applied,
   `kubectl get svc -A` shows a real `EXTERNAL-IP`, not `<pending>`. From the
   server: `ping 10.10.10.200` answers, and `ip neigh show dev vmbr1` lists the
   address with a worker's MAC. If this fails, the interface regex in the
   announcement policy is wrong.

3. **The mesh reaches it.** From your laptop, on the mesh with
   `--accept-routes`: `curl -v http://10.10.10.200` returns the Gateway's 404,
   which proves routing works. No firewall or ACL change should have been
   needed; if it was, something in this plan is wrong.

4. **DNS and certificates are automatic.** Apply an `HTTPRoute` for
   `hubble.k8s.homelab.grncunha.com`. Within a minute
   `dig hubble.k8s.homelab.grncunha.com` returns `10.10.10.200`, and
   `kubectl get certificate -A` shows both wildcards `Ready: True`. Open the URL
   in a browser from a mesh device: the page loads with a valid certificate and
   no warning.

5. **The public path works and opens nothing.** `cloudflared` logs four
   registered connections. A public app answers over HTTPS from a device that is
   **not** on the mesh. Then, from outside: `nmap` the server and confirm only
   `22, 80, 443` are open, unchanged from before.

6. **Isolation holds.** An `HTTPRoute` in a namespace labelled `env: dev`
   referencing `gw-internal-prod` is rejected, showing `NotAllowedByListeners`.
   `hubble observe` shows dev → prod pod traffic dropped by policy.

7. **Repo checks.** `task ansible:lint`, `task ansible:check` (must show no
   changes — this plan touches no Ansible role), `task tofu:fmt`,
   `task tofu:validate`, `task secrets:check`.

8. **A rebuild still decrypts.** Not a routine check, but the reason for the two
   keys: after `tofu destroy` and a rebuild, `task cluster:sops-key` followed by
   an Argo CD sync brings every committed secret back with no re-encryption.

## Open questions

- **Argo CD's access to this repo.** If it stays private, Argo CD needs a deploy
  key, which is another bootstrap secret and would have to be placed alongside
  the age key.
- **Persistent storage.** `docs/cheatsheet.md` notes there is none yet.
  Argo CD and cert-manager are fine without it; most real applications are not.
  Out of scope here, but it is the next thing that blocks progress.
