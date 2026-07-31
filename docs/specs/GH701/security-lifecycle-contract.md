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
counters. The runtime rejects an undeclared provider or a platform on which these
properties cannot be proved.

- Linux uses an unprivileged candidate inside a dedicated PID namespace and cgroup
  v2 subtree. The namespace init is a subreaper; the candidate lacks cgroup,
  namespace, mount, ptrace, and privilege-escalation capabilities. `setsid()` and
  double-fork may change process relationships but cannot leave the cgroup/PID
  namespace. The supervisor records fork/clone/exec/exit from boundary creation.
- Windows uses a Job Object with kill-on-close, breakaway disabled, a restricted
  token without debug privilege, and completion-port accounting. Nested jobs or
  child-process policies must not enable breakaway.
- macOS uses a supervisor-owned ephemeral helper VM or equivalent kernel-enforced
  containment provider with complete fork/exec/exit lineage and no candidate
  control of the provider. If the current release cannot provide that boundary,
  the adapter is `unsupported`; process-group polling is not a fallback.

At timeout the runtime first closes candidate stdout/stderr ingestion, marks the
result fail-closed, and asks the provider to kill the entire boundary. Linux uses
`cgroup.kill`, waits for `cgroup.events populated=0`, and reaps through namespace
PID 1; Windows closes/terminates the Job and waits for zero active processes; the
macOS provider destroys the helper boundary and proves zero live lineage. Encoding
is forbidden until the ordered event ledger has no unaccounted process, no open
candidate output pipe, no event loss, and all reaping is complete.

Any boundary creation failure, late attachment, event gap/drop/overflow, new child
after the kill epoch, nonempty boundary, unreaped descendant, or output after the
kill receipt produces `hook_error: batch_deadline_exceeded` and no success evidence.
The proof attestation binds the provider record and descendant-ledger Merkle root.

Required negative fixtures include `setsid`, double-fork, daemon reparenting,
fork/exec during termination, fork bomb at the process limit, inherited output FD,
delayed output, nested-job breakaway, namespace/cgroup escape, event overflow, and
unreaped zombie. Each must finish within the outer deadline with an empty boundary
and zero late output/side effects.

## 2. Executable-memory integrity (B-028)

The pre-resume loader ledger in `tech.md` is necessary but not sufficient: approved
code pages must also be protected from transient patch-and-restore attacks. The
execution boundary therefore enforces a closed executable-memory policy from the
first instruction through candidate kill/reap.

1. Candidate credentials and capabilities cannot open or write another process's
   memory. Linux denies `ptrace`, `process_vm_writev`, `/proc/<pid>/mem`, debugfs,
   perf/BPF injection, and writable procfs aliases using capability removal,
   seccomp/LSM policy, a private restricted proc mount, and parent-death isolation.
   macOS denies task ports, `task_for_pid`, Mach VM write APIs, debugger entitlements,
   and dynamic-code exceptions. Windows removes `SeDebugPrivilege`, denies
   PROCESS_VM_WRITE/PROCESS_VM_OPERATION/debug handles, and audits handle grants.
2. Approved distribution files and loader roots are mounted/read through immutable,
   no-follow identities. Candidate processes have no writable file descriptor or
   writable filesystem path to any approved executable backing object.
3. W^X is mandatory. Anonymous executable pages and RWX mappings are denied.
   `mprotect`/equivalent transitions to executable are mediated and must identify an
   H-001-approved immutable backing object; approved executable pages cannot become
   writable. Any denied attempt invalidates the run rather than merely logging it.
4. The append-only ledger records every executable map/protection/load/unload event,
   policy denial, handle grant, sequence number, and loss counter. Unloaded mappings
   remain in the ledger. Final maps/dyld/module state is a cross-check, not the sole
   evidence source.
5. At the native block event and after candidate freeze, the trusted supervisor
   hashes the executable-page view and binds its Merkle root to the backing-object
   identities and continuous ledger. A mismatch or unreadable page fails closed.

The supervisor attestation binds containment policy/provider digest, privilege and
mount/handle inventory, denial counters, loader ledger root, executable-page roots,
and final snapshot. The H-001 decision must name a platform provider capable of the
whole contract; partial enforcement is `unsupported`.

Required semantic negatives include successful and denied attempts using `ptrace`,
`/proc/<pid>/mem`, `process_vm_writev`, Mach task/VM writes, Windows process-memory
handles, writable backing files, RWX, executable `mprotect`, patch-then-restore,
load-then-unload, anonymous executable memory, and event/denial-log loss. A fixture
passes only when the attempted run cannot produce accepted proof.

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
delete events, watcher overflow, or an unexplained sequence gap require a full
no-follow re-read and invalidate activation on any mismatch. Manual evidence binds
both identity tuples, held-handle observation digests, watcher sequence/root, and
the pre/post/final reads. It is point-in-time evidence: check, doctor, runtime use,
and proof collection revalidate identity and digest before relying on it.

### 3.2 Receipt states

A 0600 receipt in a 0700 VibeGuard state directory has a unique ID, monotonically
increasing generation, and state `planned`, `active`, or `consumed`. It binds target,
parent identity, base presence/identity, candidate identity/digest, apply operation,
failure-reverse operation, clean operation, preserved entries, and all operation
digests. Raw bytes and diffs remain local and never enter logs or proof artifacts.

An existing active receipt cannot be overwritten by a planned update. Probe success
first fsyncs the candidate receipt as active, then atomically publishes evidence that
binds its exact digest. The receipt remains durable for the full lifetime of that
active evidence.

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
and original unmanaged clean base/presence for later clean. The old active receipt is
consumed only after the new receipt durably carries both ancestries, its native probe
passes, and evidence atomically points to the new active digest. Failure leaves the
old active receipt intact. Consumed receipts may then be deleted; planned/active or
drifted receipts must remain available with only path+digest shown to the user.

### 3.3 Required fixtures

Positive fixtures cover present-base install/failure reverse/clean, absent-base fresh
install/failure deletion/clean deletion, active receipt retention, and safe update
supersession. Negative fixtures cover early receipt deletion, missing or duplicate
generation, candidate/receipt drift, byte-identical target replacement, parent swap,
symlink/hard-link/mount change, watcher overflow, partial reverse/delete, target
recreation, delayed old-FD write, and stale evidence used by runtime/proof.

## 4. Closure rule

B-019, B-025, and B-028 implementation and closure gates must consume the applicable
records from this file as one contract. Tests that exercise only process groups,
pathname+bytes, event-time loaded images, or present-file rollback are incomplete.
Any implementation platform lacking a required containment, identity, watcher, or
memory-integrity capability remains explicit `unsupported/needs_human`; it cannot
silently downgrade and cannot provide third-host proof.
