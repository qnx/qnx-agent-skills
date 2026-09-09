# QNX Agent Skills

A drop-in workspace that turns any skills-capable coding agent into a QNX 8.0
development companion. Clone it, point your agent at it, and it configures
itself with a QNX knowledge base: platform facts, Alpine aports porting,
packaging, patch creation, and port reporting.

Built on the [Agent Skills](https://agentskills.io) open standard, so the same
skill set works across Claude Code, Codex, and other compatible clients. There
is one copy of the skills on disk; the per-client directories are symlinks.

## Quick start

```bash
git clone https://github.com/qnx-ports/qnx-agent-skills.git
cd qnx-agent-skills
```

Then start your agent in this directory and tell it to read `AGENTS.md`. Claude
Code picks it up automatically via `CLAUDE.md`; Codex reads `AGENTS.md`
natively.

Before doing real work, fill in `TARGET.md` with how to reach your QNX target
(connection, authentication, and the aports tree path). The agent will ask if
you leave placeholders in it.

**New here?** Three prompts take you from a fresh clone to a completed, validated
port, and they are deliberately short:

1. Can you see the skills? List them.
2. Connect to my target and show me the aports tree.
3. Port `<package>` and write the report.

That is the whole script — the skills carry the detail, so the prompts do not
have to. The codelab walks through them with the setup around them. Keep your
own copy in a local `PROMPTS.md` if you like; it is gitignored on purpose, so
your working prompts stay yours and do not sprawl into a spec.

> If your client's permission handling blocks the on-target password workflow,
> switch to manual approval mode and grant passwordless `apk` on the target.
> `TARGET.md` documents the non-interactive `sshpass` and `SUDO_APK` patterns.

If your client only reads a global skills directory, run `./setup.sh` once:

```bash
./setup.sh claude    # links ~/.claude/skills
./setup.sh codex     # links ~/.codex/skills
./setup.sh agents    # links ~/.agents/skills (default)
```

## Layout

```
AGENTS.md      canonical agent instructions: setup, rules, skill map
CLAUDE.md      pointer to AGENTS.md, so Claude Code finds it automatically
TARGET.md      your QNX target: connection, auth, tree path (you fill this in)
skills/        the skill set, one directory per skill
projects/      per-port notes and reports land here
run.sh         optional QEMU launcher, if you bring your own QNX image
setup.sh       links skills/ into a global agent directory
settings.template.json   optional Claude Code permission rules, to prompt less
```

`PROMPTS.md`, `SOLUTIONS.md` and `RUNBOOK.md` are deliberately not tracked (see
`.gitignore`), so your prompts, worked answers and operator notes stay yours.

`.claude/skills`, `.codex/skills`, and `.agents/skills` are symlinks to
`skills/`. Nothing is duplicated, so a fix to a skill is a single edit.

## The skills

| Skill | Covers |
| :--- | :--- |
| `qnx-porting` | Router. Read first: universal rules and task routing. |
| `qnx-platform-facts` | QNX platform truths: libc gaps, stack size, macros, toolchain quirks. |
| `alpine-qnx-porting` | Adapting an Alpine APKBUILD for QNX, per build system. |
| `qnx-apk-packaging` | End-to-end port workflow and the validation gate. |
| `aports-patch-creation` | Making and verifying patches the QNX way. |
| `qnx-port-reporting` | The after-action `REPORT.md` written for each port. |
| `skill-authoring` | How to add or extend a skill without degrading the set. |

## How it improves

The skills are not a fixed manual. One of the universal rules tells the agent to
record what it proves: a platform gotcha goes to `qnx-platform-facts`, a build
technique to `qnx-apk-packaging`, a target quirk to `TARGET.md`. Each port that
surfaces something new leaves the set better for the next one.

If you extend the skills, `skill-authoring` covers the conventions. Pull requests
welcome.

## Working model

Builds are native. Packages are built on the QNX target with Alpine's `abuild`,
compiled by the target's own toolchain, not cross-compiled from the host. The
agent connects over SSH, edits and builds on the target, and stops short of
writing history: it uses git to inspect the tree and to generate patches, but a
human makes the commits and pushes.
