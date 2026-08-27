# Manual 5 - Open the tunnel

This makes the cluster reachable from the internet, over a Cloudflare tunnel.
Nothing new listens on the host: the tunnel is opened from inside, outbound, and
the firewall does not change.

Before you start, finish
[Bootstrap GitOps](./4-bootstrap-gitops.md). ArgoCD must be syncing and
`gw-public` must exist:

```bash
export KUBECONFIG=$PWD/kubeconfig
kubectl -n gateway-system get gateway gw-public
```

```
NAME        CLASS      ADDRESS   PROGRAMMED   AGE
gw-public   kgateway             True         35h
```

No address is correct. `gw-public` is a `ClusterIP`, and `cloudflared` reaches
it over the cluster network.
[Getting traffic into the cluster](../../concepts/ingress.md) explains why the
path is shaped this way.

This step is done once, by hand. The tunnel is not an OpenTofu resource: it is
created here, its credentials go into git encrypted, and nothing after that
needs an account-scoped Cloudflare token.

## 1. Creating the tunnel

```bash
brew install cloudflared
cloudflared tunnel login
```

A browser opens. Pick `grncunha.com`. This writes `~/.cloudflared/cert.pem`,
which is what lets this machine create and delete tunnels. The cluster never
sees it, and it is not in this repo.

```bash
cloudflared tunnel create homelab
```

```
Tunnel credentials written to /Users/you/.cloudflared/<tunnel-id>.json.
Created tunnel homelab with id <tunnel-id>
```

Keep the id. It is an identifier, not a secret, and is committed in the clear.

```bash
cloudflared tunnel list
```

```
ID          NAME     CREATED              CONNECTIONS
<tunnel-id> homelab  2026-08-27T10:14:22Z
```

No connections yet is expected. Nothing is running the connector.

**Do not run `cloudflared tunnel route dns`.** That command writes the CNAME,
and external-dns owns DNS for this cluster. Two writers on one name is a
conflict; step 4 is how the record gets made.

The CLI makes the tunnel *locally managed*: Cloudflare holds no ingress rules
for it, so the ConfigMap in step 3 is the routing table rather than a copy of
one. A tunnel made in the dashboard is not.

## 2. Putting the credentials in git

The credentials file holds three fields, all of which `cloudflared` needs:

```bash
cat ~/.cloudflared/<tunnel-id>.json
```

```json
{"AccountTag":"...","TunnelID":"...","TunnelSecret":"..."}
```

Paste it, on one line, into `gitops/secrets/base/cloudflared.sops.yaml` as the
`credentials.json` value, then encrypt the file:

```bash
sops -e -i gitops/secrets/base/cloudflared.sops.yaml
task secrets:check
```

```
gitops/secrets/base/cloudflared.sops.yaml is encrypted.
```

`secrets:check` must name the file: it is not gitignored, so a plaintext one
would be committed. See [Secrets with SOPS](../../concepts/sops.md).

Delete the local copy under `~/.cloudflared/`. Keep `cert.pem`, or you cannot
manage the tunnel later.

## 3. Pointing the connector at the Gateway

Three values carry the tunnel id, and all three are already in this repo waiting
for yours:

| File | Field |
| --- | --- |
| `gitops/system/base/cloudflared/configmap.yaml` | `tunnel:` |
| `gitops/network/base/gateways.yaml` | the `target` annotation on `gw-public` |
| `gitops/secrets/base/cloudflared.sops.yaml` | `TunnelID`, inside the credentials |

It changes only if the tunnel is deleted.

## 4. Deploying

Commit on a branch, open a pull request, and merge it. ArgoCD tracks `main`, so
merging is what deploys.

```bash
kubectl -n cloudflared get pods
```

```
NAME                           READY   STATUS    RESTARTS   AGE
cloudflared-7d4f8b6c5d-9x2kq   1/1     Running   0          40s
cloudflared-7d4f8b6c5d-lm4rt   1/1     Running   0          40s
```

```bash
kubectl -n cloudflared logs -l app=cloudflared | grep -c "Registered tunnel connection"
```

```
8
```

Four connections per pod is `cloudflared`'s own default, not something set here.

## 5. Checking it end to end

`examples/web-public/` is a throwaway app for this: `traefik/whoami` on
`gw-public`, with no annotations on the route. ArgoCD does not sync `examples/`,
so applying it is not a deployment.

```bash
kubectl apply -k examples/web-public
kubectl -n web-public rollout status deploy/whoami
```

```
deployment "whoami" successfully rolled out
```

First, that the route attached:

```bash
kubectl -n web-public get httproute whoami \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}{"\n"}'
```

```
True
```

`False`, or `NotAllowedByListeners` in the full status, means the namespace lost
its `env: prod` label.

Then that external-dns wrote a **proxied** record. Give it about a minute:

```bash
dig +short whoami.grncunha.com
```

```
104.21.64.1
172.67.180.22
```

Cloudflare's addresses prove it is proxied. A `.cfargotunnel.com` line instead
means the record was written unproxied and will not resolve for a browser:

```bash
kubectl -n external-dns logs deploy/external-dns-tunnel | grep whoami
```

Now the tunnel itself, from a device that is **not** on the mesh:

```bash
curl -sS https://whoami.grncunha.com
```

```
Hostname: whoami-5c9d7f8b4d-2xqvw
IP: 127.0.0.1
IP: 10.244.2.17
RemoteAddr: 10.244.1.9:52134
GET / HTTP/1.1
Host: whoami.grncunha.com
X-Forwarded-Proto: https
```

Read the `Host` line: it must be the public name. `cloudflared` passes the
original host through and `gw-public` matches the route on it, so anything else
is a 404.

Then confirm nothing new is listening:

```bash
nmap -Pn homelab.grncunha.com -p 1-1000
```

```
PORT    STATE SERVICE
22/tcp  open  ssh
80/tcp  open  http
443/tcp open  https
```

Three ports, the same three as before the tunnel. That is the whole reason for
choosing a tunnel over a port forward.

Then remove the example. It is a test, not a workload:

```bash
kubectl delete -k examples/web-public
dig +short whoami.grncunha.com
```

The second should print nothing within a minute: external-dns owns the record
and prunes it. If it still resolves, remove it by hand.

## When it does not work

**HTTPS fails, HTTP works.** The name has no edge certificate, which means it is
too deep: Universal SSL covers the apex and one level only. `whoami.grncunha.com`
is covered, `whoami.apps.homelab.grncunha.com` is not. See
[Names](../../architecture/names.md).

```bash
curl -sS  https://whoami.grncunha.com    # curl: (35) ... handshake failure
curl -sSI http://whoami.grncunha.com     # 200
```

The `cloudflared` logs stay empty: the handshake is refused at the edge and no
request is made.

**Cloudflare error 1033.** The record resolves but no connector is registered.
Check step 4, then the credentials.

```bash
kubectl -n cloudflared logs -l app=cloudflared | tail -20
```

`Couldn't decode credentials` means the JSON in the `SopsSecret` is malformed or
was pasted across several lines.

**A 502 from Cloudflare.** `gw-public` refused the request, almost always a
hostname matching no `HTTPRoute`. Check from inside the cluster:

```bash
kubectl -n cloudflared exec deploy/cloudflared -- \
  curl -sI -H 'Host: <app>.grncunha.com' http://gw-public.gateway-system.svc
```

**The name does not resolve at all.** external-dns has not written it.

```bash
kubectl -n external-dns logs deploy/external-dns-tunnel | tail -20
```

It only considers Gateways labelled `dns-mode: tunnel`. If it logs nothing about
your hostname, check that label on `gw-public`.

**A record appears, unproxied.** The wrong instance picked the route up. Check
the same log on `external-dns`, which is filtered to `dns-mode: direct`.
