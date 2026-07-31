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

- Linux uses a provider-owned, per-invocation destructible microVM outside the candidate
  trust domain. Inside it, an unprivileged candidate uses a dedicated PID namespace and
  cgroup v2 subtree plus private user, mount, IPC, and network namespaces. The namespace
  init is a subreaper; a minimal private root/proc view exposes no host service-manager,
  D-Bus, container-daemon, agent, or same-user broker socket. All inherited handles
  except closed supervisor channels are removed, and socket/SCM_RIGHTS policy cannot
  acquire an external broker endpoint. The candidate lacks cgroup, namespace, mount,
  ptrace, and privilege-escalation capabilities. `setsid()` and double-fork may change
  process relationships but cannot leave the guest. The outer VM exposes no passthrough
  device, host-writable mount, network, or blocking candidate-controlled host backend;
  its control plane records create/destroy receipts and is H-001-bound. The supervisor
  records fork/clone/exec/exit and denied external-endpoint attempts from boundary creation.
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

At timeout the runtime first closes candidate stdout/stderr ingestion and marks the
result fail-closed. Linux gives inner `cgroup.kill`/subreaper cleanup a bounded
sub-deadline; if any guest task remains—including uninterruptible sleep—the host control
plane destroys the outer microVM by the response deadline, independently of guest reap.
Windows closes/terminates the Job and macOS destroys its helper boundary under the same
bounded provider contract. Encoding waits for closed host-side pipes, the ordered ledger,
and a provider destroy/zero-side-channel receipt, but never for an uninterruptible guest
task after VM destruction. A platform unable to prove bounded outer teardown is unsupported.

Any boundary creation failure, late attachment, event gap/drop/overflow, new child
after the kill epoch, nonempty boundary, unreaped descendant, or output after the
kill receipt produces `hook_error: batch_deadline_exceeded` and no success evidence.
The proof attestation binds the provider record and descendant-ledger Merkle root.

Required negative fixtures include `setsid`, double-fork, daemon reparenting,
fork/exec during termination, fork bomb at the process limit, inherited output FD,
user-systemd/D-Bus/launchd/service-manager or same-user-daemon spawn requests,
SCM_RIGHTS/broker socket acquisition, delayed output, nested-job breakaway,
namespace/cgroup escape, event overflow, unreaped zombie, uninterruptible guest I/O, and
inner cgroup non-emptiness. Each must finish within the outer deadline with a destroyed
outer boundary, closed side-effect channels, and zero late output; inner reap alone is
not accepted as the bounded-termination authority.

## 2. Executable-memory integrity (B-028)

The pre-resume loader ledger in `tech.md` is necessary but not sufficient: approved
code pages must also be protected from transient patch-and-restore attacks. The
execution boundary therefore enforces a closed executable-memory policy from the
first instruction through provider-confirmed boundary destruction and host-channel closure.

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

### 2.1 Candidate-independent confidentiality boundary

Contiguous sentinel search is diagnostic defense-in-depth, not non-disclosure evidence.
Before candidate start, an H-001-approved high-side supervisor outside the execution VM
parses raw host input, configuration, credentials, and payload. It treats unknown/free-
form fields as secret by default and applies a closed, digest-bound declassification
policy. Only explicitly low fields cross a one-way typed channel; secret values, secret-
derived digests, reversible encodings, substrings, lengths, keys, and sentinel bytes do
not. Redacted fields become per-run opaque handles that have no guest lookup operation
and are removed from output. If the selected host behavior requires raw high-side data,
that proof mode is unsupported rather than silently exposing it.

The H-001 closed selection exact-pins the high-side supervisor identity and version,
the raw declassification-policy SHA-256, and the raw low-side output-schema SHA-256.
The supervisor attestation and proof gate exact-match all four values before accepting
the typed transcript or any sink. A self-selected, missing, substituted, or drifted
supervisor, policy, or schema is unsupported even when its subjects are internally
consistent.

The candidate has no filesystem, memory, IPC, network, inherited handle, or broker path
to high-side bytes or redaction keys. Its output uses a closed low-side schema; the
supervisor ignores candidate labels, rejects opaque handles/arbitrary byte carriers, and
independently canonicalizes every persisted subject and sink. The attestation binds the
declassification-policy digest, a salted/keyed high-side commitment, candidate-view
digest, typed-channel transcript root, output-schema digest, and final sink manifest.
Byte sentinels may test the boundary but can never replace this access/noninterference
proof. Fixtures include split, reordered, encoded, compressed, encrypted, hashed, and
cross-field/cross-sink reconstruction attempts; candidate access to any high-side source
or any undeclared declassification prevents proof.

### 2.2 Trusted proof time

Freshness derives only from the protected supervisor/provider and attestation issuer,
never from candidate `observed_at`. The signed record binds protected run creation,
supervisor start, native-event monotonic time plus trusted wall-clock mapping, supervisor
finish, attestation issuance, clock-source identity, and fixed maximum skew of 300
seconds. The gate live-reads the protected run metadata, verifies the attestation
integrated/issuance time, requires those trusted sources to agree within the bound, and
exact-matches candidate `observed_at` to the trusted event time within the same skew.
H-001 exact-pins the trusted clock-source identity and monotonic-to-wall mapping-policy
SHA-256; the gate rejects a self-selected, substituted, or drifted clock or mapping even
when its signed times fall within 300 seconds of later attestation issuance.
The seven-day window is calculated from trusted event and issuance times to current
protected gate time; a later witness cannot refresh an old run. Missing time authority,
future/skewed candidate time, delayed replay, archived subjects with a fresh witness, or
clock disagreement fails closed.

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

The H-001-selected lifecycle provider runs outside the same-user process trust domain
and owns the authoritative append-only journal, monotonic generations, transaction CAS,
target leases/exclusions, sealed recovery payloads, and signing key. Its trust-root digest
is an H-001 field. H-001 also exact-pins lifecycle provider kind/version, a transition
policy digest covering generation/CAS/lease/exclusion/state/abort/reverse/retirement
semantics, and a caller-authentication policy digest covering measured callers and every
provider IPC entrypoint. Arbitrary same-user processes cannot read the key/journal or
invoke an authority-conferring transition. The provider independently verifies the
pinned policies, watcher, probe, identity, and transaction expectations. A missing,
self-selected, substituted, or drifted provider/policy, or a platform without this
boundary, is unsupported.

Each authoritative receipt has a unique ID and state `planned`, `activating`,
`publishing`, `completed`, `consumed`, or terminal `aborted`. Canonical records bind the
provider sequence/journal root, previous-record digest, decision digest, transaction ID,
target/base/candidate identities, operations, evidence roots, and provider signature.
Base bytes/diffs remain host-local only in provider-sealed recovery storage and never
enter logs/proof. A 0600 receipt/pointer/bundle in a 0700 user state directory is merely
an untrusted cache: it may aid display but never authorize, recover, or retire anything.
Every read exact-matches a fresh nonce-bound provider snapshot and signature; journal
unavailability or cache/journal mismatch fails closed with no cache fallback.

The state enum is closed. The success path is
`planned → activating → publishing → completed → consumed`; failure may transition
`activating` or `publishing` to terminal `aborted`, which has no outgoing edge. The sole
`planned → aborted` edge is the verified `failed_reverse_release_and_record` commit;
generic abort preserves `planned`. Retry creates a new generation rather than skipping a state. The literal state `active`, a direct
`activating → completed` transition, and evidence that omits publishing/completion
records are schema errors rejected by setup, check, doctor, runtime, proof, and recovery.

Every install, verify, recovery, clean, and runtime evidence consumer takes the same
provider-owned exclusive per-target lease before reading authoritative generation state;
a user-directory lock is advisory defense-in-depth only. Under that lease, a writer
snapshots the journal's current pointer as expected generation+digest
(or expected absence). Any publish/consume operation is a compare-and-swap that first
re-reads and exact-matches that expected pair; mismatch rejects the stale operation and
cannot consume either receipt. Supersession is the sole multi-record form: its current-
pointer expectation is N+1 publishing while a separate immutable-receipt CAS expectation
names predecessor N completed. Atomic replacement without these comparisons is invalid.

An existing completed receipt cannot be overwritten by a planned update. Probe success
causes the provider to append an authenticated immutable `activating` record containing
the receipt, probe result, and watcher epoch; any fsynced user-directory bundle is only
its signed mirror. With the watcher still running, the verifier acquires a
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
held-handle/no-follow observation, and asks the journal to persist an authenticated
immutable `publish_intent` binding those results and the evidence payload.
The exclusion provider is authorization-conferring: the H-001 closed selection must
approve its kind, version, and raw policy digest in addition to the execution provider.
The lifecycle gate exact-matches those fields and binds the decision-record digest into
the provider record, intent, completion, and every success/abort/use/consume release record.
Self-selected, missing, substituted, or drifted provider/policy fields are unsupported.
The writer may then CAS the current pointer from the expected generation+digest to the
exact intent with state `publishing` in the provider journal; a local directory mirror
may then be fsynced. This journal pointer is durable pending state, never completed
evidence; every consumer must reject it.

Still under provider lease and exclusion, the publisher drains a post-CAS watcher barrier
and repeats the held-handle read. Only a clean result may cause the provider to append an
authenticated immutable `publish_completion` binding the publishing pointer/intent digest,
both barrier roots, final reads, target identities, and evidence digest. Any local mirror
is fsynced only after provider authentication and while exclusion remains enforced. The
provider then performs one journaled atomic `release_and_record` transaction. At one
durable linearization point it (1) CASes the exact publishing generation/digest,
(2) persists a receipt and pointer carrying literal `state: completed`, exact ancestry,
intent/completion digests, and the provider release receipt, and (3) removes the
mandatory policy. The release receipt binds final watcher/provider sequence, zero denied
attempts/gaps, and exact identities. Consumers accept only this completed pointer/receipt
tuple; they never reinterpret a publishing pointer. A provider unable to make all three
effects atomic is unsupported.

Every non-success path after exclusion acquisition—including denied write, gap, drift,
timeout, cancellation, crash recovery, orphan intent/completion, stale CAS, or policy
error—must instead run journaled atomic `abort_release_and_record`. At one durable point
it records a closed abort reason and provider/watcher roots, preserves any predecessor
completed receipt, preserves any `planned` receipt, CASes an owned activating/publishing
receipt to terminal `aborted` when its exact expectation still matches, CASes an owned
publishing pointer to a non-state tombstone, and otherwise records stale mismatch without
changing current state. It persists the exclusion release receipt and removes the
mandatory policy. It is idempotent by exclusion ID plus generation/digest. No completed
evidence is produced. On owner death or bounded,
non-renewable expiry, the provider itself executes the same `abort_release_and_record`;
policy removal and its durable abort/release event are indivisible. If the caller-side
abort fails, VibeGuard remains fail-closed while the provider completes that transaction
by the deadline, so the host target cannot remain locked indefinitely.
Consumers cannot take the provider lease until a success or abort release receipt exists.

Every activating/publishing abort records `abort_kind: publication_aborted`,
`reverse_status: pending`, exact candidate/base ancestry, and `retirement_allowed: false`;
the provider retains the sealed recovery payload. Neither the terminal state nor a local
tombstone proves reversal, so the receipt/payload cannot be retired until the protected
verified-reverse transaction below commits.

Pointer presence alone never authorizes use. Any consumer that will cause a host to load
or use the target—including runtime and proof—takes the provider lease, starts a new watcher,
and acquires a fresh H-001-approved mandatory exclusion before its first completed-tuple
read. It exact-matches the literal completed pointer/receipt/intent/marker/publication-
release tuple, drains a barrier, revalidates held parent/target identity and bytes, and
re-reads the unchanged pointer while exclusion remains enforced. Inspection-only check
or doctor may report this state but cannot authorize later host use.

The host must then fully acquire and parse an immutable exact-byte snapshot while the
lease, watcher, and exclusion remain held. A trusted provider returns a durable
`host_acquisition_ack` binding the host process measurement, acquisition event/nonce,
sealed handle or snapshot identity, exact loaded bytes/digest, completed tuple digest,
and watcher/provider roots. Deferred or lazy target reads are unsupported. After that
ack, the consumer drains a post-acquisition barrier, revalidates identities/bytes, and
CAS re-reads the same completed pointer. Only a clean result may atomically
`use_release_and_record`: persist the acquisition/release receipt and remove the consumer
exclusion. The adapter may release host dispatch/side effects only after that commit;
failure discards the snapshot. Any denied attempt, event, gap, drift, stale CAS, missing/mismatched ack, crash,
or timeout instead runs the same durable abort-release protocol and emits no accepted
host-use/proof evidence; owner-death/expiry preserves host liveness. The use receipt does
not change the lifecycle state to `consumed`. Because publication and every host use have
separate gap-free exclusion epochs, release-to-acquisition TOCTOU cannot authorize altered
bytes. Publishing remains unacceptable evidence, and bundles remain durable for the
lifetime of completed evidence.

For protected proof, the exact `host_acquisition_ack` and `use_release_and_record`
receipt bytes are mandatory content-addressed handoff subjects. Their manifest roles and
digests are validated by fixed **schemas/gh701-host-acquisition-ack.schema.json** and
**schemas/gh701-use-release-receipt.schema.json** bytes. Both paths belong to
`resolved_trust_paths`; H-001 exact-binds their protected-main raw-byte digests. Each
schema permits only fragment `$ref` targets inside its own pinned bytes; remote, relative,
absolute, file, dynamic, or resolver-fetched external references are schema errors. The supervisor
attestation exact-binds both to the same event, nonce, measured host process, completed
tuple, provider journal trust root/sequence/snapshot digest, watcher roots, and candidate
head. The proof gate rehashes both subjects, verifies every provider signature against the
H-001-selected journal trust root and fresh nonce-bound snapshot, and
exact-matches every binding before `proof_accepted`. A current config digest, self-report,
missing/substituted subject, or ack/release from another event cannot substitute.

Recovery takes the provider lease and reads the authoritative journal snapshot/root,
then reconciles signed local mirrors, completion, abort/tombstone, exclusion status, and
success/abort release records. A local self-consistent tuple without the journal entry is forged.
An unpointed `activating` bundle is never assumed completed or consumed: retry must open
new held identities, run a fresh zero-mutation watcher epoch and native probe, and
either create/commit a new generation or retain the orphan with `needs_human` and the
exact user reverse. Only an exact completed pointer/intent/marker/release tuple may enter the
normal consumer revalidation path. A pointer naming an activating/intent record without
completion follows the incomplete-publication path below. Missing, torn, duplicate,
or conflicting records/CAS expectations are `needs_human`; no evidence is published and
the prior receipt is not consumed. Any `publishing` pointer lacking the atomic completed
receipt/pointer/release tuple is non-completed. Recovery must finish
`abort_release_and_record` (or reconcile the provider owner-death/expiry release event
into the same durable abort record) before opening fresh identities and running a new
watcher epoch/native probe; restored bytes cannot complete the old probe. Unknown release
status remains fail-closed while bounded expiry preserves host liveness. Orphan success/
abort release records are rejected.

For a present base, failure-reverse restores the exact base bytes/semantics; clean
restores the original unmanaged clean base carried through superseding generations.
For an absent base, both operations are an exact-target deletion instruction for the
user, not creation of an empty file. VibeGuard never writes or deletes the host target.

After the user applies a completed-receipt clean/reverse, a failed-probe receipt's
failure-reverse, or a publication-aborted receipt's failure-reverse, the verifier takes
the provider lease, starts a new loss-detecting watcher,
and acquires the H-001-approved mandatory exclusion against the restored target or absent
directory entry before the first bounded observation.
For absent base it uses the retained parent handle and no-follow `fstatat`/equivalent to
require stable absence across two observations and proves host-native unregistration.
For present base it pins the restored target, requires exact original bytes/semantics
and stable parent/target identities across the same observations, and confirms the
receipt-specified restored/unmanaged state. Before the final barrier the provider appends
an authenticated immutable transition intent containing a unique transaction ID,
transition kind, exact starting receipt/pointer generation+digest, exclusion ID, and
verification roots; any user-directory copy is an untrusted signed mirror only.

For a completed receipt, `consume_release_and_record` drains the final watcher/provider
barrier, repeats the held-handle identity+byte read or absence+unregistration proof,
CASes the exact completed generation/digest to `consumed`, persists an idempotent commit
receipt, invalidates candidate evidence, and removes the policy at one durable
linearization point. For a native-probe failure, which never creates a completed receipt,
`failed_reverse_release_and_record` performs the same protected final verification but
CASes the exact `planned` failure receipt to terminal `aborted` and persists the verified
reverse/abort commit receipt with `reverse_status: verified`. For publication-aborted
receipts, atomic `aborted_reverse_release_and_record` exact-matches the authoritative
`aborted` record with pending reverse, persists the same verified evidence and a durable
retirement authorization, invalidates candidate evidence, and releases exclusion while
the lifecycle state remains terminal `aborted`. Neither path can use `consumed` or
authorize host use. Only an exact verified commit may report `restored`/`not_installed`
and later retire sealed receipt data; the signed retirement tombstone remains.

Recovery queries the provider journal by transaction ID. Before linearization, any event,
denied attempt, gap, drift, recreation, remaining registration, stale CAS, crash, or
timeout idempotently abort-releases and leaves the starting completed/planned/aborted receipt
unchanged. After linearization, the exact commit receipt is authoritative: recovery
reconciles the durable `consumed`/`aborted` result and never runs abort or rolls it back.
Unknown outcome remains fail-closed until the provider returns the commit or performs its
pre-commit owner-death/expiry abort; expiry cannot overwrite a committed transaction.

A superseding plan carries immediate rollback and original unmanaged clean ancestries.
After the provider appends an authenticated transaction intent that binds both expected records, its atomic
`supersede_release_and_record` is a multi-record CAS: it exact-matches the
current N+1 publishing pointer/receipt and immutable predecessor N completed receipt,
then at one linearization point persists N+1 as completed/current, persists N as consumed
with exact successor ancestry, and removes the exclusion. A provider lacking multi-record
atomicity is unsupported. A mismatch or pre-commit crash
completes neither effect and leaves N completed; recovery uses the transaction receipt.
Consumed receipts and aborted receipts carrying exact `reverse_status: verified` may
later be retired; all others remain. In particular, `rollback_required: false` is not a
retirement authorization for any publication-aborted receipt and cannot replace the
protected verified-reverse transaction.

`completed → consumed` is the only consume transition. Its atomic CAS/release record binds the
exact completed receipt digest, original clean ancestry/presence, verified restore or
absent-base deletion evidence, and either the clean operation or exact successor
completed generation/digest. Supersession performs the predecessor consume in the same
multi-record new-completion transaction; it does not require N to remain the current pointer.
Direct publishing/abort-to-consumed, missing successor
ancestry, replay, or consuming the predecessor before successor completion is rejected.

### 3.3 Required fixtures

Positive fixtures cover present-base install/failure reverse/clean, absent-base fresh
install/failure deletion/clean deletion, completed receipt retention, and safe update
supersession, plus crash recovery around authenticated journal intent/pointer/barrier/
completion/tombstone append and local-mirror fsync. Success fixtures assert atomic publishing→completed pointer+receipt+release;
abort fixtures cover every phase/reason, idempotent retry, owner death/expiry, durable
abort before release, eventual host writability, and zero completed evidence. Negative
fixtures cover concurrent installers/recovery/clean, stale expected
generation/digest, early receipt deletion, missing/torn/duplicate pointer or generation,
publishing reuse, exclusion bypass/write attempt/gap, crash before release receipt,
mutation+restore after journal pointer commit, orphan completion/release, candidate/receipt drift,
temporary same-inode write-and-restore, byte-identical target replacement, parent
swap, symlink/hard-link/mount change, watcher overflow, partial reverse/delete, target
recreation, delayed old-FD write, and stale evidence used by runtime/proof.
Host-use fixtures require the H-001-approved exclusion, exact immutable acquisition ack,
post-acquisition barrier, CAS pointer re-read, and atomic use-release receipt; they reject
provider/policy drift, a write or restore between tuple read and host acquisition, lazy
reads, missing/mismatched loaded-byte evidence, use-release crash, and permanent lock.
Proof fixtures require authenticated exact ack/use-release subjects bound to the same
event/nonce/process/completed tuple and reject missing, substituted, stale, or cross-event
subjects. Reverse/clean fixtures mutate at every final-observation→consume boundary and
require atomic abort-release with the completed receipt retained.
Transaction fixtures cover failed-probe planned→aborted without completed evidence,
pre/post-linearization consume crashes and idempotent recovery, plus a supersession
multi-record CAS that completes N+1 and consumes N together or does neither. Proof fixtures
also reject missing/untrusted schema paths, schema-byte drift, wrong H-001 digests, every
non-fragment/cross-document reference, and any resolver I/O.
Publication-abort fixtures keep sealed reverse data and retirement disabled through every
denied/gap/stale/crash phase, then require atomic verified reverse before retirement and
reject `rollback_required: false` as a bypass.
Authority fixtures let a same-user attacker replace/replay/delete every local mirror and
call provider IPC with arbitrary payloads; no forged completed/use/consume/retire result
is accepted without the H-001-pinned provider kind/version, transition and caller-auth
policies, fresh signed journal snapshot, and measured approved caller. Proof authority
fixtures likewise reject high-side supervisor/policy/output-schema or trusted-clock/
mapping drift even when the substituted artifacts are self-consistent and signed.
Consume fixtures accept only completed→consumed with exact clean/successor ancestry and
reject every direct, early, replayed, or mismatched transition.

## 4. Closure rule

B-019, B-025, and B-028 implementation and closure gates must consume the applicable
records from this file as one contract. Tests that exercise only process groups,
pathname+bytes, event-time loaded images, or present-file rollback are incomplete.
Any implementation platform lacking required containment, confidentiality, trusted-time,
journal-authenticity, identity, watcher, or memory-integrity capability remains explicit
`unsupported/needs_human`; it cannot
silently downgrade and cannot provide third-host proof.
