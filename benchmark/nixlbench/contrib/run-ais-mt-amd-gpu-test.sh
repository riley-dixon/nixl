#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Run nixlbench (HIP build) with AIS_MT on AMD VRAM against NVMe-backed files
# under a directory, wrapped in hipFile's ais-stats so HIPFILE_STATS_LEVEL
# output can confirm fastpath use.
#
# Typical flow (host): bind-mount an NVMe-backed directory into the container,
# pass /dev/kfd and /dev/dri, set FILEPATH to a directory inside the mount,
# then run:
#   docker run ... YOUR_GPU_IMAGE \
#     bash /workspace/nixl/benchmark/nixlbench/contrib/run-ais-mt-amd-gpu-test.sh run
#
# Command print-docker-run (or --help) shows a full docker run template.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  run-ais-mt-amd-gpu-test.sh [options] [run | print-docker-run | help]

Put options before the subcommand (e.g. --init-file run).
  --init-file          If FILEPATH is missing, mkdir -p(1) it (must be a directory).
  --skip-ais-stats     Run nixlbench-rocm without wrapping ais-stats.

Commands:
  run (default)        Run nixlbench-rocm under ais-stats.
  print-docker-run     Print a docker run example for the host.
  help                 This text.

Environment (run):
  NIXL_PREFIX          Default: /opt/nixl
  ROCM_PATH            Default: /opt/rocm
  FILEPATH             Required directory inside the container; nixlbench creates
                       nixlbench_ais_mt_test_file_* files under it (see nixl_worker.cpp).
  HIPFILE_STATS_LEVEL  Default: 1 (0=off, 1=basic, 2=detailed per hipFile docs).
  AIS_STATS_BIN        Default: ${ROCM_PATH}/bin/ais-stats
  NIXLBENCH_EXTRA      Extra nixlbench args (single quoted string, word-split).
  GDS_MT_NUM_THREADS   Default: 4
  TOTAL_BUFFER_SIZE    Default: 67108864 (64 MiB)
  NUM_ITER / WARMUP_ITER / OP_TYPE / block and batch size envs — see script body.

Examples (inside container):
  FILEPATH=/data/ais-mt-run ./run-ais-mt-amd-gpu-test.sh run
EOF
}

print_docker_run() {
    cat <<'EOF'
# Example: bind an NVMe-backed directory from the host. Prefer stable by-id
# paths on the host when formatting or mounting the filesystem; expose a
# directory to the container (e.g. /data) and set FILEPATH to a subdirectory
# where nixlbench will create test files (not a single .bin file path).
#
# Create that directory on the host (optional):
#   mkdir -p /your/nvme/mount/nixlbench-ais-mt
#
# IMAGE: e.g. nixl-gpu-test:latest from Dockerfile.gpu-test + Dockerfile.base.

IMAGE="${IMAGE:-nixl-gpu-test:latest}"
HOST_NVME_DIR="${HOST_NVME_DIR:-/path/to/nvme/mount}"
CONTAINER_DATA="${CONTAINER_DATA:-/data}"
TESTFILE="${TESTFILE:-${CONTAINER_DATA}/nixlbench-ais-mt}"

# If the image predates this script, mount it from your nixl checkout (repo root):
NIXL_SRC="${NIXL_SRC:-$PWD}"

docker run --rm -it \
  --device=/dev/kfd \
  --device=/dev/dri \
  --ipc=host \
  --security-opt seccomp=unconfined \
  -v "${HOST_NVME_DIR}:${CONTAINER_DATA}:rw" \
  -v "${NIXL_SRC}/benchmark/nixlbench/contrib/run-ais-mt-amd-gpu-test.sh:/workspace/nixl/benchmark/nixlbench/contrib/run-ais-mt-amd-gpu-test.sh:ro" \
  -e FILEPATH="${TESTFILE}" \
  -e HIPFILE_STATS_LEVEL=1 \
  -e ROCM_PATH=/opt/rocm \
  -e NIXL_PREFIX=/opt/nixl \
  -e LD_LIBRARY_PATH="/opt/nixl/lib:/opt/nixl/lib/x86_64-linux-gnu:/opt/nixl/lib/x86_64-linux-gnu/plugins:/opt/rocm/lib" \
  -e NIXL_PLUGIN_DIR=/opt/nixl/lib/x86_64-linux-gnu/plugins \
  "${IMAGE}" \
  bash /workspace/nixl/benchmark/nixlbench/contrib/run-ais-mt-amd-gpu-test.sh run

# Omit the -v ...run-ais-mt-amd-gpu-test.sh... line if your image already
# contains that file (rebuild gpu-test after adding the script).
#
# Bind-mount writes: the container user must own or be allowed to write
# FILEPATH (host mkdir as your UID vs image UID 148069). Options: chown
# 148069:30 on the host dir, chmod a+w, or --user "$(id -u):$(id -g)" plus
# video/render --group-add lines below when /dev/dri requires it.

# Add video/render groups when your host uses them for /dev/dri:
#   --group-add "$(getent group video  | cut -d: -f3)"
#   --group-add "$(getent group render | cut -d: -f3)"
# Optional:  -e HIP_VISIBLE_DEVICES=0
# aarch64 images: set NIXL_PLUGIN_DIR to .../aarch64-linux-gnu/plugins in -e.
EOF
}

require_in_container_tools() {
    command -v "${NIXL_PREFIX}/bin/nixlbench-rocm" >/dev/null 2>&1 || {
        echo "ERROR: missing ${NIXL_PREFIX}/bin/nixlbench-rocm (build nixlbench with -Dnixlbench_gpu=rocm)." >&2
        exit 1
    }
    if [[ "${SKIP_AIS_STATS:-0}" != "1" ]]; then
        command -v "${AIS_STATS_BIN}" >/dev/null 2>&1 || {
            echo "ERROR: ais-stats not found at ${AIS_STATS_BIN} (set AIS_STATS_BIN or install hipFile tools)." >&2
            exit 1
        }
    fi
}

assert_fastpath_hint() {
    local logf=$1
    if grep -Eiq 'fastpath|fast[[:space:]]*path' "$logf"; then
        echo "OK: ais-stats / hipFile output mentions fastpath (see ${logf})."
        return 0
    fi
    if grep -Eiq 'fallback' "$logf"; then
        echo "WARN: log mentions fallback I/O; fastpath string not found. Inspect ${logf}." >&2
        return 0
    fi
    echo "WARN: could not find 'fastpath' or 'fallback' tokens in ais-stats output." >&2
    echo "      HIPFILE_STATS_LEVEL=${HIPFILE_STATS_LEVEL:-} — try HIPFILE_STATS_LEVEL=2 or confirm hipFile stats build." >&2
    echo "      Full log: ${logf}" >&2
}

run_benchmark() {
    NIXL_PREFIX="${NIXL_PREFIX:-/opt/nixl}"
    ROCM_PATH="${ROCM_PATH:-/opt/rocm}"
    AIS_STATS_BIN="${AIS_STATS_BIN:-${ROCM_PATH}/bin/ais-stats}"
    FILEPATH="${FILEPATH:-}"
    HIPFILE_STATS_LEVEL="${HIPFILE_STATS_LEVEL:-1}"

    local arch
    arch="$(uname -m)"
    case "$arch" in
        aarch64) libarch="aarch64-linux-gnu" ;;
        x86_64) libarch="x86_64-linux-gnu" ;;
        *) libarch="${arch}-linux-gnu" ;;
    esac

    export ROCM_PATH
    export HIPFILE_STATS_LEVEL
    export LD_LIBRARY_PATH="${NIXL_PREFIX}/lib:${NIXL_PREFIX}/lib/${libarch}:${NIXL_PREFIX}/lib/${libarch}/plugins:${ROCM_PATH}/lib:${LD_LIBRARY_PATH:-}"
    export NIXL_PLUGIN_DIR="${NIXL_PREFIX}/lib/${libarch}/plugins"

    # docker --user keeps image ENV HOME=/home/svc-nixl. NIXL then resolves
    # $HOME/.nixl.cfg (see configuration.cpp) and weakly_canonical(2) returns
    # EACCES for UIDs that cannot search that home directory.
    if [[ -n "${HOME:-}" ]] && [[ ! -x "$HOME" ]]; then
        export HOME=/tmp
    fi

    require_in_container_tools

    if [[ -z "$FILEPATH" ]]; then
        echo "ERROR: set FILEPATH to a directory inside the container (under your NVMe bind mount)." >&2
        echo "nixlbench AIS_MT creates files under FILEPATH (see createFileFds in nixl_worker.cpp)." >&2
        exit 1
    fi

    if [[ -e "$FILEPATH" && ! -d "$FILEPATH" ]]; then
        echo "ERROR: FILEPATH=${FILEPATH} exists but is not a directory." >&2
        echo "AIS_MT opens FILEPATH/nixlbench_ais_mt_test_file_* ; a regular file cannot be used." >&2
        echo "Use an empty directory (mkdir on the host) or remove the file and point FILEPATH at a directory." >&2
        exit 1
    fi

    if [[ ! -e "$FILEPATH" ]]; then
        if [[ "${INIT_FILE:-0}" = 1 ]]; then
            echo "Creating directory FILEPATH=${FILEPATH}"
            if ! mkdir -p "$FILEPATH"; then
                echo "ERROR: could not mkdir FILEPATH=${FILEPATH} (e.g. permission denied)." >&2
                echo "Images based on Dockerfile.base run as non-root (UID 148069, svc-nixl by default)." >&2
                echo "Host-owned bind mounts are usually not writable by that UID." >&2
                echo "Fix: on the host run mkdir -p for that path, then run without --init-file, e.g.:" >&2
                echo "  mkdir -p <host-path-matching-FILEPATH>" >&2
                echo "Or use docker run --user \"\$(id -u):\$(id -g)\" (and --group-add for video/render if /dev/dri needs it)." >&2
                exit 1
            fi
        else
            echo "ERROR: FILEPATH=${FILEPATH} does not exist; mkdir on the host or pass --init-file." >&2
            exit 1
        fi
    fi

    local probe="${FILEPATH%/}/.nixlbench_ais_mt_write_probe.$$"
    if ! : >"$probe" 2>/dev/null; then
        echo "ERROR: cannot create files under FILEPATH=${FILEPATH} (permission denied)." >&2
        echo "This UID ($(id -u), $(id -un)) must be able to write the directory; nixlbench creates" >&2
        echo "nixlbench_ais_mt_test_file_* there. Host mkdir often leaves owner=your UID and mode 755;" >&2
        echo "images from Dockerfile.base usually run as UID 148069 (svc-nixl), not your host UID." >&2
        echo "Fix on host (pick one): chown -R 148069:30 the mounted directory tree (match Dockerfile.base" >&2
        echo "  _UID/_GID), or chmod a+w on that directory, or docker run --user \"\$(id -u):\$(id -g)\"" >&2
        echo "  with --group-add for video/render if /dev/dri access needs it." >&2
        exit 1
    fi
    rm -f "$probe"

    local -a nb_cmd=(
        "${NIXL_PREFIX}/bin/nixlbench-rocm"
        --backend AIS_MT
        --filepath "$FILEPATH"
        --initiator_seg_type VRAM
        --target_seg_type VRAM
        --gds_mt_num_threads "${GDS_MT_NUM_THREADS:-4}"
        --total_buffer_size "${TOTAL_BUFFER_SIZE:-$((64 * 1024 * 1024))}"
        --start_block_size "${START_BLOCK_SIZE:-65536}"
        --max_block_size "${MAX_BLOCK_SIZE:-65536}"
        --start_batch_size "${START_BATCH_SIZE:-1}"
        --max_batch_size "${MAX_BATCH_SIZE:-1}"
        --num_iter "${NUM_ITER:-200}"
        --warmup_iter "${WARMUP_ITER:-40}"
        --op_type "${OP_TYPE:-WRITE}"
        --check_consistency
    )
    if [[ -n "${NIXLBENCH_EXTRA:-}" ]]; then
        # shellcheck disable=SC2206
        nb_cmd+=(${NIXLBENCH_EXTRA})
    fi

    local report
    report="$(mktemp -t ais-mt-ais-stats.XXXXXX.log)"
    echo "HIPFILE_STATS_LEVEL=${HIPFILE_STATS_LEVEL} (ais-stats + nixlbench log: ${report})"
    echo "Running: ${nb_cmd[*]}"
    if [[ "${SKIP_AIS_STATS:-0}" = 1 ]]; then
        "${nb_cmd[@]}" 2>&1 | tee "$report"
    else
        "${AIS_STATS_BIN}" "${nb_cmd[@]}" 2>&1 | tee "$report"
    fi

    assert_fastpath_hint "$report"
}

INIT_FILE=0
SKIP_AIS_STATS=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --init-file) INIT_FILE=1; shift ;;
        --skip-ais-stats) SKIP_AIS_STATS=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) break ;;
    esac
done

cmd="${1:-run}"
case "$cmd" in
    print-docker-run) print_docker_run ;;
    help) usage ;;
    run)
        [[ $# -ge 1 && "$1" == run ]] && shift
        run_benchmark
        ;;
    *)
        echo "Unknown command: ${cmd}" >&2
        usage
        exit 1
        ;;
esac
