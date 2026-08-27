# Manual 2 - Configure the server

This documentation describes how to configure the server with Ansible. It
installs Headscale, Caddy and Proxmox, and puts a firewall in place.

Before you start, finish [Bootstrap](./1-bootstrap.md). Ansible reaches
the server by name, so the DNS records must already work.

## 1. Installing the tools

You need [Task](https://taskfile.dev) and Ansible on your own machine.

```bash
task ansible:deps
```

This installs the Ansible collections the playbook uses.

## 2. Checking the connection

```bash
task ansible:ping
```

You should see `SUCCESS` and `"ping": "pong"`. If it hangs or reports
`UNREACHABLE`, the DNS record or your SSH key is the problem.

## 3. Configuring the server

Run this on **your own machine**, from the repo:

```bash
task ansible:site
```

This takes a while. Three things are worth knowing:

- **The server reboots partway through.** Proxmox replaces the Debian kernel
  with its own. Ansible waits for the server to come back and carries on.
- **Caddy requests a TLS certificate** for `vpn.homelab.grncunha.com` the first
  time it starts. This needs port 80 reachable, which the firewall allows.
- **The server joins its own mesh** at the end, using a single-use key that
  expires in ten minutes. The key is never saved anywhere.

If the run fails on the last step with a TLS error, the certificate was not
ready. Check it from **your own machine**:

```bash
curl -sS https://vpn.homelab.grncunha.com/health
```

- **Healthy response**: the certificate is fine. Run `task ansible:site` again.
- **A certificate error**: not ready yet. Wait a minute and try again.
- **Still failing after a few minutes**: see Troubleshooting below.

To configure everything except the mesh in the meantime:

```bash
task ansible:site:no-mesh
```

## 4. Checking it worked

On **your own machine**:

```bash
curl https://vpn.homelab.grncunha.com/health
```

You should get a healthy response over valid TLS.

On the **server**:

```bash
ssh root@homelab.grncunha.com
systemctl status headscale caddy tailscaled pveproxy
headscale nodes list
```

All four services should be `active (running)`. The node list should show
`homelab` with an address starting `100.64.`, tagged `tag:infra`.

## 5. Reaching the Proxmox interface

The Proxmox interface is served at `https://proxmox.homelab.grncunha.com`, with
a real certificate, and only to devices on the mesh. Joining takes one step on
each machine.

**1. On the server**, create a key for your device.

Keys are tied to a user id, not a name, so look the id up first:

```bash
headscale users list
```

Then create a key that is valid for one hour:

```bash
headscale preauthkeys create --user <id> --expiration 1h
```

Copy the key it prints.

**NOTE**: do not pass `--tags`. Your own devices must stay untagged, or the
access policy will treat them as servers and deny them.

**2. On your own device**, install the
[Tailscale client](https://tailscale.com/download) and point it at your
Headscale instead of Tailscale's servers:

```bash
tailscale up --login-server https://vpn.homelab.grncunha.com --authkey <key> --accept-routes
```

The key authorises the device, so there is nothing to approve afterwards.

`--accept-routes` is what lets this device reach the Proxmox guests on
`10.10.10.0/24`, including the Kubernetes cluster. It is off by default in every
client and nothing on the server can turn it on for you. If the device has
already joined without it:

```bash
tailscale set --accept-routes
```

Either way, check the route arrived:

```bash
netstat -rn -f inet | grep 10.10.10
```

```
10.10.10/24        link#31            UCS                 utun5
```

Nothing printed means the guests are unreachable from this device, however
healthy the mesh looks. [The mesh network](../../concepts/mesh.md) explains why the
route needs agreement from both ends.

**3. On the server**, set a root password, once only.

Proxmox checks the web login against the server's Linux users, and Hetzner
installs with SSH keys and no password, so there is nothing to log in with yet:

```bash
passwd root
```

This does not let anyone log in over SSH with a password. SSH is configured to
refuse passwords entirely; only Proxmox uses this one.

Ansible does not manage this password on purpose. Setting it from the playbook
would mean the playbook deciding it, and a password you cannot change on the
server without also editing the repository is worse, not better.

**Write this password down in the encrypted secrets file**, under
`PROXMOX_ROOT_PASSWORD`. A rebuild wipes the server's users, and this password is
not stored anywhere else.

That file is `secrets.enc.yaml`, at the root of this repository. It is committed,
and it is safe to commit because every value in it is encrypted with SOPS. See
[Secrets with SOPS](../../concepts/sops.md) for what that means and how to use it.

If you have not set that up yet, you have not reached it: it is step 2 of
[Provision the cluster](./3-provision-cluster.md). Keep the password somewhere
safe until then, and record it when you get there.

**4. On your own device**, open the interface:

```
https://proxmox.homelab.grncunha.com
```

No port, no certificate warning. Log in with:

| Field | Value |
| --- | --- |
| User name | `root` |
| Password | the one you just set |
| Realm | **Linux PAM standard authentication** |

### How it stays private

The name answers differently depending on who asks: mesh devices get the
server's mesh address, everyone else gets the public one, and Caddy answers
`403` to anything that is not a mesh address.
[The mesh network](../../concepts/mesh.md) explains the split and what a `403`
tells you.

Port `8006` is also open on the mesh, so `https://<mesh address>:8006` still
works if Caddy is ever down. It shows a certificate warning, because that is
Proxmox's own self-signed certificate.

## Troubleshooting

If several things fail at once, stop guessing and apply the playbook one
role at a time: [Applying step by step](../../troubleshooting/step-by-step.md).

**Caddy cannot get a certificate.** Check the DNS record is **DNS only** and not
proxied, as described in [Bootstrap](./1-bootstrap.md). On the server, Caddy
says why it failed:

```bash
journalctl -u caddy --since "10 minutes ago"
```

**The Proxmox interface answers `403`.** The name resolved to the public
address instead of the mesh one. On your own device, check what it resolves to:

```bash
tailscale status
dig +short proxmox.homelab.grncunha.com
```

It should print an address starting `100.64.`. If it prints the public address,
the device is either not on the mesh or not accepting DNS from Headscale.

**A device cannot reach the Proxmox interface at all.** The access policy at
`/etc/headscale/acl.hujson` only lets your own untagged devices through. A
tagged device, or one registered under a different user, is denied. On the
server:

```bash
headscale policy check --file /etc/headscale/acl.hujson
headscale nodes list
```

**Everything is reported as changed on a second run.** That is a bug, not
normal. A second `task ansible:site` should report no changes at all.

## Next

The server is now finished. Build the Kubernetes cluster on top of it with
[Provision the cluster](./3-provision-cluster.md).
