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
  printf 'verify-attestation\n' >> "${GH_STUB_LOG}"
  [[ "${GH_STUB_ATTEST_FAIL:-0}" != "1" ]]
  exit
fi
if [[ "${1:-}" == "api" ]]; then
  if [[ " $* " == *" --method PATCH "* ]]; then
    printf 'publish-transition\n' >> "${GH_STUB_LOG}"
    printf '{"id":%s,"draft":false}\n' "${RELEASE_ID}"
    exit 0
  fi
  endpoint="${2:-}"
  case "${endpoint}" in
    "repos/${GH_REPO}/commits/${TAG_NAME}") printf '%s\n' "${GH_STUB_TAG_SHA}" ;;
    "repos/${GH_REPO}/releases/${RELEASE_ID}")
      printf '{"id":%s,"draft":true,"tag_name":"%s"}\n' "${RELEASE_ID}" "${TAG_NAME}"
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
