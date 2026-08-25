# Applying step by step

The playbook does a lot at once. On a fresh server, one broken step buries every
step after it, and you end up reading a wall of errors that all have the same
cause.

This document applies one piece at a time, and checks each one before moving on.
Use it the first time you set the server up, and any time something breaks.

## Before you start

Finish [Bootstrap](../manual/1-bootstrap.md) first. DNS must resolve, and this
must work:

```bash
task ansible:ping
```

Apply one role at a time with:

```bash
task ansible:role -- <tag>
```

Useful flags to add after the tag:

| Flag | What it does |
| --- | --- |
| `--check` | Changes nothing. Shows what would happen. |
| `-vv` | Shows the command that ran and what it returned. |
| `--start-at-task "<name>"` | Resumes from a named task instead of the top. |

## The order

Each role assumes the ones above it have run. Do not skip.

| Step | Tag | Needs | Notes |
| --- | --- | --- | --- |
| 1 | `common` | nothing | Firewall. Read the warning below first. |
| 2 | `caddy` | `common` | Opens 80 and 443. |
| 3 | `headscale` | `caddy` | Needs a certificate to be reachable. |
| 4 | `mesh` | `headscale` | Fails if the certificate is not issued. |
| 5 | `proxmox` | `common` | **Reboots the server.** |

## Step 1: the base system and firewall

This sets the hostname, hardens SSH, and installs the firewall.

**Open a second SSH session before you run this, and leave it open.** If the
firewall or the SSH change is wrong, that open session is how you fix it without
a trip to the Hetzner console.

```bash
task ansible:role -- common --check
task ansible:role -- common
```

Check it worked, on the server:

```bash
nft list ruleset | head -20
sshd -T | grep -E 'passwordauthentication|permitrootlogin'
sysctl net.ipv4.ip_forward
getent hosts homelab.grncunha.com
```

You should see a `policy drop` input chain, `passwordauthentication no`,
`net.ipv4.ip_forward = 1`, and the hostname resolving to the server's public
address.

**If you are locked out**: use the Hetzner console to boot into rescue mode,
mount the disk, and undo `/etc/nftables.conf`.

**If `getent` returns nothing or `127.0.1.1`**: the `/etc/hosts` task did not
apply. Proxmox will fail later. Fix this before continuing.

## Step 2: the web server

```bash
task ansible:role -- caddy
```

Check it worked, on the server:

```bash
systemctl status caddy
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
ss -lntp | grep -E ':80|:443'
```

Caddy should be `active (running)` and listening on both ports.

**If the package will not install**: the signing key or repository is wrong.
Check `/etc/apt/sources.list.d/caddy-stable.sources` and run `apt update`.

**If port 80 is already taken**: something else is bound to it. `ss -lntp`
names the process.

## Step 3: headscale

```bash
task ansible:role -- headscale
```

Check it worked, on the server:

```bash
systemctl status headscale
curl -sS http://127.0.0.1:8080/health
headscale users list
headscale policy check --file /etc/headscale/acl.hujson
```

Then from **your own machine**, which is the real test:

```bash
curl -sS https://vpn.homelab.grncunha.com/health
```

A healthy response here means the certificate was issued and Caddy is proxying
correctly.

**If headscale will not start**: it validates its config on startup and says
what is wrong.

```bash
journalctl -u headscale -n 50
```

**If the certificate never arrives**: Caddy explains why.

```bash
journalctl -u caddy --since "10 minutes ago"
```

The usual cause is the DNS record being proxied through Cloudflare instead of
**DNS only**. See [Bootstrap](../manual/1-bootstrap.md).

## Step 4: joining the mesh

This is the step that fails if the certificate is not ready, because the server
has to reach its own Headscale over HTTPS.

```bash
task ansible:role -- mesh
```

Check it worked, on the server:

```bash
tailscale status
tailscale ip -4
headscale nodes list
cat /var/lib/headscale/extra-records.json
```

`tailscale status` should say the connection is up. `headscale nodes list`
should show `homelab` with an address starting `100.64.`, tagged `tag:infra`.
The records file should contain that same address.

**If it fails on `tailscale up`**: run step 3's check from your own machine
first. This step cannot work until that returns healthy.

**If the node is registered but the run failed partway**: the role skips
enrollment when `tailscale status` already reports a working connection, so it
is safe to run again.

## Step 5: Proxmox

**This reboots the server.** Ansible waits for it to come back and continues.

```bash
task ansible:role -- proxmox
```

Check it worked, on the server:

```bash
pveversion
systemctl status pveproxy
uname -r
ip a show vmbr1
nft list table ip nat
```

`uname -r` should name a `pve` kernel. `vmbr1` should be up with the guest
address. The NAT table should contain a masquerade rule for the guest network.

**If the install fails on `pve-manager` or `postfix`**: almost always
`/etc/hosts`. Go back to step 1 and check `getent hosts`.

**If the server does not come back after the reboot**: use the Hetzner console.
The Debian kernel is removed only after Proxmox's own kernel is installed, so
there should still be something to boot.

**If `apt update` reports a 401**: the enterprise repository is still enabled.
The role removes it; check `/etc/apt/sources.list.d/`.

## Step 6: reaching Proxmox by name

Follow section 6 of [Configure the server](../manual/2-configure-server.md) to
join your own device to the mesh, then:

```bash
dig +short proxmox.homelab.grncunha.com
```

On a mesh device this prints an address starting `100.64.`. Anywhere else it
prints the public address, and the site answers `403`. Both are correct.

## When a task fails

1. Read the name of the failed task. It says what it was doing.
2. Run that role again with `-vv` to see the command and its output.
3. Skip ahead with `--start-at-task "<the task name>"` once you have fixed it.

## Finishing

Once every step passes, run the whole thing:

```bash
task ansible:site
```

It should report no changes at all. Anything reported as changed on a clean
second run is a bug worth fixing, not noise to ignore.
