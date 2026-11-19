#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build.sh [options]

Options:
  --configuration <id>   Generated configuration. Default: linux-x64-server
  --surface <name>       Generated surface directory. Default: bedrock
  --shim-source <file>   Generated binding_table.cpp to compile.
  --output <file>        Output shared library.
                         Default: artifacts/native/libHosihikari.Binding.Bedrock.Shim.so
  --cxx <compiler>       C++ compiler. Default: g++, or the CXX environment variable.
EOF
}

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_root/../.." && pwd)"
configuration="linux-x64-server"
surface="bedrock"
shim_source=""
output="$repo_root/artifacts/native/libHosihikari.Binding.Bedrock.Shim.so"
cxx="${CXX:-g++}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --configuration)
            configuration="${2:-}"
            shift 2
            ;;
        --surface)
            surface="${2:-}"
            shift 2
            ;;
        --shim-source)
            shim_source="${2:-}"
            shift 2
            ;;
        --output)
            output="${2:-}"
            shift 2
            ;;
        --cxx)
            cxx="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

shim_dir="$script_root/generated/$configuration/$surface"
if [ -z "$shim_source" ]; then
    shim_source="$shim_dir/binding_table.cpp"
fi
source_file="$(cd "$(dirname "$shim_source")" && pwd)/$(basename "$shim_source")"
if [ ! -f "$source_file" ]; then
    echo "Generated BindingShim sources are missing: $source_file" >&2
    exit 1
fi
if [ ! -f "$shim_dir/hosihikari_abi.h" ]; then
    echo "hosihikari_abi.h is missing under $shim_dir" >&2
    exit 1
fi

mkdir -p "$(dirname "$output")"
"$cxx" \
    -std=c++20 \
    -shared \
    -fPIC \
    -O2 \
    -I "$shim_dir" \
    "$source_file" \
    -o "$output" \
    -ldl

if command -v nm >/dev/null 2>&1; then
    exports="$(nm -D --defined-only "$output")"
    if ! printf '%s\n' "$exports" | grep -q 'hosihikari_get_binding_table_v1'; then
        echo "The built shim does not export hosihikari_get_binding_table_v1." >&2
        exit 1
    fi
fi

echo "Built $output"
