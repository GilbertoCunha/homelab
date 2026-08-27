# Examples

Throwaway manifests, applied by hand to prove a path works, then deleted.

**ArgoCD does not sync this directory.** Everything it manages lives under
`gitops/`, and nothing here is referenced from there. That is the point: an
example can be applied, broken, and removed without a commit being a
deployment.

Nothing here is a template to copy into `gitops/`. For that, follow
[Exposing a service](../docs/manual/maintenance/exposing-a-service.md).

| Example | Proves |
| --- | --- |
| `web-public/` | The Cloudflare tunnel reaches the cluster, and the record it gets is proxied |

`web-public` is the end-to-end check for
[Opening the tunnel](../docs/manual/provisioning/5-open-the-tunnel.md), which
has the steps and what each one should print.
