# JASL - Just A Scripting Language

JASL is a statically typed, low-level(!) and byte-compiled scripting language backed by JASM and CSR. JASL is
written in the [Effekt research language](https://effekt-lang.org/) and is compiled into JASM IL. The rest is done
by the [JASM Assembler and Linker](https://github.com/ysufender/JASM) and [CSR](https://github.com/ysufender/CSR).

Since it is backed by JASM and CSR, JASL can call C ABI compatible functions with a specific signature (given in 
CSR documentation). So as long as you provide a clean wrapper for JASL to call, native calls are completely possible.

JASL looks and feels like Zig/C and allows you to use raw pointers, pointer arithmetic and unsafe actions. However
these are all done on VM level, the pointers are not "real" pointers so it's all safe to mess up. CSR is completely
sandboxed (not if on JIT) and (hopefully) crash-free.

JASL is NOT object oriented, I think. But you can define layouts. Like C structs but different because you can directly
define "methods" for them. See below:

```zig
wrapper layout String {
    data: ptr;      
};

# Oh yeah, multiple returns. This is not a tuple mind you. #
pub fn String::unpack() -> (u32, i8*) {
    let size: u32 = ptrcast(u32, this.data).get(); # no '->' or ambiguous '.' #
    let data: i8* = ptrcast(i8, this.data.offset(sizeof(u32))); # no overloaded arithmetic operators #
    return size, data;
}

pub fn main() -> i32 {
    # Oh and even though there is type inference, you have to write the type
      Sorry not sorry. #
    let someStr: String = "Hello World";

    let size: u32, data: i8* = someStr.unpack(); # this is just syntax sugar #
                             # String::unpack(someStr); #
    return 0;
}
```

## Quickstart

### Installation

You can either grab the compiled binaries from the release section (if there is any), or build JASL from source. I recommend
building from source since it's pretty easy.

#### Building From The Source

##### Prerequisites

- Ninja Makefiles 1.11+
- Effekt 0.49

The Effekt version must be exactly the same for a smooth experience. Since it is a research language I can't promise for any kind
of backwards compatibility.

##### Building

Just run `ninja` and the final executable `jasl(.exe optionally)` will be written to `$SOURCE_DIR/build/`

### Basic CLI Usage

Here is the helper text from the current version of JASL:

```

```

### JASL Documentation 

See the [docs](docs/DOCUMENTATION.md).

## Footnotes

The licenses, readmes and citations for every library used in this project, lies within its own directory
under `lib`.
