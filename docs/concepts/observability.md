# Seeing what the cluster is doing

Four questions, four tools. This explains which one answers which, how the
data gets there, and — more usefully — what is not collected at all.

| Question | Where to look |
| --- | --- |
| Is it up, how much is it using, and what did that look like an hour ago | Grafana, reading VictoriaMetrics |
| What did it print | VictoriaLogs |
| Which functions is it spending its CPU and memory in | Grafana, reading Pyroscope |
| What is talking to what | Hubble, which is part of Cilium |

Hubble is not covered here. It is a property of the CNI and lives in
[The cluster's networking](./cilium.md).

## What is used

**VictoriaMetrics** for metrics, **VictoriaLogs** for logs, **Pyroscope** for
profiles, all single-server, with **Grafana** in front of them.

| Namespace | What runs there |
| --- | --- |
| `victoria-metrics` | The metric store, and the scraper inside it |
| `victoria-logs` | The log store, and a collector on every node |
| `kube-state-metrics` | Turns the API server's object list into metrics |
| `node-exporter` | Host-level metrics from every node, control planes included |
| `pyroscope` | The profile store, and the Alloy that scrapes profiles into it |
| `grafana` | The dashboards, reading all three stores |

Chart versions and volume sizes live in each Application and are not repeated
here.

Single-server, not clustered. A handful of nodes on one host do not produce enough of
either to need sharding, and a cluster of three components has three ways to be
half-broken.

## Why VictoriaMetrics and not Prometheus

Being honest about the reasons, because the usual ones do not apply here:

| Reason | Does it apply? |
| --- | --- |
| Faster ingestion, better compression at scale | **No.** Nothing here is at scale |
| Noticeably less memory for the same data | Yes, and on a host with 125 GiB shared between everything, that is the reason |
| Prometheus-compatible query API | Yes, and it is what makes the stock grafana.com dashboards work unmodified |

That last one is load-bearing. Both dashboards are pulled from grafana.com by
`gnetId`, and they are written against Prometheus. They work because
VictoriaMetrics answers PromQL.

## Metrics are pulled, logs are pushed

The two halves work in opposite directions, which is worth holding in your head
before debugging either.

**Metrics.** VictoriaMetrics scrapes, on a config written inline in
`gitops/system/base/victoria-metrics/application.yaml`. Six jobs, in two groups:

| Job | What it gives you |
| --- | --- |
| `victoriametrics` | Its own health |
| `kubernetes-apiservers` | Request rates and latency, per control plane |
| `kubernetes-nodes` | The kubelet on every node |
| `kubernetes-nodes-cadvisor` | Per-container CPU, memory, network |
| `kubernetes-pods` | Anything whose **pod** says to scrape it |
| `kubernetes-service-endpoints` | Anything whose **Service** says to scrape it |

The first four name their targets. The last two name nothing at all, and that
difference is the whole design.

**Logs.** The collector runs on every schedulable node, reads each container's
log file off that node, and writes to
`http://victoria-logs.victoria-logs.svc.cluster.local:9428`. Nothing is asked
for; the collector decides what to send.

It attaches pod name, namespace, node and container as fields, so a search can
be narrowed without knowing anything else. It also drops `password`, `token` and
`request.payload*` before sending, so a secret printed into a log does not get
stored for a week.

## A component asks to be scraped

There is no list of scrape targets anywhere, and adding a workload does not mean
editing VictoriaMetrics. The two discovery jobs keep anything annotated:

```yaml
prometheus.io/scrape: "true"
prometheus.io/port: "9402"
```

Most charts set that on themselves already — cert-manager, Envoy, kgateway,
cilium-operator, CoreDNS and kube-state-metrics all arrive pre-annotated. The
rest opt in with a `podAnnotations` value beside their own manifest, which is
the same rule the repo follows for everything else: a component owns what it
declares about itself.

Profiles work the same way, with their own annotations, one pair per profile
type. Alloy, in the `pyroscope` namespace, fetches the pod's pprof endpoints:

```yaml
profiles.grafana.com/cpu.scrape: "true"
profiles.grafana.com/cpu.port: "6060"
```

`memory`, `goroutine`, `block` and `mutex` take the same pair. Every project
namespace lets the `pyroscope` namespace in, as it does `victoria-metrics`.

Two jobs rather than one because charts disagree about where the annotation
belongs. Pod annotations cover cert-manager, Envoy, Cilium's agent; Service
annotations cover CoreDNS, `hubble-metrics` and kube-state-metrics. Neither job
knows any names.

VictoriaMetrics is the exception: it is scraped by the `victoriametrics` job on
`localhost:8428` and is deliberately **not** annotated, because it would then be
collected twice under two job names.

This is also why there is no OpenTelemetry collector. A collector's Prometheus
receiver would scrape exactly these endpoints, one hop further away, and none of
these components speak OTLP anyway. VictoriaMetrics already accepts OTLP
directly on `/opentelemetry/v1/metrics`, so an instrumented application of your
own can push straight to it with nothing in between. A collector earns its place
for traces or fan-out, not for this.

## What is not collected

The gaps matter more than the coverage, because nothing tells you they are
there. A query simply returns nothing.

**No logs from Talos services.** The collector tolerates every taint, so it
runs on every node and reads every pod's log, the API server, scheduler and
controller manager included. etcd and the kubelet are not pods. They are Talos
services, and **their logs never reach VictoriaLogs**. Read them with
`talosctl` instead:

```bash
talosctl --nodes 10.10.10.11 logs etcd
talosctl --nodes 10.10.10.11 logs kubelet
```

It is in [Improvements](../improvements.md).

## How long it is kept

| | Retention | Set where |
| --- | --- | --- |
| Logs | 7 days | Explicitly, in the Application |
| Profiles | 14 days | Explicitly, in the Application |
| Metrics | 1 month | Nowhere — it is the chart's default |

The asymmetry is not deliberate, and the metrics figure is written down in no
file, which is the part worth fixing.

All three volumes come from `local-path`, so each lives on whichever system node its
pod first landed on. Losing that node loses the history with it. That is an
accepted trade for a homelab and is explained in
[The cluster's storage](./storage.md); it is also the reason none of these
is a backup.

## Getting in

| | Where | Reachable from |
| --- | --- | --- |
| Grafana | `grafana.k8s.homelab.grncunha.com` | the mesh |
| VictoriaLogs' own UI | `victoria-logs.k8s.homelab.grncunha.com` | the mesh |
| VictoriaMetrics | no route | port-forward, or through Grafana |

VictoriaMetrics is deliberately not exposed. Grafana is the way in, and its own
`vmui` is a debugging tool rather than something to bookmark:

```bash
kubectl -n victoria-metrics port-forward svc/victoria-metrics 8428:8428
```

## Grafana's two datasources, and two ways a dashboard arrives

| Datasource | Type | Reads |
| --- | --- | --- |
| `victoriametrics` | `prometheus`, and the default | Metrics, in PromQL |
| `victorialogs` | `victoriametrics-logs-datasource` | Logs, in LogsQL |

The logs one needs a plugin, listed under `plugins:` and installed from
grafana.com when the pod starts. Its id is `victoriametrics-logs-datasource`;
the older `victorialogs-datasource` no longer exists, so any dashboard still
asking for that one will not bind to this datasource. There is no published
log-browsing dashboard that uses the current id — build panels against Explore
instead.

Dashboards arrive two ways:

- **By `gnetId` and `revision`**, downloaded from grafana.com at startup by an
  init container. Both numbers are required: with no `revision` the chart asks
  for revision 1, the first version ever published, which is usually written
  against metric names that have since been renamed. A cluster with no egress
  gets an empty dashboard list and no error anywhere obvious.
- **As a labelled ConfigMap**, collected by Grafana's sidecar from any
  namespace. That is how Cilium's dashboards arrive: its chart ships versions
  written for the release actually running, which grafana.com's Cilium
  dashboards are not. It is also the way to ship a dashboard next to the
  component it describes.

## Grafana's password is set once, and only once

The admin login is a `SopsSecret`,
`gitops/system/base/grafana/admin-credentials.sops.yaml`. Read it with:

```bash
task secrets:show:cluster -- gitops/system/base/grafana/admin-credentials.sops.yaml
```

**Grafana applies `GF_SECURITY_ADMIN_PASSWORD` only when it first creates its
database.** Change the Secret on a running install and nothing happens: the
password lives in `grafana.db` on the volume from then on, and the environment
variable is ignored. Logging in still fails with the old password, which is the
one you no longer have.

That is why the Secret is sync-wave 3 and Grafana is wave 4 — on a fresh
cluster the login exists before the database that reads it. On an install that
is already running, either reset it in place, passing the password read above:

```bash
kubectl -n grafana exec deploy/grafana -c grafana -- \
  grafana cli admin reset-admin-password '<the password>'
```

or, when the volume holds nothing worth keeping, delete the PVC and the pod and
let Grafana start again. Everything Grafana serves — datasources, plugin and
dashboards — is provisioned from git, so a fresh volume costs nothing unless
someone has been clicking.

## Where the pieces live

| What | Where |
| --- | --- |
| Metric storage, and the scrape config | `gitops/system/base/victoria-metrics/application.yaml` |
| Log storage | `gitops/system/base/victoria-logs/application.yaml` |
| The log collector | `gitops/system/base/victoria-logs/collector.yaml` |
| Object-state metrics | `gitops/system/base/kube-state-metrics/application.yaml` |
| Host-level metrics | `gitops/system/base/node-exporter/application.yaml` |
| The Node pools dashboard: steal, pressure, usage and requests per pool | `gitops/system/base/node-exporter/node-pools.json` |
| Cilium and Hubble metrics, and their dashboards | `gitops/system/base/cilium/cilium.yaml` |
| Grafana, its datasources, plugin and dashboards | `gitops/system/base/grafana/application.yaml` |
| Grafana's admin login | `gitops/system/base/grafana/admin-credentials.sops.yaml` |
| The two UI routes | `route.yaml` in each of those directories |
| Network flow visibility | [The cluster's networking](./cilium.md) |
| Why a volume is node-local | [The cluster's storage](./storage.md) |
| The commands | [Cheatsheet](../cheatsheet.md) |
