#!/usr/bin/env bash

set -euo pipefail
LC_ALL=C
export LC_ALL

if [[ $# -ne 0 ]]; then
  echo "usage: $0" >&2
  exit 2
fi

tap_test_root=$(git rev-parse --show-toplevel)
tap_test_verifier="$tap_test_root/scripts/verify-mcp-sync-release.sh"
tap_test_stager="$tap_test_root/scripts/stage-mcp-sync-formula.sh"
tap_test_workflow="$tap_test_root/.github/workflows/publish-mcp-sync.yml"
tap_test_temp_parent=${TMPDIR:-/tmp}
tap_test_temp_prefix="${tap_test_temp_parent%/}/homebrew-tap-mcp-sync-policy."
tap_test_temp=$(mktemp -d "${tap_test_temp_prefix}XXXXXX")

tap_test_cleanup() {
  if [[ "$tap_test_temp" != "$tap_test_temp_prefix"* ]]; then
    echo "refusing to remove an unexpected tap policy test path" >&2
    return 1
  fi
  if [[ -d "$tap_test_temp" ]]; then
    rm -rf -- "$tap_test_temp"
  fi
}
trap tap_test_cleanup EXIT

tap_test_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print tolower($1) }'
  else
    shasum -a 256 "$1" | awk '{ print tolower($1) }'
  fi
}

tap_test_formula() {
  local path=$1
  local version=$2
  local package_hash=$3

  printf '%s\n' \
    '# typed: false' \
    '# frozen_string_literal: true' \
    '' \
    'class McpSync < Formula' \
    '  desc "Keep MCP server configuration synchronized across supported clients"' \
    '  homepage "https://github.com/EnjoyableWork/mcp-sync"' \
    "  url \"https://github.com/EnjoyableWork/mcp-sync/releases/download/v$version/enjoyable-mcp-sync-$version.crate\"" \
    "  sha256 \"$package_hash\"" \
    '  license "MIT"' \
    '' \
    '  depends_on "rust" => :build' \
    '' \
    '  def install' \
    '    system "cargo", "install", *std_cargo_args(path: ".")' \
    '  end' \
    '' \
    '  test do' \
    '    assert_equal "mcp-sync #{version}", shell_output("#{bin}/mcp-sync --version").strip' \
    '  end' \
    'end' >"$path"
}

tap_test_release_asset_names() {
  local version=$1
  printf '%s\n' \
    SHA256SUMS \
    "enjoyable-mcp-sync-$version.crate" \
    "mcp-sync-v$version-aarch64-unknown-linux-gnu.spdx.json" \
    "mcp-sync-v$version-aarch64-unknown-linux-gnu.tar.gz" \
    "mcp-sync-v$version-x86_64-unknown-linux-gnu.spdx.json" \
    "mcp-sync-v$version-x86_64-unknown-linux-gnu.tar.gz" \
    mcp-sync.rb
}

tap_test_make_attestation_marker() {
  local marker=$1
  local version=$2
  local commit=$3
  local assets=$4
  shift 4
  local marker_assets asset

  marker_assets="$({
    for asset in "$@"; do
      jq -n \
        --arg name "$asset" \
        --arg sha256 "$(tap_test_sha256 "$assets/$asset")" \
        '{name: $name, sha256: $sha256}'
    done
  } | jq -s 'sort_by(.name)')"
  jq -n \
    --arg digest "$commit" \
    --arg ref "refs/tags/v$version" \
    --argjson assets "$marker_assets" \
    '{
      schema: "mcp-sync.tap-attestations/v1",
      source_repository: "EnjoyableWork/mcp-sync",
      source_workflow: "EnjoyableWork/mcp-sync/.github/workflows/source-linux-release.yml",
      source_ref: $ref,
      source_digest: $digest,
      release_verified: true,
      assets: $assets
    }' >"$marker"
}

tap_test_make_release() {
  local destination=$1
  local version=$2
  local commit=$3
  local package_bytes=$4
  local assets="$destination/assets"
  local package="enjoyable-mcp-sync-$version.crate"
  local asset asset_records package_hash

  mkdir -p "$assets"
  printf '%s\n' "$package_bytes" >"$assets/$package"
  package_hash=$(tap_test_sha256 "$assets/$package")
  tap_test_formula "$assets/mcp-sync.rb" "$version" "$package_hash"
  for tap_test_target in aarch64-unknown-linux-gnu x86_64-unknown-linux-gnu; do
    printf 'synthetic archive %s %s\n' "$version" "$tap_test_target" \
      >"$assets/mcp-sync-v$version-$tap_test_target.tar.gz"
    jq -n \
      --arg namespace "https://example.invalid/spdx/$version/$tap_test_target" \
      '{spdxVersion: "SPDX-2.3", documentNamespace: $namespace, packages: [{name: "synthetic"}]}' \
      >"$assets/mcp-sync-v$version-$tap_test_target.spdx.json"
  done
  (
    cd -- "$assets"
    for asset in \
      "$package" \
      "mcp-sync-v$version-aarch64-unknown-linux-gnu.spdx.json" \
      "mcp-sync-v$version-aarch64-unknown-linux-gnu.tar.gz" \
      "mcp-sync-v$version-x86_64-unknown-linux-gnu.spdx.json" \
      "mcp-sync-v$version-x86_64-unknown-linux-gnu.tar.gz" \
      mcp-sync.rb; do
      if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$asset"
      else
        shasum -a 256 "$asset"
      fi
    done | sort -k2 >SHA256SUMS
  )

  jq -n \
    --arg ref "refs/tags/v$version" \
    '{ref: $ref, object: {type: "tag", sha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}' \
    >"$destination/tag-ref.json"
  jq -n \
    --arg tag "v$version" \
    --arg commit "$commit" \
    '{
      sha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      tag: $tag,
      object: {type: "commit", sha: $commit},
      verification: {verified: true, reason: "valid"}
    }' >"$destination/annotated-tag.json"
  asset_records="$({
    while IFS= read -r asset; do
      jq -n \
        --arg name "$asset" \
        --arg digest "sha256:$(tap_test_sha256 "$assets/$asset")" \
        '{name: $name, state: "uploaded", digest: $digest}'
    done < <(tap_test_release_asset_names "$version")
  } | jq -s '.')"
  jq -n \
    --arg tag "v$version" \
    --argjson assets "$asset_records" \
    '{
      tag_name: $tag,
      target_commitish: "main",
      draft: false,
      prerelease: false,
      immutable: true,
      assets: $assets
    }' >"$destination/release.json"
  tap_test_make_attestation_marker \
    "$destination/attestations.json" \
    "$version" \
    "$commit" \
    "$assets" \
    SHA256SUMS \
    "$package" \
    "mcp-sync-v$version-aarch64-unknown-linux-gnu.spdx.json" \
    "mcp-sync-v$version-aarch64-unknown-linux-gnu.tar.gz" \
    "mcp-sync-v$version-x86_64-unknown-linux-gnu.spdx.json" \
    "mcp-sync-v$version-x86_64-unknown-linux-gnu.tar.gz" \
    mcp-sync.rb
}

tap_test_make_handoff() {
  local handoff=$1
  local candidate_version=$2
  local prior_version=$3
  local candidate_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  local prior_commit=cccccccccccccccccccccccccccccccccccccccc
  local candidate_hash prior_package_bytes

  mkdir -p "$handoff"
  tap_test_make_release \
    "$handoff/candidate" \
    "$candidate_version" \
    "$candidate_commit" \
    "synthetic candidate crate $candidate_version"
  prior_package_bytes="synthetic prior crate $prior_version"
  if [[ "$candidate_version" == "$prior_version" ]]; then
    prior_package_bytes="synthetic candidate crate $candidate_version"
  fi
  tap_test_make_release \
    "$handoff/prior-full" \
    "$prior_version" \
    "$prior_commit" \
    "$prior_package_bytes"
  mkdir -p "$handoff/prior/assets"
  cp -- \
    "$handoff/prior-full/release.json" \
    "$handoff/prior-full/tag-ref.json" \
    "$handoff/prior-full/annotated-tag.json" \
    "$handoff/prior/"
  cp -- \
    "$handoff/prior-full/assets/SHA256SUMS" \
    "$handoff/prior-full/assets/mcp-sync.rb" \
    "$handoff/prior/assets/"
  tap_test_make_attestation_marker \
    "$handoff/prior/attestations.json" \
    "$prior_version" \
    "$prior_commit" \
    "$handoff/prior/assets" \
    SHA256SUMS \
    mcp-sync.rb
  rm -rf -- "$handoff/prior-full"

  cp -- \
    "$handoff/candidate/assets/enjoyable-mcp-sync-$candidate_version.crate" \
    "$handoff/candidate/registry.crate"
  candidate_hash="$(
    tap_test_sha256 \
      "$handoff/candidate/assets/enjoyable-mcp-sync-$candidate_version.crate"
  )"
  jq -n \
    --arg candidate "$candidate_version" \
    --arg checksum "$candidate_hash" \
    --arg prior "$prior_version" '
      {
        crate: {
          id: "enjoyable-mcp-sync",
          name: "enjoyable-mcp-sync",
          repository: "https://github.com/EnjoyableWork/mcp-sync",
          trustpub_only: true
        },
        versions: (
          [{num: "0.1.0", yanked: false, checksum: ("0" * 64), crate: "enjoyable-mcp-sync"}] +
          (if $prior != "0.1.0" and $prior != $candidate then
            [{num: $prior, yanked: false, checksum: ("1" * 64), crate: "enjoyable-mcp-sync"}]
          else [] end) +
          [{num: $candidate, yanked: false, checksum: $checksum, crate: "enjoyable-mcp-sync"}]
        )
      }
    ' >"$handoff/candidate/registry.json"
}

tap_test_expect_rejection() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "mcp-sync tap policy accepted $description" >&2
    exit 1
  fi
}

noop_handoff="$tap_test_temp/noop-handoff"
tap_test_make_handoff "$noop_handoff" 0.1.1 0.1.1
noop_formula="$tap_test_temp/noop-formula.rb"
cp -- "$noop_handoff/prior/assets/mcp-sync.rb" "$noop_formula"
if [[ "$($tap_test_verifier "$noop_handoff" 0.1.1 rehearse "$noop_formula")" != \
  'noop aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ]]; then
  echo "mcp-sync tap verifier rejected the exact no-write v0.1.1 no-op" >&2
  exit 1
fi

publish_handoff="$tap_test_temp/publish-handoff"
tap_test_make_handoff "$publish_handoff" 0.1.2 0.1.1
publish_formula="$tap_test_temp/publish-formula.rb"
cp -- "$publish_handoff/prior/assets/mcp-sync.rb" "$publish_formula"
if [[ "$($tap_test_verifier "$publish_handoff" 0.1.2 publish "$publish_formula")" != \
  'publish aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ]]; then
  echo "mcp-sync tap verifier rejected a monotonic exact-byte transition" >&2
  exit 1
fi

bad_cargo="$tap_test_temp/bad-cargo"
cp -R "$publish_handoff" "$bad_cargo"
printf 'mismatch\n' >>"$bad_cargo/candidate/registry.crate"
tap_test_expect_rejection \
  'mismatched Cargo registry bytes' \
  "$tap_test_verifier" "$bad_cargo" 0.1.2 publish "$publish_formula"

extra_path="$tap_test_temp/extra-path"
cp -R "$publish_handoff" "$extra_path"
printf 'unexpected\n' >"$extra_path/candidate/unexpected"
tap_test_expect_rejection \
  'an extra handoff path' \
  "$tap_test_verifier" "$extra_path" 0.1.2 publish "$publish_formula"

stale_version="$tap_test_temp/stale-version"
cp -R "$publish_handoff" "$stale_version"
jq '.versions += [{
      num: "0.1.3",
      yanked: false,
      checksum: ("2" * 64),
      crate: "enjoyable-mcp-sync"
    }]' \
  "$stale_version/candidate/registry.json" \
  >"$stale_version/candidate/registry-updated.json"
mv -- \
  "$stale_version/candidate/registry-updated.json" \
  "$stale_version/candidate/registry.json"
tap_test_expect_rejection \
  'a stale version behind crates.io' \
  "$tap_test_verifier" "$stale_version" 0.1.2 publish "$publish_formula"

tag_identity_mismatch="$tap_test_temp/tag-identity-mismatch"
cp -R "$publish_handoff" "$tag_identity_mismatch"
jq '.sha = "dddddddddddddddddddddddddddddddddddddddd"' \
  "$tag_identity_mismatch/candidate/annotated-tag.json" \
  >"$tag_identity_mismatch/candidate/annotated-tag-updated.json"
mv -- \
  "$tag_identity_mismatch/candidate/annotated-tag-updated.json" \
  "$tag_identity_mismatch/candidate/annotated-tag.json"
tap_test_expect_rejection \
  'an annotated tag object detached from its fetched ref' \
  "$tap_test_verifier" "$tag_identity_mismatch" 0.1.2 publish "$publish_formula"

formula_mismatch="$tap_test_temp/formula-mismatch"
cp -R "$publish_handoff" "$formula_mismatch"
printf '# changed after attestation\n' \
  >>"$formula_mismatch/candidate/assets/mcp-sync.rb"
tap_test_expect_rejection \
  'formula bytes changed after attestation' \
  "$tap_test_verifier" "$formula_mismatch" 0.1.2 publish "$publish_formula"

prior_mismatch="$tap_test_temp/prior-mismatch.rb"
cp -- "$publish_formula" "$prior_mismatch"
printf '# not the immutable prior formula\n' >>"$prior_mismatch"
tap_test_expect_rejection \
  'a current formula that differs from its own immutable release' \
  "$tap_test_verifier" "$publish_handoff" 0.1.2 publish "$prior_mismatch"

tap_test_make_repository() {
  local repository=$1
  mkdir -p "$repository/Formula"
  cp -- "$noop_formula" "$repository/Formula/mcp-sync.rb"
  cp -- "$tap_test_root/Formula/mcp-doctor.rb" "$repository/Formula/mcp-doctor.rb"
  git -C "$repository" init -q
  git -C "$repository" config user.name synthetic-test
  git -C "$repository" config user.email synthetic@example.invalid
  git -C "$repository" add -- Formula/mcp-sync.rb Formula/mcp-doctor.rb
  git -C "$repository" commit -q -m 'synthetic tap baseline'
}

staging_repository="$tap_test_temp/staging-repository"
tap_test_make_repository "$staging_repository"
staging_base=$(git -C "$staging_repository" rev-parse HEAD)
if [[ "$($tap_test_stager "$staging_repository" "$publish_handoff/candidate/assets/mcp-sync.rb" "$staging_base")" != Formula/mcp-sync.rb ]] ||
  [[ "$(git -C "$staging_repository" diff --cached --name-only)" != Formula/mcp-sync.rb ]] ||
  ! git -C "$staging_repository" diff --quiet -- Formula/mcp-doctor.rb; then
  echo "mcp-sync tap stager did not isolate the exact formula path" >&2
  exit 1
fi

sibling_repository="$tap_test_temp/sibling-repository"
tap_test_make_repository "$sibling_repository"
sibling_base=$(git -C "$sibling_repository" rev-parse HEAD)
printf '# forbidden sibling change\n' >>"$sibling_repository/Formula/mcp-doctor.rb"
tap_test_expect_rejection \
  'a pre-existing Formula/mcp-doctor.rb change' \
  "$tap_test_stager" \
  "$sibling_repository" \
  "$publish_handoff/candidate/assets/mcp-sync.rb" \
  "$sibling_base"

untracked_repository="$tap_test_temp/untracked-repository"
tap_test_make_repository "$untracked_repository"
untracked_base=$(git -C "$untracked_repository" rev-parse HEAD)
printf 'extra\n' >"$untracked_repository/extra-file"
tap_test_expect_rejection \
  'an extra tap path' \
  "$tap_test_stager" \
  "$untracked_repository" \
  "$publish_handoff/candidate/assets/mcp-sync.rb" \
  "$untracked_base"

wrong_ref_repository="$tap_test_temp/wrong-ref-repository"
tap_test_make_repository "$wrong_ref_repository"
tap_test_expect_rejection \
  'a mismatched tap base ref' \
  "$tap_test_stager" \
  "$wrong_ref_repository" \
  "$publish_handoff/candidate/assets/mcp-sync.rb" \
  dddddddddddddddddddddddddddddddddddddddd

tap_test_assert_workflow_policy() {
  local workflow=$1
  local validate_block rehearse_block publish_block

  validate_block=$(sed -n '/^  validate:/,/^  rehearse:/p' "$workflow")
  rehearse_block=$(sed -n '/^  rehearse:/,/^  publish:/p' "$workflow")
  publish_block=$(sed -n '/^  publish:/,$p' "$workflow")
  # These are literal GitHub expression and shell-source policy markers.
  # shellcheck disable=SC2016
  for required in \
    'workflow_dispatch:' \
    'permissions: {}' \
    'group: homebrew-tap-release' \
    'DISPATCH_REF: ${{ github.ref }}' \
    'WORKFLOW_COMMIT: ${{ github.workflow_sha }}' \
    '"$DISPATCH_REF" != refs/heads/main' \
    '"$WORKFLOW_COMMIT" != "$TAP_COMMIT"' \
    'scripts/verify-mcp-sync-release.sh' \
    'scripts/stage-mcp-sync-formula.sh' \
    'git diff-tree --no-commit-id --name-only -r HEAD' \
    'Formula/mcp-sync.rb' \
    'Formula/mcp-doctor.rb'; do
    if ! grep -F -- "$required" "$workflow" >/dev/null; then
      echo "mcp-sync tap workflow lacks required policy: $required" >&2
      return 1
    fi
  done
  for forbidden in \
    'secrets.' \
    'PERSONAL_ACCESS_TOKEN' \
    'HOMEBREW_TAP_DEPLOY_KEY' \
    'deploy key' \
    'GitHub App credential' \
    'repository_dispatch:' \
    'workflow_call:' \
    'workflow_run:' \
    'pull_request_target:' \
    '--retry' \
    'sleep '; do
    if grep -F -- "$forbidden" "$workflow" >/dev/null; then
      echo "mcp-sync tap workflow contains forbidden authority or timing behavior: $forbidden" >&2
      return 1
    fi
  done
  if grep -F 'environment:' <<<"$validate_block" >/dev/null ||
    grep -E '^[[:space:]]+[A-Za-z0-9_-]+:[[:space:]]*write([[:space:]#]|$)' \
      <<<"$validate_block" >/dev/null ||
    grep -E '^[[:space:]]+[A-Za-z0-9_-]+:[[:space:]]*write([[:space:]#]|$)' \
      <<<"$rehearse_block" >/dev/null ||
    ! grep -F 'environment:' <<<"$rehearse_block" >/dev/null ||
    [[ "$(grep -F -c 'contents: write' "$workflow")" != 1 ]] ||
    ! grep -F 'contents: write' <<<"$publish_block" >/dev/null ||
    [[ "$(
      grep -E '^[[:space:]]+[A-Za-z0-9_-]+:[[:space:]]*write([[:space:]#]|$)' \
        <<<"$publish_block" | sed 's/^[[:space:]]*//'
    )" != 'contents: write' ]]; then
    echo "mcp-sync tap workflow permission or protected-job boundary drifted" >&2
    return 1
  fi
  if [[ "$(grep -F -c 'persist-credentials: true' "$workflow")" != 1 ]] ||
    ! grep -F 'persist-credentials: true' <<<"$publish_block" >/dev/null; then
    echo "only the mcp-sync tap write job may persist its job token" >&2
    return 1
  fi
  while IFS= read -r action_ref; do
    action_revision=${action_ref##*@}
    action_revision=${action_revision%% *}
    if [[ ! "$action_revision" =~ ^[0-9a-f]{40}$ ]]; then
      echo "mcp-sync tap workflow action is not commit pinned: $action_ref" >&2
      return 1
    fi
  done < <(sed -n 's/^[[:space:]]*uses: \([^#]*\).*$/\1/p' "$workflow")
}

tap_test_assert_workflow_policy "$tap_test_workflow"

permission_drift="$tap_test_temp/permission-drift.yml"
sed 's/^      contents: write$/      contents: write\n      actions: write/' \
  "$tap_test_workflow" >"$permission_drift"
tap_test_expect_rejection \
  'write-permission drift' \
  tap_test_assert_workflow_policy "$permission_drift"

credential_drift="$tap_test_temp/credential-drift.yml"
sed 's/GH_TOKEN: \${{ github.token }}/GH_TOKEN: \${{ secrets.CROSS_REPOSITORY_TOKEN }}/' \
  "$tap_test_workflow" >"$credential_drift"
tap_test_expect_rejection \
  'stored-credential drift' \
  tap_test_assert_workflow_policy "$credential_drift"

ref_drift="$tap_test_temp/ref-drift.yml"
sed 's/refs\/heads\/main/refs\/heads\/release/' \
  "$tap_test_workflow" >"$ref_drift"
tap_test_expect_rejection \
  'dispatch-ref drift' \
  tap_test_assert_workflow_policy "$ref_drift"

if ! grep -F 'group: homebrew-tap-release' \
  "$tap_test_root/.github/workflows/publish-mcp-doctor.yml" >/dev/null; then
  echo "tap formula writers must share one non-cancelling serialization group" >&2
  exit 1
fi

printf '%s\n' \
  'Verified mcp-sync no-op and monotonic handoffs plus Cargo, stale-version, byte, path, ref, permission, and credential rejection.'
