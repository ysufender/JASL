# JASL - Just A Scripting Language

> STATUS: IL generation finished. Polishing the compiler.  
> UPCOMING: Quality-of-life tweaks, bugfixes, perhaps "extern" functions  

JASL is a statically typed, low-level(!) and byte-compiled scripting language backed by JASM and CSR. JASL is
written in the [Effekt research language](https://effekt-lang.org/) and is compiled into JASM IL. The rest is done
by the [JASM Assembler and Linker](https://github.com/ysufender/JASM) and [CSR](https://github.com/ysufender/CSR).

~Since it is backed by JASM and CSR, JASL can call C ABI compatible functions with a specific signature (given in 
CSR documentation). So as long as you provide a clean wrapper for JASL to call, native calls are completely possible.~

Since CSR is havign problems with native callbacks, they are not possible yet. Call it WIP.

JASL looks and feels like Zig/C and allows you to use raw pointers, pointer arithmetic and unsafe actions. However
these are all done on VM level, the pointers are not "real" pointers so it's all safe to mess up. CSR is completely
sandboxed (not if on JIT (perhaps depends on CSR implementation)) and (hopefully) crash-free.

JASL is semi-object oriented, I think. Custom types (called "layouts") can be defined and "methods" can be attached to them.
However there is no inheritance, interfaces etc. so you'll have to create vtables manually if you want to mimic such behaviour.

Here's a simple "Hello World" program written in JASL:

```rust
module main

include "io"

fn main() -> void {
    io::println("Hello World");
}
```

If you want more complicated examples, you can check the JASL stdlib under `lib/jasl/`. It is still WIP, simple but complex enough.

## Quickstart

### Building From the Source

The cleanest way to get JASL is to build it from source, currently Windows/Mac builds
are unsupported and/or untested. The compilation speed depends on the performance
of the [Effekt](https://effekt-lang.org/) compiler, the language that JASL compiler is written in.

#### Prerequisites

- Builds are only tested on a Linux machine, Windows/Mac builds/crossbuilds are not supported.
- Ninja Makefiles 1.11+
- Effekt 0.58+
- C++20 and C17 compatible compilers (I used gcc/g++, you might need to tweak the ninja files otherwise)
- LLVM 15

The Effekt version must be exactly the same for a smooth experience. Since it is a research language I can't promise for any kind
of backwards compatibility.

#### Building

```bash
git clone https://github.com/ysufender/JASL
ninja -f release.ninja
```

OR

```bash
git clone https://github.com/ysufender/JASL
ninja -f debug.ninja
```

The resulting binaries will be written to `$SOURCEDIR/build/<configuration>/`

#### Setting Up the Environment

One of the resulting binaries is `jasl_install`, which is a compile-time hardcoded executable for managing
`jaslc` executable and stdlib paths. The compiler relies on `jasl_install` to detect the stdlib path, and will error out
if it can't find it on the path.

Here is the helper text of the current `jasl_install`:

```
JASL Installation Manager 0.1.0

Usage:
        jasl_install [install <symlink_dir>|uninstall <symlink_dir>|--version|--stdlib]
```

`install` will create symlinks for `jaslc` and `jasl_install` under the given directory
`uninstall` will remove the symlinks from the given directory
`version` will print the JASL version as usual
`stdlib` will print the JASL stdlib path

You can use `install` to create symlinks under any directory that is included in path, such as
`/usr/local/bin` or something, then use `jaslc` and `jasl_install` freely.

### Basic CLI Usage

Here is the helper text from the current version of JASL:

```
The JASL Compiler
        Version: 0.1.0-debug
        Usage:
        jaslc <input_file> [flags]
                Flags:
                --help                  : print this help message

                --typecheck             : do not compile or assemble, typecheck only
                --compile               : do not assemble, generate IL only

                --static                : build a static library
                --dynamic               : build a dynamic library

                --release [jit = false] : build in release mode, with optional jit support. defaults to false.

                --output <file_name>    : set output file name
                --working <file_name>   : set working directory

                --check-nullptr         : enable nullptr check on every pointer operation

                --include <dir_path>    : include the given directory as a search path
```

### Language and Project References

See [this](docs/LANGUAGE_REFERENCE.md) for language reference and [that](docs/COMPILER_REFERENCE.md) for project reference.
