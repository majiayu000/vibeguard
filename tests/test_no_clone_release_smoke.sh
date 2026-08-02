#!/usr/bin/env bash
# Structural and executable contract tests for the release-backed GH699 smoke.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="${REPO_DIR}/.github/workflows/release.yml"
CI_WORKFLOW="${REPO_DIR}/.github/workflows/ci.yml"
PASS=0
FAIL=0

pass() {
  printf 'PASS: %s\n' "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAIL=$((FAIL + 1))
}

expect_success() {
  local description="$1"
  shift
  if "$@"; then pass "${description}"; else fail "${description}"; fi
}

expect_failure() {
  local description="$1"
  shift
  if "$@"; then fail "${description}"; else pass "${description}"; fi
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibeguard-no-clone-smoke.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT
JOB_SCRIPT="${TMP_ROOT}/no-clone-smoke.sh"

# Parse the workflow as YAML. This deliberately rejects a disabled security
# step and extracts the executable run body rather than scanning comments.
extract_smoke_script() {
  local workflow="$1" output="$2"
  ruby - "${workflow}" "${output}" <<'RUBY'
require "yaml"

document = YAML.load_file(ARGV.fetch(0))
jobs = document.fetch("jobs")
job = jobs.fetch("no-clone-smoke")
raise "smoke must depend on publish-release" unless job.fetch("needs") == "publish-release"
raise "smoke contents permission must be read" unless job.dig("permissions", "contents") == "read"
raise "smoke attestations permission must be read" unless job.dig("permissions", "attestations") == "read"
oses = job.dig("strategy", "matrix", "include").map { |entry| entry.fetch("os") }
raise "smoke matrix must cover macOS and Ubuntu" unless oses.sort == ["macos-14", "ubuntu-latest"]
steps = job.fetch("steps")
raise "smoke must not checkout source" if steps.any? { |step| step["uses"].to_s.start_with?("actions/checkout@") }
matches = steps.select { |step| step["name"] == "Install and verify from immutable release" }
raise "expected exactly one immutable release smoke step" unless matches.length == 1
step = matches.fetch(0)
raise "immutable release smoke step must be reachable" if step.key?("if")
raise "immutable release smoke step must not ignore failure" if step["continue-on-error"]
run = step.fetch("run")
raise "immutable release smoke step is empty" if run.strip.empty?
File.binwrite(ARGV.fetch(1), run)
RUBY
}

validate_ci_invocation() {
  ruby - "${CI_WORKFLOW}" <<'RUBY'
require "yaml"

document = YAML.load_file(ARGV.fetch(0))
steps = document.fetch("jobs").fetch("validate-and-test").fetch("steps")
matches = steps.select { |step| step["name"] == "Validate no-clone release smoke contract" }
raise "expected one CI no-clone contract step" unless matches.length == 1
step = matches.fetch(0)
raise "CI no-clone contract must execute the test" unless step["run"] == "bash tests/test_no_clone_release_smoke.sh"
raise "CI no-clone contract must propagate failure" if step["continue-on-error"]
raise "CI no-clone contract must run on both Unix matrices" unless step["if"] == "runner.os != 'Windows'"
RUBY
}

expect_success "release smoke is a reachable structured YAML step" \
  extract_smoke_script "${WORKFLOW}" "${JOB_SCRIPT}"
expect_success "extracted release smoke is valid Bash" bash -n "${JOB_SCRIPT}"
expect_success "CI structurally invokes the executable contract on Unix" validate_ci_invocation

make_payload_fixture() {
  local root="$1" marker_commit="$2" bootstrap_repo="$3" checksum_mode="$4" archive_mode="$5"
  local payload_root="${root}/payload-root"
  local asset="${root}/vibeguard-payload-1.2.3.tar.gz"
  mkdir -p "${payload_root}/scripts/setup"

  printf 'version=1.2.3\nmanifest_sha256=%064d\ngit_commit=%s\n' \
    0 "${marker_commit}" > "${payload_root}/.vibeguard-payload"
  cat > "${payload_root}/setup.sh" <<'SETUP'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "verify-install" ]]; then
  exit "${FIXTURE_VERIFY_EXIT:-0}"
fi
mkdir -p "${HOME}/.vibeguard/installed/bin" "${HOME}/.vibeguard/installed/rules/claude-rules"
printf '#!/usr/bin/env bash\nexit 0\n' > "${HOME}/.vibeguard/installed/bin/vibeguard-runtime"
chmod 0755 "${HOME}/.vibeguard/installed/bin/vibeguard-runtime"
SETUP
  chmod 0755 "${payload_root}/setup.sh"

  cat > "${payload_root}/scripts/setup/bootstrap.sh" <<BOOTSTRAP
#!/usr/bin/env bash
set -euo pipefail
version=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --version) version="\${2#v}"; shift 2 ;;
    --require-provenance) shift ;;
    --) break ;;
    *) shift ;;
  esac
done
tag="v\${version}"
asset="vibeguard-payload-\${version}.tar.gz"
download="\${RUNNER_TEMP}/fixture-bootstrap-download"
mkdir -p "\${download}"
gh release download "\${tag}" --repo "${bootstrap_repo}" \
  --pattern "\${asset}" --pattern SHA256SUMS --dir "\${download}"
gh attestation verify "\${download}/\${asset}" \
  --repo "${bootstrap_repo}" \
  --signer-workflow "github.com/${bootstrap_repo}/.github/workflows/release.yml" \
  --source-ref "refs/tags/\${tag}" --deny-self-hosted-runners
final="\${HOME}/.vibeguard/dist/\${version}"
mkdir -p "\${final}"
tar -xzf "\${download}/\${asset}" -C "\${final}"
ln -s "\${version}" "\${HOME}/.vibeguard/dist/current"
HOME="\${HOME}" bash "\${final}/setup.sh" --yes --require-provenance
BOOTSTRAP
  chmod 0755 "${payload_root}/scripts/setup/bootstrap.sh"

  local helper
  for helper in \
    bootstrap-lib.sh bootstrap_identity.sh bootstrap_birth_token.jxa \
    bootstrap_process.sh bootstrap_termination.sh bootstrap_lease_terminal.sh \
    bootstrap_lease_retirement.sh bootstrap_state.sh; do
    printf '# fixture helper\n' > "${payload_root}/scripts/setup/${helper}"
  done

  local -a members=(
    .vibeguard-payload
    setup.sh
    scripts/setup/bootstrap.sh
    scripts/setup/bootstrap-lib.sh
    scripts/setup/bootstrap_identity.sh
    scripts/setup/bootstrap_birth_token.jxa
    scripts/setup/bootstrap_process.sh
    scripts/setup/bootstrap_termination.sh
    scripts/setup/bootstrap_lease_terminal.sh
    scripts/setup/bootstrap_lease_retirement.sh
    scripts/setup/bootstrap_state.sh
  )
  if [[ "${archive_mode}" == "unsafe-link" ]]; then
    ln -s setup.sh "${payload_root}/unsafe-link"
    members+=(unsafe-link)
  fi
  tar -czf "${asset}" -C "${payload_root}" "${members[@]}"

  local digest
  digest="$(sha256_file "${asset}")"
  if [[ "${checksum_mode}" == "wrong" ]]; then
    digest="0000000000000000000000000000000000000000000000000000000000000000"
  fi
  printf '%s  %s\n' "${digest}" "${asset##*/}" > "${root}/SHA256SUMS"
}

make_gh_stub() {
  local bin_dir="$1"
  mkdir -p "${bin_dir}"
  cat > "${bin_dir}/gh" <<'GH_STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "api" ]]; then
  printf '%s\n' "${GH_STUB_API_SHA}"
  exit 0
fi
if [[ "${1:-}" == "release" && "${2:-}" == "download" ]]; then
  shift 2
  tag="${1:-}"
  shift
  repo=""
  destination=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      --repo=*) repo="${1#*=}"; shift ;;
      --dir) destination="$2"; shift 2 ;;
      --dir=*) destination="${1#*=}"; shift ;;
      --pattern) shift 2 ;;
      --pattern=*) shift ;;
      *) exit 64 ;;
    esac
  done
  [[ "${repo}" == "${GH_REPO}" && "${tag}" == "${TAG_NAME}" && -n "${destination}" ]] || exit 1
  mkdir -p "${destination}"
  cp "${GH_STUB_PAYLOAD}" "${destination}/${GH_STUB_PAYLOAD##*/}"
  cp "${GH_STUB_SUMS}" "${destination}/SHA256SUMS"
  printf 'download\n' >> "${GH_STUB_LOG}"
  exit 0
fi
if [[ "${1:-}" == "attestation" && "${2:-}" == "verify" ]]; then
  for argument in "$@"; do
    [[ "${argument}" == "--help" ]] && exit 0
  done
  repo="" signer="" signer_digest="" source_ref="" source_digest=""
  shift 2
  [[ $# -gt 0 ]] || exit 64
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      --signer-workflow) signer="$2"; shift 2 ;;
      --signer-digest) signer_digest="$2"; shift 2 ;;
      --source-ref) source_ref="$2"; shift 2 ;;
      --source-digest) source_digest="$2"; shift 2 ;;
      --deny-self-hosted-runners) shift ;;
      *) exit 64 ;;
    esac
  done
  [[ "${repo}" == "${GH_REPO}" \
    && "${signer}" == "github.com/${GH_REPO}/.github/workflows/release.yml" \
    && "${source_ref}" == "refs/tags/${TAG_NAME}" ]] || exit 1
  if [[ "${source_digest}" == "${EVENT_SHA}" && "${signer_digest}" == "${WORKFLOW_SHA}" ]]; then
    printf 'attest-exact\n' >> "${GH_STUB_LOG}"
  else
    printf 'attest-loose\n' >> "${GH_STUB_LOG}"
  fi
  exit 0
fi
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  exit 0
fi
exit 64
GH_STUB
  chmod 0755 "${bin_dir}/gh"
}

run_fixture() {
  local fixture_root="$1" script="$2" verify_exit="${3:-0}"
  local runner="${fixture_root}/runner"
  local stub_bin="${fixture_root}/stub-bin"
  rm -rf "${runner}" "${stub_bin}"
  mkdir -p "${runner}"
  make_gh_stub "${stub_bin}"
  : > "${fixture_root}/gh.log"

  if ! env \
    EVENT_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    WORKFLOW_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    GH_REPO="majiayu000/vibeguard" \
    TAG_NAME="v1.2.3" \
    GH_TOKEN="fixture-token" \
    RUNNER_TEMP="${runner}" \
    GH_STUB_API_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    GH_STUB_PAYLOAD="${fixture_root}/vibeguard-payload-1.2.3.tar.gz" \
    GH_STUB_SUMS="${fixture_root}/SHA256SUMS" \
    GH_STUB_LOG="${fixture_root}/gh.log" \
    FIXTURE_VERIFY_EXIT="${verify_exit}" \
    PATH="${stub_bin}:${PATH}" \
    bash "${script}" > "${fixture_root}/run.log" 2>&1; then
    return 1
  fi
  [[ "$(grep -c '^download$' "${fixture_root}/gh.log" || true)" -eq 2 ]] || return 1
  [[ "$(grep -c '^attest-exact$' "${fixture_root}/gh.log" || true)" -eq 1 ]] || return 1
  [[ "$(grep -c '^attest-loose$' "${fixture_root}/gh.log" || true)" -eq 1 ]] || return 1
}

GOOD="${TMP_ROOT}/good"
mkdir -p "${GOOD}"
make_payload_fixture "${GOOD}" \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  majiayu000/vibeguard correct safe
expect_success "exact release smoke executes checksum, provenance, secondary download, install, and verify" \
  run_fixture "${GOOD}" "${JOB_SCRIPT}"

WRONG_SUM="${TMP_ROOT}/wrong-sum"
mkdir -p "${WRONG_SUM}"
make_payload_fixture "${WRONG_SUM}" \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  majiayu000/vibeguard wrong safe
expect_failure "checksum mutation fails closed" run_fixture "${WRONG_SUM}" "${JOB_SCRIPT}"

WRONG_MARKER="${TMP_ROOT}/wrong-marker"
mkdir -p "${WRONG_MARKER}"
make_payload_fixture "${WRONG_MARKER}" \
  cccccccccccccccccccccccccccccccccccccccc \
  majiayu000/vibeguard correct safe
expect_failure "payload marker from another commit fails closed" \
  run_fixture "${WRONG_MARKER}" "${JOB_SCRIPT}"

WRONG_REPO="${TMP_ROOT}/wrong-repo"
mkdir -p "${WRONG_REPO}"
make_payload_fixture "${WRONG_REPO}" \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  other/repository correct safe
expect_failure "bootstrap secondary download from another repository fails closed" \
  run_fixture "${WRONG_REPO}" "${JOB_SCRIPT}"

UNSAFE="${TMP_ROOT}/unsafe"
mkdir -p "${UNSAFE}"
make_payload_fixture "${UNSAFE}" \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  majiayu000/vibeguard correct unsafe-link
expect_failure "link or special archive entry fails before execution" \
  run_fixture "${UNSAFE}" "${JOB_SCRIPT}"

expect_failure "verify-install nonzero status propagates" \
  run_fixture "${GOOD}" "${JOB_SCRIPT}" 17

WRONG_DIGEST_SCRIPT="${TMP_ROOT}/wrong-source-digest.sh"
ruby - "${JOB_SCRIPT}" "${WRONG_DIGEST_SCRIPT}" <<'RUBY'
text = File.binread(ARGV.fetch(0))
old = '--source-digest "${EVENT_SHA}"'
raise "source digest binding missing" unless text.sub!(old, '--source-digest "${WORKFLOW_SHA}"')
File.binwrite(ARGV.fetch(1), text)
RUBY
expect_failure "wrong provenance source identity is rejected by executable fixture" \
  run_fixture "${GOOD}" "${WRONG_DIGEST_SCRIPT}"

INERT_SCRIPT="${TMP_ROOT}/inert-attestation.sh"
ruby - "${JOB_SCRIPT}" "${INERT_SCRIPT}" <<'RUBY'
text = File.binread(ARGV.fetch(0))
pattern = /gh attestation verify "\$\{DOWNLOAD_DIR\}\/\$\{ASSET\}" .*?--deny-self-hosted-runners\n/m
raise "active attestation command missing" unless text.sub!(pattern, ": # attestation deliberately disabled\n")
File.binwrite(ARGV.fetch(1), text)
RUBY
expect_failure "commented or inert attestation cannot satisfy the executable contract" \
  run_fixture "${GOOD}" "${INERT_SCRIPT}"

DISABLED_WORKFLOW="${TMP_ROOT}/disabled-workflow.yml"
ruby - "${WORKFLOW}" "${DISABLED_WORKFLOW}" <<'RUBY'
require "yaml"
document = YAML.load_file(ARGV.fetch(0))
step = document.fetch("jobs").fetch("no-clone-smoke").fetch("steps")
  .find { |candidate| candidate["name"] == "Install and verify from immutable release" }
step["if"] = "${{ false }}"
File.write(ARGV.fetch(1), YAML.dump(document))
RUBY
expect_failure "structural validator rejects an unreachable smoke step" \
  extract_smoke_script "${DISABLED_WORKFLOW}" "${TMP_ROOT}/disabled.sh" 2>/dev/null

printf '%s passed, %s failed\n' "${PASS}" "${FAIL}"
test "${FAIL}" -eq 0
