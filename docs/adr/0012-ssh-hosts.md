# ADR 0012: SSH hosts

Date: 2026-11-04. Status: accepted. Spec: 0001, "Network". Builds on [ADR 0004](0004-http-api-services.md) and
[ADR 0006](0006-mcp-servers.md).

## Context

The user wants Pi to run shell commands (bash, fish) on their own machines: the homelab, a NAS, a dev box. iOS can't
start `ssh`, but an app may open TCP connections, so the SSH client has to live in the app. A command can take longer
than iOS keeps Pi running, and Pi can be killed in the middle of one, so a plain "run and wait" would either lose the
output or, on resume, run the command a second time.

A shell on the user's machines is the strongest tool Pi has: it can read anything there, send data anywhere, and
delete things. ADR 0004 rules out a generic HTTP tool for the same reason, and ADR 0006 allows MCP only because the
user chooses each server and writes ask first.

## Decision

### Client: Citadel, in its own package

- **`Packages/PiSSH`** wraps [Citadel](https://github.com/orlandos-nl/Citadel) (SSH over Apple's swift-nio-ssh),
  pinned to 0.12.x. It is the app's only third-party package; the alternatives were libssh2 as a C xcframework, or
  writing the client part of swift-nio-ssh ourselves.
- **Ed25519 user keys only.** Citadel signs RSA logins with SHA-1 (`ssh-rsa`), which OpenSSH 8.8 and later refuse by
  default, and it reads no OpenSSH ECDSA private keys. Settings makes a key, or imports an OpenSSH Ed25519 key (with
  or without a passphrase); other keys are refused with a way out (`ssh-keygen -t ed25519`). Passwords work too.
- The host key may be of any type the server offers.

### Hosts live in Swift, secrets in a Keychain service of their own

- The user adds a host in Settings › SSH Hosts: name, host, port, user, login (key or password), shell (login shell,
  bash, zsh, fish or sh), "Needs VPN", "Run without asking", on or off. The list is Application Support
  `ssh-hosts.json`; the password or private key is the Keychain item `ssh-<id>` in the service
  `dev.jcdiv47.pidurable.ssh`, apart from provider keys, so the fetch bridge's key substitution can never reach it.
- **JS gets each host without secrets** (`SshHostConfig`: ID, name, `user@host`, shell, whether it's ready) and names
  hosts by ID. Swift's `SSHToolHost` looks up the host and its secret itself. Only the user adds, changes or removes a
  host; no tool can.
- **Host keys are pinned, and confirmed before any login.** "Get Host Key" connects only far enough to read the key and
  then refuses it, so no password or key goes to a server the user hasn't confirmed. The user compares the fingerprint
  (`SHA256:…`, as `ssh-keygen -l` prints it) and taps Trust; then Pi tests the login. A host whose address changes loses
  its pinned key. A key that differs from the pinned one stops the connection before login, with a message, and
  Settings shows both fingerprints before the user may trust the new one.

### Commands are detached jobs, so the tool is replay-safe

- `ssh_exec { host, command, timeout_seconds }` sends a POSIX sh script to `sh -s` on stdin. The script never goes in the
  exec request, so the login shell (fish, say) never parses it. The script:
  1. creates `~/.cache/pi-durable/ssh/<job>/` with `mkdir`, which is atomic: a second start of the same job finds it;
  2. writes the command through a quoted heredoc with a random delimiter;
  3. runs it detached (`setsid`/`nohup`, all streams redirected) in the chosen shell (`<shell> -l -c "$cmd"`, from the
     home folder), writing `out`, `err`, `pid`, and `exit` when it's done (written to a temporary file and renamed).
- A second exec waits up to `timeout_seconds` (default 60, at most 600) for `exit`, then returns the state, the exit
  code and the output: stdout cut to 24 KB and stderr to 8 KB, each keeping its start and its end.
- **The job ID is `<install ID>-t<taskId>`.** A tool call that reruns after Pi was killed is the same job: it finds the
  directory and waits for the command it started instead of running it again. So `ssh_exec` is `replay: "safe"`. The
  install ID (random, in UserDefaults) keeps a reinstall, whose task IDs start over, from finding an old job.
- A command that outlives the wait keeps running, including while iOS suspends Pi. The result says so, with the job
  ID and pid; `ssh_job { host, job, wait_seconds }` waits for it again (a read: safe, runs without asking). A job whose
  start was cut off before its `pid` was written comes back as `lost`, and the model is told it may not have run.
- Job directories older than 7 days are deleted when the next job starts.
- Connections are kept per host in `SSHConnections` and opened again, once, when iOS or the network closed them.
- The remote machine needs a POSIX `sh`, `mkdir`, `nohup`, `head -c`, `tail -c` and `date +%s`: any Linux, BSD or
  macOS. Windows hosts aren't supported.

### Approvals

- `ssh_exec` is `ask` in `defaultPolicies`. The approval sheet shows the host and the whole command in monospace.
- **"Run without asking"** (off by default) is a per-host `trusted` check: the call runs at once when its host allows it
  **and the conversation holds no outside text**, meaning no `web_search`, `web_fetch` or MCP results. Once a
  conversation holds such text, every command asks again: that text could tell the model what to run.
- Output from the machines is framed as data in the prompt section, and doesn't count as outside text (they're the
  user's own machines).
- The tool's own policy can still be changed in Settings › Tool Approvals, as for any tool.

### Reachability

- "Needs VPN" defaults on for private hosts (the MCP rules: RFC 1918, Tailscale's 100.64/10, `.ts.net`, `.local`, names
  without a dot). A call that can't reach such a host says the VPN may be off.
- Raw TCP isn't subject to App Transport Security. The Local Network prompt's text names SSH hosts too.

## Testing

- `cd Packages/PiSSH && swift test`: keys and scripts; host key and login checks against an in-process Citadel server
  (no login is offered before the key is pinned; a changed key stops the connection); and commands against the
  machine's own OpenSSH `sshd`, run as the current user on a free port with its own host key, `authorized_keys` and
  `HOME` (the user's login shell, fish included; exit codes and streams; quoting; the same job twice runs once; a job
  outliving its wait and its connection; cut output; the tool host's checks). The OpenSSH suite is skipped where
  there is no `sshd`.
- `cd Packages/PiRuntime && swift test` (`SSHChatTests`): in JavaScriptCore, with the scripted model's `ssh` and
  `sshjob` prompts: asking first, the job key from the task, "Run without asking" until web results arrive, unready
  hosts failing without reaching Swift, and the prompt section.

## Later

1. Agent forwarding and jump hosts (Citadel has `jump(to:)`).
2. SFTP tools to read and write files, and a card that draws command output.
3. A stop button for a running job on the tool row (today the model can `kill` the pid with `ssh_exec`).
4. Keys in the Secure Enclave: swift-nio-ssh takes a Secure Enclave P-256 key (`NIOSSHPrivateKey(secureEnclaveP256Key:)`), so a key that can never leave the iPhone is a custom auth method away.
5. A kill-test case that kills Pi in the middle of an `ssh_exec` against a local `sshd`.

## Consequences

- One third-party dependency (Citadel and its SwiftNIO, swift-crypto and BigInt packages) in the app binary.
- RSA-only servers can't be used with a key; they need an Ed25519 key added, or a password.
- Commands run without a TTY and without stdin: anything that prompts (sudo with a password, editors, pagers) fails.
  The prompt section tells the model so.
- Every command leaves its files in `~/.cache/pi-durable/ssh/` on the machine for a week, output included.
