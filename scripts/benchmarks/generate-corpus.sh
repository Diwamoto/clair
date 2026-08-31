#!/usr/bin/env bash

set -euo pipefail

generator_version="1"
output_dir=""

usage() {
  cat <<'USAGE'
Usage: generate-corpus.sh --output DIRECTORY

Create the deterministic Clair benchmark corpus in an empty directory.
USAGE
}

while (($# > 0)); do
  case "$1" in
    --output)
      if (($# < 2)); then
        echo "--output requires a directory" >&2
        exit 2
      fi
      output_dir="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$output_dir" ]]; then
  echo "--output is required" >&2
  usage >&2
  exit 2
fi

if [[ -e "$output_dir" ]] && [[ -n "$(find "$output_dir" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "refusing to write into non-empty directory: $output_dir" >&2
  exit 1
fi

mkdir -p \
  "$output_dir/large-files" \
  "$output_dir/unicode" \
  "$output_dir/terminal" \
  "$output_dir/file-tree" \
  "$output_dir/git-status"

write_repeated_text() {
  local path="$1"
  local size="$2"
  local line="$3"

  # `yes` plus `head -c` gives exact byte-sized deterministic text without
  # keeping a 100 MiB intermediate string in a shell variable.
  set +o pipefail
  LC_ALL=C yes "$line" 2>/dev/null | head -c "$size" > "$path"
  set -o pipefail
  actual_size=$(wc -c < "$path" | tr -d ' ')
  if [[ "$actual_size" != "$size" ]]; then
    echo "unexpected size for $path: got $actual_size, expected $size" >&2
    exit 1
  fi
}

write_repeated_text \
  "$output_dir/large-files/text-10MiB.txt" \
  10485760 \
  'clair-benchmark-v1|line=000000|stable synthetic source workload'

write_repeated_text \
  "$output_dir/large-files/text-100MiB.txt" \
  104857600 \
  'clair-benchmark-v1|line=000000|stable synthetic source workload'

cat > "$output_dir/unicode/unicode-fixture.txt" <<'EOF'
ASCII: Clair benchmark fixture
CJK: 日本語の入力と編集を確認する。漢字、ひらがな、カタカナ。
Emoji: 😀 🧪 🧑‍💻 🏳️‍🌈 👍🏽
Combining: é å ñ Z͑͗
Full-width: ＡＢＣ１２３ ａｂｃ！＠＃
Wide glyph: 表示幅を持つ文字、界、界、界
Box drawing: ┌─┬─┐│ │ │└─┴─┘
Control-shaped text: tab<TAB>marker and literal escape spelling \x1b[31m
EOF

cat > "$output_dir/unicode/ime-operations.json" <<'EOF'
{
  "schema_version": 1,
  "range_unit": "UTF-16 code units",
  "cases": [
    {
      "id": "marked-text-commit-cjk",
      "initial_text": "prefix|suffix",
      "insertion_offset_utf16": 7,
      "events": [
        {"action": "set-marked-text", "text": "に", "selected_range": [1, 0]},
        {"action": "set-marked-text", "text": "日本", "selected_range": [2, 0]},
        {"action": "insert-text", "text": "日本語"}
      ],
      "expected_text": "prefix|日本語suffix",
      "expected_inserted_utf8_bytes": 9,
      "expected_inserted_utf16_units": 3,
      "expected_inserted_graphemes": 3
    },
    {
      "id": "marked-text-cancel",
      "initial_text": "before|after",
      "insertion_offset_utf16": 7,
      "events": [
        {"action": "set-marked-text", "text": "かな", "selected_range": [2, 0]},
        {"action": "unmark-text-without-commit"}
      ],
      "expected_text": "before|after"
    },
    {
      "id": "emoji-and-combining-offsets",
      "text": "A😀é界Z",
      "expected_utf8_bytes": 12,
      "expected_utf16_units": 7,
      "expected_graphemes": 5,
      "expected_boundaries_utf16": [0, 1, 3, 5, 6, 7]
    }
  ]
}
EOF

write_repeated_text \
  "$output_dir/terminal/flood-1MiB.txt" \
  1048576 \
  'clair-terminal-flood|0123456789|日本語|wide=界|frame=000000'

printf '\033]52;c;Y2xhaXItYmVuY2htYXJr\007\033]633;A\007printf clair-benchmark\033]633;B\007\033]633;C\007\033]633;D;0\007' \
  > "$output_dir/terminal/osc-sequences.bin"

# 10 modules × 20 packages × 50 files = 10,000 files. This is the stress
# profile; the count and shape are part of the manifest contract.
for module_index in $(seq 0 9); do
  printf -v module_label '%02d' "$module_index"
  for package_index in $(seq 0 19); do
    printf -v package_label '%02d' "$package_index"
    directory="$output_dir/file-tree/module-$module_label/package-$package_label"
    mkdir -p "$directory"
    for file_index in $(seq 0 49); do
      printf -v file_label '%02d' "$file_index"
      path="$directory/file-$file_label.txt"
      printf 'clair-benchmark-v1\nmodule=%s\npackage=%s\nfile=%s\n日本語\n' \
        "$module_label" "$package_label" "$file_label" > "$path"
    done
  done
done

git -C "$output_dir/git-status" init -q
git -C "$output_dir/git-status" config user.name 'Clair Benchmark'
git -C "$output_dir/git-status" config user.email 'benchmark@example.invalid'
mkdir -p "$output_dir/git-status/src" "$output_dir/git-status/docs"
printf 'baseline\n' > "$output_dir/git-status/README.md"
printf 'tracked and modified\n' > "$output_dir/git-status/src/modified.txt"
printf 'tracked and renamed\n' > "$output_dir/git-status/src/rename-before.txt"
printf 'tracked and deleted\n' > "$output_dir/git-status/src/delete-me.txt"
printf 'documentation\n' > "$output_dir/git-status/docs/fixture.md"
git -C "$output_dir/git-status" add README.md src docs
git -C "$output_dir/git-status" commit -q -m 'benchmark baseline'
printf 'modified after baseline\n' >> "$output_dir/git-status/src/modified.txt"
git -C "$output_dir/git-status" mv src/rename-before.txt src/rename-after.txt
rm "$output_dir/git-status/src/delete-me.txt"
printf 'untracked\n' > "$output_dir/git-status/src/untracked.txt"

manifest_path="$output_dir/MANIFEST.json"
python3 - "$output_dir" "$manifest_path" "$generator_version" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve()
manifest_path = pathlib.Path(sys.argv[2]).resolve()
version = sys.argv[3]

paths = [
    pathlib.Path("large-files/text-10MiB.txt"),
    pathlib.Path("large-files/text-100MiB.txt"),
    pathlib.Path("unicode/unicode-fixture.txt"),
    pathlib.Path("unicode/ime-operations.json"),
    pathlib.Path("terminal/flood-1MiB.txt"),
    pathlib.Path("terminal/osc-sequences.bin"),
]
paths.extend(sorted(path.relative_to(root) for path in (root / "file-tree").rglob("*.txt")))
paths.extend(sorted(path.relative_to(root) for path in (root / "git-status").rglob("*") if path.is_file() and ".git" not in path.parts))

entries = []
for relative in paths:
    path = root / relative
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    entries.append({"path": relative.as_posix(), "bytes": path.stat().st_size, "sha256": digest})

status = subprocess.run(
    ["git", "-C", str(root / "git-status"), "status", "--short"],
    check=True,
    capture_output=True,
    text=True,
).stdout.splitlines()

manifest = {
    "manifest_version": 1,
    "generator_version": version,
    "file_tree_profile": {
        "files": 10_000,
        "directories": 200,
        "levels_below_root": 3,
    },
    "files": entries,
    "git_status": status,
    "git_status_expected": [
        " D src/delete-me.txt",
        " M src/modified.txt",
        "R  src/rename-before.txt -> src/rename-after.txt",
        "?? src/untracked.txt",
    ],
}
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
PY

echo "generated benchmark corpus: $output_dir"
