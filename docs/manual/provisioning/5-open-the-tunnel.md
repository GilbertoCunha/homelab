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

Keep the id. It is needed three times below, and it is an identifier rather than
a secret, so it is committed in the clear.

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

Creating the tunnel with the CLI rather than the dashboard also makes it
*locally managed*: Cloudflare holds no ingress rules for it and expects the
connector to carry its own. That is what makes the ConfigMap in step 3 the
routing table rather than a copy of one.

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

`secrets:check` must name the file. It is deliberately not gitignored, so a
plaintext one would be committed. [Secrets with SOPS](../../concepts/sops.md)
explains the scheme.

The local copy under `~/.cloudflared/` is now a duplicate and can be deleted.
Keep `cert.pem`: without it you cannot manage the tunnel later.

## 3. Pointing the connector at the Gateway

Three values carry the tunnel id, and all three are already in this repo waiting
for yours:

| File | Field |
| --- | --- |
| `gitops/system/base/cloudflared/configmap.yaml` | `tunnel:` |
| `gitops/network/base/gateways.yaml` | the `target` annotation on `gw-public` |
| `gitops/secrets/base/cloudflared.sops.yaml` | `TunnelID`, inside the credentials |

The id is stated rather than shared because the three are read by different
things, in different namespaces, from different manifests. It changes only if
the tunnel is deleted.

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

Four connections per pod, across two Cloudflare datacenters, is `cloudflared`'s
own high-availability default rather than something configured here.

## 5. Checking it end to end

`examples/web-public/` is a throwaway app for exactly this: `traefik/whoami`, a
`Service`, a namespace labelled `env: prod`, and an `HTTPRoute` on `gw-public`
carrying no annotations. Apply it by hand. ArgoCD does not sync `examples/`, so
nothing here is a deployment and nothing needs a commit.

```bash
kubectl apply -k examples/web-public
kubectl -n web-public rollout status deploy/whoami
```

```
deployment "whoami" successfully rolled out
```

First, that the route attached. This is the API server's answer, not a guess:

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

Cloudflare's own addresses are what proves it is proxied. A
`<tunnel-id>.cfargotunnel.com` line in the answer instead means the record was
written unproxied, the name will not resolve for a browser, and the two
external-dns instances are not split correctly. Check which one claimed it:

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

The `Host` line is the one to read. It must be the public name, not
`gw-public.gateway-system.svc`: `cloudflared` passes the original host through,
and `gw-public` matches the route on it. Anything else there means the routing
in the ConfigMap is wrong, and you would see a 404 rather than this output.

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

The second command should print nothing within a minute or so. external-dns
owns the record, so deleting the route deletes it; a name that still resolves
means `policy: sync` is not pruning and the record will have to go by hand.

## When it does not work

**HTTPS fails but HTTP works.** The clearest signal, and the easiest to
misread:

```bash
curl -sS  https://whoami.grncunha.com    # curl: (35) ... handshake failure
curl -sSI http://whoami.grncunha.com     # 200
```

Nothing appears in the `cloudflared` logs, because the handshake is refused at
the edge and no request is ever made. It means the name has no edge
certificate, which almost always means it is too deep: Universal SSL covers the
apex and one level only. `whoami.grncunha.com` is covered,
`whoami.apps.homelab.grncunha.com` is not. See
[Names](../../architecture/names.md).

**Cloudflare error 1033.** The record resolves but no connector is registered.
The tunnel exists and nothing is dialling it: check step 4, then the credentials.

```bash
kubectl -n cloudflared logs -l app=cloudflared | tail -20
```

`Couldn't decode credentials` means the JSON in the `SopsSecret` is malformed or
was pasted across several lines.

**A 502 from Cloudflare.** `cloudflared` connected and `gw-public` refused it,
which is almost always a hostname that matches no `HTTPRoute`. Check from inside
the cluster, bypassing the tunnel:

```bash
kubectl -n cloudflared exec deploy/cloudflared -- \
  curl -sI -H 'Host: <app>.grncunha.com' http://gw-public.gateway-system.svc
```

**The name does not resolve at all.** external-dns has not written it.

```bash
kubectl -n external-dns logs deploy/external-dns-tunnel | tail -20
```

The tunnel instance only considers Gateways labelled `dns-mode: tunnel`. If it
logs nothing about your hostname, check that label on `gw-public`.

**A record appears, unproxied.** The route was picked up by the wrong instance.
Both instances log which records they own; the one that should not have it is
`external-dns`, filtered to `dns-mode: direct`.
