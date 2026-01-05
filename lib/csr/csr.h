#pragma once

#ifndef CSR_EMBED
#include "CSRConfig.hpp"
#else
#define TOOLCHAIN_MODE
#include <stdlib.h>
#endif

#ifndef TOOLCHAIN_MODE
#include "CLIParser.hpp"
#include <iostream>
int csrmain(int argc, char** args);

void PrintHeader() noexcept;
void PrintHelp(const CLIParser::Flags& flags) noexcept;

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
    typedef enum CSRBuildFlags {
        CSR_BuildFlags_EnableJIT = 0b00001,
        CSR_BuildFlags_BuildFlat = 0b00010,
        CSR_BuildFlags_BuildStructured = 0b00100
    } CSRBuildFlags;

    typedef struct CSRInfo {
        const char* const versionString;
        const char* const description;
        int versionMajor;
        int versionMinor;
        int versionPatch;
        char flags;
    } CSRInfo;

    typedef enum CSRErrorCode {
        CSR_Error_Ok = 0,
        CSR_Error_Bad,
        CSR_Error_UnhandledException,
        CSR_Error_ROMAccessError,
        CSR_Error_RAMAccessError,
        CSR_Error_SourceFileNotFound,
        CSR_Error_UnsupportedFileType,
        CSR_Error_HeapOverflow,
        CSR_Error_StackOverflow,
        CSR_Error_NoSourceFile,
        CSR_Error_InvalidSpecifier,
        CSR_Error_FileIOError,
        CSR_Error_MessageSendError,
        CSR_Error_IndexOutOfBounds,
        CSR_Error_InvalidInstruction,
        CSR_Error_MessageReceiveError,
        CSR_Error_MessageDispatchError,
        CSR_Error_MemoryOverflow,
        CSR_Error_NotImplemented,
        CSR_Error_FragmentedHeap,
        CSR_Error_StackUnderflow,
        CSR_Error_DuplicateSysBind,
        CSR_Error_InvalidKey,
        CSR_Error_DLLoadError,
        CSR_Error_DLSymbolError,
        CSR_Error_VMError,
        CSR_Error_DLInitError,
        CSR_Error_DoubleFree,
        CSR_Error_Shutdown,
        CSR_Error_ProcessInterrupt,
        CSR_Error_IOError,
        CSR_Error_NativeCallError,
        CSR_Error_JITError,
        CSR_Error_CLIParseError,
        CSR_Error_DivideByZero,
    } CSRErrorCode;

    typedef enum CSRSettingFlags {
        CSR_Settings_Default = 0,
        CSR_Settings_Silent = 0b0001
    } CSRSettingFlags;

    typedef const char* Str;
    typedef struct StrVector {
        Str* elements;
        size_t top;
        size_t size;
    } StrVector;

    typedef struct CSRVMContext { void* ptr; } CSRVMContext;

    // API Funcs
    CSRInfo CSRGetBuildInfo();
    void CSRSettings(CSRSettingFlags settings);

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

    // VMContext
    CSRVMContext CreateVMContext(int unsafe, int jit, const Str executable);
    CSRErrorCode RunVM(CSRVMContext context);
    void DeleteVMContext(CSRVMContext context);
#ifdef __cplusplus
#ifndef CSR_EMBED
namespace CSR
{
    CSRSettingFlags Settings();
}
#endif
}
#endif
#endif
