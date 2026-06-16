#!/bin/bash

# One-shot: build/install NIXL (default GDS_MT,AIS_MT), then nixlbench.
#
# NIXL: CUDA toolkit with nvcc on PATH for GDS_MT; ROCm + hipFile for AIS_MT.
# CUDA-linked nixlbench needs libcuda.so.1 at runtime (NVIDIA driver), not only
# the toolkit; the script adds common driver library paths to LD_LIBRARY_PATH.
#
# nixlbench (Ubuntu): install dev packages before running, for example:
#   sudo apt install libgflags-dev libasio-dev libtomlplusplus-dev
# Optional ETCD coordination:
#   sudo apt install libetcd-cpp-apiv3-dev
#
# Override install roots if needed (must be writable by this user; no sudo
# prompt — Meson is run so insufficient permissions fail fast):
#   NIXL_PREFIX=$HOME/.local/nixl NIXLBENCH_PREFIX=$HOME/.local/nixlbench ./build-test-this.sh
# For system paths (/opt/...), create dirs with correct ownership first, or run
#   sudo meson install -C …   yourself after meson compile.
#
# nixlbench links against the installed libnixl.so. If NIXL was built with CUDA
# (e.g. GDS_MT), libnixl still needs libcuda.so.1 at runtime from the NVIDIA
# driver — the CUDA toolkit alone is not enough. Options:
#   - Install the driver (or Ubuntu libnvidia-compute-*), then sudo ldconfig.
#   - Or skip the final smoke test: NIXLBENCH_ALLOW_MISSING_LIBCUDA=1
#   - Or build nixlbench against HIP only: NIXLBENCH_USE_ROCM=1 meson adds
#     -Duse_rocm=true (VRAM/CUDA paths in nixlbench differ; libnixl may still
#     pull libcuda if that NIXL build linked CUDA).

set -euo pipefail

BUILD_DIR=${BUILD_DIR:-build-mt}
BUILD_THIS=${BUILD_THIS:-GDS_MT,AIS_MT}
NIXL_PREFIX="${NIXL_PREFIX:-/opt/nixl}"
NIXLBENCH_PREFIX="${NIXLBENCH_PREFIX:-/opt/nixlbench}"
NIXLBENCH_USE_ROCM="${NIXLBENCH_USE_ROCM:-1}"
ROCM_PATH="${ROCM_PATH:-/opt/rocm}"
NIXLBENCH_ALLOW_MISSING_LIBCUDA="${NIXLBENCH_ALLOW_MISSING_LIBCUDA:-0}"

# GDS_MT needs nvcc (full CUDA toolkit), not only libcudart under /usr/local/cuda.
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
export PATH="${CUDA_HOME}/bin:${PATH}"

if ! command -v pkg-config >/dev/null 2>&1; then
    echo "ERROR: pkg-config not found; install it (e.g. sudo apt install pkg-config)." >&2
    exit 1
fi

require_pkgconfig() {
    local pc="$1"
    local deb_hint="$2"
    if ! pkg-config --exists "${pc}" 2>/dev/null; then
        echo "ERROR: nixlbench needs pkg-config module '${pc}'." >&2
        echo "       On Ubuntu, try: sudo apt install ${deb_hint}" >&2
        exit 1
    fi
}

require_pkgconfig gflags libgflags-dev
require_pkgconfig asio libasio-dev
require_pkgconfig tomlplusplus libtomlplusplus-dev

# Meson asks "[y/n] use sudo?" only when stdout+stderr are TTYs. Pipe install
# through cat so permission errors exit immediately (set -o pipefail).
meson_install_noninteractive() {
    local build_dir="$1"
    meson install -C "${build_dir}" 2>&1 | cat
}

# Fail before meson install with a clear message instead of a Python traceback
# or an interactive sudo prompt when the prefix is not writable.
require_writable_install_prefix() {
    local prefix="$1"
    local label="$2"
    if ! mkdir -p "${prefix}" 2>/dev/null; then
        echo "ERROR: cannot create ${label} install prefix (missing write permission): ${prefix}" >&2
        echo "       Use a user-writable prefix, e.g. NIXL_PREFIX=\$HOME/.local/nixl, or" >&2
        echo "       fix ownership of the parent directory, or run: sudo meson install -C <builddir>" >&2
        exit 1
    fi
    if [[ ! -w "${prefix}" ]]; then
        echo "ERROR: ${label} install prefix is not writable: ${prefix}" >&2
        echo "       Use a user-writable prefix or: sudo chown -R \"\$USER\" \"${prefix}\"" >&2
        exit 1
    fi
}

cd /home/stebates/Projects/nixl
rm -rf "${BUILD_DIR}"

case ",${BUILD_THIS}," in
*,GDS_MT,*|*,CUDA_GDS,*|*,GDS,*)
    if ! command -v nvcc >/dev/null 2>&1; then
        echo "ERROR: GDS_MT needs nvcc. Install the CUDA toolkit (e.g. cuda-toolkit-13-*)," >&2
        echo "       or set CUDA_HOME and ensure \$CUDA_HOME/bin is on PATH." >&2
        exit 1
    fi
    ;;
esac

meson setup "${BUILD_DIR}" \
  -Denable_plugins="${BUILD_THIS}" -Dprefix="${NIXL_PREFIX}"
require_writable_install_prefix "${NIXL_PREFIX}" "NIXL"
meson compile -C "${BUILD_DIR}"
meson_install_noninteractive "${BUILD_DIR}"

cd benchmark/nixlbench
rm -rf nbench-build
nbench_args=(
    -Dnixl_path="${NIXL_PREFIX}"
    -Dprefix="${NIXLBENCH_PREFIX}"
)
if [[ "${NIXLBENCH_USE_ROCM}" == "1" ]]; then
    nbench_args+=(-Duse_rocm=true "-Drocm_path=${ROCM_PATH}")
fi
meson setup nbench-build "${nbench_args[@]}"
require_writable_install_prefix "${NIXLBENCH_PREFIX}" "nixlbench"
meson compile -C nbench-build
meson_install_noninteractive nbench-build

# Runtime: nixlbench loads libnixl.so from the NIXL prefix (often multiarch lib
# dirs). libnixl may also need libcuda.so.1 from the NVIDIA *driver* (usually
# /usr/lib/x86_64-linux-gnu, not only CUDA_HOME). Prepend sensible paths for the
# smoke test. If libcuda.so.1 is still missing, install the driver (or a compute
# package such as libnvidia-compute-<ver> on Ubuntu).
append_nixl_runtime_ld_path() {
    local parts=""
    local d
    for d in \
        "${NIXL_PREFIX}/lib/x86_64-linux-gnu" \
        "${NIXL_PREFIX}/lib/aarch64-linux-gnu" \
        "${NIXL_PREFIX}/lib64" \
        "${NIXL_PREFIX}/lib" \
        "${NIXLBENCH_PREFIX}/lib/x86_64-linux-gnu" \
        "${NIXLBENCH_PREFIX}/lib/aarch64-linux-gnu" \
        "${NIXLBENCH_PREFIX}/lib"; do
        if [[ -d "$d" ]]; then
            if [[ -z "$parts" ]]; then
                parts="$d"
            elif [[ ":$parts:" != *":$d:"* ]]; then
                parts="$parts:$d"
            fi
        fi
    done
    if [[ -d "${CUDA_HOME}/lib64" ]]; then
        if [[ -z "$parts" ]]; then
            parts="${CUDA_HOME}/lib64"
        elif [[ ":$parts:" != *":${CUDA_HOME}/lib64:"* ]]; then
            parts="$parts:${CUDA_HOME}/lib64"
        fi
    fi
    if [[ -d /opt/rocm/lib ]]; then
        if [[ -z "$parts" ]]; then
            parts="/opt/rocm/lib"
        elif [[ ":$parts:" != *":/opt/rocm/lib:"* ]]; then
            parts="$parts:/opt/rocm/lib"
        fi
    fi
    # libcuda.so.1: ask ldconfig first (works for vendor-specific paths), then
    # common locations if the cache has no entry (e.g. before sudo ldconfig).
    local libcuda_path cuda_dir
    libcuda_path=$(PATH="/usr/sbin:/sbin:${PATH:-}" ldconfig -p 2>/dev/null |
        sed -n 's/.*libcuda\.so\.1[^=]*=> *\([^ ]*\).*/\1/p' | head -1 || true)
    if [[ -n "${libcuda_path:-}" && -f "$libcuda_path" ]]; then
        cuda_dir=$(dirname "$libcuda_path")
        if [[ -z "$parts" ]]; then
            parts="$cuda_dir"
        elif [[ ":$parts:" != *":$cuda_dir:"* ]]; then
            parts="$parts:$cuda_dir"
        fi
    fi
    for d in /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu /usr/lib/wsl/lib /usr/lib64; do
        if [[ -e "$d/libcuda.so.1" ]] || [[ -e "$d/libcuda.so" ]]; then
            if [[ -z "$parts" ]]; then
                parts="$d"
            elif [[ ":$parts:" != *":$d:"* ]]; then
                parts="$parts:$d"
            fi
        fi
    done
    if [[ -n "$parts" ]]; then
        if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
            export LD_LIBRARY_PATH="${parts}:${LD_LIBRARY_PATH}"
        else
            export LD_LIBRARY_PATH="${parts}"
        fi
    fi
}

append_nixl_runtime_ld_path

if [[ ! -x "${NIXLBENCH_PREFIX}/bin/nixlbench" ]]; then
    echo "ERROR: nixlbench not installed at ${NIXLBENCH_PREFIX}/bin/nixlbench" >&2
    exit 1
fi

# CUDA-linked binaries need libcuda.so.1 from the NVIDIA driver; fail clearly if
# it cannot be resolved with the computed LD_LIBRARY_PATH.
_libcuda_ldd_line="$(
    LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" \
        ldd "${NIXLBENCH_PREFIX}/bin/nixlbench" 2>/dev/null | grep 'libcuda.so.1' || true
)"
if echo "${_libcuda_ldd_line}" | grep -q 'not found'; then
    if [[ "${NIXLBENCH_ALLOW_MISSING_LIBCUDA}" == "1" ]]; then
        echo "WARNING: libcuda.so.1 not found; skipping nixlbench --version (NIXLBENCH_ALLOW_MISSING_LIBCUDA=1)." >&2
    else
        echo "ERROR: libcuda.so.1 not found for ${NIXLBENCH_PREFIX}/bin/nixlbench." >&2
        echo "       libnixl was built with CUDA; install the NVIDIA driver (or Ubuntu" >&2
        echo "       libnvidia-compute-*) and run sudo ldconfig, then re-run this script." >&2
        echo "       Optional: NIXLBENCH_USE_ROCM=1 rebuilds nixlbench with -Duse_rocm=true." >&2
        echo "       Install-only (no smoke test): NIXLBENCH_ALLOW_MISSING_LIBCUDA=1" >&2
        echo "       ldd line: ${_libcuda_ldd_line:-<missing>}" >&2
        exit 1
    fi
else
    "${NIXLBENCH_PREFIX}/bin/nixlbench" --version
fi

if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
    echo "To run nixlbench in another shell with the same loader path, use:" >&2
    echo "  export LD_LIBRARY_PATH=${LD_LIBRARY_PATH}" >&2
fi

sudo mkdir -p /mnt/nvme-nixlbench
sudo mkfs.xfs /dev/disk/by-id/nvme-MTR_SLC_16GB_0400000E3CBC_1
sudo mount /dev/disk/by-id/nvme-MTR_SLC_16GB_0400000E3CBC_1 /mnt/nvme-nixlbench
sudo chown -R stebates:stebates /mnt/nvme-nixlbench

/opt/nixlbench/bin/nixlbench \
  --backend AIS_MT \
  --filepath /mnt/nvme-nixlbench \
  --op_type READ \
  --check_consistency
