---
name: qnx-apk-packaging
description: "End-to-end workflow for turning a QNX 8.0 port into a reviewable, standalone APK package. Read when taking a package from working build to PR-ready: establishing the version baseline, cleaning up APKBUILD metadata, local repo resolution on the target, building and inspecting subpackages, running upstream tests, the review-reduction pass, and the commit/PR split. Complements alpine-qnx-porting (APKBUILD content mechanics) and aports-patch-creation (patch content and mechanics - apply its rules while authoring, not at the review pass here). Read qnx-porting first."
---

# QNX APK Packaging Workflow

The process for turning a port into a clean, standalone, reviewable QNX APK package. This is the "what is the end-to-end process" skill. For APKBUILD content mechanics (dependency renames, pkgrel, Vala) see `alpine-qnx-porting`; for patch creation see `aports-patch-creation`. This skill assumes the native aports build method (build on the QNX target with abuild).

Each package gets its own project notes under `projects/apks/<pkgname>/` and its own aport review, unless the change is only a consumer dependency update.

## The workflow

### 1. Identify package ownership
Check the authoritative aports tree under its `core/` and `extra/` directories (the exact tree path is target-specific and is recorded in TARGET.md). Check `apk search <pkgname>` and `apk info -W <file>` for installed ownership. Decide which case this is: existing-package cleanup, new Alpine-derived aport, QNX platform package, or host-only validation tooling. The case determines everything downstream.

### 2. Establish the source baseline
Prefer an existing Alpine aport when one exists. Start from the latest stable upstream/Alpine version whenever possible. Do not keep an older imported version just because it was the first that built. If the latest stable fails and the port must pin or downgrade, document the failing version, why the older one is required, and what must change to move forward again. Preserve upstream source URLs. Preserve inherited Alpine APKBUILD logic (existing `prepare()`, `sed`, generated files, package conventions) unless that exact logic causes the QNX problem. New QNX source edits go in patch files, not new sed (see aports-patch-creation and the alpine-qnx-porting source-modification rule).

**Where the source comes from.** The aports tree is a fork of `qnx-ports/aports` (remote `git@github.com:<your-github-username>/aports.git`), organized into `core` and `extra` (roughly Alpine `main` to `core`, and `community`/`testing` to `extra`). To start or update a port, take the package's Alpine aport as the reference (the upstream Alpine source is `https://gitlab.alpinelinux.org/alpine/aports`, under `main/<pkg>` or `community/<pkg>`) and place or update the package directory under the matching `core/` or `extra/` path in the QNX tree. The APKBUILD's `source=` line already points at the upstream release tarball (for example `source="$pkgname-$pkgver.tar.gz::https://github.com/.../$pkgver.tar.gz"`); `abuild` downloads it on first build and caches it under `/var/cache/distfiles`, so the actual upstream code is pulled by the build, not copied by hand. Verify the live tree layout and remotes on the target rather than assuming.

### 3. Clean up APKBUILD metadata
Verify `pkgdesc`, `url`, `arch`, `license`, `options`, `subpackages`, `depends`, `depends_dev`, `makedepends`, `checkdepends`.

**"Verify" means confirm they are right for QNX, not rewrite them to your own taste.** A
metadata field inherited from the Alpine aport changes only when QNX requires it or when it
is provably wrong — a dependency that is renamed here, a subpackage split that differs, an
`arch` restriction the port actually needs. Fields like `license`, `pkgdesc` and `url`
normally carry over untouched. Changing one on general principle (a more precise license
expression, a tidier description) produces an unexplained divergence from the reference
aport that a reviewer must stop and adjudicate, and it is not what this port is for. If you
believe such a field is genuinely wrong upstream, leave it, and raise it in the report as a
separate observation rather than folding it into the port. Confirm QNX runtime dependencies explicitly when APK metadata does not infer them reliably. For every APKBUILD deviation from the original Alpine aport, document it in the package notes, and add a short comment beside the changed line when it helps a reviewer. A deviation comment states: what changed, why QNX needs it, why this solution was chosen, and what warning/build failure/runtime issue/ownership problem it resolves. Prefer a nearby comment specifically for: CMake flags, dependency variables, architecture restrictions, disabled features, and package-split changes not present in Alpine, since those affect review and package semantics directly. Keep comments factual and tied to specific QNX/toolchain behavior.

**Comment content rules for QNX-specific changes.** A QNX-specific code comment states what the code does, why QNX needs different behavior, and the impact (if a feature is disabled or performance reduced, say so explicitly). Do not: write "under investigation" or future-tense omission comments ("add X back when Y is ready"); explain what is NOT in a list; put PR-reply justifications in code comments; or use threading jargon (`std::promise`, future exception state) where plain language works. Do not comment repo-wide conventions like LTO or `-Qunused-arguments` (see alpine-qnx-porting).

### 4. Validate source and checksums
Run `abuild checksum`. Confirm the tarball license and any patch checksums. Never commit generated `src/`, `pkg/`, or `tmp/` directories.

### 5. Configure local repo resolution on the target
Put local package output paths before remote repositories in `/etc/apk/repositories`, for example:

```text
/var/home/qnx/packages/core
/var/home/qnx/packages/extra
```

Use whichever local paths actually exist for the target image. Run `sudo apk update`. Confirm `apk search <pkgname>` and `apk policy <pkgname>` resolve the local package before relying on it as a dependency of the next package in a chain.

**How the local repo is created.** You do not build the index by hand. A successful `abuild -r` writes the package and its subpackages to the package output directory (for example `/var/home/qnx/packages/extra/x86_64`) and regenerates and signs `APKINDEX.tar.gz` there with the abuild packager key (`PACKAGER_PRIVKEY` in `~/.abuild/abuild.conf`). That signed index is what makes the directory a usable apk repository. Listing it in `/etc/apk/repositories` (local paths first) plus `sudo apk update` is all the next package in a chain needs to resolve it.

### 6. Build and inspect
Run a clean `abuild -r -c -K`. Inspect the generated APK names and subpackages. Use `apk info -L` and `apk info -W` to confirm file ownership. As a structural check, `find pkg -name '*.so*' | sort` confirms the subpackage split is correct and nothing is orphaned.

**If `abuild -r` fails at `builddeps failed`, suspect the apk environment before the package.** apk validates the entire installed world on every transaction, so a single conflicting or broken installed package makes `apk add` (and therefore abuild's make-dependency install) fail for EVERY package, often with only an opaque `1 error`. Diagnose with `apk fix 2>&1 | grep -i error` to surface the real conflict (for example a file owned by two packages, or an index fetch returning non-zero). Common causes: a leftover test install that conflicts with a base package over a shared file; a repository in `/etc/apk/repositories` that returns an HTTP error on index update; and orphaned `.makedepends-*` virtual packages left behind by interrupted builds (safe to remove with `apk del $(apk info | grep makedepends)`). Fix the environment, confirm `apk add --simulate <a-dep>` returns OK, then rebuild.

If the apk environment is healthy (`apk add --simulate` returns OK) but `builddeps` still fails, suspect the `SUDO_APK` elevation wrapper itself rather than the package or the repo. Transferring the wrapper to the target through a heredoc-over-SSH can let an unquoted `$@` expand mid-transfer, leaving the wrapper as `apk ""`, so every make-dependency install runs an empty apk command. Fix by writing the wrapper as a local file and pushing it verbatim, not inlining it in a heredoc.

**A stale build directory under `-K` can mask an APKBUILD flag change.** `abuild -r -K`
keeps `src/`, including any CMake/Meson build directory from the previous run. CMake
caches `CMAKE_C_FLAGS` at first configure, so re-running `cmake -B <same-dir>` reuses the
old flags and a newly added `CFLAGS` export never reaches the compile line — the build
fails with the identical error and the fix looks wrong. If a flag change appears to have no
effect, check the actual compile line in the log for the flag before doubting the fix,
and run `abuild clean` before the rebuild.

**An empty subpackage fails the split with a misleading path error.** If a declared
subpackage's split function finds nothing to move, abuild never creates its directory and
the build dies at the very end, after a successful compile and test run:

```
>>> <pkgname>-static*: Preparing subpackage <pkgname>-static...
/usr/bin/abuild: line 2674: cd: .../pkg/<pkgname>-static: No such file or directory
>>> ERROR: <pkgname>-static*: prepare_package failed
```

This reads like an abuild path bug; it is an empty-subpackage bug. The usual cause is a
`$pkgname-static` subpackage on a project whose configure defaults to `--disable-static`
— check the log for `checking whether to build static libraries... no`. Fix by adding
`--enable-static` to configure if the distro ships the static package, or by dropping the
subpackage if it does not.

**Do not rely on automatic `so:` dependency derivation without checking that it works.**
abuild normally derives runtime dependencies from the `NEEDED` entries of the built
shared objects, matching them against the `so:` provides other packages declare. Where no
installed package declares provides, that matching silently yields nothing: the build
prints warnings and still succeeds, but ships a package with no dependencies at all.

```
>>> WARNING: <pkgname>*: so dependency missing: <some-library>
>>> WARNING: <pkgname>-dev*: pkg-config dependency missing: <some-module>
```

Check before trusting it, and check the built package rather than the log:

```sh
apk info --provides <any-installed-lib>   # empty output = derivation cannot work
tar -xzf <pkg>-<ver>.apk .PKGINFO && grep -E '^(depend|provides)' .PKGINFO
```

Where derivation is dead, work the list out mechanically from the built object rather than
from the dependencies you already have in mind. Doing it from memory reliably produces a
short list that omits the platform libraries:

```sh
# 1. what the built library actually needs
readelf -d pkg/<pkgname>/usr/lib/<soname> | grep NEEDED
# 2. resolve each NEEDED except libc to its owning package
apk info -W /usr/lib/<each-soname>
# 3. declare every owner in depends=, with a comment saying why it is explicit
```

Comment the resulting line, so a reviewer does not read it as a redundant hand-rolled
dependency. A plain package-name depend resolves correctly even with no provides.

Expect the QNX platform libraries to be the ones you miss. A library that Linux folds into
libc is frequently its own package here (sockets are the common case), so the `NEEDED` list
routinely contains an entry that has no counterpart in the Alpine aport you started from.

**Every `so dependency missing: NAME` line names a package that belongs in `depends`, with
one exception: the C library.** Treat them individually, not as collective noise from the
provides gap.

The exception matters because the rule as first written contradicts the validation gate,
which says "every **non-libc** entry covered by `depends=`". On this image `libc.so.6` is
owned by `qnx-microkernel`, so a third warning line appears alongside the real ones:

```
>>> WARNING: <pkgname>*: so dependency missing: <a-library>       <- belongs in depends
>>> WARNING: <pkgname>*: so dependency missing: <a-qnx-subsystem> <- belongs in depends
>>> WARNING: <pkgname>*: so dependency missing: qnx-microkernel   <- this is libc, omit
```

`qnx-microkernel` owns `libc.so.6` on this image, so it appears in the warning block on
every port. Omit it, the same way an Alpine aport does not depend on `musl`: it is present
on every system by construction, and declaring it adds noise a reviewer has to question.
Resolve the `NEEDED` list, drop the libc entry, declare the rest.

**`makedepends` needs the same treatment, and nothing warns you when it is wrong.** The
`NEEDED` procedure above resolves *runtime* dependencies. The parallel build-time question
is which `-dev` package owns each bare `.so` symlink the link step resolves, and there is
no warning line for it at all: a missing `makedepends` entry is invisible on any machine
where the package is already installed, and the build simply succeeds. It then fails for
the next person on a clean builder.

```sh
# 1. what the link actually asked for
grep -oE '^\s*-l[a-z0-9_-]+|\-l[a-z0-9_-]+' /tmp/build.log | sort -u
# 2. resolve each -lNAME to the package owning the bare symlink (NOT the versioned .so)
apk info -W /usr/lib/lib<NAME>.so
```

Note it is `/usr/lib/libfoo.so` you must resolve, not `/usr/lib/libfoo.so.N`: the two are
usually owned by *different* packages, the `-dev` one and the runtime one, and only the
`-dev` package makes the link work. The runtime package belongs in `depends`, the `-dev`
package in `makedepends`. A port that declares only the former passes the entire validation
gate and still fails on a clean builder.

**Read every warning line individually.** This is a trap worth naming: once you know
provides are broken image-wide, the whole warning block reads like a single known issue,
and the specific package names in it stop registering. The failure mode is declaring the
one dependency you already had in mind, dismissing the adjacent line as more of the same
noise, and shipping a package missing a real runtime dependency — with the full gate green.

On the x86_64 QEMU image no package declares **`so:`** provides. Be precise about which
kind of provides is missing: plain package-name provides do exist (some packages declare
`provides: <name>=<version>`), but the `so:<soname>` provides that abuild matches `NEEDED`
entries against are absent everywhere. The practical consequence is that derivation is
dead, but the sharper claim is the one that survives contact with the next image.

```sh
apk info --provides <a-few-installed-libs>   # expect: no so: entries anywhere
```

Whether this is specific to how one image's packages were built or general to the QNX apk
repos is **not established**; check rather than assume, and record the per-image answer in
TARGET.md.

Target-specific instances of these belong in TARGET.md.

### 7. Test package function
Enable and run upstream tests where practical. Do not disable an entire suite by default just because some tests are expected to fail. If a suite must be disabled globally, document the specific blocker, the attempted command, and why selective skips are not enough. If individual tests are skipped, list each with its observed failure mode or external dependency. Prefer a small direct smoke test of the package itself, and validate at least one real consumer when the package is a dependency-chain component.

Before disabling a test, separate environment failures from real defects. A whole suite failing identically is usually the harness, not the code: for example a test script that calls `cmp` fails with `cmp: command not found` because the image's busybox lacks that applet, fixed by `checkdepends="diffutils"`, not by skipping. (Some missing tools have no package to add: this image's busybox also lacks `killall`, and `psmisc` is not packaged, so a harness calling `killall` cannot be satisfied with a checkdep; record such cases in TARGET.md.) Once the harness runs, a single test that still fails on QNX while the rest of the suite passes is a documented selective skip via `ctest ... -E '^name$'` (or the suite's equivalent) with a comment stating the observed failure mode, plus a note in the package project README to follow up. Do not skip the suite to hide a real per-platform defect.

**When a data package "does not work", verify the consumer's lookup path before touching the package.** For packages whose value only shows at runtime in another program — icon and cursor themes, fonts, locales, plugin directories — the package can be installed perfectly and still appear broken because the consumer is looking somewhere else. Do not start adding compatibility symlinks or extra install paths to the package until you have found the exact name and path the consumer asks for, in the consumer's own source.

Work the lookup path in this order, and stop as soon as one step explains the symptom:

1. **Find the name the consumer actually asks for**, in the consumer's own source on the target. It is often a hardcoded fallback that differs from the name you installed, and a wrong assumption here sends you to fix the wrong package.
2. **Find where that name comes from at runtime** — the settings backend actually in use, not the one you expect. Check for an explicit empty or overriding value in the live config; an empty string overriding a good schema default is a one-line cause that looks like a packaging bug.
3. **Confirm the consumer's backend implements the feature at all.** A stubbed-out backend function means the feature cannot work no matter what is installed, and no packaging change will fix it.

Two rules fall out of this class of bug. **A previously "working" setup is not evidence the package was right** — the predecessor may have worked only because it happened to populate the one name being requested. And **resist the tempting fix of installing under the name the consumer wants**: making a content package own a system-wide selection point deviates from upstream distros and creates a permanent file conflict with the package that legitimately owns it.

**Timing-sensitive tests under QEMU.** A tight-margin timeout test (a few milliseconds of slack) can fail consistently under QEMU loopback and scheduling jitter while the logic is correct — the tell is that the matching negative case still passes. Treat this as an open root-cause item (QEMU timing vs real QNX behaviour: re-run on hardware or instrument the timing), not an automatic skip. Do not patch out or skip it as if it were a defect until the cause is confirmed.

**Monolithic test binaries.** When the suite is a single binary or one shell script with no `ctest -E` equivalent, a single failing assertion cannot be selectively skipped without patching the test source. Patching out a failure whose root cause is unconfirmed could hide a real defect, so the correct move is to disable the suite (`options="!check"`), document both the blocker and the unconfirmed cause in the report and README, and flag it as a follow-up before merge. Disabling-with-documentation is honest; patching-out-unconfirmed is not.

### 8. Document the review
Two documents come out of this, and they are not the same thing.

The **package project README** (`projects/apks/<pkgname>/<pkgname>-README.md`) is the living project doc: package origin, changes made and why, and a changelog entry for every APKBUILD update, patch add/remove, helper-script addition, dependency change, and package-split decision. Each entry answers: what changed, why, what solution was chosen, and how it resolves the problem. Treat every APKBUILD deviation from Alpine as a documented porting decision, not an incidental edit. If this package unblocks another, link both project notes.

The **after-action report** (`projects/apks/<pkgname>/REPORT.md`) is the write-up a human reads to review the port. Do not skip it and do not fold it into the README: when the port finishes or hits a clear blocker, load `qnx-port-reporting` and write `REPORT.md` per that skill.

### 9. Review-reduction pass (before staging)
This pass is what makes a port reviewable. Remove: unrelated architecture fixes, unused feature flags, local debugging helpers, cross-compilation files in self-hosted ports, and investigation code not required by an observed QNX failure. Consolidate patches that touch the same source area when it makes the reason clearer and does not hide separate decisions. For each remaining patch hunk, be able to point to the exact compile error, link failure, runtime failure, test failure, or package warning it resolves. Confirm each patch hunk matches the house form for patch content — positive `__QNX__` conditionals placed inside the source's existing platform branches. That rule is stated in full in `aports-patch-creation` ("What the change should look like"), which is where it must be applied: by this step the patch is already written, tested, checksummed and validated, so a style change here costs a full re-run of the gate. This is a last check that it was followed, not the place to learn it. Do not keep no-op CMake flags or dependency edits that were only tried during investigation.

### 10. Prepare the review split
Keep one package per review unless a dependency chain requires a tightly coupled version bump. Submit dependency packages before consumer packages. Commit subject style: `<repo>/<pkgname>: new aport` for new aports, `<repo>/<pkgname>: enable/fix build on QNX` for existing ones.

## The validation gate (must pass before reporting work complete)

Run on the target, in the package directory of the authoritative aports tree:

```bash
abuild clean && abuild -K unpack prepare  # patches APPLY here, no Hunk FAILED, no .rej
abuild clean && abuild -r -c -K        # builds, tests pass, expected APKs produced
find pkg -name '*.so*' | sort          # subpackage split correct, nothing orphaned
readelf -d pkg/*/usr/lib/*.so.* | grep NEEDED   # every non-libc entry is covered by depends=
grep -oE '\-l[a-z0-9_-]+' /tmp/build.log | sort -u  # every -l covered by makedepends (see step 6)
git status                             # read-only check: only intended files modified
```

**The second `abuild clean` is not redundant — without it the gate fails itself.** Line 1
leaves a fully unpacked, already-patched `src/`. `abuild -r` does not re-extract over an
existing `src/`, so it runs `prepare` a second time against the patched tree and the
patch is applied twice. For a patch that creates new files, BusyBox `patch` stops with a
message that looks like a broken patch and is not:

```
>>> pkgname: <some>.patch
creating <a/new/file/the/patch/adds>
patch: can't open '<a/new/file/the/patch/adds>': File exists
>>> ERROR: pkgname: The following patches failed to apply:
>>> ERROR: pkgname: prepare failed
```

The tell is that the same patch applied cleanly seconds earlier in line 1. Before blaming
the patch, confirm the checksums match the reference aport and that the upstream tarball
really lacks the file (`tar -tf <distfile> | grep <path>`) — if both check out, it is
stale `src/`, not the patch. Whether a patch that only *modifies* files fails the same way
on a double `prepare` is **not established** — run the gate with the clean either way.

The `NEEDED` line is in the gate because a package with missing runtime dependencies
passes every other check. It builds, it tests, it splits correctly, and the defect only
appears when someone installs it on a machine that does not already have the dependency.
Compare that output against the `depend` lines actually recorded in the built package:

```sh
tar -xzf <pkgname>-<pkgver>-r<n>.apk .PKGINFO && grep '^depend' .PKGINFO
```

Read the built package, not the APKBUILD. Whether a `depends=` line survived into the
package is the thing being checked, and on an image where `so:` derivation is dead
(see step 6) the APKBUILD is the only thing that puts it there.

If the target needs the `SUDO_APK` elevation wrapper (see TARGET.md), the `abuild -r`
line needs it too: `SUDO_APK=/tmp/sudo-apk abuild -r -c -K`. Without it the gate fails at
`builddeps failed` before compiling anything, which looks like a package problem and is not.

This gate is the human's check. A local agent can run the commands, but the judgment to proceed is the driver's.

