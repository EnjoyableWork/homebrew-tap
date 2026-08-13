#!/usr/bin/env bash

set -euo pipefail
LC_ALL=C
export LC_ALL

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <tap checkout> <candidate formula> <exact base commit>" >&2
  exit 2
fi

tap_checkout=$1
tap_candidate_formula=$2
tap_expected_base=$3

if [[ ! "$tap_expected_base" =~ ^[0-9a-f]{40}$ ]]; then
  echo "tap base must be one exact lowercase commit" >&2
  exit 1
fi
if [[ ! -d "$tap_checkout" || -L "$tap_checkout" ]]; then
  echo "tap checkout must be a regular directory" >&2
  exit 1
fi
if [[ ! -f "$tap_candidate_formula" || -L "$tap_candidate_formula" ]]; then
  echo "candidate mcp-sync formula must be a regular, non-symbolic-link file" >&2
  exit 1
fi

tap_checkout=$(cd -- "$tap_checkout" && pwd -P)
if [[ "$(git -C "$tap_checkout" rev-parse --show-toplevel)" != "$tap_checkout" ]] ||
  [[ "$(git -C "$tap_checkout" rev-parse HEAD)" != "$tap_expected_base" ]]; then
  echo "tap checkout is not the exact verified repository commit" >&2
  exit 1
fi
if [[ -n "$(git -C "$tap_checkout" status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "tap checkout contains a pre-existing sibling or extra path change" >&2
  exit 1
fi

tap_formula="$tap_checkout/Formula/mcp-sync.rb"
tap_sibling_formula="$tap_checkout/Formula/mcp-doctor.rb"
if [[ ! -f "$tap_formula" || -L "$tap_formula" ]] ||
  [[ ! -f "$tap_sibling_formula" || -L "$tap_sibling_formula" ]]; then
  echo "tap formula targets must be regular, non-symbolic-link files" >&2
  exit 1
fi
if cmp --silent "$tap_candidate_formula" "$tap_formula"; then
  echo "tap publish candidate is already installed" >&2
  exit 1
fi

install -m 0644 "$tap_candidate_formula" "$tap_formula"
tap_changed_paths="$(git -C "$tap_checkout" diff --name-only --diff-filter=ACDMRTUXB)"
tap_status="$(git -C "$tap_checkout" status --porcelain=v1 --untracked-files=all)"
if [[ "$tap_changed_paths" != Formula/mcp-sync.rb ]] ||
  [[ "$tap_status" != ' M Formula/mcp-sync.rb' ]]; then
  echo "tap staging changed a sibling or extra path" >&2
  exit 1
fi
if ! git -C "$tap_checkout" diff --quiet -- Formula/mcp-doctor.rb; then
  echo "tap staging changed Formula/mcp-doctor.rb" >&2
  exit 1
fi

git -C "$tap_checkout" add -- Formula/mcp-sync.rb
tap_staged_paths="$(git -C "$tap_checkout" diff --cached --name-only --diff-filter=ACDMRTUXB)"
tap_status="$(git -C "$tap_checkout" status --porcelain=v1 --untracked-files=all)"
if [[ "$tap_staged_paths" != Formula/mcp-sync.rb ]] ||
  [[ "$tap_status" != 'M  Formula/mcp-sync.rb' ]] ||
  ! git -C "$tap_checkout" diff --quiet; then
  echo "tap index contains a sibling, extra, or unstaged path" >&2
  exit 1
fi

printf 'Formula/mcp-sync.rb\n'
