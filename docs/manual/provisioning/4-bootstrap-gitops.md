# Manual 4 - Bootstrap GitOps

This installs ArgoCD, and through it kgateway and the Gateways that make
workloads reachable. After it, changing what runs in the cluster is a commit to
this repo.

Before you start, finish
[Provision the Kubernetes cluster](./3-provision-cluster.md). All six nodes must
be `Ready`:

```bash
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes
```

```
NAME       STATUS   ROLES           AGE   VERSION
cp-1       Ready    control-plane   35h   v1.36.2
cp-2       Ready    control-plane   35h   v1.36.2
cp-3       Ready    control-plane   35h   v1.36.2
worker-1   Ready    <none>          35h   v1.36.2
worker-2   Ready    <none>          35h   v1.36.2
worker-3   Ready    <none>          35h   v1.36.2
```

Your own device must be on the mesh and accepting subnet routes, as in step 3.
[GitOps with ArgoCD](../../concepts/gitops.md) explains the layout this applies.

## 1. Installing the tools

On **your own machine**, in addition to step 3's tools:

```bash
brew install kustomize helm yq
```

`helm` is never run directly. `kustomize` calls it to inflate the ArgoCD chart,
and refuses to without it installed. `yq` is only needed to recover a cluster
whose CNI is broken; see
[Upgrading Cilium](../maintenance/upgrading-cilium.md).

## 2. Checking what would be applied

```bash
task cluster:render
```

```
Both overlays render.
```

This needs no cluster and catches most mistakes. Run it before every commit.

## 3. Putting the age key in the cluster

Every secret this cluster needs is committed to this repo, encrypted, and
decrypted in the cluster by sops-secrets-operator. The key that does that
decrypting is the one thing that cannot be committed: it would be the lock and
the key in the same box.

`task secrets:init` created it, at `~/.config/sops/age/keys.txt`. Push it in:

```bash
task cluster:sops-key
```

```
namespace/sops created
secret/sops-age-key created
Cluster key in place. Every other secret comes from git.
```

This is the only command in this guide that moves a secret by hand, and the
only one to repeat after a rebuild.

**This is the same key that decrypts `secrets.enc.yaml`**, so the cluster can
read every credential in this repo, including the Proxmox root password and the
R2 state credentials. That is a deliberate choice in favour of one key to hold
and back up. It means a compromise of the cluster is a compromise of those
credentials too, and rotating means re-encrypting everything rather than just
`gitops/`. [Secrets with SOPS](../../concepts/sops.md) has the alternative.

## 4. Filling in the Cloudflare DNS token

cert-manager and external-dns both need a Cloudflare API token. The encrypted
file holding it is committed with an empty value, so this is a one-time edit.

This is the **DNS** token, and it is the only Cloudflare token anything here
holds. The public path needs no second one: a tunnel is an account resource, but
it is created by hand in
[Opening the tunnel](./5-open-the-tunnel.md) and its credentials are committed
encrypted, so no account-scoped token is ever stored.

Create the token first, in the [Cloudflare
dashboard](https://dash.cloudflare.com) under **My Profile**, **API Tokens**:

| Field | Value |
| --- | --- |
| Permissions | `Zone` - `DNS` - `Edit` |
| Zone Resources | Include - Specific zone - `grncunha.com` |

Cloudflare shows it once. Put it straight in:

```bash
task secrets:edit:cluster -- gitops/system/base/cert-manager/cloudflare-token.sops.yaml
task secrets:edit:cluster -- gitops/system/base/external-dns/cloudflare-token.sops.yaml
```

Your editor opens on the decrypted file. Set `api-token`, then save; SOPS
re-encrypts on close. One file per namespace, because a `Secret` is only
readable in its own.

```bash
task secrets:check
```

```
secrets.enc.yaml is encrypted.
gitops/system/base/cert-manager/cloudflare-token.sops.yaml is encrypted.
gitops/system/base/external-dns/cloudflare-token.sops.yaml is encrypted.
```

Commit the file. It is meant to be committed: the value inside is ciphertext,
and only the two age keys open it.

## 5. Bootstrapping

```bash
task cluster:bootstrap
```

The last line is:

```
Bootstrapped. Check it with: kubectl -n argocd get applications
```

This applies the same manifests ArgoCD then syncs, so it is repeatable: run it
again and nothing changes. That is also how you repair a broken ArgoCD.

## 6. Watching it converge

The first sync takes a few minutes. kgateway's CRDs have to be established
before its controller starts, and the Gateways cannot be created until both are
done.

```bash
kubectl -n argocd get applications
```

```
NAME                      SYNC STATUS   HEALTH STATUS
cert-manager              Synced        Healthy
cilium                    Synced        Healthy
crds                      Synced        Healthy
...
system                    Synced        Healthy
```

One row per directory in `gitops/system/base/`, and what you are checking is
that **every** row reads `Synced` and `Healthy` — not that a particular set is
present. The list grows whenever a component is added.

`system` sits `OutOfSync` or `Degraded` for the first minute or two, because it
creates `GatewayParameters` before kgateway has registered that kind. ArgoCD
retries on its own. If it is still degraded after five minutes, something is
actually wrong.

Anything claiming a volume stays `Progressing` until `local-path-provisioner` is
`Healthy` and the claim binds. That covers most of the observability stack; see
[Seeing what the cluster is doing](../../concepts/observability.md).

## 7. Checking an address became live

This is the step that proves the load balancer works. See
[Getting traffic into the cluster](../../concepts/ingress.md) for what is
happening.

```bash
kubectl -n gateway-system get svc
```

```
NAME                      TYPE           EXTERNAL-IP     PORT(S)
gw-internal-prod          LoadBalancer   10.10.10.200    80:31234/TCP
gw-internal-dev           LoadBalancer   10.10.10.201    80:30991/TCP
gw-public                 ClusterIP      <none>          80/TCP
```

`<pending>` under `EXTERNAL-IP` means the address pool is missing or Cilium's LB
IPAM is off. Check `kubectl get ciliumloadbalancerippool`.

Then, from your own machine on the mesh:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://10.10.10.200
```

```
404
```

A `404` is success: it is Envoy answering, saying no route matches. A timeout
means the address exists but nothing answers ARP for it, which is almost always
the interface name in the announcement policy. Confirm the real one:

```bash
talosctl --nodes 10.10.10.21 get addresses | grep 10.10.10.21/24
```

```
10.10.10.21   network   AddressStatus   eth0/10.10.10.21/24   1   10.10.10.21/24   eth0
```

The last column must match `interfaces` in
`gitops/system/base/cilium/l2-announcement.yaml`.

## 8. Checking DNS and certificates happened on their own

Both wildcards must be issued. The first pair takes a couple of minutes: a
DNS-01 challenge waits for a Cloudflare record to propagate.

```bash
kubectl -n gateway-system get certificate
```

```
NAME               READY   SECRET                 AGE
wildcard-dev-k8s   True    wildcard-dev-k8s-tls   3m
wildcard-k8s       True    wildcard-k8s-tls       3m
```

`READY: False` for more than five minutes means the token is wrong or too
narrowly scoped. cert-manager says which:

```bash
kubectl -n gateway-system describe certificate wildcard-k8s
kubectl -n cert-manager logs deploy/cert-manager | tail -20
```

Then check external-dns wrote the records:

```bash
dig +short argocd.k8s.homelab.grncunha.com
```

```
10.10.10.200
```

Nothing back means external-dns has not run yet, or the route's hostname falls
outside its domain filter. Its log says which:

```bash
kubectl -n external-dns logs deploy/external-dns | tail -20
```

## 9. Reaching the ArgoCD UI

From a device on the mesh, open
[`argocd.k8s.homelab.grncunha.com`](https://argocd.k8s.homelab.grncunha.com).
The page loads over HTTPS with no certificate warning. Three more answer the
same way:

| UI | Name |
| --- | --- |
| Hubble, what is talking to what | `hubble.k8s.homelab.grncunha.com` |
| Grafana, the dashboards | `grafana.k8s.homelab.grncunha.com` |
| VictoriaLogs, what every pod printed | `victoria-logs.k8s.homelab.grncunha.com` |

ArgoCD's anonymous access is read-only and there is no admin user, which is
deliberate: see [GitOps with ArgoCD](../../concepts/gitops.md). Grafana does
have one, and its password comes from a `SopsSecret`; see
[Seeing what the cluster is doing](../../concepts/observability.md).

If the name does not resolve, your device is not on the mesh, or is not
accepting subnet routes. The Gateways still answer by address, which is how you
tell a DNS problem from a routing one:

```bash
curl -skS -o /dev/null -w '%{http_code}\n' \
  -H 'Host: argocd.k8s.homelab.grncunha.com' http://10.10.10.200
```

```
200
```

## Troubleshooting

**`task cluster:render` fails with `must specify --enable-helm`.** The task
passes it. This means something ran `kustomize build` by hand.

**`kubectl apply` fails on a conflict.** The task passes `--force-conflicts` for
exactly this. Same cause as above.

**An `Application` stays `OutOfSync` with `the server could not find the
requested resource`.** It needs a CRD from an earlier wave. Check the wave
ordering in [GitOps with ArgoCD](../../concepts/gitops.md), and that the `crds`
Application is `Synced`.

**A `Gateway` never gets an address.** Work down the chain, stopping at the
first thing that is wrong:

```bash
kubectl -n gateway-system get gateway
kubectl -n gateway-system get svc
kubectl get ciliumloadbalancerippool
kubectl get ciliuml2announcementpolicy
```

No Gateway at all means kgateway is not running. A Gateway but no Service means
kgateway has not accepted it, and `kubectl -n gateway-system describe gateway`
says why. A Service stuck `<pending>` means the pool is missing.

**A `Certificate` stays `READY: False`.** Work outward from the challenge:

```bash
kubectl -n gateway-system describe certificate wildcard-k8s
kubectl -n gateway-system get challenge
```

`propagation check failed` means the token cannot write the zone. Check the
Secret the operator produced actually holds a value:

```bash
kubectl -n cert-manager get secret cloudflare-api-dns-token \
  -o jsonpath='{.data.api-token}' | base64 -d | wc -c
```

Zero means the encrypted file still has the placeholder. Anything else means
the token is wrong, or not scoped to `Zone` - `DNS` - `Edit` on `grncunha.com`.

**A Gateway serves the wrong certificate, or none.** The `Secret` cert-manager
writes must be in the same namespace as the Gateway. Both are `gateway-system`;
`kubectl -n gateway-system get secret` should list both `-tls` secrets.

**No Secret appears from a `SopsSecret`.** The operator could not decrypt it.

```bash
kubectl -n sops logs deploy/sops-secrets-operator | tail -20
kubectl get sopssecret -A
```

`no matching keys found` means the key is missing from the cluster, or is not a
recipient of that file. `task cluster:sops-key` puts it back; if `.sops.yaml`
changed since the file was encrypted, re-encrypt it with `sops updatekeys <file>`.

**Starting over.** `task tofu:destroy` and `task tofu:apply` rebuild the cluster
from nothing, then `task cluster:sops-key` and `task cluster:bootstrap`. Nothing
else here is stored only in the cluster: every other secret comes back from git.

## Next

The cluster serves the mesh. To publish a workload to the internet, continue
with [Opening the tunnel](./5-open-the-tunnel.md).
