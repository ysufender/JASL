#pragma once

// This file includes C API for JASM
// The capabilities of C API might be lower
// than the original.
//
// NOTE: C API is only available when the project
// is built in TOOLCHAIN_MODE
//
// you can remove JASMConfig.hpp and just #define TOOLCHAIN_MODE

#ifndef JASM_EMBED
#include "JASMConfig.hpp"
#else
#define TOOLCHAIN_MODE
#endif

#ifndef TOOLCHAIN_MODE
#include "CLIParser.hpp"

int jasmmain(int argc, char** args);

void PrintHeader() noexcept;
void PrintHelp(const CLIParser::Flags& flags) noexcept;
void SetStdout(const CLIParser::Flags& flags);

CLIParser::Flags SetUpCLI(char** args, int argc);
#else

//
// C API Here
//
#ifdef __cplusplus
extern "C"
{
    namespace JASM
    {
#endif
        typedef enum {
            Static = 0,
            Shared = 1,
            Executable = 2
        } LibTypes;

        typedef const char* Str;
        typedef struct {
            const Str* elements;
            int size;
        } StrVector;

        typedef struct { void* ptr; } JASMAssemblyContext;
        typedef struct { void* ptr; } JASMByteAssembler;
        typedef struct { void* ptr; } JASMByteLinker;
        typedef struct { void* ptr; } JASMAssemblyInfoCollection;

        // AssemblyContext
        JASMAssemblyContext CreateAssemblyContext(
            int silent,
            int single, 
            int pipelines,
            const Str out, 
            LibTypes libT, 
            const Str workingDir,
            StrVector in,
            StrVector libs,
            int storeSymbols,
            int storeName
        );
        void DeleteAssemblyContext(JASMAssemblyContext context);

        // ByteAssembler
        JASMByteAssembler CreateByteAssembler(JASMAssemblyContext context);
        void DeleteByteAssembler(JASMByteAssembler assembler);
        JASMAssemblyInfoCollection ByteAssemble(JASMByteAssembler assembler);

        // ByteLinker
        JASMByteLinker CreateByteLinker();
        void DeleteByteLinker(JASMByteLinker linker);
        void ByteLink(JASMByteLinker linker, JASMAssemblyInfoCollection objects, JASMAssemblyContext context);
#ifdef __cplusplus
    }
}
#endif
#endif
