#!/bin/bash
# new_project.sh -- start a new GEL project from this template.
#
#   ./new_project.sh <new project directory>
#
# Copies the template (code only: no data, outputs, bundles or backups) and
# names the project after the directory.

set -euo pipefail
dest="${1:?usage: ./new_project.sh <new project directory>}"
[[ -e "$dest" ]] && { echo "new_project: $dest already exists" >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
name="$(basename "$dest")"

mkdir -p "$dest"
( cd "$here" && tar cf - \
    --exclude ./new_project.sh --exclude ./bundle.txt --exclude ./.bundle_applied \
    --exclude ./.bundle_backup --exclude ./data --exclude ./pipeline/work \
    --exclude ./pipeline/nf_work --exclude ./pipeline/.nextflow --exclude ./pipeline/logs \
    --exclude './pipeline/.nextflow.log*' --exclude .DS_Store . ) | ( cd "$dest" && tar xf - )
sed -e "s/^PROJECT=.*/PROJECT=\"$name\"/" "$dest/.bundle.conf" > "$dest/.bundle.conf.new"
mv "$dest/.bundle.conf.new" "$dest/.bundle.conf"
chmod +x "$dest/bundle.sh"

cat <<MSG
created $dest (project "$name")
next:
  cd $dest
  Rscript tools/make_mock.R          # mock inputs, local runs
  # replace the example step scripts, processes, config and data_structure.txt
  ./bundle.sh pack                   # -> bundle.txt; on GEL: paste, save, bash bundle.txt
MSG
