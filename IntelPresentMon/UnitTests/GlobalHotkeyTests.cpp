// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: MIT
#include <Core/source/win/HotkeyListener.h>
#include <CppUnitTest.h>
#include <atomic>
#include <chrono>
#include <semaphore>

using namespace Microsoft::VisualStudio::CppUnitTestFramework;
using namespace std::chrono_literals;
using namespace p2c::win;

namespace HotkeyTests
{
    TEST_CLASS(GlobalHotkeyTests)
    {
        static void KeyEvent(WORD key, bool up)
        {
            INPUT input{};
            input.type = INPUT_KEYBOARD;
            input.ki.wVk = key;
            input.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
            if (key == VK_RCONTROL) input.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
            Assert::AreEqual(1u, SendInput(1, &input, sizeof(input)));
        }
    public:
        TEST_METHOD(BackgroundDispatchRepeatRebindAndClear)
        {
            DWORD foregroundPid = 0;
            Assert::IsTrue(GetForegroundWindow() != nullptr);
            GetWindowThreadProcessId(GetForegroundWindow(), &foregroundPid);
            Assert::AreNotEqual(GetCurrentProcessId(), foregroundPid,
                L"Run this test with another application in the foreground.");
            std::counting_semaphore<16> fired{ 0 };
            std::atomic<int> lastAction{ -1 };
            Hotkeys hotkeys;
            hotkeys.SetHandler([&](int action) { lastAction = action; fired.release(); });
            Assert::IsTrue(hotkeys.BindAction(1, Key::Code::F23, Mod::Null));
            KeyEvent(VK_F23, false);
            const auto first = fired.try_acquire_for(2s);
            KeyEvent(VK_F23, false);
            const auto repeat = fired.try_acquire_for(150ms);
            KeyEvent(VK_F23, true);
            Assert::IsTrue(first, L"The global hotkey must fire while another app is foreground.");
            Assert::IsFalse(repeat, L"Holding a key must not repeat the action.");
            Assert::AreEqual(1, lastAction.load());

            Assert::IsTrue(hotkeys.BindAction(1, Key::Code::F24, Mod::Null));
            KeyEvent(VK_F23, false);
            KeyEvent(VK_F23, true);
            Assert::IsFalse(fired.try_acquire_for(150ms));
            KeyEvent(VK_F24, false);
            KeyEvent(VK_F24, true);
            Assert::IsTrue(fired.try_acquire_for(2s));
            Assert::IsTrue(hotkeys.ClearAction(1));
            KeyEvent(VK_F24, false);
            KeyEvent(VK_F24, true);
            Assert::IsFalse(fired.try_acquire_for(150ms));
        }

        TEST_METHOD(ConflictPreservesBindingAndShutdownReleasesShortcut)
        {
            Assert::IsTrue(RegisterHotKey(nullptr, 0x6001, MOD_NOREPEAT, VK_F24) != FALSE);
            struct RegistrationGuard
            {
                ~RegistrationGuard() { UnregisterHotKey(nullptr, 0x6001); }
            } guard;
            {
                Hotkeys hotkeys;
                Assert::IsTrue(hotkeys.BindAction(1, Key::Code::F23, Mod::Null));
                Assert::IsFalse(hotkeys.BindAction(1, Key::Code::F24, Mod::Null));
                // The original shortcut remains owned after the failed rebind.
                Assert::IsFalse(RegisterHotKey(nullptr, 0x6002, 0, VK_F23) != FALSE);
            }
            Assert::IsTrue(RegisterHotKey(nullptr, 0x6002, 0, VK_F23) != FALSE);
            UnregisterHotKey(nullptr, 0x6002);
            // A second listener can start after the first is destroyed.
            Hotkeys hotkeys;
            Assert::IsTrue(hotkeys.BindAction(1, Key::Code::F23, Mod::Null));
        }

        TEST_METHOD(RightModifiersAndCombinationReassignment)
        {
            std::counting_semaphore<16> fired{ 0 };
            std::atomic<int> lastAction{ -1 };
            Hotkeys hotkeys;
            hotkeys.SetHandler([&](int action) { lastAction = action; fired.release(); });
            const auto mods = Mod::Ctrl | Mod::Shift;
            Assert::IsTrue(hotkeys.BindAction(1, Key::Code::F23, mods));
            Assert::IsTrue(hotkeys.BindAction(1, Key::Code::F23, mods));
            Assert::IsTrue(hotkeys.BindAction(2, Key::Code::F24, mods));
            Assert::IsTrue(hotkeys.BindAction(2, Key::Code::F23, mods));
            KeyEvent(VK_F23, false);
            KeyEvent(VK_F23, true);
            Assert::IsFalse(fired.try_acquire_for(150ms));
            KeyEvent(VK_RCONTROL, false);
            KeyEvent(VK_RSHIFT, false);
            KeyEvent(VK_F23, false);
            KeyEvent(VK_F23, true);
            const auto received = fired.try_acquire_for(2s);
            KeyEvent(VK_RSHIFT, true);
            KeyEvent(VK_RCONTROL, true);
            Assert::IsTrue(received);
            Assert::AreEqual(2, lastAction.load());
            Assert::IsFalse(fired.try_acquire_for(150ms));
        }
    };
}
