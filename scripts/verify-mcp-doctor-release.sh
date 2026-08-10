#!/usr/bin/env bash

set -euo pipefail
LC_ALL=C
export LC_ALL

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <candidate directory> <stable version> <rehearse|publish> <current formula>" >&2
  exit 2
fi

tap_candidate_directory=$1
tap_candidate_version=$2
tap_candidate_mode=$3
tap_current_formula=$4

tap_stable_version_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
if [[ ! "${tap_candidate_version}" =~ ${tap_stable_version_pattern} ]]; then
  echo "mcp-doctor tap version must be a canonical stable semantic version" >&2
  exit 1
fi
if [[ ! -d "${tap_candidate_directory}" || -L "${tap_candidate_directory}" ]]; then
  echo "mcp-doctor tap candidate directory is missing or symbolic" >&2
  exit 1
fi
if [[ ! -f "${tap_current_formula}" || -L "${tap_current_formula}" ]]; then
  echo "current mcp-doctor formula must be a regular file" >&2
  exit 1
fi

tap_semver_greater_than() {
  local candidate=$1
  local baseline=$2
  local candidate_major candidate_minor candidate_patch
  local baseline_major baseline_minor baseline_patch

  IFS=. read -r candidate_major candidate_minor candidate_patch <<<"${candidate}"
  IFS=. read -r baseline_major baseline_minor baseline_patch <<<"${baseline}"

  if [[ "${candidate_major}" != "${baseline_major}" ]]; then
    tap_numeric_component_greater "${candidate_major}" "${baseline_major}"
    return
  fi
  if [[ "${candidate_minor}" != "${baseline_minor}" ]]; then
    tap_numeric_component_greater "${candidate_minor}" "${baseline_minor}"
    return
  fi
  tap_numeric_component_greater "${candidate_patch}" "${baseline_patch}"
}

tap_numeric_component_greater() {
  local candidate=$1
  local baseline=$2

  if ((${#candidate} != ${#baseline})); then
    ((${#candidate} > ${#baseline}))
    return
  fi
  [[ "${candidate}" > "${baseline}" ]]
}

case "${tap_candidate_mode}" in
  rehearse)
    if [[ "${tap_candidate_version}" != 0.1.0 ]]; then
      echo "tap rehearsal reuses only immutable mcp-doctor v0.1.0" >&2
      exit 1
    fi
    ;;
  publish)
    tap_current_version=$(
      sed -n \
        's#^[[:space:]]*url "https://github.com/EnjoyableWork/mcp-doctor/releases/download/v\([0-9][0-9.]*\)/mcp-doctor-[0-9][0-9.]*\.crate"$#\1#p' \
        "${tap_current_formula}"
    )
    if [[ ! "${tap_current_version}" =~ ${tap_stable_version_pattern} ]]; then
      echo "current mcp-doctor formula version could not be determined safely" >&2
      exit 1
    fi
    if ! tap_semver_greater_than "${tap_candidate_version}" "${tap_current_version}"; then
      echo "tap publication requires a version newer than the current formula" >&2
      exit 1
    fi
    ;;
  *)
    echo "mcp-doctor tap mode must be rehearse or publish" >&2
    exit 2
    ;;
esac

tap_candidate_directory=$(cd -- "${tap_candidate_directory}" && pwd)
tap_candidate_package="mcp-doctor-${tap_candidate_version}.crate"
tap_candidate_expected=(
  SHA256SUMS
  annotated-tag.json
  mcp-doctor.rb
  "${tap_candidate_package}"
  provenance-verified
  release.json
  tag-ref.json
)
tap_candidate_observed=$(
  find "${tap_candidate_directory}" -maxdepth 1 -type f -print \
    | sed 's#^.*/##' \
    | LC_ALL=C sort
)
tap_candidate_expected_sorted=$(printf '%s\n' "${tap_candidate_expected[@]}" | LC_ALL=C sort)
if [[ "${tap_candidate_observed}" != "${tap_candidate_expected_sorted}" ]]; then
  echo "mcp-doctor tap candidate is incomplete or contains unexpected files" >&2
  exit 1
fi

tap_candidate_tag="v${tap_candidate_version}"
jq -e \
  --arg tag "${tap_candidate_tag}" \
  '.tag_name == $tag and .draft == false and .prerelease == false and .immutable == true' \
  "${tap_candidate_directory}/release.json" >/dev/null
jq -e \
  --arg ref "refs/tags/${tap_candidate_tag}" \
  '.ref == $ref and .object.type == "tag" and (.object.sha | test("^[0-9a-f]{40}$"))' \
  "${tap_candidate_directory}/tag-ref.json" >/dev/null
jq -e \
  --arg tag "${tap_candidate_tag}" \
  '.tag == $tag and .object.type == "commit" and (.object.sha | test("^[0-9a-f]{40}$"))' \
  "${tap_candidate_directory}/annotated-tag.json" >/dev/null

tap_release_commit=$(jq -r '.object.sha' "${tap_candidate_directory}/annotated-tag.json")
if [[ "$(tr -d '[:space:]' <"${tap_candidate_directory}/provenance-verified")" != "${tap_release_commit}" ]]; then
  echo "mcp-doctor tap candidate lacks exact-commit provenance evidence" >&2
  exit 1
fi

tap_checksum_entries=$(
  sed -n 's/^[[:xdigit:]]\{64\}  \([^/][^/]*\)$/\1/p' \
    "${tap_candidate_directory}/SHA256SUMS"
)
for tap_required_asset in "${tap_candidate_package}" mcp-doctor.rb; do
  tap_matching_entries=$(
    printf '%s\n' "${tap_checksum_entries}" \
      | awk -v asset="${tap_required_asset}" '$0 == asset { count++ } END { print count + 0 }'
  )
  if [[ "${tap_matching_entries}" != 1 ]]; then
    echo "SHA256SUMS does not name the required mcp-doctor handoff exactly once" >&2
    exit 1
  fi
done
(
  cd -- "${tap_candidate_directory}"
  {
    awk -v asset="${tap_candidate_package}" '$2 == asset { print }' SHA256SUMS
    awk -v asset=mcp-doctor.rb '$2 == asset { print }' SHA256SUMS
  } | if command -v sha256sum >/dev/null 2>&1; then
    sha256sum --check - >/dev/null
  else
    shasum -a 256 --check - >/dev/null
  fi
)

tap_candidate_formula="${tap_candidate_directory}/mcp-doctor.rb"
tap_candidate_package_path="${tap_candidate_directory}/${tap_candidate_package}"
tap_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print tolower($1) }'
  else
    shasum -a 256 "$1" | awk '{ print tolower($1) }'
  fi
}
tap_package_hash=$(tap_sha256 "${tap_candidate_package_path}")

for tap_formula_contract in \
  'class McpDoctor < Formula' \
  '  homepage "https://github.com/EnjoyableWork/mcp-doctor"' \
  "  url \"https://github.com/EnjoyableWork/mcp-doctor/releases/download/${tap_candidate_tag}/${tap_candidate_package}\"" \
  "  sha256 \"${tap_package_hash}\"" \
  '  license "MIT"' \
  '  depends_on "rust" => :build'; do
  if ! grep -F -x -- "${tap_formula_contract}" "${tap_candidate_formula}" >/dev/null; then
    echo "mcp-doctor formula does not match the verified source release" >&2
    exit 1
  fi
done

if [[ "${tap_candidate_mode}" == publish ]] && cmp --silent "${tap_candidate_formula}" "${tap_current_formula}"; then
  echo "mcp-doctor formula is already published; refusing to overwrite it" >&2
  exit 1
fi

printf '%s\n' "${tap_release_commit}"
