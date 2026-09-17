// Copyright (C) 2022 Intel Corporation
// SPDX-License-Identifier: MIT
#include "HotkeyListener.h"
#include <Core/source/infra/Logging.h>
#include <CommonUtilities/Exception.h>
#include <stdexcept>

namespace p2c::win
{
    Hotkeys::Hotkeys() : thread_{ "hotkey", &Hotkeys::Kernel_, this }
    {
        startupSemaphore_.acquire();
    }

    Hotkeys::~Hotkeys()
    {
        PostThreadMessageW(threadId_, WM_QUIT, 0, 0);
        thread_.join();
    }

    bool Hotkeys::Invoke_(std::function<bool()> command)
    {
        if (GetCurrentThreadId() == threadId_) {
            return command();
        }
        std::packaged_task<bool()> task{ std::move(command) };
        auto result = task.get_future();
        if (!PostThreadMessageW(threadId_, commandMessage_, 0, reinterpret_cast<LPARAM>(&task))) {
            throw std::runtime_error("Failed to send a hotkey registration command.");
        }
        return result.get();
    }

    void Hotkeys::Kernel_() noexcept
    {
        threadId_ = GetCurrentThreadId();
        MSG message{};
        // Create the queue before allowing callers to post commands.
        PeekMessageW(&message, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
        startupSemaphore_.release();
        while (GetMessageW(&message, nullptr, 0, 0) > 0) {
            if (message.message == commandMessage_) {
                (*reinterpret_cast<std::packaged_task<bool()>*>(message.lParam))();
            }
            else if (message.message == WM_HOTKEY) {
                const auto binding = bindings_.find((int)message.wParam);
                if (binding != bindings_.end() && handler_) {
                    try {
                        // Copy so a callback can replace the handler safely.
                        auto handler = handler_;
                        handler(binding->second.action);
                    }
                    catch (...) {
                        pmlog_error(pmon::util::ReportException());
                    }
                }
            }
        }
        for (const auto& entry : bindings_) {
            UnregisterHotKey(nullptr, entry.first);
        }
    }

    void Hotkeys::SetHandler(std::function<void(int)> handler)
    {
        Invoke_([this, handler = std::move(handler)]() mutable {
            handler_ = std::move(handler);
            return true;
        });
    }

    bool Hotkeys::BindAction(int action, Key key, ModSet mods)
    {
        return Invoke_([this, action, key, mods] {
            const auto vk = key.GetPlatformCode();
            const auto modifiers = mods.ToPlatform();
            for (auto& entry : bindings_) {
                if (entry.second.key == vk && entry.second.modifiers == modifiers) {
                    if (entry.second.action != action) {
                        ClearAction_(action);
                        entry.second.action = action;
                    }
                    return true;
                }
            }
            // Use fresh IDs so queued messages from removed bindings are ignored.
            if (nextId_ > 0xBFFF) {
                return false;
            }
            const auto id = nextId_++;
            bindings_.emplace(id, Binding{ action, vk, modifiers });
            if (!RegisterHotKey(nullptr, id, modifiers | MOD_NOREPEAT, vk)) {
                bindings_.erase(id);
                pmlog_warn("Global hotkey registration failed").hr();
                return false;
            }
            // Keep the previous shortcut if the new registration fails.
            for (auto it = bindings_.begin(); it != bindings_.end();) {
                if (it->first != id && it->second.action == action) {
                    UnregisterHotKey(nullptr, it->first);
                    it = bindings_.erase(it);
                }
                else {
                    ++it;
                }
            }
            return true;
        });
    }

    bool Hotkeys::ClearAction_(int action)
    {
        for (auto it = bindings_.begin(); it != bindings_.end(); ++it) {
            if (it->second.action == action) {
                UnregisterHotKey(nullptr, it->first);
                bindings_.erase(it);
                break;
            }
        }
        return true;
    }

    bool Hotkeys::ClearAction(int action)
    {
        return Invoke_([this, action] { return ClearAction_(action); });
    }
}
