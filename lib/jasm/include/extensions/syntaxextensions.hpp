#pragma once

// https://stackoverflow.com/a/42060129

struct defer_dummy {};
template <class F> struct deferrer { F f; ~deferrer() { f(); } };
template <class F> deferrer<F> operator*(defer_dummy, F f) { return {f}; }
#define DEFER_(LINE) zz_defer##LINE
#define DEFER(LINE) DEFER_(LINE)
#define defermul auto DEFER(__LINE__) = defer_dummy{} *[&]()
#define defer(expr) defermul { expr; } 
