// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: MIT
#pragma once

#include <winrt/base.h>

#include <initializer_list>
#include <string>
#include <string_view>

namespace pmon::ui::localization
{
    winrt::hstring Text(std::string_view key);
    winrt::hstring Format(std::string_view key, std::initializer_list<std::string> values);
}
