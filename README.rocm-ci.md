# ROCm and CUDA Based NIXL CI Setup and Build

## Build Process

To build the docker-based CI setup and build for both CUDA and ROCm versions
of NIXL and nixlbench do the following. Note the first step is needed if you
cannot access the Mellanox registry which houses the infinia stub.
```
docker build -f .ci/dockerfiles/Dockerfile.infinia-stub -t infinia-libs:stub .
docker build -f .ci/dockerfiles/Dockerfile.base --build-arg NIXL_INSTALL_DIR=/opt/nixl --build-arg INFINIA_LIBS_IMAGE=infinia-libs:stub --build-arg PRE_INSTALLED_NIXL_ENV=1 -t nixl-ci-base:latest .
docker build -f .ci/dockerfiles/Dockerfile.gpu-test --build-arg PRE_INSTALLED_ENV=1 --build-arg BASE_IMAGE=docker.io/library/nixl-ci-base:latest -t nixl-gpu-test:latest .
```

## Build Validation

Verify what landed in the image (the script runs **inside** the container).
From the repo root, bind-mount the checker, or use the path below after a
`gpu-test` build that used `COPY . .`:

```bash
docker run --rm -v "$PWD/.ci/scripts/verify-gpu-test-contents.sh:/tmp/v.sh:ro" \
  nixl-gpu-test:latest bash /tmp/v.sh
```

### Validation Results

```bash
$ docker run --rm -v "$PWD/.ci/scripts/verify-gpu-test-contents.sh:/tmp/v.sh:ro" \
  nixl-gpu-test:latest bash /tmp/v.sh

=== Install prefix ===
OK: /opt/nixl

=== Core NIXL libraries ===
OK: /opt/nixl/lib/x86_64-linux-gnu/libnixl.so
OK: /opt/nixl/lib/x86_64-linux-gnu/libnixl_build.so

=== Plugin directory ===
OK: /opt/nixl/lib/x86_64-linux-gnu/plugins (12 plugins)
-rwxr-xr-x 1 svc-nixl dip  4634408 Jun 17 20:48 /opt/nixl/lib/x86_64-linux-gnu/plugins/libplugin_AZURE_BLOB.so
-rwxr-xr-x 1 svc-nixl dip  1364512 Jun 17 20:48 /opt/nixl/lib/x86_64-linux-gnu/plugins/libplugin_GDS.so
-rwxr-xr-x 1 svc-nixl dip  4235528 Jun 17 20:48 /opt/nixl/lib/x86_64-linux-gnu/plugins/libplugin_GDS_MT.so
-rwxr-xr-x 1 svc-nixl dip 25269360 Jun 17 20:48 /opt/nixl/lib/x86_64-linux-gnu/plugins/libplugin_GPUNETIO.so
-rwxr-xr-x 1 svc-nixl dip  1406296 Jun 17 20:48 /opt/nixl/lib/x86_64-linux-gnu/plugins/libplugin_GUSLI.so
-rwxr-xr-x 1 svc-nixl dip  7301448 Jun 17 20:48 /opt/nixl/lib/x86_64-linux-gnu/plugins/libplugin_LIBFABRIC.so
-rwxr-xr-x 1 svc-nixl dip  5650000 Jun 17 20:48 /opt/nixl/lib/x86_64-linux-gnu/plugins/libplugin_MOCK_BACKEND.so
-rwxr-xr-x 1 svc-nixl dip  1664368 Jun 17 20:48 /opt/nixl/lib/x86_64-linux-gnu/plugins/libplugin_Mooncake.so
-rwxr-xr-x 1 svc-nixl dip  6317496 Jun 17 20:48 /opt/nixl/lib/x86_64-linux-gnu/plugins/libplugin_OBJ.so
-rwxr-xr-x 1 svc-nixl dip  2221160 Jun 17 20:48 /opt/nixl/lib/x86_64-linux-gnu/plugins/libplugin_POSIX.so
-rwxr-xr-x 1 svc-nixl dip  2182032 Jun 17 20:48 /opt/nixl/lib/x86_64-linux-gnu/plugins/libplugin_UCCL.so
-rwxr-xr-x 1 svc-nixl dip  5145336 Jun 17 20:48 /opt/nixl/lib/x86_64-linux-gnu/plugins/libplugin_UCX.so

=== UCX backend plugin ===
OK: /opt/nixl/lib/x86_64-linux-gnu/plugins/libplugin_UCX.so
--- readelf NEEDED (first level) ---
 0x0000000000000001 (NEEDED)             Shared library: [libnixl_common.so]
 0x0000000000000001 (NEEDED)             Shared library: [libnixl_build.so]
 0x0000000000000001 (NEEDED)             Shared library: [libserdes.so]
 0x0000000000000001 (NEEDED)             Shared library: [libabsl_log_internal_message.so.2508.0.0]
 0x0000000000000001 (NEEDED)             Shared library: [libabsl_log_internal_nullguard.so.2508.0.0]
 0x0000000000000001 (NEEDED)             Shared library: [libabsl_vlog_config_internal.so.2508.0.0]
 0x0000000000000001 (NEEDED)             Shared library: [libabsl_strings.so.2508.0.0]
 0x0000000000000001 (NEEDED)             Shared library: [libucp.so.0]
 0x0000000000000001 (NEEDED)             Shared library: [libucs.so.0]
 0x0000000000000001 (NEEDED)             Shared library: [libstdc++.so.6]
 0x0000000000000001 (NEEDED)             Shared library: [libgcc_s.so.1]
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
 0x0000000000000001 (NEEDED)             Shared library: [ld-linux-x86-64.so.2]
--- ldd (full; CUDA/ROCm names may be indirect) ---
        linux-vdso.so.1 (0x00007aa369df2000)
        libnixl_common.so => /opt/nixl/lib/x86_64-linux-gnu/plugins/../libnixl_common.so (0x00007aa369bf5000)
        libnixl_build.so => /opt/nixl/lib/x86_64-linux-gnu/plugins/../libnixl_build.so (0x00007aa369b68000)
        libserdes.so => /opt/nixl/lib/x86_64-linux-gnu/plugins/../libserdes.so (0x00007aa369b5a000)
        libabsl_log_internal_message.so.2508.0.0 => /opt/nixl/lib/libabsl_log_internal_message.so.2508.0.0 (0x00007aa369b4b000)
        libabsl_log_internal_nullguard.so.2508.0.0 => /opt/nixl/lib/libabsl_log_internal_nullguard.so.2508.0.0 (0x00007aa369b46000)
        libabsl_vlog_config_internal.so.2508.0.0 => /opt/nixl/lib/libabsl_vlog_config_internal.so.2508.0.0 (0x00007aa369b3b000)
        libabsl_strings.so.2508.0.0 => /opt/nixl/lib/libabsl_strings.so.2508.0.0 (0x00007aa369b0f000)
        libucp.so.0 => /opt/nixl/lib/libucp.so.0 (0x00007aa369a0c000)
        libucs.so.0 => /opt/nixl/lib/libucs.so.0 (0x00007aa369992000)
        libstdc++.so.6 => /lib/x86_64-linux-gnu/libstdc++.so.6 (0x00007aa369704000)
        libgcc_s.so.1 => /lib/x86_64-linux-gnu/libgcc_s.so.1 (0x00007aa3696d6000)
        libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007aa3694c2000)
        /lib64/ld-linux-x86-64.so.2 (0x00007aa369df4000)
        libabsl_log_globals.so.2508.0.0 => not found
        libabsl_hash.so.2508.0.0 => not found
        libabsl_throw_delegate.so.2508.0.0 => not found
        libabsl_raw_logging_internal.so.2508.0.0 => not found
        libabsl_log_initialize.so.2508.0.0 => not found
        libabsl_raw_hash_set.so.2508.0.0 => not found
        libabsl_examine_stack.so.2508.0.0 => /opt/nixl/lib/libabsl_examine_stack.so.2508.0.0 (0x00007aa3694bb000)
        libabsl_log_internal_format.so.2508.0.0 => /opt/nixl/lib/libabsl_log_internal_format.so.2508.0.0 (0x00007aa3694b6000)
        libabsl_log_internal_structured_proto.so.2508.0.0 => /opt/nixl/lib/libabsl_log_internal_structured_proto.so.2508.0.0 (0x00007aa3694b1000)
        libabsl_strerror.so.2508.0.0 => /opt/nixl/lib/libabsl_strerror.so.2508.0.0 (0x00007aa3694aa000)
        libabsl_log_internal_log_sink_set.so.2508.0.0 => /opt/nixl/lib/libabsl_log_internal_log_sink_set.so.2508.0.0 (0x00007aa3694a3000)
        libabsl_log_internal_globals.so.2508.0.0 => /opt/nixl/lib/libabsl_log_internal_globals.so.2508.0.0 (0x00007aa36949e000)
        libabsl_log_globals.so.2508.0.0 => /opt/nixl/lib/libabsl_log_globals.so.2508.0.0 (0x00007aa369498000)
        libabsl_log_internal_proto.so.2508.0.0 => /opt/nixl/lib/libabsl_log_internal_proto.so.2508.0.0 (0x00007aa369493000)
        libabsl_time.so.2508.0.0 => /opt/nixl/lib/libabsl_time.so.2508.0.0 (0x00007aa36947a000)
        libabsl_strings_internal.so.2508.0.0 => /opt/nixl/lib/libabsl_strings_internal.so.2508.0.0 (0x00007aa369474000)
        libabsl_base.so.2508.0.0 => /opt/nixl/lib/libabsl_base.so.2508.0.0 (0x00007aa36946d000)
        libabsl_raw_logging_internal.so.2508.0.0 => /opt/nixl/lib/libabsl_raw_logging_internal.so.2508.0.0 (0x00007aa369468000)
        libabsl_log_internal_fnmatch.so.2508.0.0 => /opt/nixl/lib/libabsl_log_internal_fnmatch.so.2508.0.0 (0x00007aa369463000)
        libabsl_synchronization.so.2508.0.0 => /opt/nixl/lib/libabsl_synchronization.so.2508.0.0 (0x00007aa36944f000)
        libm.so.6 => /lib/x86_64-linux-gnu/libm.so.6 (0x00007aa369366000)
        libuct.so.0 => /opt/nixl/lib/libuct.so.0 (0x00007aa369325000)
        libucm.so.0 => /opt/nixl/lib/libucm.so.0 (0x00007aa369307000)
        libabsl_stacktrace.so.2508.0.0 => /opt/nixl/lib/libabsl_stacktrace.so.2508.0.0 (0x00007aa369301000)
        libabsl_symbolize.so.2508.0.0 => /opt/nixl/lib/libabsl_symbolize.so.2508.0.0 (0x00007aa3692f6000)
        libabsl_str_format_internal.so.2508.0.0 => /opt/nixl/lib/libabsl_str_format_internal.so.2508.0.0 (0x00007aa3692d6000)
        libabsl_log_sink.so.2508.0.0 => /opt/nixl/lib/libabsl_log_sink.so.2508.0.0 (0x00007aa3692d1000)
        libabsl_spinlock_wait.so.2508.0.0 => /opt/nixl/lib/libabsl_spinlock_wait.so.2508.0.0 (0x00007aa3692cc000)
        libabsl_hash.so.2508.0.0 => /opt/nixl/lib/libabsl_hash.so.2508.0.0 (0x00007aa3692c7000)
        libabsl_time_zone.so.2508.0.0 => /opt/nixl/lib/libabsl_time_zone.so.2508.0.0 (0x00007aa3692a2000)
        libabsl_kernel_timeout_internal.so.2508.0.0 => /opt/nixl/lib/libabsl_kernel_timeout_internal.so.2508.0.0 (0x00007aa36929d000)
        libabsl_tracing_internal.so.2508.0.0 => /opt/nixl/lib/libabsl_tracing_internal.so.2508.0.0 (0x00007aa369298000)
        libabsl_malloc_internal.so.2508.0.0 => /opt/nixl/lib/libabsl_malloc_internal.so.2508.0.0 (0x00007aa369291000)
        libabsl_debugging_internal.so.2508.0.0 => /opt/nixl/lib/libabsl_debugging_internal.so.2508.0.0 (0x00007aa36928a000)
        libabsl_demangle_internal.so.2508.0.0 => /opt/nixl/lib/libabsl_demangle_internal.so.2508.0.0 (0x00007aa369277000)
        libabsl_int128.so.2508.0.0 => /opt/nixl/lib/libabsl_int128.so.2508.0.0 (0x00007aa36926e000)
        libabsl_city.so.2508.0.0 => /opt/nixl/lib/libabsl_city.so.2508.0.0 (0x00007aa369269000)
        libabsl_demangle_rust.so.2508.0.0 => /opt/nixl/lib/libabsl_demangle_rust.so.2508.0.0 (0x00007aa369262000)
        libabsl_decode_rust_punycode.so.2508.0.0 => /opt/nixl/lib/libabsl_decode_rust_punycode.so.2508.0.0 (0x00007aa36925d000)
        libabsl_utf8_for_code_point.so.2508.0.0 => /opt/nixl/lib/libabsl_utf8_for_code_point.so.2508.0.0 (0x00007aa369256000)

=== UCX transport modules (CUDA / ROCm hints) ===
  /opt/nixl/lib/ucx/libuct_rocm.so
  /opt/nixl/lib/ucx/libucx_perftest_rocm.so.0
  /opt/nixl/lib/ucx/libuct_rocm.so.0
  /opt/nixl/lib/ucx/libucx_perftest_rocm.so
  /opt/nixl/lib/ucx/libucx_perftest_rocm.so.0.0.0
  /opt/nixl/lib/ucx/libucm_rocm.so
  /opt/nixl/lib/ucx/libucm_rocm.so.0.0.0
  /opt/nixl/lib/ucx/libucm_rocm.so.0
  /opt/nixl/lib/ucx/libuct_rocm.so.0.0.0
  /opt/nixl/lib/ucx/libuct_cuda.so.0
  /opt/nixl/lib/ucx/libucm_cuda.so.0.0.0
  /opt/nixl/lib/ucx/libuct_cuda.so.0.0.0
  /opt/nixl/lib/ucx/libucx_perftest_cuda.so.0.0.0
  /opt/nixl/lib/ucx/libucx_perftest_cuda.so.0
  /opt/nixl/lib/ucx/libucm_cuda.so.0
  /opt/nixl/lib/ucx/libucx_perftest_cuda.so
  /opt/nixl/lib/ucx/libucm_cuda.so
  /opt/nixl/lib/ucx/libuct_cuda.so

=== nixlbench binaries ===
OK: /opt/nixl/bin/nixlbench
/opt/nixl/bin/nixlbench: ELF 64-bit LSB pie executable, x86-64, version 1 (GNU/Linux), dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2, BuildID[sha1]=d34f7913843e22efd52572d8356180d4d5745b46, for GNU/Linux 3.2.0, not stripped
OK: /opt/nixl/bin/nixlbench-rocm (dual HIP build)
/opt/nixl/bin/nixlbench-rocm: ELF 64-bit LSB pie executable, x86-64, version 1 (GNU/Linux), dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2, BuildID[sha1]=74e6e79bc9d80fa3e359062386a75e71f8b81aab, for GNU/Linux 3.2.0, not stripped

=== UCX introspection (ucx_info) ===
Using: /opt/nixl/bin/ucx_info
# Library path should be under /opt/nixl/lib (not /opt/hpcx/ucx).
# "Configured with" should match the UCX built in .gitlab/build.sh.

=== Summary ===
warnings: 0  failures: 0
```
