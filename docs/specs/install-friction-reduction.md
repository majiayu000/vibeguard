# Spec: Reduce install friction (prebuilt binaries + opt-in scheduler)

- Status: Draft
- Date: 2026-06-02
- Owner: @majiayu000
- Related: README "Install in 30 seconds", `scripts/setup/install.sh`, `vibeguard-runtime/`

## 1. Problem

The only documented install path compiles the Rust runtime from source, which makes
the barrier high for VibeGuard's actual audience (Claude Code / Codex users, mostly
JS/TS/Python/Go developers who often have no Rust toolchain).

Verified facts (this repo, 2026-06-02):

- `scripts/setup/install.sh:184-212` requires `cargo` and runs `cargo build --release`;
  it is **fail-closed** — no cargo or a failed build exits 2, with no fallback.
- `install.sh:135` also requires `python3` (hook helpers + cargo-metadata parsing).
- Neither the `v1.1.0` nor `v1.1.1` GitHub release ships any binary asset; there is no
  prebuilt-binary download path anywhere in `install.sh`.
- No `package.json` (no npm path) and no root `Dockerfile`.
- `install.sh:265-289` auto-installs a **scheduled GC** job (launchd on macOS, systemd
  on Linux; Sunday 03:00) as part of the default install — a system-level side effect
  the user did not opt into.

Net effect: "git clone + bash setup.sh" needs a full Rust toolchain **and** Python 3,
then silently registers a system scheduler entry. Compared with `npm i -g` / `brew
install` / `curl | sh` (prebuilt binary) installs in the same category, this is a
meaningful adoption blocker.

## 2. Goals / Non-goals

**Goals**
- G1: A user on a supported platform can install **without a Rust toolchain** — the
  matching prebuilt `vibeguard-runtime` binary is downloaded and verified.
- G2: Source build (`cargo`) remains a first-class, automatic fallback for unsupported
  platforms, offline installs, and `--build-from-source`.
- G3: Scheduled GC becomes **opt-in**; default install adds no system scheduler entry.
- G4: Binary downloads are integrity-verified (SHA-256) and version-pinned to the repo's
  release tag, so the binary always matches the hook contract it ships with.

**Non-goals**
- Windows prebuilt binaries (hooks run through bash; track separately — see §7).
- Removing the Rust runtime or its `python3` hook helpers (separate roadmap, §3.5).
- Publishing to npm / PyPI / Homebrew (possible later; out of scope here).

## 3. Design

### 3.1 Release pipeline (new CI workflow)

Add `.github/workflows/release.yml`, triggered on tag push `v*`:

- Build matrix (deps are pure-Rust — `serde_json` + `regex` — so static/cross builds are clean):
  | target | runner | notes |
  |---|---|---|
  | `aarch64-apple-darwin` | `macos-14` | native |
  | `x86_64-apple-darwin` | `macos-14` | `rustup target add` + `--target` |
  | `x86_64-unknown-linux-musl` | `ubuntu-latest` | fully static |
  | `aarch64-unknown-linux-musl` | `ubuntu-latest` | via `cross` or musl toolchain, static |
- Each job: `cargo build --release --target <t>`, rename output to
  `vibeguard-runtime-<target>`, compute SHA-256.
- A final job uploads all binaries + a single `SHA256SUMS` file to the GitHub Release
  for that tag (`gh release upload` or `softprops/action-gh-release`).
- Reuse the existing toolchain/style from `.github/workflows/ci.yml`; pin Rust to a
  stable version that supports `edition = "2024"` (≥ 1.85).

### 3.2 `install.sh`: download-with-verify, cargo fallback

Replace the unconditional `cargo build` block (`install.sh:184-212`) with:

1. Resolve `target` from `uname -s`/`uname -m` → one of the matrix triples.
2. Resolve the pinned runtime version (see §3.4) → release tag `vN.N.N`.
3. If target is supported and not `--build-from-source`:
   - Download `vibeguard-runtime-<target>` and `SHA256SUMS` from the release
     (`gh release download` if `gh` present, else `curl -fsSL`).
   - **Verify SHA-256** against `SHA256SUMS`; on mismatch → abort (do not silently
     fall back to an unverified binary).
   - On verify success: `install -m 0755` into `~/.vibeguard/installed/bin/vibeguard-runtime`.
4. If download fails (offline / 404 / unsupported target) **or** `--build-from-source`:
   - Fall back to the current `cargo build --release` path unchanged.
   - If `cargo` is also unavailable here, fail closed with a clear message naming both
     the unsupported target and the `--build-from-source` requirement.

Flags: `--build-from-source` (force compile), `--runtime-version <tag>` (override, for
testing). The atomic snapshot swap (`install.sh:213-228`) is unchanged.

### 3.3 Scheduled GC → opt-in

- Default install: **do not** install launchd/systemd (`install.sh:265-289`). Print one
  line: "Scheduled GC not installed (run `setup.sh --with-scheduler` to enable)".
- Add `--with-scheduler` to opt in to the existing launchd/systemd path.
- `--check` reports scheduler as INFO (not WARN/MISSING) when absent.
- `--clean` continues to remove any previously installed scheduler entry.
- Document that without the scheduler, log GC runs via `/vibeguard:gc` or
  `scripts/gc/gc-scheduled.sh` on demand.

### 3.4 Runtime version pinning

The binary's behavior must match the hooks it ships with. Add a single source of truth:
`vibeguard-runtime/VERSION` (e.g. `1.1.2`), bumped with each release tag and asserted in
CI to equal the tag. `install.sh` reads it to know which release asset to download.
(Alternative: `git describe --tags`; rejected — installs from a non-tag checkout would
have no matching asset, so an explicit VERSION file is more robust.)

### 3.5 (Roadmap, not in this spec's scope) Single-runtime consolidation

Folding the Python hook helpers (`hooks/_lib/*.py`) into `vibeguard-runtime` would drop
the `python3` runtime dependency, leaving a single self-contained binary and enabling a
true `curl | sh` one-liner. Tracked as a follow-up; large and out of scope here.

## 4. Security considerations

- Binary integrity: SHA-256 verification against the release `SHA256SUMS` is mandatory;
  a mismatch aborts (never silently uses an unverified binary). Aligns with the project's
  own supply-chain stance (SEC-12 / SEC-13).
- Provenance (stretch): add build provenance / cosign attestation in a later iteration.
- The download path must not pipe remote content into a shell; only fetch the binary +
  checksum file and verify before executing.

## 5. Acceptance criteria

- AC1: On `aarch64-apple-darwin` with **no Rust installed**, `bash setup.sh` completes
  and `setup.sh --check --strict` exits 0 (HEALTHY), using a downloaded binary.
- AC2: Tampering with the downloaded binary (or a wrong checksum) makes install abort
  with a verification error — no install proceeds.
- AC3: `bash setup.sh --build-from-source` still works and uses `cargo`.
- AC4: Offline / unsupported-arch install with `cargo` present falls back to source build
  and succeeds.
- AC5: Default install adds **no** launchd/systemd entry; `--with-scheduler` adds it;
  `--clean` removes it.
- AC6: A tag push publishes 4 platform binaries + `SHA256SUMS` to the Release.
- AC7: README install section reflects the no-Rust default path and the prerequisites
  matrix.
- AC8: A release tag whose `vibeguard-runtime/VERSION` does not match the tag fails
  before any release asset is published.
- AC9: The binary download path succeeds when `gh` is absent but `curl` is present.

## 6. Work breakdown (→ issues)

1. Release CI workflow (cross-compile + checksums + upload) — §3.1.
2. `install.sh` download-with-verify + cargo fallback + `VERSION` pin — §3.2, §3.4.
3. Scheduled GC opt-in (`--with-scheduler`, default off) — §3.3.
4. README + Codex/Claude install docs update — §5/AC7.
5. (Roadmap) Investigate single-runtime consolidation — §3.5.

## 7. Risks & open questions

- musl `aarch64-linux` cross-build reliability — may need `cross` or a prebuilt
  cross-toolchain; verify in CI before relying on it.
- `edition = "2024"` requires a recent stable Rust on all runners — pin explicitly.
- Windows: hooks run via bash; decide whether a `x86_64-pc-windows-msvc` binary is needed
  or whether WSL/git-bash callers can reuse the linux binary (likely a separate issue).
- Existing installs built from source: the next `setup.sh` run will switch them to the
  downloaded binary; `--check` drift detection must treat that as expected, not BROKEN.
