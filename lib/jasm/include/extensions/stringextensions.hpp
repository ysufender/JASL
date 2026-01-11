#pragma once

#include <cctype>
#include <concepts>
#include <string>
#include <vector>

namespace Extensions::String 
{
    std::vector<std::string> Split(const std::string_view& str, char delimiter, bool removeTrailing = true);
    std::string Concat(const std::vector<std::string_view>& strings);
    std::string Join(const std::vector<std::string_view>& strings, char delimiter);

    template<typename T>
    concept integer = std::integral<T>;
        
    template<integer T>
    inline constexpr T HexToInt(const std::string& hex)
    {
        return static_cast<T>(std::stoul(hex, 0, 16));
    }

    size_t Hash(const std::string_view str);

    inline bool TokenIsNumber(const std::string& token)
    {
        if (token.empty())
            return false;

        bool fracted = false;
        bool hex = false;

        for (size_t i = 0; i < token.size(); i++)
        {
            const char ch { token.at(i) };

            if (isdigit(ch))
                continue;
            if (ch == '-' && i != 0)
                return false;
            if (ch == '.')
            {
                if (fracted || hex)
                    return false;
                fracted = true;
            }
            if (ch == 'x' && i == 1)
                hex = true;
            if (isalpha(ch) && !hex)
                return false;
        }

        return true;
    }
}
