#pragma once

#include <string>

#include "JASMConfig.hpp"

#define Is8Bit(reg) (reg >= Enumc(ModeFlags::RegisterModeFlags::al) && reg <= Enumc(ModeFlags::RegisterModeFlags::flg))
#define IsSysReg(reg) (reg >= Enumc(ModeFlags::RegisterModeFlags::pc) && reg <= Enumc(ModeFlags::RegisterModeFlags::bp))
#define Enumc(enum) static_cast<uchar_t>(enum)

namespace ModeFlags
{
    inline constexpr uchar_t NoMode = 0x00;

    enum class NumericModeFlags : uchar_t
    {
        Int = 1,
        Float,
        Byte,
        UInt,
        UByte,
    };

    enum class MemoryModeFlags : uchar_t
    {
        Stack = 6,
        Heap,
    };

    enum class RegisterModeFlags : uchar_t
    {
        /* 32-bit */ eax = 8, ebx, ecx, edx, esi, edi,

        /* 32-bit system */ pc, sp, bp,

        /* 8-bit */ al, bl, cl, dl,

        /* 8-bit system */ flg,
    };

    enum class CompareModeFlags : uchar_t
    {
        les = 21, gre, equ, leq, geq, neq,
    };

    uchar_t GetModeFlag(const std::string& identifier, uchar_t start, uchar_t end, bool throws = false);
}
