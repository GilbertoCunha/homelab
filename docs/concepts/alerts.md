# Knowing when something is down

Every hostname the cluster serves is requested twice a minute. When one stops
answering, a phone is told. When it answers again, the phone is told that too.

This explains how, and what it cannot see. To get the messages on a phone, see
[Receiving alerts](../manual/maintenance/receiving-alerts.md).

## Why it exists

Every other signal here watches one part. A pod is `Running`, ArgoCD says
`Synced`, a certificate is `Ready`. All of them were true on the day an
external-dns upgrade deleted a DNS record and the public application answered
nobody.

A **probe** is a request made the way a browser makes it: resolve the name,
connect, check the certificate, read the answer. It fails when any part fails,
and it does not need to know which parts exist.

## The parts

| Part | What it does | Namespace |
| --- | --- | --- |
| `probe-targets` | Lists every `HTTPRoute` hostname, once a minute | `blackbox-exporter` |
| blackbox exporter | Requests a hostname and reports whether it answered | `blackbox-exporter` |
| VictoriaMetrics | Asks the exporter about each hostname, every 30 seconds | `victoria-metrics` |
| Grafana | Decides a hostname is down, and that it is back | `grafana` |
| ntfy | Delivers the message to a phone | `ntfy` |

A probe passes on any `2xx` answer over HTTPS, after following redirects.
Nothing else is checked.

## A new route is probed without being listed

There is no list of hostnames in git. `probe-targets` builds one from the
routes in the cluster, so
[exposing a service](../manual/maintenance/exposing-a-service.md) is all it
takes to have it watched. That includes routes from other repositories.

It is a small script and not a setting, because nothing discovers an
`HTTPRoute` for scraping. The Kubernetes discovery in VictoriaMetrics knows
pods, Services and Ingresses, and no Gateway API kind.

Two annotations on a route change what happens:

| Annotation | Effect |
| --- | --- |
| `homelab.grncunha.com/probe: "false"` | The route is not probed |
| `homelab.grncunha.com/probe-path: /healthz` | That path is requested, not `/` |

## Public names take the long way round

The probe resolves a name the way anything else does. So the two kinds of name
travel differently:

| Name | Path the probe takes |
| --- | --- |
| `<app>.k8s.homelab.grncunha.com` | Public DNS, then the mesh Gateway's address, from inside the cluster |
| `<app>.grncunha.com` | Public DNS, out to Cloudflare, back through the tunnel |

A public name is therefore tested end to end, from the cluster: its DNS
record, Cloudflare's certificate, the tunnel and the Gateway.

## When an alert fires, and when it clears

One rule covers every hostname, and each hostname is its own alert.

| Event | After |
| --- | --- |
| "is down" | Two minutes of failed probes. Three to four minutes from the failure |
| "is back up" | One passing probe. About two minutes from the recovery |
| A reminder that it is still down | Once a day |

**When the probe itself breaks, nothing changes state.** If the exporter stops
or VictoriaMetrics cannot be queried, the rule has no data. Every alert then
keeps the state it had. Grafana's default would clear them, and send "back up"
for an application that is still down.

A route that is deleted while down does send "back up". Its series is gone,
and Grafana cannot tell that from a recovery.

## What it cannot see

The whole chain runs on the system node, in the cluster it reports on.

| What fails | Are you told? |
| --- | --- |
| An application, its route, its DNS record, the tunnel | Yes |
| The worker node | Yes, for every application on it |
| The system node, the server or the mesh | **No. Silence** |

Silence is not a signal here. Something outside the cluster has to notice
that; it is in the [Backlog](../backlog.md).

The phone also has to be on the mesh. ntfy is served on a mesh name on
purpose: a public name would go through the tunnel, and losing the tunnel
would take the alerts with it. Messages sent while the phone is away wait
72 hours for it.

Grafana does not use that name. It posts to ntfy's Service, so sending an
alert does not depend on the DNS record or the Gateway the alert may be about.

## Where the pieces live

| What | Where |
| --- | --- |
| The exporter | `gitops/system/base/blackbox-exporter/application.yaml` |
| The list of hostnames | `gitops/system/base/blackbox-exporter/targets.yaml` |
| The `uptime` scrape job | `gitops/system/base/victoria-metrics/application.yaml` |
| The rule, and where it is sent | `alerting:` in `gitops/system/base/grafana/application.yaml` |
| ntfy, and the wording of a message | `gitops/system/base/ntfy/` |
