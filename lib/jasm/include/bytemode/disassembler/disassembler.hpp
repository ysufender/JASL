#pragma once

#include "JASMConfig.hpp"

#ifdef TOOLCHAIN_MODE
#include "assemblycontext.hpp"
#endif

namespace ByteAssembler
{
    class ByteDisassembler
    {
        public:
#ifndef TOOLCHAIN_MODE
            ByteDisassembler() = default; 
#else
            ByteDisassembler(const AssemblyContext&& context);
#endif

            void Disassemble();

        private:
#ifdef TOOLCHAIN_MODE
            const AssemblyContext context;
#endif
    };
}

