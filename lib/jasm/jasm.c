#include "../effekt/types.h"
#include "../effekt/bytearray.h"

#define JASM_EMBED
#include "jasm.h"

#include "stdlib.h"
#include "float.h"

Double string_to_float(struct Pos _str)
{
    Str str = (char*)c_bytearray_data(_str);
    char* end;
    float val = strtof(str, &end);

    erasePositive(_str);
    return (end == str) ? DBL_MAX : val;
}

Int random_range(Int min, Int max) {
    srand(time(NULL));
    return rand() % (max - min + 1) + min;
}

void assemble_il_call(struct Pos filePath)
{
    Str fileName = (char*)c_bytearray_data(filePath);
    Str inFiles[] = { fileName };
    StrVector ins = { inFiles, 1 };
    StrVector libs = { NULL, 0 };

    JASMAssemblyContext context = CreateAssemblyContext(0, 0, 0, "build/out.jef", Executable, "", ins, libs, 0, 0);
    JASMByteAssembler assembler = CreateByteAssembler(context);
    JASMAssemblyInfoCollection objects = ByteAssemble(assembler);
    JASMByteLinker linker = CreateByteLinker();
    ByteLink(linker, objects, context);

    DeleteByteLinker(linker);
    DeleteByteAssembler(assembler);
    DeleteAssemblyContext(context);

    erasePositive(filePath);
}
