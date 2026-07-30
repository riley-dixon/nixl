# SPDX-FileCopyrightText: Copyright (c) 2026 Advanced Micro Devices, Inc. All rights reserved.
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

# AIS (AMD Infinity Storage) plugin. The abstract base engine (nixlAisEngine)
# is compiled once into ais_common_lib; each backend name builds a thin entry
# point plus its concrete engine subclass. Today the only name is "AIS_MT"; a
# hipFile batch engine mirroring "GDS" slots in alongside it later.

rocm_ais_path_opt = get_option('rocm_ais_path')
if rocm_ais_path_opt == ''
    rocm_path = run_command('bash', '-c', 'echo ${ROCM_PATH:-$ROCM_HOME}', check: false).stdout().strip()
    if rocm_path == ''
        rocm_path = '/opt/rocm'
    endif
    hipfile_search_dirs = [rocm_path, '/opt/rocs-ais', '/usr/local']
    hipfile_lib_found = false
    cc_local = meson.get_compiler('cpp')
    foreach search_dir : hipfile_search_dirs
        hipfile_lib_candidate = search_dir + '/lib'
        hipfile_inc_candidate = search_dir + '/include'
        if fs.exists(hipfile_lib_candidate) and fs.exists(hipfile_inc_candidate)
            hipfile_lib_check = cc_local.find_library('hipfile',
                dirs: [hipfile_lib_candidate], required: false)
            if hipfile_lib_check.found()
                hipfile_dep = declare_dependency(
                    link_args: ['-L' + hipfile_lib_candidate, '-lhipfile',
                                '-Wl,-rpath,' + hipfile_lib_candidate],
                    include_directories: include_directories(hipfile_inc_candidate))
                hipfile_lib_found = true
                message('Found hipFile at: ' + search_dir)
                break
            endif
        endif
    endforeach
    if not hipfile_lib_found
        hipfile_dep = declare_dependency()
        subdir_done()
    endif
else
    hipfile_lib_path = rocm_ais_path_opt + '/lib'
    hipfile_inc_path = rocm_ais_path_opt + '/include'
    hipfile_dep = declare_dependency(
        link_args: ['-L' + hipfile_lib_path, '-lhipfile',
                    '-Wl,-rpath,' + hipfile_lib_path],
        include_directories: include_directories(hipfile_inc_path))
endif

# hipFile calls are issued against HIP device memory, so the HIP runtime is
# required even for the registration-only paths.
if not hip_dep.found()
    subdir_done()
endif

ais_common_incs = [nixl_inc_dirs, utils_inc_dirs]
# Shared engine deps exclude TaskFlow because the common registration and
# metadata path does not create workers.
ais_common_deps = [nixl_infra, nixl_common_dep, hip_dep, hipfile_dep, file_utils_interface]

# Shared base engine + utils compiled exactly once (PIC) so it can be embedded
# into a shared plugin or linked statically into the core without duplicate
# symbols. No TaskFlow here.
ais_common_lib = static_library('ais_common',
    'ais_utils.cpp', 'ais_utils.h',
    'ais_backend.cpp', 'ais_backend.h',
    dependencies: ais_common_deps,
    include_directories: ais_common_incs,
    cpp_args: ['-fPIC'],
    install: false)

ais_common_dep = declare_dependency(
    link_with: ais_common_lib,
    dependencies: ais_common_deps,
    include_directories: ais_common_incs)

# "AIS_MT" backend name entry point (per-request TaskFlow strategy).
if enabled_plugins.get('AIS_MT')
    if not taskflow_proj.found()
        if is_explicit_enable
            error('AIS_MT plugin requested but Taskflow dependency not found')
        endif
        # Otherwise silently skip building the AIS_MT entry point.
    else
        ais_mt_sources = ['ais_mt_plugin.cpp', 'ais_mt_engine.cpp', 'ais_mt_engine.h']
        ais_mt_deps = [ais_common_dep, taskflow_proj, thread_dep]
        if 'AIS_MT' in static_plugins
            ais_mt_backend_lib = static_library('AIS_MT',
                ais_mt_sources,
                dependencies: ais_mt_deps,
                include_directories: ais_common_incs,
                install: false,
                name_prefix: 'libplugin_')  # Custom prefix for plugin libraries
        else
            ais_mt_backend_lib = shared_library('AIS_MT',
                ais_mt_sources,
                dependencies: ais_mt_deps,
                include_directories: ais_common_incs,
                install: true,
                cpp_args: ['-fPIC'],
                name_prefix: 'libplugin_',  # Custom prefix for plugin libraries
                install_dir: plugin_install_dir,
                install_rpath: '$ORIGIN/..')
            if get_option('buildtype') == 'debug'
                run_command('sh', '-c',
                    'echo "AIS_MT=' + ais_mt_backend_lib.full_path() + '" >> ' + plugin_build_dir + '/pluginlist',
                    check: true
                )
            endif
        endif
        ais_mt_backend_interface = declare_dependency(
            link_with: ais_mt_backend_lib,
            dependencies: [taskflow_proj, thread_dep])
    endif
endif
