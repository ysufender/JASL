# JASL Compiler Documentation

> Note: This is not a language reference, if you wish to learn the JASL itself
> (eg. the syntax, behaviour, features), see the [language reference](./LANGUAGE_REFERENCE.md)

## Introduction

The JASL compiler is a simple, two-pass compiler that targets the [JASM IL](https://github.com/ysufender/JASM).
The compiler does (as for now) no optimizations to the given source file, and does not support incremental builds.

The JASL compiler is mainly written in the [Effekt research language](https://effekt-lang.org/), and depends on LLVM 15
as a backend. The compiler source includes C and C++ files as well, for JASM IL backend calls and various operations
such as file IO etc.

## Table of Contents

<table>
<tr><td width=33% valign=top>

* [Compilation Model](#compilation-model)
    * [Compilation Phase Chart](#compilation-phase-chart)
* [Compilation Phases](#compilation-phases)
    * [Entry Phase](#entry-phase)
    * [Lexical Analysis](#lexical-analysis)
    * [Parser Phase](#parser-phase)
        * [Prepass](#prepass)
        * [Parse](#parse)
    * [IL Generation](#il-generation)

</td><td width=33% valign=top>

</td><td valign=top>

</td></tr>
<tr><td width=33% valign=top>

</td></tr>
</table>

## Compilation Model

JASL Compiler (will be addressed as JASLC from now on) is a non-linear (or semi-linear, I'm not sure), single threaded and phase-based two-pass compiler.
The compiler works recursively upon itself in the first pass, invoking the lexical analysis phase for every included file. We'll explain this in detail later.

There are mainly four phases, where one of them includes two sub-phases, resulting in a two-pass architecture. See the ["Compilation Phases"](#compilation-phases)
and the [compilation chart](#compilation-chart) below.

### Compilation Phase Chart

![Source not found](./compiler_flowchart.png "Compilation Phase Chart")

## Compilation Phases

There are four phases in compilation: Entry Phase, Lexical Analysis (or Lexer Phase), Parser Phase, and IL Generation. The Parser Phase consists of two
sub-phases: Prepass and Parse. This results in a two-pass compiler where Prepass sub-phase detects all used files, registers their lexer outputs to the compilation
context, and fills the global symbol table with function, layout, and global variable definitions.

### Entry Phase

The Entry Phase has two jobs: parsing the command line, setting up the compilation context. Below is the helper output from the current version of JASLC in debug build,
which lists all available command line flags and options:
 
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

After the parsing of the given command line structure, JASLC proceeds to detect the JASL stdlib path via the helper executable `jasl_install`, which
is expected to be on the PATH of your system. See the [README.md](../README.md#building-from-the-source) or the
[LANGUAGE_REFERENCE.md](./LANGUAGE_REFERENCE.md#building-from-the-source) for environment setting after a successful build.

On a successful execution of the `jasl_install` command, the compiler will append the JASL stdlib to the search path for inclusion.

Lastly, the backend context (namely [AssemblyContext](https://github.com/ysufender/JASM)) will be craeted and that will be the end of the
entry phase.

### Lexical Analysis

After the Entry Phase, the input file given will be passed to the Lexer. 
