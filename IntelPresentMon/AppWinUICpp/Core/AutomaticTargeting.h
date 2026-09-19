// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: MIT
#pragma once

#include <chrono>
#include <unordered_map>
#include <optional>
#include <vector>

namespace pmon::ui::core
{
    struct GpuProcessSample
    {
        int Pid;
        double RunningTime;
    };

    struct GpuBusyTotal
    {
        int Pid;
        double BusyMilliseconds;
    };

    class AutomaticTargeting
    {
    public:
        using Clock = std::chrono::steady_clock;
        void Start(Clock::time_point now);
        void Add(const std::vector<GpuBusyTotal>& samples);
        bool IsDue(Clock::time_point now) const;
        std::optional<int> Finish(Clock::time_point now, const std::vector<int>& candidates);

    private:
        Clock::time_point deadline_{};
        std::unordered_map<int, double> totals_;
    };
}
