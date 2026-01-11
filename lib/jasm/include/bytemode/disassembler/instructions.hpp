#pragma once

#include <istream>

namespace DisassemblerInstructions
{
    void Nop(std::istream& in);

    void Store32(std::istream& in);
    void Store8(std::istream& in);
    void StoreFloat(std::istream& in);

    void Load32(std::istream& in);
    void Load8(std::istream& in);
    void LoadFloat(std::istream& in);

    void ReadRegister(std::istream& in);
    void ReadAddress(std::istream& in);

    void MoveStackToReg(std::istream& in);
    void MoveRegToReg(std::istream& in);
    void MoveConstToReg(std::istream& in);

    void Add32(std::istream& in);
    void Add8(std::istream& in);
    void AddFloat(std::istream& in);

    void AddReg32(std::istream& in);
    void AddReg8(std::istream& in);
    void AddRegFloat(std::istream& in);

    void AddSafe32(std::istream& in);
    void AddSafe8(std::istream& in);
    void AddSafeFloat(std::istream& in);

    void Sub32(std::istream& in);
    void Sub8(std::istream& in);
    void SubFloat(std::istream& in);

    void SubReg32(std::istream& in);
    void SubReg8(std::istream& in);
    void SubRegFloat(std::istream& in);

    void SubSafe32(std::istream& in);
    void SubSafe8(std::istream& in);
    void SubSafeFloat(std::istream& in);

    void MemCopy(std::istream& in);

    void Increment32(std::istream& in);
    void Increment8(std::istream& in);
    void IncrementFloat(std::istream& in);

    void IncrementReg32(std::istream& in);
    void IncrementReg8(std::istream& in);
    void IncrementRegFloat(std::istream& in);

    void IncrementSafe32(std::istream& in);
    void IncrementSafe8(std::istream& in);
    void IncrementSafeFloat(std::istream& in);

    void Decrement32(std::istream& in);
    void Decrement8(std::istream& in);
    void DecrementFloat(std::istream& in);

    void DecrementReg32(std::istream& in);
    void DecrementReg8(std::istream& in);
    void DecrementRegFloat(std::istream& in);

    void DecrementSafe32(std::istream& in);
    void DecrementSafe8(std::istream& in);
    void DecrementSafeFloat(std::istream& in);

    void And32(std::istream& in);
    void And8(std::istream& in);
    void AndReg(std::istream& in);

    void Or32(std::istream& in);
    void Or8(std::istream& in);
    void OrReg(std::istream& in);

    void Nor32(std::istream& in);
    void Nor8(std::istream& in);
    void NorReg(std::istream& in);

    void Swap32(std::istream& in);
    void Swap8(std::istream& in);
    void SwapReg(std::istream& in);

    void Duplicate32(std::istream& in);
    void Duplicate8(std::istream& in);

    void RawData(std::istream& in);
    void RawSymbol(std::istream& in);

//  This instruction can't be detected since it leaves no trace
//  void RomData(std::istream& in);

    void Invert32(std::istream& in);
    void Invert8(std::istream& in);
    void InvertReg(std::istream& in);

    void InvertSafe32(std::istream& in);
    void InvertSafe8(std::istream& in);
    
    void CompareStack(std::istream& in);
    void CompareReg(std::istream& in);

    void Pop32(std::istream& in);
    void Pop8(std::istream& in);

    void JumpImm(std::istream& in);
    void JumpReg(std::istream& in);

    void SwapRange(std::istream& in);

    void DuplicateRange(std::istream& in);

    void Repeat(std::istream& in);

    void Allocate(std::istream& in);

    void PowerImm32(std::istream& in);
    void PowerImm8(std::istream& in);
    void PowerImmFloat(std::istream& in);

    void PowerStack32(std::istream& in);
    void PowerStack8(std::istream& in);
    void PowerStackFloat(std::istream& in);

    void PowerReg32(std::istream& in);
    void PowerReg8(std::istream& in);
    void PowerRegFloat(std::istream& in);

    void SquareImm32(std::istream& in);
    void SquareImm8(std::istream& in);
    void SquareImmFloat(std::istream& in);

    void SquareStack32(std::istream& in);
    void SquareStack8(std::istream& in);
    void SquareStackFloat(std::istream& in);

    void SquareReg32(std::istream& in);
    void SquareReg8(std::istream& in);
    void SquareRegFloat(std::istream& in);

    void ConditionalImm(std::istream& in);
    void ConditionalReg(std::istream& in);

    void CallImm(std::istream& in);
    void CallReg(std::istream& in);

    void Multiply32(std::istream& in);
    void Multiply8(std::istream& in);
    void MultiplyFloat(std::istream& in);

    void MultiplyReg32(std::istream& in);
    void MultiplyReg8(std::istream& in);
    void MultiplyRegFloat(std::istream& in);

    void MultiplySafe32(std::istream& in);
    void MultiplySafe8(std::istream& in);
    void MultiplySafeFloat(std::istream& in);

    void Divide32(std::istream& in);
    void Divide8(std::istream& in);
    void DivideFloat(std::istream& in);

    void DivideReg32(std::istream& in);
    void DivideReg8(std::istream& in);
    void DivideRegFloat(std::istream& in);

    void DivideSafe32(std::istream& in);
    void DivideSafe8(std::istream& in);
    void DivideSafeFloat(std::istream& in);

    void Return(std::istream& in);

    void Deallocate(std::istream& in);

    void IncrementLocal32(std::istream& in);
    void IncrementLocal8(std::istream& in);
    void IncrementLocalFloat(std::istream& in);

    void ReadLocal32(std::istream& in);
    void DividetLocal8(std::istream& in);
    void DividetLocalFloat(std::istream& in);

    void ConditionalJump(std::istream& in);

    void CompareLocal(std::istream& in);

    void StoreAddress(std::istream& in);
}
