#!/usr/bin/env bash
set -euo pipefail

archive=$1
output=$2
expected_sha=147267177eef7b22ec3d2476dd514d1b12e160e176230b740e3d1bd600118447
expected_bytes=9012805

[[ -f "$archive" ]] || { echo "whisper.cpp archive not found: $archive" >&2; exit 1; }
[[ $(wc -c < "$archive" | tr -d ' ') == "$expected_bytes" ]] || { echo "whisper.cpp v1.9.1 archive size mismatch" >&2; exit 1; }
[[ $(shasum -a 256 "$archive" | awk '{print $1}') == "$expected_sha" ]] || { echo "whisper.cpp v1.9.1 archive digest mismatch" >&2; exit 1; }

source_dir="$output/source"
build_dir="$output/build"
mkdir -p "$output"
[[ ! -e "$source_dir" && ! -e "$build_dir" ]] || {
  echo "refusing to reuse an extracted whisper.cpp source tree: $output" >&2
  exit 1
}
mkdir -p "$source_dir"
tar -xzf "$archive" -C "$source_dir" --strip-components=1

cmake -S "$source_dir" -B "$build_dir" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DWHISPER_BUILD_EXAMPLES=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON
cmake --build "$build_dir" --target whisper -j4
