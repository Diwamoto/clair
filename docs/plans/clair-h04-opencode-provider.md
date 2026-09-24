# H04: OpenCode provider runtime contract

Status: accepted task-owned contract
Date: 2026-09-14
Task: `H04`
Depends on: `H02`

This document fixes the H04 boundary before production implementation. H04 is
the first provider lifecycle adapter; it is not the provider event
normalizer, command registry, mobile transport, terminal renderer, or session
journal.

## Scope and ownership

`ClairAgent` owns:

- typed provider identity and version identity;
- typed Project / Worktree / Session identity association;
- resolution of an execution directory from the H02 read-only workspace
  catalog and stable launch-root capability;
- an actor-serialized start, resume, stop, restart, and explicit provider
  upgrade state machine;
- opaque provider process handles and exactly-once cleanup ownership;
- typed launch failures, stale/duplicate lifecycle requests, provider version
  changes, abnormal exits, signals, and exit status;
- bounded, redacted process launch metadata.

The H04 adapter exposes raw provider process output only as an opaque future
seam and exposes bounded process signals for lifecycle control. H04 never
parses stdout, stderr, TUI bytes, JSON, prompts, tool calls, or provider
events. H05 owns provider-independent event normalization, ordering,
deduplication, partial-event handling, and unknown-event policy.

H04 does not import or call the v1 agent runtime, v1 terminal/session
coordinator, mobile protocol, H03 transport, or H06 command dispatcher.

## Typed identity contract

Every managed process is identified by:

```text
ProviderIdentity(providerID, providerVersion)
 + ResourceScope(projectID, optional worktreeID, optional sessionID)
 + SessionID
```

The provider identity is `OpenCode` for the first concrete adapter. The
ProjectID, WorktreeID, and SessionID are the shared B03 types; no UUID or raw
string substitution is allowed at the H04 public runtime seam. A project-owned
session may omit WorktreeID. A worktree-owned session must retain its exact
WorktreeID.

The session ID is never silently reused for another Project, Worktree, or
provider. `start` may create a new typed SessionID or accept one supplied by a
fixture/client. `resume`, `stop`, and `restart` preserve the stored identity.

## Invariants

1. The runtime is an actor and is the sole owner of its mutable session table.
   Public lifecycle calls are linearized by that actor.
2. At most one process handle is attached to a SessionID. A session in
   `starting`, `running`, or `stopping` rejects another launch with a typed
   duplicate/lifecycle error.
3. A launch is admitted only after the H02 catalog boundary finds the exact
   Project or Worktree in `available` state and binds its device/inode identity
   to a stable launch-root capability. Missing, permission-denied, symlink,
   non-directory, or inaccessible roots never become a process cwd.
4. The launch spec cwd must equal the H02-validated root URL after the same
   standard filesystem normalization. An adapter cannot redirect a session to
   an arbitrary path; a mismatch is a typed failure before process creation.
5. Provider ID and provider version are recorded with the session. Resume and
   restart reject an incompatible provider version with a typed provider
   upgrade error; no silent migration or replacement is allowed.
6. A process handle is released once, only after a normal exit, signal exit,
   and descendant cleanup have been proven. The process boundary keeps an
   observed exit private until group cleanup succeeds; a termination callback
   retries cleanup and reports `cleanup_pending` if it still cannot prove the
   group is gone. A stale termination callback cannot mutate a newer process
   because each attachment has a generation token.
7. Stop requests are graceful first and bounded. If the process does not exit
   within the configured grace period, the process boundary force-terminates
   its owned process group and reports a typed forced/abnormal termination
   outcome. Failure to claim that group is a typed failure, never a successful
   parent-only stop.
8. External exit is classified from the provider process boundary as normal
   exit status, signal, or abnormal non-zero exit. H04 does not infer state
   from output bytes.
9. Executable path, cwd, argument count/size, environment count/size, and raw
   output retention are bounded before spawn. The runtime revalidates the
   adapter's launch spec against its own limits immediately before process
   creation. H04 retains no unbounded stdout/stderr buffer.
10. Credentials may enter only through the provider adapter's explicit
    credential boundary. Credentials are not Codable, not part of session
    snapshots, not included in errors/descriptions, and are never logged or
    sent to UI/mobile state.
11. A failed launch cannot leave a session falsely marked running. Cleanup is
    attempted before the typed failure is returned; if the process boundary
    cannot prove cleanup, the process handle and `cleanup_pending` state are
    retained for retry instead of being discarded.
12. Shutdown installs an actor-owned generation fence before it begins
   draining. New start/resume/restart/upgrade operations fail with a typed
   shutdown error; shutdown waits for starting, stopping, upgrading, and
   cleanup-pending sessions to become terminal before returning.
13. On macOS, H02's launch-root capability carries a retained directory
   descriptor plus device/inode identity from the selected catalog snapshot.
   H04 obtains it before any adapter call, retains it through launch-spec
   construction and process creation, and spawn uses descriptor-based cwd.
   H02 rejects a same-path replacement between catalog selection and capability
   open; H04 also compares the descriptor and path identity at spawn and never
   falls back to a path-only cwd.
14. The process boundary returns an atomic start outcome. The start thread
   owns the first nonblocking `waitid(WNOHANG|WNOWAIT)` observation while the
   background reaper is gated. macOS keeps a known group keeper alive as the
   process-group leader; cleanup proves that keeper's live group identity,
   sends the group signal before reaping the provider leader, reaps both
   children, and performs only a read-only PGID absence probe afterward.
   Callback scheduling cannot create a false running result or a terminal
   result before cleanup.

## State machine

```text
absent --start--> starting --spawned--> running
                     |                    |
                     |                    +--external exit--> exited/failed
                     |                    |
                     +--launch error-----> failed
                                          |
running --stop--> stopping --exit-------> stopped
starting --immediate exit----------------> exited/failed
running --restart-> stopping --exit----> starting -> running
running --upgrade-> upgrading --exit---> starting -> running
exited/stopped/failed --resume/restart--> starting -> running
cleanup_pending --retry cleanup---------> stopped/failed
```

`resume` and `restart` retain the same SessionID and target. An explicit
`upgrade` retains the SessionID and target while changing the recorded provider
version; it is the only operation allowed to migrate a provider identity. A
stopped or exited session is metadata, not a live process. A stale identity,
unavailable workspace, provider upgrade without an explicit operation, or
invalid executable prevents the transition to `starting`.

## Failure modes

The public error contract includes typed cases for:

| Failure | Required behavior |
|---|---|
| duplicate launch | reject without touching the live process |
| stale/unknown session | reject without creating a process |
| provider ID/version mismatch or implicit upgrade | reject without replacing the recorded provider |
| explicit provider upgrade | stop the old process, retain target/session identity, and relaunch with the requested version |
| Project/Worktree not found or unavailable | map the H02 typed workspace result; do not spawn |
| cwd mismatch | reject adapter spec before process creation |
| adapter spec exceeds runtime limits | revalidate argv, environment, output, executable, and cwd before process creation |
| invalid executable URL | reject before process creation |
| missing executable | report typed missing-executable error |
| non-executable file | report typed executable-permission error |
| process-group claim failure | report typed group-ownership failure; do not report a successful stop |
| claim failure after spawn | retain the PID, live group-keeper state, and handle in a retryable cleanup path; cleanup fails closed if keeper ownership is not provable |
| process spawn failure | report typed launch error and clean ownership |
| abnormal non-zero exit | retain typed status and mark the session exited/failed |
| signal exit | retain typed signal and mark the session exited/failed |
| graceful stop timeout | force terminate within the bound and report forced termination |
| failed force cleanup | retain the process handle in `cleanup_pending` and retry before restart/shutdown can release it |
| concurrent start/stop/restart | actor ordering plus typed lifecycle conflict; no race-created child |
| shutdown race | fence new lifecycle admissions and drain every in-flight lifecycle state before returning |
| same-path root replacement after catalog selection | H02 compares the catalog device/inode identity while acquiring the stable descriptor and returns a typed fail-closed error |
| cwd replacement during adapter launch-spec construction | retain the H02 capability descriptor, compare descriptor/path identity, and use descriptor-based cwd; return a typed fail-closed error |
| immediate process exit during start | gate the background reaper, observe with `waitid(WNOHANG|WNOWAIT)` under start ownership, clean the keeper-owned group before `waitpid`, and return a terminated outcome only after cleanup/publication |
| PGID reuse between provider exit and reap | keep an OS-backed group keeper alive, signal the group before either child is reaped, and never send a group signal after reap; a reused numeric PGID fails closed |
| stale cleanup callback after concurrent force cleanup | guard pending reassertion by process-group ID, generation, and completion exit under the same lock |
| stale claim completion after cleanup | serialize claim/cleanup transitions by lock and process-group generation; never reassert `pending_cleanup` after successful cleanup |

Errors are safe to present to a caller: they contain IDs, bounded status,
signal, or executable/cwd metadata only. They do not contain environment
values, credentials, prompt text, terminal bytes, or provider output.

## Provider process and credential boundary

The provider protocol constructs a non-wire `LaunchSpec` containing:

- an absolute executable URL;
- bounded argv values (the executable is not duplicated in argv);
- a bounded, sanitized environment assembled by the provider adapter;
- the already validated H02 cwd;
- a raw-output retention limit/policy.

The H02 runtime selects the registered catalog scope, revalidates a supplied
snapshot against a fresh registered Project/Worktree identity, captures its
device/inode identity, and opens a retained launch-root capability. H04
obtains that capability before invoking the adapter's `makeLaunchSpec`, retains
it through process creation, and attaches a duplicated descriptor plus
identity to the validated spec before passing it to an opaque
`AgentProcessFactory`. The concrete OpenCode implementation uses macOS
`posix_spawn` with a control-pipe-backed group keeper, a keeper-owned process
group, and bounded pipe readers behind that factory. Tests use a deterministic
fake factory/process, repeated real immediate-exit commands, an explicit
pre-reap descendant-ordering barrier, arbitrary-catalog rejection, a same-path
catalog replacement, and a real shell-plus-descendant fixture; they never
require an OpenCode installation, network, or provider credential.

The credential source is injected into the OpenCode adapter, not the runtime.
The source can provide environment entries to the adapter, but the launch spec
has no Codable or UI projection and its textual description redacts all values.
The default test fixture provides no credentials. H04 does not implement
Keychain, network authentication, OpenCode server APIs, or event decoding.

## Bounds

The standard fixture/runtime limits are finite and validated at construction:

- at most 64 provider arguments;
- at most 8 KiB per argument and 32 KiB total argv UTF-8 bytes;
- at most 64 environment entries, 256 bytes per key, 8 KiB per value, and
  64 KiB total environment UTF-8 bytes;
- at most 1 MiB of raw output retained per process, with excess discarded and
  a truncation flag available to the future H05 seam;
- a finite stop grace period (default 2 seconds).

These are correctness bounds, not performance benchmarks. H04 does not run
benchmark corpora or collect timing/percentile evidence.

## Test matrix

The H04 test fixture must cover the following without a real OpenCode binary:

| Area | Cases |
|---|---|
| identity | typed provider/project/worktree/session association; project-owned and worktree-owned sessions |
| cwd gate | exact project root; exact worktree root; project/worktree mismatch; missing, symlink, and unavailable H02 roots; catalog identity fields; same-path replacement before capability open; adapter cwd mismatch; adversarial root directory rename/recreate during spec construction |
| launch | start; resume; restart; repeated real immediate process exit; invalid URL; missing executable; non-executable executable; factory spawn failure; adversarial adapter spec revalidation |
| state | duplicate start; stale session; provider version upgrade; concurrent start; concurrent stop/restart ordering |
| exit | zero status; non-zero status; signal; abnormal callback from an old generation; status retained after exit |
| stop | graceful termination; bounded timeout and force termination; repeated stop; injected callback cleanup failure with no premature completed snapshot; concurrent force cleanup versus stale callback failure; injected group-claim failure with real descendant cleanup; claim/cleanup exit race; real descendant cleanup and no retained handle |
| shutdown | concurrent shutdown plus stop/restart/upgrade admissions; fence remains until cleanup finishes |
| bounds/privacy | argv/environment/output limits; no credential in snapshot, error, description, or captured UI-facing state |
| boundary | no v1 import/dependency; no stdout/stderr normalization in H04; fake process receives only the validated cwd and bounded spec |

Each test asserts the typed error or snapshot state and the fake process's
creation/termination count, so a passing test proves resource ownership rather
than only a successful return value.
