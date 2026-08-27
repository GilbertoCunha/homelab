# Backlog

What is not built yet, and what it is waiting on. An item leaves this file when
it is done, not when it is started.

## Public access, with `cloudflared`

**Nothing is reachable from the internet yet.** The mesh path works end to end;
the public one is built up to the last hop and stops there.

`gw-public` already exists and already has an `HTTPRoute` listener on
`*.apps.homelab.grncunha.com`. It is a `ClusterIP`, so nothing outside the
cluster can dial it, and nothing does. What is missing is the thing that dials
it from inside.

### What it needs

| Piece | Where |
| --- | --- |
| Tunnel | `opentofu/project/cloudflare.tf`. OpenTofu creates it, so nothing is done in the dashboard |
| Credentials | `gitops/secrets/base/cloudflared.sops.yaml`, copied once from `tofu output` |
| `cloudflared` | A `Deployment`, two replicas, in `gitops/system/base/` |
| Routing | A ConfigMap, so the routing table is in git rather than the Cloudflare dashboard |
| DNS | A `cloudflare-proxied: "true"` annotation on `gw-public`, plus `target: <tunnel-id>.cfargotunnel.com`. external-dns writes the rest |

One catch-all ingress rule is enough:
`*.apps.homelab.grncunha.com` to `http://gw-public.gateway-system.svc:80`, with
the `Host` header preserved. Adding a public app then never touches this config
again -- it is one more `HTTPRoute`, exactly like a mesh one.

### A second Cloudflare token

A tunnel is an **account** resource. The token the cluster already holds is
`Zone` - `DNS` - `Edit` on `grncunha.com`, and a zone-scoped token cannot
express an account permission at all, so this is a second token rather than a
wider one:

| Name | Scope | Read by |
| --- | --- | --- |
| `cloudflare-api-dns-token` | `Zone` - `DNS` - `Edit` on `grncunha.com` | cert-manager and external-dns, in the cluster |
| `CLOUDFLARE_API_TUNNEL_TOKEN` | `Account` - `Cloudflare Tunnel` - `Edit` | OpenTofu, on your machine |

Widening the first would put account-wide tunnel rights on two workloads that
never use them. Splitting also puts each token in the home the repo already has
for it: the cluster's in `gitops/secrets/`, and OpenTofu's in `secrets.enc.yaml`
beside the other keys `sops exec-env` supplies. The new key goes in
`task secrets:init` and nowhere else.

### Why OpenTofu creates the tunnel

`cloudflare_zero_trust_tunnel_cloudflared` takes `tunnel_secret` as an **input**,
not an output. The credentials are therefore a function of state rather than a
value Cloudflare shows once, which is the whole reason the Proxmox token is
minted by hand and this one is not.

- `random_password`, 32 bytes, base64, supplies `tunnel_secret`. It joins the
  cluster PKI already in state.
- **`config_src = "local"`** is the load-bearing setting. It tells Cloudflare the
  ingress rules live on the connector, which is what makes the ConfigMap the
  source of truth instead of a copy of the dashboard.
- The `cloudflare` provider is pinned in `versions.tf` like the others. The
  account id goes in `terraform.tfvars`; it is the same identifier already in
  `backend.tofu` for R2.

`cloudflared` authenticates with a credentials file rather than a tunnel token,
because OpenTofu knows all three of its fields and a token would be a fourth
thing to fetch:

```json
{ "AccountTag": ..., "TunnelID": ..., "TunnelSecret": ... }
```

The tunnel id is copied into the `gw-public` annotation by hand, once. OpenTofu
must not write that CNAME itself: external-dns owns DNS for the cluster, and two
writers on one name is a conflict. The id is an identifier, not a secret, so it
is committed like any other.

### Why it is shaped this way

The tunnel opens itself, outbound. Nothing new listens on the host, the firewall
does not change, and the server keeps accepting `22`, `80` and `443` and nothing
else. That is the whole reason for choosing a tunnel over a port forward.

A tunnel CNAME only resolves when proxied, which is the one place in this repo
where an orange cloud is correct. Everything else made by hand must stay DNS
only; see [Names](./architecture/names.md).

`gw-public` needs no certificate. Cloudflare terminates TLS at the edge and the
tunnel carries its own, so the last hop is inside the cluster.
[Getting traffic into the cluster](./concepts/ingress.md) has the reasoning.

### Done when

An app on `*.apps.homelab.grncunha.com` answers over HTTPS from a device that is
**not** on the mesh, `cloudflared` logs four registered connections, and an
`nmap` of the server from outside still shows only `22`, `80` and `443`.

## Persistent storage

Nothing has any. A pod asking for a volume stays `Pending`, and that is expected
rather than broken. ArgoCD and cert-manager do not need it; most real
applications do, so this is what blocks the cluster being useful for anything
that keeps state.

No decision made yet on what provides it.
