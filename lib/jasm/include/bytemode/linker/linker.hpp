#pragma once

#include "JASMConfig.hpp"
#include "bytemode/assembler/assembler.hpp"


namespace ByteLinker
{
    // I don't really know why this class is not fully static.
    // I don't even know why I made a class at the first place.
    // Bear with me for the time being.
    class ByteLinker
    {
        public:
            ByteLinker() = default;
            void Link(
                const ByteAssembler::AssemblyInfoCollection& objects
#ifdef TOOLCHAIN_MODE
                , const AssemblyContext& context
#endif
            );

#ifdef TOOLCHAIN_MODE
        private:
#endif
            void LinkSingle(const ByteAssembler::AssemblyInfoCollection& objects);
            void LinkLib(const ByteAssembler::AssemblyInfoCollection& objects);
            void LinkExe(const ByteAssembler::AssemblyInfoCollection& objects);
    };
}
