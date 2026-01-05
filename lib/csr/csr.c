#include "../effekt/types.h"
#include "../effekt/bytearray.h"

#define CSR_EMBED
#include "csr.h"

int run_bytecode(String _str)
{
    Str fileName = (char*)c_bytearray_data(_str);

    CSRSettings(CSR_Settings_Default);
    CSRVMContext vm = CreateVMContext(0, 0, fileName);
    CSRErrorCode code = RunVM(vm);

    DeleteVMContext(vm);
    return (int)code;
}
