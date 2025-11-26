#pragma once

#include "types.h"

void c_bytearray_erase_noop(void *envPtr);
struct Pos c_bytearray_new(const Int size);
Int c_bytearray_size(const struct Pos arr);
Byte c_bytearray_get(const struct Pos arr, const Int index);
struct Pos c_bytearray_set(const struct Pos arr, const Int index, const Byte value);
uint8_t* c_bytearray_data(const struct Pos arr);
struct Pos c_bytearray_construct(const uint64_t n, const uint8_t *data);
struct Pos c_bytearray_from_nullterminated_string(const char *data);
char* c_bytearray_into_nullterminated_string(const struct Pos arr);
struct Pos c_bytearray_show_Int(const Int n);
struct Pos c_bytearray_show_Char(const uint64_t n);
struct Pos c_bytearray_show_Byte(const Byte n);
struct Pos c_bytearray_show_Double(const Double x);
struct Pos c_bytearray_concatenate(const struct Pos left, const struct Pos right);
struct Pos c_bytearray_equal(const struct Pos left, const struct Pos right);
Int c_bytearray_compare(const struct Pos left, const struct Pos right);
struct Pos c_bytearray_substring(const struct Pos str, uint64_t start, uint64_t end);
uint32_t c_bytearray_character_at(const struct Pos str, const uint64_t index);
