/*
 * SPDX-FileCopyrightText: Copyright (c) 2026 Advanced Micro Devices, Inc. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include <exception>
#include <memory>
#include <utility>
#include <variant>

#include <hip/hip_runtime.h>

#include "ais_backend.h"
#include "common/nixl_log.h"
#include "file/file_utils.h"

namespace {

struct fileSegData {
    std::shared_ptr<aisFileHandle> handle;

    explicit fileSegData(std::shared_ptr<aisFileHandle> h) : handle(std::move(h)) {}
};

struct memSegData {
    std::unique_ptr<aisMemBuf> buf;

    memSegData(void *addr, size_t size, int flags)
        : buf(std::make_unique<aisMemBuf>(addr, size, flags)) {}
};

// Registered-descriptor state. FILE_SEG descriptors share a refcounted hipFile
// handle; memory descriptors own their pinned-buffer registration.
class nixlAisMetadata : public nixlBackendMD {
public:
    explicit nixlAisMetadata(std::shared_ptr<aisFileHandle> file_handle)
        : nixlBackendMD(true),
          data_(fileSegData{std::move(file_handle)}) {}

    nixlAisMetadata(void *addr, size_t size, int flags)
        : nixlBackendMD(true),
          data_(memSegData{addr, size, flags}) {}

    ~nixlAisMetadata() = default;

    nixlAisMetadata(const nixlAisMetadata &) = delete;
    nixlAisMetadata &
    operator=(const nixlAisMetadata &) = delete;

    std::variant<fileSegData, memSegData> data_;
};

} // namespace

nixlAisEngine::nixlAisEngine(const nixlBackendInitParams *init_params)
    : FileEngineBase(init_params) {
    try {
        driver_ = std::make_unique<aisDriverHandle>();
    }
    catch (const std::exception &e) {
        NIXL_ERROR << e.what();
        this->initErr = true;
    }
}

nixl_status_t
nixlAisEngine::registerMem(const nixlBlobDesc &mem,
                           const nixl_mem_t &nixl_mem,
                           nixlBackendMD *&out) {
    switch (nixl_mem) {
    case FILE_SEG: {
        // Repeated registrations of the same fd share one hipFile handle; the
        // map holds a weak reference so the last descriptor deregisters it.
        auto it = ais_file_map_.find(mem.devId);
        std::shared_ptr<aisFileHandle> handle;
        if (it != ais_file_map_.end()) {
            handle = it->second.lock();
            if (handle) {
                out = new nixlAisMetadata(std::move(handle));
                return NIXL_SUCCESS;
            }
            ais_file_map_.erase(it);
        }

        try {
            handle = std::make_shared<aisFileHandle>(mem.devId);
        }
        catch (const std::exception &e) {
            NIXL_ERROR << "AIS: failed to create file handle: " << e.what();
            return NIXL_ERR_BACKEND;
        }
        ais_file_map_[mem.devId] = handle;
        out = new nixlAisMetadata(std::move(handle));
        return NIXL_SUCCESS;
    }

    case VRAM_SEG: {
        const hipError_t error_id = hipSetDevice(mem.devId);
        if (error_id != hipSuccess) {
            NIXL_ERROR << "AIS: error: hipSetDevice returned " << hipGetErrorString(error_id)
                       << " for device ID " << mem.devId;
            return NIXL_ERR_BACKEND;
        }
        [[fallthrough]];
    }

    case DRAM_SEG: {
        try {
            out = new nixlAisMetadata((void *)mem.addr, mem.len, 0);
            return NIXL_SUCCESS;
        }
        catch (const std::exception &e) {
            NIXL_ERROR << "AIS: failed to create memory buffer: " << e.what();
            return NIXL_ERR_BACKEND;
        }
    }

    default:
        return NIXL_ERR_BACKEND;
    }
}

nixl_status_t
nixlAisEngine::deregisterMem(nixlBackendMD *meta) {
    std::unique_ptr<nixlAisMetadata> md(static_cast<nixlAisMetadata *>(meta));

    if (auto *file_data = std::get_if<fileSegData>(&md->data_)) {
        if (file_data->handle) {
            const int key = file_data->handle->fd;
            md.reset();

            auto it = ais_file_map_.find(key);
            if (it != ais_file_map_.end() && it->second.expired()) {
                ais_file_map_.erase(it);
            }
        }
    }

    return NIXL_SUCCESS;
}

nixl_status_t
nixlAisEngine::prepXfer(const nixl_xfer_op_t &operation,
                        const nixl_meta_dlist_t &local,
                        const nixl_meta_dlist_t &remote,
                        const std::string &remote_agent,
                        nixlBackendReqH *&handle,
                        const nixl_opt_b_args_t *opt_args) const {
    const size_t buf_cnt = local.descCount();
    const size_t file_cnt = remote.descCount();

    if ((buf_cnt != file_cnt) || ((operation != NIXL_READ) && (operation != NIXL_WRITE))) {
        NIXL_ERROR << "AIS: error: incorrect count or operation selection";
        return NIXL_ERR_INVALID_PARAM;
    }

    // Exactly one side must be the file side; file-to-file has no meaning here.
    const bool is_local_file = (local.getType() == FILE_SEG);
    if (is_local_file == (remote.getType() == FILE_SEG)) {
        NIXL_ERROR << "AIS: backend only supports I/O between memory and files";
        return NIXL_ERR_INVALID_PARAM;
    }

    std::vector<aisXferReq> reqs;
    reqs.reserve(buf_cnt);
    for (size_t i = 0; i < buf_cnt; i++) {
        const nixlMetaDesc &mem_desc = is_local_file ? remote[i] : local[i];
        const nixlMetaDesc &file_desc = is_local_file ? local[i] : remote[i];

        void *base_addr = (void *)mem_desc.addr;
        if (!base_addr) {
            return NIXL_ERR_INVALID_PARAM;
        }

        auto it = ais_file_map_.find(file_desc.devId);
        if (it == ais_file_map_.end()) {
            NIXL_ERROR << "AIS: error: file metadata not found";
            return NIXL_ERR_NOT_FOUND;
        }
        const auto file_handle = it->second.lock();
        if (!file_handle) {
            NIXL_ERROR << "AIS: file handle expired before transfer preparation";
            return NIXL_ERR_NOT_FOUND;
        }

        reqs.push_back(aisXferReq{base_addr,
                                  mem_desc.len,
                                  (size_t)file_desc.addr,
                                  file_handle->hip_fhandle,
                                  (operation == NIXL_READ) ? hipFileBatchRead : hipFileBatchWrite,
                                  mem_desc.devId});
    }

    if (reqs.empty()) {
        return NIXL_ERR_INVALID_PARAM;
    }

    return finalizePrep(std::move(reqs), handle);
}

nixl_status_t
nixlAisEngine::queryMem(const nixl_reg_dlist_t &descs,
                        std::vector<nixl_query_resp_t> &resp) const {
    std::vector<nixl_blob_t> metadata(descs.descCount());
    for (int i = 0; i < descs.descCount(); ++i) {
        metadata[i] = descs[i].metaInfo;
    }

    return nixl::queryFileInfoList(metadata, resp);
}
