#!/bin/sh
set -eu
set -f

manifest_name=SOURCE_CANDIDATE.manifest
digest_name=SOURCE_CANDIDATE.sha256
receipt_name=SOURCE_CANDIDATE.receipt
manifest_header=codex-cove-source-candidate-v2
receipt_header=codex-cove-source-candidate-receipt-v1

fail() {
    printf 'source-candidate: %s\n' "$1" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
Usage: scripts/source-candidate.sh write [output-directory]
       scripts/source-candidate.sh verify [output-directory]

The output directory defaults to the repository root. An alternate output
directory must be outside the repository and is intended for temporary checks.
EOF
    exit 2
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

sha256_file() {
    sha256_output=$(shasum -a 256 <"$1") || fail "could not hash a candidate file"
    sha256_value=${sha256_output%% *}
    case "$sha256_value" in
        '' | *[!0-9a-f]*) fail "SHA-256 tool returned an invalid digest" ;;
    esac
    [ "${#sha256_value}" -eq 64 ] || fail "SHA-256 tool returned an invalid digest"
    printf '%s' "$sha256_value"
}

file_metadata() {
    metadata_path=$1
    case $(uname -s) in
        Darwin)
            stat -f '%Lp|%d:%i:%z:%m:%c:%p' -- "$metadata_path"
            ;;
        *)
            stat -c '%a|%d:%i:%s:%Y:%Z:%f' -- "$metadata_path" 2>/dev/null ||
                fail "this platform's stat utility is unsupported"
            ;;
    esac
}

normalize_mode() {
    raw_mode=$1
    case "$raw_mode" in
        '' | *[!0-7]*) fail "stat returned an invalid file mode" ;;
    esac
    case ${#raw_mode} in
        1) printf '000%s' "$raw_mode" ;;
        2) printf '00%s' "$raw_mode" ;;
        3) printf '0%s' "$raw_mode" ;;
        4) printf '%s' "$raw_mode" ;;
        *) fail "stat returned an invalid file mode" ;;
    esac
}

# xargs invokes these private workers with one NUL-delimited path. Keeping the
# path as a single argument preserves spaces, tabs, newlines, and non-ASCII
# bytes; Git supplies the deterministic C-style representation in a record.
if [ "${1-}" = "__record" ]; then
    [ "$#" -eq 3 ] || fail "invalid internal record invocation"
    record_root=$2
    record_path=$3

    case "$record_path" in
        "$manifest_name" | "$digest_name" | "$receipt_name") exit 0 ;;
    esac

    case "$record_path" in
        '' | /* | ../* | */../* | */..) fail "Git returned an unsafe relative path" ;;
    esac

    record_file=$record_root/$record_path
    [ ! -L "$record_file" ] || fail "candidate input is a symbolic link: $record_path"
    [ -f "$record_file" ] || fail "candidate input is not a regular file: $record_path"

    metadata_before=$(file_metadata "$record_file") || fail "could not inspect: $record_path"
    raw_mode=${metadata_before%%|*}
    record_mode=$(normalize_mode "$raw_mode")
    record_sha256=$(sha256_file "$record_file")

    [ ! -L "$record_file" ] || fail "candidate input became a symbolic link: $record_path"
    [ -f "$record_file" ] || fail "candidate input ceased to be a regular file: $record_path"
    metadata_after=$(file_metadata "$record_file") || fail "could not re-inspect: $record_path"
    [ "$metadata_before" = "$metadata_after" ] || fail "candidate input changed while hashing: $record_path"

    quoted_path=$(
        cd "$record_root"
        LC_ALL=C git -c core.excludesFile=/dev/null -c core.quotePath=true \
            --literal-pathspecs ls-files --cached --others \
            --exclude-per-directory=.gitignore --deduplicate -- "$record_path"
    ) || fail "could not encode Git path: $record_path"
    [ -n "$quoted_path" ] || fail "Git path disappeared while hashing: $record_path"
    case "$quoted_path" in
        *'
'*) fail "Git returned more than one encoded path: $record_path" ;;
    esac

    printf '%s\t%s\t%s\n' "$record_mode" "$record_sha256" "$quoted_path"
    exit 0
fi

if [ "${1-}" = "__audit_special" ]; then
    [ "$#" -eq 3 ] || fail "invalid internal audit invocation"
    audit_root=$2
    audit_path=${3#./}

    case "$audit_path" in
        '' | /* | ../* | */../* | */..) fail "filesystem audit returned an unsafe relative path" ;;
    esac

    ignore_status=0
    ignore_details=$(
        cd "$audit_root"
        LC_ALL=C git -c core.excludesFile=/dev/null -c core.quotePath=true \
            check-ignore --no-index --verbose -- "$audit_path" 2>/dev/null
    ) || ignore_status=$?

    case "$ignore_status" in
        0)
            ignore_rule=${ignore_details%%	*}
            # Accept only a repository .gitignore match. In particular, a
            # match reported from .git/info/exclude is deliberately ignored.
            case "$ignore_rule" in
                .gitignore:* | */.gitignore:* | *'/.gitignore":'*) exit 0 ;;
            esac
            ;;
        1) ;;
        *) fail "Git could not evaluate repository ignore rules: $audit_path" ;;
    esac

    fail "nonignored entry is not a direct regular file: $audit_path"
fi

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
action=$1
case "$action" in
    write | verify) ;;
    *) usage ;;
esac

require_command git
require_command shasum
require_command sort
require_command xargs
require_command stat
require_command cmp
require_command mktemp
require_command sed
require_command find
require_command mkdir
require_command rmdir

script_directory=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
script_path=$script_directory/$(basename "$0")
repository_root=$(git -C "$script_directory/.." rev-parse --show-toplevel 2>/dev/null) ||
    fail "script is not inside a Git working tree"
repository_root=$(CDPATH= cd -- "$repository_root" && pwd -P)

if [ "$#" -eq 2 ]; then
    [ -d "$2" ] || fail "output directory does not exist: $2"
    [ ! -L "$2" ] || fail "output directory must not be a symbolic link: $2"
    output_directory=$(CDPATH= cd -- "$2" && pwd -P)
else
    output_directory=$repository_root
fi

case "$output_directory/" in
    "$repository_root/") ;;
    "$repository_root/"*) fail "alternate output directory must be outside the repository" ;;
esac

manifest_path=$output_directory/$manifest_name
digest_path=$output_directory/$digest_name
receipt_path=$output_directory/$receipt_name

validate_generated_path() {
    output_path=$1
    if [ -e "$output_path" ] || [ -L "$output_path" ]; then
        [ ! -L "$output_path" ] || fail "output must not be a symbolic link: $output_path"
        [ -f "$output_path" ] || fail "output must be a regular file: $output_path"
    fi
}

validate_generated_set() {
    generated_directory=$1
    validate_generated_path "$generated_directory/$manifest_name"
    validate_generated_path "$generated_directory/$digest_name"
    validate_generated_path "$generated_directory/$receipt_name"
}

# The three root artifacts are always reserved, even when a temporary external
# output directory is selected. Nested files with the same basenames are not.
validate_generated_set "$repository_root"
if [ "$output_directory" != "$repository_root" ]; then
    validate_generated_set "$output_directory"
fi

if [ "$action" = verify ]; then
    [ -f "$manifest_path" ] || fail "candidate manifest is missing: $manifest_path"
    [ -f "$digest_path" ] || fail "candidate digest is missing: $digest_path"
fi

temporary_directory=
lock_acquired=0
lock_directory=
lock_identity=

lock_root_input=${TMPDIR:-/tmp}
[ -d "$lock_root_input" ] || fail "temporary directory root does not exist"
[ ! -L "$lock_root_input" ] || fail "temporary directory root must not be a symbolic link"
lock_root=$(CDPATH= cd -- "$lock_root_input" && pwd -P)
lock_key_output=$(
    printf '%s\000%s\000' "$repository_root" "$output_directory" | shasum -a 256
) || fail "could not derive the candidate lock identity"
lock_key=${lock_key_output%% *}
case "$lock_key" in
    '' | *[!0-9a-f]*) fail "candidate lock identity is invalid" ;;
esac
[ "${#lock_key}" -eq 64 ] || fail "candidate lock identity is invalid"
lock_directory=$lock_root/codex-cove-source-candidate-$lock_key.lock

umask 077
if mkdir -- "$lock_directory" 2>/dev/null; then
    lock_acquired=1
else
    fail "another candidate operation is active for this output"
fi
chmod 0700 "$lock_directory"
lock_identity=$(file_metadata "$lock_directory") || fail "could not bind the candidate lock"

cleanup() {
    if [ -n "$temporary_directory" ]; then
        rm -f -- \
            "$temporary_directory/paths.raw" \
            "$temporary_directory/paths.sorted" \
            "$temporary_directory/special.raw" \
            "$temporary_directory/special.sorted" \
            "$temporary_directory/manifest-1" \
            "$temporary_directory/manifest-2" \
            "$temporary_directory/$manifest_name" \
            "$temporary_directory/$digest_name"
        rmdir -- "$temporary_directory" 2>/dev/null || true
    fi
    if [ "$lock_acquired" -eq 1 ] && [ -d "$lock_directory" ] && [ ! -L "$lock_directory" ]; then
        current_lock_identity=$(file_metadata "$lock_directory" 2>/dev/null || true)
        if [ "$current_lock_identity" = "$lock_identity" ]; then
            rmdir -- "$lock_directory" 2>/dev/null || true
        fi
    fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

assert_lock_owned() {
    [ "$lock_acquired" -eq 1 ] || fail "candidate lock was not acquired"
    [ -d "$lock_directory" ] && [ ! -L "$lock_directory" ] ||
        fail "candidate lock identity changed"
    current_lock_identity=$(file_metadata "$lock_directory") ||
        fail "candidate lock identity changed"
    [ "$current_lock_identity" = "$lock_identity" ] ||
        fail "candidate lock identity changed"
}

temporary_directory=$(mktemp -d "$lock_root/codex-cove-source-candidate.XXXXXX") ||
    fail "could not create a private temporary directory"
chmod 0700 "$temporary_directory"

enumerate_paths() {
    raw_path_list=$1
    sorted_path_list=$2
    (
        cd "$repository_root"
        LC_ALL=C git -c core.excludesFile=/dev/null -c core.quotePath=true \
            ls-files --cached --others --exclude-per-directory=.gitignore \
            --deduplicate -z
    ) >"$raw_path_list" || fail "Git could not enumerate candidate inputs"
    LC_ALL=C sort -z "$raw_path_list" >"$sorted_path_list" ||
        fail "sort could not order candidate inputs"
}

audit_working_tree() {
    special_raw=$temporary_directory/special.raw
    special_sorted=$temporary_directory/special.sorted
    (
        cd "$repository_root"
        LC_ALL=C find -P . -path './.git' -prune -o \
            ! -type d ! -type f -print0
    ) >"$special_raw" || fail "could not audit working-tree entry types"
    LC_ALL=C sort -z "$special_raw" >"$special_sorted" ||
        fail "could not order working-tree audit entries"
    if [ -s "$special_sorted" ]; then
        LC_ALL=C xargs -0 -n 1 "$script_path" __audit_special "$repository_root" \
            <"$special_sorted" >/dev/null ||
            fail "working tree contains a nonregular nonignored entry"
    fi
}

build_manifest() {
    built_manifest=$1
    paths_raw=$temporary_directory/paths.raw
    paths_sorted=$temporary_directory/paths.sorted

    audit_working_tree
    enumerate_paths "$paths_raw" "$paths_sorted"
    printf '%s\n' "$manifest_header" >"$built_manifest"
    if [ -s "$paths_sorted" ]; then
        LC_ALL=C xargs -0 -n 1 "$script_path" __record "$repository_root" \
            <"$paths_sorted" >>"$built_manifest" ||
            fail "could not build the candidate manifest"
    fi
    audit_working_tree
}

manifest_1=$temporary_directory/manifest-1
manifest_2=$temporary_directory/manifest-2
temporary_manifest=$temporary_directory/$manifest_name
temporary_digest=$temporary_directory/$digest_name

build_manifest "$manifest_1"
build_manifest "$manifest_2"
cmp -s "$manifest_1" "$manifest_2" ||
    fail "source tree changed between independent candidate manifests"
mv -- "$manifest_2" "$temporary_manifest"
rm -f -- "$manifest_1"

candidate_digest=$(sha256_file "$temporary_manifest")
printf '%s\n' "$candidate_digest" >"$temporary_digest"

validate_receipt() {
    checked_receipt=$1
    [ -f "$checked_receipt" ] || return 0
    [ ! -L "$checked_receipt" ] || fail "candidate receipt must not be a symbolic link"
    receipt_metadata_before=$(file_metadata "$checked_receipt") ||
        fail "could not inspect candidate receipt"
    receipt_line_1=$(sed -n '1p' "$checked_receipt") || fail "could not read candidate receipt"
    receipt_line_2=$(sed -n '2p' "$checked_receipt") || fail "could not read candidate receipt"
    [ "$receipt_line_1" = "$receipt_header" ] || fail "candidate receipt header is invalid"
    [ "$receipt_line_2" = "source_candidate_digest=$candidate_digest" ] ||
        fail "candidate receipt does not bind the current source digest"
    receipt_metadata_after=$(file_metadata "$checked_receipt") ||
        fail "could not re-inspect candidate receipt"
    [ "$receipt_metadata_before" = "$receipt_metadata_after" ] ||
        fail "candidate receipt changed while validating"
}

validate_receipt "$repository_root/$receipt_name"
if [ "$output_directory" != "$repository_root" ]; then
    validate_receipt "$receipt_path"
fi

assert_lock_owned
validate_generated_set "$repository_root"
if [ "$output_directory" != "$repository_root" ]; then
    validate_generated_set "$output_directory"
fi

if [ "$action" = write ]; then
    chmod 0644 "$temporary_manifest" "$temporary_digest"
    mv -f -- "$temporary_manifest" "$manifest_path"
    mv -f -- "$temporary_digest" "$digest_path"
else
    cmp -s "$temporary_manifest" "$manifest_path" || fail "candidate manifest does not match the source tree"
    cmp -s "$temporary_digest" "$digest_path" || fail "candidate digest file is not canonical or does not match"
fi

printf '%s\n' "$candidate_digest"
