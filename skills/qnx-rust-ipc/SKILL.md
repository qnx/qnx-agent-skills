---
name: qnx-rust-ipc
description: "Guide for writing QNX 8.0 native IPC in Rust with the qnx-ipc crates (qnx-ipc, qnx-resmgr, qnx-ipc-sys): toolchain setup with QNX's Rust package, channels and connections, typed messages and replies, pulses and pulse timers, named channels, resource managers that serve a /dev path, Rust and C sharing one wire protocol, the documented pitfalls, and running tests on the target through a cargo runner. Read this when Rust code needs MsgSend/MsgReceive/MsgReply, pulses, name_attach/name_open or a resource manager; when tempted to hand-write unsafe FFI against sys/neutrino.h; or on errors such as E0505 on a PulseTimer or Request, ENOENT when a resource manager opens its own path, 'Endian not defined' from bindgen, or the libc crate failing for x86_64-pc-nto-qnx800. This is application development with a host cross-compile, not aports porting (see qnx-porting)."
---

# QNX native IPC in Rust

This skill covers writing Rust programs that use QNX 8.0 message passing, pulses and resource managers through [qnx-ipc](https://github.com/jakethehoffer/qnx-ipc) (Apache-2.0). It is application development. It is not aports porting, and the native-build rule in `qnx-porting` (packages are built on the target with `abuild`) does not describe it: these programs are compiled on a Linux host with QNX's Rust package and copied to the target to run. `qnx-platform-facts` calls host cross-compile a separate context, and this is that context. If the task is porting a package, go back to `qnx-porting`.

Provenance and scope: unless an entry says otherwise, the facts below come from qnx-ipc at commit `b3c1b09`, whose tests ran on an x86_64 QEMU target with QNX 8.0 (SDP 8.0.0.00141); its toolchain was set up and checked on 2026-11-11. The toolchain re-check commands and the `libc` failure below were run again on 2026-11-15 on a Linux host (WSL2 Ubuntu), with no target involved, and the Rust snippets in this skill were compiled for `x86_64-pc-nto-qnx800` against that commit but not run. The aarch64 path has not been run. Before relying on a load-bearing fact, run the re-check command next to it.

## The crates

- `qnx-ipc`: `Channel`, `NamedChannel`, `Connection`, `Message`, `Request`, `Handler`, `Pulse`, `PulseCode`, `PulseKind`, `PulseTimer`, `RecvBuf`, `Received`, `SenderInfo`, `ChannelFlags`, `Header`, and the shared `Error` and `Result`.
- `qnx-resmgr`: the `Device` trait and `ResourceManager`, which attaches a device at a path. `ResourceManager::spawn` returns a `RunningManager`.
- `qnx-ipc-sys`: raw bindings that bindgen generates from the SDP headers at build time. Use it for errno constants (`sys::EINVAL as i32`) and for kernel calls the safe crates do not wrap.

Every kernel object is owned by one value and released in its `Drop`: `Channel` destroys its channel, `NamedChannel` calls `name_detach`, `Connection` calls `ConnectDetach` (or `name_close` if it came from `Connection::open`), `PulseTimer` deletes its timer, and dropping a `RunningManager` detaches its path and closes the files still open on it. The public API has no `unsafe fn`. The crate's `docs/architecture.md` lists every `unsafe` block with its invariant.

## Setup

QNX's Rust package ships `rustc` with the standard library prebuilt for QNX, but no `cargo`, `clippy` or `rustfmt`. Pair it with rustup's cargo of the same version. The one-time setup, per qnx-ipc's `docs/toolchain.md`:

1. Install QNX SDP 8.0 with QNX Software Center into `~/qnx800`, plus QNX's host Rust package. Package ids are `com.qnx.qnx800` and `com.qnx.qnx800.host.linux.x86_64.rust`. The proven version is 0.0.1.00014, which gives `rustc 1.85.1-dev`.
2. `rustup toolchain install 1.85.1 --profile minimal`, and for lint `rustup component add rustfmt clippy --toolchain 1.85.1`.
3. `sudo apt install clang libclang-dev`. `qnx-ipc-sys` runs bindgen over the SDP headers, so every consumer needs libclang and `QNX_TARGET` set, also for host-only builds.

Re-check the toolchain after sourcing the SDP environment:

```sh
source ~/qnx800/qnxsdp-env.sh
"$QNX_HOST/usr/bin/rustc" -V                         # expect: rustc 1.85.1-dev
ls "$QNX_HOST/usr/bin" | grep -E 'rustc|cargo'        # expect: rustc only, no cargo
"$QNX_HOST/usr/bin/rustc" --print target-list | grep qnx800   # expect: aarch64-unknown-nto-qnx800, x86_64-pc-nto-qnx800
```

Each shell then needs what qnx-ipc's `tools/env.sh` exports. Inside a qnx-ipc checkout, `source tools/env.sh` does all of it:

```sh
source "${QNX_SDP:-$HOME/qnx800}/qnxsdp-env.sh" >/dev/null   # QNX_HOST, QNX_TARGET, qcc on PATH
export PATH="$HOME/.cargo/bin:$PATH"
export RUSTUP_TOOLCHAIN=1.85.1                                # rustup's cargo
export RUSTC="$QNX_HOST/usr/bin/rustc"                        # QNX's rustc for host and target code
export QNX_RUST_TARGET=x86_64-pc-nto-qnx800
export QNX_IPC_ROOT=/path/to/qnx-ipc                         # your qnx-ipc checkout
export CARGO_TARGET_DIR="$HOME/build/qnx-ipc"                 # the runner reads it for QNX_RUN_WITH_C
export CARGO_TARGET_X86_64_PC_NTO_QNX800_RUNNER="$QNX_IPC_ROOT/tools/qnx-run"
export QNX_SSH_PORT="${QNX_SSH_PORT:-2222}"
export QNX_SSH_KEY="${QNX_SSH_KEY:-$HOME/.ssh/qnx_target_ed25519}"
```

The target triple is `x86_64-pc-nto-qnx800`. QNX's package also carries `aarch64-unknown-nto-qnx800`, which qnx-ipc has not run.

### Depending on the crates

The crates are `publish = false`, so they are not on crates.io. The proven way to use them from another crate is a path dependency on a qnx-ipc checkout, as the scratch crate in `tools/compile-fail.sh` and the demo crates do. `bytemuck` with `derive` is needed to define messages:

```toml
[dependencies]
qnx-ipc = { path = "../qnx-ipc/crates/qnx-ipc" }
qnx-resmgr = { path = "../qnx-ipc/crates/qnx-resmgr" }    # only for resource managers
qnx-ipc-sys = { path = "../qnx-ipc/crates/qnx-ipc-sys" }  # only for errno constants or raw calls
bytemuck = { version = "1", features = ["derive"] }
```

### The cargo runner

`tools/qnx-run` is the runner that `CARGO_TARGET_X86_64_PC_NTO_QNX800_RUNNER` points at. For each `cargo run` or `cargo test` binary built for the QNX triple, it copies the binary over SSH into a fresh directory under `/tmp/qnx-run/`, runs it there as root, streams its output and exits with its exit code. It passes host variables named in `QNX_RUN_ENV="VAR1 VAR2"` to the program, and with `QNX_RUN_WITH_C=1` it also copies the C programs that `tools/build-c.sh` put in `$CARGO_TARGET_DIR/c/`.

It is written for qnx-ipc's own QEMU image: it connects to `root@127.0.0.1` on `$QNX_SSH_PORT` with the key in `$QNX_SSH_KEY`, and the host and user are hard-coded. For a target described in `TARGET.md` (a QSTI image at its own IP, with `qnxuser`), copy the script and change the host and user (qnx-ipc has not tried this). Running as root matters: attaching a resource manager under `/dev` needs it.

## Messages and replies

A message is a plain-data type with a `KIND` of at least `0x200`. On the wire it is a 4-byte `Header` (`kind: u16`, `reserved: u16`) followed by the type's bytes. This is `crates/qnx-ipc/examples/ping_pong.rs` as it is in the repo:

```rust
//! A server and a client in one process, talking over a QNX channel with typed
//! messages: the client sends `Ping { n: 41 }`, the server replies
//! `Pong { n: 42 }` and stops.
//!
//! `cargo run -p qnx-ipc --example ping_pong --target x86_64-pc-nto-qnx800`

use std::ops::ControlFlow;
use std::thread;

use qnx_ipc::{Channel, ChannelFlags, Connection, Handler, Message, RecvBuf, Request};

#[repr(C)]
#[derive(Debug, Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct Ping {
    n: u32,
}

impl Message for Ping {
    const KIND: u16 = 0x201; // user kinds start at 0x200
}

#[repr(C)]
#[derive(Debug, Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct Pong {
    n: u32,
}

struct Server;

impl Handler for Server {
    fn on_message(&mut self, req: Request<'_>) -> qnx_ipc::Result<ControlFlow<()>> {
        // A short or foreign message fails here; the dropped request then
        // answers the client ENOSYS, so it is not left blocked.
        let ping: Ping = req.decode()?;
        req.reply(&Pong { n: ping.n + 1 })?;
        Ok(ControlFlow::Break(())) // one request, then stop
    }
}

fn main() -> qnx_ipc::Result<()> {
    let channel = Channel::new(ChannelFlags::empty())?;
    let conn = Connection::to_local(channel.id())?;
    // The server thread owns the channel. If the send fails, `?` returns from
    // `main` and the process exits, server thread included; joining a server
    // that never got its message would wait forever.
    let server = thread::spawn(move || channel.serve(&mut RecvBuf::with_capacity(64), &mut Server));
    let pong: Pong = conn.send(&Ping { n: 41 })?;
    println!("sent ping 41, got pong {}", pong.n);
    server.join().expect("server thread panicked")
}
```

The rules that make a server correct:

- **A `Request` is answered at most once.** `req.reply(&value)` and `req.reply_error(errno)` both take `self`, so a second answer does not compile.
- **A dropped request still answers.** Dropping a `Request` unanswered replies `ENOSYS`. If it is dropped while its thread panics, it replies `EIO`. `Channel::serve` and `NamedChannel::serve` run each handler call inside `catch_unwind`, so a panicking `on_message` gives its client `EIO` and the loop keeps serving. Use this: for a kind you do not handle, let the request drop.
- **`reply_error` needs a positive errno.** `reply_error(0)` or a negative value is not sent; it returns `Err(Error::Os(EINVAL))` and the dropped request answers `ENOSYS`.
- **A handler `Err` does not stop `serve`.** Only `Ok(ControlFlow::Break(()))` does. `serve` returns `Err` only when receiving fails, and it retries `EINTR`.
- **Dispatch on `req.kind()` before decoding** when one channel takes several types, the way qnx-ipc's `demo/vsigd` does with `const HELLO_KIND: u16 = <Hello as qnx_ipc::Message>::KIND;` in a `match`. An empty reply is `req.reply(&())?`.
- **Size the `RecvBuf` for the largest message decoded:** at least `4 + size_of::<M>()` bytes. A message longer than the buffer is cut to it, and if that leaves too few bytes for `M`, `decode` fails with `Error::Truncated { expected, got }`. A wrong kind fails with `Error::UnknownKind(kind)`. For payloads larger than the buffer, compare `req.sender().srcmsglen` with the buffer and read the rest with `req.read_into(offset, &mut out)`. The client side of that is `conn.send_bytes(kind, &payload, &mut reply)`, which returns the reply length.
- **Who sent it:** `req.sender()` returns a `SenderInfo` with `pid`, `tid`, `priority` and `srcmsglen`.
- **Priority inheritance is on by default.** The receiving thread runs at the sending client's priority unless the channel was created with `ChannelFlags::FIXED_PRIORITY`. Other flags are `DISCONNECT`, `UNBLOCK` and `PRIVATE`.

On the client, `conn.send::<M, R>(&msg)` blocks until the reply and returns it as `R`. A server error reply comes back as `Err(Error::Os(errno))`; use `err.errno()` to read it. `Connection::to_local(chid)` connects to a channel in the same process and `Connection::to_process(pid, chid)` to one in another process on the same node.

## Pulses and pulse timers

A pulse is a small notification that does not block the sender. User codes are `0..=127`; `PulseCode::user(code)` returns `Err(Error::InvalidPulseCode(_))` for anything higher. Send one with `conn.send_pulse(code, value)`. A server receives pulses in `Handler::on_pulse`, whose default ignores them, and matches on `pulse.kind()`:

- `PulseKind::User(code)` for user pulses, with the payload in `pulse.value`.
- `PulseKind::Disconnect` when a client process's last connection goes away. It needs `ChannelFlags::DISCONNECT` on a plain `Channel`; a `NamedChannel` always has it. `receive` has already released the kernel's server connection.
- `PulseKind::Unblock`, `ThreadDeath`, `CoidDeath` and `Other(code)` for the other kernel codes.

A `Pulse` does not carry the sender's connection, so put an identity in the value. qnx-ipc's watchdog demo sends the client id as the heartbeat value.

`PulseTimer::periodic(&conn, code, period)` starts a `CLOCK_MONOTONIC` timer that sends a pulse with `code` (value 0) on `conn` every `period`. To get timer pulses on your own channel, connect to it first. The pattern from `demo/watchdog`, adapted to a server that only takes pulses:

```rust
use std::ops::ControlFlow;
use std::time::Duration;

use qnx_ipc::{Connection, NamedChannel, Pulse, PulseCode, PulseKind, PulseTimer, RecvBuf, Request};

const CHECK_CODE: u8 = 1;
const HEARTBEAT_CODE: u8 = 10;
const CHECK_PERIOD: Duration = Duration::from_millis(500);

struct Monitor {
    beats: u64,
}

impl qnx_ipc::Handler for Monitor {
    fn on_message(&mut self, req: Request<'_>) -> qnx_ipc::Result<ControlFlow<()>> {
        drop(req); // takes no messages: dropping the request answers ENOSYS
        Ok(ControlFlow::Continue(()))
    }

    fn on_pulse(&mut self, pulse: Pulse) -> qnx_ipc::Result<ControlFlow<()>> {
        match pulse.kind() {
            PulseKind::User(HEARTBEAT_CODE) => self.beats += 1, // pulse.value says who
            PulseKind::User(CHECK_CODE) => { /* periodic check */ }
            PulseKind::Disconnect => { /* a client process went away */ }
            _ => {}
        }
        Ok(ControlFlow::Continue(()))
    }
}

fn main() -> qnx_ipc::Result<()> {
    let channel = NamedChannel::attach("monitor")?;
    let self_conn = Connection::to_local(channel.id())?;
    let _timer = PulseTimer::periodic(&self_conn, PulseCode::user(CHECK_CODE)?, CHECK_PERIOD)?;
    channel.serve(&mut RecvBuf::with_capacity(64), &mut Monitor { beats: 0 })
}
```

A client opens the name once with `let monitor = Connection::open("monitor")?;` and then sends each heartbeat with `monitor.send_pulse(PulseCode::user(HEARTBEAT_CODE)?, client_id)?;`.

Keep the timer in a named binding such as `_timer`, as the demos do. `let _ = PulseTimer::periodic(..)` drops it at once, and dropping a `PulseTimer` deletes the timer. A zero `period` fails with `Error::Os(EINVAL)`.

## Named channels

`NamedChannel::attach(name)` registers a name with `name_attach`, and a client in any process on the node connects with `Connection::open(name)`. A `NamedChannel` has the same `id`, `receive` and `serve` as a `Channel`.

- Names are non-empty and use only ASCII letters, digits, `-`, `_` and `.`. Anything else fails with `Error::InvalidName` before any kernel call.
- Attaching a name that is already attached fails with `Error::Os(EEXIST)`. Opening a name nobody has attached fails with `Error::Os(ENOENT)`, so a client that may start before its server retries on `ENOENT`, as `demo/safety-client` does.
- QNX system messages (kinds up to `0x1FF`) can arrive on a named channel. `receive` and `serve` answer them before the handler sees anything: `_IO_CONNECT` gets `EOK` and the rest get `ENOSYS`.
- QNX creates the channel with `_NTO_CHF_UNBLOCK`. A client blocked on it that is signalled or times out stays blocked until the server answers, and the server gets a `PulseKind::Unblock` pulse.

## Resource managers with qnx-resmgr

Implement `Device` and attach it at a path; then `cat`, `std::fs` and C programs can use the path as a file. This is `crates/qnx-resmgr/examples/hello_device.rs` as it is in the repo:

```rust
//! Serves `/dev/hello` until killed: `cat /dev/hello` prints `hello from Rust`.
//!
//! Run as root (attaching under `/dev` needs it).

use qnx_resmgr::{Device, ResourceManager};

struct Hello;

impl Device for Hello {
    fn read(&self) -> qnx_ipc::Result<Vec<u8>> {
        Ok(b"hello from Rust\n".to_vec())
    }
}

fn main() -> qnx_ipc::Result<()> {
    eprintln!("serving /dev/hello");
    ResourceManager::new("/dev/hello")?.run(Hello)
}
```

From a qnx-ipc checkout, run it with `cargo run -p qnx-resmgr --example hello_device --target $QNX_RUST_TARGET`, then read it from another shell with `ssh -i "$QNX_SSH_KEY" -p 2222 root@127.0.0.1 cat /dev/hello`.

How `Device` behaves:

- `read(&self)` is called once per open file, on its first read. The result is that open's snapshot: later reads are served from it at the file offset, a read at or past the end returns end of file, and a new open sees new content.
- `write(&self, data)` gets each write's full payload and returns how many bytes it took. The default rejects writes with `ENOSYS`.
- `devctl(&self, cmd, data)` gets commands the framework does not handle itself. `cmd` is the full `<devctl.h>` command word; write output into `data` and return its length. The default is `ENOTTY`. The open mode is not checked, so a client that opened the path read-only can send any command; check permissions in the device.
- `pread` and `pwrite` (`_IO_XTYPE_OFFSET`) get `ENOSYS` without reaching the device.
- The methods take `&self` and the trait needs `Send + Sync + 'static`, so keep mutable state behind a `Mutex` or atomics. The repo's `Store` test device holds `data: Mutex<Vec<u8>>` and appends in `write`.
- An `Error::Os(errno)` with a positive errno goes to the client as that errno. Any other error goes as `EIO`, and a panicking method gives `EIO` while the manager keeps serving.

`ResourceManager::new(path)` takes an absolute path and fails with `Error::InvalidName` for a relative path or one containing a NUL byte. `.mode(0o444)` sets the permission bits (default `0o666`). `.run(device)` serves on the calling thread and blocks. `.spawn(device)` serves on a new thread and returns a `RunningManager`; keep it in a named binding, because dropping it detaches the path. `demo/vsigd` spawns two read-only managers next to a named channel in one process.

There is one dispatch thread per manager. A `Device` method must not do I/O on its own path, because the dispatch thread would wait for itself. Other code in the same process may open the path.

## Rust and C on one protocol

The wire format is plain C structs, so a C program built with `qcc` can be a client or a server. From `c/include/qnx_ipc_ping.h`:

```c
#define PING_NAME "qnx-ipc-ping"
#define PING_KIND 0x201 /* user kinds start at 0x200 */

struct ping_hdr {
    uint16_t kind;     /* PING_KIND */
    uint16_t reserved; /* always zero */
};

struct ping_msg {
    struct ping_hdr hdr;
    uint32_t n;
};

struct pong {
    uint32_t n;
};

_Static_assert(sizeof(struct ping_hdr) == 4, "ping_hdr must be 4 bytes");
_Static_assert(sizeof(struct ping_msg) == 8, "ping_msg must be 8 bytes");
_Static_assert(sizeof(struct pong) == 4, "pong must be 4 bytes");
```

The Rust side defines `Ping` (payload only, without the header) and `Pong` with `#[repr(C)]` and asserts the same sizes, so a size change on one side fails to build until the other side changes too. Reordered or retyped fields of the same size are not caught.

```rust
const _: () = assert!(size_of::<Header>() + size_of::<Ping>() == 8);
const _: () = assert!(size_of::<Pong>() == 4);
```

Rules for the C side:

- `Request::reply` passes the reply length as the `MsgReply` status, so a C client's `MsgSend` returns that length on success. Treat only `-1` as failure.
- A C server that replies with status `EOK` makes the Rust client's `send_bytes` return 0 even if it sent data. `send` is unaffected.
- A C server on a `name_attach` channel must answer system messages itself, as `c/ping_server.c` does: `MsgReply(rcvid, EOK, NULL, 0)` for `_IO_CONNECT`, `MsgError(rcvid, ENOSYS)` for any other type up to `_IO_MAX`, and `ConnectDetach(msg.pulse.scoid)` on a `_PULSE_CODE_DISCONNECT` pulse.
- Build with `qcc -Vgcc_ntox86_64`, as `tools/build-c.sh` does, and run the C programs on the target with `QNX_RUN_WITH_C=1`.

## Pitfalls

Each of these was hit or documented in qnx-ipc. Symptom first, then cause and fix.

- **``error[E0505]: cannot move out of `conn` because it is borrowed`` around a `PulseTimer`.** The kernel timer holds only the coid number, and QNX reuses coids, so a timer that outlived its connection would pulse whatever channel got that coid next. `PulseTimer<'c>` borrows its `Connection` to rule that out. Declare the connection before the timer and keep both alive together.
- **``error[E0505]: cannot move out of `channel` because it is borrowed`` around a `Request`.** A received request borrows its channel and its `RecvBuf`, so it cannot outlive the channel and the buffer cannot be reused while it lives. Answer or drop the request before the channel goes, and receive into the buffer again only after that.
- **`Message::KIND must be >= 0x200` (`error[E0080]`).** Kinds below `0x200` are QNX's (`_IO_BASE` to `_IO_MAX`), and `send` and `decode` refuse them at compile time. `send_bytes` with such a kind returns `Error::Os(EINVAL)` at run time.
- **A server that waits for a connect message never sees one.** On QNX 8.0, `name_open` of a local name sends the server nothing, which a probe on the target showed. Learn about a client from its first real message (the demo's `HELLO`) and about its exit from `PulseKind::Disconnect`. `NamedChannel` still answers an `_IO_CONNECT` if one arrives.
- **Every open of a resource manager's path from its own process fails with `ENOENT`.** QNX needs `_RESMGR_FLAG_SELF` in `resmgr_attach` for that. `qnx-resmgr` passes it, so this only bites code that calls `resmgr_attach` itself through `qnx-ipc-sys`.
- **A client stays blocked forever.** The library answers a dropped request and a panicking handler, but `std::mem::forget` on a `Request` skips its `Drop`, and `panic = "abort"` turns the `EIO` path into a process abort (the client then sees the server die). Do not leak requests, and keep the default unwinding panics in servers.
- **The `libc` crate fails to build for `x86_64-pc-nto-qnx800`.** Version 0.2.191 only knows QNX 7.x target environments. The first error is `error: non-item macro in item position: panic` at `libc-0.2.191/src/unix/nto/mod.rs`. Take errno and other constants from `qnx-ipc-sys` instead (`sys::ENOENT as i32`). Reproduced on 2026-11-15 with a scratch crate that depends on `libc = "=0.2.191"` and runs `cargo build --target x86_64-pc-nto-qnx800` with `RUSTC` set to QNX's `rustc`. If a newer `libc` builds, update this entry.
- **bindgen stops with `Endian not defined`.** clang does not predefine the macros `qcc` does. `qnx-ipc-sys/build.rs` passes `__QNX__=800`, `__QNXNTO__`, `__unix__`, `__unix`, `__LITTLEENDIAN__` and, on x86_64, `__X86_64__`, with `--target=<triple>` and `--sysroot=$QNX_TARGET`. Copy that list if you write your own bindings.
- **`scp: ... Resource busy` when tests run back to back.** QNX keeps a program file busy for a moment after its process exits. `tools/qnx-run` copies into a fresh directory per run for this reason; keep that if you adapt it.
- **Ctrl-C stops `cargo run` but not the program on the target.** A resource manager keeps serving its path. Stop it on the target with `slay <program>`, for example `ssh -i "$QNX_SSH_KEY" -p 2222 root@127.0.0.1 slay hello_device`, which also removes `/dev/hello`.
- **A `TimerTimeout` armed before `NamedChannel::receive` does not cover the whole call.** It covers only the first internal receive; if that one gets a system message, the next receive is not covered. `Channel::receive`, `Connection::send` and `Connection::send_bytes` make no kernel call before the receive or send, so a timeout armed just before them applies.

## Verifying on the target

Claims about IPC behaviour need a run on QNX. Type-checking on Linux is not enough.

- **Tests on the target.** With the environment above and the target reachable, `cargo test --target $QNX_RUST_TARGET` builds every test binary for QNX and the runner executes each one on the target, returning its real exit code. Add `QNX_RUN_WITH_C=1` when tests start the C programs. A test that can block (a send with no reply) should carry its own deadline, as the repo's tests do with `TimerTimeout` called through `qnx-ipc-sys` or a thread that waits with a time limit, so a bug fails the run instead of hanging it.
- **Everything at once in qnx-ipc.** `tools/test-all.sh` runs lint, docs, the `compile_fail` checks, the C build, every workspace test on the target and the demo check, and writes `docs/test-log.txt` with the QNX and toolchain versions.
- **Lint and docs on the host.** `clippy` and `rustfmt` are not in QNX's package. Run them from rustup with `RUSTC` unset, for the Linux target: `env -u RUSTC cargo clippy --workspace --all-targets --target x86_64-unknown-linux-gnu -- -D warnings`. This type-checks because the bindings always come from the QNX headers.
- **`compile_fail` doc examples** cannot run as doctests for QNX. qnx-ipc's `tools/compile-fail.sh` builds each one in a scratch crate for the Linux host and requires the error code named in its comment.

When reporting a result, state the scope that was run: the target image and architecture, the QNX and `rustc` versions, and which tests ran on the target.
