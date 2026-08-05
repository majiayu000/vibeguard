#!/usr/bin/env bash
# Executable fixture for the draft -> verify -> publish release protocol.

set -euo pipefail

WORKFLOW="${1:?release workflow path required}"
CONTRACT_HELPER="${2:?workflow contract helper required}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibeguard-staged-release.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

STAGE_SCRIPT="${TMP_ROOT}/stage.sh"
PUBLISH_SCRIPT="${TMP_ROOT}/publish.sh"
ruby "${CONTRACT_HELPER}" extract-stage "${WORKFLOW}" "${STAGE_SCRIPT}"
ruby "${CONTRACT_HELPER}" extract-publish "${WORKFLOW}" "${PUBLISH_SCRIPT}"

EVENT_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
WORKFLOW_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
GH_REPO="fork-owner/renamed-vibeguard"
TAG_NAME="v1.2.3"
RELEASE_ID="4242"
FIXTURE_ROOT="${TMP_ROOT}/fixture"
DIST="${FIXTURE_ROOT}/dist"
STUB_BIN="${FIXTURE_ROOT}/bin"
GH_LOG="${FIXTURE_ROOT}/gh.log"
mkdir -p "${DIST}" "${STUB_BIN}"

for target in \
  aarch64-apple-darwin \
  aarch64-unknown-linux-musl \
  x86_64-apple-darwin \
  x86_64-unknown-linux-musl
do
  printf 'runtime=%s\n' "${target}" > "${DIST}/vibeguard-runtime-${target}"
done
printf '{"dependencies":[]}\n' > "${DIST}/vibeguard-runtime-dependency-metadata.json"
printf '{"release":"fixture"}\n' > "${DIST}/vibeguard-runtime-releases.json"

PAYLOAD_ROOT="${FIXTURE_ROOT}/payload"
mkdir -p "${PAYLOAD_ROOT}"
printf 'version=1.2.3\nmanifest_sha256=%064d\ngit_commit=%s\n' \
  0 "${EVENT_SHA}" > "${PAYLOAD_ROOT}/.vibeguard-payload"
tar -czf "${DIST}/vibeguard-payload-1.2.3.tar.gz" -C "${PAYLOAD_ROOT}" .vibeguard-payload
(
  cd "${DIST}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum vibeguard-runtime-aarch64-apple-darwin \
      vibeguard-runtime-aarch64-unknown-linux-musl \
      vibeguard-runtime-dependency-metadata.json \
      vibeguard-runtime-x86_64-apple-darwin \
      vibeguard-runtime-x86_64-unknown-linux-musl \
      vibeguard-payload-1.2.3.tar.gz > SHA256SUMS
  else
    shasum -a 256 vibeguard-runtime-aarch64-apple-darwin \
      vibeguard-runtime-aarch64-unknown-linux-musl \
      vibeguard-runtime-dependency-metadata.json \
      vibeguard-runtime-x86_64-apple-darwin \
      vibeguard-runtime-x86_64-unknown-linux-musl \
      vibeguard-payload-1.2.3.tar.gz > SHA256SUMS
  fi
)

cat > "${STUB_BIN}/gh" <<'GH_STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "release" && "${2:-}" == "view" ]]; then
  if [[ " $* " == *" --json "* ]]; then
    printf '{"databaseId":%s,"isDraft":true,"tagName":"%s"}\n' "${RELEASE_ID}" "${TAG_NAME}"
    exit 0
  fi
  exit 1
fi
if [[ "${1:-}" == "release" && "${2:-}" == "create" ]]; then
  printf 'create-draft\n' >> "${GH_STUB_LOG}"
  [[ " $* " == *" --draft "* ]]
  exit 0
fi
if [[ "${1:-}" == "release" && "${2:-}" == "upload" ]]; then
  printf 'upload-assets\n' >> "${GH_STUB_LOG}"
  [[ "${GH_STUB_UPLOAD_FAIL:-0}" != "1" ]]
  exit
fi
if [[ "${1:-}" == "release" && "${2:-}" == "delete" ]]; then
  printf 'delete-draft\n' >> "${GH_STUB_LOG}"
  exit 0
fi
if [[ "${1:-}" == "release" && "${2:-}" == "download" ]]; then
  destination=""
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) destination="$2"; shift 2 ;;
      --repo) shift 2 ;;
      *) shift ;;
    esac
  done
  mkdir -p "${destination}"
  cp "${GH_STUB_ASSET_DIR}"/* "${destination}/"
  printf 'download-draft\n' >> "${GH_STUB_LOG}"
  exit 0
fi
if [[ "${1:-}" == "attestation" && "${2:-}" == "verify" ]]; then
  shift 2
  subject="${1:-}"
  [[ -n "${subject}" && "${subject}" != -* ]] || exit 64
  shift
  repo="" signer="" signer_digest="" source_ref="" source_digest="" deny=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) [[ $# -ge 2 ]] || exit 64; repo="$2"; shift 2 ;;
      --signer-workflow) [[ $# -ge 2 ]] || exit 64; signer="$2"; shift 2 ;;
      --signer-digest) [[ $# -ge 2 ]] || exit 64; signer_digest="$2"; shift 2 ;;
      --source-ref) [[ $# -ge 2 ]] || exit 64; source_ref="$2"; shift 2 ;;
      --source-digest) [[ $# -ge 2 ]] || exit 64; source_digest="$2"; shift 2 ;;
      --deny-self-hosted-runners) deny=1; shift ;;
      *) exit 64 ;;
    esac
  done
  # A stub that ignores arguments would false-green a provenance regression:
  # require the complete pinned identity that the workflow advertises.
  if [[ "${repo}" != "${GH_REPO}" \
    || "${signer}" != "github.com/${GH_REPO}/.github/workflows/release.yml" \
    || "${signer_digest}" != "${WORKFLOW_SHA}" \
    || "${source_ref}" != "refs/tags/${TAG_NAME}" \
    || "${source_digest}" != "${EVENT_SHA}" \
    || "${deny}" != "1" ]]; then
    echo "ERROR: attestation verify omitted the pinned signer identity" >&2
    exit 64
  fi
  printf 'verify-attestation\n' >> "${GH_STUB_LOG}"
  [[ "${GH_STUB_ATTEST_FAIL:-0}" != "1" ]]
  exit
fi
if [[ "${1:-}" == "api" ]]; then
  shift
  method="GET" endpoint="" draft_value="" make_latest_value=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --method) [[ $# -ge 2 ]] || exit 64; method="$2"; shift 2 ;;
      --jq) [[ $# -ge 2 ]] || exit 64; shift 2 ;;
      -F|-f)
        [[ $# -ge 2 ]] || exit 64
        case "$2" in
          draft=*) draft_value="${2#draft=}" ;;
          make_latest=*) make_latest_value="${2#make_latest=}" ;;
          *) exit 64 ;;
        esac
        shift 2 ;;
      -*) exit 64 ;;
      *) [[ -z "${endpoint}" ]] || exit 64; endpoint="$1"; shift ;;
    esac
  done
  if [[ "${method}" == "PATCH" ]]; then
    if [[ "${endpoint}" != "repos/${GH_REPO}/releases/${RELEASE_ID}" \
      || "${draft_value}" != "false" \
      || "${make_latest_value}" != "true" ]]; then
      echo "ERROR: publish PATCH did not target the staged draft release" >&2
      exit 64
    fi
    printf 'publish-transition\n' >> "${GH_STUB_LOG}"
    # An applied PATCH whose acknowledgement is lost is the ambiguous commit
    # point the publish job must reconcile instead of failing outright.
    if [[ "${GH_STUB_PATCH_LOSE_ACK:-0}" == "1" ]]; then
      exit 1
    fi
    printf '{"id":%s,"draft":false}\n' "${RELEASE_ID}"
    exit 0
  fi
  [[ "${method}" == "GET" ]] || exit 64
  case "${endpoint}" in
    "repos/${GH_REPO}/commits/${TAG_NAME}") printf '%s\n' "${GH_STUB_TAG_SHA}" ;;
    "repos/${GH_REPO}/releases/${RELEASE_ID}")
      patch_seen="$(grep -c '^publish-transition$' "${GH_STUB_LOG}" || true)"
      if [[ "${patch_seen}" -gt 0 && "${GH_STUB_PATCH_COMMITTED:-1}" == "1" ]]; then
        printf '{"id":%s,"draft":false,"tag_name":"%s"}\n' "${RELEASE_ID}" "${TAG_NAME}"
      else
        printf '{"id":%s,"draft":true,"tag_name":"%s"}\n' "${RELEASE_ID}" "${TAG_NAME}"
      fi
      ;;
    *) exit 64 ;;
  esac
  exit 0
fi
exit 64
GH_STUB
chmod 0755 "${STUB_BIN}/gh"

run_env=(
  "EVENT_SHA=${EVENT_SHA}"
  "WORKFLOW_SHA=${WORKFLOW_SHA}"
  "GH_REPO=${GH_REPO}"
  "TAG_NAME=${TAG_NAME}"
  "RELEASE_ID=${RELEASE_ID}"
  "GH_TOKEN=fixture-token"
  "GH_STUB_LOG=${GH_LOG}"
  "GH_STUB_ASSET_DIR=${DIST}"
  "PATH=${STUB_BIN}:${PATH}"
)

: > "${GH_LOG}"
(
  cd "${FIXTURE_ROOT}"
  env "${run_env[@]}" GH_STUB_TAG_SHA="${EVENT_SHA}" \
    GITHUB_OUTPUT="${FIXTURE_ROOT}/github-output" bash "${STAGE_SCRIPT}"
)
grep -qx 'release_id=4242' "${FIXTURE_ROOT}/github-output"
test "$(grep -c '^create-draft$' "${GH_LOG}")" -eq 1
test "$(grep -c '^upload-assets$' "${GH_LOG}")" -eq 1
test "$(grep -c '^publish-transition$' "${GH_LOG}" || true)" -eq 0

env "${run_env[@]}" GH_STUB_TAG_SHA="${EVENT_SHA}" \
  RUNNER_TEMP="${FIXTURE_ROOT}/runner-success" bash "${PUBLISH_SCRIPT}"
test "$(grep -c '^publish-transition$' "${GH_LOG}")" -eq 1

: > "${GH_LOG}"
if env "${run_env[@]}" GH_STUB_TAG_SHA="cccccccccccccccccccccccccccccccccccccccc" \
  RUNNER_TEMP="${FIXTURE_ROOT}/runner-drift" bash "${PUBLISH_SCRIPT}" >/dev/null 2>&1; then
  exit 1
fi
test "$(grep -c '^publish-transition$' "${GH_LOG}" || true)" -eq 0

: > "${GH_LOG}"
if env "${run_env[@]}" GH_STUB_TAG_SHA="${EVENT_SHA}" GH_STUB_ATTEST_FAIL=1 \
  RUNNER_TEMP="${FIXTURE_ROOT}/runner-attestation" bash "${PUBLISH_SCRIPT}" >/dev/null 2>&1; then
  exit 1
fi
test "$(grep -c '^publish-transition$' "${GH_LOG}" || true)" -eq 0

: > "${GH_LOG}"
if (
  cd "${FIXTURE_ROOT}"
  env "${run_env[@]}" GH_STUB_TAG_SHA="${EVENT_SHA}" GH_STUB_UPLOAD_FAIL=1 \
    GITHUB_OUTPUT="${FIXTURE_ROOT}/failed-output" bash "${STAGE_SCRIPT}" >/dev/null 2>&1
); then
  exit 1
fi
test "$(grep -c '^delete-draft$' "${GH_LOG}")" -eq 1

# An applied PATCH whose acknowledgement is lost must reconcile to success
# against the exact release id, without a second publish transition.
: > "${GH_LOG}"
env "${run_env[@]}" GH_STUB_TAG_SHA="${EVENT_SHA}" GH_STUB_PATCH_LOSE_ACK=1 \
  RUNNER_TEMP="${FIXTURE_ROOT}/runner-lost-ack" bash "${PUBLISH_SCRIPT}" >/dev/null 2>&1
test "$(grep -c '^publish-transition$' "${GH_LOG}")" -eq 1

# A PATCH that never committed must stay a failure, not be reconciled away.
: > "${GH_LOG}"
if env "${run_env[@]}" GH_STUB_TAG_SHA="${EVENT_SHA}" GH_STUB_PATCH_LOSE_ACK=1 \
  GH_STUB_PATCH_COMMITTED=0 \
  RUNNER_TEMP="${FIXTURE_ROOT}/runner-uncommitted" bash "${PUBLISH_SCRIPT}" >/dev/null 2>&1; then
  exit 1
fi

# Negative mutation: publishing another release id must fail closed.
WRONG_RELEASE_SCRIPT="${TMP_ROOT}/publish-wrong-release.sh"
ruby - "${PUBLISH_SCRIPT}" "${WRONG_RELEASE_SCRIPT}" <<'RUBY'
text = File.binread(ARGV.fetch(0))
old = 'gh api --method PATCH "repos/${GH_REPO}/releases/${RELEASE_ID}"'
new = 'gh api --method PATCH "repos/${GH_REPO}/releases/999999"'
raise "publish PATCH endpoint missing" unless text.sub!(old, new)
File.binwrite(ARGV.fetch(1), text)
RUBY
: > "${GH_LOG}"
if env "${run_env[@]}" GH_STUB_TAG_SHA="${EVENT_SHA}" \
  RUNNER_TEMP="${FIXTURE_ROOT}/runner-wrong-release" \
  bash "${WRONG_RELEASE_SCRIPT}" >/dev/null 2>&1; then
  exit 1
fi
test "$(grep -c '^publish-transition$' "${GH_LOG}" || true)" -eq 0

# Negative mutation: dropping the pinned provenance identity must fail closed.
LOOSE_ATTEST_SCRIPT="${TMP_ROOT}/publish-loose-attestation.sh"
ruby - "${PUBLISH_SCRIPT}" "${LOOSE_ATTEST_SCRIPT}" <<'RUBY'
text = File.binread(ARGV.fetch(0))
pattern = /gh attestation verify "\$\{asset\}".*?--deny-self-hosted-runners\n/m
replacement = %Q{gh attestation verify "${asset}" --repo "${GH_REPO}"\n}
raise "pinned attestation identity missing" unless text.sub!(pattern, replacement)
File.binwrite(ARGV.fetch(1), text)
RUBY
: > "${GH_LOG}"
if env "${run_env[@]}" GH_STUB_TAG_SHA="${EVENT_SHA}" \
  RUNNER_TEMP="${FIXTURE_ROOT}/runner-loose-attestation" \
  bash "${LOOSE_ATTEST_SCRIPT}" >/dev/null 2>&1; then
  exit 1
fi
test "$(grep -c '^publish-transition$' "${GH_LOG}" || true)" -eq 0
