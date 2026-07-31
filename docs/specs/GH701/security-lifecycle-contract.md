# GH-701 Normative Security and Manual-Lifecycle Contract

## Status and ownership

This file is a normative part of the GH-701 spec set, not optional background.
`product.md` owns behavior requirements; `tech.md` owns system composition; this file
owns the exact B-019 execution-containment, B-025 verified-file, and B-028 native-proof
security protocols. A decision record must bind the raw-byte SHA-256 of all three
files. A conflict fails closed and requires a new maintainer decision; it is never
resolved by choosing the less restrictive text.

## 1. Non-escapable execution containment (B-019)

Every core invocation starts inside a supervisor-created containment boundary before
candidate-controlled code executes. A Unix process group alone is not a valid
boundary because `setsid()`, double-fork, reparenting, or namespace creation can
escape it.

The selected provider must expose one closed capability record containing provider
kind/version, boundary identity, creation receipt, policy digest, initial process,
descendant event sequence, kill receipt, emptiness proof, reap result, and event-gap
counters. It also binds the inherited-handle inventory, IPC/network namespace and
endpoint policy, denied broker attempts, and external-process access policy. The
runtime rejects a provider not selected by H-001 or a platform on which these
properties cannot be proved.

- Linux uses an unprivileged candidate inside a dedicated PID namespace and cgroup
  v2 subtree plus private user, mount, IPC, and network namespaces. The namespace
  init is a subreaper; a minimal private root/proc view exposes no host service-manager,
  D-Bus, container-daemon, agent, or same-user broker socket. All inherited handles
  except closed supervisor channels are removed, and socket/SCM_RIGHTS policy cannot
  acquire an external broker endpoint. The candidate lacks cgroup, namespace, mount,
  ptrace, and privilege-escalation capabilities. `setsid()` and double-fork may change
  process relationships but cannot leave the boundary. The supervisor records
  fork/clone/exec/exit and denied external-endpoint attempts from boundary creation.
- Windows uses a Job Object with kill-on-close, breakaway disabled, a restricted
  token without debug privilege, and completion-port accounting. Nested jobs or
  child-process policies must not enable breakaway; inherited handles and named-pipe,
  RPC, COM, service-control, and task-scheduler access are deny-by-default except for
  exact supervisor channels.
- macOS uses a supervisor-owned ephemeral helper VM or equivalent kernel-enforced
  containment provider with complete fork/exec/exit lineage and no candidate
control of the provider. If the current release cannot provide that boundary,
  the adapter is `unsupported`; process-group polling is not a fallback.

Candidate code cannot ask a process that is outside the boundary to execute work.
Every spawn-capable IPC/network endpoint is either unreachable or belongs to a broker
that is itself created inside and accounted by the same provider. A pre-existing
broker can never be added to the trusted closure after candidate start. Any endpoint
policy miss, inherited external handle, broker delegation, or unaccounted side-effect
producer invalidates the run even when the process boundary later becomes empty.

At timeout the runtime first closes candidate stdout/stderr ingestion, marks the
result fail-closed, and asks the provider to kill the entire boundary. Linux uses
`cgroup.kill`, waits for `cgroup.events populated=0`, and reaps through namespace
PID 1; Windows closes/terminates the Job and waits for zero live processes; the
macOS provider destroys the helper boundary and proves zero live lineage. Encoding
is forbidden until the ordered event ledger has no unaccounted process, no open
candidate output pipe, no event loss, and all reaping is complete.

Any boundary creation failure, late attachment, event gap/drop/overflow, new child
after the kill epoch, nonempty boundary, unreaped descendant, or output after the
kill receipt produces `hook_error: batch_deadline_exceeded` and no success evidence.
The proof attestation binds the provider record and descendant-ledger Merkle root.

Required negative fixtures include `setsid`, double-fork, daemon reparenting,
fork/exec during termination, fork bomb at the process limit, inherited output FD,
user-systemd/D-Bus/launchd/service-manager or same-user-daemon spawn requests,
SCM_RIGHTS/broker socket acquisition, delayed output, nested-job breakaway,
namespace/cgroup escape, event overflow, and unreaped zombie. Each must finish within
the outer deadline with an empty boundary and zero late output/side effects.

## 2. Executable-memory integrity (B-028)

The pre-resume loader ledger in `tech.md` is necessary but not sufficient: approved
code pages must also be protected from transient patch-and-restore attacks. The
execution boundary therefore enforces a closed executable-memory policy from the
first instruction through candidate kill/reap.

1. Neither candidate credentials nor any untrusted process outside the boundary can
   open or write candidate/supervisor memory. Linux uses a unique disposable identity,
   non-dumpable targets, private restricted proc, capability removal, seccomp, and an
   LSM target-side policy that allows only the authenticated supervisor; it denies
   inbound and outbound `ptrace`, `process_vm_writev`, `/proc/<pid>/mem`, debugfs, and
   perf/BPF injection. The supervisor probes and attests denial from an independent
   same-user process before the candidate event.
   macOS denies task ports, `task_for_pid`, Mach VM write APIs, debugger entitlements,
   and dynamic-code exceptions in both directions. Windows removes `SeDebugPrivilege`,
   applies target process-object ACLs that deny external VM/debug handles, and audits
   every handle grant. A platform that cannot enforce target-side denial is unsupported.
2. Approved distribution files and loader roots are mounted/read through immutable,
   no-follow identities. Candidate processes have no writable file descriptor or
   writable filesystem path to any approved executable backing object.
3. W^X is mandatory. Anonymous executable pages, RWX mappings, and executable
   transitions from any candidate-writable or private-COW mapping are denied. Before
   resume, the trusted loader derives an expected page root from exact approved backing
   bytes, file offset/length, and the relocation manifest whose raw digest and signing
   identity/certificate chain are pinned by H-001 to the approved distribution
   provenance. The proof gate verifies that signature, trust root/transparency or
   registry evidence, and exact digest; self/implementer-signed manifests are rejected.
   The manifest names every relocation type/site/value; unknown, writable-text,
   runtime-selected, or candidate-provided relocation is forbidden. Each map/transition must
   exact-match those relocation-normalized expected bytes before execution, and an
   approved executable page can never subsequently become writable.
4. The append-only ledger records every executable map/protection/load/unload event,
   policy denial, handle grant, sequence number, and loss counter. Unloaded mappings
   remain in the ledger. Final maps/dyld/module state is a cross-check, not the sole
   evidence source.
5. At mapping, every protection transition, the native block event, and after candidate
   freeze, the trusted supervisor compares each executable page with its expected
   backing+offset+relocation bytes and hashes the verified view. The page/root manifest
   binds mapping address, backing identity, offset, relocation-manifest digest, expected
   root, and observed root. Any COW divergence, mismatch, or unreadable page fails closed.

The supervisor attestation binds containment policy/provider digest, privilege and
mount/handle inventory, denial counters, loader ledger root, executable-page roots,
and final snapshot. The H-001 decision must name a platform provider capable of the
whole contract; partial enforcement is `unsupported`.

Required semantic negatives include inbound and outbound attempts using `ptrace`,
`/proc/<pid>/mem`, `process_vm_writev`, Mach task/VM writes, Windows process-memory
handles, writable backing files, private writable COW then executable, unapproved or
malformed relocation, RWX, executable `mprotect`, patch-then-restore, load-then-unload,
anonymous executable memory, and event/denial-log loss. A fixture passes only when the
attempted run cannot produce accepted proof.

## 3. Verified-file identity and receipt state machine (B-025)

### 3.1 Identity model

Every receipt records `base_presence` as the closed enum `present | absent`. It also
records a canonical component-walk result and a no-follow parent-directory identity:
device/volume, inode/file ID, generation where available, owner, mode/ACL digest, and
directory-entry name. A present file additionally records target device/volume,
inode/file ID, generation, type, link count, owner, mode/ACL digest, size, and raw-byte
SHA-256. An absent file has no invented empty bytes/mode/owner.

The verifier opens the parent directory with no-follow semantics and retains that
handle through candidate observation, native probe, evidence commit, and final
observation. For a present candidate it also retains a no-follow target handle.
Every re-resolution of the path must return the same parent and target identities as
the held handles, in addition to exact bytes/ownership/mode. A byte-identical inode
replacement, parent-directory swap, symlink, hard-link ambiguity, mount change,
rename, or identity-generation change is `partial/needs_human`.

A loss-detecting filesystem watcher covers the held parent/target from the first
candidate observation until the final post-evidence observation. Write/rename/link/
delete events, watcher overflow, or an unexplained sequence gap unconditionally
invalidate that activation epoch, even if a later re-read finds identical bytes and
identity. A no-follow re-read is diagnostic only and cannot rehabilitate the epoch.
Manual evidence binds both identity tuples, held-handle observation digests, a
zero-mutation watcher sequence/root, and the pre/post/final reads. It is point-in-time
evidence: check, doctor, runtime use, and proof collection start a new zero-mutation
epoch and revalidate identity and digest before relying on it.

### 3.2 Receipt states

A 0600 receipt in a 0700 VibeGuard state directory has a unique ID, monotonically
increasing generation, and state `planned`, `activating`, `publishing`, `completed`,
or `consumed`. It binds target, parent identity, base presence/identity, candidate identity/digest,
apply operation, failure-reverse operation, clean operation, preserved entries, and
all operation digests. Raw bytes and diffs remain local and never enter logs or proof
artifacts.

The state enum is closed. The only forward path is
`planned → activating → publishing → completed → consumed`; retry creates a new
generation rather than skipping a state. The literal state `active`, a direct
`activating → completed` transition, and evidence that omits publishing/completion
records are schema errors rejected by setup, check, doctor, runtime, proof, and recovery.

Every install, verify, recovery, clean, and runtime evidence consumer takes the same
kernel-held exclusive per-target state lock before reading generation state. The lock
inode is stable in the 0700 state directory and cannot be replaced; crash releases it.
Under that lock, a writer snapshots the current pointer as expected generation+digest
(or expected absence). Any publish/consume operation is a compare-and-swap that first
re-reads and exact-matches that expected pair; mismatch rejects the stale operation and
cannot consume either receipt. Atomic replacement without this comparison is invalid.

An existing completed receipt cannot be overwritten by a planned update. Probe success
creates and fsyncs an immutable `activating` bundle containing the receipt, probe result,
and watcher epoch so far. With the watcher still running, the verifier acquires a
declared kernel-enforced `target_mutation_exclusion_v1` against the held parent/target
identities. It denies write/truncate, writable mmap, rename/link/unlink, mount replacement,
and metadata mutation by every process, including pre-existing descriptors/handles;
advisory locks, ordinary POSIX leases, ACL-only checks, or watcher-only detection are
insufficient. Linux requires an LSM/fanotify-permission or equivalent mandatory inode
policy, Windows requires a minifilter/mandatory handle policy, and macOS requires an
equivalent kernel provider. A platform unable to deny every route is unsupported.

The loss-detecting watcher stays continuous across exclusion acquisition and the whole
publication epoch. The provider record binds kind/version, policy digest, held identities,
start epoch, pre-existing-writer closure, denied-attempt ledger, loss counters, and an
atomic durable release receipt. Any write attempt—even when denied—watcher/provider gap,
identity drift, or policy loss invalidates the generation. Under the exclusion the
verifier drains the final pre-CAS barrier, requires zero mutation/loss, performs the
held-handle/no-follow observation, and fsyncs an immutable `publish_intent` binding those
results and the evidence payload.
The writer may then CAS the current pointer from the expected generation+digest to the
exact intent with state `publishing` and fsync the directory. This pointer is durable
pending state, never completed evidence; every consumer must reject it.

Still under both locks, the publisher drains a post-CAS watcher barrier and repeats
the held-handle read. On any event, gap, or drift it CASes the exact publishing pointer
to a durable invalid tombstone and fsyncs before lock release. Only a clean result may
create and fsync an immutable `publish_completion` binding the publishing pointer/intent
digest, both barrier roots, final reads, target identities, and evidence digest. The
completion file plus directory are fsynced while exclusion remains enforced. The
provider then performs one atomic `release_and_record` operation that removes the
mandatory policy and durably persists a release receipt binding the completion digest,
final watcher/provider sequence, zero denied attempts/gaps, and exact identities. The
generation stays `publishing` until this operation succeeds. Only an exact pointer,
intent, completion marker, and release receipt makes it `completed`; no missing, partial,
or orphan record is completed. Consumers cannot take the per-target lock until the
publisher finishes release-and-record and releases that lock.

Pointer presence alone never authorizes use. While holding the same target lock, every
consumer first exact-matches a completed pointer/intent/marker/release tuple, drains its new
watcher epoch past a barrier taken after that read,
revalidates held parent/target identity and bytes, and re-reads the unchanged pointer.
Any mutation, gap, target drift, or pointer/marker change rejects the generation before
host use/proof. Because every consumer takes the same lock, publishing state is never
acceptable evidence. The bundles remain durable for the lifetime of completed evidence.

Recovery takes the target lock and enumerates immutable bundles, pointer, completion,
and tombstone records.
An unpointed `activating` bundle is never assumed completed or consumed: retry must open
new held identities, run a fresh zero-mutation watcher epoch and native probe, and
either create/commit a new generation or retain the orphan with `needs_human` and the
exact user reverse. Only an exact completed pointer/intent/marker/release tuple may enter the
normal consumer revalidation path. A pointer naming an activating/intent record without
completion follows the incomplete-publication path below. Missing, torn, duplicate,
or conflicting records/CAS expectations are `needs_human`; no evidence is published and
the prior receipt is not consumed. Any `publishing` pointer lacking an exact durable
completion marker and release receipt—including crash after pointer fsync, during the
barrier/completion fsync, or before release-and-record—is non-completed. Recovery must
first CAS it to a durable invalid
tombstone, then open fresh identities and run a new zero-mutation watcher epoch and
native probe in a new generation; restored bytes cannot complete the old probe. An
orphan completion/release record is also rejected. Supersession consumes the old receipt only
after the new completion tuple is durable and exact; every earlier crash leaves it
unconsumed.

For a present base, failure-reverse restores the exact base bytes/semantics; clean
restores the original unmanaged clean base carried through superseding generations.
For an absent base, both operations are an exact-target deletion instruction for the
user, not creation of an empty file. VibeGuard never writes or deletes the host target.

After user-applied deletion, the verifier uses the retained parent handle and
no-follow `fstatat`/platform equivalent to require the entry to remain absent across
two bounded observations and the filesystem-watcher interval. It then performs
host-native discovery to prove the VibeGuard registration is absent. There are no
base bytes to parse. Parent identity drift, target recreation, late old-FD write,
watcher loss, or a remaining managed registration is `needs_human`.

For a present-base reverse, the verifier pins the newly restored target identity,
requires exact base bytes/semantics and stable parent/target identities across the
same bounded observations, and confirms the VibeGuard entry is restored/removed as
the receipt specifies. Only then does it invalidate candidate evidence, mark the
receipt consumed, and report `restored` or `not_installed`.

A superseding plan carries two ancestries: immediate rollback base for failed update,
and original unmanaged clean base/presence for later clean. The old completed receipt is
consumed only after the new receipt durably carries both ancestries, its native probe
passes, and the new completion tuple is exact. Failure leaves the old completed receipt
intact. Consumed receipts may then be deleted; planned/activating/publishing/completed
or drifted receipts must remain available with only path+digest shown to the user.

### 3.3 Required fixtures

Positive fixtures cover present-base install/failure reverse/clean, absent-base fresh
install/failure deletion/clean deletion, completed receipt retention, and safe update
supersession, plus crash recovery around intent/pointer/barrier/completion/tombstone
fsync. Negative fixtures cover concurrent installers/recovery/clean, stale expected
generation/digest, early receipt deletion, missing/torn/duplicate pointer or generation,
publishing reuse, exclusion bypass/write attempt/gap, crash before release receipt,
mutation+restore after pointer fsync, orphan completion/release, candidate/receipt drift,
temporary same-inode write-and-restore, byte-identical target replacement, parent
swap, symlink/hard-link/mount change, watcher overflow, partial reverse/delete, target
recreation, delayed old-FD write, and stale evidence used by runtime/proof.

## 4. Closure rule

B-019, B-025, and B-028 implementation and closure gates must consume the applicable
records from this file as one contract. Tests that exercise only process groups,
pathname+bytes, event-time loaded images, or present-file rollback are incomplete.
Any implementation platform lacking a required containment, identity, watcher, or
memory-integrity capability remains explicit `unsupported/needs_human`; it cannot
silently downgrade and cannot provide third-host proof.
