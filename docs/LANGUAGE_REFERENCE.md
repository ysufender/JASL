# JASL Documentation

(See [this](./STDLIB_REFERENCE.md) for JASL stdlib documentation)

## Introduction

JASL is a statically typed, byte-compiled scripting language, designed to be what C is to
a real computer, to my custom VM.

It's similar to Zig and ultimately to C in overall feeling.

JASL is an extremely simple language, without any kind of bloat or insane features. It is small,
with a couple improvements (arguably) over C.

The JASL philosophy is: No hidden control flow, no hidden allocations, no hidden memory writes, and
no overcomplicated features. It is meant to be as simple as, if not simpler than, C.

Just like C, although the language offers little to no abstractions and higher-level features, you can
mimic them or build them from ground up using existing language features. Need interfaces? Write layouts
that mimic vtables to do so. In fact, the stdlib does that from time to time.

Technically, since the language is Turing Complete, it can do anything. But for now it is bound by the
capabilities of the VM it runs on. The [VM](https://github.com/ysufender/CSR) is still in the improvement phase.
Currently the FFI support using [libffi](https://github.com/libffi/libffi) is being implemented, once it is finished
JASL will be able to load dynamic libraries at runtime and call any C function from them with automatic type conversion
between C and VM RAM. Also the VM has the foundations of JIT (currently only hot-path detection) so once the VM completely
supports JIT, JASL will naturally be able to get JIT compiled.

JASL is built on top of my other personal project-complex that I call CSLB (Common Scripting Language Backend), it
includes an Assembler/Linker/Disassembler complex for the custom IL/Assembly Language for the VM architecture called
[JASM](https://github.com/ysufender/CSR) and a VM for the bytecode that I mentioned earlier.

## Installing JASL

If there are no prebuilt binaries in the release section of the [JASL repo](https://github.com/ysufender/JASL.git),
you have to build it from source. It is pretty easy, no worries.

### Building From the Source

The cleanest way to get JASL is to build it from source, currently Windows/Mac builds
are unsupported and/or untested. The compilation speed depends on the performance
of the [Effekt](https://effekt-lang.org/) compiler, the language that JASL compiler is written in.

#### Prerequisites

- Builds are only tested on a Linux machine, Windows/Mac builds/crossbuilds are not supported.
- Ninja Makefiles 1.11+
- Effekt 0.59
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

## Table of Contents

<table>
<tr><td width=33% valign=top>

* [Hello World](#hello-world)
* [Compiling Multiple Sources](#compiling-multiple-sources)
* [Comments](#comments)
* [Functions](#functions)
    * [Hoisting](#hoisting)
    * [Returning Multiple Values](#returning-multiple-values)
* [Symbol visibility](#symbol-visibility)
* [Variables](#variables)
    * [Mutable Variables](#mutable-variables)
    * [Variable Shadowing](#variable-shadowing)
* [JASL types](#jasl-types)
    * [Primitive types](#primitive-types)
    * [Numbers](#numbers)
    * [Arrays](#arrays)

</td><td width=33% valign=top>

* [Statements & expressions](#statements--expressions)
    * [If](#if)
    * [While Loop](#while-loop)
    * [Defer](#defer)
* [Layouts](#layouts)
    * [Heap Layouts](#heap-layouts)
    * [Access Modifiers](#access-modifiers)
    * [Anonymous Structs](#anonymous-structs)
    * [Mimicking OOP](#mimicking-oop)
* [UFCS](#ufcs)

</td><td valign=top>

* [Modules](#modules)
    * [Including Files](#including-files)

</td></tr>
<tr><td width=33% valign=top>

* [Memory management](#memory-management)
    * [Stack and Heap](#stack-and-heap)

</td><td width=33% valign=top>

* [Other JASL Features](#other-v-features)
    * [Inline assembly](#inline-assembly)
* [Underlying System](#underlying-system)
* [Appendices](#appendices)
    * [Keywords](#appendix-i-keywords)
    * [Operators](#appendix-ii-operators)
    * [EBNF Notation](#appendix-iii-ebnf-notation)

</td></tr>
</table>

## Hello World

```rust
module main

include "io"

fn main() -> void {
	io::println("hello world");
}
```

Save this snippet into a file named `hello.jasl`. Now do: `jaslc hello.jasl`.

> That is assuming you have successfully added `jaslc` and `jasl_install` executables to the PATH of your system,
or used `jasl_install` to create symlinks to somewhere on the PATH of your system.
> If you haven't yet, you have to type the path to JASL manually.

If everything is set up nicely, and no unexpected problems arise, this is the output you will see:

```
[ILGEN] Compiler exited without any errors.
[ILGEN] IL output written to path: build/out.jef.jasm
Making an assemble call...
Finished compiling.
Build files written to 'build/'.
```

You'll see your executable `out.jef` under `build/`.

To run it, you need the runtime, CSR. Its installation is not covered in this documentation, check out
[CSR](https://github.com/ysufender/CSR) to find out more.

Once you have the runtime, you can execute the output by doing `csr -e build/out.jef`.

```
>>> csr -e build/out.jef
Hello World
```

See `jaslc --help` for all supported commands.

From the example above, you can see that functions are declared with the `fn` keyword.
The return type is specified after the function name, after an arrow `->`.
In this case `main` doesn't return anything, so we return empty `void`.

Statements are terminated via a semicolon symbol ';', this might change in the future.
Trailing semicolons will simply be ignored.

As in many other languages, `main` is the entry point of your program. It must comply with a specific signature:
It must reside in the module `main`, must be private, and must be of signature `fn () -> void`.

`io::println` is a part of the stdlib, as you can see namespace resolution is mandatory.
It is essentially a wrapper around a VM callback to `CSR_Println` function.

JASL has some sort of UFCS, so you can do this too:

```rust
module main

include "io"

fn main() -> void {
    "Hello World".io::println();
}
```

> NOTE: For the sake of simplicity, I will omit the `include`, `module` directives and `main` function
> definition from time to time while giving examples.

## Compiling Multiple Sources

Suppose you have a folder with several `.jasl` files in it, where one of them
contains your `main()` function, and the other files have other helper
functions. They may be different modules, or a part of the main module,
perhaps they are in separate directories.

You don't need to pass each one of them to the compiler, or add each directory as
an include path. Assume this structure:

```
.
|_ script.jasl
|_ dir/
  |_ main.jasl
```

And let the file content be:

```rust
// script.jasl
module script

include "dir/main"

pub fn helperFunc() -> void {
    io::println("Hello From Helper");
    main::fnInMain();
}

// main.jasl
module main

include "io"
include "script"

fn main() -> void {
    io::println("Hello From Main");
    script::helperFunc();
}

pub fn fnInMain() -> void { /*Do Something*/ }
```

As you can see, the files have a little circular dependency. However this is not a problem, because
JASL is a two-pass compiler. Since `script::helperFunc` is used inside the `main` function, which is
parsed in the second pass, the program won't run into a circular dependency problem. You can compile
it by doing:

```
jaslc script.jasl
```

and the compiler will automatically detect that `dir/main.jasl` was used, process it and write the
build files as usual.

```
[ILGEN] Compiler exited without any errors.
[ILGEN] IL output written to path: build/out.jef.jasm
Making an assemble call...
Finished compiling.
Build files written to 'build/'.
```

This is the output you'll get, and if you run the program, you'll see:

```
>>> csr -e build/out.jef
Hello From Main
Hello From Helper
Hello From Fn In Main
```

Any unused files will simply be ignored.

## Comments

```rust
// This is a single line comment.
/*
This is a multiline comment.
   /* It can be nested. */
*/
```

## Functions

```rust
module main

include "io"

fn main() -> void {
	add(77, 33);
	sub(100, 50);
}

fn add(x: i32, y: i32) -> i32 {
	return x + y;
}

fn sub(x: i32, y: i32) -> i32 {
	return x - y;
}
```

Type variable signature syntax is `name : type`, the ':' is mandatory at all times,
in contexts where inference is possible, you may omit the 'type', however ':' must
still be present.

Just like in Go and C, functions cannot be overloaded.
This simplifies the code and improves maintainability and readability.

> NOTE: This might change in the future, if I implement generics.

### Hoisting

Functions can be used before their declaration:
`add` and `sub` are declared after `main`, but can still be called from `main`.
This is true for all declarations, except some cases where a type or identifier
must be known. This mostly gets rid of the need of header files and forward
declarations, however you must still be cautious with declaration order to
prevent the said "some cases".

### Returning Multiple Values

```rust
module main

fn foo() -> (i32, i32) {
	return { 2, 3 };
}

fn main() -> void {
    let (a:, b:) = foo();
}
```

Multiple returns are neither structs, nor tuples in JASL. They are a promise to the compiler, stating
"When I return, the top of the stack will look like this and you MUST bind them to something". So
you can't discard returns, and you can't assign them to a single variable.

You can see the colons ':' after the variable names, not followed by a typename, in this
case the types are inferred from the return types of `foo`.

## Symbol visibility

```rust
pub fn publicFunction() -> void {
}

fn privateFunction() -> void {
}
```

Functions are private (not exported) by default.
To allow other files to use them, prepend `pub`. The same applies
to [layouts](#layouts) and [global variables](#global-variables).

## Variables

```rust
let name := "Bob";
let age := 20u32;
let (name2:, age2: u32) = { "Joseph", 21u32 };

let mut someBool: bool;
```

Variables are declared with the `let` keyword, and initialized with `=`. If the variable
is mutable (which are not by default), initial value may be omitted, as you can see from
the variable `someBool`.

The variable's type is inferred from the value on the right hand side, if the type specifier is omitted.
Typecasting between values are never implicit, you can use `ptrcast` to cast between pointers
and `intcast` to cast between integers (and floats).

Numeric literals must have type suffixes unless they are `i32`. Available suffixes are: `i32,
u32, i8, u8, and f`.

Identifiers must either start with an underscore `_` or a lowercase letter. They may include digits.

Keep in mind that `:` and `=` are separate tokens at all times, so all of the below are permitted:

```
let a : = 5;
let a: = 5;
let a := 5;       ---> prefer this
let a:=5;
let a : i32 = 5;
let a : i32= 5;
let a :i32= 5;
let a:i32= 5;
let a:i32= 5;
let a: i32 = 5;   ---> or this
```

Essentially, the `:` is a part of the `variable signature`. The variable definition can be written as:

```rust
let <signature> [= initialization];

or

let (<signature>, <signature>, ....) [= initialization];

where

<signature> = [mut] <identifier> : [type]
```

Where the brackets symbolize optional components, and `<x>` or `x` means `x` is mandatory.
This is precisely the reason why the `:` symbol persists even in multiple returns, or in type
inference. It indicates a type assignment for the identifier provided, if no type is given, it
assigns the inferred type.

### Mutable variables

```rust
let mut age := 20;
age = 21;
```

To change the value of the variable use `=`. In JASL, variables are immutable by default.
To be able to change the value of the variable, you have to mark it with `mut`.

Mutability is not at type level but at variable level, for now. That means you can mutate immutable
variables using pointers since they provide unlimited access.

### Variable Shadowing

The classic shadowing works like most languages:

```rust
let a := "Outer";
{
    let a := "Inner"; // completely fine
    io::println(a); // Output: Inner
}

io::println(a); // Output: Outer
```

The important point here is that variables can shadow functions with the same name. For example:

```rust
module main

fn main() -> void {
    let test := nullptr;
    test();
}

fn test() -> void { }

/*
[PARSER ERROR] test/main.jasl at 5:9: Attempt to call non-function expression.

            test();
                ^
                Right here buddy
*/
```

As you can see, the identifier `test` in the local scope shadows the identifier `test`,
which is a function that resides in the global scope, and the compiler warns us for attempting
to call a non-function expression.

In such cases, you can use namespace resolution to refer to the global symbol:

```
module main

include "io"

fn main() -> void {
    let test := nullptr;
    main::test();
}

fn test() -> void {
    io::println("Hello World");
}

/*
Hello World
*/
```

## JASL Types

### Primitive types

```rust
bool

i8  i32
u8  u32

float (32 bit)

void

and pointers to any of these, including pointers
```

There is no implicit conversion in JASL, conversion between types must either be done by
compiler builtins `ptrcast` and `intcasr`, or by manually writing conversion functions.

```rust
let u := 12u32;
let v := 13 + u;

/*
OUTPUT:
[PARSER ERROR] main.jasl at 7:19: Type mismatch between the sides of binary expression. Expected '(i32)' on both, got '(u32)' instead on one side.

            let v := 13 + u;
                          ^
                          You should be a bit more careful with your code
*/
```

### Strings

In JASL, strings are just wrappers around raw VM pointers pointing to a block of memory
with layout `[4 byte size header][u8 data...]`. However accessing the raw pointer under
is not directly possible. You can check out the string module in stdlib for more.

Here is the `string::String` layout from stdlib if you are lazy to go check it:

```rust
//
// Stack String, Static, No Free.
// Just a pointer to the constant string.
//
pub wrapper layout String {
    data: void*;
}
```

### Numbers

```rust
let a := 123;
```

This will assign the value of 123 to `a`. By default `a` will have the
type `i32`.

If you want a different type of integer, you can use numeric suffixes:

```rust
let a := 123i8;
let b := 42u8;
let c := 12345u32;
```

Assigning floating point numbers works the same way pretty much:

```
let a := 1.0; // There is literally a floating point in the literal
let b := 1f;
```

### Arrays

Arrays are not yet implemented in the compiler, this part of the project is WIP, and TODO.

## Statements & expressions

### If

```rust
let a := 10;
let b := 20;
if a < b {
	io::println("a < b");
} else if a > b {
	io::println("a > b");
} else {
	io::println("a == b");
}
```

`if` statements are pretty straightforward and similar to most other languages.
Unlike other C-like languages, there are no parentheses surrounding the condition and the braces are always required.

If statements are always statements, and there is no such thing as an `if expression`.

If statements are the only control blocks (apart from while loops, if you count them).

### While loop

JASL has only one looping keyword: `while`, with a single form that is classic C-style.

```rust
while condition {
    ...body...
}
```

As you can see, parentheses around the condition is not required, but braces are. The condition
must be an expression that returns a boolean value, since there is no automatic type conversion.

`break` and `continue` statements are not labeled, and they will only affect the closest loop.

### Defer

A `defer <function_call>;` statement, defers the execution of the given call
until the surrounding scope of the defer ends. It is limited to function calls only
for the sake of simplicity. The arguments of the function call are evaluated at the
place of defer, whereas defer is executed at the end of the scope.

Defer statements are executed in the LIFO (Last in First Out) order.

```rust
module main

include "io"

fn main() -> void {
    let mut msg := "Hello World";
    defer io::println(msg);
    defer io::println(msg = "Oh no!");
    defer io::println(msg);
}
```

If you compile and run the program above, you'll get the output:

```
Oh no!
Oh no!
Hello World
```

The last output is from the first defer, which evaluates its parameter in place, so it is "Hello World".
The second defer is the one with the `msg = "Oh no!"`, which when evaluated returns "Oh no!" but also sets
the `msg` to `Oh no!`, so the last defer also prints "Oh no!".

If the function returns a value the `defer` block is executed *after* the return
expression is evaluated:

```rust
module main

include "io"

fn main() -> void {
    if getVal() == 5 {
        io::println("Value was not changed");
    }
    else {
        io::println("Value was changed");
    }
}

fn getVal() -> i32 {
    let mut local := 5;
    defer local.&.set(8);

    return local;
}
```

This prints `Value was not changed`.

In case of an early exit from a scope, whether inside a loop or not, via `break, return, continue`
statements, the defers will work. The compiler will inject them on every exit.

#### defer in loop scopes:

You can have defer statements inside loops too, they'll be executed each loop since
each loops is an enter/exit from the scope.

## Layouts

Layouts are the custom types you define in JASL. They are quite literally C structs,
however I wanted to be honest with the naming. They are just layouts on the memory so,
the name "layout".

Layout names must start with an uppercase letter.

You can define layouts like:

```rust
layout Vec2f {
    pub x: float;
    pub y: float;
}
```

By default, the layout is private. You can mark it `pub` to make it public. The same
goes for the fields of the layout, they are private and immutable by default.

A layout may contain a pointer to itself:

```rust
layout Node {
    prev: Node*;
    next: Node*;
}
```

The keyword `layout` is not quite like C's `struct`, this is not supported, at
least not yet:

```rust
layout Example {
    field: layout {
        innerField: float;
    };
}
```

You may use the keyword `wrapper` to enforce encapsulated layouts:

```rust
wrapper layout WrapThisPtr {
    wrappedPtr: void*;

    pub other: void*;
}

/*
[PARSER ERROR] test/main.jasl at 8:5: Public fields in wrapper layouts are not allowed.

            pub other: void*;
            ^
            You seriously missed this?
*/
```

To create a variable from a layout, you use the constructor style syntax:

```rust
fn main() -> void {
    let wrp := WrapThisPtr(nullptr);
}
```

Mind you, this is no function call. Since the layout is quite literally a layout in VM memory,
the `TypeName(..exprs..)` syntax is just a compiler hint.

Obviously, you can't access the private fields of a layout:

```rust
fn main() -> void {
    let wrp := WrapThisPtr(nullptr);
    let ptr := wrp.wrappedPtr;
}

/*
[PARSER ERROR] test/main.jasl at 11:19: Can't access the fields of a wrapper type inside a function that is not owned by that type.

            let ptr := wrp.wrappedPtr;
                          ^
                          Come on, it's here
*/
```

Notice the `function that is not owned by that type` part, that means we can make functions
be owned by a type!

Here is how:

```rust
fn WrapThisPtr::getPtr(this: WrapThisPtr) -> void* {
}
```

Now this function `getPtr` is owned by the type `WrapThisPtr`. But be careful! This is just
a compiler hint! There is no Object Orientation here, the type name is not even added to the
function name. So if you do:

```rust
fn WrapThisPtr::getPtr(this: WrapThisPtr) -> void* { }
fn SomeType::getPtr() -> u32 { }

/*
[PARSER ERROR] test/main.jasl at 12:14: Multiple definition of function 'getPtr'.

        fn SomeType::getPtr() -> u32 { }
                     ^
                     It's here lad
*/
```

You'll get that error. Note that the parameter `this` is just my choice of name, you can
make it any name you want, you can also choose to not have any parameters of the type `WrapThisPtr`
too. As I said, it is just a compiler hint that allows you to access the private fields of that
layout inside the function boundaries.

In fact, since this owning style is not really some complicated thing, you can just do:

```rust
fn WrapThisPtr::main() -> void {
    let wrp := WrapThisPtr(nullptr);
    let ptr := wrp.wrappedPtr;
}
```

And it compiles just fine.

So, to sum it up, `owned functions` do not affect name mangling and dispatch. See the ["Underlying System"](#underlying-system)
section for more info about how it works (the name mangling section).

### Heap Layouts

Firstly, an introduction to using heap.

Everything in JASL is allocated on stack. To allocate something on the heap,
you must allocate a bit of memory, cast it to needed type and set its value:

```rust
let alloc := allocator::default();
let heapi32 :=
    memory::malloc(sizeof(i32), alloc)
    .ptrcast(i32)
    .set(15);

defer memory::free(heapi32, sizeof(i32), alloc);
```

As you can see, the UFCS of JASL allows you to chain your calls nicely. We allocated
a block with size 4, casted it to `i32*`, and set its value to 15.

As you can see from the `.set(15)` syntax, JASL doesn't do `*ptr = newValue;` like C. To make
every memory write explicit, it has a compiler builtin function `set`, it has the signature
`fn (T*, T) -> T*`. In fact, `.*` and `.&` syntax is just a syntax sugar, they are actually the
compiler builtin functions `deref` and `ref` respectively. They have the signatures
`fn (T*) -> T` and `fn (T) -> T*` respectively.

Don't forget to free the memory too! Also, as you can see, the stdlib `memory` module
functions take an allocator as a parameter, it is a manually crafted vtable mimicking
an interface. You'll see it in detail later.

Now, heap layouts are just the same. You can do it in two styles:

1- C style, allocate and set the fields one-by-one,  
2- Use the `set` operator to directly set it's value.  

However for the C style (method 1), the variable, and all the fields must be mutable.
So I suggest using the second method, it is cleaner.

For example:

```rust
module main

include "memory"

layout Vec {
    pub mut x: float;
    pub mut y: float;
}

fn main() -> void {
    let alloc := allocator::default();

    // Method 1: C Style
    let mut heapVec2 :=
        memory::malloc(sizeof(Vec), alloc)
        .ptrcast(Vec);

    heapVec2.x.set(0f);
    heapVec2.y.set(5f);

    // Method 2: `set` operator
    let heapVec :=
        memory::malloc(sizeof(Vec), alloc)
        .ptrcast(Vec)
        .set(Vec(0f, 5f));
}
```

As you can see above, we also use the `set` operator to set the fields. That is because
when we access the fields of a pointer, the result is a pointer to the fields.

See below:

```rust
let vec :=
    memory::malloc(sizeof(Vec), alloc)
    .ptrcast(Vec);

let fieldX: float* = vec.x; // This is correct, and typechecks
```

Since the snippet above typechecks, we can be sure that the type of `vec.x` is `float*`,
because JASL doesn't have any implicit conversion.

Also for the notes, JASL doesn't have any `reference` or something, everything is passed by value.
If you want to mutate something in another context, pass a pointer.

### Access Modifiers

As I mentioned before, everything in JASL is immutable and private by default. This is the same
for the fields. You must mark them individually to make them public and/or mutable.

```rust
layout Example {
    private_immutable: u32;
    mut private_mutable: u32;
    pub public_immutable: u32;
    pub mut public_mutable: u32;
}
```

### Anonymous Structs

As I mentioned before, no such thing is possible. Sorry.

### Mimicking OOP

JASL has no `objects`, `vtables` or `methods`. However you can mimic them using modules and
type-owned functions, combined with UFCS. The Arena Allocator in stdlib is a great example
for that. See below for a simplified version:

```rust
module arena

include "memory"

pub layout ArenaAllocator {
    base: void*;
    pub capacity: u32;
    mut offset: u32;
}

pub fn ArenaAllocator::new(capacity: u32) -> ArenaAllocator { ... }
pub fn ArenaAllocator::allocate(this: ArenaAllocator*, size: u32) -> void* { ... }
pub fn ArenaAllocator::free(this: ArenaAllocator*) -> bool { ... }
pub fn ArenaAllocator::allocator(this: ArenaAllocator*) -> allocator::Allocator { ... }
```

As you can see, if we structure our modules like this, we can use it like:

```rust
let arena := arena::new(128u32);
let alloc := arena.&.arena::allocator();
defer arena.&.arena::free();

let arenaAllocatedU32 := arena.&.arena::allocate(4u32).ptrcast(u32);
```

The mandatory `namespace::member` resolution might feel tedious, however it saves us a lot of trouble,
and increases clarity.

Also, you can craft vtables manually too, do dynamic dispatch and such. However instead of that
you can just use composition, or interfaces like `allocator::Allocator`, which looks like:

```rust
pub wrapper layout Allocator {
    context: void*;
    allocator: fn (void*, u32) -> void*;
    deallocator: fn (void*, void*, u32) -> bool;
}
```

## UFCS

JASL has a unique way of UFCS. It works by treating every value in the language as what they are:
Indexes on Stack.

For example, let's say I have this function:

```rust
fn returnTwoFloats() -> (float, float) { ... }
```

And I want to construct a `Vec` from our previous example from the return values of this function.
Now, we know that `Vec` is just a compiler `alias` for the layout of two floats on stack, we also
know that multiple returns are just `promises` to the compiler about the layout left on the stack after
the function returns. So essentially, it is just reinterpreting the memory blob like this or like that.

By those definitions, we should be able to do something like:

```rust
let vec := Vec(returnTwoFloats());
```

And indeed we can. Or for example if we have this function:

```rust
fn useFourFloats(a: float, b: float, c: float, d: float) -> void { ... }
```

We should be able to do:

```rust
returnTwoFloats().useFourFloats(3f, 4d);
```

And again, indeed we can, because we know that JASL calling convention works purely on the stack.

Furthermore, expression lists can be used to pack expressions together, as you've seen in section
["Returning Multiple Values"](#returning-multiple-values). So we are also free to do:

```rust
{1f, returnTwoFloats(), 4f}.useFourFloats();
```

The expression list is flattened, and its type is evaluated as `(float, float, float, float)`, which matches
the parameter types of the function `useFourFloats`.

If you remember, I mentioned that `.*` and `.&` were just syntax sugar for compiler builtin functions
`deref` and `ref`, the reason for this decision is to utilize the UFCS to our advantage. By doing so,
we have opened the roads to making JASL a purely "Left-to-Right" oriented language.

We can now chain everything together and create pipelines!

```rust
let creature := creature::create();

creature.&
    .applyGravity()
    .applyTorque(...params...)
    .setProperty(...params...)
    .calculateMovement()
    .move();
```

Or something like this!

## Modules

`Module` is a fancy (or a less fancy) word for a `namespace` in JASL.

Every file must start with a `module` directive. It has the form:

```rust
module <identifier>
```

When the compiler sees a module directive, it creates a namespace (or expands and existing one)
with the functions, types, global variables it sees until it reaches the end of compilation or another
module directive. Until then, the `working module` is the given module.

You can access every member of a module if you are inside that module, if not you can only access
the `exported` a.k.a `pub marked` members, and you must use module resolution syntax `modulename::member`.

See [symbol visibility](#symbol-visibility), [Access modifiers](#access-modifiers).

### Including Files

I specifically stated that `module is a fancy word for a namespace`, that is to prevent the confusion
with include directives.

Include directives have the form:

```rust
include "path/to/file/without/extension"
```

When the compiler sees an include directive, it searches for the file `path/to/file/without/extension.jasl`
on the search path, once it finds it parses the top-level members (like layouts, functions and global variables)
and registers them to the working module, which is the module of the included file. When including a file, you don't know what module that file is, that is
because compiler also only learns that when it opens up the file and sees the `module` directive mentioned above.

With this way, you can span a module across files, and mimic a real module system using directories
and files. The stdlib `memory` module does that extensively.

Keep in mind that there is no such thing as a `multilevel module`, all namespacing
is single layered. This limits the structure of code but makes things easier to understand
by getting rid of namespace hell (I'm looking at you C++).

## Memory management

It is completely manual, which is strange given JASL is a scripting language.

However that is because JASL is the C of a custom VM, built to write the common functions
that'll be used among the languages that target the same VM. So it is the scripting language that
will write the standard library of the scripting languages. And we need low-level control
over VM internals if we want to do that.

To make things easier though, JASL stdlib utilizes the `allocator::Allocator` interface, the
stdlib memory functions such as `memory::malloc` and `memory::free` take an allocator as a parameter,
and it falls back to the standard heap allocation of the VM in case the provided allocator is the default
allocator (or an ill-formed one).

Alongside custom allocator support, there is also `defer` statements that I mentioned earlier. By limiting
the defer statements to function calls, we mimic the behaviour of RAII by essentially doing destructor
calls explicit. Which is nice in my opinion.

And that is all the memory management JASL has folks, no hidden allocations, no hidden
deallocations, everything is clear and explicit.

However.....

Since JASL is a Turing complete language, technically you can write a Garbage Collecting Allocator
manually, that is if you are insane enough.

### Stack and Heap

#### Stack and Heap Basics

Like with most other programming languages there are two locations where data can
be stored:

* The *stack* allows fast allocations with almost zero administrative overhead. The
  stack grows and shrinks with the function call depth &ndash; so every called
  function has its stack segment that remains valid until the function returns.
  No freeing is necessary, however, this also means that a reference to a stack
  object becomes invalid on function return. Furthermore stack space is
  limited (currently fixed to 256000 bytes, but in the future the compiler will
  analyze the source code and specify a stack size based on it).
* The *heap* is a large memory area (yet still limited, currently 64000 bytes,
  however the workings of the heap depends heavily on the VM so JASL doesn't really
  have much to do) that is administrated
  by the VM. Heap objects are allocated and freed by special function
  calls that delegate the administrative tasks to the OS. This means that they can
  remain valid across several function calls, however, the administration is
  expensive.

#### The JASL Way

JASL is explicit and verbose in its way of handling memory. Everything goes to stack, unless
you specify otherwise. And if you do a heap operation, that is guaranteed to be on the heap.

No hidden shenanigans.

## Other JASL Features

### Inline assembly

JASL supports directly injecting inline assembly (the assembly here is the IL the backend
uses) into the code. The stdlib (especially the `memory` module) uses inline assembly extensively.

```rust
let x: u32 = 15u32;
asm {
    pop %ui
    stc %ui 5
}
```

Although `x` is immutable, we overwrite the value of `x` inside the assembly block, so
it has the value `5` instead now.

Assembly blocks are not parsed by the compiler, they are directly injected into the generated IL. That
means you can freely corrupt your program by messing with the stack. You're welcome.

## Underlying System

Since JASL is a low-level (at least I marketed it as one) language, a couple questions may arise about:

1- Alignment  
2- Evaluation Order  
3- Endianness (perhaps)  
4- Calling Convention  
5- Name Mangling  

I have short answers to all of them.  

1- VM RAM is unaligned, everything is packed tightly.  

2- Strictly Left-to-Right, as JASL is read. For example:  

```rust
value.function1().function2().function3()
```

is turned into:

```rust
function3(function2(function1(value)))
```

So the evaluation order is:

```rust
value -> function1 -> function2 -> function3
```

as UFCS is written. This aligns with the postfix `.&` and `.*` operators too.

3- VM enforces a specific endianness, for now it is big endian. Refer to the [VM page](https://github.com/ysufender/CSR)
to be sure, it is not a part of JASL.  

4- Parameters are passed, and returned on the stack. The caller pushes the parameters
to the stack, and uses the `cal` instruction. The VM does some frame setting and when
PC is set to the target function, the stack layout is `[Base Pointer][Program Counter][...params...]`.
The returns work the same, callee pushes the return values onto stack, and uses the `ret` instruction.
The VM reverts the frame and at the end the stack layout is `[...returned values...]`. Be aware
that returned values overwrite the pushed arguments at the end, so essentially they are written
to the start of the pushed arguments.  

Refer to the [VM page](https://github.com/ysufender/CSR) for details.

5- Name mangling is simple, all names are mangled in the following format:  

```rust
modulename$$visibility$$membername
```

As you can see it doesn't contain any type information at all, and no overloading rule is
clear from just by looking at it, because nothing about the signature of this member is known at
this point, apart from its module, visibility and name.

# Appendices

## Appendix I: Keywords

JASL has 17 reserved keywords (2 of them are literals):

```rust
asm
module
include
wrapper
layout
fn
pub
return
let
while
if
else
mut
defer
break
continue
nullptr
```

See also [JASL Types](#jasl-types).

## Appendix II: Operators

This list operators is for [primitive types](#primitive-types) only, except for
the assignment operator.

```rust
+    sum                    integers, floats
-    difference             integers, floats
*    product                integers, floats
/    quotient               integers, floats

!    logical NOT            bools
&&   logical AND            bools
||   logical OR             bools

==   Equality               all primitives, except void
!=   Inequality             all primitives, except void

<=   Lesser Equal           integers, floats
>=   Greater Equal          integers, floats
<    Lesser Than            integers, floats
>    Greater Than           integers, floats

Assignment Operators
=
```

Be aware that operators strictly require values of same types on both sides, as per
the "no implicity conversions" rule.

Also the logical binary operators are short-circuiting.

## Appendix III: EBNF Notation

The BNF form given below might not match with the language at any given time, that is because
compiler is still under development and new features, feature refactorings and rewrites are happening
day by day, and that the parser as well as the lexer are hand-rolled, so I write this BNF additionally.

Use at your own risk, the valid syntax might not be semantically correct, though I tried my best
to set up the BNF so that it'll also be semantically correct.

```
File:
    jasl_code = ModuleDirective , { FunctionDefinition | LayoutDefinition | VariableDefinition | IncludeDirective } ;

Common:
    newline = "\r" | "\n" ;

    comment = "//" , { character } , newline
            | "/*" , { character } , "*/" ;

    identifier = ( "_" , ( "a".."z" | "A".."Z" ) | "a".."z" ) , { "_" | "a".."z" | "A".."Z" | "0".."9" } ;

    lvalue = identifier , { "." , identifier } ;

    custom_typename = "A".."Z" , { "a".."z" | "_" | "A".."Z" } ;
    typename = custom_typename
             | ( "i" | "u" ) , ( "32" | "8" )
             | "float" | "bool" | "void"
             | typename , "*" ;

    mutable_variable = "mut" , identifier , ":" , [ typename ] ;
    immutable_variable = identifier , ":" , [ typename ] ;
    typed_variable = [ "mut" ] , identifier , ":" , typename ;
    variable_signature = mutable_variable | immutable_variable ;

    pointer_value = /* any pointer */;
    variable = /* any defined variable */ ;

Special:
    private_field = typed_variable , ";" ;
    field = "pub" , private_field ;
    wrapper_layout_definition = [ "pub" ] , "wrapper" , "layout" , custom_typename , "{" , { private_field } , "}" ;
    normal_layout_definition = [ "pub" ] , "layout" , custom_typename , "{" , { field } , "}" ;
    layout_definition = wrapper_layout_definition | normal_layout_definition ;

    module_directive = "module" , identifier ;
    include_directive = "include" , '"' , { character } , '"' ;

    jasm_il = /* any acceptable JASM IL code */;
    character = /* any ASCII character */;
    string_applicable_character = /* any character except '"' */ ;

    referencing = variable , "." , "&" ;
    dereferencing = pointer_value , "." , "*" ;
    memory_writing = pointer_value , "." , "set" , "(" , expression , ")"
                   | "set" , "(" , ( pointer_value , "," , expression | expression_list ) , ")" ;
    offsetting = pointer_value , "." , "offset" , "(" , expression , ")"
               | "offset" , "(" , ( pointer_value , "," , expression | expression_list ) , ")" ;

Statement:
    statement = FunctionDefinition | Return | Assembly | VariableDefinition | Block | Conditional | While | ExpressionStatement | Break | Continue | Defer ;

    FunctionDefinition = [ "pub" ] , "fn" , identifier , "(" , [ typed_variable , { "," , typed_variable } ] , ")"
                         , "->" , ( "(" , [ typename , { "," , typename } ] , ")" | typename ) , Block ;

    Return = "return" , expression , ";" ;
    Assembly = "asm" , "{" , { jasm_il } , "}" ;

    VariableDefinition =
        [ "pub" ] , "let" , ( 
            mutable_variable , [ "=" , expression ]
          | immutable_variable , "=" , expression
          | "(" , mutable_variable , { "," , mutable_variable } , ")" , [ "=" , expression ]
          | "(" , immutable_variable , { "," , immutable_variable } , ")" , "=" , expression
        ) , ";" ;

    Block = "{" , { statement } , "}" ;

    Conditional = "if" , expression , Block , [ "else" , ( Block | Conditional ) ] ;

    While = "while" , expression , Block ;

    ExpressionStatement = ( FunctionCall | AssignmentExpression ) , ";" ;

    Break = "break" , ";" ;
    Continue = "continue" , ";" ;
    Defer = "defer" , FunctionCall , ";" ;

Expression:
    expression = AssignmentExpression | Initialization ;

    AssignmentExpression = lvalue , "=" , expression ;

    ConditionalExpression = LogicalOrExpression ;

    LogicalOrExpression = LogicalAndExpression , { "||" , LogicalAndExpression } ;
    LogicalAndExpression = EqualityExpression , { "&&" , EqualityExpression } ;
    EqualityExpression = ComparisonExpression , { ( "==" | "!=" ) , ComparisonExpression } ;
    ComparisonExpression = AdditiveExpression , { ( ">" | "<" | ">=" | "<=" ) , AdditiveExpression } ;
    AdditiveExpression = MultiplicativeExpression , { ( "+" | "-" ) , MultiplicativeExpression } ;
    MultiplicativeExpression = UnaryExpression , { ( "*" | "/" ) , UnaryExpression } ;
    UnaryExpression = ( "-" | "!" ) , UnaryExpression | PostfixExpression ;
    PostfixExpression = PrimaryExpression , { PostfixSuffix } ;
    PostfixSuffix = "." , identifier | "(" , [ ExpressionList ] , ")" | "::" , identifier ;
    PrimaryExpression = identifier | literal | "(" , expression , ")" | ExpressionList ;
    ExpressionList = "{" , [ expression , { "," , expression } ] , "}" ;

    literal = '"' , { string_applicable_character } , '"' 
            | integer , [ integer_suffix ]
            | integer , "." , integer
            | "nullptr" ;

    Initialization = custom_typename , "(" , expression , { "," , expression } , ")" ;
    FunctionCall = [ expression , "." ] , expression , "(" , [ expression , { "," , expression } ] , ")" ;
```
