/*
#include <float.h>
#include <stdio.h>
*/

#include <filesystem>
#include <limits>
#include <string_view>
#include <vector>
#include <fstream>

#include "JASMConfig.hpp"
#include "assemblycontext.hpp"
#include "bytemode/assembler/assembler.hpp"
#include "bytemode/linker/linker.hpp"
#include "system.hpp"

extern "C" {

#include "types.h"
#include "bytearray.h"

#include "sys/types.h"
#include "sys/wait.h"

/*
#define JASM_EMBED
#include "jasm.h"
*/

    using Str = std::string_view;

    String stdlib_path()
    {
        int pipefd[2];
        if (pipe(pipefd) != 0) return (String){0, NULL};

        pid_t pid = fork();
        if (pid < 0)
            return (String){0, NULL};

        if (pid == 0)
        {
            close(pipefd[0]);
            dup2(pipefd[1], STDOUT_FILENO);
            close(pipefd[1]);

            execlp("jasl_install", "jasl_install", "--stdlib", NULL);
            std::cerr << "Couldn't find 'jasl_install' on path, please install jasl toolchain completely first.\n";
            _exit(127);
        }

        close(pipefd[1]);

        uint64_t capacity = 64;
        uint64_t length   = 0;
        char* buffer      = static_cast<char*>(std::malloc(capacity));
        if (!buffer) return (String){0, NULL};

        int c;
        while ((c = read(pipefd[0], &buffer[length], 1)) == 1)
        {
            length++;
            if (length == capacity)
            {
                capacity *= 2;
                char* newbuf = static_cast<char*>(std::realloc(buffer, capacity));
                if (!newbuf)
                {
                    free(buffer);
                    return (String){0, NULL};
                }
                buffer = newbuf;
            }
        }

        close(pipefd[0]);
        waitpid(pid, NULL, 0);

        while (length > 0 && (buffer[length - 1] == '\n' || buffer[length - 1] == '\r'))
            length--;

        String result = c_bytearray_construct(length, (const uint8_t*)buffer);
        free(buffer);
        return result;
    }

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

    static AssemblyContext context { DefaultContext };
    void create_assembly_context(String filePath)
    {
        Str fileName { c_bytearray_into_nullterminated_string(filePath) };

        if (!std::filesystem::exists("build/"))
            std::filesystem::create_directories("build/");

        context = {
            true,
            false, 
            false,
            "build/out.jef", 
            LibTypeEnum::Executable,
            std::filesystem::path(""),
            std::vector<std::string>{fileName.data()},
            std::vector<std::string>{},
            true,
            true
        };
    }

    struct Pos assemble_il_call(struct Pos filePath)
    {
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

    void read_lib(String filePath)
    {
        Str fileName { c_bytearray_into_nullterminated_string(filePath) };
        std::ifstream stream { fileName.data(), std::ios::in };

        ByteAssembler::AssemblyInfo info { fileName.data(), ByteAssembler::AssemblyFlags::Static, context };
        info.Deserialize(stream);
    }
}
