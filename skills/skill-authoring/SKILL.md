---
name: skill-authoring
description: "Guide for adding a new skill to this repository or extending an existing one. Covers the required directory and file layout, the YAML frontmatter fields and their constraints, how to write a description that gets the skill selected at the right moment, house conventions for headers and naming, and the bar a fact must clear before it is written down. Read this whenever recording a new confirmed fact, splitting a skill that has grown too large, or creating a skill for a new area of QNX work."
---

# Skill authoring

Skills in this repository are how knowledge survives past a single session. This skill covers how to add to them without degrading the set. It is deliberately not QNX-specific; everything here applies to any skill in `skills/`.

## Layout

One skill is one directory containing a `SKILL.md`:

```
skills/
└── qnx-platform-facts/
    └── SKILL.md
```

The filename is always `SKILL.md`, in capitals. That is the discovery contract; agents look for that exact name. Skills are told apart by their directory name, not their filename, so never rename `SKILL.md` to something descriptive.

Supporting files may sit alongside `SKILL.md` in the same directory and be referenced from it. Keep references one level deep: `SKILL.md` may point at a file next to it, but avoid chains where that file points at another which points at another.

## Frontmatter

Every `SKILL.md` opens with YAML frontmatter:

```yaml
---
name: qnx-platform-facts
description: "..."
---
```

`name` must match the directory name exactly, be lowercase with hyphens, and must not contain the words `anthropic` or `claude` (those are reserved).

`description` is the field that decides whether the skill gets loaded, so it earns the most care. It is injected into the agent's context ahead of the skill body, and the agent uses it to decide relevance. Requirements:

- Cover both **what the skill contains and when to read it**. The "when" is what makes it fire at the right moment. Name the concrete triggers: the error text, the file type, the task phrase.
- Lead with the contents ("Covers...", "Guide for...", "Build-method-independent facts for..."). A direct reading instruction ("Read this when a port hits a platform-level wall") is fine and useful for the trigger half — several skills here use it. What matters is consistency across the set, not avoiding the imperative.
- Stay under 1024 characters. Aim for two or three sentences.

A weak description says what the skill is about. A strong one lists the situations that should send you to it.

## Body

Keep the body under 500 lines. If it grows past that, the skill is doing too much and should be split by task rather than padded down.

House conventions:

- H1 is the skill title. Every header below it is Sentence case, not Title Case.
- Use fenced code blocks with a language tag for anything runnable.
- Reference other skills by name in backticks (`` `qnx-apk-packaging` ``), not by file path. Skills are loaded by name; paths go stale.
- Prefer extending an existing section over adding a new one. A skill with fifteen one-line sections is harder to use than one with five coherent ones.

## The bar for writing something down

Only record what has been proven. A fact enters a skill when a command has demonstrated it, not when it seems likely. When you record it, include enough to make it actionable next time: the symptom as it actually appeared, the root cause, and the fix. A line that says "watch out for the toolchain" helps nobody; one that quotes the real error and names the flag that resolves it saves the next session an hour.

Mark uncertainty as uncertainty. If something worked but you do not know why, or you suspect an environment quirk rather than a real defect, say so in the skill. A confidently wrong fact is worse than an honest open question, because the next session will build on it.

**Any claim about the state of the environment ships with the command that re-checks it.** Facts of the form "X is empty", "Y is missing", "Z is broken" are the ones that rot: they were read off one image on one day, and the next session has no way to tell a durable truth from a stale observation unless you leave the check behind. A single line is enough:

```sh
sh -c '. /usr/share/abuild/functions.sh; echo "CBUILD=[$CBUILD]"'   # expect the target triple
```

Two things go wrong without it. The reader cannot cheaply obey the router's rule 1, so they take the claim on trust; and when the claim *is* wrong, there is no obvious way to prove it, so it survives another session. This is not hypothetical — `alpine-qnx-porting` carried "`$CHOST`/`$CBUILD` are empty in this image's abuild.conf" for several ports. It was literally true of the file and false of the shell `build()` runs in, and it propagated a hardcoded triple into a port before anyone ran the one-line check.

State the scope you actually proved, too. "On the x86_64 QEMU image on 2026-08-06" is honest and ages well; a bare "on QNX" claims every target and every release from a single data point.

## Where a fact belongs

Route by the kind of knowledge, not by which skill you happen to have open:

- A platform truth that holds regardless of build system goes in `qnx-platform-facts`.
- Something about adapting a recipe, or a build-system-specific wall, goes in `alpine-qnx-porting`.
- Workflow, validation, or packaging mechanics go in `qnx-apk-packaging`.
- Anything about making or verifying a patch goes in `aports-patch-creation`.
- Facts about one specific target or image go in `TARGET.md`, not in a skill. Skills are portable; targets are not.
- History about one package goes in that package's folder under `projects/apks/`, not in a shared skill.

## Adding a new skill

Create a new skill only when the material does not fit an existing one and is substantial enough to stand alone. Then:

1. Create `skills/<name>/SKILL.md` with frontmatter and body per the rules above.
2. Add it to the router (`qnx-porting`): both the task-routing section, so the agent knows when to reach for it, and the skill map.
3. Add it to the skill map in `AGENTS.md`.

A skill that exists but is not routed to will rarely load. The router entry is not optional bookkeeping; it is how the skill gets used.
