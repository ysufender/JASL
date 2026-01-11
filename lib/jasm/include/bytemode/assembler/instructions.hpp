#pragma once

#include <istream>
#include <ostream>
#include <string>

#include <cmath>

#include "JASMConfig.hpp"
#include "extensions/serialization.hpp"
#include "bytemode/assembler/assembler.hpp"

namespace Instructions
{
    enum class OpCodes : uchar_t 
    {
        nop, 
        stt, ste, 
        stts, stes, 
        ldt, lde, 
        rdt, rde, rdr, 
        movc, movs, movr, 
        addi, addf, addb, addri, addrf, addrb, addsi, addsf, addsb, 
        mcp, 
        inci, incf, incb, incri, incrf, incrb, incsi, incsf, incsb, 
        dcri, dcrf, dcrb, dcrri, dcrrf, dcrrb, dcrsi, dcrsf, dcrsb, 
        andst, andse, andr, 
        orst, orse, orr, 
        norst, norse, norr, 
        swpt, swpe, swpr, 
        dupt, dupe, 
        raw , raws, 
        invt, inve, invr, invst, invse, 
        cmp, cmpr, 
        popt, pope, 
        jmp, jmpr,
        swr,
        dur,
        rep,
        alc,
        powri, powrf, powrb, powsi, powsf, powsb, powi, powf, powb,
        sqri, sqrf, sqrb, sqrri, sqrrf, sqrrb, sqrsi, sqrsf, sqrsb,
        cnd, cndr,
        cal, calr,
        muli, mulf, mulb, mulri, mulrf, mulrb, mulsi, mulsf, mulsb, 
        divi, divf, divb, divri, divrf, divrb, divsi, divsf, divsb, 
        ret,
        del,
        subi, subf, subb, subri, subrf, subrb, subsi, subsf, subsb,
        incli, inclf, inclb,
        rdlt, rdle,
        cnj,
        cml,
        // psf,
        stf,
        sys,
        xorst, xorse, xorr,
    };

    std::string Nop(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string StoreConstant(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string LoadConstant(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string ReadAddress(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Move(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Add(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string AddSafe(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string MemCopy(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Increment(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string IncrementSafe(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Decrement(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string DecrementSafe(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string And(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Or(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Nor(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Swap(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Duplicate(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string RawData(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string RomData(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Invert(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string InvertSafe(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Compare(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Pop(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Jump(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string SwapRange(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string DuplicateRange(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string DuplicateRange(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Repeat(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Allocate(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Power(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string SquareRoot(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Conditional(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Call(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Multiply(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string MultiplySafe(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Divide(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string DivideSafe(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Return(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Deallocate(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Sub(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string SubSafe(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string IncrementLocal(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string ReadLocal(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string ConditionalJump(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string CompareLocal(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string SymbolAddress(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string PushStackFrame(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string SetFlag(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string SysCall(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
    std::string Xor(ByteAssembler::AssemblyInfo& info, std::istream& in, std::ostream& out);
}
