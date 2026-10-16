#include "../native/windows_symlink_support.hpp"
#include <iostream>
#include <system_error>

namespace fs = std::filesystem;
static void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
struct Handle {
    HANDLE value = nullptr;
    ~Handle() { if (value) CloseHandle(value); }
};
struct Impersonation {
    bool active = false;
    ~Impersonation() { if (active) RevertToSelf(); }
};
int main() {
    const auto root = fs::temp_directory_path() /
        (L"xtool symlink privileges ü " + std::to_wstring(GetCurrentProcessId()));
    try {
        xtool_windows::requireSymbolicLinks(root);
        require(fs::is_empty(root), "Successful preflight left probe files behind");
        std::cout << "File/directory symlink capability and probe cleanup passed\n";
        Handle process, restricted;
        require(OpenProcessToken(GetCurrentProcess(), TOKEN_DUPLICATE | TOKEN_QUERY |
            TOKEN_IMPERSONATE, &process.value) != 0, "OpenProcessToken failed");
        require(CreateRestrictedToken(process.value, DISABLE_MAX_PRIVILEGE, 0, nullptr,
            0, nullptr, 0, nullptr, &restricted.value) != 0, "CreateRestrictedToken failed");
        DWORD developerMode = 0, size = sizeof(developerMode);
        const LSTATUS registry = RegGetValueW(HKEY_LOCAL_MACHINE,
            L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\AppModelUnlock",
            L"AllowDevelopmentWithoutDevLicense", RRF_RT_REG_DWORD, nullptr, &developerMode, &size);
        Impersonation impersonation;
        require(ImpersonateLoggedOnUser(restricted.value) != 0, "Impersonation failed");
        impersonation.active = true;
        bool denied = false;
        try {
            xtool_windows::requireSymbolicLinks(root);
        } catch (const xtool_windows::SymlinkError& error) {
            require(error.code() == ERROR_PRIVILEGE_NOT_HELD,
                "Restricted token failed for a reason other than symlink privileges");
            require(std::string(error.what()).find("Enable Windows Developer Mode") != std::string::npos,
                "Missing symlink privileges did not explain the remedy");
            denied = true;
            std::cout << "Restricted-token prerequisite failure: " << error.what() << '\n';
        }
        if (registry != ERROR_SUCCESS || !developerMode) {
            require(denied, "Missing privileges were not detected with Developer Mode disabled");
        } else {
            require(!denied, "Developer Mode did not allow unprivileged symlinks");
            std::cout << "Developer Mode allows the restricted token without symlink privileges\n";
        }
        require(fs::is_empty(root), "Denied preflight left probe files behind");
        require(RevertToSelf() != 0, "RevertToSelf failed");
        impersonation.active = false;
        fs::remove(root);
        std::cout << "Native Windows symlink prerequisite tests passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        std::error_code ignored;
        fs::remove_all(root, ignored);
        return 1;
    }
}
