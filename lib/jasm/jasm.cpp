/*
#include <float.h>
#include <stdio.h>
*/

#include <filesystem>
#include <limits>
#include <string_view>
#include <vector>

#include "assemblycontext.hpp"
#include "bytemode/assembler/assembler.hpp"
#include "bytemode/linker/linker.hpp"
#include "system.hpp"

extern "C" {

#include "types.h"
#include "bytearray.h"
/*
#define JASM_EMBED
#include "jasm.h"
*/

    using Str = std::string_view;

    struct Pos file_exists(String _str)
    {
        Str str { c_bytearray_into_nullterminated_string(_str) };
        if (std::filesystem::exists(str))
            return BooleanTrue;
        return BooleanFalse;
    }

    Double string_to_float(String _str)
    {
        Str str { c_bytearray_into_nullterminated_string(_str) };
        double val { std::stod(str.data()) };

        erasePositive(_str);
        return val;
    }

    Int random_range(Int min, Int max) {
        return rand() % (max - min + 1) + min;
    }

    struct Pos assemble_il_call(struct Pos filePath)
    {
        Str fileName { c_bytearray_into_nullterminated_string(filePath) };

        if (!std::filesystem::exists("build/"))
            std::filesystem::create_directories("build/");

        AssemblyContext context {
            true,
            false, 
            false,
            "build/out.jef", 
            LibTypeEnum::Executable,
            std::filesystem::path(""),
            std::vector<std::string>{fileName.data()},
            std::vector<std::string>{},
            true,
            false 
        };

        ByteAssembler::ByteAssembler basm {context};

        ByteAssembler::AssemblyInfoCollection infos;
        try {
            infos = basm.Assemble();
        } catch (const JASMException& e) {
            std::cerr << "An error occured while assembling the generated IL. Refer to the output below.\n";
            std::cerr << e;
            return BooleanFalse;
        }

        try {
            ByteLinker::ByteLinker linker;
            linker.Link(infos, context);
        } catch (const JASMException& e) {
            std::cerr << "An error occured while linking the assembled IL. Refer to the output below.\n";
            std::cerr << e;
            return BooleanFalse;
        }

        erasePositive(filePath);
        return BooleanTrue;
    }
}
