#include <float.h>
#include <inttypes.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <unistd.h>
#include <uv.h>

#define DEBUG_REFCOUNT (false)

#include "bytearray.h"
#include "types.h"

extern void effektMain();

int program_argc;
char** program_argv;

struct Pos c_get_arg(uint64_t idx) {
    if(idx < (uint64_t)program_argc) {
        return c_bytearray_from_nullterminated_string(program_argv[idx]);
    } else {
        return c_bytearray_new(0);
    }
}
uint64_t c_get_argc() {
    return program_argc;
}

int main(int argc, char *argv[]) {
    program_argc = argc;
    program_argv = argv;
    effektMain();
    uv_loop_t *loop = uv_default_loop();
    uv_run(loop, UV_RUN_DEFAULT);
    return uv_loop_close(loop);
}
