#!/bin/bash
# bundle.sh -- move source code into an air-gapped platform by copy-paste.
#
# Same script runs on both sides.
#
#   local            ./bundle.sh pack        source tree -> bundle.txt (+ clipboard)
#   paste            open an editor on the platform, paste, save as bundle.txt
#   platform         ./bundle.sh populate    bundle.txt -> source tree
#
# First time on a fresh platform project there is no bundle.sh yet, so run
# "bash bundle.txt" instead -- the bundle is self-extracting and installs
# bundle.sh along with everything else.
#
# Other subcommands:
#   ./bundle.sh init      scaffold .bundle.conf and data_structure.txt
#   ./bundle.sh list      show what a bundle contains, write nothing
#   ./bundle.sh check     validate data files against data_structure.txt
#
# No dependencies beyond bash and coreutils. No git required.

set -euo pipefail

VERSION=1
CONF_FILE=".bundle.conf"
STRUCT_FILE="data_structure.txt"

# --- defaults, overridable in .bundle.conf ---------------------------------

PROJECT="$(basename "$PWD")"
BUNDLE_FILE="bundle.txt"
BACKUP_DIR=".bundle_backup"
BACKUP_KEEP=5
MAX_FILE_BYTES=1048576

# Extensions that are source and therefore packed. Files with no extension are
# packed only if named in INCLUDE_NAMES.
INCLUDE_EXT="r R sh py pl md txt conf cfg ini yaml yml json sql"
INCLUDE_NAMES="Makefile Dockerfile"

# Directories never descended into.
EXCLUDE_DIRS="prepared results logs .bundle_backup .git .svn node_modules __pycache__ .Rproj.user"

# Extensions that are data and must NEVER travel. Enforced when packing and
# again when populating, so a hand-edited bundle still cannot overwrite data.
NEVER_PACK_EXT="csv tsv tab rds rda RData vcf bcf gz bz2 zip bgen bgi sample bam bai cram crai bed bim fam pgen pvar psam parquet feather h5 hdf5 npy npz png jpg jpeg pdf xlsx doc docx"

[[ -f "$CONF_FILE" ]] && . "./$CONF_FILE"

# --- portability helpers ---------------------------------------------------

sha_of() {   # sha256 of a file, bare hex
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

sha_of_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
    else shasum -a 256 | cut -d' ' -f1; fi
}

b64_encode() { base64 | tr -d '\n' | fold -w 76; }

b64_decode() {
    if base64 --help 2>&1 | grep -q -- '-d,'; then tr -d '\n' | base64 -d
    elif base64 -d </dev/null >/dev/null 2>&1; then tr -d '\n' | base64 -d
    else tr -d '\n' | base64 -D; fi
}

size_of() { wc -c < "$1" | tr -d ' '; }

die() { echo "bundle: $*" >&2; exit 1; }

# --- file selection --------------------------------------------------------

ext_of() {
    local base="${1##*/}"
    [[ "$base" == *.* ]] && printf '%s' "${base##*.}" || printf ''
}

in_list() {   # in_list <needle> <space separated haystack>
    local needle="$1" item
    for item in $2; do [[ "$item" == "$needle" ]] && return 0; done
    return 1
}

is_data_file() {
    local e; e="$(ext_of "$1")"
    [[ -n "$e" ]] && in_list "$e" "$NEVER_PACK_EXT"
}

should_pack() {
    local path="$1" base="${1##*/}" e
    [[ "$base" == "$BUNDLE_FILE" ]] && return 1
    is_data_file "$path" && return 1
    e="$(ext_of "$path")"
    if [[ -z "$e" ]]; then in_list "$base" "$INCLUDE_NAMES"; return $?; fi
    in_list "$e" "$INCLUDE_EXT"
}

list_source_files() {
    local prune=() d
    for d in $EXCLUDE_DIRS; do prune+=( -name "$d" -o ); done
    # shellcheck disable=SC2086
    find . \( "${prune[@]}" -false \) -prune -o -type f -print 2>/dev/null \
        | sed 's|^\./||' | sort | while IFS= read -r f; do
            should_pack "$f" && printf '%s\n' "$f"
        done
}

# --- pack ------------------------------------------------------------------

cmd_pack() {
    local files tmp tar_file payload manifest n bytes id created
    files="$(list_source_files)"
    [[ -z "$files" ]] && die "no source files found under $PWD"

    n=0; bytes=0
    while IFS= read -r f; do
        local sz; sz="$(size_of "$f")"
        (( sz > MAX_FILE_BYTES )) && die "$f is ${sz}B, over MAX_FILE_BYTES ($MAX_FILE_BYTES)"
        n=$(( n + 1 )); bytes=$(( bytes + sz ))
    done <<< "$files"

    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    tar_file="$tmp/payload.tgz"

    COPYFILE_DISABLE=1 tar -czf "$tar_file" --format=ustar -T <(printf '%s\n' "$files") 2>/dev/null \
        || COPYFILE_DISABLE=1 tar -czf "$tar_file" -T <(printf '%s\n' "$files")

    payload="$(b64_encode < "$tar_file")"
    local payload_sha; payload_sha="$(printf '%s' "$payload" | tr -d '\n' | sha_of_stdin)"

    manifest=""
    while IFS= read -r f; do
        manifest+="$(printf '%s|%s|%s' "$f" "$(size_of "$f")" "$(sha_of "$f")")"$'\n'
    done <<< "$files"

    created="$(date -u +%Y-%m-%dT%H:%MZ)"
    id="$(printf '%s' "$manifest" | sha_of_stdin | cut -c1-7)"

    {
        echo "#!/bin/bash"
        echo "# ===== bundle v$VERSION ====="
        echo "# project : $PROJECT"
        echo "# created : $created"
        echo "# id      : $id"
        echo "# files   : $n   source bytes: $bytes"
        echo "#"
        echo "# Apply with:  ./bundle.sh populate      (or: bash $BUNDLE_FILE)"
        echo "#"
        echo "# If bash reports \"unexpected EOF\" the paste was cut short."
        echo "# Nothing is written in that case -- re-copy and paste again."
        echo "#"
        echo "# contents:"
        while IFS='|' read -r p s h; do
            [[ -z "$p" ]] && continue
            printf '#   %-44s %8s  %s\n' "$p" "$s" "${h:0:12}"
        done <<< "$manifest"
        echo

        cat <<'__HEAD__'
set -euo pipefail
DRY_RUN="${BUNDLE_DRY_RUN:-0}"
PRUNE="${BUNDLE_PRUNE:-0}"
__HEAD__

        echo "BUNDLE_ID='$id'"
        echo "BUNDLE_CREATED='$created'"
        echo "BUNDLE_PROJECT='$PROJECT'"
        echo "PAYLOAD_SHA='$payload_sha'"
        echo "NEVER_PACK_EXT='$NEVER_PACK_EXT'"
        echo "INCLUDE_EXT='$INCLUDE_EXT'"
        echo "INCLUDE_NAMES='$INCLUDE_NAMES'"
        echo "EXCLUDE_DIRS='$EXCLUDE_DIRS'"
        echo "BUNDLE_FILE='$BUNDLE_FILE'"
        echo "MAX_FILE_BYTES='$MAX_FILE_BYTES'"
        echo "BACKUP_DIR='$BACKUP_DIR'"
        echo "BACKUP_KEEP='$BACKUP_KEEP'"
        echo
        echo "MANIFEST=\$(cat <<'__MANIFEST__'"
        printf '%s' "$manifest"
        echo "__MANIFEST__"
        echo ")"
        echo
        echo "PAYLOAD=\$(cat <<'__PAYLOAD__'"
        printf '%s\n' "$payload"
        echo "__PAYLOAD__"
        echo ")"
        echo

        cat <<'__BODY__'
sha_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
sha_of_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
    else shasum -a 256 | cut -d' ' -f1; fi
}
b64_decode() {
    if base64 -d </dev/null >/dev/null 2>&1; then tr -d '\n' | base64 -d
    else tr -d '\n' | base64 -D; fi
}
die() { echo "bundle: $*" >&2; exit 1; }

in_list() { local x="$1" i; for i in $2; do [[ "$i" == "$x" ]] && return 0; done; return 1; }
is_data_file() {
    local b="${1##*/}" e
    [[ "$b" == *.* ]] || return 1
    e="${b##*.}"
    in_list "$e" "$NEVER_PACK_EXT"
}

echo "bundle $BUNDLE_ID  ($BUNDLE_PROJECT, created $BUNDLE_CREATED)"

got="$(printf '%s' "$PAYLOAD" | tr -d '\n' | sha_of_stdin)"
[[ "$got" == "$PAYLOAD_SHA" ]] || die "payload checksum mismatch -- the paste is incomplete or corrupted.
  expected $PAYLOAD_SHA
  got      $got
Nothing was written. Re-copy the bundle and paste again."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf '%s' "$PAYLOAD" | b64_decode | tar -xzf - -C "$tmp" || die "could not unpack payload"

# verify every extracted file before touching the working tree
bad=0
while IFS='|' read -r path size want; do
    [[ -z "$path" ]] && continue
    case "$path" in /*|*..*) die "refusing unsafe path in manifest: $path" ;; esac
    is_data_file "$path" && die "refusing data file in bundle: $path"
    [[ -f "$tmp/$path" ]] || { echo "  MISSING in payload: $path"; bad=1; continue; }
    have="$(sha_of "$tmp/$path")"
    [[ "$have" == "$want" ]] || { echo "  CHECKSUM FAILED: $path"; bad=1; }
done <<< "$MANIFEST"
(( bad )) && die "verification failed; nothing was written"

new=0; upd=0; same=0
while IFS='|' read -r path size want; do
    [[ -z "$path" ]] && continue
    if [[ -f "$path" ]]; then
        if [[ "$(sha_of "$path")" == "$want" ]]; then same=$(( same + 1 ))
        else upd=$(( upd + 1 )); echo "  update  $path"; fi
    else
        new=$(( new + 1 )); echo "  new     $path"
    fi
done <<< "$MANIFEST"

# The same selection rule the packer uses. Prune must never consider anything
# the packer would not have packed -- data, results, logs, backups -- or it
# would delete them for being "absent from the bundle".
is_source() {
    local f="$1" base="${1##*/}" d
    [[ "$base" == "$BUNDLE_FILE" ]] && return 1
    for d in $EXCLUDE_DIRS; do
        case "/$f/" in */"$d"/*) return 1 ;; esac
    done
    is_data_file "$f" && return 1
    # the packer refuses anything larger, so no bundle can have delivered it
    (( $(wc -c < "$f") > ${MAX_FILE_BYTES:-1048576} )) && return 1
    if [[ "$base" == *.* ]]; then in_list "${base##*.}" "$INCLUDE_EXT"
    else in_list "$base" "$INCLUDE_NAMES"; fi
}

stale=""
if [[ "$PRUNE" == "1" ]]; then
    manifest_paths="$(cut -d'|' -f1 <<< "$MANIFEST")"
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        is_source "$f" || continue
        grep -qxF -- "$f" <<< "$manifest_paths" || { stale+="$f"$'\n'; echo "  prune   $f"; }
    done < <(find . -type f 2>/dev/null | sed 's|^\./||' | sort)
fi
nstale=$(grep -c . <<< "$stale" || true)

echo "  ($new new, $upd updated, $same unchanged)"

if [[ "$DRY_RUN" == "1" ]]; then
    echo "dry run -- nothing written"
    exit 0
fi

# back up anything about to be replaced or pruned; there is no git here to fall back on
stamp="$BACKUP_DIR/$(date -u +%Y%m%d-%H%M%S)"
if (( upd > 0 )); then
    mkdir -p "$stamp"
    while IFS='|' read -r path size want; do
        [[ -z "$path" ]] && continue
        [[ -f "$path" ]] || continue
        [[ "$(sha_of "$path")" == "$want" ]] && continue
        mkdir -p "$stamp/$(dirname "$path")"
        cp -p "$path" "$stamp/$path"
    done <<< "$MANIFEST"
    echo "  backed up $upd replaced file(s) to $stamp/"
fi

# Write only what differs. An unchanged file keeps its timestamp, which matters
# to tools that use it to decide what to rerun (Nextflow, make).
while IFS='|' read -r path size want; do
    [[ -z "$path" ]] && continue
    [[ -f "$path" && "$(sha_of "$path")" == "$want" ]] && continue
    mkdir -p "$(dirname "$path")"
    cp "$tmp/$path" "$path"
done <<< "$MANIFEST"

if (( nstale > 0 )); then
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        mkdir -p "$stamp/$(dirname "$f")"
        cp -p "$f" "$stamp/$f" && rm -f "$f"
        rmdir -p "$(dirname "$f")" 2>/dev/null || true   # only directories now empty
    done <<< "$stale"
    echo "  pruned $nstale file(s); copies kept in $stamp/"
fi

# keep the backup directory from growing without bound
if [[ -d "$BACKUP_DIR" ]]; then
    ls -1dt "$BACKUP_DIR"/*/ 2>/dev/null | tail -n +$(( BACKUP_KEEP + 1 )) \
        | while IFS= read -r old; do rm -rf "$old"; done
fi

[[ -f bundle.sh ]] && chmod +x bundle.sh 2>/dev/null || true
for s in $(grep -o '^[^|]*\.sh' <<< "$MANIFEST" || true); do
    [[ -f "$s" ]] && chmod +x "$s" 2>/dev/null || true
done

# record what is installed here, so a run can say which code it used
printf '%s  created %s  applied %s\n' "$BUNDLE_ID" "$BUNDLE_CREATED" "$(date -u +%Y-%m-%dT%H:%MZ)" > .bundle_applied
echo "done -- bundle $BUNDLE_ID applied in $PWD"
exit 0
__BODY__

    } > "$BUNDLE_FILE"

    local out_size; out_size="$(size_of "$BUNDLE_FILE")"
    echo "packed $n files ($bytes B source) -> $BUNDLE_FILE ($out_size B, id $id)"

    if command -v pbcopy >/dev/null 2>&1; then
        pbcopy < "$BUNDLE_FILE"
        echo "copied to clipboard -- paste into the platform and save as $BUNDLE_FILE"
    else
        echo "copy $BUNDLE_FILE to the platform and save it there as $BUNDLE_FILE"
    fi
}

# --- list ------------------------------------------------------------------

cmd_list() {
    local f="${1:-$BUNDLE_FILE}"
    [[ -f "$f" ]] || die "$f not found"
    sed -n '1,/^$/p' "$f" | sed 's/^# \{0,1\}//'
}

# --- populate --------------------------------------------------------------

cmd_populate() {
    local dry=0 prune=0 f="$BUNDLE_FILE"
    while (( $# )); do
        case "$1" in
            --dry-run) dry=1 ;;
            --prune)   prune=1 ;;
            -*) die "unknown option $1" ;;
            *) f="$1" ;;
        esac
        shift
    done
    [[ -f "$f" ]] || die "$f not found -- paste the bundle and save it as $f first"
    BUNDLE_DRY_RUN="$dry" BUNDLE_PRUNE="$prune" bash "$f"
}

# --- check -----------------------------------------------------------------
#
# Validate real (or mock) data files against data_structure.txt. Deliberately
# shallow: existence, delimiter, column count, declared header names, and a
# dtype spot check. Fast enough to run before every job submission.

cmd_check() {
    local root="."
    while (( $# )); do
        case "$1" in
            --root) root="$2"; shift ;;
            *) die "unknown option $1" ;;
        esac
        shift
    done
    [[ -f "$STRUCT_FILE" ]] || die "$STRUCT_FILE not found (run: ./bundle.sh init)"

    local path delim header ncols_spec rows_spec blank_spec kw rest fail=0 nfile=0
    local -a want_cols

    _reset_file_state() {
        path=""; delim=""; header=""; ncols_spec=""
        rows_spec=""; blank_spec=""; want_cols=()
    }

    _finish_file() {
        [[ -z "${path:-}" ]] && return 0
        nfile=$(( nfile + 1 ))
        local full="$root/$path"
        if [[ ! -f "$full" ]]; then
            printf '  %-52s MISSING\n' "$path"; fail=1
            _reset_file_state; return 0
        fi

        local d="${delim:-,}"
        [[ "$d" == "tab" || "$d" == '\t' ]] && d=$'\t'

        local got_ncol; got_ncol="$(awk -F"$d" 'NR==1{print NF}' "$full")"
        local nrow; nrow="$(wc -l < "$full" | tr -d ' ')"

        local status="ok" notes=""

        if [[ -n "${ncols_spec:-}" ]]; then
            case "$ncols_spec" in
                *+*) local base="${ncols_spec%%+*}"; base="${base// /}"
                     (( got_ncol >= base )) || { status="FAIL"; notes+=" cols<$base"; } ;;
                *)   local want="${ncols_spec// /}"
                     [[ "$got_ncol" == "$want" ]] || { status="FAIL"; notes+=" cols=$got_ncol want=$want"; } ;;
            esac
        fi

        if [[ -n "${blank_spec:-}" ]]; then
            local nblank; nblank="$(awk -F"$d" -v n="$blank_spec" \
                'NR==1{c=0; for(i=1;i<=n;i++) if($i=="") c++; print c; exit}' "$full")"
            [[ "$nblank" == "$blank_spec" ]] \
                || { status="FAIL"; notes+=" first $blank_spec header fields not blank (got $nblank)"; }
        fi

        if [[ "${header:-yes}" == "yes" && ${#want_cols[@]} -gt 0 ]]; then
            local c
            for c in "${want_cols[@]}"; do
                awk -F"$d" -v want="$c" 'NR==1{for(i=1;i<=NF;i++) if($i==want){found=1}} END{exit !found}' "$full" \
                    || { status="FAIL"; notes+=" no column '$c'"; }
            done
        fi

        [[ "$status" == "FAIL" ]] && fail=1
        printf '  %-52s %-4s %6s cols %8s rows%s\n' "$path" "$status" "$got_ncol" "$nrow" "$notes"

        _reset_file_state
    }

    echo "checking data against $STRUCT_FILE (root: $root)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue
        # split into keyword and remainder, tolerating any run of whitespace
        kw="${line%%[[:space:]]*}"
        rest="${line#"$kw"}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        case "$kw" in
            file)   _finish_file; path="$rest" ;;
            delim)  delim="$rest" ;;
            header) header="$rest" ;;
            cols)   ncols_spec="$rest" ;;
            blank)  blank_spec="$rest" ;;
            rows)   rows_spec="$rest" ;;
            col)    want_cols+=( "${rest%%[[:space:]]*}" ) ;;
            colset) : ;;
            end)    _finish_file ;;
        esac
    done < "$STRUCT_FILE"
    _finish_file

    echo
    if (( fail )); then
        echo "FAILED -- data does not match $STRUCT_FILE"; exit 1
    fi
    echo "all $nfile file(s) match $STRUCT_FILE"
}

# --- init ------------------------------------------------------------------

cmd_init() {
    if [[ -f "$CONF_FILE" ]]; then
        echo "$CONF_FILE exists, leaving it alone"
    else
        cat > "$CONF_FILE" <<EOF
# bundle.sh configuration
PROJECT="$(basename "$PWD")"
BUNDLE_FILE="bundle.txt"

INCLUDE_EXT="r R sh py pl md txt conf cfg ini yaml yml json sql"
INCLUDE_NAMES="Makefile Dockerfile"
EXCLUDE_DIRS="prepared results logs .bundle_backup .git node_modules __pycache__"

# Never travels, enforced when packing and again when populating.
NEVER_PACK_EXT="csv tsv tab rds rda RData vcf bcf gz bz2 zip bgen bgi sample bam bai cram crai bed bim fam pgen pvar psam parquet feather h5 hdf5 npy npz png jpg jpeg pdf xlsx doc docx"

MAX_FILE_BYTES=1048576
BACKUP_KEEP=5
EOF
        echo "wrote $CONF_FILE"
    fi

    if [[ -f "$STRUCT_FILE" ]]; then
        echo "$STRUCT_FILE exists, leaving it alone"
    else
        cat > "$STRUCT_FILE" <<'EOF'
# data_structure.txt -- what the data is expected to look like.
#
# Checked by:  ./bundle.sh check            (real data, on the platform)
#              ./bundle.sh check --root .   (mock data, locally)
#
# Paths are relative to the project root. Data files themselves never travel
# in a bundle; this file records their shape so both sides agree.
#
# Grammar:
#   file <path>
#     desc   <free text>
#     delim  , | tab
#     header yes | no
#     cols   <n>  or  <n> + N    (N = variable, e.g. one column per sample)
#     blank  <n>                 first n header fields are empty in the file
#     col    <name> <type> [note]
#     colset <range> <type> [note]
#     rows   <approx>
#   end

file example/path.csv
  desc    one line describing the file
  delim   ,
  header  yes
  cols    3
  col     id     str
  col     value  float
  col     group  str
  rows    ~1000
end
EOF
        echo "wrote $STRUCT_FILE"
    fi
    echo "edit both, then: ./bundle.sh pack"
}

# --- dispatch --------------------------------------------------------------

usage() {
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
    pack)     shift; cmd_pack "$@" ;;
    populate) shift; cmd_populate "$@" ;;
    list)     shift; cmd_list "$@" ;;
    check)    shift; cmd_check "$@" ;;
    init)     shift; cmd_init "$@" ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown subcommand '$1' (try: pack, populate, list, check, init)" ;;
esac
