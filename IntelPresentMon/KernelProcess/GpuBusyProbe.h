// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: MIT
#pragma once
#include <cmath>
#include <PresentMonAPIWrapper/Session.h>
#include <PresentMonAPIWrapperCommon/Exception.h>
#include <CommonUtilities/Qpc.h>
#include <algorithm>
#include <array>
#include <cstring>
#include <memory>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace kproc
{
    struct GpuBusyTotal
    {
        uint32_t pid;
        double busyMilliseconds;
        template<class A> void serialize(A& ar) { ar(pid, busyMilliseconds); }
    };

    // Uses a separate API session so probing cannot stop or consume the overlay's tracking.
    class GpuBusyProbe
    {
    public:
        explicit GpuBusyProbe(pmapi::Session session) : session_{ std::move(session) }
        {
            std::array elements{
                PM_QUERY_ELEMENT{ .metric = PM_METRIC_PRESENT_START_QPC, .stat = PM_STAT_NONE },
                PM_QUERY_ELEMENT{ .metric = PM_METRIC_GPU_BUSY, .stat = PM_STAT_NONE },
            };
            frames_ = session_.RegisterFrameQuery(elements);
            timestampOffset_ = elements[0].dataOffset;
            gpuBusyOffset_ = elements[1].dataOffset;
            frameBlobs_ = frames_.MakeBlobContainer(256);
        }

        std::vector<GpuBusyTotal> Poll(const std::vector<uint32_t>& pids)
        {
            const std::unordered_set<uint32_t> wanted{ pids.begin(), pids.end() };
            std::erase_if(entries_, [&](const auto& entry) { return !wanted.contains(entry.first); });
            std::vector<GpuBusyTotal> totals;
            for (const auto pid : wanted) {
                try {
                    auto it = entries_.find(pid);
                    if (it == entries_.end()) {
                        entries_.emplace(pid, std::make_unique<Entry>(session_, pid));
                        continue; // New trackers need actual frames before they can qualify.
                    }
                    auto& entry = *it->second;
                    double total = 0.;
                    // Bound work even if a producer continuously fills the queue.
                    for (int batch = 0; batch < 64; ++batch) {
                        frames_.Consume(entry.tracker, frameBlobs_);
                        for (const auto blob : frameBlobs_) {
                            uint64_t timestamp = 0;
                            double rawGpuBusy = 0;
                            std::memcpy(&timestamp, blob + timestampOffset_, sizeof(timestamp));
                            std::memcpy(&rawGpuBusy, blob + gpuBusyOffset_, sizeof(rawGpuBusy));
                            if (timestamp >= entry.started && std::isfinite(rawGpuBusy) && rawGpuBusy > 0.) {
                                total += rawGpuBusy;
                            }
                        }
                        if (!frameBlobs_.AllBlobsPopulated()) break;
                    }
                    totals.push_back({ pid, total });
                }
                catch (const pmapi::ApiErrorException& ex) {
                    entries_.erase(pid);
                    // An exited/inaccessible process must not prevent other candidates from qualifying.
                    if (ex.GetCode() != PM_STATUS_INVALID_PID && ex.GetCode() != PM_STATUS_FAILURE) throw;
                }
            }
            return totals;
        }

    private:
        struct Entry
        {
            Entry(pmapi::Session& session, uint32_t pid) : tracker{ session.TrackProcess(pid) } {}
            pmapi::ProcessTracker tracker;
            uint64_t started = (uint64_t)pmon::util::GetCurrentTimestamp();
        };
        pmapi::Session session_;
        pmapi::FrameQuery frames_;
        pmapi::BlobContainer frameBlobs_;
        uint64_t timestampOffset_ = 0;
        uint64_t gpuBusyOffset_ = 0;
        std::unordered_map<uint32_t, std::unique_ptr<Entry>> entries_;
    };
}
