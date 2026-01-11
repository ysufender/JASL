#pragma once

#include <filesystem>
#include <ios>
#include <iostream>
#include <stdexcept>
#include <string_view>

#include "assemblycontext.hpp"
#include "extensions/stringextensions.hpp"

#ifndef TOOLCHAIN_MODE
#include "CLIParser.hpp"
#endif

#ifndef NDEBUG
    #define LOGD(...) System::LogInternal(Extensions::String::Concat({__VA_ARGS__}), __FILE__, __LINE__)
#else
    #define LOGD(...)
#endif

#define LOG(...) System::Log(Extensions::String::Concat({__VA_ARGS__}))
#define LOGW(...) System::LogWarning(Extensions::String::Concat({__VA_ARGS__}), __FILE__, __LINE__)
#define LOGE(level, ...) System::LogError(Extensions::String::Concat({__VA_ARGS__}), level, __FILE__, __LINE__)

#define JASM_ERR(message) JASMException { message, __FILE__, __LINE__ };

struct System
{
#ifndef TOOLCHAIN_MODE
    static AssemblyContext& Context; 
#else
    static AssemblyContext* Context;
#endif

    enum class LogLevel
    {
        Normal,
        Low,
        Medium,
        High
    };

    static void Log(std::string_view message);
    static void LogInternal(std::string_view message, std::string_view file, int line);
    static void LogWarning(std::string_view message, std::string_view file, int line);
    static void LogError(std::string_view message, LogLevel level, std::string_view file, int line);

#ifndef TOOLCHAIN_MODE
    static void Setup(const CLIParser::Flags& flags, std::ostream& cout, std::ostream& cerr);
    static void Setup(const AssemblyContext&& context, std::ostream& cout, std::ostream& cerr);
    static void Setup(const AssemblyContext& context, std::ostream& cout, std::ostream& cerr);
#endif
    
    static std::ifstream OpenInFile(const std::filesystem::path& path, const std::ios::openmode mode = std::ios::binary);
    static std::ofstream OpenOutFile(const std::filesystem::path& path, const std::ios::openmode mode = std::ios::binary);
};

class JASMException : std::runtime_error
{
    private:
        int _line;
        std::string _file;
        std::string _message;

        std::string _fullStr;

    public:
        JASMException(std::string message, std::string file, int line);
        
        int GetLine() const;
        const std::string& GetFile() const;
        const std::string& GetMsg() const;

        const std::string& Stringify() const;

        friend std::ostream& operator<<(std::ostream& out, const JASMException& exc);
};
