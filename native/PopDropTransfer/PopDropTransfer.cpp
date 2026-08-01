#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincrypt.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <shldisp.h>
#include <shlwapi.h>
#include <shellapi.h>
#include <objidl.h>
#include <urlmon.h>
#include <winhttp.h>
#include <wincodec.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cwchar>
#include <cwctype>
#include <filesystem>
#include <functional>
#include <iterator>
#include <map>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "crypt32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "user32.lib")

namespace fs = std::filesystem;

namespace {

constexpr wchar_t kPartSuffix[] = L".popdrop-part";
constexpr wchar_t kHelperVersion[] = L"1.0.0";
constexpr DWORD kChunkSize = 1024 * 1024;
constexpr DWORD kStateThrottleMs = 125;
constexpr DWORD kAdoptSourceTimeoutMs = 30 * 60 * 1000;
constexpr ULONGLONG kMaxDescriptorBytes = 128ULL * 1024 * 1024 * 1024;
constexpr DWORD FD_ATTRIBUTES_VALUE = 0x00000004;
constexpr DWORD FD_FILESIZE_VALUE = 0x00000040;
constexpr DWORD FD_PROGRESSUI_VALUE = 0x00004000;
constexpr DWORD FD_UNICODE_VALUE = 0x80000000;

struct ComInit {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ~ComInit() {
        if (SUCCEEDED(hr)) CoUninitialize();
    }
};

template <class T>
struct ComPtr {
    T* p = nullptr;
    ComPtr() = default;
    explicit ComPtr(T* value) : p(value) {}
    ~ComPtr() { reset(); }
    ComPtr(const ComPtr&) = delete;
    ComPtr& operator=(const ComPtr&) = delete;
    ComPtr(ComPtr&& other) noexcept : p(other.p) { other.p = nullptr; }
    ComPtr& operator=(ComPtr&& other) noexcept {
        if (this != &other) {
            reset();
            p = other.p;
            other.p = nullptr;
        }
        return *this;
    }
    void reset(T* value = nullptr) {
        if (p) p->Release();
        p = value;
    }
    T** put() {
        reset();
        return &p;
    }
    T* operator->() const { return p; }
    explicit operator bool() const { return p != nullptr; }
};

struct Medium {
    STGMEDIUM value{};
    ~Medium() {
        if (value.tymed != TYMED_NULL) ReleaseStgMedium(&value);
    }
};

struct Request {
    std::wstring requestPath;
    int protocol = 0;
    std::wstring batchId;
    std::wstring adapter;
    std::wstring targetPath;
    std::wstring targetSourceId;
    std::wstring targetName;
    std::wstring marshalPath;
    std::wstring statePath;
    std::wstring cancelPath;
    std::wstring readyPath;
    std::wstring retryPath;
    bool allowHttp = false;
    int maxConcurrent = 3;
};

struct ItemState {
    std::wstring id;
    std::wstring name;
    std::wstring source;
    std::wstring status = L"Preparing";
    std::wstring error;
    std::wstring errorCode;
    std::wstring finalPath;
    std::wstring created;
    std::wstring started;
    std::wstring finished;
    uint64_t done = 0;
    int64_t total = -1;
    uint64_t speed = 0;
    bool retryable = false;
    bool resumable = false;
};

std::wstring Ini(const std::wstring& file, const wchar_t* section,
                 const wchar_t* key, const wchar_t* fallback = L"") {
    std::vector<wchar_t> buffer(32768);
    GetPrivateProfileStringW(section, key, fallback, buffer.data(),
                             static_cast<DWORD>(buffer.size()), file.c_str());
    return buffer.data();
}

int IniInt(const std::wstring& file, const wchar_t* section,
           const wchar_t* key, int fallback) {
    return GetPrivateProfileIntW(section, key, fallback, file.c_str());
}

std::wstring HResultText(HRESULT hr) {
    wchar_t hex[24]{};
    swprintf_s(hex, L"0x%08X", static_cast<unsigned>(hr));
    wchar_t* system = nullptr;
    FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER |
                       FORMAT_MESSAGE_FROM_SYSTEM |
                       FORMAT_MESSAGE_IGNORE_INSERTS,
                   nullptr, static_cast<DWORD>(hr), 0,
                   reinterpret_cast<wchar_t*>(&system), 0, nullptr);
    std::wstring result = hex;
    if (system) {
        result += L" ";
        result += system;
        LocalFree(system);
    }
    while (!result.empty() &&
           (result.back() == L'\r' || result.back() == L'\n')) {
        result.pop_back();
    }
    return result;
}

std::wstring Win32Text(DWORD code) {
    return HResultText(HRESULT_FROM_WIN32(code));
}

std::wstring Trim(std::wstring value) {
    auto notSpace = [](wchar_t c) { return !iswspace(c); };
    value.erase(value.begin(),
                std::find_if(value.begin(), value.end(), notSpace));
    value.erase(std::find_if(value.rbegin(), value.rend(), notSpace).base(),
                value.end());
    return value;
}

std::wstring Lower(std::wstring value) {
    std::transform(value.begin(), value.end(), value.begin(), towlower);
    return value;
}

std::wstring ReplaceIniUnsafe(std::wstring value) {
    for (auto& ch : value) {
        if (ch == L'\r' || ch == L'\n') ch = L' ';
    }
    return value;
}

bool Exists(const std::wstring& path) {
    return GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

bool IsDirectory(const std::wstring& path) {
    DWORD attr = GetFileAttributesW(path.c_str());
    return attr != INVALID_FILE_ATTRIBUTES &&
           (attr & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

bool IsTemporaryPath(const std::wstring& path) {
    wchar_t buffer[32768]{};
    DWORD length = GetTempPathW(static_cast<DWORD>(std::size(buffer)), buffer);
    if (!length || length >= std::size(buffer)) return false;
    std::wstring root = Lower(std::wstring(buffer, length));
    if (!root.empty() && root.back() != L'\\') root.push_back(L'\\');
    std::wstring candidate = Lower(path);
    return candidate.size() > root.size() &&
           candidate.compare(0, root.size(), root) == 0;
}

uint64_t FileTimeValue(const FILETIME& value) {
    ULARGE_INTEGER result{};
    result.LowPart = value.dwLowDateTime;
    result.HighPart = value.dwHighDateTime;
    return result.QuadPart;
}

std::wstring FullPathForCompare(const std::wstring& path);

struct FileSnapshot {
    std::wstring path;
    uint64_t creation = 0;
    uint64_t modified = 0;
    uint64_t size = 0;
};

FileSnapshot SnapshotFromFindData(const WIN32_FIND_DATAW& data) {
    FileSnapshot snapshot;
    snapshot.creation = FileTimeValue(data.ftCreationTime);
    snapshot.modified = FileTimeValue(data.ftLastWriteTime);
    snapshot.size =
        (static_cast<uint64_t>(data.nFileSizeHigh) << 32) |
        data.nFileSizeLow;
    return snapshot;
}

std::map<std::wstring, FileSnapshot> SnapshotDirectoryFiles(
    const std::wstring& directory) {
    std::map<std::wstring, FileSnapshot> result;
    std::wstring pattern = (fs::path(directory) / L"*").wstring();
    WIN32_FIND_DATAW found{};
    HANDLE search = FindFirstFileW(pattern.c_str(), &found);
    if (search == INVALID_HANDLE_VALUE) return result;
    do {
        if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
        std::wstring path =
            (fs::path(directory) / found.cFileName).wstring();
        FileSnapshot snapshot = SnapshotFromFindData(found);
        snapshot.path = path;
        result[FullPathForCompare(path)] = std::move(snapshot);
    } while (FindNextFileW(search, &found));
    FindClose(search);
    return result;
}

std::wstring FullPathForCompare(const std::wstring& path) {
    DWORD required = GetFullPathNameW(path.c_str(), 0, nullptr, nullptr);
    if (!required) return Lower(path);
    std::wstring result(required, L'\0');
    DWORD written = GetFullPathNameW(path.c_str(), required, result.data(),
                                     nullptr);
    if (!written || written >= required) return Lower(path);
    result.resize(written);
    while (result.size() > 3 &&
           (result.back() == L'\\' || result.back() == L'/'))
        result.pop_back();
    return Lower(result);
}

bool ReadFileIdentity(const std::wstring& path,
                      BY_HANDLE_FILE_INFORMATION& identity) {
    HANDLE handle = CreateFileW(
        path.c_str(), FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    if (handle == INVALID_HANDLE_VALUE) return false;
    bool ok = GetFileInformationByHandle(handle, &identity) != FALSE;
    CloseHandle(handle);
    return ok;
}

bool SameDirectoryPath(const std::wstring& filePath,
                       const std::wstring& targetPath) {
    std::wstring parent = fs::path(filePath).parent_path().wstring();
    if (parent.empty() || targetPath.empty()) return false;
    BY_HANDLE_FILE_INFORMATION left{}, right{};
    if (ReadFileIdentity(parent, left) &&
        ReadFileIdentity(targetPath, right)) {
        const bool leftHasId =
            left.nFileIndexHigh != 0 || left.nFileIndexLow != 0;
        const bool rightHasId =
            right.nFileIndexHigh != 0 || right.nFileIndexLow != 0;
        if (leftHasId && rightHasId) {
            return left.dwVolumeSerialNumber == right.dwVolumeSerialNumber &&
                   left.nFileIndexHigh == right.nFileIndexHigh &&
                   left.nFileIndexLow == right.nFileIndexLow;
        }
    }
    return FullPathForCompare(parent) == FullPathForCompare(targetPath);
}

bool IsCancelled(const Request& request, const std::wstring& itemId = L"") {
    if (!Exists(request.cancelPath)) return false;
    HANDLE file = CreateFileW(request.cancelPath.c_str(), GENERIC_READ,
                              FILE_SHARE_READ | FILE_SHARE_WRITE |
                                  FILE_SHARE_DELETE,
                              nullptr, OPEN_EXISTING, 0, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    char bytes[256]{};
    DWORD read = 0;
    ReadFile(file, bytes, sizeof(bytes) - 1, &read, nullptr);
    CloseHandle(file);
    size_t offset = read >= 3 &&
                    static_cast<unsigned char>(bytes[0]) == 0xEF &&
                    static_cast<unsigned char>(bytes[1]) == 0xBB &&
                    static_cast<unsigned char>(bytes[2]) == 0xBF ? 3 : 0;
    std::wstring value;
    for (size_t i = offset; i < read && bytes[i] != '\r' &&
         bytes[i] != '\n'; ++i)
        value.push_back(static_cast<unsigned char>(bytes[i]));
    value = Trim(value);
    return value == L"BATCH" || (!itemId.empty() && value == itemId);
}

std::wstring NewId(const wchar_t* prefix) {
    GUID guid{};
    CoCreateGuid(&guid);
    wchar_t text[64]{};
    StringFromGUID2(guid, text, 64);
    std::wstring value(text);
    value.erase(std::remove(value.begin(), value.end(), L'{'), value.end());
    value.erase(std::remove(value.begin(), value.end(), L'}'), value.end());
    return std::wstring(prefix) + L"-" + value;
}

class StateWriter {
public:
    explicit StateWriter(const Request& request) : request_(request) {}

    void SetBatch(std::wstring status, std::wstring error = L"") {
        std::lock_guard lock(mu_);
        status_ = std::move(status);
        error_ = std::move(error);
        if (started_.empty() && status_ != L"Queued") started_ = Timestamp();
        if (status_ == L"Completed" || status_ == L"Failed" ||
            status_ == L"Cancelled" || status_ == L"NeedsAttention") {
            finished_ = Timestamp();
        }
        WriteLocked(true);
    }

    size_t Add(ItemState item) {
        std::lock_guard lock(mu_);
        if (item.created.empty()) item.created = Timestamp();
        if (item.started.empty() && item.status != L"Queued")
            item.started = item.created;
        items_.push_back(std::move(item));
        WriteLocked(true);
        return items_.size() - 1;
    }

    void Update(size_t index, const std::function<void(ItemState&)>& update,
                bool force = false) {
        std::lock_guard lock(mu_);
        if (index >= items_.size()) return;
        update(items_[index]);
        auto& item = items_[index];
        if (item.started.empty() && item.status != L"Queued")
            item.started = Timestamp();
        if (item.finished.empty() &&
            (item.status == L"Completed" || item.status == L"Failed" ||
             item.status == L"Cancelled" ||
             item.status == L"NeedsAttention"))
            item.finished = Timestamp();
        WriteLocked(force);
    }

    const std::vector<ItemState>& Items() const { return items_; }

    void Flush() {
        std::lock_guard lock(mu_);
        WriteLocked(true);
    }

private:
    static std::wstring Timestamp() {
        SYSTEMTIME st{};
        GetLocalTime(&st);
        wchar_t text[32]{};
        swprintf_s(text, L"%04u%02u%02u%02u%02u%02u", st.wYear,
                   st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
        return text;
    }

    void WriteLocked(bool force) {
        DWORD now = GetTickCount();
        if (!force && now - lastWrite_ < kStateThrottleMs) return;
        lastWrite_ = now;
        std::wstring temp = request_.statePath + L".writing";
        std::wostringstream out;
        out << L"[Batch]\r\n"
            << L"Protocol=2\r\n"
            << L"HelperVersion=" << kHelperVersion << L"\r\n"
            << L"BatchId=" << request_.batchId << L"\r\n"
            << L"Status=" << status_ << L"\r\n"
            << L"Error=" << ReplaceIniUnsafe(error_) << L"\r\n"
            << L"Started=" << started_ << L"\r\n"
            << L"Finished=" << finished_ << L"\r\n"
            << L"ItemCount=" << items_.size() << L"\r\n";
        for (size_t i = 0; i < items_.size(); ++i) {
            const auto& item = items_[i];
            wchar_t section[32]{};
            swprintf_s(section, L"Item:%03zu", i + 1);
            out << L"\r\n[" << section << L"]\r\n"
                << L"Id=" << item.id << L"\r\n"
                << L"Name=" << ReplaceIniUnsafe(item.name) << L"\r\n"
                << L"Source=" << ReplaceIniUnsafe(item.source) << L"\r\n"
                << L"Status=" << item.status << L"\r\n"
                << L"Done=" << item.done << L"\r\n"
                << L"Total=" << item.total << L"\r\n"
                << L"Speed=" << item.speed << L"\r\n"
                << L"Error=" << ReplaceIniUnsafe(item.error) << L"\r\n"
                << L"ErrorCode=" << item.errorCode << L"\r\n"
                << L"FinalPath=" << item.finalPath << L"\r\n"
                << L"Created=" << item.created << L"\r\n"
                << L"Started=" << item.started << L"\r\n"
                << L"Finished=" << item.finished << L"\r\n"
                << L"Retryable=" << (item.retryable ? 1 : 0) << L"\r\n"
                << L"Resumable=" << (item.resumable ? 1 : 0) << L"\r\n";
        }
        std::wstring text = out.str();
        HANDLE file = CreateFileW(temp.c_str(), GENERIC_WRITE, 0, nullptr,
                                  CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY,
                                  nullptr);
        if (file == INVALID_HANDLE_VALUE) return;
        const wchar_t bom = 0xFEFF;
        DWORD written = 0;
        bool ok = WriteFile(file, &bom, sizeof(bom), &written, nullptr) &&
                  written == sizeof(bom);
        DWORD textBytes = static_cast<DWORD>(
            text.size() * sizeof(wchar_t));
        written = 0;
        ok = ok && WriteFile(file, text.data(), textBytes, &written, nullptr) &&
             written == textBytes && FlushFileBuffers(file);
        CloseHandle(file);
        if (!ok) {
            DeleteFileW(temp.c_str());
            return;
        }
        MoveFileExW(temp.c_str(), request_.statePath.c_str(),
                    MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    }

    const Request& request_;
    std::mutex mu_;
    std::wstring status_ = L"Preparing";
    std::wstring error_;
    std::wstring started_;
    std::wstring finished_;
    std::vector<ItemState> items_;
    DWORD lastWrite_ = 0;
};

struct AsyncOperation {
    ComPtr<IDataObjectAsyncCapability> async;
    bool started = false;
    explicit AsyncOperation(IDataObject* data) {
        if (!data) return;
        if (SUCCEEDED(data->QueryInterface(IID_PPV_ARGS(async.put()))) && async) {
            BOOL mode = FALSE;
            if (SUCCEEDED(async->GetAsyncMode(&mode))) {
                if (!mode) async->SetAsyncMode(TRUE);
                if (SUCCEEDED(async->StartOperation(nullptr))) started = true;
            }
        }
    }
    void Finish(HRESULT hr, DWORD effect) {
        if (started && async) {
            async->EndOperation(hr, nullptr, effect);
            started = false;
        }
    }
    ~AsyncOperation() { Finish(E_ABORT, DROPEFFECT_NONE); }
};

bool ReadAll(const std::wstring& path, std::vector<std::byte>& bytes) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;

    LARGE_INTEGER size{};
    if (!GetFileSizeEx(file, &size) || size.QuadPart <= 0 ||
        size.QuadPart > 16 * 1024 * 1024) {
        CloseHandle(file);
        return false;
    }
    bytes.resize(static_cast<size_t>(size.QuadPart));
    size_t offset = 0;
    while (offset < bytes.size()) {
        const DWORD chunk = static_cast<DWORD>(
            std::min<size_t>(bytes.size() - offset, 1024 * 1024));
        DWORD read = 0;
        if (!ReadFile(file, bytes.data() + offset, chunk, &read, nullptr) ||
            read == 0) {
            CloseHandle(file);
            bytes.clear();
            return false;
        }
        offset += read;
    }
    CloseHandle(file);
    return true;
}

HRESULT UnmarshalDataObject(const Request& request,
                            ComPtr<IDataObject>& object) {
    std::vector<std::byte> bytes;
    if (!ReadAll(request.marshalPath, bytes))
        return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
    if (!memory) return E_OUTOFMEMORY;
    void* locked = GlobalLock(memory);
    memcpy(locked, bytes.data(), bytes.size());
    GlobalUnlock(memory);
    ComPtr<IStream> stream;
    HRESULT hr = CreateStreamOnHGlobal(memory, TRUE, stream.put());
    if (FAILED(hr)) {
        GlobalFree(memory);
        return hr;
    }
    LARGE_INTEGER start{};
    stream->Seek(start, STREAM_SEEK_SET, nullptr);
    return CoUnmarshalInterface(stream.p, IID_PPV_ARGS(object.put()));
}

std::wstring SanitizeName(std::wstring name, std::wstring fallback) {
    name = fs::path(name).filename().wstring();
    for (auto& c : name) {
        if (c < 32 || wcschr(L"<>:\"/\\|?*", c)) c = L'_';
    }
    while (!name.empty() && (name.back() == L'.' || name.back() == L' '))
        name.pop_back();
    while (!name.empty() && name.front() == L' ') name.erase(name.begin());
    if (name.empty()) name = std::move(fallback);
    std::wstring stem = Lower(fs::path(name).stem().wstring());
    static const wchar_t* reserved[] = {
        L"con", L"prn", L"aux", L"nul", L"com1", L"com2", L"com3",
        L"com4", L"com5", L"com6", L"com7", L"com8", L"com9",
        L"lpt1", L"lpt2", L"lpt3", L"lpt4", L"lpt5", L"lpt6",
        L"lpt7", L"lpt8", L"lpt9"};
    for (auto* value : reserved) {
        if (stem == value) {
            name += L"_";
            break;
        }
    }
    if (name.size() > 180) {
        auto ext = fs::path(name).extension().wstring();
        auto base = fs::path(name).stem().wstring();
        size_t keep = ext.size() < 40 ? 180 - ext.size() : 140;
        name = base.substr(0, keep) + ext.substr(0, 40);
    }
    return name;
}

std::wstring UniqueFinalPath(const std::wstring& target,
                             const std::wstring& suggested) {
    fs::path requested = fs::path(target) / suggested;
    if (!Exists(requested.wstring())) return requested.wstring();
    auto stem = requested.stem().wstring();
    auto ext = requested.extension().wstring();
    for (unsigned i = 2; i < 100000; ++i) {
        fs::path candidate = fs::path(target) /
            (stem + L" (" + std::to_wstring(i) + L")" + ext);
        if (!Exists(candidate.wstring())) return candidate.wstring();
    }
    return L"";
}

struct Destination {
    std::wstring part;
    std::wstring final;
    HANDLE file = INVALID_HANDLE_VALUE;
    ~Destination() {
        if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
        if (!part.empty() && Exists(part)) DeleteFileW(part.c_str());
    }
};

HRESULT OpenDestination(const Request& request, const std::wstring& name,
                        Destination& dest) {
    std::wstring safe = SanitizeName(name, L"拖入文件");
    std::wstring final = UniqueFinalPath(request.targetPath, safe);
    if (final.empty()) return HRESULT_FROM_WIN32(ERROR_FILE_EXISTS);
    dest.final = final;
    for (unsigned i = 0; i < 1000; ++i) {
        dest.part = final + L"." + request.batchId.substr(0, 12);
        if (i) dest.part += L"-" + std::to_wstring(i);
        dest.part += kPartSuffix;
        dest.file = CreateFileW(dest.part.c_str(), GENERIC_WRITE,
                                FILE_SHARE_READ, nullptr, CREATE_NEW,
                                FILE_ATTRIBUTE_HIDDEN |
                                    FILE_ATTRIBUTE_TEMPORARY,
                                nullptr);
        if (dest.file != INVALID_HANDLE_VALUE) return S_OK;
        if (GetLastError() != ERROR_FILE_EXISTS)
            return HRESULT_FROM_WIN32(GetLastError());
    }
    return HRESULT_FROM_WIN32(ERROR_FILE_EXISTS);
}

HRESULT OpenReplacementDestination(const Request& request,
                                   const std::wstring& existingTarget,
                                   Destination& dest) {
    if (!SameDirectoryPath(existingTarget, request.targetPath) ||
        !Exists(existingTarget) || IsDirectory(existingTarget))
        return HRESULT_FROM_WIN32(ERROR_INVALID_TARGET_HANDLE);
    dest.final = existingTarget;
    for (unsigned i = 0; i < 1000; ++i) {
        dest.part = existingTarget + L"." + request.batchId.substr(0, 12);
        if (i) dest.part += L"-" + std::to_wstring(i);
        dest.part += kPartSuffix;
        dest.file = CreateFileW(dest.part.c_str(), GENERIC_WRITE,
                                FILE_SHARE_READ, nullptr, CREATE_NEW,
                                FILE_ATTRIBUTE_HIDDEN |
                                    FILE_ATTRIBUTE_TEMPORARY,
                                nullptr);
        if (dest.file != INVALID_HANDLE_VALUE) return S_OK;
        if (GetLastError() != ERROR_FILE_EXISTS)
            return HRESULT_FROM_WIN32(GetLastError());
    }
    return HRESULT_FROM_WIN32(ERROR_FILE_EXISTS);
}

HRESULT FinalizeDestination(Destination& dest) {
    if (dest.file == INVALID_HANDLE_VALUE) return E_HANDLE;
    if (!FlushFileBuffers(dest.file))
        return HRESULT_FROM_WIN32(GetLastError());
    CloseHandle(dest.file);
    dest.file = INVALID_HANDLE_VALUE;
    for (unsigned attempt = 0; attempt < 20; ++attempt) {
        if (MoveFileExW(dest.part.c_str(), dest.final.c_str(),
                        MOVEFILE_WRITE_THROUGH)) {
            dest.part.clear();
            SetFileAttributesW(dest.final.c_str(), FILE_ATTRIBUTE_NORMAL);
            return S_OK;
        }
        if (GetLastError() == ERROR_ALREADY_EXISTS ||
            GetLastError() == ERROR_FILE_EXISTS) {
            auto name = fs::path(dest.final).filename().wstring();
            dest.final = UniqueFinalPath(fs::path(dest.final).parent_path().wstring(),
                                         name);
            continue;
        }
        return HRESULT_FROM_WIN32(GetLastError());
    }
    return HRESULT_FROM_WIN32(ERROR_FILE_EXISTS);
}

HRESULT FinalizeReplacement(Destination& dest) {
    if (dest.file == INVALID_HANDLE_VALUE) return E_HANDLE;
    if (!FlushFileBuffers(dest.file))
        return HRESULT_FROM_WIN32(GetLastError());
    CloseHandle(dest.file);
    dest.file = INVALID_HANDLE_VALUE;
    if (!MoveFileExW(dest.part.c_str(), dest.final.c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
        return HRESULT_FROM_WIN32(GetLastError());
    dest.part.clear();
    SetFileAttributesW(dest.final.c_str(), FILE_ATTRIBUTE_NORMAL);
    return S_OK;
}

void PreserveZoneIdentifier(const std::wstring& source,
                            const std::wstring& destination) {
    std::wstring sourceAds = source + L":Zone.Identifier";
    std::wstring destinationAds = destination + L":Zone.Identifier";
    CopyFileW(sourceAds.c_str(), destinationAds.c_str(), FALSE);
}

class Progress {
public:
    Progress(const Request& request, StateWriter& state, size_t index,
             std::wstring itemId)
        : request_(request), state_(state), index_(index),
          itemId_(std::move(itemId)),
          started_(std::chrono::steady_clock::now()),
          windowStarted_(started_) {}

    bool Add(uint64_t amount) {
        done_ += amount;
        windowBytes_ += amount;
        auto now = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                           now - windowStarted_).count();
        if (elapsed >= 250) {
            speed_ = elapsed ? windowBytes_ * 1000 / elapsed : 0;
            windowStarted_ = now;
            windowBytes_ = 0;
            state_.Update(index_, [&](ItemState& item) {
                item.done = done_;
                item.speed = speed_;
                item.status = L"Receiving";
            });
        }
        return !IsCancelled(request_, itemId_);
    }

    uint64_t done() const { return done_; }
    uint64_t averageSpeed() const {
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                           std::chrono::steady_clock::now() - started_).count();
        return done_
            ? done_ * 1000 /
                static_cast<uint64_t>(std::max<int64_t>(1, elapsed))
            : 0;
    }

private:
    const Request& request_;
    StateWriter& state_;
    size_t index_;
    std::wstring itemId_;
    std::chrono::steady_clock::time_point started_;
    std::chrono::steady_clock::time_point windowStarted_;
    uint64_t done_ = 0;
    uint64_t speed_ = 0;
    uint64_t windowBytes_ = 0;
};

HRESULT WriteBytes(HANDLE file, const void* data, size_t size,
                   Progress& progress) {
    const auto* cursor = static_cast<const std::byte*>(data);
    while (size) {
        DWORD piece = static_cast<DWORD>(
            std::min<size_t>(size, kChunkSize));
        DWORD written = 0;
        if (!WriteFile(file, cursor, piece, &written, nullptr))
            return HRESULT_FROM_WIN32(GetLastError());
        if (!written) return HRESULT_FROM_WIN32(ERROR_WRITE_FAULT);
        cursor += written;
        size -= written;
        if (!progress.Add(written)) return HRESULT_FROM_WIN32(ERROR_CANCELLED);
    }
    return S_OK;
}

HRESULT CopyStreamToFile(IStream* stream, HANDLE file, Progress& progress) {
    std::vector<std::byte> buffer(kChunkSize);
    for (;;) {
        ULONG read = 0;
        HRESULT hr = stream->Read(buffer.data(),
                                  static_cast<ULONG>(buffer.size()), &read);
        if (FAILED(hr)) return hr;
        if (read) {
            hr = WriteBytes(file, buffer.data(), read, progress);
            if (FAILED(hr)) return hr;
        }
        if (hr == S_FALSE || read == 0) return S_OK;
    }
}

HRESULT SaveMedium(const Request& request, StateWriter& state, size_t index,
                   const std::wstring& itemId, STGMEDIUM& medium,
                   Destination& dest, uint64_t& transferred,
                   uint64_t& averageSpeed) {
    Progress progress(request, state, index, itemId);
    HRESULT hr = DV_E_TYMED;
    if (medium.tymed == TYMED_ISTREAM && medium.pstm) {
        hr = CopyStreamToFile(medium.pstm, dest.file, progress);
    } else if (medium.tymed == TYMED_HGLOBAL && medium.hGlobal) {
        SIZE_T size = GlobalSize(medium.hGlobal);
        void* data = GlobalLock(medium.hGlobal);
        if (!data && size) return HRESULT_FROM_WIN32(GetLastError());
        hr = WriteBytes(dest.file, data, size, progress);
        if (data) GlobalUnlock(medium.hGlobal);
    } else if (medium.tymed == TYMED_ISTORAGE) {
        hr = HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
    }
    transferred = progress.done();
    averageSpeed = progress.averageSpeed();
    return hr;
}

bool IsVirtualDirectory(const FILEDESCRIPTORW& descriptor) {
    return (descriptor.dwFlags & FD_ATTRIBUTES_VALUE) &&
           (descriptor.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY);
}

int64_t DescriptorSize(const FILEDESCRIPTORW& descriptor) {
    if (!(descriptor.dwFlags & FD_FILESIZE_VALUE)) return -1;
    const uint64_t size =
        (static_cast<uint64_t>(descriptor.nFileSizeHigh) << 32) |
        descriptor.nFileSizeLow;
    if (size > static_cast<uint64_t>(INT64_MAX)) return -2;
    return static_cast<int64_t>(size);
}

HRESULT MarkInternetOrigin(const std::wstring& path,
                           const std::wstring& sourceUrl) {
    static const CLSID clsidAttachment = {
        0x4125dd96, 0xe03a, 0x4103,
        {0x8f, 0x70, 0xe0, 0x59, 0x7d, 0x80, 0x3b, 0x9c}};
    ComPtr<IAttachmentExecute> attachment;
    HRESULT hr = CoCreateInstance(clsidAttachment, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(attachment.put()));
    if (FAILED(hr)) {
        // FAT volumes and some network shares do not support ADS. Return the
        // error so UI can report that the file exists but security marking
        // needs attention.
        return hr;
    }
    if (FAILED(hr = attachment->SetLocalPath(path.c_str()))) return hr;
    if (!sourceUrl.empty() &&
        FAILED(hr = attachment->SetSource(sourceUrl.c_str()))) return hr;
    return attachment->Save();
}

std::wstring ReadUrlFromDataObject(IDataObject* data);

HRESULT WaitForPathReady(
    const Request& request, const std::wstring& source,
    const std::wstring& itemId, uint64_t& finalSize,
    const std::function<void(uint64_t)>& onProgress = {}) {
    DWORD started = GetTickCount();
    for (;;) {
        if (IsCancelled(request, itemId))
            return HRESULT_FROM_WIN32(ERROR_CANCELLED);

        // A delayed-render browser file may still be owned by a producer.
        // Omitting FILE_SHARE_WRITE makes this open succeed only after that
        // producer has finished, so quality and byte-size comparisons never
        // use an incomplete snapshot.
        HANDLE ready = CreateFileW(
            source.c_str(), GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_DELETE,
            nullptr, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
        if (ready != INVALID_HANDLE_VALUE) {
            LARGE_INTEGER size{};
            bool measured = GetFileSizeEx(ready, &size) != FALSE;
            DWORD measureError = measured ? ERROR_SUCCESS : GetLastError();
            CloseHandle(ready);
            if (!measured) return HRESULT_FROM_WIN32(measureError);
            finalSize = static_cast<uint64_t>(size.QuadPart);
            return S_OK;
        }

        DWORD error = GetLastError();
        if (error != ERROR_SHARING_VIOLATION &&
            error != ERROR_LOCK_VIOLATION &&
            error != ERROR_FILE_NOT_FOUND &&
            error != ERROR_PATH_NOT_FOUND)
            return HRESULT_FROM_WIN32(error);
        if (GetTickCount() - started >= kAdoptSourceTimeoutMs)
            return HRESULT_FROM_WIN32(ERROR_TIMEOUT);

        WIN32_FILE_ATTRIBUTE_DATA info{};
        uint64_t observed = 0;
        if (GetFileAttributesExW(source.c_str(), GetFileExInfoStandard,
                                 &info)) {
            observed =
                (static_cast<uint64_t>(info.nFileSizeHigh) << 32) |
                info.nFileSizeLow;
        }
        if (onProgress) onProgress(observed);
        Sleep(100);
    }
}

HRESULT WaitForSourceReady(const Request& request,
                           const std::wstring& source,
                           StateWriter& state, size_t row,
                           const std::wstring& itemId,
                           uint64_t& finalSize) {
    return WaitForPathReady(
        request, source, itemId, finalSize,
        [&](uint64_t observed) {
            state.Update(row, [&](ItemState& value) {
                value.status = L"Receiving";
                value.done = observed;
                value.total = -1;
                value.source = L"来源正在直接写入目标文件夹";
            });
        });
}

bool IsLikelyImageName(const std::wstring& name) {
    const std::wstring extension =
        Lower(fs::path(name).extension().wstring());
    static const wchar_t* values[] = {
        L".jpg", L".jpeg", L".jpe", L".png", L".gif", L".webp",
        L".bmp", L".dib", L".tif", L".tiff", L".ico", L".heic",
        L".heif", L".avif"};
    return std::find_if(
               std::begin(values), std::end(values),
               [&](const wchar_t* value) { return extension == value; }) !=
           std::end(values);
}

std::wstring CanonicalDuplicateImageName(const std::wstring& name) {
    fs::path path(name);
    std::wstring stem = path.stem().wstring();
    const std::wstring extension = path.extension().wstring();
    if (stem.size() >= 4 && stem.back() == L')') {
        size_t marker = stem.rfind(L" (");
        if (marker != std::wstring::npos && marker + 2 < stem.size() - 1) {
            bool numeric = true;
            for (size_t i = marker + 2; i + 1 < stem.size(); ++i) {
                if (!iswdigit(stem[i])) {
                    numeric = false;
                    break;
                }
            }
            if (numeric) stem.resize(marker);
        }
    }
    return stem + extension;
}

struct ImageQuality {
    bool decoded = false;
    UINT width = 0;
    UINT height = 0;
    uint64_t pixels = 0;
};

ImageQuality ReadImageQuality(const std::wstring& path) {
    ImageQuality quality;
    ComPtr<IWICImagingFactory> factory;
    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(factory.put()));
    if (FAILED(hr)) return quality;
    ComPtr<IWICBitmapDecoder> decoder;
    hr = factory->CreateDecoderFromFilename(
        path.c_str(), nullptr, GENERIC_READ,
        WICDecodeMetadataCacheOnDemand, decoder.put());
    if (FAILED(hr)) return quality;
    ComPtr<IWICBitmapFrameDecode> frame;
    if (FAILED(decoder->GetFrame(0, frame.put()))) return quality;
    if (FAILED(frame->GetSize(&quality.width, &quality.height)) ||
        !quality.width || !quality.height)
        return quality;
    quality.decoded = true;
    quality.pixels = static_cast<uint64_t>(quality.width) *
                     static_cast<uint64_t>(quality.height);
    return quality;
}

struct ImageReconcilePlan {
    size_t row = 0;
    std::wstring itemId;
    std::wstring canonicalName;
    std::wstring finalPath;
    std::wstring networkOrigin;
    ImageQuality quality;
    uint64_t size = 0;
};

struct ImageReconcileContext {
    std::map<std::wstring, FileSnapshot> baseline;
    std::vector<ImageReconcilePlan> plans;
};

HRESULT ExtractVirtual(const Request& request, IDataObject* data,
                       StateWriter& state, int& succeeded, int& failed) {
    UINT descriptorFormat = RegisterClipboardFormatW(CFSTR_FILEDESCRIPTORW);
    UINT contentsFormat = RegisterClipboardFormatW(CFSTR_FILECONTENTS);
    FORMATETC descriptorEtc{static_cast<CLIPFORMAT>(descriptorFormat), nullptr,
                            DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    Medium descriptors;
    HRESULT hr = data->GetData(&descriptorEtc, &descriptors.value);
    if (FAILED(hr)) return hr;
    if (descriptors.value.tymed != TYMED_HGLOBAL ||
        !descriptors.value.hGlobal) return DV_E_TYMED;
    SIZE_T bytes = GlobalSize(descriptors.value.hGlobal);
    auto* group = static_cast<FILEGROUPDESCRIPTORW*>(
        GlobalLock(descriptors.value.hGlobal));
    if (!group) return HRESULT_FROM_WIN32(GetLastError());
    UINT count = group->cItems;
    if (count > 10000) {
        GlobalUnlock(descriptors.value.hGlobal);
        return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
    }
    size_t required = offsetof(FILEGROUPDESCRIPTORW, fgd) +
                      static_cast<size_t>(count) * sizeof(FILEDESCRIPTORW);
    if (bytes < required) {
        GlobalUnlock(descriptors.value.hGlobal);
        return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
    }
    std::vector<FILEDESCRIPTORW> list(group->fgd, group->fgd + count);
    GlobalUnlock(descriptors.value.hGlobal);
    if (list.empty()) return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
    std::wstring networkOrigin = ReadUrlFromDataObject(data);
    std::vector<std::wstring> descriptorNames(count);
    std::vector<int64_t> descriptorSizes(count, -1);
    std::vector<bool> validDescriptorNames(count, false);
    std::vector<bool> keepDescriptor(count, true);
    for (UINT i = 0; i < count; ++i) {
        const auto& descriptor = list[i];
        const size_t rawNameLength =
            wcsnlen_s(descriptor.cFileName, std::size(descriptor.cFileName));
        if (rawNameLength == std::size(descriptor.cFileName))
            continue;
        descriptorNames[i] = SanitizeName(
            std::wstring(descriptor.cFileName, rawNameLength), L"拖入文件");
        descriptorSizes[i] = DescriptorSize(descriptor);
        validDescriptorNames[i] = true;
    }

    // An image nested in an HTML <a> can make Chromium expose two virtual
    // FILEDESCRIPTOR entries: one for the image and one derived from the link.
    // The source also exposes an explicit URL in that case. Suppress duplicate
    // safe filenames before GetData(FILECONTENTS) so the second network-backed
    // stream is never requested. Non-web virtual file drags retain all entries.
    if (!networkOrigin.empty()) {
        std::map<std::wstring, size_t> bestByName;
        for (size_t i = 0; i < list.size(); ++i) {
            if (!validDescriptorNames[i] || descriptorNames[i].empty() ||
                IsVirtualDirectory(list[i]))
                continue;
            std::wstring key = Lower(descriptorNames[i]);
            auto found = bestByName.find(key);
            if (found == bestByName.end()) {
                bestByName[key] = i;
                continue;
            }
            size_t currentIndex = found->second;
            const int64_t currentSize = descriptorSizes[currentIndex];
            const int64_t candidateSize = descriptorSizes[i];
            const bool candidateIsBetter =
                candidateSize >= 0 &&
                (currentSize < 0 || candidateSize > currentSize);
            if (candidateIsBetter) {
                keepDescriptor[currentIndex] = false;
                found->second = i;
            } else {
                keepDescriptor[i] = false;
            }
        }
    }

    for (UINT i = 0; i < count; ++i) {
        if (!keepDescriptor[i]) continue;
        const auto& descriptor = list[i];
        const size_t rawNameLength =
            wcsnlen_s(descriptor.cFileName, std::size(descriptor.cFileName));
        const bool unterminatedName =
            rawNameLength == std::size(descriptor.cFileName);
        ItemState item;
        item.id = NewId(L"item");
        item.name = unterminatedName
            ? L"无效文件名"
            : descriptorNames[i];
        item.source = L"虚拟文件";
        item.total = descriptorSizes[i];
        size_t row = state.Add(item);
        if (unterminatedName) {
            ++failed;
            state.Update(row, [](ItemState& value) {
                value.status = L"Failed";
                value.errorCode = L"InvalidDescriptorName";
                value.error = L"文件描述符中的名称没有正确终止。";
            }, true);
            continue;
        }
        if (IsVirtualDirectory(descriptor)) {
            ++failed;
            state.Update(row, [](ItemState& value) {
                value.status = L"Failed";
                value.errorCode = L"VirtualDirectory";
                value.error =
                    L"当前来源提供的是虚拟文件夹，PopDrop 本期只支持拖入文件。";
            }, true);
            continue;
        }
        if (item.total == -2 ||
            item.total > static_cast<int64_t>(kMaxDescriptorBytes)) {
            ++failed;
            state.Update(row, [](ItemState& value) {
                value.status = L"Failed";
                value.errorCode = L"DescriptorTooLarge";
                value.error = L"文件描述符声明的大小超过安全限制。";
            }, true);
            continue;
        }
        if (IsCancelled(request, item.id)) {
            state.Update(row, [](ItemState& value) {
                value.status = L"Cancelled";
                value.error = L"用户取消。";
            }, true);
            continue;
        }
        FORMATETC contentEtc{static_cast<CLIPFORMAT>(contentsFormat), nullptr,
                             DVASPECT_CONTENT, static_cast<LONG>(i),
                             TYMED_ISTREAM | TYMED_HGLOBAL | TYMED_ISTORAGE};
        Medium content;
        hr = data->GetData(&contentEtc, &content.value);
        if (FAILED(hr)) {
            ++failed;
            state.Update(row, [&](ItemState& value) {
                value.status = L"Failed";
                value.errorCode = L"FileContentsGetData";
                value.error = L"读取虚拟文件流失败：" + HResultText(hr);
            }, true);
            continue;
        }
        if (content.value.tymed == TYMED_ISTORAGE) {
            ++failed;
            state.Update(row, [](ItemState& value) {
                value.status = L"Failed";
                value.errorCode = L"TymedStorageUnsupported";
                value.error =
                    L"来源仅提供 TYMED_ISTORAGE；当前版本支持 IStream 和 HGLOBAL。";
            }, true);
            continue;
        }
        Destination destination;
        uint64_t transferred = 0;
        uint64_t averageSpeed = 0;
        hr = OpenDestination(request, item.name, destination);
        if (SUCCEEDED(hr))
            hr = SaveMedium(request, state, row, item.id,
                            content.value, destination,
                            transferred, averageSpeed);
        if (SUCCEEDED(hr)) {
            state.Update(row, [](ItemState& value) {
                value.status = L"Finalizing";
            }, true);
            hr = FinalizeDestination(destination);
        }
        if (SUCCEEDED(hr)) {
            ++succeeded;
            HRESULT mark = networkOrigin.empty()
                ? S_OK : MarkInternetOrigin(destination.final, networkOrigin);
            if (FAILED(mark)) ++failed;
            state.Update(row, [&](ItemState& value) {
                value.status = FAILED(mark) ? L"NeedsAttention" : L"Completed";
                value.done = transferred;
                if (value.total < 0)
                    value.total = static_cast<int64_t>(transferred);
                value.speed = averageSpeed;
                value.finalPath = destination.final;
                if (FAILED(mark))
                    value.error =
                        L"文件已保存，但 Windows 网络来源安全标记失败：" +
                        HResultText(mark);
            }, true);
        } else {
            if (HRESULT_CODE(hr) == ERROR_CANCELLED) {
                state.Update(row, [](ItemState& value) {
                    value.status = L"Cancelled";
                    value.errorCode = L"Cancelled";
                    value.error = L"用户取消。";
                }, true);
            } else {
                ++failed;
                state.Update(row, [&](ItemState& value) {
                    value.status = L"Failed";
                    value.errorCode = L"VirtualWriteFailed";
                    value.error = L"保存虚拟文件失败：" + HResultText(hr);
                }, true);
            }
        }
    }
    return succeeded ? S_OK : (failed ? E_FAIL : S_FALSE);
}

HRESULT ExtractHDrop(const Request& request, IDataObject* data,
                     StateWriter& state, int& succeeded, int& failed,
                     ImageReconcileContext& reconcile) {
    // This is a lightweight explicit-web-origin read. For async Chromium
    // HDROP, the UI process deliberately does not call GetData(CF_HDROP);
    // this helper owns the one and only delayed-render request below.
    std::wstring networkOrigin = ReadUrlFromDataObject(data);
    const auto targetBefore = SnapshotDirectoryFiles(request.targetPath);
    WIN32_FILE_ATTRIBUTE_DATA requestInfo{};
    uint64_t requestCreated = 0;
    if (GetFileAttributesExW(request.requestPath.c_str(),
                             GetFileExInfoStandard, &requestInfo))
        requestCreated = FileTimeValue(requestInfo.ftCreationTime);
    FORMATETC format{CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    Medium medium;
    HRESULT hr = data->GetData(&format, &medium.value);
    if (FAILED(hr)) return hr;
    HDROP drop = static_cast<HDROP>(medium.value.hGlobal);
    UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
    struct SourceEntry {
        std::wstring path;
        std::wstring name;
        std::wstring outputName;
        std::wstring replacementTarget;
        std::vector<std::wstring> redundantTargets;
        uint64_t size = 0;
        bool sizeKnown = false;
        bool directory = false;
        bool temporary = false;
        bool alreadyInTarget = false;
        bool settledChecked = false;
        bool ready = false;
        HRESULT readyHr = S_OK;
        ImageQuality imageQuality;
        bool keep = true;
    };
    std::vector<SourceEntry> sources;
    for (UINT i = 0; i < count; ++i) {
        UINT length = DragQueryFileW(drop, i, nullptr, 0);
        std::wstring source(length + 1, L'\0');
        DragQueryFileW(drop, i, source.data(), length + 1);
        source.resize(length);
        SourceEntry entry;
        entry.path = source;
        entry.name = fs::path(source).filename().wstring();
        entry.outputName = entry.name;
        entry.temporary = IsTemporaryPath(source);
        entry.alreadyInTarget =
            SameDirectoryPath(source, request.targetPath);
        WIN32_FILE_ATTRIBUTE_DATA dataInfo{};
        if (GetFileAttributesExW(source.c_str(), GetFileExInfoStandard,
                                 &dataInfo)) {
            entry.directory =
                (dataInfo.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
            if (!entry.directory) {
                entry.size =
                    (static_cast<uint64_t>(dataInfo.nFileSizeHigh) << 32) |
                    dataInfo.nFileSizeLow;
                entry.sizeKnown = true;
            }
        }
        sources.push_back(std::move(entry));
    }

    // Chromium-style webpage image drags can expose both a thumbnail and the
    // full image as delayed CF_HDROP paths. One path may already be in the
    // target and still be growing while a higher-resolution sibling appears
    // later in browser cache. Wait for every same-image candidate to become
    // readable before comparing it. Image pixel area wins, then byte size,
    // then an existing target path as a no-copy tie-breaker. A numeric Shell
    // suffix such as "image (1).jpg" is treated as the same web-image name.
    // Stable Explorer/QQ/WeChat HDROP stays on the original IFileOperation
    // path and never enters this helper policy.
    std::map<std::wstring, std::vector<size_t>> groups;
    for (size_t i = 0; i < sources.size(); ++i) {
        auto& source = sources[i];
        if (source.directory || source.name.empty())
            continue;
        const bool image = IsLikelyImageName(source.name);
        if (!image && networkOrigin.empty() && !source.temporary &&
            !source.alreadyInTarget)
            continue;
        std::wstring canonical = image
            ? CanonicalDuplicateImageName(source.name) : source.name;
        source.outputName = canonical;
        groups[Lower(canonical)].push_back(i);
    }

    auto settleSource = [&](SourceEntry& source) {
        uint64_t settledSize = 0;
        source.settledChecked = true;
        source.readyHr = WaitForPathReady(
            request, source.path, L"", settledSize);
        source.ready = SUCCEEDED(source.readyHr);
        if (!source.ready) return;
        source.size = settledSize;
        source.sizeKnown = true;
        if (IsLikelyImageName(source.name))
            source.imageQuality = ReadImageQuality(source.path);
    };

    bool hasWebImageGroup = false;
    for (auto& group : groups) {
        auto& indexes = group.second;
        const bool image = !indexes.empty() &&
            IsLikelyImageName(sources[indexes.front()].name);
        if (image) hasWebImageGroup = true;
        if (indexes.size() < 2 && !image) continue;
        state.SetBatch(L"Receiving");
        for (size_t index : indexes)
            settleSource(sources[index]);
    }

    // Chromium may create a first thumbnail in its default download folder as
    // a side effect of rendering CF_HDROP without listing that path in the
    // returned DROPFILES block. If the folder is also PopDrop's target, the
    // old code could only see the later cache/full-size path and auto-rename
    // it beside that untracked thumbnail. Discover only very recent target
    // images whose canonical name matches this drop, then compare them with
    // the returned candidates. The pre-GetData directory snapshot prevents
    // unrelated pre-existing files from being inferred as drop candidates.
    if (hasWebImageGroup) {
        std::wstring pattern =
            (fs::path(request.targetPath) / L"*").wstring();
        WIN32_FIND_DATAW found{};
        HANDLE search = FindFirstFileW(pattern.c_str(), &found);
        if (search != INVALID_HANDLE_VALUE) {
            do {
                if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
                    !IsLikelyImageName(found.cFileName))
                    continue;
                std::wstring name = found.cFileName;
                std::wstring key = Lower(
                    CanonicalDuplicateImageName(name));
                auto group = groups.find(key);
                if (group == groups.end()) continue;
                std::wstring path =
                    (fs::path(request.targetPath) / name).wstring();
                const FileSnapshot current =
                    SnapshotFromFindData(found);
                const auto baseline =
                    targetBefore.find(FullPathForCompare(path));
                const bool changedSinceTakeover =
                    baseline == targetBefore.end() ||
                    baseline->second.creation != current.creation ||
                    baseline->second.modified != current.modified ||
                    baseline->second.size != current.size;
                const bool createdForRequest =
                    requestCreated != 0 &&
                    current.creation >= requestCreated;
                if (!changedSinceTakeover && !createdForRequest)
                    continue;
                bool alreadyListed = false;
                for (const auto& source : sources) {
                    if (FullPathForCompare(source.path) ==
                        FullPathForCompare(path)) {
                        alreadyListed = true;
                        break;
                    }
                }
                if (alreadyListed) continue;

                SourceEntry sideEffect;
                sideEffect.path = path;
                sideEffect.name = name;
                sideEffect.outputName =
                    CanonicalDuplicateImageName(name);
                sideEffect.alreadyInTarget = true;
                sideEffect.size =
                    (static_cast<uint64_t>(found.nFileSizeHigh) << 32) |
                    found.nFileSizeLow;
                sideEffect.sizeKnown = true;
                sources.push_back(std::move(sideEffect));
                const size_t index = sources.size() - 1;
                settleSource(sources[index]);
                group->second.push_back(index);
            } while (FindNextFileW(search, &found));
            FindClose(search);
        }
    }

    for (auto& group : groups) {
        auto& indexes = group.second;
        if (indexes.size() < 2) continue;
        size_t best = indexes.front();
        auto candidateIsBetter = [&](const SourceEntry& candidate,
                                     const SourceEntry& current) {
            if (candidate.ready != current.ready) return candidate.ready;
            if (candidate.imageQuality.decoded &&
                current.imageQuality.decoded &&
                candidate.imageQuality.pixels !=
                    current.imageQuality.pixels)
                return candidate.imageQuality.pixels >
                       current.imageQuality.pixels;
            if (candidate.imageQuality.decoded !=
                current.imageQuality.decoded)
                return candidate.imageQuality.decoded;
            if (candidate.sizeKnown != current.sizeKnown)
                return candidate.sizeKnown;
            if (candidate.sizeKnown && candidate.size != current.size)
                return candidate.size > current.size;
            return candidate.alreadyInTarget &&
                   !current.alreadyInTarget;
        };
        for (size_t index : indexes) {
            if (index == best) continue;
            if (candidateIsBetter(sources[index], sources[best]))
                best = index;
        }
        for (size_t index : indexes)
            sources[index].keep = index == best;

        auto& chosen = sources[best];
        std::wstring replacement;
        for (size_t index : indexes) {
            if (!sources[index].alreadyInTarget || index == best) continue;
            if (replacement.empty())
                replacement = sources[index].path;
            if (Lower(sources[index].name) ==
                Lower(chosen.outputName))
                replacement = sources[index].path;
        }
        if (!chosen.alreadyInTarget)
            chosen.replacementTarget = replacement;
        for (size_t index : indexes) {
            if (index == best || !sources[index].alreadyInTarget)
                continue;
            if (!chosen.replacementTarget.empty() &&
                FullPathForCompare(sources[index].path) ==
                    FullPathForCompare(chosen.replacementTarget))
                continue;
            chosen.redundantTargets.push_back(sources[index].path);
        }
    }

    for (const auto& sourceEntry : sources) {
        if (!sourceEntry.keep) continue;
        const std::wstring& source = sourceEntry.path;
        ItemState item;
        item.id = NewId(L"item");
        item.name = sourceEntry.outputName;
        item.source = L"本地临时文件";
        if (sourceEntry.sizeKnown &&
            sourceEntry.size <= static_cast<uint64_t>(INT64_MAX))
            item.total = static_cast<int64_t>(sourceEntry.size);
        size_t row = state.Add(item);
        if (IsDirectory(source)) {
            ++failed;
            state.Update(row, [](ItemState& value) {
                value.status = L"Failed";
                value.errorCode = L"AsyncDirectoryUnsupported";
                value.error =
                    L"异步来源提供了文件夹；请从资源管理器拖入本地文件夹。";
            }, true);
            continue;
        }
        if (sourceEntry.settledChecked && !sourceEntry.ready) {
            hr = sourceEntry.readyHr;
            if (HRESULT_CODE(hr) != ERROR_CANCELLED) ++failed;
            state.Update(row, [&](ItemState& value) {
                value.status = HRESULT_CODE(hr) == ERROR_CANCELLED
                    ? L"Cancelled" : L"Failed";
                value.errorCode = HRESULT_CODE(hr) == ERROR_CANCELLED
                    ? L"Cancelled" : L"SourceNotReady";
                value.error = HRESULT_CODE(hr) == ERROR_CANCELLED
                    ? L"用户取消。"
                    : L"网页图片候选未能完成写入：" + HResultText(hr);
            }, true);
            continue;
        }
        auto removeRedundantTargets = [&]() -> HRESULT {
            for (const auto& redundant : sourceEntry.redundantTargets) {
                if (FullPathForCompare(redundant) ==
                    FullPathForCompare(source))
                    continue;
                if (Exists(redundant) && !DeleteFileW(redundant.c_str()))
                    return HRESULT_FROM_WIN32(GetLastError());
            }
            return S_OK;
        };
        if (sourceEntry.alreadyInTarget) {
            uint64_t finalSize = sourceEntry.ready
                ? sourceEntry.size : 0;
            state.Update(row, [](ItemState& value) {
                value.status = L"Receiving";
                value.total = -1;
                value.source = L"来源正在直接写入目标文件夹";
            }, true);
            hr = sourceEntry.ready
                ? S_OK
                : WaitForSourceReady(request, source, state, row,
                                     item.id, finalSize);
            if (SUCCEEDED(hr)) {
                HRESULT mark = networkOrigin.empty()
                    ? S_OK : MarkInternetOrigin(source, networkOrigin);
                HRESULT cleanup = removeRedundantTargets();
                ++succeeded;
                if (FAILED(mark) || FAILED(cleanup)) ++failed;
                state.Update(row, [&](ItemState& value) {
                    value.status = FAILED(mark) || FAILED(cleanup)
                        ? L"NeedsAttention" : L"Completed";
                    value.done = finalSize;
                    value.total = finalSize <=
                        static_cast<uint64_t>(INT64_MAX)
                            ? static_cast<int64_t>(finalSize) : -1;
                    value.speed = 0;
                    value.source = sourceEntry.redundantTargets.empty()
                        ? L"来源已直接保存到目标文件夹"
                        : L"已保留像素尺寸较大的网页图片";
                    value.finalPath = source;
                    if (FAILED(mark))
                        value.error =
                            L"文件已由来源保存，但 Windows 网络来源安全标记失败：" +
                            HResultText(mark);
                    else if (FAILED(cleanup))
                        value.error =
                            L"已保存较大图片，但删除较小候选失败：" +
                            HResultText(cleanup);
                }, true);
                if (IsLikelyImageName(item.name)) {
                    ImageQuality quality = sourceEntry.imageQuality.decoded
                        ? sourceEntry.imageQuality
                        : ReadImageQuality(source);
                    reconcile.plans.push_back({
                        row, item.id,
                        CanonicalDuplicateImageName(item.name),
                        source, networkOrigin, quality, finalSize});
                }
            } else {
                if (HRESULT_CODE(hr) != ERROR_CANCELLED) ++failed;
                state.Update(row, [&](ItemState& value) {
                    value.status = HRESULT_CODE(hr) == ERROR_CANCELLED
                        ? L"Cancelled" : L"Failed";
                    value.errorCode = HRESULT_CODE(hr) == ERROR_CANCELLED
                        ? L"Cancelled" : L"DirectSourceNotReady";
                    value.error = HRESULT_CODE(hr) == ERROR_CANCELLED
                        ? L"用户取消。"
                        : L"来源在目标文件夹中的文件未能完成写入：" +
                          HResultText(hr);
                }, true);
            }
            continue;
        }
        HANDLE input = CreateFileW(source.c_str(), GENERIC_READ,
                                   FILE_SHARE_READ | FILE_SHARE_WRITE |
                                       FILE_SHARE_DELETE,
                                   nullptr, OPEN_EXISTING,
                                   FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
        if (input == INVALID_HANDLE_VALUE) {
            ++failed;
            DWORD error = GetLastError();
            state.Update(row, [&](ItemState& value) {
                value.status = L"Failed";
                value.errorCode = L"SourceUnavailable";
                value.error = L"来源临时文件已不可用：" + Win32Text(error);
            }, true);
            continue;
        }
        Destination destination;
        const bool replacingTarget =
            !sourceEntry.replacementTarget.empty();
        hr = replacingTarget
            ? OpenReplacementDestination(
                  request, sourceEntry.replacementTarget, destination)
            : OpenDestination(request, item.name, destination);
        Progress progress(request, state, row, item.id);
        std::vector<std::byte> buffer(kChunkSize);
        while (SUCCEEDED(hr)) {
            DWORD read = 0;
            if (!ReadFile(input, buffer.data(), static_cast<DWORD>(buffer.size()),
                          &read, nullptr)) {
                hr = HRESULT_FROM_WIN32(GetLastError());
                break;
            }
            if (!read) break;
            hr = WriteBytes(destination.file, buffer.data(), read, progress);
        }
        uint64_t averageSpeed = progress.averageSpeed();
        CloseHandle(input);
        if (SUCCEEDED(hr))
            hr = replacingTarget
                ? FinalizeReplacement(destination)
                : FinalizeDestination(destination);
        if (SUCCEEDED(hr)) {
            ++succeeded;
            PreserveZoneIdentifier(source, destination.final);
            HRESULT mark = networkOrigin.empty()
                ? S_OK : MarkInternetOrigin(destination.final, networkOrigin);
            HRESULT cleanup = removeRedundantTargets();
            if (FAILED(mark) || FAILED(cleanup)) ++failed;
            state.Update(row, [&](ItemState& value) {
                value.status = FAILED(mark) || FAILED(cleanup)
                    ? L"NeedsAttention" : L"Completed";
                value.done = progress.done();
                value.speed = averageSpeed;
                value.finalPath = destination.final;
                value.source = replacingTarget
                    ? L"已用像素尺寸较大的网页图片替换缩略图"
                    : L"本地临时文件";
                if (FAILED(mark))
                    value.error =
                        L"图片已保存，但 Windows 网络来源安全标记失败：" +
                        HResultText(mark);
                else if (FAILED(cleanup))
                    value.error =
                        L"已保存较大图片，但删除较小候选失败：" +
                        HResultText(cleanup);
            }, true);
            if (IsLikelyImageName(item.name)) {
                ImageQuality quality = ReadImageQuality(destination.final);
                reconcile.plans.push_back({
                    row, item.id,
                    CanonicalDuplicateImageName(item.name),
                    destination.final, networkOrigin, quality,
                    progress.done()});
            }
        } else {
            ++failed;
            state.Update(row, [&](ItemState& value) {
                value.status = HRESULT_CODE(hr) == ERROR_CANCELLED
                                   ? L"Cancelled" : L"Failed";
                value.errorCode = HRESULT_CODE(hr) == ERROR_CANCELLED
                                    ? L"Cancelled" : L"HDropCopyFailed";
                value.error = HRESULT_CODE(hr) == ERROR_CANCELLED
                                  ? L"用户取消。"
                                  : L"复制来源临时文件失败：" + HResultText(hr);
            }, true);
        }
    }
    return succeeded ? S_OK : E_FAIL;
}

void CollectSavedImagePlans(StateWriter& state,
                            ImageReconcileContext& context) {
    const auto& items = state.Items();
    for (size_t row = 0; row < items.size(); ++row) {
        const auto& item = items[row];
        if (item.finalPath.empty() ||
            !IsLikelyImageName(item.finalPath) ||
            !Exists(item.finalPath) || IsDirectory(item.finalPath))
            continue;
        const std::wstring normalized =
            FullPathForCompare(item.finalPath);
        const bool recorded = std::any_of(
            context.plans.begin(), context.plans.end(),
            [&](const ImageReconcilePlan& plan) {
                return FullPathForCompare(plan.finalPath) == normalized;
            });
        if (recorded) continue;

        WIN32_FILE_ATTRIBUTE_DATA info{};
        if (!GetFileAttributesExW(item.finalPath.c_str(),
                                  GetFileExInfoStandard, &info))
            continue;
        const uint64_t size =
            (static_cast<uint64_t>(info.nFileSizeHigh) << 32) |
            info.nFileSizeLow;
        const std::wstring name =
            fs::path(item.finalPath).filename().wstring();
        context.plans.push_back({
            row, item.id, CanonicalDuplicateImageName(name),
            item.finalPath, L"", ReadImageQuality(item.finalPath), size});
    }
}

bool SameFileSnapshot(const FileSnapshot& left,
                      const FileSnapshot& right) {
    return left.creation == right.creation &&
           left.modified == right.modified &&
           left.size == right.size;
}

bool DelayedImageIsBetter(const ImageQuality& candidateQuality,
                          uint64_t candidateSize,
                          const ImageReconcilePlan& current) {
    if (candidateQuality.decoded && current.quality.decoded &&
        candidateQuality.pixels != current.quality.pixels)
        return candidateQuality.pixels > current.quality.pixels;
    if (candidateQuality.decoded != current.quality.decoded)
        return candidateQuality.decoded;
    return candidateSize > current.size;
}

HRESULT ReplaceReconciledImage(
    const Request& request, StateWriter& state,
    ImageReconcilePlan& plan, const std::wstring& candidate,
    uint64_t candidateSize, const ImageQuality& candidateQuality) {
    HANDLE input = CreateFileW(
        candidate.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
        FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (input == INVALID_HANDLE_VALUE)
        return HRESULT_FROM_WIN32(GetLastError());
    Destination destination;
    HRESULT hr = OpenReplacementDestination(
        request, plan.finalPath, destination);
    Progress progress(request, state, plan.row, plan.itemId);
    std::vector<std::byte> buffer(kChunkSize);
    while (SUCCEEDED(hr)) {
        DWORD read = 0;
        if (!ReadFile(input, buffer.data(),
                      static_cast<DWORD>(buffer.size()), &read, nullptr)) {
            hr = HRESULT_FROM_WIN32(GetLastError());
            break;
        }
        if (!read) break;
        hr = WriteBytes(destination.file, buffer.data(), read, progress);
    }
    CloseHandle(input);
    if (SUCCEEDED(hr)) {
        PreserveZoneIdentifier(plan.finalPath, destination.part);
        hr = FinalizeReplacement(destination);
    }
    if (FAILED(hr)) return hr;
    PreserveZoneIdentifier(candidate, plan.finalPath);
    const HRESULT mark = plan.networkOrigin.empty()
        ? S_OK : MarkInternetOrigin(plan.finalPath, plan.networkOrigin);
    if (!DeleteFileW(candidate.c_str()))
        return HRESULT_FROM_WIN32(GetLastError());
    plan.size = candidateSize;
    plan.quality = candidateQuality;
    state.Update(plan.row, [&](ItemState& value) {
        value.status = L"Completed";
        value.done = candidateSize;
        value.total = candidateSize <=
            static_cast<uint64_t>(INT64_MAX)
                ? static_cast<int64_t>(candidateSize) : -1;
        value.finalPath = plan.finalPath;
        value.source =
            L"异步结束后已保留像素尺寸较大的网页图片";
    }, true);
    return mark;
}

std::map<std::wstring, FileSnapshot> SnapshotMatchingImageFiles(
    const std::wstring& directory,
    const std::vector<ImageReconcilePlan>& plans) {
    std::map<std::wstring, FileSnapshot> result;
    for (const auto& plan : plans) {
        fs::path canonical(plan.canonicalName);
        const std::wstring expected = Lower(plan.canonicalName);
        const std::wstring patternName =
            canonical.stem().wstring() + L"*" +
            canonical.extension().wstring();
        const std::wstring pattern =
            (fs::path(directory) / patternName).wstring();
        WIN32_FIND_DATAW found{};
        HANDLE search = FindFirstFileW(pattern.c_str(), &found);
        if (search == INVALID_HANDLE_VALUE) continue;
        do {
            if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
                Lower(CanonicalDuplicateImageName(found.cFileName)) !=
                    expected)
                continue;
            const std::wstring path =
                (fs::path(directory) / found.cFileName).wstring();
            FileSnapshot snapshot = SnapshotFromFindData(found);
            snapshot.path = path;
            result[FullPathForCompare(path)] = std::move(snapshot);
        } while (FindNextFileW(search, &found));
        FindClose(search);
    }
    return result;
}

bool ReconcileDelayedImages(
    const Request& request, StateWriter& state,
    ImageReconcileContext& context, int& failed) {
    if (context.plans.empty()) return true;
    constexpr DWORD kPostEndOperationWatchMs = 5000;
    constexpr DWORD kPostEndOperationPollMs = 200;
    DWORD started = GetTickCount();
    bool clean = true;
    auto baseline = context.baseline;

    while (GetTickCount() - started < kPostEndOperationWatchMs) {
        auto current = SnapshotMatchingImageFiles(
            request.targetPath, context.plans);
        for (const auto& [normalizedPath, snapshot] : current) {
            auto previous = baseline.find(normalizedPath);
            if (previous != baseline.end() &&
                SameFileSnapshot(previous->second, snapshot))
                continue;

            const std::wstring candidate = snapshot.path;
            const std::wstring candidateName =
                fs::path(candidate).filename().wstring();
            if (!IsLikelyImageName(candidateName)) {
                baseline[normalizedPath] = snapshot;
                continue;
            }
            const bool isBatchFinal = std::any_of(
                context.plans.begin(), context.plans.end(),
                [&](const ImageReconcilePlan& plan) {
                    return FullPathForCompare(plan.finalPath) ==
                           normalizedPath;
                });
            if (isBatchFinal) {
                baseline[normalizedPath] = snapshot;
                continue;
            }
            const std::wstring key = Lower(
                CanonicalDuplicateImageName(candidateName));
            auto planIt = std::find_if(
                context.plans.begin(), context.plans.end(),
                [&](const ImageReconcilePlan& plan) {
                    return Lower(plan.canonicalName) == key;
                });
            if (planIt == context.plans.end()) {
                baseline[normalizedPath] = snapshot;
                continue;
            }

            uint64_t candidateSize = 0;
            HRESULT hr = WaitForPathReady(
                request, candidate, planIt->itemId, candidateSize);
            if (FAILED(hr)) {
                if (HRESULT_CODE(hr) != ERROR_FILE_NOT_FOUND &&
                    HRESULT_CODE(hr) != ERROR_PATH_NOT_FOUND) {
                    ++failed;
                    clean = false;
                    state.Update(planIt->row, [&](ItemState& value) {
                        value.status = L"NeedsAttention";
                        value.errorCode = L"DelayedCandidateNotReady";
                        value.error =
                            L"来源在异步结束后生成了另一张图片，但无法完成收敛：" +
                            HResultText(hr);
                    }, true);
                }
                baseline[normalizedPath] = snapshot;
                continue;
            }

            const ImageQuality quality = ReadImageQuality(candidate);
            if (DelayedImageIsBetter(
                    quality, candidateSize, *planIt)) {
                hr = ReplaceReconciledImage(
                    request, state, *planIt, candidate,
                    candidateSize, quality);
            } else if (!DeleteFileW(candidate.c_str())) {
                hr = HRESULT_FROM_WIN32(GetLastError());
            } else {
                hr = S_OK;
            }
            if (FAILED(hr)) {
                ++failed;
                clean = false;
                state.Update(planIt->row, [&](ItemState& value) {
                    value.status = L"NeedsAttention";
                    value.errorCode = L"DelayedDuplicateCleanup";
                    value.error =
                        L"检测到来源延迟生成的重复图片，但清理失败：" +
                        HResultText(hr);
                }, true);
                baseline[normalizedPath] = snapshot;
            } else {
                baseline.erase(normalizedPath);
            }
        }
        Sleep(kPostEndOperationPollMs);
    }
    return clean;
}

HRESULT EncodeHBitmapAsPng(HBITMAP bitmap, const std::wstring& path) {
    ComPtr<IWICImagingFactory> factory;
    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(factory.put()));
    if (FAILED(hr)) return hr;
    ComPtr<IWICBitmap> source;
    hr = factory->CreateBitmapFromHBITMAP(bitmap, nullptr,
                                         WICBitmapUsePremultipliedAlpha,
                                         source.put());
    if (FAILED(hr)) return hr;
    ComPtr<IWICStream> stream;
    if (FAILED(hr = factory->CreateStream(stream.put()))) return hr;
    if (FAILED(hr = stream->InitializeFromFilename(
                   path.c_str(), GENERIC_WRITE))) return hr;
    ComPtr<IWICBitmapEncoder> encoder;
    if (FAILED(hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr,
                                           encoder.put()))) return hr;
    if (FAILED(hr = encoder->Initialize(stream.p, WICBitmapEncoderNoCache)))
        return hr;
    ComPtr<IWICBitmapFrameEncode> frame;
    ComPtr<IPropertyBag2> properties;
    if (FAILED(hr = encoder->CreateNewFrame(frame.put(), properties.put())))
        return hr;
    if (FAILED(hr = frame->Initialize(properties.p))) return hr;
    UINT width = 0, height = 0;
    source->GetSize(&width, &height);
    if (FAILED(hr = frame->SetSize(width, height))) return hr;
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppPBGRA;
    frame->SetPixelFormat(&format);
    if (FAILED(hr = frame->WriteSource(source.p, nullptr))) return hr;
    if (FAILED(hr = frame->Commit())) return hr;
    return encoder->Commit();
}

std::wstring ImageName() {
    SYSTEMTIME st{};
    GetLocalTime(&st);
    wchar_t value[80]{};
    swprintf_s(value, L"拖入图片_%04u%02u%02u_%02u%02u%02u.png",
               st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute,
               st.wSecond);
    return value;
}

HRESULT ExtractImage(const Request& request, IDataObject* data,
                     StateWriter& state, int& succeeded, int& failed) {
    UINT formatId = 0;
    bool png = false;
    if (request.adapter == L"Png") {
        formatId = RegisterClipboardFormatW(L"PNG");
        png = true;
    } else {
        formatId = request.adapter == L"DibV5" ? CF_DIBV5 : CF_DIB;
    }
    FORMATETC format{static_cast<CLIPFORMAT>(formatId), nullptr,
                     DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    Medium medium;
    HRESULT hr = data->GetData(&format, &medium.value);
    ItemState item;
    item.id = NewId(L"item");
    item.name = ImageName();
    item.source = png ? L"PNG 图片数据" : L"位图数据";
    size_t row = state.Add(item);
    if (FAILED(hr) || medium.value.tymed != TYMED_HGLOBAL) {
        ++failed;
        state.Update(row, [&](ItemState& value) {
            value.status = L"Failed";
            value.errorCode = L"ImageGetData";
            value.error = L"读取图片数据失败：" + HResultText(hr);
        }, true);
        return FAILED(hr) ? hr : DV_E_TYMED;
    }
    SIZE_T size = GlobalSize(medium.value.hGlobal);
    void* bytes = GlobalLock(medium.value.hGlobal);
    if (!bytes && size) {
        hr = HRESULT_FROM_WIN32(GetLastError());
        ++failed;
        state.Update(row, [&](ItemState& value) {
            value.status = L"Failed";
            value.errorCode = L"ImageGlobalLock";
            value.error = L"锁定图片数据失败：" + HResultText(hr);
        }, true);
        return hr;
    }
    Destination destination;
    uint64_t imageAverageSpeed = 0;
    hr = OpenDestination(request, item.name, destination);
    if (SUCCEEDED(hr) && png) {
        static constexpr unsigned char signature[] =
            {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
        if (size < sizeof(signature) ||
            memcmp(bytes, signature, sizeof(signature)) != 0) {
            hr = HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        } else {
            Progress progress(request, state, row, item.id);
            hr = WriteBytes(destination.file, bytes, size, progress);
            imageAverageSpeed = progress.averageSpeed();
        }
    } else if (SUCCEEDED(hr)) {
        if (size < sizeof(BITMAPINFOHEADER)) {
            hr = HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        } else {
            auto* info = static_cast<BITMAPINFO*>(bytes);
            auto& header = info->bmiHeader;
            size_t colors = header.biClrUsed;
            if (!colors && header.biBitCount <= 8)
                colors = 1ULL << header.biBitCount;
            size_t offset = header.biSize + colors * sizeof(RGBQUAD);
            if (header.biCompression == BI_BITFIELDS &&
                header.biSize == sizeof(BITMAPINFOHEADER)) {
                offset += 3 * sizeof(DWORD);
            }
            if (offset >= size) {
                hr = HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
            } else {
                HDC dc = GetDC(nullptr);
                HBITMAP bitmap = CreateDIBitmap(
                    dc, &header, CBM_INIT,
                    static_cast<const std::byte*>(bytes) + offset,
                    info, DIB_RGB_COLORS);
                ReleaseDC(nullptr, dc);
                if (!bitmap) {
                    hr = HRESULT_FROM_WIN32(GetLastError());
                } else {
                    CloseHandle(destination.file);
                    destination.file = INVALID_HANDLE_VALUE;
                    hr = EncodeHBitmapAsPng(bitmap, destination.part);
                    DeleteObject(bitmap);
                    if (SUCCEEDED(hr)) {
                        destination.file = CreateFileW(
                            destination.part.c_str(), GENERIC_READ | GENERIC_WRITE,
                            FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                            FILE_ATTRIBUTE_HIDDEN, nullptr);
                        if (destination.file == INVALID_HANDLE_VALUE)
                            hr = HRESULT_FROM_WIN32(GetLastError());
                    }
                }
            }
        }
    }
    if (bytes) GlobalUnlock(medium.value.hGlobal);
    if (SUCCEEDED(hr)) hr = FinalizeDestination(destination);
    if (SUCCEEDED(hr)) {
        ++succeeded;
        WIN32_FILE_ATTRIBUTE_DATA info{};
        GetFileAttributesExW(destination.final.c_str(), GetFileExInfoStandard,
                             &info);
        uint64_t finalSize =
            (static_cast<uint64_t>(info.nFileSizeHigh) << 32) |
            info.nFileSizeLow;
        state.Update(row, [&](ItemState& value) {
            value.status = L"Completed";
            value.done = finalSize;
            value.total = static_cast<int64_t>(finalSize);
            value.speed = imageAverageSpeed;
            value.finalPath = destination.final;
        }, true);
    } else {
        ++failed;
        state.Update(row, [&](ItemState& value) {
            value.status = L"Failed";
            value.errorCode = L"ImageEncodeFailed";
            value.error = L"图片保存为 PNG 失败：" + HResultText(hr);
        }, true);
    }
    return hr;
}

std::wstring ReadUrlFromDataObject(IDataObject* data) {
    const UINT ids[] = {
        RegisterClipboardFormatW(L"UniformResourceLocatorW"),
        RegisterClipboardFormatW(L"text/uri-list"),
        RegisterClipboardFormatW(L"UniformResourceLocator")};
    for (size_t i = 0; i < std::size(ids); ++i) {
        FORMATETC format{static_cast<CLIPFORMAT>(ids[i]), nullptr,
                         DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
        Medium medium;
        if (FAILED(data->GetData(&format, &medium.value)) ||
            medium.value.tymed != TYMED_HGLOBAL)
            continue;
        SIZE_T size = GlobalSize(medium.value.hGlobal);
        void* memory = GlobalLock(medium.value.hGlobal);
        if (!memory) continue;
        std::wstring value;
        if (i == 0) {
            size_t count = size / sizeof(wchar_t);
            const auto* text = static_cast<const wchar_t*>(memory);
            value.assign(text, text + wcsnlen_s(text, count));
        } else {
            int chars = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                            static_cast<const char*>(memory),
                                            static_cast<int>(strnlen_s(
                                                static_cast<const char*>(memory),
                                                size)),
                                            nullptr, 0);
            if (!chars) {
                chars = MultiByteToWideChar(
                    CP_ACP, 0, static_cast<const char*>(memory),
                    static_cast<int>(strnlen_s(
                        static_cast<const char*>(memory), size)),
                    nullptr, 0);
                value.resize(chars);
                MultiByteToWideChar(
                    CP_ACP, 0, static_cast<const char*>(memory),
                    static_cast<int>(strnlen_s(
                        static_cast<const char*>(memory), size)),
                    value.data(), chars);
            } else {
                value.resize(chars);
                MultiByteToWideChar(
                    CP_UTF8, MB_ERR_INVALID_CHARS,
                    static_cast<const char*>(memory),
                    static_cast<int>(strnlen_s(
                        static_cast<const char*>(memory), size)),
                    value.data(), chars);
            }
        }
        GlobalUnlock(medium.value.hGlobal);
        std::wistringstream lines(value);
        std::wstring line;
        while (std::getline(lines, line)) {
            line = Trim(line);
            if (!line.empty() && line[0] != L'#') return line;
        }
    }
    return L"";
}

bool ProtectRetryUrl(const Request& request, const std::wstring& url) {
    if (request.retryPath.empty() || url.empty()) return false;
    DATA_BLOB input{
        static_cast<DWORD>((url.size() + 1) * sizeof(wchar_t)),
        reinterpret_cast<BYTE*>(const_cast<wchar_t*>(url.c_str()))};
    DATA_BLOB output{};
    if (!CryptProtectData(&input, L"PopDrop URL retry", nullptr, nullptr,
                          nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output))
        return false;
    HANDLE file = CreateFileW(request.retryPath.c_str(), GENERIC_WRITE, 0,
                              nullptr, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_TEMPORARY,
                              nullptr);
    bool ok = false;
    if (file != INVALID_HANDLE_VALUE) {
        DWORD written = 0;
        ok = WriteFile(file, output.pbData, output.cbData, &written, nullptr) &&
             written == output.cbData && FlushFileBuffers(file);
        CloseHandle(file);
    }
    LocalFree(output.pbData);
    return ok;
}

std::wstring UnprotectRetryUrl(const Request& request) {
    std::vector<std::byte> bytes;
    if (!ReadAll(request.retryPath, bytes)) return L"";
    DATA_BLOB input{static_cast<DWORD>(bytes.size()),
                    reinterpret_cast<BYTE*>(bytes.data())};
    DATA_BLOB output{};
    if (!CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr,
                            CRYPTPROTECT_UI_FORBIDDEN, &output))
        return L"";
    std::wstring result;
    if (output.cbData >= sizeof(wchar_t)) {
        const auto* text = reinterpret_cast<const wchar_t*>(output.pbData);
        result.assign(text, wcsnlen_s(
            text, output.cbData / sizeof(wchar_t)));
    }
    LocalFree(output.pbData);
    return result;
}

std::wstring PercentDecodeUtf8(const std::wstring& value) {
    std::string bytes;
    for (size_t i = 0; i < value.size(); ++i) {
        if (value[i] == L'%' && i + 2 < value.size()) {
            wchar_t hex[3]{value[i + 1], value[i + 2], 0};
            wchar_t* end = nullptr;
            long decoded = wcstol(hex, &end, 16);
            if (end == hex + 2) {
                bytes.push_back(static_cast<char>(decoded));
                i += 2;
                continue;
            }
        }
        if (value[i] < 128) bytes.push_back(static_cast<char>(value[i]));
    }
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                    bytes.data(), static_cast<int>(bytes.size()),
                                    nullptr, 0);
    if (!count) return value;
    std::wstring result(count, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes.data(),
                        static_cast<int>(bytes.size()), result.data(), count);
    return result;
}

std::wstring ContentDispositionName(const std::wstring& header) {
    std::wstring lower = Lower(header);
    size_t utf = lower.find(L"filename*=");
    if (utf != std::wstring::npos) {
        std::wstring value = Trim(header.substr(utf + 10));
        size_t semicolon = value.find(L';');
        if (semicolon != std::wstring::npos) value.resize(semicolon);
        if (value.size() >= 2 && value.front() == L'"' &&
            value.back() == L'"') {
            value = value.substr(1, value.size() - 2);
        }
        size_t marker = Lower(value).find(L"utf-8''");
        if (marker == 0) value = value.substr(7);
        return PercentDecodeUtf8(value);
    }
    size_t plain = lower.find(L"filename=");
    if (plain != std::wstring::npos) {
        std::wstring value = Trim(header.substr(plain + 9));
        size_t semicolon = value.find(L';');
        if (semicolon != std::wstring::npos) value.resize(semicolon);
        if (value.size() >= 2 && value.front() == L'"' &&
            value.back() == L'"') {
            value = value.substr(1, value.size() - 2);
        }
        return value;
    }
    return L"";
}

std::wstring QueryHeader(HINTERNET request, DWORD query) {
    DWORD bytes = 0;
    WinHttpQueryHeaders(request, query, WINHTTP_HEADER_NAME_BY_INDEX,
                        nullptr, &bytes, WINHTTP_NO_HEADER_INDEX);
    if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || !bytes) return L"";
    std::vector<wchar_t> buffer(bytes / sizeof(wchar_t) + 1);
    if (!WinHttpQueryHeaders(request, query, WINHTTP_HEADER_NAME_BY_INDEX,
                             buffer.data(), &bytes,
                             WINHTTP_NO_HEADER_INDEX))
        return L"";
    return buffer.data();
}

std::wstring UrlDisplayHost(const URL_COMPONENTSW& parts) {
    return std::wstring(parts.lpszHostName, parts.dwHostNameLength);
}

HANDLE AcquireHostSlot(const std::wstring& host, const Request& request) {
    uint64_t hash = 1469598103934665603ULL;
    for (wchar_t c : Lower(host)) {
        hash ^= static_cast<uint16_t>(c);
        hash *= 1099511628211ULL;
    }
    wchar_t name[80]{};
    swprintf_s(name, L"Local\\PopDrop.TransferHost.%016llX",
               static_cast<unsigned long long>(hash));
    HANDLE semaphore = CreateSemaphoreW(nullptr, 2, 2, name);
    if (!semaphore) return nullptr;
    for (;;) {
        DWORD result = WaitForSingleObject(semaphore, 200);
        if (result == WAIT_OBJECT_0) break;
        if (IsCancelled(request)) {
            CloseHandle(semaphore);
            return nullptr;
        }
        if (result == WAIT_FAILED) {
            CloseHandle(semaphore);
            return nullptr;
        }
    }
    return semaphore;
}

HRESULT ExtractUrl(const Request& request, IDataObject* data,
                   const std::wstring& retryUrl,
                   StateWriter& state, int& succeeded, int& failed) {
    std::wstring url = retryUrl.empty()
        ? ReadUrlFromDataObject(data) : retryUrl;
    ItemState item;
    item.id = NewId(L"item");
    item.name = L"正在获取文件名…";
    item.source = L"公开 URL";
    item.retryable = true;
    size_t row = state.Add(item);
    if (url.empty()) {
        ++failed;
        state.Update(row, [](ItemState& value) {
            value.status = L"Failed";
            value.errorCode = L"MissingUrl";
            value.error = L"来源没有提供可读取的规范 URL。";
        }, true);
        return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
    }
    ProtectRetryUrl(request, url);
    URL_COMPONENTSW parts{sizeof(parts)};
    wchar_t scheme[16]{}, host[2048]{}, path[32768]{}, extra[32768]{};
    wchar_t user[1024]{}, password[1024]{};
    parts.lpszScheme = scheme;
    parts.dwSchemeLength = std::size(scheme);
    parts.lpszHostName = host;
    parts.dwHostNameLength = std::size(host);
    parts.lpszUrlPath = path;
    parts.dwUrlPathLength = std::size(path);
    parts.lpszExtraInfo = extra;
    parts.dwExtraInfoLength = std::size(extra);
    parts.lpszUserName = user;
    parts.dwUserNameLength = std::size(user);
    parts.lpszPassword = password;
    parts.dwPasswordLength = std::size(password);
    if (!WinHttpCrackUrl(url.c_str(), static_cast<DWORD>(url.size()), 0,
                         &parts) ||
        parts.dwHostNameLength == 0 || parts.dwUserNameLength != 0 ||
        parts.dwPasswordLength != 0 ||
        (parts.nScheme != INTERNET_SCHEME_HTTPS &&
         !(request.allowHttp && parts.nScheme == INTERNET_SCHEME_HTTP))) {
        ++failed;
        state.Update(row, [](ItemState& value) {
            value.status = L"Failed";
            value.errorCode = L"UnsafeUrl";
            value.error = L"URL 协议、凭据或主机不符合安全策略。";
        }, true);
        return E_INVALIDARG;
    }
    item.source = UrlDisplayHost(parts);
    HANDLE hostSlot = AcquireHostSlot(item.source, request);
    if (!hostSlot) {
        const bool cancelled = IsCancelled(request);
        if (!cancelled) ++failed;
        state.Update(row, [&](ItemState& value) {
            value.status = cancelled ? L"Cancelled" : L"Failed";
            value.errorCode = cancelled ? L"Cancelled" : L"HostQueueFailed";
            value.error = cancelled
                ? L"用户取消。"
                : L"无法创建同主机下载队列。";
        }, true);
        return HRESULT_FROM_WIN32(
            cancelled ? ERROR_CANCELLED : ERROR_NOT_ENOUGH_MEMORY);
    }
    state.Update(row, [&](ItemState& value) {
        value.source = item.source;
        value.status = L"Connecting";
    }, true);

    HINTERNET session = WinHttpOpen(
        L"PopDrop/1.0.0", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) {
        DWORD error = GetLastError();
        if (hostSlot) {
            ReleaseSemaphore(hostSlot, 1, nullptr);
            CloseHandle(hostSlot);
        }
        ++failed;
        state.Update(row, [&](ItemState& value) {
            value.status = L"Failed";
            value.errorCode = L"WinHttpOpen";
            value.error = L"无法初始化系统网络会话：" + Win32Text(error);
        }, true);
        return HRESULT_FROM_WIN32(error);
    }
    WinHttpSetTimeouts(session, 15000, 15000, 30000, 30000);
    DWORD maxRedirects = 10;
    WinHttpSetOption(session, WINHTTP_OPTION_MAX_HTTP_AUTOMATIC_REDIRECTS,
                     &maxRedirects, sizeof(maxRedirects));
    HINTERNET connection = WinHttpConnect(
        session, std::wstring(parts.lpszHostName,
                              parts.dwHostNameLength).c_str(),
        parts.nPort, 0);
    std::wstring object(parts.lpszUrlPath, parts.dwUrlPathLength);
    object.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);
    HINTERNET http = connection ? WinHttpOpenRequest(
        connection, L"GET", object.c_str(), nullptr,
        WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
        parts.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0)
        : nullptr;
    HRESULT hr = S_OK;
    if (!connection || !http ||
        !WinHttpSendRequest(http, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                            WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
        !WinHttpReceiveResponse(http, nullptr)) {
        hr = HRESULT_FROM_WIN32(GetLastError());
    }
    DWORD status = 0, statusSize = sizeof(status);
    if (SUCCEEDED(hr) &&
        (!WinHttpQueryHeaders(http,
             WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
             WINHTTP_HEADER_NAME_BY_INDEX, &status, &statusSize,
             WINHTTP_NO_HEADER_INDEX) ||
         status < 200 || status >= 300)) {
        hr = HRESULT_FROM_WIN32(ERROR_WINHTTP_INVALID_SERVER_RESPONSE);
    }
    std::wstring type = QueryHeader(http, WINHTTP_QUERY_CONTENT_TYPE);
    std::wstring disposition =
        QueryHeader(http, WINHTTP_QUERY_CONTENT_DISPOSITION);
    bool attachment = Lower(disposition).find(L"attachment") !=
                      std::wstring::npos;
    bool html = Lower(type).find(L"text/html") != std::wstring::npos ||
                Lower(type).find(L"application/xhtml") != std::wstring::npos;
    if (SUCCEEDED(hr) && html && !attachment) {
        hr = HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        state.Update(row, [](ItemState& value) {
            value.error =
                L"该拖拽只提供了网页地址，服务器没有返回可下载文件。"
                L" 来源网站没有通过系统拖放提供文件内容，PopDrop也无法继承"
                L"浏览器登录状态。请先在浏览器中完成下载。";
        }, true);
    }
    std::wstring name = ContentDispositionName(disposition);
    if (name.empty()) {
        name = fs::path(std::wstring(parts.lpszUrlPath,
                                    parts.dwUrlPathLength)).filename().wstring();
    }
    if (name.empty()) name = L"下载文件";
    name = SanitizeName(name, L"下载文件");
    std::wstring lengthText =
        Trim(QueryHeader(http, WINHTTP_QUERY_CONTENT_LENGTH));
    wchar_t* lengthEnd = nullptr;
    uint64_t length = lengthText.empty()
        ? 0 : wcstoull(lengthText.c_str(), &lengthEnd, 10);
    bool knownLength = !lengthText.empty() && lengthEnd &&
        *lengthEnd == L'\0' &&
        length <= static_cast<uint64_t>(INT64_MAX);
    state.Update(row, [&](ItemState& value) {
        value.name = name;
        value.total = knownLength ? static_cast<int64_t>(length) : -1;
        if (SUCCEEDED(hr)) value.status = L"Receiving";
    }, true);
    Destination destination;
    if (SUCCEEDED(hr)) hr = OpenDestination(request, name, destination);
    Progress progress(request, state, row, item.id);
    std::vector<std::byte> buffer(kChunkSize);
    while (SUCCEEDED(hr)) {
        DWORD available = 0;
        if (!WinHttpQueryDataAvailable(http, &available)) {
            hr = HRESULT_FROM_WIN32(GetLastError());
            break;
        }
        if (!available) break;
        while (available) {
            DWORD ask = std::min<DWORD>(
                available, static_cast<DWORD>(buffer.size()));
            DWORD read = 0;
            if (!WinHttpReadData(http, buffer.data(), ask, &read)) {
                hr = HRESULT_FROM_WIN32(GetLastError());
                break;
            }
            if (!read) {
                hr = HRESULT_FROM_WIN32(ERROR_HANDLE_EOF);
                break;
            }
            hr = WriteBytes(destination.file, buffer.data(), read, progress);
            if (FAILED(hr)) break;
            available -= read;
        }
    }
    uint64_t averageSpeed = progress.averageSpeed();
    if (SUCCEEDED(hr) && knownLength && progress.done() != length)
        hr = HRESULT_FROM_WIN32(ERROR_HANDLE_EOF);
    if (SUCCEEDED(hr)) {
        state.Update(row, [](ItemState& value) {
            value.status = L"Finalizing";
        }, true);
        hr = FinalizeDestination(destination);
    }
    if (SUCCEEDED(hr)) {
        HRESULT mark = MarkInternetOrigin(destination.final, url);
        ++succeeded;
        if (FAILED(mark)) ++failed;
        state.Update(row, [&](ItemState& value) {
            value.status = FAILED(mark) ? L"NeedsAttention" : L"Completed";
            value.done = progress.done();
            if (value.total < 0)
                value.total = static_cast<int64_t>(progress.done());
            value.speed = averageSpeed;
            value.finalPath = destination.final;
            if (FAILED(mark))
                value.error =
                    L"文件已保存，但 Windows 网络来源安全标记失败：" +
                    HResultText(mark);
        }, true);
    } else {
        ++failed;
        state.Update(row, [&](ItemState& value) {
            value.status = HRESULT_CODE(hr) == ERROR_CANCELLED
                               ? L"Cancelled" : L"Failed";
            value.errorCode = HRESULT_CODE(hr) == ERROR_CANCELLED
                                ? L"Cancelled" : L"HttpDownloadFailed";
            if (value.error.empty())
                value.error = L"公开 URL 下载失败：" + HResultText(hr);
        }, true);
    }
    if (http) WinHttpCloseHandle(http);
    if (connection) WinHttpCloseHandle(connection);
    if (session) WinHttpCloseHandle(session);
    if (hostSlot) {
        ReleaseSemaphore(hostSlot, 1, nullptr);
        CloseHandle(hostSlot);
    }
    return hr;
}

HANDLE AcquireGlobalSlot(const Request& request) {
    int maximum = std::clamp(request.maxConcurrent, 1, 6);
    HANDLE semaphore = CreateSemaphoreW(
        nullptr, maximum, maximum, L"Local\\PopDrop.TransferSlots.v2");
    if (!semaphore) return nullptr;
    for (;;) {
        DWORD result = WaitForSingleObject(semaphore, 200);
        if (result == WAIT_OBJECT_0) break;
        if (IsCancelled(request)) {
            CloseHandle(semaphore);
            return nullptr;
        }
        if (result == WAIT_FAILED) {
            CloseHandle(semaphore);
            return nullptr;
        }
    }
    return semaphore;
}

void ReleaseGlobalSlot(HANDLE slot) {
    if (!slot) return;
    ReleaseSemaphore(slot, 1, nullptr);
    CloseHandle(slot);
}

Request ReadRequest(const std::wstring& path) {
    Request request;
    request.requestPath = path;
    request.protocol = IniInt(path, L"Transfer", L"Protocol", 0);
    request.batchId = Ini(path, L"Transfer", L"BatchId");
    request.adapter = Ini(path, L"Transfer", L"Adapter");
    request.targetPath = Ini(path, L"Transfer", L"TargetPath");
    request.targetSourceId = Ini(path, L"Transfer", L"TargetSourceId");
    request.targetName = Ini(path, L"Transfer", L"TargetName");
    request.marshalPath = Ini(path, L"Transfer", L"MarshalPath");
    request.statePath = Ini(path, L"Transfer", L"StatePath");
    request.cancelPath = Ini(path, L"Transfer", L"CancelPath");
    request.readyPath = Ini(path, L"Transfer", L"ReadyPath");
    request.retryPath = Ini(path, L"Transfer", L"RetryPath");
    request.allowHttp = IniInt(path, L"Transfer", L"AllowHttp", 0) == 1;
    request.maxConcurrent =
        IniInt(path, L"Transfer", L"MaxConcurrent", 3);
    return request;
}

bool ValidRequest(const Request& request) {
    return request.protocol == 2 &&
           !request.batchId.empty() && !request.adapter.empty() &&
           IsDirectory(request.targetPath) &&
           (request.adapter == L"UrlRetry" || !request.marshalPath.empty()) &&
           !request.statePath.empty() &&
           !request.readyPath.empty();
}

int Run(const Request& request) {
    StateWriter state(request);
    state.SetBatch(L"Preparing");
    ImageReconcileContext imageReconcile;
    imageReconcile.baseline =
        SnapshotDirectoryFiles(request.targetPath);
    ComPtr<IDataObject> data;
    HRESULT hr = S_OK;
    std::wstring retryUrl;
    if (request.adapter == L"UrlRetry") {
        retryUrl = UnprotectRetryUrl(request);
        if (retryUrl.empty()) {
            state.SetBatch(L"Failed", L"URL 重试凭据已失效或不属于当前用户。");
            return 3;
        }
    } else {
        hr = UnmarshalDataObject(request, data);
        if (FAILED(hr) || !data) {
            state.SetBatch(L"Failed",
                           L"无法安全接管来源数据对象：" + HResultText(hr));
            return 3;
        }
        DeleteFileW(request.marshalPath.c_str());
    }
    AsyncOperation async(data.p);
    HANDLE ready = CreateFileW(request.readyPath.c_str(), GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, CREATE_ALWAYS,
        FILE_ATTRIBUTE_TEMPORARY, nullptr);
    if (ready == INVALID_HANDLE_VALUE) return 5;
    constexpr char marker[] = "READY";
    DWORD written = 0;
    const bool readyWritten =
        WriteFile(ready, marker, static_cast<DWORD>(sizeof(marker) - 1),
                  &written, nullptr) &&
        written == sizeof(marker) - 1;
    CloseHandle(ready);
    if (!readyWritten) return 5;
    state.SetBatch(L"Queued");
    HANDLE slot = AcquireGlobalSlot(request);
    if (!slot) {
        const bool cancelled = IsCancelled(request);
        state.SetBatch(cancelled ? L"Cancelled" : L"Failed",
                       cancelled
                           ? L"用户在任务排队时取消。"
                           : L"无法创建全局传输队列。");
        async.Finish(
            HRESULT_FROM_WIN32(cancelled ? ERROR_CANCELLED
                                         : ERROR_NOT_ENOUGH_MEMORY),
            DROPEFFECT_NONE);
        DeleteFileW(request.requestPath.c_str());
        return 4;
    }
    if (IsCancelled(request)) {
        ReleaseGlobalSlot(slot);
        state.SetBatch(L"Cancelled", L"用户在任务排队时取消。");
        async.Finish(HRESULT_FROM_WIN32(ERROR_CANCELLED), DROPEFFECT_NONE);
        DeleteFileW(request.requestPath.c_str());
        return 4;
    }
    state.SetBatch(L"Preparing");
    int succeeded = 0, failed = 0;
    if (request.adapter == L"VirtualFiles")
        hr = ExtractVirtual(request, data.p, state, succeeded, failed);
    else if (request.adapter == L"HDrop")
        hr = ExtractHDrop(request, data.p, state, succeeded, failed,
                          imageReconcile);
    else if (request.adapter == L"Png" || request.adapter == L"DibV5" ||
             request.adapter == L"Dib")
        hr = ExtractImage(request, data.p, state, succeeded, failed);
    else if (request.adapter == L"Url" || request.adapter == L"UrlRetry")
        hr = ExtractUrl(request, data.p, retryUrl,
                        state, succeeded, failed);
    else
        hr = DV_E_FORMATETC;
    if (succeeded)
        CollectSavedImagePlans(state, imageReconcile);
    const bool shouldReconcileImages =
        succeeded && !imageReconcile.plans.empty();
    ReleaseGlobalSlot(slot);
    bool cancelled = IsCancelled(request);
    if (cancelled) {
        state.SetBatch(L"Cancelled", L"用户取消。");
        async.Finish(HRESULT_FROM_WIN32(ERROR_CANCELLED), DROPEFFECT_NONE);
    } else if (succeeded) {
        if (shouldReconcileImages)
            state.SetBatch(L"Finalizing");
        async.Finish(failed ? S_FALSE : S_OK, DROPEFFECT_COPY);
        if (shouldReconcileImages)
            ReconcileDelayedImages(
                request, state, imageReconcile, failed);
        if (failed)
            state.SetBatch(L"NeedsAttention", L"部分项目保存失败。");
        else
            state.SetBatch(L"Completed");
    } else {
        state.SetBatch(L"Failed",
                       failed ? L"所有项目均保存失败。" : HResultText(hr));
        async.Finish(FAILED(hr) ? hr : E_FAIL, DROPEFFECT_NONE);
    }
    DeleteFileW(request.requestPath.c_str());
    return succeeded ? 0 : 4;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR commandLine, int) {
    int argc = 0;
    wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) return 2;
    std::wstring requestPath;
    for (int i = 1; i + 1 < argc; ++i) {
        if (std::wstring(argv[i]) == L"--request")
            requestPath = argv[++i];
    }
    LocalFree(argv);
    if (requestPath.empty()) return 2;
    ComInit com;
    if (FAILED(com.hr)) return 2;
    Request request = ReadRequest(requestPath);
    if (!ValidRequest(request)) return 2;
    return Run(request);
}
