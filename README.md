# JASL - Just A Scripting Language

> STATUS: Writing the parser [AST Generation]
> UPCOMING: JASM IL generation from AST

JASL is a statically typed, low-level(!) and byte-compiled scripting language backed by JASM and CSR. JASL is
written in the [Effekt research language](https://effekt-lang.org/) and is compiled into JASM IL. The rest is done
by the [JASM Assembler and Linker](https://github.com/ysufender/JASM) and [CSR](https://github.com/ysufender/CSR).

Since it is backed by JASM and CSR, JASL can call C ABI compatible functions with a specific signature (given in 
CSR documentation). So as long as you provide a clean wrapper for JASL to call, native calls are completely possible.

JASL looks and feels like Zig/C and allows you to use raw pointers, pointer arithmetic and unsafe actions. However
these are all done on VM level, the pointers are not "real" pointers so it's all safe to mess up. CSR is completely
sandboxed (not if on JIT (perhaps depends on CSR implementation)) and (hopefully) crash-free.

JASL is NOT object oriented, I think. But you can define layouts. Like C structs but different because you can directly
define "methods" for them. See below:

```rust
// every file is a module and must start with a module directive
module main

include "math" // includes 'math.jasl' from the search path
// Circular dependencies are allowed, the linker handles them.

// Wrapper layout means everything inside this layout is
// hidden from outside. It is, in fact, a wrapper for what's inside.
wrapper layout String {
    data: void*;

    //pub someField: u32; // [PARSER ERROR] main.jasl at 9:5: Public fields in wrapper layouts are not allowed. 
};

// Oh yeah, multiple returns. This is not a tuple mind you.
pub fn String::unpack() -> (u32, i8*) {
    // all variables are immutable by default. Use 'mut' after 'let' to make them mutable.
    let size: u32 = this.data.ptrcast(u32).deref();
    let data: i8* = this.data.ptrcast(i8).offset(sizeof(u32))); // no overloaded arithmetic operators
    return { size, data }; // braces are expression lists, used to return multiple values
}

fn main() -> void {
    /*
        Block comment
        /* And nested comments are allowed. */
    */
    let someStr: String = "Hello World";

    let (size: u32, data: i8*) = someStr.unpack(); // this is just syntax sugar
                              // String::unpack(someStr);

    // ':=' is not a token, it's just ':' and '='
    let inferredFromRhs := math::abs(-12);
    let (multiple:, infer:) = { 5u32, 6i8 };
}
```

## Quickstart

### Installation

You can either grab the compiled binaries from the release section (if there is any), or build JASL from source. I recommend
building from source since it's pretty easy.

#### Building From The Source

##### Prerequisites

- Ninja Makefiles 1.11+
- Effekt 0.49+

The Effekt version must be exactly the same for a smooth experience. Since it is a research language I can't promise for any kind
of backwards compatibility.

##### Building

Just run `ninja -f <configuration>.ninja` and the final executable `jasl(.exe optionally)` will be written to `$SOURCE_DIR/build/$CONFIGURATION/`

### Basic CLI Usage

Here is the helper text from the current version of JASL:

```
The JASL Compiler
        Version: 0.0.1
        Usage:
        jasl <input_file> [flags]
                Flags:
                --help                  : print this help message

                --typecheck             : do not compile or assemble, typecheck only
                --compile               : do not assemble, generate IL only

                --static                : build a static library
                --dynamic               : build a dynamic library

                --release [jit = false] : build in release mode, with optional jit support. defaults to false.

                --output <file_name>    : set output file name
                --working <file_name>   : set working directory
```
