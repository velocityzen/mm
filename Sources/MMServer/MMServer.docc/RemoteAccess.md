# Remote access

matter-in-motion authorizes every request by the peer's kernel-attested identity: on a Unix domain socket the server captures the client's uid/gid at accept (`LOCAL_PEERCRED` on Darwin, `SO_PEERCRED` on Linux) and evaluates filesystem-style ACLs against it. That identity does not exist on a raw network connection, so the blessed remote path is not TCP — it is **SSH Unix-socket forwarding**, which preserves per-user authorization end to end. This chapter is the deployment recipe: the exact `ssh` incantations, systemd and launchd unit files, and a troubleshooting map grounded in what the server and client actually log and return.

One fact drives everything below: **the server always binds its own socket.** `MMService` creates the `AF_UNIX` descriptor itself, `bind(2)`s it, `chmod(2)`s the socket file to `MMServerConfiguration.unixSocketMode` *between bind and listen* (so no connection is ever accepted under a more permissive umask-derived mode), and hands the descriptor to SwiftNIO, which performs the `listen(2)`. Before binding it runs a stale-socket check: a leftover socket file at the path is liveness-probed with `connect(2)` — refused means a dead predecessor and the file is unlinked; a successful connect means a live server and startup fails with `socketPathInUse`; anything that is not a socket fails startup with `socketPathOccupied` and is never deleted. On graceful shutdown the server unlinks the socket file last, guarded by a device/inode comparison so it never deletes a successor's socket. **There is no systemd socket-activation or launchd `Sockets`-key support in v1** — the server cannot adopt a listening descriptor from an init system, and an init system that binds the path first will make the server's startup probe find a live listener and fail.

## 1. SSH Unix-socket forwarding

### Why this is the remote path

When you forward a Unix socket over SSH, the process that connects to the daemon's socket on the server machine is sshd, running *as the SSH-authenticated user* (sshd drops to that user after authentication). The daemon's peer-credential capture therefore sees that user's real uid and gids, and every ACL check — traversal `x` on ancestors, first-matching-class-wins on the target — works exactly as if the user were logged in locally. No tokens, no TLS certificates, no second identity system: SSH is the authentication layer, the kernel is the attestation layer, and the daemon never knows it is being used remotely.

Two consequences worth internalizing:

- The daemon sees **the forwarding user**, not whoever touches the forwarded socket on the other end. Anyone who can connect to your local end of the tunnel speaks to the remote daemon *as you*. Protect the local socket file accordingly (see below).
- The remote socket file's mode still gates the connection: sshd's `connect(2)` to the daemon's socket is subject to the same `unixSocketMode` and directory permissions as a local client. If the SSH user cannot connect locally on that machine, forwarding does not help — which is the point.

Unix-domain socket forwarding requires **OpenSSH 6.7 or newer** on both ends (released 2014; anything current qualifies). In `ssh -L`/`-R`, an argument containing a `/` is interpreted as a Unix-domain socket path instead of a TCP port.

### Local forwarding: use a remote daemon from your machine

Forward a local socket path to the daemon's socket on the server:

```sh
ssh -N -f \
  -o ExitOnForwardFailure=yes \
  -o StreamLocalBindUnlink=yes \
  -o StreamLocalBindMask=0177 \
  -L "$HOME/.mm/mm.sock:/run/mm/mm.sock" \
  alice@server.example.com
```

Then point the client at the local end:

```swift
let home = FileManager.default.homeDirectoryForCurrentUser.path
let connection = try await MMClientConnection.connect(
    to: .unix(path: "\(home)/.mm/mm.sock")
).get()
```

Flag by flag:

- `-L local_socket:remote_socket` — the ssh client listens on `~/.mm/mm.sock` locally; each connection is carried over the SSH channel and sshd connects to `/run/mm/mm.sock` on the server as `alice`. The daemon sees `alice`'s uid/gid.
- `-N` — no remote command; the session exists only to forward.
- `-f` — background ssh after authentication, so the tunnel survives the launching shell. Combine with `ExitOnForwardFailure=yes` so a failed bind kills the backgrounded process instead of leaving a tunnel that forwards nothing.
- `StreamLocalBindUnlink=yes` — remove a stale socket file from a previous tunnel before binding. The OpenSSH default is `no`, and without it a reconnect fails with `bind: Address already in use` (Unix sockets do not benefit from `SO_REUSEADDR`; the file must be unlinked).
- `StreamLocalBindMask=0177` — the umask applied to the socket file ssh creates. `0177` (the OpenSSH default, restated here because it is load-bearing) yields mode `0600`: only you can connect to the local end, so only you can borrow your remote identity. Do not loosen this to "share" a tunnel — every connection through it is authorized as you.

Create the directory for the local end once, privately: `mkdir -m 0700 ~/.mm`. On Linux, `$XDG_RUNTIME_DIR/mm.sock` is a good alternative (per-user, `0700`, cleaned at logout); macOS has no equivalent, hence the dotdir. Keep the full path short — `sockaddr_un.sun_path` caps it at 103 bytes on Darwin, 107 on Linux, on both the ssh side and the `MMEndpoint.unix` side.

### Remote forwarding: expose a local daemon to a remote machine

The mirror image — a daemon on your machine, a client on the server:

```sh
ssh -N -f \
  -o ExitOnForwardFailure=yes \
  -R /run/user/1000/mm.sock:/run/mm/mm.sock \
  alice@server.example.com
```

`-R remote_socket:local_socket`: sshd binds `/run/user/1000/mm.sock` on the remote machine; connections to it are carried back and the ssh *client* process connects to your local `/run/mm/mm.sock`. Your local daemon therefore sees the peer credentials of your ssh client process — again, the forwarding user. For the remote end, `StreamLocalBindUnlink` and `StreamLocalBindMask` must be set in the *server's* `sshd_config` (both options exist on both sides; for `-R` the socket is created by sshd, so the client-side options do not apply). `AllowStreamLocalForwarding` in `sshd_config` must not have been disabled (default `yes`).

### Tunnel hygiene

- **Stale forwarded sockets** are the most common failure. ssh does not remove its socket file on exit; without `StreamLocalBindUnlink=yes` the next tunnel fails to bind, and with `ExitOnForwardFailure` unset that failure is silent under `-f`. Set both, always.
- **Idle reaping is expected.** The server closes a connection with no traffic in either direction for `MMServerConfiguration.idleTimeout` (default 120 s). SSH keepalives (`ServerAliveInterval`) keep the *tunnel* alive but generate no matter-in-motion frames, so an idle client is still reaped — the client observes `ClientState.closed`. Reconnection is out of scope for v1; the application reconnects (through the still-open tunnel) when it next needs the daemon.
- The tunnel forwards one Unix socket to one Unix socket. The daemon's connection cap, per-connection in-flight cap, frame cap, and hello exchange all apply unchanged; SSH is invisible above the transport.

## 2. systemd service recipe (Linux)

A plain service unit — **not** a socket unit. Do not write a `.socket` file for this daemon: systemd would bind and listen on the path itself, and the daemon's startup liveness probe would then find a live listener and fail with `socketPathInUse`. The daemon binds its own socket; systemd's job is the process, the runtime directory, and the signals.

```ini
# /etc/systemd/system/mm.service
[Unit]
Description=matter-in-motion daemon

[Service]
Type=exec
User=mm
Group=mm
ExecStart=/usr/local/bin/mmd --socket /run/mm/mm.sock
RuntimeDirectory=mm
RuntimeDirectoryMode=0750
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Division of labor, which matters:

- **`RuntimeDirectory=mm`** makes systemd create `/run/mm` at service start, owned by `User=`/`Group=`, and remove it at stop. `/run` is a tmpfs, so this is also what makes the path exist after reboot. **`RuntimeDirectoryMode=0750`** (systemd's default is `0755`) sets the *directory* mode — the outer gate: a peer needs execute on the directory to reach the socket at all. Members of group `mm` get through; others are stopped at the directory.
- **The socket file's own mode is not systemd's job.** The server `chmod(2)`s the socket to `MMServerConfiguration.unixSocketMode` (default `0o660`, owner+group read/write) between `bind` and `listen`. Do not set `UMask=` hoping to shape the socket mode — the server's explicit chmod supersedes the umask-derived creation mode before any connection can be accepted, which is exactly why the configuration value is authoritative.
- Grant access by group membership: run the daemon with a dedicated group (`Group=mm`), add client users to it (`usermod -aG mm alice`), and keep directory `0750` + socket `0660`. For a strictly single-user daemon set `unixSocketMode: 0o600` in code and there is nothing to add here. Note that connect-level access is only the outer boundary — everything past connect is decided per-entity by the ACL provider, per user, which is what the SSH path preserves.

Stop/restart behaves correctly out of the box: systemd's default stop signal is SIGTERM, which the recommended `ServiceGroup` wiring maps to graceful shutdown (stop accepting, drain in-flight handlers, close connections, unlink the socket file last). `RuntimeDirectory` removal then sweeps the directory. On a crash, the leftover socket file is handled by the next start's liveness probe — refused connect, unlink, rebind; no `ExecStartPre=rm ...` incantations needed, and none should be added (the server refuses to delete non-socket files at its path on purpose).

## 3. launchd recipe (macOS)

The equivalent LaunchDaemon. The same rule applies: **no `Sockets` key.** launchd's `Sockets` mechanism creates and listens on the socket itself and hands descriptors to the job over check-in — an API this server does not speak in v1. If launchd binds the path first, the daemon's startup probe finds a live listener and fails with `socketPathInUse`. The daemon binds its own socket; the plist just runs the program.

```xml
<!-- /Library/LaunchDaemons/com.example.mm.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.example.mm</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/mmd</string>
        <string>--socket</string>
        <string>/var/db/mm/mm.sock</string>
    </array>
    <key>UserName</key>
    <string>_mm</string>
    <key>GroupName</key>
    <string>_mm</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
</dict>
</plist>
```

macOS ships no `_mm` account, and launchd refuses to spawn a job whose `UserName` does not resolve — create the role account and group once at install time, before loading the plist. Underscore-prefixed names are Apple's convention for system accounts; pick an unused id in the 200–400 range (`dscl . -list /Users UniqueID | sort -n -k2` shows what is taken):

```sh
sudo dscl . -create /Groups/_mm PrimaryGroupID 300
sudo dscl . -create /Users/_mm UniqueID 300
sudo dscl . -create /Users/_mm PrimaryGroupID 300
sudo dscl . -create /Users/_mm UserShell /usr/bin/false
```

Load with `sudo launchctl bootstrap system /Library/LaunchDaemons/com.example.mm.plist`. On stop, launchd sends SIGTERM (SIGKILL after `ExitTimeOut`, default 20 s) — again the graceful-shutdown path.

Socket directory: launchd has no `RuntimeDirectory` equivalent, and `/var/run` is root-owned and **cleared at every boot**, so a daemon running as `_mm` cannot create its directory there. Use a persistent per-app directory instead and create it once at install time:

```sh
sudo mkdir -m 0750 /var/db/mm
sudo chown _mm:_mm /var/db/mm
```

Ownership and mode of that directory are the outer gate, exactly as with systemd; the socket file's mode is again applied by the server from `unixSocketMode`. Add client users to the `_mm` group for the default `0o660` socket. If you insist on `/var/run`, the daemon must run as root (don't) or a separate root pre-flight job must recreate the directory each boot — the persistent `/var/db` directory avoids both. A stale `mm.sock` surviving reboot in `/var/db/mm` is not a problem: the startup probe unlinks it.

## 4. Raw TCP: trusted networks only

`MMEndpoint.tcp(host:port:)` works, and you should read this paragraph before using it across anything you do not fully control.

> **TCP connections have no identity and no encryption in v1.** Every TCP peer is `PeerIdentity.anonymous` — there are no kernel credentials on a TCP socket, and v1 defines no substitute. The anonymous identity is `uid = uid_t.max, gid = gid_t.max` and is not special-cased in classification; because no real entity should be owned by those values, it classifies as **other** in practice on every entity: the other-class `rwx` bits decide *everything*, for *every* peer that can reach the port. Never create an ACL with owner `4294967295` or group `4294967295` (a `-1` uid/gid cast leaking into the ACL store) — such a record grants its owner- or group-class bits to every anonymous TCP peer. There is no TLS: frames travel in cleartext and nothing authenticates the server to the client or vice versa. The design leaves a seam for an optional NIOSSL handler ahead of the frame decoder (planned as a package trait so UDS-only consumers never link TLS), but that is future work, not a v1 feature. Peer identity over TCP (token- or client-cert-derived) is deferred to a v1.1 hello extension.

Legitimate uses: loopback (`tcp(host: "127.0.0.1", ...)`) when a UDS path is impractical, and closed lab/cluster networks where "anyone who can reach the port" is an acceptable principal. In both cases author the ACLs knowing that only other-bits apply — an entity with other `---` is invisible and untouchable over TCP (provided no ACL carries the `uid_t.max`/`gid_t.max` sentinel, per the warning above), and an entity with other `rw-` is world-writable to the segment. For anything else, use SSH forwarding; if you are tempted to expose TCP across a real network because tunnels feel inconvenient, `ssh -N -f -L` above is the supported answer. (`TCP_NODELAY` is set on all TCP channels; `unixSocketMode` is ignored for TCP.)

## 5. Troubleshooting

Each symptom below maps to what the code actually does, so you can tell the failures apart from the logs and returned errors alone.

- **Client: `MMCallError.denied` on a call.** Wire error code 2 (`permissionDenied`) from the server: ACL denial (missing `x` on an ancestor, target class bits insufficient, no ACL record for the entity, or a root-targeted request to a route that does not accept root). The server logs `authorization denied` at **debug** level with `method`, `entity`, and `reason` metadata and bumps its denials counter — raise the server's log level to debug to see which check failed. Over TCP, remember: you are the other class, always.
- **Client: `MMClientError.transport` / `MMCallError.transport` with "connection refused".** A socket file exists but nothing is listening — daemon down, still starting, or draining. Distinct from a *missing* file (`ENOENT` in the description: wrong path, tunnel not up, or `RuntimeDirectory` already swept). No server log entry exists for either — the kernel refuses before the server is involved. The daemon itself never suffers from a stale file: its startup probe unlinks refused sockets automatically.
- **Client: transport error with "permission denied" (`EACCES`) on connect.** The outer boundary: socket file mode (`unixSocketMode`) or a missing `x` on a directory in the path. Also kernel-level, also invisible to the server. Check group membership against the socket's group and the directory modes at both ends of a tunnel — on the server end the relevant user is the *SSH* user, not whoever runs the client.
- **Server startup fails: `socketPathInUse`.** The liveness probe's `connect(2)` succeeded: a live listener already owns the path. Either a second daemon instance, or an init system that bound the socket for you — remove any `.socket` unit or launchd `Sockets` key; v1 daemons bind their own socket.
- **Server startup fails: `socketPathOccupied`.** Something that is not a socket sits at the path. The server refuses to delete unknown files by design; inspect and remove it manually.
- **ssh: `bind: Address already in use` when opening a tunnel.** Stale forwarded-socket file from a previous tunnel. `StreamLocalBindUnlink=yes` (client config for `-L`, `sshd_config` for `-R`). With `-f` but without `ExitOnForwardFailure=yes` this failure is easy to miss — the backgrounded ssh keeps running while forwarding nothing.
- **Connection drops after ~2 minutes idle.** The server's all-traffic idle timeout (default 120 s, `idleTimeout`) — deliberate reaping. The reap is silent server-side: the connection's inbound stream ends cleanly and no log line is emitted; only the client observes it, as `ClientState.closed`. SSH keepalives do not count as traffic. Reconnect on demand, or raise the timeout.
- **Connection closes immediately after connect, no error frame.** Over the connection cap (`maxConnections`): the server closes without a busy frame — pre-hello there is no msgid to address an error to — logging `connection rejected` with `reason: connection_cap` at debug and counting a rejection. Also the fate of non-protocol probes (`nc`, stray HTTP): the first frame must be a valid hello or the connection is dropped.
