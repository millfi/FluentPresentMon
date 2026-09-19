// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: MIT
#include "AutomaticTargeting.h"

#include <cmath>

namespace pmon::ui::core
{
    void AutomaticTargeting::Start(Clock::time_point now)
    {
        totals_.clear();
        deadline_ = now + std::chrono::milliseconds(200);
    }

    void AutomaticTargeting::Add(const std::vector<GpuBusyTotal>& samples)
    {
        for (const auto& sample : samples) {
            if (std::isfinite(sample.BusyMilliseconds) && sample.BusyMilliseconds > 0.) {
                totals_[sample.Pid] += sample.BusyMilliseconds;
            }
        }
    }

    bool AutomaticTargeting::IsDue(Clock::time_point now) const
    {
        return now >= deadline_;
    }

    std::optional<int> AutomaticTargeting::Finish(Clock::time_point now, const std::vector<int>& candidates)
    {
        std::optional<int> best;
        double bestTotal = 0.;
        for (const auto pid : candidates) {
            const auto found = totals_.find(pid);
            if (found == totals_.end()) continue;
            const auto total = found->second;
            if (total > bestTotal || (total == bestTotal && best && pid < *best)) {
                best = pid;
                bestTotal = total;
            }
        }
        totals_.clear();
        deadline_ = now + std::chrono::seconds(5);
        return best;
    }

}
