# Target Connection (QNX 8.0)

All porting work happens **on the QNX target itself**, over SSH. There is no host-side aports tree and no scp round-trip: connect to the target, edit the source/APKBUILD/patches there, and build there with `abuild`. The Linux host only launches the target (if it is a local VM) and runs the SSH session.

The simplest way to get a target is the official Quick Start Target Image (QSTI). See the [QSTI for QEMU guide](https://www.qnx.com/developers/docs/qnxeverywhere/com.qnx.doc.target_images/topic/qsti_qemu/about.html) or the [QSTI for Raspberry Pi guide](https://www.qnx.com/developers/docs/qnxeverywhere/com.qnx.doc.target_images/topic/qsti/intro.html). With QSTI you launch the target with `mkqnximage --run` and get its IP with `mkqnximage --getip`.

If you already have your own QNX 8.0 disk image, the `run.sh` in this repo is a QEMU launcher template you can edit and tune directly (set the image path, RAM, cores, and the SSH port forward). It is an alternative to QSTI for the bring-your-own-image case; the instructions are in the script's header comments.

## Connecting

```bash
ssh <user>@<host>
```

- User: `<user>` (depends on the image; QSTI images use `qnxuser`, with `root` available for escalation)
- Host: `<target-host>` (the device or VM IP; use `mkqnximage --getip` for QSTI)
- Password / key: fill in below. If SSH is forwarded to a non-standard host port
  (a hand-rolled QEMU launcher, for example), add `-p <port>` to every ssh and
  sshpass command in this file.

> Fill these in locally, but think before you commit them. This repo is public.
> A shared dev password in git history is public forever. Prefer key-based auth,
> or keep your filled-in copy out of commits (`git update-index --skip-worktree TARGET.md`).
- Port: standard SSH port `22` by default (the QSTI case, connect straight to the target IP). If your setup forwards SSH to a non-standard host port instead (for example a hand-rolled QEMU launcher forwarding host `2227` to guest `22`), add `-p <port>` to every ssh and sshpass command below.
- Authentication: fill in your method below (password or key)

For non-interactive use (required for Claude Code to work without prompting). Add `-p <port>` after `ssh` if your setup uses a forwarded port:

```bash
sshpass -p <password> ssh \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  <user>@<host> '<command>'
```

Or, if using key-based auth:

```bash
ssh -i ~/.ssh/<your-key> <user>@<host> '<command>'
```

## About authentication

A local development target often uses a simple shared dev password. That is fine for a throwaway local image. For anything shared or networked, use key-based SSH and proper secrets handling.

For sudo on the target, pipe the password:

```bash
printf '%s\n' <password> | sudo -S <command>
```

## On-target paths

- Authoritative aports tree: `<path-to-aports>` (for example `/var/home/<user>/aports`)
  An image often carries several `aports*` trees (scratch copies, old experiments).
  Only one is authoritative; use this one path for all PR-bound work and do not read
  from the others. **This is a path, not a credential — fill it in and keep it filled
  in.** Leaving it blank costs every session a round-trip with the operator, and the
  discovery sweep below cannot resolve the ambiguity on its own (see the warning there).
- Package output: `<path-to-packages>/<repo>/<arch>` (for example
  `/var/home/<user>/packages/extra/x86_64`)
- Local repo resolution: add local package output paths before remote repos in
  `/etc/apk/repositories`, then `sudo apk update` (see the `qnx-apk-packaging` skill).

## Discovery sweep (run on a fresh image to populate this file)

Run this on the target to find which aports trees exist and which is authoritative:

```bash
whoami; uname -m
ls -la "$HOME"
for d in "$HOME"/aports*; do
  echo "== $d =="
  git -C "$d" remote -v 2>/dev/null | head -1
  git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null
done
```

**The sweep produces candidates, not an answer.** "The tree whose remote is your fork" is
often not discriminating: where several `aports*` trees share the same fork as their remote
and differ only by branch, that heuristic selects all of them. Treat the sweep as a way to
enumerate what exists, then have the operator name the authoritative one **once**, and
record it above so no later session has to ask again. If the path above is already filled
in, trust it and do not re-run this sweep to second-guess it.

## The on-target loop

1. SSH to the target.
2. `cd` into the package directory in the authoritative tree.
3. Edit APKBUILD / source / patches in place on the target.
4. Iterate with `abuild -K` (keeps `src/`); test changes with the native build system in the unpacked tree. Never `abuild -r` while iterating (it wipes `src/`).
5. Run the validation gate before reporting complete (see `AGENTS.md` and `qnx-apk-packaging`).
6. The human owns the commit and PR record. The agent may inspect the tree with read-only
   git and use git inside `src/` to generate patches, but never commits to the aports tree
   and never pushes.

## Non-interactive abuild dependency install

`abuild -r` installs makedepends through `$SUDO_APK`, which cannot gain root without a tty and fails with `builddeps failed`.

**Preferred fix — grant passwordless apk, so no password is stored anywhere.** Confirm the real path first; the sudoers rule must name the actual binary or it will parse, install, and silently never match:

```sh
command -v apk                      # confirm the real path on your image
echo '<user> ALL=(ALL) NOPASSWD: /usr/bin/apk' | sudo tee /etc/sudoers.d/10-apk-nopasswd
sudo chmod 440 /etc/sudoers.d/10-apk-nopasswd
sudo visudo -c                      # must report no errors
```

`abuild -r` then works with no wrapper and no secret on disk. Check what is already in force before adding anything — `sudo -n -l` shows the effective rules, and on some images the NOPASSWD line lives in `/etc/sudoers` itself rather than a drop-in, so adding one is redundant. Where a drop-in is the right answer, add a new one rather than editing an existing file; images often already ship something like `/etc/sudoers.d/00-<vendor>`.

**Fallback, only where sudoers cannot be edited** — a wrapper holding the dev password. Create it private: `chmod +x` alone leaves it world-readable (755) in a world-readable directory, which exposes the password that gets root to every local user.

```sh
(umask 077; cat > /tmp/sudo-apk <<'WRAPPER'
#!/bin/sh
printf '%s\n' <password> | sudo -S apk "$@"
WRAPPER
)
chmod 700 /tmp/sudo-apk
ls -la /tmp/sudo-apk                # confirm -rwx------

cd <path-to-aports>/extra/<pkg>
SUDO_APK=/tmp/sudo-apk abuild -r
```

Note that `abuild -r` **uninstalls** makedepends when it finishes, so the second run in any sequence needs elevation again. A bare `abuild -r` that worked once will fail at `builddeps failed` the next time.

## Token-efficient remote-build pattern

Redirect the full `abuild` log to a file on the target and pull back only key lines:

```sh
SUDO_APK=/tmp/sudo-apk abuild -r > /tmp/build.log 2>&1; echo "EXIT=$?"
grep -nE '>>>|Hunk FAILED|error:|Build complete|builddeps failed' /tmp/build.log | tail
```

## Image-specific facts (fill in as you discover them)

This section starts empty on purpose. Record anything specific to *your* image that cost
you time once, so it is not rediscovered. Keep it to facts you have proven on this target
with a command; a fact that holds for QNX generally belongs in the `qnx-platform-facts`
skill instead, not here.

Date each entry, and name the command that proved it. The categories below are the ones
that most often bite on a fresh image and are worth checking early:

- **Architecture and identification.** What `uname -m` and `uname -a` actually return, and
  what your build system reports for the system name and processor. These are frequently
  not what a Linux-shaped guess would predict.
- **The clock.** A QEMU guest clock that drifts behind the host silently breaks every
  HTTPS fetch, including the source downloads `abuild` needs, and the TLS error reads like
  a CA or network problem. Compare host and target UTC before anything else on a fresh
  session:
  `diff <(date -u) <(ssh <user>@<host> 'date -u')`
- **Missing busybox applets.** Tests often need a utility the image does not ship; note
  which, and the `checkdepends=` that supplies it.
- **`/etc/apk/repositories`.** Unreachable or forbidden repos make every apk transaction
  noisy and slow, and the noise hides real errors. Note which entries do not resolve from
  your network.
- **Empty or broken packages.** A package can be installed, report a version, and ship no
  files, so a dependency looks satisfied while the library is absent. Confirm anything you
  are about to depend on: `apk info -L <pkg>` for the file list, then `ls` for the library
  itself.
- **apk behaviour.** Check how your `apk` version reports things before writing a test
  around its output; on some versions `apk info -e` prints nothing whether or not the
  package is installed, so only the exit status carries the answer.
- **Elevation.** What passwordless sudo actually covers, proven functionally with
  `sudo -n -l` and a `--simulate` install rather than by reading `/etc/sudoers.d/`, which
  is often not readable by your user.
- **Orphaned `.makedepends-*` virtuals.** These accumulate across interrupted builds and
  cause `builddeps failed`. Note the count and how you cleared it — and check afterwards
  that the purge did not cascade and take the toolchain with it.
- **Any system file you repaired**, and what was wrong with it.
