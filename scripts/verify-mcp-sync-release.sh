#!/usr/bin/env bash

set -euo pipefail
LC_ALL=C
export LC_ALL

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <handoff directory> <stable version> <rehearse|publish> <current formula>" >&2
  exit 2
fi

tap_handoff_directory=$1
tap_candidate_version=$2
tap_candidate_mode=$3
tap_current_formula=$4
tap_stable_version_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

if [[ ! "$tap_candidate_version" =~ $tap_stable_version_pattern ]]; then
  echo "mcp-sync tap version must be a canonical stable semantic version" >&2
  exit 1
fi
if [[ ! -d "$tap_handoff_directory" || -L "$tap_handoff_directory" ]]; then
  echo "mcp-sync tap handoff directory is missing or symbolic" >&2
  exit 1
fi
if [[ ! -f "$tap_current_formula" || -L "$tap_current_formula" ]]; then
  echo "current mcp-sync formula must be a regular, non-symbolic-link file" >&2
  exit 1
fi
case "$tap_candidate_mode" in
  rehearse | publish) ;;
  *)
    echo "mcp-sync tap mode must be rehearse or publish" >&2
    exit 2
    ;;
esac

for tap_required_command in awk cmp find grep jq ruby sed sort tr wc; do
  if ! command -v "$tap_required_command" >/dev/null 2>&1; then
    echo "mcp-sync tap verification requires $tap_required_command" >&2
    exit 2
  fi
done
if ! command -v sha256sum >/dev/null 2>&1 &&
  ! command -v shasum >/dev/null 2>&1; then
  echo "mcp-sync tap verification requires sha256sum or shasum" >&2
  exit 2
fi

tap_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print tolower($1) }'
  else
    shasum -a 256 "$1" | awk '{ print tolower($1) }'
  fi
}

tap_numeric_component_greater() {
  local candidate=$1
  local baseline=$2

  if ((${#candidate} != ${#baseline})); then
    ((${#candidate} > ${#baseline}))
    return
  fi
  [[ "$candidate" > "$baseline" ]]
}

tap_semver_greater_than() {
  local candidate=$1
  local baseline=$2
  local candidate_major candidate_minor candidate_patch
  local baseline_major baseline_minor baseline_patch

  IFS=. read -r candidate_major candidate_minor candidate_patch <<<"$candidate"
  IFS=. read -r baseline_major baseline_minor baseline_patch <<<"$baseline"
  if [[ "$candidate_major" != "$baseline_major" ]]; then
    tap_numeric_component_greater "$candidate_major" "$baseline_major"
    return
  fi
  if [[ "$candidate_minor" != "$baseline_minor" ]]; then
    tap_numeric_component_greater "$candidate_minor" "$baseline_minor"
    return
  fi
  tap_numeric_component_greater "$candidate_patch" "$baseline_patch"
}

tap_formula_version() {
  local formula_path=$1
  local formula_label=$2
  local formula_url formula_url_count formula_tag_version formula_package_version

  if [[ ! -f "$formula_path" || -L "$formula_path" ]]; then
    echo "$formula_label formula must be a regular, non-symbolic-link file" >&2
    return 1
  fi
  formula_url="$(sed -n 's/^  url "\(.*\)"$/\1/p' "$formula_path")"
  formula_url_count="$(sed -n 's/^  url "\(.*\)"$/\1/p' "$formula_path" | awk 'END { print NR }')"
  if [[ "$formula_url_count" != 1 ]]; then
    echo "$formula_label formula must contain exactly one canonical source URL" >&2
    return 1
  fi
  if [[ "$formula_url" =~ ^https://github\.com/EnjoyableWork/mcp-sync/releases/download/v([^/]+)/enjoyable-mcp-sync-([^/]+)\.crate$ ]]; then
    formula_tag_version=${BASH_REMATCH[1]}
    formula_package_version=${BASH_REMATCH[2]}
  else
    echo "$formula_label formula does not use the canonical immutable release URL" >&2
    return 1
  fi
  if [[ "$formula_tag_version" != "$formula_package_version" ]] ||
    [[ ! "$formula_tag_version" =~ $tap_stable_version_pattern ]]; then
    echo "$formula_label formula version is inconsistent or noncanonical" >&2
    return 1
  fi
  printf '%s\n' "$formula_tag_version"
}

tap_formula_hash() {
  local formula_path=$1
  local formula_label=$2
  local formula_hash formula_hash_count

  formula_hash="$(sed -n 's/^  sha256 "\([0-9a-f][0-9a-f]*\)"$/\1/p' "$formula_path")"
  formula_hash_count="$(sed -n 's/^  sha256 "\([0-9a-f][0-9a-f]*\)"$/\1/p' "$formula_path" | awk 'END { print NR }')"
  if [[ "$formula_hash_count" != 1 || ! "$formula_hash" =~ ^[0-9a-f]{64}$ ]]; then
    echo "$formula_label formula must contain exactly one canonical SHA-256" >&2
    return 1
  fi
  printf '%s\n' "$formula_hash"
}

tap_require_formula_line() {
  local formula_path=$1
  local required_line=$2
  local matching_count

  matching_count="$(grep -F -x -c -- "$required_line" "$formula_path" || true)"
  if [[ "$matching_count" != 1 ]]; then
    echo "mcp-sync formula does not match the verified source release contract" >&2
    return 1
  fi
}

tap_release_asset_names() {
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

tap_release_payload_names() {
  local version=$1
  tap_release_asset_names "$version" | awk '$0 != "SHA256SUMS"'
}

tap_verify_release_identity() {
  local release_directory=$1
  local release_version=$2
  local release_label=$3
  local release_tag="v$release_version"
  local expected_assets observed_assets asset_name asset_digest tag_object

  jq -e \
    --arg tag "$release_tag" '
      .tag_name == $tag and
      .target_commitish == "main" and
      .draft == false and
      .prerelease == false and
      .immutable == true and
      (.assets | type == "array" and length == 7) and
      ([.assets[].name] | length == (unique | length)) and
      all(.assets[];
        .state == "uploaded" and
        (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")))
    ' "$release_directory/release.json" >/dev/null
  jq -e \
    --arg ref "refs/tags/$release_tag" '
      .ref == $ref and
      .object.type == "tag" and
      (.object.sha | test("^[0-9a-f]{40}$"))
    ' "$release_directory/tag-ref.json" >/dev/null
  tag_object="$(jq -r '.object.sha' "$release_directory/tag-ref.json")"
  jq -e \
    --arg tag "$release_tag" \
    --arg tag_object "$tag_object" '
      .tag == $tag and
      .sha == $tag_object and
      .object.type == "commit" and
      (.object.sha | test("^[0-9a-f]{40}$")) and
      .verification.verified == true and
      .verification.reason == "valid"
    ' "$release_directory/annotated-tag.json" >/dev/null

  expected_assets="$(tap_release_asset_names "$release_version" | sort)"
  observed_assets="$(jq -r '.assets[].name' "$release_directory/release.json" | sort)"
  if [[ "$observed_assets" != "$expected_assets" ]]; then
    echo "$release_label release metadata does not expose the exact seven-asset boundary" >&2
    return 1
  fi

  while IFS= read -r asset_name; do
    asset_digest="$(
      jq -r --arg name "$asset_name" \
        '[.assets[] | select(.name == $name)] | if length == 1 then .[0].digest else empty end' \
        "$release_directory/release.json"
    )"
    if [[ ! "$asset_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      echo "$release_label release metadata lacks one exact asset digest" >&2
      return 1
    fi
  done < <(tap_release_asset_names "$release_version")

  tap_verified_release_commit="$(jq -r '.object.sha' "$release_directory/annotated-tag.json")"
}

tap_verify_attestation_marker() {
  local marker_path=$1
  local release_version=$2
  local release_commit=$3
  local asset_directory=$4
  local asset_mode=$5
  local expected_names observed_names asset_name asset_hash marker_hash

  jq -e \
    --arg ref "refs/tags/v$release_version" \
    --arg digest "$release_commit" '
      (keys | sort) == ([
        "assets",
        "release_verified",
        "schema",
        "source_digest",
        "source_ref",
        "source_repository",
        "source_workflow"
      ] | sort) and
      .schema == "mcp-sync.tap-attestations/v1" and
      .source_repository == "EnjoyableWork/mcp-sync" and
      .source_workflow == "EnjoyableWork/mcp-sync/.github/workflows/source-linux-release.yml" and
      .source_ref == $ref and
      .source_digest == $digest and
      .release_verified == true and
      (.assets | type == "array" and length == (map(.name) | unique | length)) and
      all(.assets[];
        (keys | sort) == ["name", "sha256"] and
        (.name | type == "string") and
        (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))
    ' "$marker_path" >/dev/null

  case "$asset_mode" in
    all)
      expected_names="$(tap_release_asset_names "$release_version" | sort)"
      ;;
    formula)
      expected_names="$(printf '%s\n' SHA256SUMS mcp-sync.rb | sort)"
      ;;
    *)
      echo "internal mcp-sync attestation marker mode is invalid" >&2
      return 2
      ;;
  esac
  observed_names="$(jq -r '.assets[].name' "$marker_path" | sort)"
  if [[ "$observed_names" != "$expected_names" ]]; then
    echo "mcp-sync attestation marker does not cover the exact required assets" >&2
    return 1
  fi

  while IFS= read -r asset_name; do
    asset_hash="$(tap_sha256 "$asset_directory/$asset_name")"
    marker_hash="$(
      jq -r --arg name "$asset_name" \
        '[.assets[] | select(.name == $name)] | if length == 1 then .[0].sha256 else empty end' \
        "$marker_path"
    )"
    if [[ "$marker_hash" != "$asset_hash" ]]; then
      echo "mcp-sync attestation marker does not match the retained asset bytes" >&2
      return 1
    fi
  done <<<"$expected_names"
}

tap_verify_release_metadata_digest() {
  local release_json=$1
  local asset_path=$2
  local asset_name asset_hash metadata_digest

  asset_name=$(basename -- "$asset_path")
  asset_hash=$(tap_sha256 "$asset_path")
  metadata_digest="$(
    jq -r --arg name "$asset_name" \
      '[.assets[] | select(.name == $name)] | if length == 1 then .[0].digest else empty end' \
      "$release_json"
  )"
  if [[ "$metadata_digest" != "sha256:$asset_hash" ]]; then
    echo "release metadata digest does not match $asset_name" >&2
    return 1
  fi
}

tap_handoff_directory=$(cd -- "$tap_handoff_directory" && pwd)
tap_candidate_directory="$tap_handoff_directory/candidate"
tap_candidate_assets="$tap_candidate_directory/assets"
tap_prior_directory="$tap_handoff_directory/prior"
tap_prior_assets="$tap_prior_directory/assets"

tap_expected_paths=(
  candidate
  candidate/annotated-tag.json
  candidate/assets
  "candidate/assets/SHA256SUMS"
  "candidate/assets/enjoyable-mcp-sync-$tap_candidate_version.crate"
  "candidate/assets/mcp-sync-v$tap_candidate_version-aarch64-unknown-linux-gnu.spdx.json"
  "candidate/assets/mcp-sync-v$tap_candidate_version-aarch64-unknown-linux-gnu.tar.gz"
  "candidate/assets/mcp-sync-v$tap_candidate_version-x86_64-unknown-linux-gnu.spdx.json"
  "candidate/assets/mcp-sync-v$tap_candidate_version-x86_64-unknown-linux-gnu.tar.gz"
  candidate/assets/mcp-sync.rb
  candidate/attestations.json
  candidate/registry.crate
  candidate/registry.json
  candidate/release.json
  candidate/tag-ref.json
  prior
  prior/annotated-tag.json
  prior/assets
  prior/assets/SHA256SUMS
  prior/assets/mcp-sync.rb
  prior/attestations.json
  prior/release.json
  prior/tag-ref.json
)
tap_observed_paths="$(
  find "$tap_handoff_directory" -mindepth 1 -print \
    | sed "s#^$tap_handoff_directory/##" \
    | sort
)"
tap_sorted_expected_paths="$(printf '%s\n' "${tap_expected_paths[@]}" | sort)"
if [[ "$tap_observed_paths" != "$tap_sorted_expected_paths" ]] ||
  [[ -n "$(find "$tap_handoff_directory" -type l -print -quit)" ]]; then
  echo "mcp-sync tap handoff is incomplete, symbolic, or contains unexpected paths" >&2
  exit 1
fi

tap_verify_release_identity "$tap_candidate_directory" "$tap_candidate_version" candidate
tap_candidate_release_commit=$tap_verified_release_commit
tap_verify_attestation_marker \
  "$tap_candidate_directory/attestations.json" \
  "$tap_candidate_version" \
  "$tap_candidate_release_commit" \
  "$tap_candidate_assets" \
  all

while IFS= read -r tap_asset_name; do
  tap_verify_release_metadata_digest \
    "$tap_candidate_directory/release.json" \
    "$tap_candidate_assets/$tap_asset_name"
done < <(tap_release_asset_names "$tap_candidate_version")

tap_candidate_payload="$(tap_release_payload_names "$tap_candidate_version" | sort)"
tap_checksum_entries="$(
  sed -n 's/^[0-9a-f]\{64\}  \([^/][^/]*\)$/\1/p' \
    "$tap_candidate_assets/SHA256SUMS" | sort
)"
tap_checksum_line_count="$(wc -l <"$tap_candidate_assets/SHA256SUMS" | tr -d '[:space:]')"
if [[ "$tap_checksum_entries" != "$tap_candidate_payload" ]] ||
  [[ "$tap_checksum_line_count" != 6 ]]; then
  echo "candidate SHA256SUMS does not contain the exact six release payloads" >&2
  exit 1
fi
(
  cd -- "$tap_candidate_assets"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum --check SHA256SUMS >/dev/null
  else
    shasum -a 256 --check SHA256SUMS >/dev/null
  fi
)

for tap_target in aarch64-unknown-linux-gnu x86_64-unknown-linux-gnu; do
  jq -e '
      .spdxVersion == "SPDX-2.3" and
      (.documentNamespace | type == "string" and length > 0) and
      (.packages | type == "array" and length > 0)
    ' "$tap_candidate_assets/mcp-sync-v$tap_candidate_version-$tap_target.spdx.json" >/dev/null
done

tap_candidate_package="$tap_candidate_assets/enjoyable-mcp-sync-$tap_candidate_version.crate"
tap_candidate_package_hash="$(tap_sha256 "$tap_candidate_package")"
if ! cmp --silent "$tap_candidate_package" "$tap_candidate_directory/registry.crate"; then
  echo "crates.io package bytes differ from the immutable GitHub Release" >&2
  exit 1
fi
jq -e \
  --arg version "$tap_candidate_version" \
  --arg checksum "$tap_candidate_package_hash" '
    .crate.id == "enjoyable-mcp-sync" and
    .crate.name == "enjoyable-mcp-sync" and
    .crate.repository == "https://github.com/EnjoyableWork/mcp-sync" and
    .crate.trustpub_only == true and
    (.versions | type == "array" and length > 0) and
    ([.versions[].num] | length == (unique | length)) and
    all(.versions[];
      (.num | test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))) and
    ([.versions[] |
      select(.num == $version and .yanked == false and
        .crate == "enjoyable-mcp-sync" and .checksum == $checksum)] | length) == 1
  ' "$tap_candidate_directory/registry.json" >/dev/null

tap_registry_greatest_version=
while IFS= read -r tap_registry_version; do
  if [[ -z "$tap_registry_greatest_version" ]] ||
    tap_semver_greater_than "$tap_registry_version" "$tap_registry_greatest_version"; then
    tap_registry_greatest_version=$tap_registry_version
  fi
done < <(jq -r '.versions[].num' "$tap_candidate_directory/registry.json")
if [[ "$tap_registry_greatest_version" != "$tap_candidate_version" ]]; then
  echo "requested mcp-sync version is stale relative to crates.io" >&2
  exit 1
fi

tap_candidate_formula="$tap_candidate_assets/mcp-sync.rb"
tap_candidate_formula_version="$(tap_formula_version "$tap_candidate_formula" candidate)"
tap_candidate_formula_hash="$(tap_formula_hash "$tap_candidate_formula" candidate)"
if ! ruby -c "$tap_candidate_formula" >/dev/null 2>&1; then
  echo "candidate mcp-sync formula is not valid Ruby" >&2
  exit 1
fi
if [[ "$tap_candidate_formula_version" != "$tap_candidate_version" ]] ||
  [[ "$tap_candidate_formula_hash" != "$tap_candidate_package_hash" ]]; then
  echo "candidate formula version or package hash differs from the verified release" >&2
  exit 1
fi
for tap_formula_contract in \
  'class McpSync < Formula' \
  '  homepage "https://github.com/EnjoyableWork/mcp-sync"' \
  "  url \"https://github.com/EnjoyableWork/mcp-sync/releases/download/v$tap_candidate_version/enjoyable-mcp-sync-$tap_candidate_version.crate\"" \
  "  sha256 \"$tap_candidate_package_hash\"" \
  '  license "MIT"' \
  '  depends_on "rust" => :build'; do
  tap_require_formula_line "$tap_candidate_formula" "$tap_formula_contract"
done

tap_current_version="$(tap_formula_version "$tap_current_formula" current)"
if ! ruby -c "$tap_current_formula" >/dev/null 2>&1; then
  echo "current mcp-sync formula is not valid Ruby" >&2
  exit 1
fi
tap_verify_release_identity "$tap_prior_directory" "$tap_current_version" prior
tap_prior_release_commit=$tap_verified_release_commit
tap_verify_attestation_marker \
  "$tap_prior_directory/attestations.json" \
  "$tap_current_version" \
  "$tap_prior_release_commit" \
  "$tap_prior_assets" \
  formula
tap_verify_release_metadata_digest \
  "$tap_prior_directory/release.json" \
  "$tap_prior_assets/SHA256SUMS"
tap_verify_release_metadata_digest \
  "$tap_prior_directory/release.json" \
  "$tap_prior_assets/mcp-sync.rb"

tap_prior_payload="$(tap_release_payload_names "$tap_current_version" | sort)"
tap_prior_checksum_entries="$(
  sed -n 's/^[0-9a-f]\{64\}  \([^/][^/]*\)$/\1/p' \
    "$tap_prior_assets/SHA256SUMS" | sort
)"
tap_prior_checksum_line_count="$(wc -l <"$tap_prior_assets/SHA256SUMS" | tr -d '[:space:]')"
if [[ "$tap_prior_checksum_entries" != "$tap_prior_payload" ]] ||
  [[ "$tap_prior_checksum_line_count" != 6 ]]; then
  echo "prior SHA256SUMS does not describe its exact six release payloads" >&2
  exit 1
fi
tap_prior_formula_hash="$(tap_formula_hash "$tap_prior_assets/mcp-sync.rb" prior)"
if ! ruby -c "$tap_prior_assets/mcp-sync.rb" >/dev/null 2>&1; then
  echo "prior mcp-sync release formula is not valid Ruby" >&2
  exit 1
fi
tap_prior_package_hash="$(
  awk -v asset="enjoyable-mcp-sync-$tap_current_version.crate" \
    '$2 == asset { print $1 }' "$tap_prior_assets/SHA256SUMS"
)"
if [[ ! "$tap_prior_package_hash" =~ ^[0-9a-f]{64}$ ]] ||
  [[ "$tap_prior_formula_hash" != "$tap_prior_package_hash" ]] ||
  [[ "$(tap_formula_version "$tap_prior_assets/mcp-sync.rb" prior)" != "$tap_current_version" ]] ||
  ! cmp --silent "$tap_current_formula" "$tap_prior_assets/mcp-sync.rb"; then
  echo "current tap formula is not exact to its own immutable attested release" >&2
  exit 1
fi

case "$tap_candidate_mode" in
  rehearse)
    if [[ "$tap_candidate_version" != "$tap_current_version" ]] ||
      ! cmp --silent "$tap_candidate_formula" "$tap_current_formula"; then
      echo "tap rehearsal requires the exact already-published immutable formula" >&2
      exit 1
    fi
    printf 'noop %s\n' "$tap_candidate_release_commit"
    ;;
  publish)
    if ! tap_semver_greater_than "$tap_candidate_version" "$tap_current_version"; then
      echo "tap publication requires a version newer than the current formula" >&2
      exit 1
    fi
    if cmp --silent "$tap_candidate_formula" "$tap_current_formula"; then
      echo "tap publication cannot overwrite the current formula with identical bytes" >&2
      exit 1
    fi
    printf 'publish %s\n' "$tap_candidate_release_commit"
    ;;
esac
