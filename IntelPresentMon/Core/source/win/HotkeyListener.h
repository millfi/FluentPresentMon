// Copyright (C) 2022 Intel Corporation
// SPDX-License-Identifier: MIT
#pragma once
#include <CommonUtilities/win/WinAPI.h>
#include <CommonUtilities/mt/Thread.h>
#include <Core/source/win/Key.h>
#include <Core/source/win/ModSet.h>
#include <functional>
#include <future>
#include <map>
#include <semaphore>

namespace p2c::win
{
    class Hotkeys
    {
    public:
        Hotkeys();
        Hotkeys(const Hotkeys&) = delete;
        Hotkeys& operator=(const Hotkeys&) = delete;
        ~Hotkeys();
        bool BindAction(int action, Key key, ModSet mods);
        bool ClearAction(int action);
        void SetHandler(std::function<void(int)> handler);
    private:
        struct Binding
        {
            int action;
            UINT key;
            UINT modifiers;
        };
        bool Invoke_(std::function<bool()> command);
        bool ClearAction_(int action);
        void Kernel_() noexcept;
        static constexpr UINT commandMessage_ = WM_APP + 1;
        std::binary_semaphore startupSemaphore_{ 0 };
        DWORD threadId_{};
        // Registrations and the handler are accessed only on the hotkey thread.
        std::map<int, Binding> bindings_;
        std::function<void(int)> handler_;
        int nextId_ = 1;
        // Construct last and join before any state used by the thread is destroyed.
        ::pmon::util::mt::Thread thread_;
    };
}
