# Working on this repo

Notes for anyone, human or agent, making changes here.

## Documentation

Docs are read by people, usually while something is broken. Write for a tired
reader.

- **One document, one purpose.** Before adding a file, check whether an existing
  one already owns the topic. Extend that instead.
- **Say it once.** If two documents need the same fact, one owns it and the
  other links to it.
- **Short sentences, one idea each.** Plain words over jargon.
- **Define a term at first use, then never again.**
- **Prefer a table or a numbered list to a paragraph.**
- **Every command shows what a correct result looks like.** A command with no
  expected output leaves the reader guessing.
- **Cut anything that loses no information by being removed.** No filler, no
  restating the heading, no "as mentioned above".

Documentation is split by the question it answers:

| Where | Answers | Example |
| --- | --- | --- |
| `docs/manual/provisioning/` | "How do I get this running?", in order | Provisioning the cluster |
| `docs/manual/maintenance/` | "How do I change this, now that it runs?" | Upgrading Cilium |
| `docs/concepts/` | "How does this work, and why?" | Secrets with SOPS |
| `docs/troubleshooting/` | "It is broken, now what?" | Applying step by step |
| `docs/cheatsheet.md` | "What was that command?" | — |
| `docs/architecture/` | "What is the system, and why this shape?" | Names, network ranges |
| `docs/backlog.md` | "What is not built yet?" | Public access |
| `README.md` | "Where do I click?" | Links to Proxmox, ArgoCD |

`README.md` is a front door, not a document: links to the things you actually
open, and pointers to everything else. Facts about the system live in
`docs/architecture/`, so the README does not drift.

The manual is split by when you need it. **Provisioning is numbered** and read in
order, once. **Maintenance is not numbered**: each document is a standalone
procedure for a system that is already running. Both are listed in
`docs/manual/index.md`, and a new document goes in whichever answers its
question, not wherever it was written.

When a manual step needs a paragraph of background, that paragraph belongs in
`docs/concepts/` and the step links to it. A maintenance procedure that needs to
explain why the thing works the way it does is the same rule: the procedure
stays a procedure, and the explanation gets a concepts document.

## Code

- **Every value is defined exactly once**, in `ansible/group_vars/all.yaml` if
  more than one role reads it, otherwise in that role's `defaults/main.yaml`.
  Never repeat a literal in a task or a template. In OpenTofu the same rule
  points at `opentofu/project/locals.tf` for anything describing a node, and
  `terraform.tfvars` for anything describing the environment.
- **Role defaults carry the role's name as a prefix**, so a value read only by
  the `proxmox` role is `proxmox_*`. `ansible-lint` enforces this. Values in
  `group_vars` are shared and use the name of the thing they describe.
- **Never write the server's public IP anywhere.** It lives in the Cloudflare
  DNS records. Ansible reaches the server by name; templates use the
  `ansible_facts.default_ipv4` facts.
- **Check [`docs/architecture/networks.md`](docs/architecture/networks.md)
  before allocating a network range or a guest address**, and add what you
  allocate to the table there.
- **Every role has the same shape**: `defaults/`, `tasks/`, `handlers/`,
  `templates/`. Keep `tasks/main.yaml` to about a screenful. When a role has
  real phases, `main.yaml` becomes a list of `import_tasks` and each phase gets
  its own file.
- **Task names are plain statements of what the task does.**
- **Use modules, not `command` or `shell`.** Where a command is unavoidable,
  give it an idempotency guard. A task that reports changed on every run is a
  bug.
- **Tags go on roles in `site.yaml`**, not on individual tasks.
- **Templates say they are managed by Ansible** and name the role that owns
  them.

## Secrets

Secrets live in `secrets.enc.yaml`, encrypted with SOPS, and that file is
committed. How and why is in
[Secrets with SOPS](docs/concepts/sops.md); the rules below are what you must
follow when changing this repo.

**Nothing in this repo may hold a secret in plaintext**, including `.tfvars`
files, role defaults, and anything a `.gitignore` entry is the only thing
protecting.

- **Two homes, split by who reads it.** `secrets.enc.yaml` at the root is for
  commands you run; Ansible and OpenTofu both read it, so it belongs to neither
  tree. `gitops/**/*.sops.yaml` is for secrets the cluster reads, decrypted in
  place by sops-secrets-operator. A value belongs in exactly one of them.
- **Secrets reach a command as environment variables**, through
  `sops exec-env`. Never decrypt to a file.
- **The age key that decrypts it is not in the repo** and never will be. It is
  the one secret that cannot be stored here.
- **The encrypted file documents itself.** SOPS encrypts values, not keys, so the
  key names are readable without decrypting. There is no example file to keep in
  sync, and adding one would be a second place to forget.
- **`task secrets:init` owns the bootstrap**, including the list of key names. A
  new key goes there and in the file, nowhere else.

Some secrets still never get stored, because they do not need to be. The pre-auth
key joining the server to the mesh is created and used within a single run. The
Proxmox API token is minted by hand, because Proxmox shows it once and a task
that cannot be repeated cannot be idempotent.

OpenTofu state holds the cluster's certificate authorities. It is not encrypted
by OpenTofu; the R2 bucket being private is what protects it, and
[Secrets with SOPS](docs/concepts/sops.md) explains why that trade was made.
Nothing writes state to this repo.

## OpenTofu

- **`opentofu/project` is the root module**, and the only place you run `tofu`.
  `opentofu/modules` holds anything reused.
- **A node is described in `locals.tf` and nowhere else.** Adding a worker is one
  line there.
- **Providers are pinned** to a minor version in `versions.tf`.
- **Never run `tofu` directly.** The Taskfile wraps every command in
  `sops exec-env`, which is what supplies the credentials.

## GitOps

- **`gitops/` is everything inside the cluster**, and ArgoCD is the only thing
  that applies it. OpenTofu stops at the cluster's edge. How the tree is laid
  out and why is in [GitOps with ArgoCD](docs/concepts/gitops.md).
- **Every tree has `base/` and `overlays/<environment>/`.** `base` says what a
  component is; the overlay says where this cluster reads it from. A value that
  differs per environment belongs in the overlay and nowhere else.
- **Ordering is a sync wave, not a file order.** Anything that must exist before
  something else gets its own `argocd.argoproj.io/sync-wave`, with a comment
  saying what it is waiting for.
- **A chart's own resource beats a hand-written copy.** If a chart templates the
  `HTTPRoute` you need, enable it in `values.yaml` rather than writing a second
  one; the hostname is then written once.

## Before you finish

```bash
task ansible:lint
task cluster:render
task tofu:fmt
task tofu:validate
task secrets:check
```

`ansible:lint` must pass with no failures. A second `task ansible:site` must
report nothing changed: that, not a dry run, is what proves a role is
idempotent.
`cluster:render` must render both overlays; it needs no cluster, so there is no
excuse for skipping it. `tofu:validate` must pass with no warnings; a
deprecation warning means the provider has renamed something and the code should
follow. `secrets:check` must
say the file is encrypted: it is deliberately not gitignored, so a plaintext one
would be committed.
