#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific permissions and limitations under the
# License.
#
# Run inside a gpu-test (or similar) image to sanity-check NIXL install layout,
# nixlbench binaries, the UCX plugin, and UCX CUDA/ROCm transport libraries.
#
# Usage (from repo host, image need not include this file yet):
#   docker run --rm -v "$PWD/.ci/scripts/verify-gpu-test-contents.sh:/tmp/v.sh:ro" \
#     YOUR_TAG bash /tmp/v.sh
#
# After a gpu-test build with COPY . ., the script also lives under:
#   /workspace/nixl/.ci/scripts/verify-gpu-test-contents.sh

set -euo pipefail

P="${NIXL_INSTALL_DIR:-/opt/nixl}"
fail=0
warn=0

section() {
    printf '\n=== %s ===\n' "$1"
}

note_warn() {
    echo "WARN: $*"
    warn=$((warn + 1))
}

note_fail() {
    echo "FAIL: $*"
    fail=$((fail + 1))
}

arch="$(uname -m)"
case "$arch" in
    aarch64) libarch="aarch64-linux-gnu" ;;
    x86_64) libarch="x86_64-linux-gnu" ;;
    *) libarch="$arch-linux-gnu" ;;
esac

PLUG="${P}/lib/${libarch}/plugins"
ROCM="${ROCM_PATH:-/opt/rocm}"

section "Install prefix"
if [[ ! -d "$P" ]]; then
    note_fail "missing directory: $P"
else
    echo "OK: $P"
fi

section "Core NIXL libraries"
for f in "${P}/lib/${libarch}/libnixl.so" "${P}/lib/${libarch}/libnixl_build.so"; do
    if [[ -f "$f" ]]; then
        echo "OK: $f"
    else
        note_fail "missing: $f"
    fi
done

section "Plugin directory"
if [[ ! -d "$PLUG" ]]; then
    note_fail "missing: $PLUG"
else
    echo "OK: $PLUG ($(find "$PLUG" -maxdepth 1 -name 'libplugin_*.so' | wc -l) plugins)"
    ls -la "$PLUG"/libplugin_*.so 2>/dev/null || note_warn "no libplugin_*.so in $PLUG"
fi

section "UCX backend plugin"
ucx_plugin="${PLUG}/libplugin_UCX.so"
if [[ ! -f "$ucx_plugin" ]]; then
    note_fail "missing: $ucx_plugin"
else
    echo "OK: $ucx_plugin"
    echo "--- readelf NEEDED (first level) ---"
    if command -v readelf >/dev/null 2>&1; then
        readelf -d "$ucx_plugin" | grep NEEDED || true
    else
        echo "(readelf not installed; skipping)"
    fi
    echo "--- ldd (full; CUDA/ROCm names may be indirect) ---"
    ldd "$ucx_plugin" 2>&1 | sed 's/^/    /' || note_fail "ldd failed on $ucx_plugin"
fi

section "UCX transport modules (CUDA / ROCm hints)"
# UCX install prefix matches NIXL in CI (same --prefix).
found_cuda=0
found_rocm=0
while IFS= read -r -d '' so; do
    case "$so" in
        *cuda*) found_cuda=1 ;;
        *rocm*) found_rocm=1 ;;
    esac
    echo "  $so"
done < <(find "${P}/lib" -maxdepth 4 \( -iname '*cuda*.so*' -o -iname '*rocm*.so*' \) -print0 2>/dev/null || true)

if [[ "$found_cuda" -eq 0 ]]; then
    note_warn "no *cuda*.so under ${P}/lib (UCX may be CPU-only or layout differs)"
fi
if [[ -d "${ROCM}/lib" ]] && ls "${ROCM}/lib"/libamdhip64.so* >/dev/null 2>&1; then
    if [[ "$found_rocm" -eq 0 ]]; then
        note_warn "ROCm present but no *rocm*.so under ${P}/lib (check UCX --with-rocm build)"
    fi
fi

section "nixlbench binaries"
if [[ -x "${P}/bin/nixlbench" ]]; then
    echo "OK: ${P}/bin/nixlbench"
    file "${P}/bin/nixlbench" || true
else
    note_fail "missing or not executable: ${P}/bin/nixlbench"
fi

if [[ -x "${P}/bin/nixlbench-rocm" ]]; then
    echo "OK: ${P}/bin/nixlbench-rocm (dual HIP build)"
    file "${P}/bin/nixlbench-rocm" || true
else
    if ls "${ROCM}/lib"/libamdhip64.so* >/dev/null 2>&1; then
        note_warn "no ${P}/bin/nixlbench-rocm (expected when CUDA+ROCm dual nixlbench ran)"
    else
        echo "OK: no nixlbench-rocm (ROCm HIP not expected in this image)"
    fi
fi

section "UCX introspection (ucx_info)"
# cuda-dl-base images put HPC-X UCX on PATH first; always prefer UCX installed
# next to NIXL (${P}) so "Configured with" matches the build from .gitlab/build.sh.
_ucx_info="${P}/bin/ucx_info"
_ucx_ldpath="${P}/lib:${P}/lib/${libarch}"
if [[ -x "${_ucx_info}" ]]; then
    echo "Using: ${_ucx_info}"
    env \
        PATH="${P}/bin:${PATH}" \
        LD_LIBRARY_PATH="${_ucx_ldpath}:${LD_LIBRARY_PATH:-}" \
        UCX_TLS="${UCX_TLS:-^cuda_ipc}" \
        "${_ucx_info}" -v 2>&1 | head -40 || true
else
    echo "(skipped: ${_ucx_info} not executable — UCX may use a different layout)"
fi

section "Summary"
echo "warnings: $warn  failures: $fail"
if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
