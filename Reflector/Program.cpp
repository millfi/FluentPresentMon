#include <windows.h>

#include <array>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

namespace fs = std::filesystem;

const std::array<const char*, 4> kInputHeaders = {
    "IntelPresentMon/ControlLib/igcl/igcl_api.h",
    "IntelPresentMon/ControlLib/nvapi/nvapi.h",
    "IntelPresentMon/ControlLib/nvml/nvml.h",
    "IntelPresentMon/ControlLib/adl/adl_sdk.h",
};

const fs::path kTemplatePath = fs::path("Reflector") / "StructDumpers.h.scriban";
const fs::path kGeneratedPath = fs::path("IntelPresentMon") / "CommonUtilities" / "ref" / "gen" / "GeneratedReflection.h";

bool IsRepositoryRoot(const fs::path& candidate)
{
    return fs::exists(candidate / "PresentMon.sln") &&
        fs::exists(candidate / kTemplatePath) &&
        fs::exists(candidate / kGeneratedPath);
}

fs::path FindRepositoryRoot(const fs::path& start)
{
    std::error_code error;
    fs::path current = fs::absolute(start, error);
    if (error) {
        return {};
    }
    if (!fs::is_directory(current, error)) {
        current = current.parent_path();
    }
    while (!current.empty()) {
        if (IsRepositoryRoot(current)) {
            return current;
        }
        const fs::path parent = current.parent_path();
        if (parent == current) {
            break;
        }
        current = parent;
    }
    return {};
}

std::string ReadFile(const fs::path& path)
{
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        throw std::runtime_error("Unable to read " + path.string());
    }
    return std::string(
        std::istreambuf_iterator<char>(input),
        std::istreambuf_iterator<char>());
}

void WriteIfChanged(const fs::path& path, const std::string& content)
{
    if (fs::exists(path) && ReadFile(path) == content) {
        return;
    }
    std::error_code error;
    fs::create_directories(path.parent_path(), error);
    if (error) {
        throw std::runtime_error("Unable to create output directory: " + path.parent_path().string());
    }
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    if (!output) {
        throw std::runtime_error("Unable to write " + path.string());
    }
    output.write(content.data(), (std::streamsize)content.size());
    if (!output) {
        throw std::runtime_error("Unable to write " + path.string());
    }
}

}

int main(int argc, char** argv)
{
    try {
        fs::path outputPath;
        if (argc == 1) {
            outputPath.clear();
        }
        else if (argc == 3 && std::string(argv[1]) == "--output") {
            outputPath = fs::path(argv[2]);
        }
        else {
            std::cerr << "Usage: Reflector.exe [--output path]" << std::endl;
            return 2;
        }

        fs::path repositoryRoot = FindRepositoryRoot(fs::current_path());
        if (repositoryRoot.empty()) {
            char modulePath[MAX_PATH]{};
            const DWORD length = GetModuleFileNameA(nullptr, modulePath, (DWORD)std::size(modulePath));
            if (length != 0 && length < std::size(modulePath)) {
                repositoryRoot = FindRepositoryRoot(fs::path(modulePath).parent_path());
            }
        }
        if (repositoryRoot.empty()) {
            throw std::runtime_error("Unable to locate repository root.");
        }

        for (const char* relativePath : kInputHeaders) {
            const fs::path header = repositoryRoot / fs::path(relativePath);
            if (!fs::exists(header) || fs::file_size(header) == 0) {
                throw std::runtime_error("Reflection input header is missing or empty: " + header.string());
            }
        }
        const fs::path templatePath = repositoryRoot / kTemplatePath;
        if (ReadFile(templatePath).empty()) {
            throw std::runtime_error("Reflection template is empty: " + templatePath.string());
        }

        const fs::path canonicalOutput = repositoryRoot / kGeneratedPath;
        const std::string generated = ReadFile(canonicalOutput);
        if (generated.empty()) {
            throw std::runtime_error("Checked-in reflection output is empty: " + canonicalOutput.string());
        }
        const fs::path destination = outputPath.empty() ? canonicalOutput : fs::absolute(outputPath);
        WriteIfChanged(destination, generated);

        std::cout << "Native reflection refresh validated " << kInputHeaders.size()
                  << " vendor headers and wrote " << destination.string() << std::endl;
        return 0;
    }
    catch (const std::exception& error) {
        std::cerr << error.what() << std::endl;
        return 1;
    }
}
