# Connecting Crossplane to GitHub

Crossplane's GitHub provider manages GitHub as Kubernetes resources. It signs
in as a **GitHub App**: an identity owned by your account, with only the
permissions you give it, and short-lived tokens instead of a password.

The provider is installed by `gitops/system/base/crossplane/providers/`. It
does nothing until the App exists and its credentials are in
`github-app.sops.yaml`, which this procedure does.

## What the App can and cannot do

The App is installed on the personal account `GilbertoCunha`.

| Can | Cannot |
| --- | --- |
| Manage repositories it is installed on: settings, branches, branch protection, rulesets, files, Actions secrets and variables, environments, webhooks, deploy keys | Create a repository. GitHub only lets an App create repositories in an organization, never in a personal account |
| | Manage teams or organization secrets. A personal account has none |

To create repositories, the owner has to become an organization, or the
provider a personal access token.

## 1. Create the App

1. Open <https://github.com/settings/apps/new>.
2. Fill in:

   | Field | Value |
   | --- | --- |
   | GitHub App name | `grncunha-crossplane`, or anything unique on GitHub |
   | Homepage URL | `https://github.com/GilbertoCunha/homelab` |
   | Webhook → Active | Unchecked. Crossplane polls; it receives nothing |
   | Where can this GitHub App be installed? | Only on this account |

3. Under **Repository permissions**, give only what you will manage. Every
   other permission stays at **No access**.

   | Permission | Access | Needed for |
   | --- | --- | --- |
   | Metadata | Read-only | Always; GitHub sets it |
   | Administration | Read and write | Repository settings, branch protection, rulesets, deploy keys |
   | Contents | Read and write | Branches and files |
   | Secrets | Read and write | Actions secrets |
   | Variables | Read and write | Actions variables |
   | Environments | Read and write | Environments and their secrets |
   | Webhooks | Read and write | Repository webhooks |

4. Click **Create GitHub App**.

The App's page opens. Note its **App ID**, a number near the top.

## 2. Make a private key

On the App's page, under **Private keys**, click **Generate a private key**.

Expected: a file such as `grncunha-crossplane.2026-11-11.private-key.pem` is
downloaded. GitHub keeps no copy.

## 3. Install the App

1. On the App's page, click **Install App**, then **Install** next to
   `GilbertoCunha`.
2. Choose **All repositories**, or **Only select repositories** to limit what
   Crossplane can touch.
3. Click **Install**.

The browser lands on `https://github.com/settings/installations/<number>`. That
number is the **installation ID**.

## 4. Store the credentials

The provider reads one JSON document: the owner, the App ID, the installation
ID and the key, with the key's line breaks written as `\n`. `jq` builds it, and
`sops set` writes it straight into the encrypted file, so it never sits on disk
in plain text:

```bash
APP_ID=123456
INSTALLATION_ID=7890123
PEM=~/Downloads/grncunha-crossplane.2026-11-11.private-key.pem

sops set gitops/system/base/crossplane/providers/github-app.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["credentials"]' \
  "$(jq -n --arg id "$APP_ID" --arg inst "$INSTALLATION_ID" --rawfile pem "$PEM" \
    '{owner: "GilbertoCunha", app_auth: [{id: $id, installation_id: $inst, pem_file: $pem}]} | tojson')"
```

Check the result:

```bash
sops -d --extract '["spec"]["secretTemplates"][0]["stringData"]["credentials"]' \
  gitops/system/base/crossplane/providers/github-app.sops.yaml \
  | jq '.app_auth[0] | {id, installation_id}'
```

Expected: your two IDs, not `APP_ID` and `INSTALLATION_ID`.

Then delete the downloaded `.pem`. The encrypted file is now its only copy;
losing both means generating a new key in step 2.

Commit, open a pull request, and merge it.

## 5. Check it works

After ArgoCD syncs:

```bash
kubectl get providers.pkg.crossplane.io provider-upjet-github
```

Expected: `INSTALLED True` and `HEALTHY True`.

```bash
kubectl -n crossplane-system get secret github-app
```

Expected: one line, `github-app   Opaque   1`.

Then observe a repository that already exists. `Observe` only reads, so nothing
on GitHub changes:

```bash
kubectl apply -f - <<'EOF'
apiVersion: repo.github.m.upbound.io/v1alpha1
kind: Repository
metadata:
  name: homelab
  namespace: default
  annotations:
    crossplane.io/external-name: homelab
spec:
  managementPolicies: ["Observe"]
  forProvider: {}
EOF
kubectl -n default get repository.repo.github.m.upbound.io homelab
```

Expected: `SYNCED True` and `READY True`. `SYNCED False` with a 401 or 404 in
`kubectl describe` means a wrong ID, a wrong key, or an installation that does
not include the repository.

Clean up:

```bash
kubectl -n default delete repository.repo.github.m.upbound.io homelab
```

Deleting an observed resource leaves the repository alone.

## Rotating the key

Generate a new key (step 2), store it (step 4), merge, then delete the old key
on the App's page once the provider is healthy on the new one.
