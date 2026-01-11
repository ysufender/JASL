#pragma once

#include <string>
#include <iostream>

#include "system.hpp"

#define OStreamPos(stream, varName) \
    std::streamoff varName { stream.tellp() }; \
    if (varName == -1) LOGE(System::LogLevel::High, "Couldn't get the position of stream.");

#define IStreamPos(stream, varName) \
    std::streamoff varName { stream.tellg() }; \
    if (varName == -1) LOGE(System::LogLevel::High, "Couldn't get the position of stream.");

namespace Extensions::Stream
{
    std::string Tokenize(std::istream& inputStream);
    void ClearMacros();
    void AddMacro(std::string_view name, std::string_view expansion);
    void ProcessMacroFile(const std::string_view file);
}
