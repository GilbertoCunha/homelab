# Homelab

Welcome to my homelab!

In this repo, I configure a dedicated server I have running:

- **OS**: debian 13
- **Mesh Network**: Headscale
- **Virtualization**: Proxmox
- **Container Orchestration**: Kubernetes, on Talos Linux
- **Provisioning**: OpenTofu, Ansible and ArgoCD

## Links

Most of these answer only to devices on the mesh. If a name does not resolve or
the page does not load, check that first: `tailscale status`, and
`tailscale set --accept-routes`.

| | What it is | Reachable from |
| --- | --- | --- |
| [Proxmox](https://proxmox.homelab.grncunha.com) | Virtual machines, storage and consoles | the mesh only |
| [Headscale](https://vpn.homelab.grncunha.com) | The mesh itself, where devices join | anywhere, by design |
| [ArgoCD](https://argocd.k8s.homelab.grncunha.com) | What is deployed in the cluster, and whether it is healthy | the mesh only |
| [Hubble](https://hubble.k8s.homelab.grncunha.com) | What is talking to what inside the cluster | the mesh only |
| [Grafana](https://grafana.k8s.homelab.grncunha.com) | Dashboards: what the cluster is doing, and what it was doing an hour ago | the mesh only |
| [VictoriaLogs](https://victoria-logs.k8s.homelab.grncunha.com) | What every pod printed, searchable | the mesh only |

The server itself is `homelab.grncunha.com`, over SSH.

## Documentation

- To get it running, read the [Operator Manual](./docs/manual/index.md).
- When something breaks, read [Applying step by step](./docs/troubleshooting/step-by-step.md).
- For the commands you reach for most, see the [Cheatsheet](./docs/cheatsheet.md).
- For how the system is put together, see [Architecture](./docs/architecture/index.md).
- For how a piece of it works rather than how to run it, see [Concepts](./docs/concepts/).
- For what is not built yet, see the [Backlog](./docs/backlog.md).
- For what runs but is not right yet, see [Improvements](./docs/improvements.md).
