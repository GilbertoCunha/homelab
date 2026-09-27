# Operator Manual

Everything you need to know to operate the homelab properly.

The manual is split by when you need it. [Provisioning](#provisioning) is what
you do once, in order, to get from a bare server to a running cluster.
[Maintenance](#maintenance) is what you do afterwards, for as long as the
cluster exists.

## Provisioning

Follow these in order. Each one assumes the ones above it are done.

1. [Bootstrapping](./provisioning/1-bootstrap.md): how to get the homelab up and running
2. [Configuring](./provisioning/2-configure-server.md): how to install and configure everything on the server
3. [Provisioning](./provisioning/3-provision-cluster.md): how to build the Kubernetes cluster on the server
4. [Bootstrapping GitOps](./provisioning/4-bootstrap-gitops.md): how to install ArgoCD, so the cluster's contents come from git
5. [Opening the tunnel](./provisioning/5-open-the-tunnel.md): how to make the cluster reachable from the internet, without opening a port

## Maintenance

Standalone procedures. Read the one you need.

- [Adding a project](./maintenance/adding-a-project.md): somewhere for an
  application to live, which is one file in the catalog
- [Exposing a service](./maintenance/exposing-a-service.md): making a workload
  reachable by name, which is one `HTTPRoute` and nothing else
- [Upgrading Cilium](./maintenance/upgrading-cilium.md): the CNI, which is also
  the thing every pod depends on to have a network at all

## Elsewhere

- For how the system is put together: [Architecture](../architecture/index.md)
- When something breaks: [Applying step by step](../troubleshooting/step-by-step.md)
- For how a piece works rather than how to run it: [Concepts](../concepts/)
- For the commands you reach for most: [Cheatsheet](../cheatsheet.md)
- For what is not built yet: [Backlog](../backlog.md)
- For what runs but is not right yet: [Improvements](../improvements.md)
