# Cheatsheet

Commands worth remembering, grouped by where you run them. Running the right
command in the wrong place is the most common mistake, so each section says
where it belongs.

For a guided walkthrough when something is broken, use
[Applying step by step](./troubleshooting/step-by-step.md) instead.

## Start here

When something is wrong and you do not know where to look, run these three in
order. They narrow the problem down fast.

| Where | Command | Tells you |
| --- | --- | --- |
| Your machine | `task ansible:ping` | The server is up and reachable |
| Your machine | `curl -sS https://vpn.homelab.grncunha.com/health` | TLS and headscale are healthy from outside |
| Server | `systemctl is-system-running` | Whether any service failed |

## On your own machine

### Running Ansible

| Command | When to use it |
| --- | --- |
| `task ansible:deps` | First time, or after `requirements.yaml` changes |
| `task ansible:ping` | Check the server answers before anything else |
| `task ansible:site` | Apply everything |
| `task ansible:role -- <tag>` | Apply one role: `common`, `caddy`, `headscale`, `mesh`, `proxmox`, `reboot` |
| `task ansible:check` | Preview changes. Only works on a server already set up |
| `task ansible:site:no-mesh` | Apply everything except the roles needing a certificate |
| `task ansible:lint` | Check the code before committing |

A clean run ends with `changed=0` and `failed=0`. Anything reported as changed
on a second run is a bug.

Add flags after the tag, for example `task ansible:role -- caddy -vv`.

### Applying without rebooting

The playbook reboots at the end if anything is running on old code. To be told
what needs a reboot without one happening:

```bash
task ansible:site -- -e reboot_enabled=false
```

### Running a command on the server without logging in

```bash
ansible servers -m ansible.builtin.shell -a 'systemctl is-active caddy'
```

Useful for quick checks. Everything in the next section can be run this way.

### Checking names resolve

```bash
dig +short homelab.grncunha.com
dig +short vpn.homelab.grncunha.com
dig +short proxmox.homelab.grncunha.com
```

All three print the server's public IP. A different address means the record is
proxied through Cloudflare; it must be **DNS only**.

## On the server

Get there with `ssh root@homelab.grncunha.com`.

### Is everything healthy?

| Command | Good result |
| --- | --- |
| `systemctl is-system-running` | `running`. `degraded` means something failed |
| `systemctl --failed` | Empty |
| `systemctl is-active headscale caddy tailscaled nftables pveproxy` | `active` for each |
| `uptime -p` | Matches when you last rebooted |

### Mesh and headscale

| Command | Good result |
| --- | --- |
| `headscale nodes list` | `homelab` present, address starts `100.64.`, tagged `tag:infra` |
| `headscale users list` | Your user, with its id. The id is what other commands need |
| `headscale policy check --file /etc/headscale/acl.hujson` | No errors |
| `tailscale status` | Connection up |
| `tailscale ip -4` | This host's mesh address |
| `cat /var/lib/headscale/extra-records.json` | Contains `proxmox.homelab.grncunha.com` at that same address |

To let a new device join, create a key valid for an hour. `<id>` comes from
`headscale users list`, and is a number, not a name:

```bash
headscale preauthkeys create --user <id> --expiration 1h
```

Do not pass `--tags`. Personal devices must stay untagged or the policy denies
them.

### Certificates and Caddy

| Command | Good result |
| --- | --- |
| `caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile` | `Valid configuration` |
| `ls /etc/caddy/sites/` | One `.caddy` file per published service |
| `journalctl -u caddy --since "10 minutes ago"` | No certificate errors |
| `ss -lntp \| grep -E ':80 \|:443 '` | Caddy listening, once at least one site exists |

Caddy binds no ports until a site is defined. Nothing listening on a fresh
install is correct, not a fault.

### Proxmox

| Command | Good result |
| --- | --- |
| `pveversion` | `pve-manager/9.x` and the running `-pve` kernel |
| `uname -r` | Ends in `-pve` |
| `ip -br a show vmbr1` | Address `10.10.10.1/24`. State reads `UNKNOWN`, which is normal for a bridge with no ports attached |
| `nft list table ip nat` | A masquerade rule for `10.10.10.0/24` |
| `passwd -S root` | `P`. An `L` means locked, and the web login will not work |
| `passwd root` | Sets the password for the Proxmox web login, user `root`, realm `pam` |

### Firewall

| Command | Good result |
| --- | --- |
| `nft list ruleset \| head -20` | `policy drop` on the input chain |
| `nft list ruleset \| grep dport` | 22, 80, 443 public; 22, 443, 8006 on `tailscale0` |

### Upgrades and reboots

| Command | Good result |
| --- | --- |
| `apt list --upgradable` | Ideally empty |
| `needrestart -b \| grep KSTA` | `NEEDRESTART-KSTA: 1` means the running kernel is current |
| `needrestart -b \| grep SVC` | No lines. Any line is a service running on deleted libraries |
| `apt-config dump \| grep APT::Periodic` | `Update-Package-Lists "1"` and `Unattended-Upgrade "1"` |
| `unattended-upgrade --dry-run` | Shows what would be upgraded, changes nothing |

`KSTA` values: `1` current, `2` or `3` a reboot is needed.

## On a device joining the mesh

Install the [Tailscale client](https://tailscale.com/download) first, then use a
key created on the server:

```bash
tailscale up --login-server https://vpn.homelab.grncunha.com --authkey <key>
```

| Command | Good result |
| --- | --- |
| `tailscale status` | Connected, and `homelab` listed as a peer |
| `dig +short proxmox.homelab.grncunha.com` | An address starting `100.64.` |
| `tailscale ping homelab` | A reply |

If `dig` returns the public address instead, this device is not accepting DNS
from headscale, and Proxmox will answer `403`.

Then open `https://proxmox.homelab.grncunha.com` in a browser. No port, no
certificate warning.

## Recovering

| Situation | What to do |
| --- | --- |
| Locked out by SSH or the firewall | Hetzner rescue mode. See [step by step](./troubleshooting/step-by-step.md) |
| A role went wrong | Undo that piece, then run it again. Same document |
| Beyond fixing | Reinstall and start from [Bootstrap](./manual/1-bootstrap.md) |

Ansible has no undo. Running the playbook again re-applies the wanted state; it
does not return the server to how it was before.
