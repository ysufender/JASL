#pragma once

#include <cstdint>

#define JASM_VERSION "@JASM_VERSION@"
#define JASM_VERSION_MAJOR @JASM_VERSION_MAJOR@
#define JASM_VERSION_MINOR @JASM_VERSION_MINOR@
#define JASM_VERSION_PATCH @JASM_VERSION_PATCH@
#define JASM_DESCRIPTION "@JASM_DESCRIPTION@"

#define TOOLCHAIN_MODE

using systembit_t = uint32_t;
using uchar_t = uint8_t;

#define JASM_ENDL "__JASM__ENDL__"
#define JASM_EOF "__JASM__EOF__"
