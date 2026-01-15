#include <filesystem>
#include <iostream>
#include <fstream>
#include <string>

#define VERSION "0.1.0"

int main(int argc, char** argv) {
    if (argc < 3 || argc > 4) {
        std::cerr << "Usage: " << argv[0] << " <input-file> <output-file> [debug = false]\n";
        return 1;
    }

    std::string filename = argv[1];
    std::string targetname = argv[2];
    bool debug_enabled = false;

    if (argc > 3) {
        if (std::string(argv[3]) == "true") debug_enabled = true;
        else if (std::string(argv[3]) == "false") debug_enabled = false;
    }

    std::ifstream finput(filename);
    if (!finput) {
        std::cerr << "Given file '" << filename << "' could not be found.\n";
        perror("fopen");
        return 1;
    }

    std::ofstream ftarget(targetname);
    if (!ftarget) {
        std::cerr << "Couldn't open file '" << targetname << "' for writing.\n";
        perror("fopen");
        return 1;
    }

    std::string line;
    int lineno = 1;
    bool in_debug_block = false;
    bool in_release_block = false;

    while (std::getline(finput, line)) {

        if (line.find("__DEBUG_START__") != std::string::npos) {
            in_debug_block = true;
            ftarget << "\n";
            ++lineno;
            continue;
        }

        if (line.find("__DEBUG_END__") != std::string::npos) {
            in_debug_block = false;
            ftarget << "\n";
            ++lineno;
            continue;
        }

        if (line.find("__RELEASE_START__") != std::string::npos) {
            in_release_block = true;
            ftarget << "\n";
            ++lineno;
            continue;
        }

        if (line.find("__RELEASE_END__") != std::string::npos) {
            in_release_block = false;
            ftarget << "\n";
            ++lineno;
            continue;
        }

        if (in_debug_block && !debug_enabled) {
            ftarget << "\n";
            ++lineno;
            continue;
        }

        if (in_release_block && debug_enabled) {
            ftarget << "\n";
            ++lineno;
            continue;
        }

        std::string result;
        result.reserve(line.size());

        for (size_t i = 0; i < line.size();) {
            // Check for each token at current position
            if (line.compare(i, 8, "__LINE__") == 0) {
                result += "\"" + std::to_string(lineno) + "\"";
                i += 8;
            } else if (line.compare(i, 8, "__FILE__") == 0) {
                result += "\"" + filename + "\"";
                i += 8;
            } else if (line.compare(i, 9, "__DEBUG__") == 0) {
                result += debug_enabled ? "true" : "false";
                i += 9;
            } else if (line.compare(i, 11, "__VERSION__") == 0) {
                result += VERSION;
                i += 11;
            } else if (line.compare(i, 10, "__CONFIG__") == 0) {
                result += debug_enabled ? "debug" : "release";
                i += 10;
            } else if (line.compare(i, 14, "__SOURCE_DIR__") == 0) {
                result += std::filesystem::current_path();
                i += 14;
            } else {
                result += line[i];
                ++i;
            }
        }

        ftarget << result << "\n";
        ++lineno;
    }

    return 0;
}

