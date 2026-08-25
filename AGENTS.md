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

The manual lives in `docs/manual/`, numbered in the order you would follow it.
Add new chapters to `docs/manual/index.md`. Reference facts about the system,
like names and network ranges, belong in `README.md`, not in the manual.

## Code

- **Every value is defined exactly once**, in `ansible/group_vars/all.yaml` if
  more than one role reads it, otherwise in that role's `defaults/main.yaml`.
  Never repeat a literal in a task or a template.
- **Never write the server's public IP anywhere.** It lives in the Cloudflare
  DNS records. Ansible reaches the server by name; templates use the
  `ansible_facts.default_ipv4` facts.
- **Check `README.md` before allocating a network range**, and add the new range
  to the table there.
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

There are none in this repo, and it should stay that way. The pre-auth key that
joins the server to the mesh is created and used within a single run, and is
never written to disk.

Adding the first stored credential is a decision, not a detail. Raise it before
writing it.

## Before you finish

```bash
task ansible:lint
task ansible:check
```

`ansible:lint` must pass with no failures. `ansible:check` must show only the
changes you intended. A second `task ansible:site` must report nothing changed.
