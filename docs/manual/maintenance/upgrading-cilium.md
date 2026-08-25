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

Cilium is delivered to this cluster as a Talos inline manifest, rendered from the
chart at plan time. So the upgrade is a machine configuration change, and it goes
through OpenTofu like every other change here. You do not run `helm upgrade`.

**1. Bump the version**, in `opentofu/project/terraform.tfvars`. It is written
in exactly one place:

```hcl
cilium_version = "1.20.2"
```

**2. Look at what that changes.**

```bash
task tofu:plan
```

Expect **three** resources to change, and nothing else: the machine
configuration of `cp-1`, `cp-2` and `cp-3`. The workers do not carry the
manifest, so they are untouched.

| What the plan shows | What it means |
| --- | --- |
| 3 × `talos_machine_configuration_apply` updated | Correct. This is the upgrade. |
| 6 × updated | The change touched `common_patch`, not just Cilium. Stop and read the diff. |
| Any `proxmox_virtual_environment_vm` replaced | Wrong. Nothing here should rebuild a guest. Stop. |

**3. Apply it.**

```bash
task tofu:apply
```

Talos writes the new configuration to the control planes and reconciles the
manifest into the cluster. The agent DaemonSet then rolls node by node.

**4. Watch the rollout**, in another terminal:

```bash
kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
```

```
daemon set "cilium" successfully rolled out
```

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

## If the cluster does not pick it up

Talos reconciles inline manifests when the machine configuration changes. If the
DaemonSet image has not moved a few minutes after the apply, check that the
control planes actually took the new configuration:

```bash
talosctl -n 10.10.10.11 get machineconfig -o yaml | grep -c 'cilium'
```

If the configuration is current but the cluster is not, apply the rendered
manifest by hand. It comes from the same render, so this is not a second source
of truth:

```bash
task tofu:cilium-manifest
kubectl apply -f cilium.yaml
```

`cilium.yaml` is generated and git-ignored. Delete it afterwards.

## Rolling back

Put the old version back in `terraform.tfvars` and apply again. There is nothing
else to undo, because the version is the only thing that changed.

Downgrades across a minor version are **not** supported by Cilium. If a 1.19 to
1.20 upgrade goes wrong, rolling back to 1.19 is not guaranteed to work, and the
supported recovery is a rebuild:

```bash
task tofu:destroy
task tofu:apply
```

This cluster is disposable by design. Anything stored in it is not; see the
rebuild table in [Applying step by step](../../troubleshooting/step-by-step.md).

## Two things that will surprise you

**Talos does not remove what a new version dropped.** Inline manifests are
applied, never pruned. If an upgrade deletes a resource from the chart, the old
one stays in the cluster until you delete it yourself. Compare the rendered
manifests across versions if an upgrade behaves oddly.

**Hubble's certificates are minted in the cluster**, by a job, not by the chart.
That is deliberate: rendering them would put a fresh private key into the machine
configuration on every plan. It also means Hubble may take a minute longer than
the agent to come back after an upgrade. That is normal, and not a failed
rollout.
