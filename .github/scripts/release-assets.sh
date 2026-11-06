#!/bin/bash
# Build the release assets for one tagged version.
#
# Usage: release-assets.sh <version> <output-dir>
#
# Writes to <output-dir>:
#   ptz-patrol-<version>.tar.gz  the deployable files, taken from the Git commit
#                                at HEAD, not from the working tree
#   SHA256SUMS                   one line for each deployable file and the tarball
#
# The checksums list each file separately, so a user can verify the raw files
# that install.sh downloads, not only the tarball.
set -euo pipefail

version="${1:?usage: release-assets.sh <version> <output-dir>}"
out_dir="${2:?usage: release-assets.sh <version> <output-dir>}"

# Keep this list in sync with the files that install.sh deploys.
files=(
  install.sh
  uninstall.sh
  api.sh
  discover.sh
  patrol.sh
  ptz-patrol.sh
  ptz-patrol.service
  config.json.example
  README.md
  CHANGELOG.md
  LICENSE
  VERSION
)

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

for f in "${files[@]}"; do
  if ! git cat-file -e "HEAD:$f" 2>/dev/null; then
    echo "error: $f is not in the commit at HEAD" >&2
    exit 1
  fi
done

head_version=$(git show HEAD:VERSION | tr -d '[:space:]')
if [[ "$head_version" != "$version" ]]; then
  echo "error: VERSION at HEAD is '$head_version', expected '$version'" >&2
  exit 1
fi

mkdir -p "$out_dir"
tarball="ptz-patrol-${version}.tar.gz"
git archive --format=tar.gz --prefix="ptz-patrol-${version}/" \
  --output="$out_dir/$tarball" HEAD -- "${files[@]}"

# Hash the committed content of each file, so the checksums match the raw
# files on GitHub for this tag.
sums_tmp=$(mktemp)
trap 'rm -f "$sums_tmp"' EXIT
for f in "${files[@]}"; do
  printf '%s  %s\n' "$(git show "HEAD:$f" | sha256sum | cut -d' ' -f1)" "$f" >> "$sums_tmp"
done
(cd "$out_dir" && sha256sum "$tarball") >> "$sums_tmp"
chmod 644 "$sums_tmp"
mv "$sums_tmp" "$out_dir/SHA256SUMS"
trap - EXIT

echo "Built release assets for $version in $out_dir:"
ls -l "$out_dir"
