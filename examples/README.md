# Examples

Throwaway manifests to prove a path works, then deleted.

Nothing here is a template to copy into `gitops/`; for that see
[Exposing a service](../docs/manual/maintenance/exposing-a-service.md).

| Example | Proves | Applied by | Steps |
| --- | --- | --- | --- |
| `web-public/` | The tunnel reaches the cluster, and the record is proxied | you, by hand | [Opening the tunnel](../docs/manual/provisioning/5-open-the-tunnel.md), step 5 |
| `project-web-public/` | A project's namespace, quota and policy hold a real workload | ArgoCD | [Adding a project](../docs/manual/maintenance/adding-a-project.md) |

**Read the third column before applying anything.** `web-public/` is applied
with `kubectl apply -k` and deleted the same way; ArgoCD has never heard of it.
`project-web-public/` is the opposite: it is the `sync` path of the project in
`gitops/applications/catalog/`, so ArgoCD owns it and will put back anything
you delete by hand. Remove it by removing that catalog file.

The two differ in one detail that matters more than it looks: `web-public/`
names its own namespace, and `project-web-public/` names none, because a
project decides where its workload lands and refuses a manifest that decides
for itself.
