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

Then reach it. Once external-dns is running the name resolves on its own; until
then, by address and `Host` header:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H 'Host: my-app.k8s.homelab.grncunha.com' http://10.10.10.200
```

```
200
```

A `404` means Envoy answered but no route matched: the hostname in the header
and the one in the route disagree. A `503` means the route matched and the
backend is not answering, so the problem is the workload, not this.
