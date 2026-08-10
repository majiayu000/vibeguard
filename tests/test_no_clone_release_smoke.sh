#!/usr/bin/env bash
# Structural and executable contract tests for the release-backed GH699 smoke.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="${REPO_DIR}/.github/workflows/release.yml"
CI_WORKFLOW="${REPO_DIR}/.github/workflows/ci.yml"
CONTRACT_HELPER="${REPO_DIR}/tests/helpers/release_workflow_contract.rb"
PROTOCOL_FIXTURE="${REPO_DIR}/tests/helpers/test_staged_release_protocol.sh"
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

extract_smoke_script() {
  local workflow="$1" output="$2"
  ruby "${CONTRACT_HELPER}" extract-smoke "${workflow}" "${output}"
}

expect_success "release workflow has exact structured jobs, permissions, expressions, and dependencies" \
  ruby "${CONTRACT_HELPER}" validate "${WORKFLOW}" "${CI_WORKFLOW}"
expect_success "release smoke is extracted from the parsed workflow AST" \
  extract_smoke_script "${WORKFLOW}" "${JOB_SCRIPT}"
expect_success "extracted release smoke is valid Bash" bash -n "${JOB_SCRIPT}"
expect_success "draft staging, final verification, one publish transition, and failure cleanup execute" \
  bash "${PROTOCOL_FIXTURE}" "${WORKFLOW}" "${CONTRACT_HELPER}"

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
# Mirror production runtime acquisition: the payload setup performs its own
# release download for the runtime binary, from the runtime release repository.
runtime_repo="${VIBEGUARD_RUNTIME_RELEASE_REPO:-majiayu000/vibeguard}"
runtime_dir="$(mktemp -d "${HOME}/.vibeguard/runtime-download.XXXXXX")"
gh release download "v1.2.3" \
  --repo "${runtime_repo}" \
  --pattern "vibeguard-runtime-fixture-target" \
  --pattern "SHA256SUMS" \
  --dir "${runtime_dir}"
[[ -f "${runtime_dir}/vibeguard-runtime-fixture-target" ]]
cp "${runtime_dir}/vibeguard-runtime-fixture-target" \
  "${HOME}/.vibeguard/installed/bin/vibeguard-runtime"
chmod 0755 "${HOME}/.vibeguard/installed/bin/vibeguard-runtime"
ln -s vibeguard-runtime "${HOME}/.vibeguard/installed/bin/vibeguard"
rm -rf "${runtime_dir}"
printf 'status=verified-provenance\nrelease_repo=%s\ntag=v1.2.3\ntarget=fixture-target\n' \
  "${runtime_repo}" > "${HOME}/.vibeguard/installed/runtime-provenance"
SETUP
  chmod 0755 "${payload_root}/setup.sh"

  cat > "${payload_root}/scripts/setup/bootstrap.sh" <<BOOTSTRAP
#!/usr/bin/env bash
set -euo pipefail
RELEASE_REPO="${bootstrap_repo}"
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
gh release download "\${tag}" --repo "\${RELEASE_REPO}" \
  --pattern "\${asset}" --pattern SHA256SUMS --dir "\${download}"
gh attestation verify "\${download}/\${asset}" \
  --repo "\${RELEASE_REPO}" \
  --signer-workflow "github.com/\${RELEASE_REPO}/.github/workflows/release.yml" \
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
  elif [[ "${archive_mode}" == "changed-content" ]]; then
    printf '# distinct second download\n' >> "${payload_root}/setup.sh"
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
  endpoint="${2:-}"
  if [[ "${endpoint}" == "repos/${GH_REPO}/releases/${RELEASE_ID}" ]]; then
    printf '{"id":%s,"draft":true,"tag_name":"%s"}\n' "${RELEASE_ID}" "${TAG_NAME}"
    exit 0
  fi
  if [[ "${endpoint}" == "repos/${GH_REPO}/commits/${TAG_NAME}" ]]; then
    api_count="$(grep -c '^api-tag$' "${GH_STUB_LOG}" || true)"
    printf 'api-tag\n' >> "${GH_STUB_LOG}"
    if [[ "${api_count}" -eq 0 ]]; then
      printf '%s\n' "${GH_STUB_API_SHA_FIRST}"
    else
      printf '%s\n' "${GH_STUB_API_SHA_FINAL}"
    fi
    exit 0
  fi
  exit 64
fi
if [[ "${1:-}" == "release" && "${2:-}" == "download" ]]; then
  shift 2
  tag="${1:-}"
  shift
  repo=""
  destination=""
  payload_requested=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      --repo=*) repo="${1#*=}"; shift ;;
      --dir) destination="$2"; shift 2 ;;
      --dir=*) destination="${1#*=}"; shift ;;
      --pattern)
        [[ "$2" != "vibeguard-payload-1.2.3.tar.gz" ]] || payload_requested=1
        shift 2 ;;
      --pattern=*)
        [[ "${1#*=}" != "vibeguard-payload-1.2.3.tar.gz" ]] || payload_requested=1
        shift ;;
      *) exit 64 ;;
    esac
  done
  [[ "${repo}" == "${GH_REPO}" && "${tag}" == "${TAG_NAME}" && -n "${destination}" ]] || exit 1
  mkdir -p "${destination}"
  if [[ "${payload_requested}" != "1" ]]; then
    cat > "${destination}/vibeguard-runtime-fixture-target" <<'RUNTIME'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "bench" && "${2:-}" == "--json" ]]; then
  printf '%s\n' "{\"corpus_id\":\"builtin-paired-v1\",\"provenance_status\":\"embedded-release-build\",\"source_commit\":\"${EVENT_SHA}\",\"target\":\"fixture-target\",\"case_total\":10,\"interception_rate_percent\":100.0,\"false_positive_rate_percent\":0.0,\"latency_ms\":{\"p50\":0.1,\"p95\":0.2}}"
  exit 0
fi
exit 64
RUNTIME
    chmod 0755 "${destination}/vibeguard-runtime-fixture-target"
    printf '%s  %s\n' \
      "0000000000000000000000000000000000000000000000000000000000000000" \
      "vibeguard-runtime-fixture-target" > "${destination}/SHA256SUMS"
    printf 'runtime-download\n' >> "${GH_STUB_LOG}"
    exit 0
  fi
  download_count="$(grep -c '^download$' "${GH_STUB_LOG}" || true)"
  if [[ "${download_count}" -eq 0 ]]; then
    payload="${GH_STUB_PAYLOAD}"
    sums="${GH_STUB_SUMS}"
  else
    payload="${GH_STUB_SECOND_PAYLOAD}"
    sums="${GH_STUB_SECOND_SUMS}"
  fi
  cp "${payload}" "${destination}/vibeguard-payload-1.2.3.tar.gz"
  cp "${sums}" "${destination}/SHA256SUMS"
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
  local release_repo="${4:-majiayu000/vibeguard}"
  local final_api_sha="${5:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
  local second_root="${6:-${fixture_root}}"
  local runner="${fixture_root}/runner"
  local stub_bin="${fixture_root}/stub-bin"
  rm -rf "${runner}" "${stub_bin}"
  mkdir -p "${runner}"
  make_gh_stub "${stub_bin}"
  : > "${fixture_root}/gh.log"

  if ! env \
    EVENT_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    WORKFLOW_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    GH_REPO="${release_repo}" \
    TAG_NAME="v1.2.3" \
    RELEASE_ID="4242" \
    GH_TOKEN="fixture-token" \
    RUNNER_TEMP="${runner}" \
    GH_STUB_API_SHA_FIRST="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    GH_STUB_API_SHA_FINAL="${final_api_sha}" \
    GH_STUB_PAYLOAD="${fixture_root}/vibeguard-payload-1.2.3.tar.gz" \
    GH_STUB_SUMS="${fixture_root}/SHA256SUMS" \
    GH_STUB_SECOND_PAYLOAD="${second_root}/vibeguard-payload-1.2.3.tar.gz" \
    GH_STUB_SECOND_SUMS="${second_root}/SHA256SUMS" \
    GH_STUB_LOG="${fixture_root}/gh.log" \
    FIXTURE_VERIFY_EXIT="${verify_exit}" \
    PATH="${stub_bin}:${PATH}" \
    bash "${script}" > "${fixture_root}/run.log" 2>&1; then
    return 1
  fi
  [[ "$(grep -c '^download$' "${fixture_root}/gh.log" || true)" -eq 2 ]] || return 1
  [[ "$(grep -c '^runtime-download$' "${fixture_root}/gh.log" || true)" -eq 1 ]] || return 1
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

expect_success "fork or renamed repository uses one trusted identity for both downloads" \
  run_fixture "${GOOD}" "${JOB_SCRIPT}" 0 fork-owner/renamed-vibeguard

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

WRONG_REPO_SCRIPT="${TMP_ROOT}/wrong-repository-parameter.sh"
ruby - "${JOB_SCRIPT}" "${WRONG_REPO_SCRIPT}" <<'RUBY'
text = File.binread(ARGV.fetch(0))
old = 'VIBEGUARD_RELEASE_REPO="${GH_REPO}"'
raise "trusted repository argument missing" unless text.sub!(old, 'VIBEGUARD_RELEASE_REPO="other/repository"')
File.binwrite(ARGV.fetch(1), text)
RUBY
expect_failure "bootstrap cannot perform its second download from another repository" \
  run_fixture "${GOOD}" "${WRONG_REPO_SCRIPT}"

UNBOUND_RUNTIME_SCRIPT="${TMP_ROOT}/unbound-runtime-repository.sh"
ruby - "${JOB_SCRIPT}" "${UNBOUND_RUNTIME_SCRIPT}" <<'RUBY'
text = File.binread(ARGV.fetch(0))
pattern = /^[ \t]*VIBEGUARD_RUNTIME_RELEASE_REPO="\$\{GH_REPO\}" \\\n/
raise "runtime repository binding missing" unless text.sub!(pattern, "")
File.binwrite(ARGV.fetch(1), text)
RUBY
expect_failure "nested runtime download cannot fall back to the upstream repository" \
  run_fixture "${GOOD}" "${UNBOUND_RUNTIME_SCRIPT}" 0 fork-owner/renamed-vibeguard

UNSAFE="${TMP_ROOT}/unsafe"
mkdir -p "${UNSAFE}"
make_payload_fixture "${UNSAFE}" \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  majiayu000/vibeguard correct unsafe-link
expect_failure "link or special archive entry fails before execution" \
  run_fixture "${UNSAFE}" "${JOB_SCRIPT}"

expect_failure "verify-install nonzero status propagates" \
  run_fixture "${GOOD}" "${JOB_SCRIPT}" 17

expect_failure "tag movement during staged smoke fails before publication" \
  run_fixture "${GOOD}" "${JOB_SCRIPT}" 0 majiayu000/vibeguard \
    cccccccccccccccccccccccccccccccccccccccc

SECOND_PAYLOAD="${TMP_ROOT}/second-payload"
mkdir -p "${SECOND_PAYLOAD}"
make_payload_fixture "${SECOND_PAYLOAD}" \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  majiayu000/vibeguard correct changed-content
expect_failure "independent second-download digest drift fails closed" \
  run_fixture "${GOOD}" "${JOB_SCRIPT}" 0 majiayu000/vibeguard \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "${SECOND_PAYLOAD}"

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

expect_success "structured contract rejects reachability, permission, expression, dependency, and final-check mutations" \
  ruby "${CONTRACT_HELPER}" self-test "${WORKFLOW}" "${CI_WORKFLOW}"

printf '%s passed, %s failed\n' "${PASS}" "${FAIL}"
test "${FAIL}" -eq 0
