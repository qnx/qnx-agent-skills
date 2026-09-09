---
name: aports-patch-creation
description: "Patch creation for QNX ports of Alpine APKBUILD packages: writing the change itself, then making, formatting, naming, and validating .patch files against the QNX-unpacked tree. Read before editing any source for a port and before producing any patch content, and when diagnosing a patch-apply failure (Hunk FAILED, .rej, fuzz rejected by BusyBox patch). Covers how the hunk should look - positive __QNX__ conditionals placed inside the source's existing platform branches - as well as patch mechanics. Core rule: never create a patch from an untested change; confirm the fix in the unpacked source first. Applies whenever debugging a build error or editing patches for an APKBUILD."
---

# Alpine Linux APKBUILD Patch Creation Skill

## Purpose
This skill provides the definitive workflow for creating patches for Alpine Linux APKBUILD packages. It emphasizes verification before patch creation and follows Alpine's patch format standards.

## Critical principles

1. **NEVER create patches speculatively** - Always test changes work first
2. **NEVER use `abuild -r` during development** - It wipes your working directory
3. **ALWAYS verify patch format** matches Alpine standards before using
4. **Follow the exact workflow** - Don't skip steps or improvise

## What the change should look like

Decide this before Phase 1, not at review. The rest of this skill covers patch *mechanics*
— testing, generating, formatting. This section covers the *content* of the hunk, which is
settled while you are editing the source and is expensive to revisit once the patch is
generated, checksummed and validated.

**Match the source file's existing platform structure.** If the file already branches on
platform, put the QNX change inside that structure using a positive `__QNX__` test:

```c
#ifdef HAVE_SOME_OTHER_PLATFORM
# include <that-platform.h>
#else
# include <the-portable-headers.h>
# ifdef __QNX__
#  include <the-header-qnx-also-needs.h>
# endif
#endif
```

The shape is what matters: find the branch that already covers your platform's case, and
add a positive `__QNX__` test *inside* it.

Do not introduce a second, parallel guard mechanism alongside the branching the file
already has. A feature-test macro the project's configure already defines (for example an
`HAVE_<HEADER>_H`) is perfectly good engineering and is the right choice when the file has
**no** platform branching — but where platform branches exist, adding a feature-test block
elsewhere in the include list splits one decision across two mechanisms and reads to a
reviewer as a different change from the one the rest of the file makes.

This form is easy to get wrong in a way nothing catches: a parallel-guard patch compiles,
links, passes the tests and passes the whole validation gate. It is simply not the house
form, and by the time the review-reduction pass in `qnx-apk-packaging` step 9 looks at it,
the patch is already written, checksummed and validated, so fixing the form costs a full
re-run of the gate. Settle it here, before Phase 1.

Prefer the smallest change that fits what the file already does. Keep the reasoning for the
form in the port's `REPORT.md`, not in a comment inside the hunk.

**Every line of the hunk must be independently proven, not just the hunk as a whole.**
Rule 2 says never patch an untested change, and it is easy to satisfy that in spirit while
missing it in practice: you add two things at once, the build goes green, and you have
proven the *pair* works — not that both were needed. The extra line then ships as
unexplained cargo that a reviewer cannot distinguish from the real fix.

Minimise before exporting the patch. Remove each element in turn and rebuild the single
affected object; keep only what actually fails without it:

```sh
# in the unpacked tree, after the combined fix is working
<edit out one line of your change>
make <the-one-object>.lo     # or: cc -c the-one-file.c
# still compiles? that line was not load-bearing - drop it
```

This bites hardest on include fixes, where headers often reach the translation unit through
more than one path, so an include can look obviously required and be entirely redundant.
Reading a header to see that it only forward-declares a type is **not** proof that a second
include is needed — the complete definition may arrive via another include already in the
file. Compile it both ways and believe the compiler.

The same reasoning applies to build flags (see `alpine-qnx-porting` on `-fPIC`): a flag or
a line that no observed failure requires is what the `qnx-apk-packaging` review-reduction
pass exists to strip, and it is far cheaper to strip it here, before the patch is generated
and checksummed.

## Two-phase workflow

### Phase 1: Development and testing (iterative)

This phase happens in the extracted source directory. Make changes, test with native build tools (cmake/make/ninja), verify they work. Repeat until satisfied.

**Setup:**
```bash
cd /path/to/aports/category/pkgname
abuild clean      # Remove old artifacts
abuild unpack     # Extract tarball ONLY - does not apply patches
abuild prepare    # Applies the patches in source=
```

**`abuild unpack` does not apply patches.** It only extracts the tarball. Patches are
applied by `prepare` (via `default_prepare`). The `Checking sha512sums... yourpatch.patch: OK`
line in the unpack output is checksum verification, not application, and is easy to
misread as proof the patch went in. If you skip `prepare`, you will iterate against
unpatched source and may never notice. Inherited Alpine patches are the usual casualty:
they are listed in `source=`, they checksum fine, and they silently never apply.

Verify application by inspecting the source, not the log:

```bash
grep -n "<a string your patch adds>" src/pkgname-version/path/to/file
find src -name '*.rej'          # must be empty
```

**Install the make-dependencies before iterating.** `abuild` removes its
`.makedepends-*` virtual package when a build finishes or fails, and Phase 1
deliberately does not use `abuild` — so nothing puts them back. A native `./configure`
or `cmake` in `src/` will then fail on a dependency that the abuild run had satisfied
moments earlier, which looks like a package problem and is not:

```
configure: error: <some dependency> was not found
```

Install them explicitly first (`sudo apk add <the makedepends>`), then iterate.

**abuild's build variables are not set in your shell either, for the same reason.** An
APKBUILD's `build()` runs with `$CBUILD`, `$CHOST`, `$CFLAGS` and friends already
populated by abuild; a plain SSH shell in `src/` has none of them. Copying the
APKBUILD's own configure line into that shell therefore does something different from
what the package does, and on QNX it fails in a way that looks like the bug you are
trying to fix:

```sh
./configure --build=$CBUILD --host=$CHOST ...
# with CBUILD empty this becomes --build= --host=, configure falls back to config.guess:
#   Invalid configuration `unknown-x86pc-nto-qnx8.0.0': machine `unknown-x86pc' not recognized
```

Source them before iterating, and the manual build matches the packaged one:

```sh
. /usr/share/abuild/functions.sh   # sets CBUILD/CHOST to x86_64-pc-nto-qnx8.0.0
./configure --build=$CBUILD --host=$CHOST --prefix=/usr
```

The general rule: when a Phase 1 reproduction fails where the abuild run succeeded,
suspect the difference between the two environments before suspecting your change.

**Iterative testing:**
```bash
cd src/pkgname-version/
# Make your changes to source files
# Test using native build system (NOT abuild):
#   - For CMake: rm -rf build && mkdir build && cd build && cmake .. && ninja
#   - For Make: make clean && make
#   - For Meson: meson setup build && ninja -C build
# Verify the change fixes the issue
# Repeat as needed
```

**DO NOT:**
- Run `abuild -r` (it deletes your changes)
- Create patches yet (changes aren't finalized)
- Modify APKBUILD (testing phase only)

### Phase 2: Patch creation (once changes work)

Only proceed here after Phase 1 changes are tested and working.

**Step 1: Prepare for patch creation**
```bash
cd /path/to/aports/category/pkgname
abuild clean
abuild -K unpack prepare    # Fresh extraction WITH existing patches applied
```

**Step 2: Snapshot the prepared tree with git**

Alpine's patches are produced by git, which is why they all carry `a/` and `b/` path
prefixes. Use git here too and the format comes out correct with no hand-editing.

```bash
cd src/pkgname-version/
git init -q
git add -A
git commit -qm "baseline"
```

This `.git` directory lives inside `src/`, which is build output and is never committed
to the aports tree (`abuild clean` deletes the whole thing). If the upstream tarball
already ships a `.git`, skip `git init` and just `git add -A && git commit` on top.

**Snapshot a freshly-unpacked tree, never one you have already built in.** Step 1's
`abuild clean && abuild -K unpack prepare` is what makes this work, and it is tempting to
skip it when the tree from Phase 1 is sitting right there with the proven fix already in
it. Do not: `git add -A` in a configured autotools tree also tracks the generated build
artifacts, and the next `make` rewrites them, so `git diff` emits the real one-line source
change buried in thousands of lines of `.deps/*.Plo` dependency-list churn and `.Tpo`
deletions. The patch is unusable and the mistake is invisible until you read the output.
Re-unpack, snapshot clean, then re-apply the change by hand. Verify before exporting:

```sh
git diff --stat        # must list only the source files you meant to change
```

Typical failure: snapshotting a built autotools tree yields a diff across half a dozen
files, all but one of them bookkeeping churn; re-running from a clean unpack gives the
intended single-file patch.

**This is not a repo git operation and no rule forbids it.** The universal rule is that
you never push and never write the commit history a human reviews. A throwaway repo
inside `src/`, which `abuild clean` deletes, is neither: it is the tool that produces a
correctly formatted patch. Do not fall back to plain `diff` to avoid touching git.

**Step 3: Apply your changes**
```bash
# Re-apply the changes you validated in Phase 1
vi path/to/file.ext
```

**Step 4: Generate the patch**
```bash
# From src/pkgname-version/ :
git diff > ../../NNNN-descriptive-name.patch
```

Where NNNN is the next sequential four-digit patch number (0001, 0002, etc.)

`git diff` emits exactly the Alpine format - `diff --git a/… b/…` followed by
`--- a/…` / `+++ b/…`. **There is no header to fix.** If you find yourself editing
`---`/`+++` lines by hand, you have used plain `diff` instead of git; go back and use git.

When the patch deserves a commit message or attribution (an upstream backport, a CVE
fix), commit the change and export it instead:

```bash
git commit -aqm "short summary line"
git format-patch -1 --stdout > ../../NNNN-descriptive-name.patch
```

That produces the `From <sha>` + subject form Alpine also uses. Pick one; do not mix
both forms in a single patch file.

**Step 5: Verify the format**

The patch must carry `a/` and `b/` path prefixes. Check for them rather than checking the
first line, because the first lines differ by method and neither is wrong:

```bash
grep -E '^(diff --git|--- |\+\+\+ )' NNNN-your-new-patch.patch
# git diff         → diff --git a/path b/path
#                    --- a/path/to/file.ext
#                    +++ b/path/to/file.ext
# git format-patch → same, below the From/Subject/Date header block
```

Every `---`/`+++` line that names a file must carry the prefix. (`git format-patch` also
emits a bare `---` separator before the diffstat — that one is expected and the pattern
above skips it.) If any file line shows a bare or `pkgname-version/`-prefixed path, you
did not use git; go back to Step 2.

**Do not copy the header style of neighbouring patches in this tree.** `a/` and `b/`
prefixes are the Alpine standard - a survey of 75 patches across 16 Alpine aports
packages found 73 using `a/`+`b/` (via `diff --git a/… b/…` or `--- a/…`) and only 2
using bare paths. The QNX tree, however, contains many older patches written with bare
paths (`--- pkgname-version/path/to/file`). Those are legacy and must not be used as the
model for new work. Match the standard above, not the neighbour.

**When the patch you are replacing is itself one of the legacy ones**, the standard still
wins, but flag it rather than letting a reviewer discover it. Regenerating a bare-path
patch through the git workflow rewrites every header line, so a small change to the
patched hunk arrives in review as a full-file rewrite of the `.patch`, and the reviewer
sees format churn instead of your change. Do not hand-edit headers back to the old style
to keep the diff small — that reintroduces exactly what the standard removes. Regenerate
normally, then state in `REPORT.md` that the patch was reformatted from bare paths to
`a/`/`b/`, so the reviewer knows which part of the diff is content and which is format.
Whether that package keeps the legacy format for internal consistency is the maintainer's
call to make with the facts in front of them, not a decision to take silently in either
direction.

**Step 6: Add patch to APKBUILD**

Edit APKBUILD and add your patch filename to the `source=` list:
```bash
source="https://example.com/pkgname-$pkgver.tar.xz
    0001-existing-patch.patch
    0002-another-patch.patch
    NNNN-your-new-patch.patch
    "
```

**Step 7: Update checksums**
```bash
abuild checksum
```

This updates the sha512sums in APKBUILD.

**Step 8: Test the complete build**
```bash
abuild -r
```

This builds from scratch with all patches applied. If it succeeds, your patch is correctly integrated.

## Patch commit message format

The patch file's own commit message (the text above the `---` separator) is one short summary line. No bullet-point lists in the patch header. Detail belongs as inline comments next to the changed code, not in the patch message.

## A matching checksum does not prove a patch applies

A matching sha512 proves the patch file is byte-identical to what is recorded, NOT that it still applies to the unpacked tree. QNX uses BusyBox `patch` with zero fuzz tolerance, so a patch that applies on Alpine (GNU patch tolerates fuzz) can be rejected on QNX. Always verify application with `abuild clean && abuild -K unpack prepare` and confirm there is no "Hunk FAILED" and no `.rej` file, rather than trusting the checksum.

## Common mistakes and solutions

### Mistake: Patch paths don't match
**Symptom:** `abuild unpack` fails with "can't find file to patch"

**Cause:** Patch header paths are wrong

**Solution:** 
- Verify header format matches `--- a/path` and `+++ b/path`
- Path must be relative to tarball root
- No `.orig` in filename
- No `./` prefix

### Mistake: Changes lost during build
**Symptom:** Build doesn't include your changes

**Cause:** Used `abuild -r` during development

**Solution:**
- Only use `abuild -r` for final verification
- During development, use native build tools in src/ directory

### Mistake: Patch applies but doesn't work
**Symptom:** Patch applies cleanly but issue persists

**Cause:** Didn't test changes before creating patch, or tested different changes

**Solution:**
- Delete patch, go back to Phase 1
- Test changes thoroughly before creating patch
- Create patch immediately after successful test

### Mistake: Multiple files need changes
**Solution:** Create one patch per logical change, not per file
- If files are related (single bug fix), use one patch
- If independent changes, use separate patches
- Use descriptive names: `0001-fix-qnx-audio.patch`, `0002-add-wayland-support.patch`

## Patch naming convention

Format: `NNNN-descriptive-kebab-case-name.patch`

- NNNN: Sequential number, four digits (0001, 0002, etc.) - this is what `git format-patch` emits and what Alpine uses
- descriptive: What the patch does
- kebab-case: lowercase with hyphens

**Good examples:**
- `0001-fix-qnx-processor-detection.patch`
- `0002-add-wayland-support.patch`
- `0003-disable-broken-feature.patch`

**Bad examples:**
- `fix.patch` (no number, not descriptive)
- `0001_Fix_QNX.patch` (underscores, wrong case)
- `qnx-processor.patch` (no number)

## Multi-file patches

No special handling needed - the git workflow covers it. Edit every file the change
touches, then `git diff` once. All files land in a single correctly-formatted patch:

```bash
cd src/pkgname-version/
vi path/to/file1.c
vi path/to/file2.h
git diff > ../../NNNN-description.patch
```

Group by logical change, not by file: one patch per reason, however many files that
takes. Independent fixes get separate patches (make a `git commit` between them and use
`git format-patch` if you want them split cleanly).

## Quick reference

**Workflow commands:**
```bash
# Setup (patches from source= get applied by prepare, not unpack)
cd /path/to/aports/category/pkgname
abuild clean && abuild -K unpack prepare
sudo apk add <the makedepends>          # abuild removed them; Phase 1 needs them

# Phase 1: test the change with the NATIVE build system, not abuild
cd src/pkgname-version/
vi file.ext
./configure && make                     # or cmake/ninja, or meson
# ... iterate until the fix is proven ...

# Phase 2: snapshot, re-apply, export
cd /path/to/aports/category/pkgname
abuild clean && abuild -K unpack prepare
cd src/pkgname-version/
git init -q && git add -A && git commit -qm baseline
vi file.ext                             # re-apply the proven change
git diff > ../../NNNN-name.patch        # correct a/ b/ format, no hand-editing

# Register and verify
cd ../..
# add NNNN-name.patch to source= in APKBUILD
abuild checksum
abuild clean && abuild -K unpack prepare   # no Hunk FAILED, no .rej
abuild -r -c -K
```

## When to ask before acting

Ask the user before:
1. Creating any patch - state the tested change and confirm it is the one to capture
2. Deviating from the `a/`+`b/` header format documented above (the format itself is
   settled and needs no confirmation)
3. Running `abuild -r` - it wipes `src/`, so confirm development is finished
4. Changing paths inside an existing patch

Never:
1. Assume the patch format instead of verifying it with Step 5
2. Use `abuild -r` during iterative development
3. Create a patch from a change that has not been proven to work
4. Guess at file paths in patch headers

## Verification checklist

Before considering patch complete:

- [ ] Changes tested in Phase 1 and working
- [ ] Every `---`/`+++` line carries an `a/`/`b/` prefix (Step 5), produced by git
- [ ] Patch filename follows NNNN-description.patch convention
- [ ] Patch added to APKBUILD source list
- [ ] `abuild checksum` ran successfully
- [ ] `abuild -r` completes without errors
- [ ] Patch actually applied (check build log or manually verify in src/)

## Integration with build system

After creating patch, verify it's being applied:

```bash
abuild clean
abuild -K unpack prepare
cd src/pkgname-version/
# Check that your changes are present in the source
grep "your change marker" path/to/file.ext
```

If changes aren't there, patch didn't apply - check format and paths.

