# Manual 4 - Bootstrap GitOps

This installs ArgoCD, and through it kgateway and the Gateways that make
workloads reachable. It is the last provisioning step; everything after it is a
commit to this repo.

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
brew install kustomize helm
```

`helm` is never run directly. `kustomize` calls it to inflate the ArgoCD chart,
and refuses to without it installed.

## 2. Checking what would be applied

```bash
task cluster:render
```

```
Both overlays render.
```

This needs no cluster and catches most mistakes. Run it before every commit.

## 3. Bootstrapping

```bash
task cluster:bootstrap
```

The last line is:

```
Bootstrapped. Check it with: kubectl -n argocd get applications
```

This applies the same manifests ArgoCD then syncs, so it is repeatable: run it
again and nothing changes. That is also how you repair a broken ArgoCD.

## 4. Watching it converge

The first sync takes a few minutes. kgateway's CRDs have to be established
before its controller starts, and the Gateways cannot be created until both are
done.

```bash
kubectl -n argocd get applications
```

```
NAME      SYNC STATUS   HEALTH STATUS
crds      Synced        Healthy
network   Synced        Healthy
system    Synced        Healthy
```

`network` sits `OutOfSync` or `Degraded` for the first minute or two, because it
creates `GatewayParameters` before kgateway has registered that kind. ArgoCD
retries on its own. If it is still degraded after five minutes, something is
actually wrong.

## 5. Checking an address became live

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
`gitops/network/base/l2-announcement.yaml`.

## 6. Reaching the ArgoCD UI

The UI is on the mesh, at `argocd.k8s.homelab.grncunha.com`. Until external-dns
and cert-manager are in place, that name does not resolve and there is no
certificate, so reach it by address and `Host` header:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H 'Host: argocd.k8s.homelab.grncunha.com' http://10.10.10.200
```

```
200
```

Anonymous access is read-only and there is no admin user, which is deliberate:
see [GitOps with ArgoCD](../../concepts/gitops.md).

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

**Starting over.** `task tofu:destroy` and `task tofu:apply` rebuild the cluster
from nothing, then `task cluster:bootstrap` again. Nothing here is stored only
in the cluster.
