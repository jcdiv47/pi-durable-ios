# ADR 0013: Proxmox VE

Date: 2026-11-05. Status: accepted; steps 1 (the reads) and 2 (the cards and the Proxmox page) are built. Spec: 0001, "Network". Builds on [ADR 0004](0004-http-api-services.md),
[ADR 0006](0006-mcp-servers.md) and [ADR 0012](0012-ssh-hosts.md).

## Context

The user runs their homelab on one Proxmox VE node (`pve`, PVE 9.2.5): 26 guests (22 LXC containers, 4 VMs), backups
to Proxmox Backup Server and NFS. The questions they ask of it are mostly the same few: what's down, did last night's
backup work, how much space is left, restart this, snapshot that before I change it.

`ssh_exec` against `pve` can already answer all of them with `pvesh`, `pct` and `qm`. But it logs in as root, every
action is an approval sheet showing a shell command, and the answers come back as text. Proxmox has an HTTP API on
port 8006 with API tokens whose rights the server enforces, and every action it starts is a server-side task with an
ID (a UPID). That is a better base for a phone: the server limits what Pi may do, the app can say in words what an
action does, and the results can be drawn as cards.

Found on `pve`:

- The API uses Proxmox's own certificate (`CN=pve.lan`, issued by the cluster's own CA, valid until 2027-06-13). Its
  names cover `pve`, `pve.lan` and `192.168.2.130`, not the Tailscale name. `GET /nodes` reports its SHA-256
  fingerprint as `ssl_fingerprint`, and it matches what a client sees on `:8006`.
- Read-only tokens already exist for dashboards (`homebase@pve`, `api@pam!homepage`, both `PVEAuditor` on `/`).
- The permission checks in the API (`PVE/API2/*.pm`): status and config need `VM.Audit`; start, stop, shutdown and
  reboot need `VM.PowerMgmt`; snapshots need `VM.Snapshot` (rollback also takes `VM.Snapshot.Rollback`); `vzdump`
  needs `VM.Backup` on the guest and `Datastore.AllocateSpace` on the backup storage; the apt update list needs
  `Sys.Audit`; a token sees its own tasks, and all of a node's tasks with `Sys.Audit` there.
- Found while building the reads: the list of pending apt updates (`GET /nodes/<node>/apt/update`) needs `Sys.Modify`,
  not `Sys.Audit`, and listing backup files on a storage needs `Datastore.AllocateSpace` on it and `VM.Backup` on each
  guest (`PVE::Storage::check_volume_access`). Neither belongs to a read-only token, so the reads don't use them.

## Decision

### A service with its own token, not root

- Proxmox is a service (ADR 0004) whose host the user sets, as `custom` has: `ProviderKeys.setProxmoxHost(_:)`, from
  Swift only. The key is `proxmox` in the Keychain, the full token `user@realm!tokenid=secret`. JS sends the header
  `Authorization: PVEAPIToken=pi-host-key:proxmox`; `FetchBridge` already substitutes a placeholder inside a header
  value.
- **The user makes a token for Pi**, with privilege separation, and gives it a role of its own. The Settings screen
  shows the commands to paste into the node's shell:

  ```sh
  pveum role add PiOperator --privs "VM.Audit,VM.PowerMgmt,VM.Snapshot,VM.Backup,Sys.Audit,Datastore.Audit"
  pveum user add pi@pve --comment "Pi on iPhone"
  pveum user token add pi@pve iphone --privsep 1 --comment "Pi on iPhone"
  pveum acl modify / --users pi@pve --tokens 'pi@pve!iphone' --roles PiOperator
  pveum role add PiBackup --privs "Datastore.AllocateSpace"
  pveum acl modify /storage/backup-daily --users pi@pve --tokens 'pi@pve!iphone' --roles PiBackup
  ```

  With privilege separation the token has the rights that both its own ACLs and its user's give, so both get the
  role (a token with ACLs whose user has none sees nothing: `/access/permissions` comes back empty).
  `PVEAuditor` alone is a read-only setup, and the write tools then fail with Proxmox's 403, which the tools turn
  into "the token may not do this".
- **Never given:** `VM.Allocate` (create, delete), `VM.Config.*` (change a guest), `VM.Snapshot.Rollback`,
  `VM.Console`, `Sys.Modify` (apt upgrades, services, other users' tasks), `Permissions.Modify`. Rolling back or
  deleting a snapshot and upgrading the host stay on `ssh_exec`, where the user sees the whole command.

### The certificate is pinned, like an SSH host key

- Settings › Proxmox: URL (`https://pve.lan:8006`, an IP, or a Tailscale name), the token, "Needs VPN" (on by
  default for private hosts, the MCP rules).
- **"Get Certificate"** connects, reads the server's leaf certificate and refuses it, before any token is sent. The
  user compares its SHA-256 fingerprint with the one in the web UI (Datacenter › node › System › Certificates) and taps
  Trust. Then Pi tests the token with `GET /version` and `GET /access/permissions`, and shows what the token may do.
- `FetchBridge` gets a server-trust handler for that one host: the leaf certificate's SHA-256 must equal the pinned
  fingerprint. The name and the chain aren't checked, so the Tailscale name works with a certificate that doesn't
  list it. Every other host keeps the system's checks.
- A different certificate (renewed, or someone else) stops the request before the token is sent. Settings shows both
  fingerprints, as for a changed SSH host key. Proxmox renews its own certificate when it nears expiry (this one
  in June 2027), so this will happen.
- App Transport Security leaves trust to the app only for hosts it exempts: IP addresses, names without a dot and
  `.local` (`NSAllowsLocalNetworking`), and `*.ts.net` (the app's exception). Elsewhere, `pve.lan` say, iOS wants a
  certificate it trusts itself, and a pinned self-signed one fails; Settings says so and suggests the IP or the
  Tailscale name. The Local Network prompt's text gains Proxmox.

### Tools

The `proxmox` extension (`js/src/app/proxmox.ts`) calls `serviceFetch("proxmox", …)`, one request at a time
(minimum interval 0). Only the URL paths below are reachable: there is no generic `pve_api` tool (ADR 0004's rule).
Guests are named by VMID; the node is found from `/cluster/resources`, so a cluster with more nodes works too.

Reads, `replay: "safe"`, run without asking:

| Tool             | Returns                                                                                         |
| ---------------- | ----------------------------------------------------------------------------------------------- |
| `pve_overview`   | node CPU, memory, disk, load, uptime, version; guests not running; storages and their use; failed tasks in 24 h |
| `pve_guests`     | every guest: VMID, name, type, status, CPU, memory, disk, uptime, tags; filters by status and tag |
| `pve_guest`      | one guest's config (cores, memory, disks, network, start at boot), snapshots, last backup, an hour's or a day's load |
| `pve_tasks`      | recent tasks, filtered by guest, type, errors only, since                                       |
| `pve_task_log`   | one task's status and the end of its log                                                        |
| `pve_backups`    | the jobs (schedule, storage, guests, next run); guests no job covers; per guest, the last backup's result, time and storage; failed backup tasks in 7 days |

Pending apt updates aren't among them (see Context); the prompt section points the model at `ssh_exec` for them.

**Backups from task logs.** A scheduled backup job runs as one `vzdump` task for all its guests, with an empty task ID,
so the task list can't be filtered by guest. `pve_backups` reads the first log line of the newest backup tasks (up to
72, six at a time), which names the job's guests (`vzdump 100 109 …` or `--all 1 --exclude …`) and storage, and gives
each guest the newest task that named it. Only a task that didn't end `OK` has its whole log read, for which guests
failed (`ERROR: Backup of VM 111 failed - …`). A guest whose job runs rarely (monthly) may be older than the tasks
read; the tool says since when it looked. On `pve` the whole call takes about half a second.

Writes, `ask` in `defaultPolicies`:

| Tool              | Does                                                                              |
| ----------------- | --------------------------------------------------------------------------------- |
| `pve_power`       | `start`, `shutdown` (clean, with a timeout), `stop` (hard) or `reboot` one guest |
| `pve_snapshot`    | takes a snapshot of one guest, with a description                                 |
| `pve_backup`      | backs up one guest now, to a storage the token may write                         |

A write returns as soon as Proxmox accepted it, with the UPID, then waits up to `wait_seconds` (default 60, at most
600) for the task. `pve_task { upid, wait_seconds }` waits again (a read). A task that outlives the wait keeps running
on the server while iOS suspends Pi, as an SSH job does.

### Replay: the server's state, then its task list

Proxmox tasks run on the server, so a write cut off by a kill may have started. Before it sends anything, each write
writes a marker into a document of its tool task: the time and the action. A rerun that finds the marker checks the
server first:

- **`pve_power`** treats `start`, `shutdown` and `stop` as the state they lead to. A rerun reads the guest's status;
  if it is already there, the call is done. Otherwise it looks in `/nodes/<node>/tasks` for a task of the token's
  user on that guest, of that type (`vzstart`, `vzshutdown`, `qmstart`, …), started after the marker, and waits for it.
  Only when there is none does it send the request again. `reboot` has no end state, so it uses the task list only.
- **`pve_snapshot`** names the snapshot after the tool task (`pi_` and a hash of the task ID; Proxmox allows letters,
  digits, `-` and `_`). A rerun that gets "snapshot name already exists" is done, and one whose snapshot task is still
  running waits for it.
- **`pve_backup`** looks for a `vzdump` task of the token's user on that guest after the marker, as `pve_power` does.

So all three are `replay: "safe"`. The token's own user in the task filter keeps a task the user started in the web UI
from being taken for Pi's.

### Approvals and outside text

- The sheet says what will happen, in words, with the guest's name, VMID and type: "Shut down **gitea** (CT 117)",
  "Back up **haos18-1** (VM 120) to backup-daily". `stop` adds "without a clean shutdown". The tool's name comes
  second, as for every tool (`ToolTitles`, `ApprovalDetails`).
- **Guests Pi reaches the node through.** Settings lets the user mark guests such as the router, the VPN and DNS
  (here `immortalwrt`, `wireguard`, `technitiumdns`, `cloudflared`). A power action on one of them always asks, even
  if the tool's policy was changed to run without asking, and the sheet warns that Pi may lose the connection to the
  node and won't see the result.
- If the user lets a write tool run without asking in Settings › Tool Approvals, ADR 0012's rule applies: once the
  conversation holds outside text (`web_search`, `web_fetch`, MCP results), it asks again.
- Guest names, tags, notes and task logs are written into the node by the user and its guests. The prompt section
  frames them as data. They don't count as outside text, as for SSH output.

### Display and system integration

- `pve_overview`, `pve_guests` and `pve_guest` join `cardTools`. The guest card is a list: status dot, name, VMID,
  CPU and memory bars, uptime; a tap opens the guest's page in the web UI through `Route.browser`, which needs the pinned
  trust too. A task card shows the task's progress and its result.
- A running write shows on the run Live Activity with the task's type and guest.
- Later steps (below): guests as App Intent entities, and a widget.

## Testing

Built for step 1:

- `PinnedCertificateTests`: a loopback HTTPS server with a certificate `openssl` makes for the test. Get Certificate
  reads its fingerprint and sends no request; with no pin the system refuses it, with another pin the bridge refuses it
  before the request (and says so), with its own pin the request goes with the token; the token goes only to the
  node's host; fingerprints in pasted forms.
- `ProxmoxChatTests`: the tools in JavaScriptCore against a fake node (`localHosts`, shaped like `pve`'s answers):
  overview, backups with a failed task, a guest's config, notes and snapshots, a 403 in Proxmox's words, no node or an
  unready one (nothing is sent), the prompt section; JS only ever sends `PVEAPIToken=pi-host-key:proxmox`.
- The six tools against `pve` itself with the read-only token, from Bun.

Built for step 2: the overview and backups tests also check the card data, and a dashboard test reads the page's
data without a conversation. The dashboard against `pve`, from Bun.

Planned:

- `cd Packages/PiRuntime && swift test`: a fake Proxmox API (a `URLProtocol`), recorded from `pve`, for the tools'
  paths and output; the replay cases (guest already in the state, a task found in the list, a snapshot that exists,
  nothing found, so the request is sent); a 403 turned into words; the token never in JS (the header JS sees). The
  pinning against a local TLS listener with its own certificate: the token is not sent before Trust, a changed
  certificate stops the request, and other hosts keep the system's checks.
- In the scripted model: `pve` prompts that ask first and show the sheet's words.
- By hand against `pve`, with a test container: every tool, and a kill in the middle of `pve_backup`.
- The kill test (`scripts/kill-test.sh`) doesn't change: it covers the runtime, not this service.

## Order

1. Settings › Proxmox, the pinned trust, `ProviderKeys.setProxmoxHost`, and the read tools, with a `PVEAuditor`
   token. Use it for a while. **Done.**
2. The cards, and the Proxmox page. **Done**, as built: `pve_overview`, `pve_guests` and `pve_backups` return their
   result as data in `details.card` beside the text the model reads (`detailCardTools` in display.ts), and the chat
   draws the node card (CPU, memory and root disk rings, guests that aren't running, storages, failed tasks), the
   guests card and the backups card (`ProxmoxCards`; problems first). The Proxmox page (`ProxmoxView`, the list's More
   menu, `pidurable://proxmox`) draws all three from `PiRuntime.proxmoxDashboard`, which reads the node the way the
   tools do, without the model, every 30 seconds while it's open. A guest's context menu asks Pi about it. No
   overcommit warning: the token can't list a thin pool's volumes, and the guests' configs leave out snapshots and
   leftover volumes, so a sum from them is wrong (574 GiB against LVM's 878 on `pve`).
3. The write tools with the replay rules and the `PiOperator` token.
4. App Intents: guests as entities ("Restart vaultwarden"), from the guest list Swift keeps of the last answer;
   intents run through `ask` with request IDs from their payload.
5. A widget: guests that are down and the last backup's result, from a surface a scheduled task publishes. The widget
   never calls the API.

## Not done

- **A generic Proxmox API tool.** Same reason as `http_request` in ADR 0004; and with a broad token it would reach
  everything in the API.
- **Commands inside guests** (`pct exec`, the QEMU guest agent). They need root or `VM.GuestAgent.*`; `ssh_exec`
  on the node or on the guest does it, with the whole command on the approval sheet.
- **Host upgrades, creating or deleting guests, rollback.** The token doesn't have the rights; SSH does, and asks.
- **Proxmox Backup Server's own API.** PVE's storage view covers the backups Pi needs to report.

## Consequences

- The server, not the app, limits what Pi may do on the homelab. A token that leaks can start, stop, snapshot and
  back up guests, and read their configs, but can't delete or change them.
- The app trusts one self-signed certificate by its fingerprint, for one host. It breaks, visibly, every time
  Proxmox renews the certificate, until the user trusts the new one.
- One more service in `ProviderKeys`, with a host set from Swift, as `custom` and MCP servers are.
- `ssh_exec` against `pve` still works and stays the way to do what the token can't.
