#!/usr/bin/env bash
set -euo pipefail

archive=$1
provenance=$2
output=$3

runtime_value() {
  awk -F= -v wanted="$1" '
    $0 == "[runtime]" { in_runtime = 1; next }
    /^\[/ { in_runtime = 0 }
    in_runtime && $1 == wanted { print substr($0, length($1) + 2); exit }
  ' "$provenance"
}

runtime_name=$(runtime_value name)
expected_sha=$(runtime_value source_sha256)
expected_bytes=$(runtime_value source_size)
source_url=$(runtime_value source)
[[ -n "$runtime_name" && -n "$expected_sha" && -n "$expected_bytes" && -n "$source_url" ]] || {
  echo "runtime provenance is incomplete: $provenance" >&2
  exit 1
}

mkdir -p "$output"
if [[ "$archive" == --download-pinned ]]; then
  archive="$output/whisper.cpp-v1.9.1.tar.gz"
  curl --fail --location --retry 3 --output "$archive" "$source_url"
fi

[[ -f "$archive" ]] || { echo "whisper.cpp archive not found: $archive" >&2; exit 1; }
[[ $(wc -c < "$archive" | tr -d ' ') == "$expected_bytes" ]] || { echo "$runtime_name archive size mismatch" >&2; exit 1; }
[[ $(shasum -a 256 "$archive" | awk '{print $1}') == "$expected_sha" ]] || { echo "$runtime_name archive digest mismatch" >&2; exit 1; }

source_dir="$output/source"
build_dir="$output/build"
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
  -DGGML_CCACHE=OFF \
  -DGGML_OPENMP=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON
cmake --build "$build_dir" --target whisper -j2
echo "verified $runtime_name built" >&2
