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
| `-vv` | Shows the command that ran and what it returned. |
| `--start-at-task "<name>"` | Resumes from a named task instead of the top. |
| `--check` | Changes nothing. Shows what would happen. Read the warning below. |

### `--check` does not work on a fresh server

`--check` never writes anything, which sounds safe but makes it useless the
first time round. A role that adds an apt repository never gets to add it, so
every package in that role then fails to resolve. You get a wall of
`No package matching ... is available` that says nothing about your actual
problem.

| Role | Does `--check` work? |
| --- | --- |
| `common` | Yes. It refreshes the package index for real first. |
| everything else | Only after that role has been applied for real once. |

So on a new server, apply each role for real and check the result afterwards.
Use `--check` later, to preview changes on a server that is already set up.

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
systemctl is-active caddy
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
ls /etc/caddy/sites/
```

Caddy should be `active`, the config should say `Valid configuration`, and
`/etc/caddy/sites/` should be empty.

**Caddy is not listening on port 80 or 443 yet, and that is correct.** It only
opens a port when a site is defined, and the first site arrives with headscale
in the next step. Do not go hunting for a bug here.

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

## When you are stuck

### Ansible does not roll back

There is no undo. A playbook describes the state you want, not the steps taken
to get there, so there is nothing to reverse. Running it again re-applies the
same state; it does not return the server to how it was before.

That is fine, because nothing here is precious. The server is described entirely
by this repo and can be rebuilt from bare metal in about fifteen minutes. Treat
rebuilding as a normal move, not a defeat.

### Undoing one piece

If a single role went wrong and the server is otherwise healthy, undo just that
piece and run it again. All of these are run on the server.

| Role | How to undo it |
| --- | --- |
| `common` | `systemctl stop nftables && nft flush ruleset` clears the firewall. This leaves every port open, so only do it while you are fixing something. |
| `caddy` | `apt purge caddy && rm -rf /etc/caddy` |
| `headscale` | `apt purge headscale && rm -rf /var/lib/headscale`. **Every device has to join again.** |
| `mesh` | `tailscale logout && apt purge tailscale && rm -rf /var/lib/tailscale` |
| `proxmox` | Not realistically undoable. See below. |

Proxmox replaces the kernel and takes over the network configuration. There is
no clean way back. This is why it runs last: everything else is proven before
the step you cannot reverse.

### Locked out of SSH

If the firewall or the SSH change locked you out, you do not need a rebuild.

1. In the [Hetzner Robot console](https://robot.hetzner.com/server), open
   **Rescue**, enable the Linux rescue system, and reset the server
2. SSH in with the rescue password Hetzner shows you
3. Mount the disk and fix the file that locked you out, usually
   `/etc/nftables.conf` or `/etc/ssh/sshd_config`
4. Reboot back into the normal system

This is also why step 1 tells you to keep a second SSH session open. It is much
faster than the above.

### Rebuilding from scratch

When the server is beyond fixing, reinstall it. Start again from
[Bootstrap](../manual/1-bootstrap.md), then work through this document.

Before you do, know what is not in this repo and will not come back:

| What | Effect of losing it |
| --- | --- |
| `/var/lib/headscale/db.sqlite` | Users, nodes, keys. Every device joins again. |
| Headscale's noise and DERP keys | Regenerated. Harmless once devices re-join. |
| Caddy's certificates | Re-issued automatically. See the rate limit below. |
| Proxmox guests and their disks | **Gone.** Back them up first. |
| The root password | Set it again with `passwd root`, or the Proxmox web login will not work. |

**The DNS records stay.** They point at the server, not at an installation, so
there is nothing to redo in Cloudflare.

**Watch the Let's Encrypt rate limit.** You may issue five certificates for the
same set of names per week. Each rebuild uses one per name. If you are
reinstalling repeatedly, you can lock yourself out of new certificates for days,
and Caddy will fail in a way that looks like a DNS problem. If you expect
several rebuilds, point Caddy at the staging service first by adding this to the
global block of `/etc/caddy/Caddyfile`:

```
acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
```

Staging certificates are not trusted by browsers, so remove that line for the
real run.

**After a reinstall the host key changes**, so clear the old one on your own
machine:

```bash
ssh-keygen -R homelab.grncunha.com
```

## Finishing

Once every step passes, run the whole thing:

```bash
task ansible:site
```

It should report no changes at all. Anything reported as changed on a clean
second run is a bug worth fixing, not noise to ignore.
