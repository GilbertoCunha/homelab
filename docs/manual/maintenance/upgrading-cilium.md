# Upgrading Cilium

Cilium is the CNI and it also replaces kube-proxy, so it is not one workload
among many. While it is down, pods have no network and Services do not resolve
to anything. Treat this as a change to the cluster, not to an application.

How it got there is worth knowing first:
[The cluster's networking](../../concepts/cilium.md).

## Before you start

**Read the upgrade notes for the version you are moving to.** Cilium documents
per-version steps, and this document cannot substitute for them:
<https://docs.cilium.io/en/stable/operations/upgrade/>

**Move one minor version at a time.** 1.19 to 1.20 is supported. 1.18 to 1.20 is
not, and the way it fails is a broken cluster rather than a refusal.

Check what is running now:

```bash
kubectl -n kube-system get daemonset cilium -o jsonpath='{.spec.template.spec.containers[0].image}'
```

```
quay.io/cilium/cilium:v1.20.1@sha256:...
```

## The procedure

ArgoCD owns Cilium, so the upgrade is a commit. Talos created the CNI once, when
the cluster was born, and cannot change it now; see
[The cluster's networking](../../concepts/cilium.md).

**1. Bump the version.** It is written in exactly one place,
`gitops/system/base/cilium/cilium.yaml`:

```yaml
targetRevision: 1.20.2
```

**2. Check it still renders.**

```bash
task cluster:render
```

```
Both overlays render.
```

**3. Commit and push.** That is the upgrade. ArgoCD picks it up within the
reconciliation timeout, or immediately if you press Sync.

**4. Watch the rollout.**

```bash
kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
```

```
daemon set "cilium" successfully rolled out
```

**5. Bring the bootstrap render back in step.**

```bash
task tofu:apply
```

Expect **three** resources to change, and nothing else: the machine
configuration of `cp-1`, `cp-2` and `cp-3`. This changes nothing in the running
cluster — Talos will not re-apply it — but it is what a rebuilt cluster would be
born with, and skipping it leaves `tofu plan` permanently dirty.

| What the plan shows | What it means |
| --- | --- |
| 3 × `talos_machine_configuration_apply` updated | Correct. The workers do not carry the manifest. |
| 6 × updated | The change touched `common_patch`, not just Cilium. Stop and read the diff. |
| Any `proxmox_virtual_environment_vm` replaced | Wrong. Nothing here should rebuild a guest. Stop. |

## Checking it worked

```bash
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
```

Six pods, one per node, `Running` and `1/1`.

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --brief
```

```
OK
```

Then prove the data path, rather than trusting the status line:

```bash
kubectl run net-test --image=nicolaka/netshoot --rm -it --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local
```

A resolved address means pod networking, Service resolution and kube-proxy
replacement are all working, which is the whole surface this change touches.

Load balancer addresses are a separate surface, and an upgrade can break them
without breaking anything above:

```bash
kubectl get lease -A | grep l2announce
```

One lease per Gateway, each held by a worker. None means no address on the guest
bridge answers ARP, and everything on the mesh stops resolving.

## Rolling back

Revert the commit and let ArgoCD sync it back. There is nothing else to undo,
because the version is the only thing that changed.

Downgrades across a minor version are **not** supported by Cilium. If a 1.19 to
1.20 upgrade goes wrong, rolling back to 1.19 is not guaranteed to work, and the
supported recovery is a rebuild:

```bash
task tofu:destroy
task tofu:apply
```

This cluster is disposable by design. Anything stored in it is not; see the
rebuild table in [Applying step by step](../../troubleshooting/step-by-step.md).

## If ArgoCD is what is broken

ArgoCD manages the network it is itself running on, which is the cost of this
arrangement. If a sync leaves the cluster without a working CNI, ArgoCD cannot
fix it, because it needs the network to run.

Render the chart yourself and apply it, from the same file ArgoCD reads, so this
is not a second source of truth:

```bash
helm template cilium cilium \
  --repo https://helm.cilium.io/ \
  --version "$(yq '.spec.source.targetRevision' gitops/system/base/cilium/cilium.yaml)" \
  --namespace kube-system \
  -f <(yq '.spec.source.helm.valuesObject' gitops/system/base/cilium/cilium.yaml) \
  | kubectl apply -f -
```

Then fix the commit that caused it, so ArgoCD agrees with the cluster again.

## One thing that will surprise you

**Hubble's certificates are minted in the cluster**, by a job, not by the chart.
That is deliberate: rendering them would put a fresh private key into the machine
configuration on every plan. It also means Hubble may take a minute longer than
the agent to come back after an upgrade. That is normal, and not a failed
rollout.
