# Exposing a service

The day-to-day procedure: making a workload reachable by name. It is one
`HTTPRoute` and, the first time in a new namespace, one label.

For how any of this works, see
[Getting traffic into the cluster](../../concepts/ingress.md).

## 1. Choosing a Gateway

| Gateway | Name your service gets | Reachable from |
| --- | --- | --- |
| `gw-internal-prod` | `<app>.k8s.homelab.grncunha.com` | The mesh |
| `gw-internal-dev` | `<app>.dev.k8s.homelab.grncunha.com` | The mesh |
| `gw-public` | `<app>.apps.homelab.grncunha.com` | Anyone |

Default to a mesh Gateway. Public is for something that has a reason to be.

The Gateway is the only thing that decides how the DNS record is written. A
route on `gw-public` gets a proxied `CNAME` through the tunnel; one on a mesh
Gateway gets an unproxied `A` record. Either way the route itself needs no
annotations.

## 2. Labelling the namespace

A Gateway only accepts routes from namespaces carrying the matching label. Set
it in the namespace manifest, not with `kubectl label`, or ArgoCD will remove it
again.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-app
  labels:
    env: prod
```

`env: prod` reaches `gw-internal-prod` and `gw-public`; `env: dev` reaches
`gw-internal-dev`. A namespace cannot carry both.

## 3. Writing the route

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: my-app
spec:
  parentRefs:
    - name: gw-internal-prod
      namespace: gateway-system
      sectionName: http
  hostnames:
    - my-app.k8s.homelab.grncunha.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: my-app
          port: 80
```

The hostname must fall under the Gateway listener's wildcard, or the route
attaches and then matches nothing.

If the chart you are deploying already has an `HTTPRoute` template, enable that
instead of writing this by hand. ArgoCD does exactly that for itself, in
`gitops/system/overlays/production/argocd/values.yaml`.

## 4. Committing and checking

Commit, and wait for ArgoCD to sync. Then check the route was accepted:

```bash
kubectl -n my-app describe httproute my-app | grep -A3 Conditions
```

```
Conditions:
  Type:    Accepted
  Status:  True
  Reason:  Accepted
```

`NotAllowedByListeners` means step 2 was missed, or the namespace has the wrong
environment for that Gateway. `NoMatchingListenerHostname` means the hostname is
outside the listener's wildcard.

Then wait about a minute and open it. external-dns writes the record and the
Gateway already has the wildcard certificate, so there is nothing else to add:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://my-app.k8s.homelab.grncunha.com
```

```
200
```

Reading the failures:

| Result | Meaning |
| --- | --- |
| `could not resolve host` | external-dns has not written the record yet, or the hostname is outside its domain filter. `kubectl -n external-dns logs deploy/external-dns` |
| Certificate warning | The hostname is not under a wildcard the Gateway serves. Wildcards do not nest: `a.dev.k8s...` needs the dev Gateway, not the prod one |
| `404` | Envoy answered, no route matched. The hostname in the route and the one you asked for disagree |
| `503` | The route matched and the backend is not answering. The problem is the workload, not this |

To separate a DNS problem from everything else, ask the Gateway by address:

```bash
curl -skS -o /dev/null -w '%{http_code}\n' \
  -H 'Host: my-app.k8s.homelab.grncunha.com' http://10.10.10.200
```

A `200` here with a failure above means DNS, and nothing else.
