#include <iostream>
#include <filesystem>
#include <cstdlib>

namespace fs = std::filesystem;

constexpr auto BUILD_OUTPUT = "__SOURCE_DIR__/build/__CONFIG__/jasl";
constexpr auto SELF_NAME    = "__SOURCE_DIR__/build/jasl_install";
constexpr auto JASL_VERSION = "__VERSION__";
constexpr auto JASL_STDLIB  = "__SOURCE_DIR__/lib/jasl";

void print_version() { std::cout << JASL_VERSION << "\n"; }
void print_stdlib()  { std::cout << JASL_STDLIB << "\n"; }

void create_symlink(const fs::path& source, const fs::path& target) {
    std::error_code ec;
    if (fs::exists(target, ec)) {
        if (fs::is_symlink(target, ec)) fs::remove(target, ec);
        else { std::cerr << "Cannot create symlink, target exists and is not a symlink: " << target << "\n"; exit(1); }
    }
    fs::create_symlink(fs::absolute(source), target, ec);
    if (ec) { std::cerr << "Failed to create symlink: " << ec.message() << "\n"; exit(1); }
}

void remove_symlink(const fs::path& path) {
    std::error_code ec;
    if (fs::exists(path, ec) && fs::is_symlink(path, ec)) fs::remove(path, ec);
}

void install(const fs::path& dir) {
    if (dir.empty()) { std::cerr << "Error: symlink directory required\n"; exit(1); }
    fs::create_directories(dir);

    fs::path compiler_link = dir / fs::path(BUILD_OUTPUT).filename();
    ::create_symlink(BUILD_OUTPUT, compiler_link);

    fs::path self_link = dir / fs::path(SELF_NAME).filename();
    ::create_symlink(SELF_NAME, self_link);

    std::cout << "Installation complete.\n";
    std::cout << "Symlinks created:\n";
    std::cout << "  " << fs::absolute(compiler_link) << " -> " << fs::absolute(BUILD_OUTPUT) << "\n";
    std::cout << "  " << fs::absolute(self_link) << " -> " << fs::absolute(SELF_NAME) << "\n";
}

void uninstall(const fs::path& dir) {
    if (dir.empty()) { std::cerr << "Error: symlink directory required\n"; exit(1); }

    fs::path compiler_link = dir / fs::path(BUILD_OUTPUT).filename();
    remove_symlink(compiler_link);

    fs::path self_link = dir / fs::path(SELF_NAME).filename();
    remove_symlink(self_link);

    std::cout << "Uninstallation complete.\n";
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cout << "JASL Installation Manager __VERSION__\n\nUsage:\n\tjasl_install [install <symlink_dir>|uninstall <symlink_dir>|--version|--stdlib]\n";
        return 0;
    }

    std::string arg = argv[1];

    if (arg == "install") {
        if (argc < 3) { std::cerr << "Error: symlink directory required\n"; return 1; }
        install(argv[2]);
    } else if (arg == "uninstall") {
        if (argc < 3) { std::cerr << "Error: symlink directory required\n"; return 1; }
        uninstall(argv[2]);
    } else if (arg == "--version") {
        print_version();
    } else if (arg == "--stdlib") {
        print_stdlib();
    } else {
        std::cerr << "Unknown argument: " << arg << "\n"; return 1;
    }

    return 0;
}
