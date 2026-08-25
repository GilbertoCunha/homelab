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

## 3. Previewing the changes

```bash
task ansible:check
```

This changes nothing. It prints what a real run would do. On a fresh server
almost everything is reported as changed, which is expected.

## 4. Configuring the server

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

## 5. Checking it worked

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

## 6. Reaching the Proxmox interface

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
tailscale up --login-server https://vpn.homelab.grncunha.com --authkey <key>
```

The key authorises the device, so there is nothing to approve afterwards.

**3. On your own device**, open the interface:

```
https://proxmox.homelab.grncunha.com
```

No port, no certificate warning.

### How it stays private

The name answers differently depending on who asks. Headscale tells mesh devices
it is this server's mesh address. Everyone else gets the public address, which
is what lets the certificate renew. Caddy then serves the interface only to
mesh addresses and answers `403` to everything else.

This means the client must be accepting DNS from Headscale, which it does by
default. If you have turned that off with `--accept-dns=false`, the name
resolves publicly and you get the `403`.

Port `8006` is also open on the mesh, so `https://<mesh address>:8006` still
works if Caddy is ever down. It shows a certificate warning, because that is
Proxmox's own self-signed certificate.

## Troubleshooting

If several things fail at once, stop guessing and apply the playbook one
role at a time: [Applying step by step](../troubleshooting/step-by-step.md).

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
