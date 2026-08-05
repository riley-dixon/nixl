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
# See the License for the specific language governing permissions and
# limitations under the License.

project('nixlbench', 'CPP', version: '1.4.0',
    default_options: ['buildtype=release',
                'werror=true',
                'cpp_std=c++20',
                'prefix=/usr/local/nixlbench'],
    meson_version: '>= 0.64.0'
)

# set up some global vars for compiler, platform, configuration, etc.
cpp = meson.get_compiler('cpp')
fs = import('fs')

# Allow overriding paths through environment variables
# CUDA
cuda_inc_path = get_option('cudapath_inc')
cuda_lib_path = get_option('cudapath_lib')
cuda_stub_path = get_option('cudapath_stub')
# ETCD
etcd_inc_path = get_option('etcd_inc_path')
etcd_lib_path = get_option('etcd_lib_path')
# NIXL
nixl_path = get_option('nixl_path')
# NVSHMEM
nvshmem_inc_path = get_option('nvshmem_inc_path')
nvshmem_lib_path = get_option('nvshmem_lib_path')

# Find required libraries
# NIXL
host_cpu_family = host_machine.cpu_family()
host_system = host_machine.system().to_lower()

if host_system != 'linux' or host_cpu_family not in ['x86_64', 'aarch64']
    error('This build only supports Linux on x86_64 or aarch64 architectures.')
endif

nixl_lib_path = join_paths(nixl_path, get_option('libdir'))
nixl_lib = cpp.find_library('nixl', dirs: [nixl_lib_path])
nixl_build = cpp.find_library('nixl_build', dirs: [nixl_lib_path])
nixl_serdes = cpp.find_library('serdes', dirs: [nixl_lib_path])

if not nixl_lib.found() or not nixl_build.found() or not nixl_serdes.found()
    error('NIXL Libraries not found. Exiting.')
endif

# CUDA (always probed; independent of ROCm)
cuda_available = false
if cuda_lib_path == ''
    cuda_dep = dependency('cuda', required : false, modules : [ 'cudart', 'cuda' ])
    if not cuda_dep.found()
        # Meson is not detecting CUDA reliably on ARM, fallback to default
        cuda_home = run_command('bash', '-c', 'echo $CUDA_HOME', check: true).stdout().strip()
        if cuda_home == ''
            cuda_home = '/usr/local/cuda'
        endif
        cuda_lib = cuda_home + '/lib64'
        cuda_inc = cuda_home + '/include'
        cuda_stub = cuda_lib + '/stubs'
        if fs.exists(cuda_lib) and fs.exists(cuda_inc)
            cuda_dep = declare_dependency(
              link_args : ['-L' + cuda_lib, '-L' + cuda_stub, '-lcuda', '-lcudart'],
              include_directories : include_directories(cuda_inc))
            if cuda_dep.found()
                message('Found CUDA installation through fallback method:', cuda_home)
            endif
        endif
    endif
    if cuda_dep.found()
        cuda_available = true
    else
        warning('CUDA not found. VRAM support will be disabled.')
    endif
else
    message('cuda lib path ', cuda_lib_path)
    if cuda_stub_path == ''
        cuda_stub_path = cuda_lib_path + '/stubs'
    endif
    cuda_dep = declare_dependency(
        link_args : ['-L' + cuda_lib_path, '-L' + cuda_stub_path, '-lcuda', '-lcudart'],
        include_directories : include_directories(cuda_inc_path))
    cuda_available = true
endif

cuda_detected = cuda_available

# ROCm / HIP (optional auto-detect; use_rocm=true makes HIP mandatory)
rocm_available = false
rocm_dep = declare_dependency()
want_rocm = get_option('use_rocm')
# `rocm_path` names the ROCm install prefix. When unset it follows ROCM_PATH
# from the environment. rocm_path could be a directory or symlink, so probe
# for the library itself rather than trusting the directory to exist.
rocm_path = get_option('rocm_path')
if rocm_path == ''
    rocm_path = run_command('bash', '-c', 'echo ${ROCM_PATH:-/opt/rocm}',
                            check: true).stdout().strip()
endif
rocm_lib_path = rocm_path + '/lib'
rocm_inc_path = rocm_path + '/include'
rocm_inc = include_directories(rocm_inc_path)
amdhip64_lib = cpp.find_library('amdhip64', dirs: [rocm_lib_path], required: false)
if amdhip64_lib.found() and cpp.has_header('hip/hip_runtime.h', include_directories: rocm_inc)
    rocm_dep = declare_dependency(
        link_args : ['-L' + rocm_lib_path, '-lamdhip64', '-lhiprtc'],
        include_directories : rocm_inc)
    rocm_available = true
elif want_rocm
    error('use_rocm=true but ROCm HIP was not found under ' + rocm_path +
          '. Set -Drocm_path=<prefix> to the correct ROCm install root.')
endif

rocm_detected = rocm_available

# One translation unit cannot include CUDA and HIP headers together. Use
# nixlbench_gpu=cuda vs nixlbench_gpu=rocm for two separate Meson builds.
gpu_flavor = get_option('nixlbench_gpu')
if gpu_flavor == 'cuda'
    cuda_available = cuda_detected
    rocm_bench = false
elif gpu_flavor == 'rocm'
    cuda_available = false
    rocm_bench = rocm_detected
else
    cuda_available = cuda_detected
    rocm_bench = rocm_detected
endif
nixlbench_rocm_enabled = rocm_bench and not cuda_available

if gpu_flavor == 'cuda' and not cuda_detected
    error('nixlbench_gpu=cuda was set but CUDA was not found.')
endif
if gpu_flavor == 'rocm' and not rocm_detected
    error('nixlbench_gpu=rocm was set but ROCm HIP was not found under ' + rocm_path + '.')
endif

if nixlbench_rocm_enabled
    add_project_arguments('-D__HIP_PLATFORM_AMD__', '-Wno-deprecated-declarations',
                          language: 'cpp')
endif

if cuda_detected and rocm_detected and gpu_flavor == 'auto'
    message(
        'CUDA and ROCm both found: default nixlbench build uses CUDA only. ' +
        'For a HIP binary as well, run a second Meson configure in another ' +
        'build directory with -Dnixlbench_gpu=rocm (see .gitlab/build-rocm.sh).',
    )
endif

bench_exe = (gpu_flavor == 'rocm' and cuda_detected) ? 'nixlbench-rocm' : 'nixlbench'

cuda_fabric_available = false
if cuda_available
    if cpp.has_header_symbol('cuda.h', 'CU_MEM_HANDLE_TYPE_FABRIC', dependencies: cuda_dep)
        cuda_fabric_available = true
    endif
endif

# OpenMP
openmp_dep = dependency('openmp', required: true)

# Try CMake before pkg-config (see root meson.build: matches Debian etcd dev).
etcd_dep = dependency('etcd-cpp-api', required : false, method : 'cmake')
if not etcd_dep.found()
  etcd_dep = dependency('etcd-cpp-api', required : false, method : 'pkg-config')
endif

# GFlags
gflags_dep = dependency('gflags', required: true)

# ASIO (usually via libasio-dev package)
asio_dep = dependency('asio', required: true)

# Check for tomlplusplus (header only)
tomlplusplus_dep = dependency('tomlplusplus', required: true, default_options: ['build_lib=false', 'compile_library=false'])

# Ensure etcd is available
etcd_available = etcd_dep.found()
if etcd_available
    add_project_arguments('-DHAVE_ETCD', language: 'cpp')
else
    message('ETCD C++ client library not found. Disabling ETCD runtime.')
endif

etcd_inc = etcd_inc_path
nixl_inc = nixl_path + '/include'
nvshmem_inc = nvshmem_inc_path

inc_dir = include_directories('.', './src/', nixl_inc)

nvshmem_available = false
if nvshmem_lib_path != '' and cuda_available
    if cpp.has_header('nvshmem.h', include_directories: include_directories(nvshmem_inc))
        nvshmem_lib = cpp.find_library('nvshmem', dirs: [nvshmem_lib_path])
        nvshmem_host_lib = cpp.find_library('nvshmem_host', dirs: [nvshmem_lib_path])
        if nvshmem_lib.found()
            nvshmem_available = true
            inc_dir = include_directories('.', './src/', nixl_inc, nvshmem_inc)
            add_project_arguments('-DHAVE_NVSHMEM', language: 'cpp')
            add_project_arguments('-Wno-unused-variable', language: 'cpp')
        endif
    endif
endif

if cuda_available
    add_project_arguments('-DHAVE_CUDA', language: 'cpp')
endif

if nixlbench_rocm_enabled
    add_project_arguments('-DHAVE_ROCM', language: 'cpp')
endif

if cuda_fabric_available
    add_project_arguments('-DHAVE_CUDA_FABRIC', language: 'cpp')
endif

if not cuda_available and not nixlbench_rocm_enabled
    warning('Neither CUDA nor ROCm is enabled for this nixlbench build. VRAM support will be disabled.')
endif

# Subprojects
subdir('src/utils')
subdir('src/runtime')
subdir('src/worker')

# Configure header file
configure_file(
    output: 'config.h',
    configuration: {
        'HAVE_ETCD': etcd_available ? '1' : '0',
        'HAVE_NVSHMEM': nvshmem_available ? '1' : '0',
        'HAVE_CUDA': cuda_available ? '1' : '0',
        'HAVE_ROCM': nixlbench_rocm_enabled ? '1' : '0',
        'HAVE_CUDA_FABRIC': cuda_fabric_available ? '1' : '0',
    },
    install: true,
    install_dir: get_option('includedir') / 'nixlbench'
)

deps = [nixl_lib, nixl_build, nixl_serdes, openmp_dep, gflags_dep, tomlplusplus_dep, asio_dep]
args = []
if etcd_available
    deps += [etcd_dep]
endif
if cuda_available
    deps += [cuda_dep]
endif
if nixlbench_rocm_enabled
    deps += [rocm_dep]
endif
if nvshmem_available
    deps += [nvshmem_lib]
    args += [
        '-Xcompiler', '-fopenmp',
        '-Xlinker', '-rpath=/usr/local/cuda/lib64',
        '-Xlinker', '--allow-shlib-undefined',
        '-lcudart',
        '-lcudadevrt',
    ]
endif

if nvshmem_available
    # Use nvcc directly for compilation and linking
    nvcc = find_program('nvcc')
    nvcc_args = []
    if etcd_available
        if etcd_inc != ''
            nvcc_args += ['-I' + etcd_inc]
        endif
    endif
    nvcc_args += ['-I' + nixl_inc]
    nvcc_args += ['-I' + nvshmem_inc]
    nvcc_args += ['-I.', '-I./src/', '-I../src/']
    nvcc_args += ['-I' + meson.current_build_dir()]
    if etcd_available
        if etcd_lib_path != ''
            nvcc_args += ['-L' + etcd_lib_path]
        endif
    endif
    nvcc_args += ['-L' + nixl_lib_path]
    nvcc_args += ['-L' + nvshmem_lib_path]
    nvcc_args += ['-L' + meson.current_build_dir() + '/src/utils']
    nvcc_args += ['-L' + meson.current_build_dir() + '/src/runtime']
    nvcc_args += ['-L' + meson.current_build_dir() + '/src/worker']
    nvcc_args += ['-lnixl', '-lnixl_build', '-lserdes', '-lcuda', '-lcudart', '-lnvshmem']
    nvcc_args += args
    nvcc_cmd_files = [
                 meson.current_build_dir() + '/src/utils/libutils.a.p/utils.cpp.o',
                 meson.current_build_dir() + '/src/runtime/libruntime.a.p/runtime.cpp.o',
                 meson.current_build_dir() + '/src/worker/libworker.a.p/worker.cpp.o',
                 meson.current_build_dir() + '/src/worker/nixl/libnixl_worker.a.p/nixl_worker.cpp.o',
                 meson.current_build_dir() + '/src/worker/nvshmem/libnvshmemWorker.a.p/nvshmem_worker.cpp.o'
                 ]

    if etcd_available
        nvcc_args += ['-letcd-cpp-api-core', '-lcpprest']
        etcd_rt = meson.current_build_dir() + '/src/runtime/etcd/libetcd_rt.a.p/etcd_rt.cpp.o'
        nvcc_cmd_files += etcd_rt
    endif

    nvcc_command = [nvcc, nvcc_args, '-o', '@OUTPUT@', '@INPUT@']
    nvcc_command += nvcc_cmd_files

    custom_target(
        bench_exe,
        input: 'src/main.cpp',
        output: bench_exe,
        command: nvcc_command,
        build_by_default: true,
        install: true,
        install_dir: get_option('bindir'),
        depends: [nixlbench_runtimes, utils_lib, worker_libs])
else
    executable(
        bench_exe,
        'src/main.cpp',
        include_directories: inc_dir,
        link_with: [nixlbench_runtimes, utils_lib, worker_libs],
        dependencies: deps,
        link_args: args,
        build_rpath: nixl_lib_path,
        install_rpath: nixl_lib_path,
        install: true,
        install_dir: get_option('bindir'))
endif
