# Upgrading Istio

Istio is four charts that must move together. While ztunnel is down, enrolled
pods cannot reach each other; unenrolled ones are unaffected. It is narrower
than a Cilium upgrade and wider than an application one.

How it got there is worth knowing first:
[Istio in ambient mode](../../concepts/istio.md).

## Before you start

**Read the upgrade notes for the version you are moving to.** Istio documents
per-version changes, and this document cannot substitute for them:
<https://istio.io/latest/news/releases/>

**Move one minor version at a time.** Istio supports one minor of skew between
the control plane and the data plane, and no more.

Check what is running now:

```bash
kubectl -n istio-system get daemonset ztunnel -o jsonpath='{.spec.template.spec.containers[0].image}'
```

```
docker.io/istio/ztunnel:1.30.4
```

## The procedure

The version is written in four files, all in `gitops/system/base/istio/`. They
must all say the same thing.

```bash
grep -rh targetRevision gitops/system/base/istio/ | sort -u
```

One line, or the four have already drifted apart:

```
    targetRevision: 1.30.4
```

1. Change all four to the new version, in one commit.
2. Render, to catch a version that does not exist before ArgoCD does:

   ```bash
   task cluster:render
   ```

   ```
   All overlays render, and every project in the catalog.
   ```

3. Push. The sync waves do the ordering: CRDs first, then istiod, then
   istio-cni and ztunnel.
4. Watch it land:

   ```bash
   kubectl -n istio-system rollout status daemonset/ztunnel
   ```

   ```
   daemon set "ztunnel" successfully rolled out
   ```

## Checking it worked

```bash
kubectl -n istio-system get pods
```

Every pod `Running`, one `ztunnel` and one `istio-cni-node` per node:

```
NAME                      READY   STATUS    RESTARTS   AGE
istio-cni-node-4kx2p      1/1     Running   0          2m
istiod-7d9f8c6b5-lm4wq    1/1     Running   0          3m
ztunnel-8sn7q             1/1     Running   0          2m
```

Then that traffic still flows through it:

```bash
istioctl ztunnel-config workload
```

Enrolled pods listed with protocol `HBONE`:

```
NAMESPACE  POD NAME              PROTOCOL  NODE
homepage   homepage-6c8f...      HBONE     homelab-worker-1
```

And that the cluster is still reachable, which is the only check that matters:

```bash
curl -sI https://home.k8s.homelab.grncunha.com | head -1
```

```
HTTP/2 200
```

## If it goes wrong

Set all four `targetRevision` values back and push. ArgoCD rolls the DaemonSets
back the same way it rolled them forward.

If the problem is that enrolled workloads cannot reach each other and the cause
is not obvious, take them out of the mesh rather than debugging under pressure:
remove `istio.io/dataplane-mode: ambient` from the namespace. Traffic returns to
plain TCP immediately, with no restart.

```bash
kubectl label namespace homepage istio.io/dataplane-mode-
```

`selfHeal` puts it straight back, so this only holds while you watch it. To
make it hold, remove the label in git: it is one line in the namespace, listed
in [Istio in ambient mode](../../concepts/istio.md).
