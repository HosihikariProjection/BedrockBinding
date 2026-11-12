// Shared C ABI primitives for Hosihikari BindingShims.
// Keep this header in sync with Hosihikari.Bindings.Abi (StringView, ArrayView,
// SharedHandleData) and bump the table version when any layout changes.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

#if defined(_WIN32)
#define HOSIHIKARI_SHIM_EXPORT __declspec(dllexport)
#else
#define HOSIHIKARI_SHIM_EXPORT __attribute__((visibility("default")))
#endif

extern "C" {

struct HosihikariStringView {
    const char* data;
    std::size_t size;
};

struct HosihikariArrayView {
    const void* data;
    std::size_t size;
};

typedef void (*HosihikariSharedRelease)(void*);

struct HosihikariSharedHandle {
    void* holder;
    void* target;
    HosihikariSharedRelease release;
};

struct HosihikariMapEntry {
    std::uint64_t key;
    std::uint64_t keySize;
    std::uint64_t value;
    std::uint64_t valueSize;
};

}  // extern "C"

namespace hosihikari::abi {

inline thread_local std::string g_lastError;

inline void setLastError(char const* message) noexcept
{
    try {
        g_lastError = message ? message : "unknown native error";
    }
    catch (...) {
    }
}

// The slot is sticky by design: a caller only reads it after a call that reported failure.
// Clearing it is a separate operation so a shim entry can reset it without the "unknown
// native error" placeholder a null setLastError would leave behind.
inline void clearLastError() noexcept
{
    try {
        g_lastError.clear();
    }
    catch (...) {
    }
}

inline char const* lastError() noexcept
{
    return g_lastError.c_str();
}

}  // namespace hosihikari::abi
