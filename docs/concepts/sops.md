# Secrets with SOPS

This homelab keeps its secrets in the repository, encrypted. This document
explains what that means, why it is safe, and how to work with it day to day.

## The problem

A homelab needs a handful of credentials: a Proxmox API token, storage keys, a
password or two. They have to be somewhere. The usual options are all bad:

| Where | Why it fails |
| --- | --- |
| In the repository, in plain text | Anyone who reads the repository has them |
| In a file the repository ignores | Invisible, easy to lose, on one machine only |
| In your head | You will forget, and a rebuild needs them |
| In a separate password manager only | Nothing links them to the code that uses them |

SOPS solves this by encrypting the values, so the file itself can be committed.

## What SOPS is

SOPS is a program that encrypts a structured file, such as YAML, **value by
value**. The keys stay readable and only the values are scrambled.

A file like this:

```yaml
PROXMOX_VE_API_TOKEN: opentofu@pve!tofu=1234abcd
AWS_ACCESS_KEY_ID: 5f4dcc3b5aa765d6
```

becomes this:

```yaml
PROXMOX_VE_API_TOKEN: ENC[AES256_GCM,data:Xy9k...,tag:aB3...]
AWS_ACCESS_KEY_ID: ENC[AES256_GCM,data:Qp2m...,tag:zK8...]
sops:
    age:
        - recipient: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
          enc: |
            -----BEGIN AGE ENCRYPTED FILE-----
            ...
```

Two things follow from encrypting values rather than the whole file:

- **You can read the file** and see which secrets exist without decrypting it.
- **`git diff` is useful.** Changing one secret changes one line, not the entire
  file, so the history shows what actually changed.

## What age is

SOPS does not invent its own encryption. It hands that job to something else,
and here that something is **age**: a small, modern file-encryption tool with
one key pair and no options to get wrong.

| Half | Where it lives | What it does |
| --- | --- | --- |
| Public key (`age1...`) | `.sops.yaml`, committed | Encrypts. Safe to share |
| Private key | `~/.config/sops/age/keys.txt`, **never committed** | Decrypts |

The private key is the one secret that cannot be stored in this repository,
because it is what opens the repository's secrets. It lives on your machine and
in a backup somewhere else, and nowhere else.

## Why not the SSH key

age can derive a key from an ed25519 SSH key, and it is tempting to reuse the
one you already have. This project does not, for one reason:

**An authentication key and an encryption key have different lifecycles.**
Rotating SSH access is normal and healthy, and should be something you can do
on a whim. If your SSH key also decrypts every secret, rotating it means
re-encrypting everything first, and forgetting that step locks you out of your
own homelab.

A separate age key costs one command to create and removes the coupling.

## How this project uses it

### One file, at the root

`secrets.enc.yaml` sits at the top of the repository. Both Ansible and OpenTofu
read from it, so it belongs to neither and sits above both.

There is no separate example file, and there does not need to be. Because SOPS
encrypts values and not keys, `secrets.enc.yaml` is its own documentation: open
it in any editor, encrypted, and the list of key names is right there.

### `.sops.yaml` decides what gets encrypted

```yaml
creation_rules:
  - path_regex: secrets\.enc\.yaml$
    age: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

This says: any file whose name ends in `secrets.enc.yaml` is encrypted to that
recipient. You never run an encrypt command yourself. `sops` reads this rule and
encrypts on save.

`task secrets:init` writes this file from your key, so the recipient is never
typed by hand and there is no placeholder left behind to trip over later.

### Secrets reach commands as environment variables

Nothing decrypts the file to disk. Every task in the `Taskfile.yaml` that needs
a credential wraps its command like this:

```bash
sops exec-env secrets.enc.yaml "tofu apply"
```

`sops exec-env` decrypts in memory, puts each key in the environment of that one
command, and the values disappear when it exits. There is no plaintext file to
forget about, and no window where one exists.

This is also why the keys are named the way they are. `PROXMOX_VE_API_TOKEN` and
`AWS_ACCESS_KEY_ID` are the names the tools already look for, so nothing has to
be wired up by hand.

### What is in the file

| Key | Used by |
| --- | --- |
| `PROXMOX_ROOT_PASSWORD` | The Proxmox web login. A record; nothing reads it automatically |
| `PROXMOX_VE_API_TOKEN` | OpenTofu, to create guests |
| `AWS_ACCESS_KEY_ID` | The state backend, against Cloudflare R2 |
| `AWS_SECRET_ACCESS_KEY` | The state backend, against Cloudflare R2 |

### Secrets the cluster needs

`secrets.enc.yaml` is read by commands you run: OpenTofu, Ansible, `kubectl`.
Nothing inside Kubernetes can read it, because `sops exec-env` puts a value in
one process's environment and nowhere else.

So secrets the cluster needs live somewhere else: `gitops/secrets/`, as
`SopsSecret` resources. Those are committed encrypted, and
**sops-secrets-operator** decrypts them in the cluster and writes a plain
`Secret` from each. Adding one is a file, not a procedure.

```
gitops/secrets/*.sops.yaml  --(committed, encrypted)-->  ArgoCD
                                                           |
                                              sops-secrets-operator
                                                           |
                                                    Secret, in the cluster
```

Two details make this work:

| Detail | Why |
| --- | --- |
| `encrypted_suffix: Templates` | SOPS encrypts values, not keys. Left at its default it would encrypt the value of `kind:` too, and Kubernetes could not tell what the resource was. This limits encryption to `secretTemplates`. |
| The key is not in git | It is the one thing that cannot be, so `task cluster:sops-key` puts it in the cluster. Everything else comes back from a `git clone`. |

### The cluster holds your key

`task cluster:sops-key` mounts `~/.config/sops/age/keys.txt` — the same key that
decrypts `secrets.enc.yaml`. Anything able to read a `Secret` in the `sops`
namespace, exec into the operator pod, or read etcd can therefore decrypt every
credential in this repo, including `PROXMOX_ROOT_PASSWORD` and the R2
credentials that hold the cluster's state.

That is a chosen trade: one key to hold, back up and remember, against a larger
blast radius if the cluster is compromised.

The alternative is a second age key, generated for the cluster and listed as a
recipient only on the `gitops/**/*.sops.yaml` rule. `secrets.enc.yaml` would
keep only the personal recipient, so the cluster could not decrypt it at all,
and the cluster key could be rotated on its own. It costs a second file to back
up. If the trade ever stops being worth it, that is the change to make.

### Some secrets are still never stored

Encryption is not a reason to keep everything. Two are deliberately absent:

- **The mesh pre-auth key** is created and used inside a single Ansible run, and
  expires in ten minutes. Nothing durable exists to protect.
- **The Proxmox API token** is minted by hand. Proxmox shows the secret once,
  which means the step cannot be repeated, which means it cannot be idempotent,
  which means Ansible should not own it.

## Using it

Install it once:

```bash
brew install sops age
```

Then set everything up, once, ever:

```bash
task secrets:init
```

That creates the key at `~/.config/sops/age/keys.txt`, writes `.sops.yaml` naming
its public half, and creates an encrypted, empty `secrets.enc.yaml`. It will not
overwrite any of them if they already exist.

**Back up `~/.config/sops/age/keys.txt` outside this repository**, in a password
manager. Everything below depends on it.

### Where the key lives

SOPS looks for the age key in a different place on each platform, and on macOS
that is `~/Library/Application Support/sops/age/keys.txt` rather than the
`~/.config` path you would expect. Rather than keep the key somewhere awkward,
the `Taskfile.yaml` sets `SOPS_AGE_KEY_FILE` for every task, naming the file
outright.

This is why `task secrets:show` works and a bare `sops -d secrets.enc.yaml` may
not. If you want to run `sops` by hand, export it yourself:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
```

Then, day to day:

| Command | What it does |
| --- | --- |
| `task secrets:init` | Sets up the key, `.sops.yaml` and the file. Safe to re-run |
| `task secrets:check` | Fails if the file is plaintext. Run before committing |
| `task secrets:edit` | Opens the file decrypted in your editor, re-encrypts on save |
| `task secrets:show` | Prints the decrypted values, to check your key works |
| `sops updatekeys secrets.enc.yaml` | Re-encrypts after you change `.sops.yaml` |

A working setup looks like this:

```bash
$ task secrets:show
PROXMOX_ROOT_PASSWORD: hunter2
PROXMOX_VE_API_TOKEN: opentofu@pve!tofu=1234abcd-...
```

## When it goes wrong

**`unknown recipient type`**. `.sops.yaml` does not hold a real key. Run
`task secrets:init`, which writes it from your key rather than leaving you to
paste one in.

**`no matching creation rules found`** when saving a new file. The file name does
not match the `path_regex` in `.sops.yaml`. The name must end in
`secrets.enc.yaml`.

**`no key could be found`** or `failed to decrypt`. SOPS cannot find your private
key, or the file was encrypted to a different one. If you ran `sops` directly
rather than through `task`, this is almost always the platform path problem
above. Otherwise, check the key exists:

```bash
ls ~/.config/sops/age/keys.txt
```

Then check the recipient in `.sops.yaml` matches your public key:

```bash
age-keygen -y ~/.config/sops/age/keys.txt
```

The two must be identical. If you changed `.sops.yaml` after the file was
encrypted, run `sops updatekeys secrets.enc.yaml` with the **old** key still
present.

**The file is plaintext.** `secrets.enc.yaml` is deliberately *not* gitignored,
because encrypted is exactly what should be committed. The cost is that a
plaintext one would be committed just as happily. `task secrets:check` catches
this, and `sops -e -i secrets.enc.yaml` fixes it.

**You committed a secret in plain text.** Rotate it. Removing the commit does not
help; assume anything that reached the history is public. Change the credential
at its source, then record the new one properly.

**You lost the age key.** Nothing in `secrets.enc.yaml` is recoverable. Every
secret has to be created again at its source: a new Proxmox token, new R2 keys, a
new root password. The OpenTofu state itself survives, because it is not
encrypted with this key; you would create a new R2 token and carry on. This is
still why the backup matters more than anything else in this document.

## What SOPS does not cover

OpenTofu state is stored in Cloudflare R2 **unencrypted by OpenTofu**, and it
contains the cluster's certificate authorities. That is a deliberate choice, not
an oversight.

OpenTofu cannot use an age key, so encrypting state would mean inventing a
second passphrase and keeping it in `secrets.enc.yaml`, next to the R2
credentials. Anyone who got the age key would get both at once, so it would not
narrow the compromise people actually worry about: a stolen laptop. It would only
help if the R2 credentials leaked on their own, or the bucket were made public.

The bucket is the control instead:

| Control | Why |
| --- | --- |
| The bucket is private | Nothing reaches it without the token |
| Its token is scoped to that one bucket | A leak does not reach the rest of the account |
| Versioning is on | A bad write can be rolled back |
| R2 encrypts at rest | Cloudflare holds those keys, so this guards the disks, not Cloudflare |

If you ever decide that last row is not good enough, OpenTofu's native state
encryption is the answer, and it does mean accepting a second key to protect.

## Where this is used

- [Configure the server](../manual/provisioning/2-configure-server.md) records the Proxmox
  root password.
- [Provision the cluster](../manual/provisioning/3-provision-cluster.md) sets the file up and
  fills in the rest.
- [Cheatsheet](../cheatsheet.md) lists the commands on their own.
