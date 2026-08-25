# The mesh network

Everything private in this homelab is reached over a mesh: Proxmox, the
Kubernetes API, and the guests themselves. This explains how that works. For the
commands that join a device to it, see
[Configure the server](../manual/provisioning/2-configure-server.md).

## The parts

**Headscale** is a self-hosted replacement for Tailscale's coordination servers.
It decides who is on the network, hands out addresses, and serves DNS. It runs on
the server, behind Caddy, at `https://vpn.homelab.grncunha.com`.

**Tailscale** is the client. Every device runs the normal client and is pointed
at Headscale with `--login-server` instead of Tailscale's servers.

Addresses come from `100.64.0.0/16`. They are stable and belong to the device,
not to the network it happens to be on.

| Party | Identity | What it is |
| --- | --- | --- |
| `homelab` | `tag:infra` | The server. Joined by the `mesh` Ansible role. |
| Your devices | user `grnc13`, untagged | Laptop, phone. Joined by hand, once each. |
| Proxmox guests | none | Not on the mesh at all. Reached through the server. |

A tagged node drops its user identity. That is what lets the access policy in
`/etc/headscale/acl.hujson` tell a server from a person, so a personal device
must stay untagged. Passing `--tags` when you join your laptop is the usual way
to lock yourself out.

## Guests are not on the mesh

The Kubernetes nodes have no mesh client and never will. Talos Linux is immutable
and has no package manager, so there is nowhere to install one.

Instead the server advertises the guest subnet `10.10.10.0/24` into the mesh and
forwards the traffic. Your laptop sends packets for `10.10.10.11` to the server,
and the server puts them on the guest bridge. This is called a **subnet route**.

## A subnet route takes four separate agreements

This is the part that catches people. A route only works when all four hold, and
each one looks fine on its own while the route stays broken.

| # | Agreement | Where | Who does it |
| --- | --- | --- | --- |
| 1 | The server **advertises** the subnet | server | `mesh` role |
| 2 | Headscale **approves** it | server | `mesh` role |
| 3 | The access policy **permits** it | `acl.hujson` | `headscale` role |
| 4 | Your device **accepts** it | your device | **you, by hand** |

Advertising is an offer. Headscale ignores an offered route until an operator
approves it, so a compromised node cannot claim to route the internet.

Approval is not permission. Headscale builds each client's view of the network
from the access policy, and a route to somewhere the client is not allowed to
reach is left out of that view entirely. So the policy needs a rule whose
destination is the subnet itself:

```
{ "action": "accept", "src": ["grnc13@"], "dst": ["10.10.10.0/24:*"] }
```

The guests cannot be named any other way. A tag names a node that has joined the
mesh, and these never do.

Step 4 has no automation and cannot have any. Accepting routes is off by default
in every Tailscale client, because a route changes how the device treats
addresses that have nothing to do with the mesh. The client will not make that
choice for you.

### Checking them

Steps 1 and 2, on the **server**:

```bash
headscale nodes list-routes
```

```
ID | Hostname | Approved      | Available     | Serving (Primary)
1  | homelab   | 10.10.10.0/24 | 10.10.10.0/24 | 10.10.10.0/24
```

Step 3, on **your own device**. This is the one worth knowing, because it shows
what Headscale actually sent you rather than what the server offered:

```bash
tailscale status --json | grep -A3 AllowedIPs
```

The `homelab` peer must list `10.10.10.0/24` alongside its own `100.64.0.1/32`.
If only the `/32` is there, the policy is not permitting the subnet and nothing
you do on the client will help.

Step 4, on **your own device**:

```bash
netstat -rn -f inet | grep 10.10.10
```

```
10.10.10/24        link#31            UCS                 utun5
```

An empty result here with `AllowedIPs` correct means only step 4 is missing. Fix
it with `tailscale set --accept-routes`. It is a stored preference, so it
survives reboots and you set it once per device.

Whichever step is missing, the symptom is identical: everything on
`10.10.10.0/24` times out. Proxmox guests, the Kubernetes API, `talosctl`, and
`tofu apply`. It is a timeout rather than a refusal, because the packets are not
going anywhere at all.

## Names resolve differently depending on who asks

`proxmox.homelab.grncunha.com` has two answers. Headscale tells mesh devices it
is the server's `100.64.` address. Public DNS gives the server's public address,
which is what lets the certificate renew.

Caddy then serves the Proxmox interface only to `100.64.` addresses and answers
`403` to everything else. So a `403` means your device resolved the name
publicly: it is either not on the mesh, or not accepting DNS from Headscale.
Clients accept it by default; `--accept-dns=false` turns it off.

MagicDNS also gives every mesh node a name under `mesh.homelab.grncunha.com`.
That suffix is deliberately not a parent of `vpn.homelab.grncunha.com`. Clients
route a whole suffix through the mesh, and a client that routed the control
server through the mesh could not reach it to join in the first place.

## What is not stored

The pre-auth key that joins the server to the mesh is created and used inside a
single Ansible run, expires in ten minutes, and is never written down. The keys
you create for your own devices are the same idea by hand. None of them belong in
[the secrets file](./sops.md), because a used key has no further value.

The one thing that does not survive a rebuild is Headscale's database. Losing it
means every device joins again. See
[Applying step by step](../troubleshooting/step-by-step.md).
