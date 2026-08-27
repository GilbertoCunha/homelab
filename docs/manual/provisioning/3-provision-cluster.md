# Manual 3 - Provision the Kubernetes cluster

This describes how to build the Kubernetes cluster with OpenTofu. It creates six
Talos Linux guests on Proxmox and hands you a working `kubectl`.

Before you start, finish [Configure the server](./2-configure-server.md). Your
own device must be on the mesh, because Proxmox is only reachable there, **and it
must be accepting subnet routes**, because the six guests are only reachable
through the route the server advertises:

```bash
tailscale set --accept-routes
netstat -rn -f inet | grep 10.10.10
```

```
10.10.10/24        link#31            UCS                 utun5
```

No route means every command in section 6 and 7 below times out, and the timeouts
take minutes each. [The mesh network](../../concepts/mesh.md) explains why this half
cannot be automated.

## What gets built

| Role | Count | vCPU | RAM | Disk | Addresses |
| --- | --- | --- | --- | --- | --- |
| Control plane | 3 | 2 | 4 GB | 40 GB | `10.10.10.11`-`.13` |
| Worker | 3 | 4 | 20 GB | 100 GB | `10.10.10.21`-`.23` |

The Kubernetes API answers on `10.10.10.10`, a virtual address the three control
planes share. Talos moves it to a healthy node on its own, so there is no load
balancer to run.

Talos is immutable and has no SSH. Nodes are configured entirely through their
machine configuration, which OpenTofu applies over the network.

## 1. Installing the tools

On **your own machine**:

```bash
brew install opentofu sops age talosctl kubernetes-cli
```

## 2. Setting up the secrets file

Every credential below goes into `secrets.enc.yaml`, encrypted, **as soon as you
create it**. Set that up first, so there is never a moment where you are holding
a secret with nowhere to put it. Some of them are shown exactly once.

[Secrets with SOPS](../../concepts/sops.md) explains how this works and why. One
command does the setup:

```bash
task secrets:init
```

It creates your age key, writes `.sops.yaml` naming its public half, and creates
`secrets.enc.yaml` already encrypted and empty:

```
Public key: age1xpuunk8cllxcrpv9ux2rw5lc0ak06xdyrqrc7pqkv84r99mvuv9qklaal7
Back this file up outside the repo. Nothing here decrypts without it.
Wrote /.../.sops.yaml for age1xpuunk8...
Created /.../secrets.enc.yaml, encrypted and empty. Fill it with: task secrets:edit
```

Running it again is safe. It never overwrites a key or a secrets file that
already exists.

**Back up `~/.config/sops/age/keys.txt` now, outside this repository**, in a
password manager. It is the only secret that cannot be stored here, and without
it nothing else can be decrypted, ever.

Check the round trip works before you put anything real in it:

```bash
task secrets:show
```

```
PROXMOX_ROOT_PASSWORD: ""
PROXMOX_VE_API_TOKEN: ""
AWS_ACCESS_KEY_ID: ""
AWS_SECRET_ACCESS_KEY: ""
```

Empty values, no errors. If this fails, fix it now;
[Secrets with SOPS](../../concepts/sops.md) lists the usual causes.

### Record the root password

You set this with `passwd root` in [manual 2](./2-configure-server.md). Put it in
now, while you are here:

```bash
task secrets:edit
```

Fill in `PROXMOX_ROOT_PASSWORD`, save, and close. The file is encrypted the
moment you save.

## 3. Creating the Proxmox API token

OpenTofu talks to Proxmox as its own user, never as `root`. Ansible has already
created the user and its role; only the token is left, because Proxmox shows the
secret once and never again.

On the **server**:

```bash
pveum user token add opentofu@pve tofu --privsep 0
```

```
┌──────────────┬──────────────────────────────────────┐
│ key          │ value                                │
╞══════════════╪══════════════════════════════════════╡
│ full-tokenid │ opentofu@pve!tofu                    │
│ value        │ xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx │
└──────────────┴──────────────────────────────────────┘
```

The token OpenTofu needs is those two joined with an `=`:

```
opentofu@pve!tofu=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

**Save it now**, on your own machine, before you do anything else. That `value`
is not shown again, and the only way back is to delete the token and make a new
one:

```bash
task secrets:edit
```

Fill in `PROXMOX_VE_API_TOKEN`, save, and close.

`--privsep 0` means the token carries the user's own permissions. Without it the
token starts with none and every API call fails with `403`.

## 4. Creating the state bucket

State records what OpenTofu built, including the cluster's certificate
authorities. It lives in Cloudflare R2, and **the bucket being private is what
protects it**, so the settings below matter.

In the Cloudflare dashboard:

1. Create an R2 bucket named `homelab-tofu-state`. Keep it **private**.
2. Turn on **object versioning**, so a bad write can be rolled back.
3. Create an R2 API token with **Object Read & Write**, scoped to **that bucket
   only**. It shows an access key id and a secret access key.

**Save both now**, before leaving the page. The secret access key is not shown
again:

```bash
task secrets:edit
```

Fill in `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, save, and close.

Then put your account id into `opentofu/project/backend.tofu`, replacing
`CLOUDFLARE_ACCOUNT_ID`. It is the subdomain of the S3 endpoint R2 shows you,
and it is an identifier rather than a secret, so it belongs in the code.

## 5. Checking before you build

Everything should now be in place:

```bash
task secrets:show
```

All four values filled in, none of them empty:

| Key | From |
| --- | --- |
| `PROXMOX_ROOT_PASSWORD` | `passwd root`, in manual 2 |
| `PROXMOX_VE_API_TOKEN` | Step 3 |
| `AWS_ACCESS_KEY_ID` | Step 4 |
| `AWS_SECRET_ACCESS_KEY` | Step 4 |

Commit the encrypted file. It is meant to be in the repository:

```bash
git add .sops.yaml secrets.enc.yaml
git commit -m "chore: add encrypted secrets"
```

## 6. Building the cluster

```bash
task tofu:init
task tofu:plan
```

The plan should create six guests, one image download, and the Talos
configuration. Nothing else.

```bash
task tofu:apply
```

This takes several minutes and does a lot:

1. The Talos Image Factory builds an image with the guest agent and iSCSI tools.
2. Proxmox downloads it.
3. Six guests boot that image and reach maintenance mode, each with the static
   address given to it by a cloud-init drive. **There is no DHCP on the guest
   bridge**, which is why the drive exists.
4. OpenTofu applies each machine configuration. Talos installs itself to disk.
5. The first control plane is bootstrapped, and etcd forms. The other two join.
6. OpenTofu waits until the cluster reports healthy.

The run finishing means Kubernetes is actually serving, not just that the guests
exist.

## 7. Reaching the cluster

```bash
task tofu:kubeconfig
task tofu:talosconfig

export KUBECONFIG=$PWD/kubeconfig
export TALOSCONFIG=$PWD/talosconfig
```

Both files are ignored by git.

```bash
kubectl get nodes -o wide
```

You should see six nodes, all `Ready`, all running `v1.36.2`, with the addresses
from the table at the top.

```bash
talosctl --nodes 10.10.10.11 health
```

This reports on etcd, the control plane and every node.

### How your laptop reaches a guest

Guests have no public address and no mesh client of their own. The server
advertises their subnet into the mesh instead, and forwards the traffic. This
needs agreement at both ends, and the `mesh` role can only supply the server's
half; see [The mesh network](../../concepts/mesh.md).

If `kubectl` hangs, check both halves. On the **server**:

```bash
headscale nodes list-routes
```

`10.10.10.0/24` should be listed against `homelab`, and approved.

On **your own device**:

```bash
netstat -rn -f inet | grep 10.10.10
```

A route on `utun`. If the server side is right and this prints nothing, run
`tailscale set --accept-routes`.

## 8. Storage

The cluster has no persistent storage yet. Pods that ask for a volume will stay
`Pending`.

This is deliberate. The single `local` directory on the host is the only storage
Proxmox has, and choosing between Longhorn, a Proxmox CSI driver and plain local
paths deserves its own decision rather than being settled by default.

## Troubleshooting

If several things fail at once, apply the Ansible roles one at a time first:
[Applying step by step](../../troubleshooting/step-by-step.md).

**`tofu init` fails on the backend.** The account id in `backend.tofu` is wrong,
or the R2 token cannot see the bucket. The error names which.

**Every Proxmox call returns `403`.** The token was created without
`--privsep 0`, so it has no permissions. Delete and recreate it:

```bash
pveum user token remove opentofu@pve tofu
pveum user token add opentofu@pve tofu --privsep 0
```

**A guest never becomes reachable.** It booted but has no address. Open its
console in Proxmox: Talos prints its address on the screen. If there is none,
the cloud-init drive did not apply. Check the guest storage still allows the
content types the drive needs, on the server:

```bash
pvesh get /storage/local
```

`images` and `snippets` should both be listed.

**`talos_machine_configuration_apply` times out on every node at once**, with
`dial tcp 10.10.10.x:50000: i/o timeout` for all six. The guests are fine; your
device has no route to them. Check the client half:

```bash
netstat -rn -f inet | grep 10.10.10
```

Nothing printed is the answer. Two things cause it, and they need different
fixes:

```bash
tailscale status --json | grep -A3 AllowedIPs
```

- **`homelab` lists `10.10.10.0/24`**: the route reached you and your client is
  not accepting it. Run `tailscale set --accept-routes`.
- **`homelab` lists only its own `/32`**: the route never reached you. The access
  policy is not permitting the guest subnet, and no client-side setting helps.
  Fix `acl.hujson` and re-apply the `headscale` role.

Either way, apply again afterwards. The run hangs for several minutes before
failing, because each of the six retries the connection until it gives up.
[The mesh network](../../concepts/mesh.md) has the full path.

**`talos_machine_configuration_apply` times out on one node.** That guest is
reachable but its Talos API is not answering yet. Applying again is safe; nothing
is half-written.

**`static hostname is already set in v1alpha1 config`.** The node name belongs in
the `HostnameConfig` document, not in `machine.network.hostname`, and Talos
refuses a configuration that has both. `cluster.tf` already sets it the right
way; this error means a patch somewhere has put it back. Check a rendered
configuration before applying it:

```bash
talosctl validate --config <file> --mode metal
```

```
<file> is valid for metal mode
```

**The cluster never reports healthy.** Ask Talos directly. It is specific about
what is wrong:

```bash
talosctl --nodes 10.10.10.11 health
talosctl --nodes 10.10.10.11 dmesg
talosctl --nodes 10.10.10.11 service etcd status
```

**Starting over.** `task tofu:destroy` removes every guest, then `task
tofu:apply` rebuilds from nothing. The cluster is disposable; anything stored in
it is not.

## Next

The cluster is running but empty. Fill it from git with
[Bootstrap GitOps](./4-bootstrap-gitops.md).
