#ifndef __JASM__HEADER__FILE__INCLUDING__C__BINDS__
#define __JASM__HEADER__FILE__INCLUDING__C__BINDS__

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
#include "stdlib.h"
#endif

#ifndef TOOLCHAIN_MODE
#include "CLIParser.hpp"

int jasmmain(int argc, char** args);

void PrintHeader() noexcept;
void PrintHelp(const CLIParser::Flags& flags) noexcept;
void SetStdout(const CLIParser::Flags& flags);

CLIParser::Flags SetUpCLI(char** args, int argc);
#else
#include <stddef.h>
#include <stdlib.h>

//
// C API Here
//
#ifdef __cplusplus
extern "C"
{
#endif
    typedef struct JASMInfo {
        const char* const versionString;
        const char* const description;
        int versionMajor;
        int versionMinor;
        int versionPatch;
        int pipelinesAvailable;
    } JASMInfo;

    typedef enum LibTypes {
        Static = 0,
        Shared = 1,
        Executable = 2
    } LibTypes;

    typedef enum ErrorTypes {
        Ok = 0,
        AssemblerError = 1,
        LinkerError = 2
    } ErrorTypes;

    typedef const char* Str;
    typedef struct StrVector {
        Str* elements;
        size_t top;
        size_t size;
    } StrVector;

    typedef struct JASMAssemblyContext { void* ptr; } JASMAssemblyContext;
    typedef struct JASMByteAssembler { void* ptr; } JASMByteAssembler;
    typedef struct JASMByteLinker { void* ptr; } JASMByteLinker;
    typedef struct JASMAssemblyInfoCollection { void* ptr; } JASMAssemblyInfoCollection;

    // API Funcs
    JASMInfo JASMGetBuildInfo();

    // Helper Functions
    static StrVector StrVectorCreate(size_t size)
    {
        Str* data = (Str*)malloc(size);
        return (StrVector){data, 0, size};
    }

    static void StrVectorDelete(StrVector vector)
    { free((void*)vector.elements); }

    static int StrVectorPush(StrVector vector, Str str)
    {
        if (vector.top >= vector.size)
            return 0;
        vector.elements[vector.top++] = str;
        return 1;
    }

    size_t HashString(Str str);

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
    ErrorTypes ByteLink(JASMByteLinker linker, JASMAssemblyInfoCollection objects, JASMAssemblyContext context);
#ifdef __cplusplus
}
#endif
#endif
#endif
