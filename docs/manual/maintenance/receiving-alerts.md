# Receiving alerts

Getting the "is down" and "is back up" messages on an Android phone. Once per
phone.

For how the messages come to exist, see
[Knowing when something is down](../../concepts/alerts.md).

## 1. Putting the phone on the mesh

ntfy answers on the mesh only. Join the phone as in the
[Cheatsheet](../../cheatsheet.md#on-a-device-joining-the-mesh), and leave the
Tailscale app connected. A message sent while the phone is off the mesh arrives
when it reconnects, for up to 72 hours.

## 2. Subscribing

Install **ntfy** from the Play Store or F-Droid. Then:

1. Tap **+**.
2. Topic name: `uptime`.
3. Tick **Use another server**.
4. Server: `https://ntfy.k8s.homelab.grncunha.com`.
5. Tap **Subscribe**.

Android asks to exempt the app from battery optimisation. Allow it. ntfy holds
a connection open to receive messages, and Android closes it otherwise.

## 3. Checking it works

From any device on the mesh:

```bash
curl -d "Test message" https://ntfy.k8s.homelab.grncunha.com/uptime
```

```
{"id":"...","time":...,"event":"message","topic":"uptime","message":"Test message"}
```

The phone shows **Test message** within a few seconds.

To check the whole chain and not only the last step, look at what Grafana is
watching:

```bash
kubectl -n victoria-metrics port-forward svc/victoria-metrics 8428:8428 &
curl -s 'localhost:8428/api/v1/query?query=probe_success{job="uptime"}' \
  | jq -r '.data.result[] | "\(.value[1]) \(.metric.hostname)"'
```

```
1 argocd.k8s.homelab.grncunha.com
1 grafana.k8s.homelab.grncunha.com
1 url-shortener.grncunha.com
```

One line per hostname. `1` is answering, `0` is not.

## Reading the failures

| Result | Meaning |
| --- | --- |
| `could not resolve host` on the test | The device is not on the mesh, or not accepting its routes |
| The test prints JSON, the phone shows nothing | The phone is off the mesh, or Android closed the app's connection: check step 2's battery setting |
| The phone reconnects every few seconds | The route's `timeouts.request: 0s` is not applied; see `gitops/system/base/ntfy/route.yaml` |
| A hostname is missing from the list | Its route carries `homelab.grncunha.com/probe: "false"`, or `probe-targets` has not listed it yet: `kubectl -n blackbox-exporter logs deploy/probe-targets -c discover` |
| A hostname reads `0` and the page loads for you | Its root does not answer `2xx`. Name a path that does, with `homelab.grncunha.com/probe-path` |
| An application was down and no message came | `kubectl -n grafana logs deploy/grafana -c grafana \| grep -i notif` |
