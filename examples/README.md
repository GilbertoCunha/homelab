# Examples

Throwaway manifests, applied by hand to prove a path works, then deleted.

**ArgoCD does not sync this directory**, so applying one is not a deployment.
Nothing here is a template to copy into `gitops/`; for that see
[Exposing a service](../docs/manual/maintenance/exposing-a-service.md).

| Example | Proves | Steps |
| --- | --- | --- |
| `web-public/` | The tunnel reaches the cluster, and the record is proxied | [Opening the tunnel](../docs/manual/provisioning/5-open-the-tunnel.md), step 5 |
