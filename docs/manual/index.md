# Operator Manual

Everything you need to know to operate the homelab properly.

The manual is split by when you need it. [Provisioning](#provisioning) is what
you do once, in order, to get from a bare server to a running cluster.
[Maintenance](#maintenance) is what you do afterwards, for as long as the
cluster exists.

## Provisioning

Follow these in order. Each one assumes the ones above it are done.

1. [Bootstraping](./provisioning/1-bootstrap.md): how to get the homelab up and running
2. [Configuring](./provisioning/2-configure-server.md): how to install and configure everything on the server
3. [Provisioning](./provisioning/3-provision-cluster.md): how to build the Kubernetes cluster on the server

## Maintenance

Standalone procedures. Read the one you need.

- [Upgrading Cilium](./maintenance/upgrading-cilium.md): the CNI, which is also
  the thing every pod depends on to have a network at all

## Elsewhere

- When something breaks: [Applying step by step](../troubleshooting/step-by-step.md)
- For how a piece works rather than how to run it: [Concepts](../concepts/)
- For the commands you reach for most: [Cheatsheet](../cheatsheet.md)
