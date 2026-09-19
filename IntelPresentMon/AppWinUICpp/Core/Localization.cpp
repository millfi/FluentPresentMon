// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: MIT
#include "Localization.h"

#include <winrt/Microsoft.Windows.ApplicationModel.Resources.h>

#include <string>

namespace
{
    std::string ResourceKey(std::string_view key)
    {
        auto const keepDots = key.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.") == std::string_view::npos;
        std::string result;
        result.reserve(key.size());
        for (auto const character : key)
        {
            auto const isAlpha = (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z');
            auto const isDigit = character >= '0' && character <= '9';
            if (isAlpha || isDigit || character == '_')
            {
                result += character;
            }
            else if (keepDots && character == '.')
            {
                result += '/';
            }
            else
            {
                result += '_';
            }
        }
        return result;
    }

    winrt::Microsoft::Windows::ApplicationModel::Resources::ResourceLoader& Loader()
    {
        static auto loader = winrt::Microsoft::Windows::ApplicationModel::Resources::ResourceLoader(L"Resources");
        return loader;
    }

    void ReplaceAll(std::string& text, const std::string& token, const std::string& value)
    {
        size_t position = 0;
        while ((position = text.find(token, position)) != std::string::npos)
        {
            text.replace(position, token.size(), value);
            position += value.size();
        }
    }
}

namespace pmon::ui::localization
{
    winrt::hstring Text(std::string_view key)
    {
        auto const fallback = winrt::to_hstring(std::string{ key });
        if (key.empty()) return {};
        try
        {
            auto const localized = Loader().GetString(winrt::to_hstring(ResourceKey(key)));
            return localized.empty() ? fallback : localized;
        }
        catch (...)
        {
            return fallback;
        }
    }

    winrt::hstring Format(std::string_view key, std::initializer_list<std::string> values)
    {
        auto result = winrt::to_string(Text(key));
        size_t index = 0;
        for (const auto& value : values)
        {
            ReplaceAll(result, "{" + std::to_string(index++) + "}", value);
        }
        return winrt::to_hstring(result);
    }
}
