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
| Your machine | `talosctl --nodes 10.10.10.11 health` | Whether the cluster is serving |

## On your own machine

### Running Ansible

| Command | When to use it |
| --- | --- |
| `task ansible:deps` | First time, or after `requirements.yaml` changes |
| `task ansible:ping` | Check the server answers before anything else |
| `task ansible:site` | Apply everything |
| `task ansible:role -- <tag>` | Apply one role: `common`, `caddy`, `headscale`, `mesh`, `proxmox`, `reboot` |
| `task ansible:site:no-mesh` | Apply everything except the roles needing a certificate |
| `task ansible:lint` | Check the code before committing |

A clean run ends with `changed=0` and `failed=0`. Anything reported as changed
on a second run is a bug.

Add flags after the tag, for example `task ansible:role -- caddy -vv`.

### Running OpenTofu

Every command below decrypts `secrets.enc.yaml` for the length of that one
command. Never run `tofu` directly; it will fail with no credentials.

| Command | When to use it |
| --- | --- |
| `task tofu:init` | First time, or after changing the backend or a provider |
| `task tofu:plan` | See what would change. Always before apply |
| `task tofu:apply` | Build or update the cluster. Waits until it is healthy |
| `task tofu:fmt` | Format the code before committing |
| `task tofu:validate` | Check the code without reaching the server |
| `task tofu:kubeconfig` | Write `./kubeconfig` for `kubectl` |
| `task tofu:talosconfig` | Write `./talosconfig` for `talosctl` |
| `task tofu:destroy` | **Deletes every guest**, cluster and volumes with them |

Add flags after `--`, for example `task tofu:plan -- -target=module.talos_node`.

### Secrets

How this works, and what to do when it does not:
[Secrets with SOPS](./concepts/sops.md).

| Command | What it does |
| --- | --- |
| `task secrets:edit` | Open the encrypted file in your editor |
| `task secrets:show` | Print the decrypted values, to check your age key works |
| `task secrets:edit:cluster -- <file>` | Open an encrypted `SopsSecret` from `gitops/system/base/` |
| `task cluster:sops-key` | Put the age key in the cluster, so the operator can decrypt |
| `age-keygen -o ~/.config/sops/age/keys.txt` | Create the key. Once, ever |
| `sops updatekeys <file>` | Re-encrypt after changing `.sops.yaml` |

Two places hold secrets, and the difference is who reads them:

| Where | Read by | Reaches it via |
| --- | --- | --- |
| `secrets.enc.yaml` | Commands you run | `sops exec-env` |
| `gitops/system/base/**/*.sops.yaml` | The cluster | sops-secrets-operator |

The age key at `~/.config/sops/age/keys.txt` is not in the repo and cannot be
recovered from it. If it is gone, every secret has to be created again. The
cluster holds a copy of it, so it can also read `secrets.enc.yaml`; see
[Secrets with SOPS](./concepts/sops.md).

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

### Guests and the API user

| Command | Good result |
| --- | --- |
| `qm list` | Six guests, `cp-1` to `cp-3` and `worker-1` to `worker-3`, all `running` |
| `pvesh get /storage/local` | Content types include `images` and `snippets` |
| `pveum user list` | `opentofu@pve` present |
| `pveum user token list opentofu@pve` | One token, named `tofu` |
| `headscale nodes list-routes` | `10.10.10.0/24` against `homelab`, approved |

To mint the API token, once. The secret is shown once and never again:

```bash
pveum user token add opentofu@pve tofu --privsep 0
```

Without `--privsep 0` the token has no permissions and every call returns `403`.

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
tailscale up --login-server https://vpn.homelab.grncunha.com --authkey <key> --accept-routes
```

That is the command-line client. The app clients have no `--login-server` flag
and are pointed at headscale through their own settings, which headscale
documents per platform:

| Platform | Where the steps live |
| --- | --- |
| Android | [headscale: Android](https://headscale.net/stable/usage/connect/android/) |
| iOS, macOS | [headscale: Apple](https://headscale.net/stable/usage/connect/apple/) |
| Windows | [headscale: Windows](https://headscale.net/stable/usage/connect/windows/) |

Two things those pages will not tell you, because they are particular to this
mesh: the device must stay **untagged**, or it loses the user identity the
access policy sorts people from servers by; and accepting subnet routes is what
makes `10.10.10.0/24` reachable. On the command line that is `--accept-routes`
above, in an app it is a setting, and without it every guest, the Kubernetes
API and `talosctl` all time out while headscale itself looks fine.

| Command | Good result |
| --- | --- |
| `tailscale status` | Connected, and `homelab` listed as a peer |
| `dig +short proxmox.homelab.grncunha.com` | An address starting `100.64.` |
| `tailscale ping homelab` | A reply |
| `netstat -rn -f inet \| grep 10.10.10` | A route for `10.10.10/24` on a `utun` interface |

If `dig` returns the public address instead, this device is not accepting DNS
from headscale, and Proxmox will answer `403`.

If `netstat` prints nothing, this device is not accepting subnet routes, and
everything on `10.10.10.0/24` times out: the guests, the Kubernetes API,
`talosctl`, `tofu apply`. Fix it with `tailscale set --accept-routes`. See
[The mesh network](./concepts/mesh.md).

Then open `https://proxmox.homelab.grncunha.com` in a browser. No port, no
certificate warning.

## On the Kubernetes cluster

Get the config files first, from the repo on your own machine:

```bash
task tofu:kubeconfig && export KUBECONFIG=$PWD/kubeconfig
task tofu:talosconfig && export TALOSCONFIG=$PWD/talosconfig
```

Talos has no SSH and no shell. `talosctl` is the only way in.

| Command | Good result |
| --- | --- |
| `kubectl get nodes -o wide` | Six nodes, all `Ready`, all `v1.36.2` |
| `kubectl get pods -A` | Everything `Running` or `Completed` |
| `talosctl --nodes 10.10.10.11 health` | Every check passes |
| `talosctl --nodes 10.10.10.11 service etcd status` | `Running` and healthy |
| `talosctl --nodes 10.10.10.11 dmesg` | Kernel and Talos logs for one node |
| `talosctl --nodes 10.10.10.11 get members` | All six nodes known to the cluster |
| `talosctl --nodes 10.10.10.11 get addresses` | Includes `10.10.10.10` on whichever node holds the virtual IP |

| Address | What it is |
| --- | --- |
| `10.10.10.10` | The Kubernetes API. Virtual, moves between control planes |
| `10.10.10.11`-`.13` | `cp-1` to `cp-3` |
| `10.10.10.21`-`.23` | `worker-1` to `worker-3` |
| `10.10.10.200` | `gw-internal-prod`, every prod workload on the mesh |
| `10.10.10.201` | `gw-internal-dev`, every dev workload on the mesh |

Restarting a node is `talosctl --nodes <ip> reboot`. Draining first is polite but
not required; Talos brings the node back into the cluster on its own.

### The network

Cilium is the CNI and it also replaces kube-proxy, so it is what Services run on
as well. See [The cluster's networking](./concepts/cilium.md).

| Command | Good result |
| --- | --- |
| `kubectl -n kube-system get pods -l k8s-app=cilium` | Six pods, `Running`, `1/1` |
| `kubectl -n kube-system exec ds/cilium -- cilium-dbg status --brief` | `OK` |
| `kubectl -n kube-system get daemonset cilium -o jsonpath='{.spec.template.spec.containers[0].image}'` | The version pinned in `gitops/system/base/cilium/cilium.yaml` |
| `kubectl -n kube-system get pods -l k8s-app=kube-proxy` | **No resources found.** There is no kube-proxy, on purpose |

Upgrading it has its own procedure:
[Upgrading Cilium](./manual/maintenance/upgrading-cilium.md).

**`local-path` is the default storage class**, so a claim that names no class
gets it. A volume is a directory on one worker and does not move. See
[The cluster's storage](./concepts/storage.md).

| Command | Good result |
| --- | --- |
| `kubectl get storageclass` | `local-path (default)`, `WaitForFirstConsumer` |
| `kubectl get pvc -A` | Every claim `Bound`. A `Pending` one with no events is usually a class that does not exist |
| `talosctl -n 10.10.10.21 get volumestatus u-local-path-provisioner` | `ready`, on `/dev/vdb1` |

### Metrics and logs

Metrics are scraped into VictoriaMetrics, logs are shipped into VictoriaLogs,
and Grafana reads both. See
[Seeing what the cluster is doing](./concepts/observability.md).

| Command | Good result |
| --- | --- |
| `kubectl -n victoria-metrics get pods` | `victoria-metrics-0`, `1/1` |
| `kubectl -n victoria-logs get pods` | The server, plus one collector per **worker**. A collector on a control plane means it lost its taint |
| `kubectl -n grafana get pods` | One pod, every container ready — Grafana plus its dashboard sidecar |
| `kubectl -n kube-state-metrics get pods` | One pod, `1/1` |
| `task secrets:show:cluster -- gitops/system/base/grafana/admin-credentials.sops.yaml` | Grafana's admin login. Only applied when Grafana first built its database |

To ask VictoriaMetrics directly, which has no route of its own:

```bash
kubectl -n victoria-metrics port-forward svc/victoria-metrics 8428:8428
curl -s 'http://127.0.0.1:8428/api/v1/query?query=sum(up)by(job)' | jq -r \
  '.data.result[] | "\(.metric.job) \(.value[1])"'
```

Every job in the scrape config comes back, and none of them at `0`. A job
missing entirely, or sitting at `0`, is the fault. A component that stops
reporting has usually lost its `prometheus.io/scrape` annotation rather than
broken its endpoint.

To ask VictoriaLogs which namespaces are actually shipping:

```bash
kubectl -n victoria-logs port-forward svc/victoria-logs 9428:9428
curl -s -G 'http://127.0.0.1:9428/select/logsql/query' \
  --data-urlencode 'query=* | stats by (kubernetes.pod_namespace) count() as n | sort by (n desc)'
```

One line per namespace, busiest first. A namespace you expect to see and do not
is the fault.

Swapping `pod_namespace` for `pod_node_name` answers a different question: every
node in that answer is a worker. Control-plane logs never arrive here; read
those with `talosctl -n 10.10.10.11 logs etcd`.

### Getting in and out

Everything reachable by name goes through a Gateway. See
[Getting traffic into the cluster](./concepts/ingress.md), and
[Exposing a service](./manual/maintenance/exposing-a-service.md) to add one.

| Command | Good result |
| --- | --- |
| `kubectl -n gateway-system get svc` | `10.10.10.200` and `.201` under `EXTERNAL-IP`, never `<pending>` |
| `kubectl -n gateway-system get gateway` | Three Gateways, `PROGRAMMED: True` |
| `kubectl get ciliumloadbalancerippool` | `guest-bridge`, not `Disabled` |
| `kubectl get ciliuml2announcementpolicy` | `guest-bridge` |
| `kubectl get httproute -A` | Every route you expect, and no others |
| `kubectl -n <ns> describe httproute <name>` | `Accepted: True`. `NotAllowedByListeners` means the namespace is missing its `env` label |
| `kubectl -n gateway-system get certificate` | Both wildcards `READY: True` |
| `kubectl -n gateway-system get challenge` | Empty. Anything lingering is a DNS-01 that is not completing |
| `kubectl -n external-dns logs deploy/external-dns \| tail -20` | The mesh records it last wrote. The public ones are `deploy/external-dns-tunnel` |
| `dig +short <app>.k8s.homelab.grncunha.com` | `10.10.10.200` |
| `dig +short <app>.grncunha.com` | Cloudflare addresses, `104.*` or `172.67.*`. A `.cfargotunnel.com` line means the record went out unproxied |
| `kubectl -n cloudflared logs -l app=cloudflared \| grep -c "Registered tunnel connection"` | `8`, four per pod |
| `curl -o /dev/null -w '%{http_code}\n' http://10.10.10.200` | `404`, from Envoy. A timeout means nothing is answering ARP for the address |

A `Service` stuck at `<pending>` and an address that never answers look the same
from `kubectl get gateway`, and they are different faults. The `curl` above is
what tells them apart.

### GitOps

The cluster's contents come from `gitops/`, applied by ArgoCD. See
[GitOps with ArgoCD](./concepts/gitops.md).

| Command | Good result |
| --- | --- |
| `task cluster:render` | `Both overlays render.` Needs no cluster; run before committing |
| `task cluster:diff` | Only the change you meant to make |
| `task cluster:bootstrap` | Installs ArgoCD, or repairs it. Safe to re-run |
| `task cluster:sops-key` | The one secret ArgoCD cannot supply. Re-run after a rebuild |
| `kubectl -n argocd get applications` | Every one `Synced` and `Healthy` |
| `kubectl -n argocd get pods` | Everything `Running` |
| `kubectl get sopssecret -A` | Every committed secret, and no error in the operator's log |
| `task secrets:edit:cluster -- <file>` | Edits an encrypted `SopsSecret` in place |

The UI is at `argocd.k8s.homelab.grncunha.com`, on the mesh, read-only without
logging in.

## Recovering

| Situation | What to do |
| --- | --- |
| Locked out by SSH or the firewall | Hetzner rescue mode. See [step by step](./troubleshooting/step-by-step.md) |
| A role went wrong | Undo that piece, then run it again. Same document |
| The cluster is wrong | `task tofu:destroy`, `task tofu:apply`, `task cluster:sops-key`, `task cluster:bootstrap`. It is disposable |
| ArgoCD is wrong | `task cluster:bootstrap`. It applies the same manifests ArgoCD syncs, so it repairs rather than reinstalls |
| Beyond fixing | Reinstall and start from [Bootstrap](./manual/provisioning/1-bootstrap.md) |

Ansible has no undo. Running the playbook again re-applies the wanted state; it
does not return the server to how it was before.
