#pragma once

#include "JASMConfig.hpp"
#include "system.hpp"
#include <bit>
#include <cmath>
#include <fstream>
#include <functional>
#include <iterator>
#include <string>
#include <type_traits>
#include <cstring>

namespace Instructions { enum class OpCodes : uchar_t; }

namespace Extensions::Serialization
{
    template<typename T>
    concept integer = requires
    {
        std::is_integral_v<T> || std::is_same_v<T, Instructions::OpCodes>;
    };

    template<typename T>
    concept iterable = requires(T& t)
    {
        std::begin(t) != std::end(t);
        ++std::declval<decltype(std::begin(t))&>();
        *std::begin(t);
    };

    template<typename U>
    inline constexpr U byteswap(U v) noexcept
    {
        static_assert(std::is_unsigned_v<U>);
        if constexpr (sizeof(U) == 1) return v;
        else if constexpr (sizeof(U) == 2)
        {
            return U((v & 0x00FFu) << 8 |
                     (v & 0xFF00u) >> 8);
        }
        else if constexpr (sizeof(U) == 4)
        {
            return U((v & 0x000000FFu) << 24 |
                     (v & 0x0000FF00u) <<  8 |
                     (v & 0x00FF0000u) >>  8 |
                     (v & 0xFF000000u) >> 24);
        }
        else if constexpr (sizeof(U) == 8)
        {
            return U((v & 0x00000000000000FFull) << 56 |
                     (v & 0x000000000000FF00ull) << 40 |
                     (v & 0x0000000000FF0000ull) << 24 |
                     (v & 0x00000000FF000000ull) <<  8 |
                     (v & 0x000000FF00000000ull) >>  8 |
                     (v & 0x0000FF0000000000ull) >> 24 |
                     (v & 0x00FF000000000000ull) >> 40 |
                     (v & 0xFF00000000000000ull) >> 56);
        }
        else
        {
            U out = 0;
            for (size_t i = 0; i < sizeof(U); ++i)
                out = (out << 8) | ((v >> (i * 8)) & 0xFF);
            return out;
        }
    }

    //
    // Serialization
    //
    template<integer T>
    inline void SerializeInteger(const T& data, std::ostream& stream)
    {
        using UT = std::make_unsigned_t<T>;
        UT temp;
        std::memcpy(&temp, &data, sizeof(T));

        if constexpr (std::endian::native == std::endian::little)
            temp = byteswap(temp);

        stream.write(reinterpret_cast<const char*>(&temp), sizeof(temp));
    }

    template<iterable ContT, integer SizeT, typename ElemT>
    inline void SerializeContainer(
        const ContT& container,
        std::ostream& stream,
        std::function<void(const ElemT&, std::ostream&)> serializer
    )
    {
        SizeT size { static_cast<SizeT>(container.size()) };
        SerializeInteger(size, stream);
        for (const ElemT& element : container)
            serializer(element, stream);
    }

    void SerializeFloat(const float& data, std::ostream& stream);

    //
    // Deserialization
    //
    template<integer T>
    inline void DeserializeInteger(T& data, std::istream& stream)
    {
        using UT = std::make_unsigned_t<T>;
        UT temp{};
        stream.read(reinterpret_cast<char*>(&temp), sizeof(temp));

        if constexpr (std::endian::native == std::endian::little)
            temp = byteswap(temp);

        std::memcpy(&data, &temp, sizeof(T));
    }

    void DeserializeFloat(float& data, std::istream& stream);

    template<iterable ContT, integer SizeT, typename ElemT>
    inline void DeserializeContainer(
        ContT& container,
        std::istream& stream,
        std::function<void(ElemT&, std::istream&)> deserializer
    )
    {
        SizeT size{};
        DeserializeInteger(size, stream);
        for (; size > 0; size--)
        {
            ElemT element;
            deserializer(element, stream);
            container.push_back(std::move(element));
        }
    }
}
