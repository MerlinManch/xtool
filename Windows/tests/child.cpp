// Test fixture used to observe argument boundaries and exit propagation.
#include <iostream>
#include <iomanip>
#include <string>
#ifdef _WIN32
#include <windows.h>
static std::string utf8(const wchar_t* text) {
    const int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
    std::string result(static_cast<size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text, -1, result.data(), size, nullptr, nullptr);
    result.pop_back();
    return result;
}
int wmain(int argc, wchar_t** argv) {
#else
static std::string utf8(const char* text) { return text; }
int main(int argc, char** argv) {
#endif
    std::cout << '[';
    for (int i = 1; i < argc; ++i) {
        if (i > 1) std::cout << ',';
        std::cout << std::quoted(utf8(argv[i]));
    }
    std::cout << "]\n";
    return 23;
}
