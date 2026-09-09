---
name: alpine-qnx-porting
description: Native QNX 8.0 porting of Alpine APKBUILD packages, built on the target with abuild. Covers dependency and APKBUILD adaptation, build-system walls (autotools config.sub/x86pc build triple, libtool -fPIC, Meson), Vala/valac segfault workarounds, macro-conflict shims, and repo conventions (LTO off, -Qunused-arguments, somask). Read when adapting an APKBUILD or hitting a compile/link wall on QNX. See qnx-platform-facts for OS-level facts and aports-patch-creation for patches.
---

# Alpine Linux to QNX 8.0 Porting

## Overview

This skill provides guidance for porting Alpine Linux projects to QNX 8.0: APKBUILD integration, and the build-system walls each upstream build system hits on QNX.

Most ports land in "Build systems on QNX" below — autotools (the `x86pc` build triple and libtool `-fPIC`) covers the common case, and CMake and Meson are handled there too. The Vala/valac material in Phase 3 is a narrower special case; skip it unless the package actually builds Vala.

## Environment context

> This skill covers native aports porting: packages are built **on the QNX target itself** with `abuild` (the host does not cross-compile them). For platform-level QNX facts shared across all ports, see the `qnx-platform-facts` skill; for the universal rules (including the native-build rule and where the SDP applies) and task routing, see `qnx-porting`.

### Development setup
- **Host System**: Ubuntu, used only to launch the QEMU target (not for compiling)
- **Target System**: QNX 8.0 (QEMU x86_64 or RPi5 aarch64), where the build actually runs
- **QNX Image**: Quick Start Target Image (QSTI) or Custom Target Image (CTI) for QEMU/RPi; the build runs on the target
- **Build System**: Alpine's APKBUILD, built natively on the target with abuild

### Key toolchain details
- **Compiler**: the native QNX `cc` is clang; expect clang diagnostics, not gcc ones
- **Vala compiler** (Vala packages only): valac 0.56.18
- **Compiler settings**: LTO disabled repo-wide; single-threaded compilation where a build is unstable

## Core porting workflow

### Phase 1: Dependency analysis
1. Identify all project dependencies from APKBUILD
2. Check which dependencies are already available on QNX — **search by stem, not by Alpine's exact package name**
3. Port missing dependencies first (bottom-up approach)
4. Document any QNX-specific patches needed for each dependency

**A dependency is not missing just because Alpine's name misses.** The QNX tree renames
packages, so `apk info -e <alpine-name>` returning nothing proves only that *that string*
is not a package. Search the stem and read the results before concluding anything:

```sh
apk search -q <stem> | sort -u     # Alpine's name may be versioned/suffixed differently here
apk info -W /usr/bin/<the-tool>    # which package actually owns the binary you need
```

Getting this wrong is expensive in both directions: you either port a dependency that
already exists under another name, or you drop a feature and write a comment claiming the
package is unavailable when it is not.

**Then ask what the dependency is actually for before adding it.** Alpine aports carry
dependencies for historical reasons, and the thing your build actually needs is often a
single binary that ships in its own standalone package. `apk info -W` on the specific file
the build looks for answers this directly, where the package name alone does not. An
available-but-unused dependency is still a no-op the review-reduction pass will remove.

### Phase 2: Header conflicts resolution
**Common Issue**: QNX's stdlib.h macros conflict with library method names

**Solution Pattern**:
```c
// Create header shim, placed before the includes that conflict
#ifdef __QNX__
#undef min
#undef max
#endif
```

**Application**:
- Place shims before problematic includes
- Test with isolated compilation units first
- Document which methods required shimming

### Phase 3: Vala compiler stability on QNX

**Known Issues**:
- Valac 0.56.18 segfaults on certain complex Vala syntax patterns
- Batch compilation often fails where individual file compilation succeeds
- Memory/parsing limitations with complex property declarations

**Workaround Strategy**:
1. **Identify Problematic Files**
   - Compile files individually: `valac file.vala`
   - Note which files cause segfaults
   
2. **Syntax Simplification via APKBUILD**
   Use sed commands in APKBUILD `prepare()` function to simplify problematic patterns:
   
   ```bash
   # Example: Simplify complex property declarations
   prepare() {
       default_prepare
       
       # Fix chained casts that crash valac
       sed -i 's/((Widget) child)/(child as Widget)/g' src/problematic.vala
       
       # Expand compact property syntax
       sed -i 's/property type name { get; set; }/property type name {\n    get { return _name; }\n    set { _name = value; }\n}/g' \
           src/another-problem.vala
   }
   ```

3. **Build Settings Adjustments**
   ```bash
   # In APKBUILD
   export CFLAGS="-g -O0"  # Debug mode, no optimization
   export LDFLAGS="-Wl,--no-as-needed"
   
   # Meson options
   meson configure -Db_lto=false  # Disable Link-Time Optimization
   meson compile -j1  # Single-threaded to avoid race conditions
   ```

### Phase 4: APKBUILD integration

**Maintainer headers: two lines, always, on every aport derived from Alpine.** An Alpine
APKBUILD opens with a single `# Maintainer:` line naming the Alpine maintainer. The QNX
tree keeps that attribution but renames it, and adds the QNX maintainer below:

```bash
# Alpine-Maintainer: <the name already on the Alpine aport>
# Maintainer: <the QNX maintainer, Name <email>>
```

Do not simply leave Alpine's header untouched — that leaves the aport claiming an upstream
maintainer for a package they do not maintain here, and it is inconsistent with every other
aport in the tree. Do not drop the Alpine name either; the provenance is wanted. Check the
convention against a neighbouring aport rather than assuming, since it is a house rule
rather than an Alpine one:

```sh
head -3 <tree>/extra/*/APKBUILD | grep -i maintainer | sort | uniq -c | sort -rn | head
```

For the QNX maintainer identity, use `PACKAGER` from `~/.abuild/abuild.conf` if it is set.
It frequently is not (the file often carries only `PACKAGER_PRIVKEY`, the signing key).
When there is no packager identity configured, do not invent one and do not guess a domain
from a git log — ask, and say plainly in the report that the identity is unset.

**Structure Pattern**:
```bash
# APKBUILD template for QNX port
# Alpine-Maintainer: <from the Alpine aport>
# Maintainer: <you>
pkgname=library-name
pkgver=version
pkgrel=0
pkgdesc="Description"
arch="all"
depends="dependency1 dependency2"
makedepends="meson vala-dev"

prepare() {
    default_prepare
    
    # QNX-specific source modifications
    # Use sed for surgical code changes
    # Document WHY each change is needed
}

build() {
    abuild-meson \
        -Db_lto=false \
        -Doption=value \
        . output
    
    meson compile -C output -j1
}

check() {
    # Often skip on QNX due to environment differences
    return 0
}

package() {
    DESTDIR="$pkgdir" meson install --no-rebuild -C output
}
```

## Build systems on QNX

Different upstream build systems hit different QNX-specific walls. The Vala/Meson path is above. The other common one is autotools.

### Autotools (configure / make / libtool)

Two QNX issues show up on almost every autotools port, and neither needs a source patch; both are `build()` fixes.

**1. The build triple (`config.sub` rejects `x86pc`).** QNX `uname -m` returns `x86pc`, so `config.guess` emits `unknown-x86pc-nto-qnx8.0.0`, and `config.sub` rejects the `x86pc` CPU token (`machine 'unknown-x86pc' not recognized`). The bundled config.sub already knows `nto-qnx`; only the CPU token is the problem. This is not a stale config.sub and is not fixed by refreshing gnuconfig (the image has none). The fix is to pass a valid build triple to configure so it skips `config.guess`:

```sh
./configure --build=$CBUILD --host=$CHOST ...
```

**Use `$CBUILD`/`$CHOST`, not a hardcoded triple.** These are *not* set in `abuild.conf`,
which makes them look unset, but abuild resolves them itself: sourcing
`/usr/share/abuild/functions.sh` yields `CBUILD=[x86_64-pc-nto-qnx8.0.0]` and
`CHOST=[x86_64-pc-nto-qnx8.0.0]` on the x86_64 image, and configure then reports
`checking build system type... x86_64-pc-nto-qnx`. Writing the literal
`--build=x86_64-pc-nto-qnx8.0.0` also works on x86_64, but it is wrong for any package
declaring `arch="all"` because it hardcodes the wrong triple on aarch64. Note the trap
that produced this correction: these variables are genuinely absent from `abuild.conf`,
which makes "they are unset" look true, but that says nothing about the shell abuild
actually runs `build()` in. Verify with:

```sh
sh -c '. /usr/share/abuild/functions.sh; echo "CBUILD=[$CBUILD] CHOST=[$CHOST]"'
```

Inside `build()` abuild has already set them, so the APKBUILD just uses them. A plain SSH
shell has not, so the same configure line pasted into `src/` during manual iteration
expands to `--build= --host=` and falls back into the `config.sub` failure above — see
`aports-patch-creation`, Phase 1, for that trap.

**2. libtool and `-fPIC` for shared libraries — package-dependent, so confirm before adding.**
Some autotools projects hit a shared-library link failure on QNX because libtool does not
inject a PIC flag:

```
relocation R_X86_64_PC32 ... can not be used when making a shared object; recompile with -fPIC
```

When that error actually appears, the fix is to add `-fPIC` to CFLAGS:

```sh
export CFLAGS="$CFLAGS -fPIC -Qunused-arguments"
```

**Do not add it pre-emptively.** This was previously written here as a near-universal QNX
autotools wall, and it is not — plenty of autotools projects link their shared library
cleanly on QNX with no `-fPIC` at all. Adding a flag that no observed failure requires is
exactly what the `qnx-apk-packaging` review-reduction pass exists to strip, and a reviewer
cannot tell a load-bearing flag from cargo. Let the link fail first, then add it. Check
whether it is doing anything:

```sh
# remove the flag, rebuild, and see whether the link still succeeds
abuild clean && abuild -K unpack prepare && abuild -K build
```

(`-Qunused-arguments` is the repo-wide convention for the clang unused-argument warnings from the default hardening flags; see the repo-conventions section.)

**Sockets often link themselves.** An autotools project whose configure does `AC_SEARCH_LIBS(socket, ...)` finds `/usr/lib/libsocket.so` and links it automatically, so the classic QNX `-lsocket` wall may never appear. Observe what the build actually does before adding a socket fix (see qnx-platform-facts).

## Common challenges and solutions

### Challenge 1: Macro name collisions
**Symptom**: Compilation errors about redefined `min`, `max`, or similar
**Root Cause**: QNX stdlib.h defines macros that conflict with library methods
**Solution**: Header-based #undef shims (see Phase 2)

### Challenge 2: Vala compiler crashes
**Symptom**: Segmentation fault during compilation
**Root Cause**: Complex syntax patterns exceed QNX valac stability limits
**Solution**: Systematic file isolation + sed-based simplification (see Phase 3)
**Key Files to Watch**:
- Files with chained property accessors
- Complex generic type declarations
- Compact class property syntax
- Files mixing signals and properties

### Challenge 3: Missing dependencies
**Symptom**: Build fails with "Package X not found"
**Root Cause**: Alpine dependencies not yet ported to QNX
**Solution**: Port dependencies first, document patches needed

### Challenge 4: Runtime library paths
**Symptom**: Binary runs but can't find shared libraries
**Solution**: 
```bash
# In APKBUILD package() function
# Ensure RPATH is set correctly
export LDFLAGS="$LDFLAGS -Wl,-rpath,/usr/lib"
```

## Debugging workflow

### Isolating compilation issues
```bash
# Test individual Vala files
valac --pkg=dependency file.vala

# Test with verbose output
valac -v --pkg=dependency file.vala

# Check generated C code
valac -C file.vala
cc -c file.c  # See if C compilation works (native toolchain is clang)
```

### Testing patches
```bash
# Dry-run an existing patch before registering it in APKBUILD
patch --dry-run -p1 < changes.patch
```

Do not generate patches with plain `diff`. Patches are produced with git inside `src/`,
which yields the required `a/`/`b/` header format by construction — see
`aports-patch-creation`, which is the source of truth for patch mechanics.

### Build system debugging
```bash
# Meson introspection
meson introspect output --targets
meson introspect output --buildsystem-files

# See actual compile commands
ninja -C output -v
```

## Best practices

### Source modifications
1. **New QNX-specific source changes go in patch files, not sed.** When you introduce a source change for QNX, make it a proper `.patch` file (see aports-patch-creation), not a `sed` rewrite hidden in `prepare()`. Patches are reviewable and a reviewer can see exactly what changed and why.
2. **Preserve inherited Alpine packaging behavior as-is.** This is the important distinction: the rule above applies to *new* QNX deltas we introduce. Existing Alpine `prepare()` logic, `sed` commands, generated files, and package-specific conventions that came with the upstream APKBUILD should be kept unchanged, unless that exact logic is what causes the QNX porting problem. Do not rewrite inherited Alpine sed into patches just for style; only touch it when it is the actual blocker.
3. **The one exception for new changes:** if the project's established standard for that specific package already uses simple `sed` setup, follow the package's own convention rather than forcing a patch.
4. **Document intent**: comment WHY each change exists, tied to a specific QNX/toolchain behavior.
5. **Test incrementally**: add one fix at a time.
6. **Keep changes minimal**: only modify what is necessary for QNX compatibility.

> Note on the Vala workarounds above: the `sed`-in-`prepare()` examples in the Vala section are a special case for valac segfault patterns where the simplification is mechanical and self-documenting. For ordinary QNX source fixes, prefer a patch per the rule above.

### Repo conventions and packaging facts

These are established conventions of the aports repo; following them keeps a port consistent and review-clean:

- **`somask`**: when a package installs libraries to a private directory rather than `/usr/lib`, use `somask` to suppress the public soname provides. No comment needed; it is an established pattern with precedent in the tree.
- **LTO is disabled repo-wide.** No comment is needed on LTO flags; it is convention (and aids QNX build stability).
- **`-Qunused-arguments`** is used across the repo without comments. Follow suit; do not annotate it. Recognize when it is needed: the QNX `cc` is clang, and the default hardening `CFLAGS` include flags clang considers unused for some compiles (for example `-fstack-clash-protection`). Under `-Werror` that becomes `error: argument unused during compilation: '...' [-Werror,-Wunused-command-line-argument]` and every object fails to compile. The fix is `export CFLAGS="$CFLAGS -Qunused-arguments"` (add `CXXFLAGS`/`CPPFLAGS` likewise for C++/preprocessed builds) at the top of `build()`. There is ample precedent for it in the tree.

Do not comment repo-wide conventions like LTO or `-Qunused-arguments`. Reserve comments for package-specific QNX deviations (see qnx-apk-packaging step 3).

### Collaboration support
- **Patch generation**: always with git inside `src/`, never plain `diff` (see `aports-patch-creation`)
- **Testing patches**: use `patch --dry-run` before applying
- **Documentation**: keep notes on which files required which fixes

### Memory management
- **Use debug builds**: `-g -O0` helps catch issues early
- **Single-threaded compilation**: Reduces race conditions
- **Disable LTO**: Link-Time Optimization causes instability on QNX

## Troubleshooting decision tree

```
Compilation Failure
├─ Header/Include Error?
│  ├─ "undefined reference to min/max" → Add macro #undef shim
│  └─ "Package not found" → Port dependency first
│
├─ Valac Segfault?
│  ├─ Identify crashing file → Compile individually
│  ├─ Complex property syntax? → Simplify with sed
│  ├─ Chained casts? → Replace with explicit 'as' casting
│  └─ Still failing? → Try splitting file into smaller units
│
├─ Linker Error?
│  ├─ "cannot find -l..." → Check dependency installation
│  └─ Runtime lib not found → Add RPATH to LDFLAGS
│
└─ Runtime Crash?
   ├─ Check library versions match
   └─ Verify all dependencies built for QNX
```

## Quick reference commands

```bash
# Iterate on a change in the unpacked tree (does NOT wipe src):
abuild clean && abuild -K unpack prepare
cd src/pkgname-version/
# edit source, then build natively to test:
meson setup build && ninja -C build      # Meson projects
# or: rm -rf build && mkdir build && cd build && cmake .. && ninja   # CMake

# Final validation only (this WIPES src/, never use while iterating):
abuild -r -c -K

# Test individual Vala compilation
valac --pkg=glib-2.0 --pkg=gobject-2.0 file.vala

# Generate a patch: git inside src/, never plain diff (see aports-patch-creation)
cd src/pkgname-version/
git init -q && git add -A && git commit -qm baseline
# ... re-apply the proven change ...
git diff > ../../NNNN-description.patch

# Dry-run an existing patch
patch --dry-run -p1 < fix.patch

# Meson clean rebuild
rm -rf output
meson setup output
meson compile -C output -j1
```

## Additional resources

For OS-level QNX platform facts (libc gaps, stack size, syscall mappings, macros) that apply regardless of build system, see the `qnx-platform-facts` skill. For the end-to-end port-to-PR workflow and the validation gate, see `qnx-apk-packaging`.

