#include <float.h>
#include <stdio.h>

#include "../effekt/types.h"
#include "../effekt/bytearray.h"

#define JASM_EMBED
#include "jasm.h"


Double string_to_float(String _str)
{
    const char* str = (char*)c_bytearray_data(_str);
    char* end;
    float val = strtof(str, &end);

    erasePositive(_str);
    return (end == str) ? DBL_MAX : val;
}

Int random_range(Int min, Int max) {
    return rand() % (max - min + 1) + min;
}

struct Pos assemble_il_call(struct Pos filePath)
{
    Str fileName = (char*)c_bytearray_data(filePath);
    StrVector ins = StrVectorCreate(1);
    StrVector libs = StrVectorCreate(0);
    StrVectorPush(ins, fileName);

    JASMAssemblyContext context = CreateAssemblyContext(0, 0, 0, "build/out.jef", Executable, "", ins, libs, 0, 0);
    JASMByteAssembler assembler = CreateByteAssembler(context);
    JASMAssemblyInfoCollection objects = ByteAssemble(assembler);
    JASMByteLinker linker = CreateByteLinker();

    ErrorTypes err = ByteLink(linker, objects, context);
    switch (err) {
        case AssemblerError:
            fprintf(stderr, "An error occured while assembling the generated IL. Refer to the output.\n");
            return BooleanFalse;
        case LinkerError:
            fprintf(stderr, "An error occured while resolving the symbols. Refer to the output.\n");
            return BooleanFalse;
        default:
            break;
    }

    DeleteByteLinker(linker);
    DeleteByteAssembler(assembler);
    DeleteAssemblyContext(context);
    StrVectorDelete(ins);
    StrVectorDelete(libs);

    erasePositive(filePath);
    return BooleanTrue;
}
