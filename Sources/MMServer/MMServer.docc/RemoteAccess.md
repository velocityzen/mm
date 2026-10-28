# Remote access

matter-in-motion authorizes each request by the peer identity that the kernel reports. On a Unix domain socket, the server reads the client's uid and gid at accept (`LOCAL_PEERCRED` on Darwin, `SO_PEERCRED` on Linux) and checks filesystem-style ACLs against them. A raw network connection has no such identity. So the supported remote path is **SSH Unix-socket forwarding**, not TCP. It keeps per-user authorization from end to end. This page gives the `ssh` commands, systemd and launchd unit files, and a troubleshooting list based on what the server and client log and return.

One rule applies to everything below: **the server always binds its own socket.** `MMService`:

- creates the `AF_UNIX` descriptor and calls `bind(2)` on it.
- sets the socket file mode to `MMServerConfiguration.unixSocketMode` with `chmod(2)` *between bind and listen*. So it never accepts a connection under a looser mode derived from the umask.
- passes the descriptor to SwiftNIO, which calls `listen(2)`.

Before binding, the server tests any leftover socket file at the path with `connect(2)`:

- Refused: the old server is dead. The server deletes the file.
- Connected: a live server owns the path. Startup fails with `socketPathInUse`.
- Not a socket: startup fails with `socketPathOccupied`. The server never deletes this file.

On graceful shutdown, the server deletes the socket file last. It first compares device and inode numbers, so it never deletes a newer server's socket.

**v1 does not support systemd socket activation or the launchd `Sockets` key.** The server cannot take a listening descriptor from an init system. If an init system binds the path first, the server's startup check finds a live listener and startup fails.

## 1. SSH Unix-socket forwarding

### Why this is the remote path

With SSH socket forwarding, sshd is the process that connects to the daemon's socket on the server machine. sshd runs *as the SSH-authenticated user* (it switches to that user after authentication). So the daemon reads that user's real uid and gids, and every ACL check works as for a local user: traversal `x` on ancestors, first-matching-class-wins on the target. You need no tokens, no TLS certificates, and no second identity system. SSH authenticates the user, the kernel reports the identity, and the daemon does not know the client is remote.

Two consequences:

- The daemon sees **the forwarding user**, not whoever connects to the other end of the tunnel. Anyone who can connect to your local end talks to the remote daemon *as you*. Protect the local socket file (see below).
- The remote socket file's mode still applies. sshd's `connect(2)` to the daemon's socket is subject to the same `unixSocketMode` and directory permissions as a local client. If the SSH user cannot connect locally on that machine, forwarding does not help. This is intended.

Unix-domain socket forwarding needs **OpenSSH 6.7 or newer** on both ends (released 2014, so any current version works). In `ssh -L`/`-R`, an argument that contains a `/` is a Unix-domain socket path, not a TCP port.

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

What each option does:

- `-L local_socket:remote_socket`: ssh listens on `~/.mm/mm.sock` locally and carries each connection over SSH. sshd connects to `/run/mm/mm.sock` on the server as `alice`, so the daemon sees `alice`'s uid and gid.
- `-N`: run no remote command. The session only forwards.
- `-f`: go to the background after authentication, so the tunnel keeps running after the shell exits. Use it with `ExitOnForwardFailure=yes`. Then a failed bind ends the process, instead of leaving a tunnel that forwards nothing.
- `StreamLocalBindUnlink=yes`: delete a stale socket file from an earlier tunnel before binding. The OpenSSH default is `no`. Without it, a reconnect fails with `bind: Address already in use`. `SO_REUSEADDR` does not help with Unix sockets: the file must be deleted.
- `StreamLocalBindMask=0177`: the umask for the socket file that ssh creates. `0177` gives mode `0600`, so only you can connect to the local end and use your remote identity. It is the OpenSSH default. The command sets it explicitly because security depends on it. Do not loosen it to share a tunnel: every connection through the tunnel is authorized as you.

Create the local directory once, with private permissions: `mkdir -m 0700 ~/.mm`. On Linux, `$XDG_RUNTIME_DIR/mm.sock` also works (per-user, `0700`, cleaned at logout). macOS has no equivalent, so use a dot directory. Keep the full path short. `sockaddr_un.sun_path` allows 103 bytes on Darwin and 107 on Linux, for both ssh and `MMEndpoint.unix`.

### Remote forwarding: expose a local daemon to a remote machine

The reverse case: the daemon runs on your machine, and the client runs on the server:

```sh
ssh -N -f \
  -o ExitOnForwardFailure=yes \
  -R /run/user/1000/mm.sock:/run/mm/mm.sock \
  alice@server.example.com
```

`-R remote_socket:local_socket`: sshd binds `/run/user/1000/mm.sock` on the remote machine. Connections to it come back over SSH, and the ssh *client* process connects to your local `/run/mm/mm.sock`. So your local daemon sees the credentials of your ssh client process, which is again the forwarding user. For `-R`, sshd creates the socket, so set `StreamLocalBindUnlink` and `StreamLocalBindMask` in the *server's* `sshd_config`. Both options exist on both sides, but the client-side ones do not apply here. `AllowStreamLocalForwarding` in `sshd_config` must stay enabled (default `yes`).

### Tunnel hygiene

- **Stale forwarded sockets** are the most common failure. ssh does not delete its socket file on exit. Without `StreamLocalBindUnlink=yes`, the next tunnel cannot bind. Without `ExitOnForwardFailure`, this failure is silent under `-f`. Always set both.
- **Idle connections are closed. This is expected.** The server closes a connection with no traffic in either direction for `MMServerConfiguration.idleTimeout` (default 120 s). SSH keepalives (`ServerAliveInterval`) keep the *tunnel* open but send no matter-in-motion frames. So the server still closes an idle client, and the client sees `ClientState.closed`. v1 has no automatic reconnect. The application reconnects through the open tunnel when it next needs the daemon.
- The tunnel connects one Unix socket to another. The connection cap, per-connection in-flight cap, frame cap, and hello exchange apply unchanged. SSH affects only the transport.

## 2. systemd service recipe (Linux)

Use a plain service unit, **not** a socket unit. Do not write a `.socket` file for this daemon. With one, systemd binds and listens on the path itself, and the daemon's startup check then fails with `socketPathInUse`. The daemon binds its own socket. systemd manages the process, the runtime directory, and the signals.

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

Who does what:

- **`RuntimeDirectory=mm`**: systemd creates `/run/mm` at start, owned by `User=`/`Group=`, and removes it at stop. `/run` is a tmpfs, so this setting is also what creates the path after a reboot. **`RuntimeDirectoryMode=0750`** (systemd default `0755`) sets the *directory* mode. This is the outer access check: a peer needs execute permission on the directory to reach the socket. Members of group `mm` pass. Other users do not.
- **systemd does not set the socket file's mode.** Between `bind` and `listen`, the server sets it to `MMServerConfiguration.unixSocketMode` (default `0o660`, owner and group read/write) with `chmod(2)`. Do not set `UMask=` to control the socket mode. The explicit chmod replaces the umask-derived mode before the server accepts any connection. So the configuration value is the one that applies.
- Grant access by group. Run the daemon with a dedicated group (`Group=mm`), add client users to it (`usermod -aG mm alice`), and keep the directory at `0750` and the socket at `0660`. For a single-user daemon, set `unixSocketMode: 0o600` in code and add nothing here. Connect access is only the outer boundary. After connect, the ACL provider decides access per entity and per user. The SSH path keeps this per-user check.

Stop and restart work with no extra setup. systemd's default stop signal is SIGTERM. The recommended setup (the server's bracket run by fp-swift-service with `shutdownSignals: [SIGTERM, SIGINT]`) maps SIGTERM to graceful shutdown: stop accepting, drain in-flight handlers, close connections, and delete the socket file last. Set `shutdownTimeout` below systemd's `TimeoutStopSec` so a stuck drain is cancelled before systemd sends SIGKILL. systemd then removes the `RuntimeDirectory`. After a crash, the next start's check handles the leftover socket file: the connect is refused, so the server deletes the file and binds again. Do not add `ExecStartPre=rm ...`. It is not needed, and the server deliberately refuses to delete non-socket files at its path.

## 3. launchd recipe (macOS)

The equivalent LaunchDaemon follows the same rule: **no `Sockets` key.** With `Sockets`, launchd creates the socket, listens on it, and passes descriptors to the job at check-in. This server does not support that API in v1. If launchd binds the path first, the daemon's startup check finds a live listener and fails with `socketPathInUse`. The daemon binds its own socket. The plist only runs the program.

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

macOS has no `_mm` account, and launchd does not start a job whose `UserName` does not exist. Create the role account and group once at install time, before you load the plist. Apple names system accounts with a leading underscore. Pick an unused id from 200 to 400 (`dscl . -list /Users UniqueID | sort -n -k2` shows the ids in use):

```sh
sudo dscl . -create /Groups/_mm PrimaryGroupID 300
sudo dscl . -create /Users/_mm UniqueID 300
sudo dscl . -create /Users/_mm PrimaryGroupID 300
sudo dscl . -create /Users/_mm UserShell /usr/bin/false
```

Load with `sudo launchctl bootstrap system /Library/LaunchDaemons/com.example.mm.plist`. On stop, launchd sends SIGTERM (then SIGKILL after `ExitTimeOut`, default 20 s). SIGTERM starts the same graceful shutdown.

Socket directory: launchd has no `RuntimeDirectory` equivalent. `/var/run` is owned by root and **cleared at every boot**, so a daemon running as `_mm` cannot create its directory there. Use a persistent directory for the app instead, and create it once at install time:

```sh
sudo mkdir -m 0750 /var/db/mm
sudo chown _mm:_mm /var/db/mm
```

As with systemd, the owner and mode of this directory are the outer access check, and the server sets the socket file's mode from `unixSocketMode`. For the default `0o660` socket, add client users to the `_mm` group. To use `/var/run`, the daemon must run as root (do not do this), or a separate root job must create the directory again at each boot. The persistent `/var/db` directory avoids both. A stale `mm.sock` in `/var/db/mm` after a reboot is not a problem: the startup check deletes it.

## 4. Raw TCP: trusted networks only

`MMEndpoint.tcp(host:port:)` works. Read this section before you use it on any network that you do not fully control.

> **TCP connections have no identity and no encryption in v1.** Every TCP peer is `PeerIdentity.anonymous`. A TCP socket has no kernel credentials, and v1 has no replacement. The anonymous identity is `uid = uid_t.max, gid = gid_t.max`, and classification has no special case for it. No real entity should be owned by those values, so in practice it is in the **other** class on every entity. The other-class `rwx` bits decide *everything*, for *every* peer that can reach the port.
>
> Never create an ACL with owner `4294967295` or group `4294967295` (a `-1` uid/gid cast that leaked into the ACL store). Such a record gives its owner-class or group-class bits to every anonymous TCP peer.
>
> There is no TLS. Frames travel in cleartext, and nothing authenticates the server to the client or the client to the server. The design allows an optional NIOSSL handler before the frame decoder in the future (planned as a package trait, so UDS-only users never link TLS). This is not a v1 feature. Peer identity over TCP (from a token or a client certificate) is deferred to a v1.1 hello extension.

Valid uses:

- Loopback (`tcp(host: "127.0.0.1", ...)`) when a UDS path is not practical.
- Closed lab or cluster networks where "anyone who can reach the port" is an acceptable principal.

In both cases, write the ACLs knowing that only the other-class bits apply:

- An entity with other `---` is invisible and inaccessible over TCP, provided no ACL uses the `uid_t.max`/`gid_t.max` value (see the warning above).
- An entity with other `rw-` can be read and written by anyone on the network segment.

For everything else, use SSH forwarding. If tunnels seem inconvenient, the supported answer is still `ssh -N -f -L` (above), not TCP on a real network. `TCP_NODELAY` is set on all TCP channels. `unixSocketMode` is ignored for TCP.

## 5. Troubleshooting

Each item matches what the code does, so you can tell failures apart from the logs and returned errors alone.

- **Client: `MMCallError.denied` on a call.** The server returned wire error code 2 (`permissionDenied`): an ACL denial. Causes: missing `x` on an ancestor, insufficient class bits on the target, no ACL record for the entity, or a root-targeted request to a route that does not accept root. The server logs `authorization denied` at **debug** level with `method`, `entity`, and `reason` metadata, and increments its denials counter. Set the server's log level to debug to see which check failed. Over TCP, you are always in the other class.
- **Client: `MMClientError.transport` / `MMCallError.transport` with "connection refused".** A socket file exists, but nothing listens on it: the daemon is down, starting, or draining. A *missing* file is a different case (`ENOENT` in the description): wrong path, tunnel not up, or `RuntimeDirectory` already removed. The server logs neither case, because the kernel refuses the connection before the server is involved. Stale files never block the daemon itself: its startup check deletes refused sockets automatically.
- **Client: transport error with "permission denied" (`EACCES`) on connect.** This is the outer boundary: the socket file mode (`unixSocketMode`) or a missing `x` on a directory in the path. The kernel also refuses this one, so the server does not see it. Check group membership against the socket's group, and check directory modes at both ends of a tunnel. On the server end, the relevant user is the *SSH* user, not the user who runs the client.
- **Server startup fails: `socketPathInUse`.** The startup check's `connect(2)` succeeded: a live listener already owns the path. This is either a second daemon instance or an init system that bound the socket. Remove any `.socket` unit or launchd `Sockets` key. v1 daemons bind their own socket.
- **Server startup fails: `socketPathOccupied`.** A file that is not a socket is at the path. The server deliberately does not delete unknown files. Inspect the file and remove it manually.
- **ssh: `bind: Address already in use` when opening a tunnel.** A stale forwarded-socket file from an earlier tunnel. Set `StreamLocalBindUnlink=yes` (client config for `-L`, `sshd_config` for `-R`). With `-f` but without `ExitOnForwardFailure=yes`, this failure is easy to miss: the background ssh keeps running and forwards nothing.
- **Connection drops after about 2 minutes idle.** The server's idle timeout (`idleTimeout`, default 120 s, counts traffic in both directions) closed it on purpose. The server side is silent: the inbound stream ends cleanly and nothing is logged. Only the client sees it, as `ClientState.closed`. SSH keepalives do not count as traffic. Reconnect when needed, or raise the timeout.
- **Connection closes right after connect, with no error frame.** The server is over its connection cap (`maxConnections`). It closes without a busy frame, because before the hello there is no msgid to send an error to. It logs `connection rejected` with `reason: connection_cap` at debug level and counts a rejection. Non-protocol clients (`nc`, stray HTTP) are also dropped: the first frame must be a valid hello.
