#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <wincodec.h>
#include <shobjidl.h>
#include <shellapi.h>
#include <bcrypt.h>
#include <propidl.h>
#include <propvarutil.h>
#include <shcore.h>
#include <filter.h>
#include <Filterr.h>
#include <NTQuery.h>
#include <winrt/Windows.Data.Pdf.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.UI.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cwctype>
#include <cstring>
#include <cstdlib>
#include <filesystem>
#include <iterator>
#include <limits>
#include <memory>
#include <sstream>
#include <string>
#include <unordered_set>
#include <vector>

#ifndef FILE_ATTRIBUTE_RECALL_ON_OPEN
#define FILE_ATTRIBUTE_RECALL_ON_OPEN 0x00040000
#endif
#ifndef FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS
#define FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS 0x00400000
#endif

#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "shcore.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "query.lib")
#pragma comment(lib, "runtimeobject.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "oleaut32.lib")
#pragma comment(lib, "user32.lib")

namespace {

constexpr uint32_t kMagic = 0x56504450; // PDPV
constexpr uint32_t kProtocolVersion = 5;
constexpr size_t kMapBytes = 4268288;
constexpr size_t kPathOffset = 256;
constexpr size_t kPathChars = 32768;
constexpr size_t kCacheRootOffset = 65792;
constexpr size_t kCacheRootChars = 4096;
constexpr size_t kPixelOffset = 73984;
constexpr size_t kMaxPixelBytes = 4 * 1024 * 1024;
constexpr uint32_t kCommandPreview = 1;
constexpr uint32_t kCommandCache = 2;
constexpr uint32_t kCommandGenerateDocument = 3;
constexpr uint32_t kStatusReady = 2;
constexpr uint32_t kStatusNoContent = 3;
constexpr uint32_t kStatusNeedsGeneration = 4;
constexpr uint32_t kStatusResourceLimit = 5;
constexpr uint32_t kStatusPasswordProtected = 6;
constexpr uint32_t kStatusInaccessible = 7;
constexpr uint32_t kStatusCorruptOrUnsupported = 8;
constexpr uint32_t kPreviewSpecVersion = 4;
constexpr uint64_t kTextReadBudget = 512ull * 1024;
constexpr size_t kTextLineLimit = 180;
constexpr size_t kTextLineCharacterLimit = 4096;
constexpr uint64_t kPdfReadBudget = 64ull * 1024 * 1024;

template <typename T>
class ComPtr {
public:
    ComPtr() = default;
    ~ComPtr() { reset(); }
    ComPtr(const ComPtr&) = delete;
    ComPtr& operator=(const ComPtr&) = delete;
    ComPtr(ComPtr&& other) noexcept : value_(other.value_) {
        other.value_ = nullptr;
    }
    ComPtr& operator=(ComPtr&& other) noexcept {
        if (this != &other) {
            reset();
            value_ = other.value_;
            other.value_ = nullptr;
        }
        return *this;
    }
    T* get() const { return value_; }
    T** put() {
        reset();
        return &value_;
    }
    T* operator->() const { return value_; }
    explicit operator bool() const { return value_ != nullptr; }
    void reset(T* replacement = nullptr) {
        if (value_) value_->Release();
        value_ = replacement;
    }
    template <typename U>
    HRESULT as(ComPtr<U>& destination) const {
        if (!value_) return E_POINTER;
        return value_->QueryInterface(__uuidof(U),
            reinterpret_cast<void**>(destination.put()));
    }
private:
    T* value_ = nullptr;
};

using PdfiumDocument = void*;
using PdfiumPage = void*;
using PdfiumBitmap = void*;

struct PdfiumFileAccess {
    unsigned long fileLength;
    int (*getBlock)(void*, unsigned long, unsigned char*, unsigned long);
    void* parameter;
};

struct PdfiumFileContext {
    HANDLE file = INVALID_HANDLE_VALUE;
    uint64_t bytesRead = 0;
    bool resourceLimit = false;
};

int PdfiumReadBlock(void* parameter, unsigned long position,
                    unsigned char* buffer, unsigned long size) {
    auto* context = static_cast<PdfiumFileContext*>(parameter);
    if (!context || context->file == INVALID_HANDLE_VALUE || !buffer
        || size == 0 || size > kPdfReadBudget
        || context->bytesRead > kPdfReadBudget - size) {
        if (context)
            context->resourceLimit = true;
        return 0;
    }
    LARGE_INTEGER offset{};
    offset.QuadPart = position;
    if (!SetFilePointerEx(context->file, offset, nullptr, FILE_BEGIN))
        return 0;
    DWORD read = 0;
    if (!ReadFile(context->file, buffer, size, &read, nullptr)
        || read != size)
        return 0;
    context->bytesRead += read;
    return 1;
}

class PdfiumApi {
public:
    using InitLibrary = void (*)();
    using DestroyLibrary = void (*)();
    using LoadCustomDocument =
        PdfiumDocument (*)(PdfiumFileAccess*, const char*);
    using GetLastError = unsigned long (*)();
    using GetPageCount = int (*)(PdfiumDocument);
    using LoadPage = PdfiumPage (*)(PdfiumDocument, int);
    using GetPageDimension = float (*)(PdfiumPage);
    using CreateBitmap =
        PdfiumBitmap (*)(int, int, int, void*, int);
    using FillBitmap =
        int (*)(PdfiumBitmap, int, int, int, int, unsigned long);
    using RenderPageBitmap =
        void (*)(PdfiumBitmap, PdfiumPage, int, int, int, int, int, int);
    using DestroyBitmap = void (*)(PdfiumBitmap);
    using ClosePage = void (*)(PdfiumPage);
    using CloseDocument = void (*)(PdfiumDocument);

    ~PdfiumApi() {
        if (initialized_ && destroyLibrary)
            destroyLibrary();
        if (module_)
            FreeLibrary(module_);
    }

    bool Load() {
        std::array<wchar_t, 32768> executable{};
        const DWORD length = GetModuleFileNameW(
            nullptr, executable.data(), static_cast<DWORD>(executable.size()));
        if (!length || length >= executable.size())
            return false;
        const std::filesystem::path dll =
            std::filesystem::path(std::wstring(executable.data(), length))
                .parent_path() / L"pdfium.dll";
        module_ = LoadLibraryExW(dll.c_str(), nullptr,
            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!module_)
            return false;
        initLibrary = Resolve<InitLibrary>("FPDF_InitLibrary");
        destroyLibrary = Resolve<DestroyLibrary>("FPDF_DestroyLibrary");
        loadCustomDocument =
            Resolve<LoadCustomDocument>("FPDF_LoadCustomDocument");
        getLastError = Resolve<GetLastError>("FPDF_GetLastError");
        getPageCount = Resolve<GetPageCount>("FPDF_GetPageCount");
        loadPage = Resolve<LoadPage>("FPDF_LoadPage");
        getPageWidth = Resolve<GetPageDimension>("FPDF_GetPageWidthF");
        getPageHeight = Resolve<GetPageDimension>("FPDF_GetPageHeightF");
        createBitmap = Resolve<CreateBitmap>("FPDFBitmap_CreateEx");
        fillBitmap = Resolve<FillBitmap>("FPDFBitmap_FillRect");
        renderPageBitmap =
            Resolve<RenderPageBitmap>("FPDF_RenderPageBitmap");
        destroyBitmap = Resolve<DestroyBitmap>("FPDFBitmap_Destroy");
        closePage = Resolve<ClosePage>("FPDF_ClosePage");
        closeDocument = Resolve<CloseDocument>("FPDF_CloseDocument");
        if (!initLibrary || !destroyLibrary || !loadCustomDocument
            || !getLastError || !getPageCount || !loadPage
            || !getPageWidth || !getPageHeight || !createBitmap
            || !fillBitmap || !renderPageBitmap || !destroyBitmap
            || !closePage || !closeDocument)
            return false;
        initLibrary();
        initialized_ = true;
        return true;
    }

    InitLibrary initLibrary = nullptr;
    DestroyLibrary destroyLibrary = nullptr;
    LoadCustomDocument loadCustomDocument = nullptr;
    GetLastError getLastError = nullptr;
    GetPageCount getPageCount = nullptr;
    LoadPage loadPage = nullptr;
    GetPageDimension getPageWidth = nullptr;
    GetPageDimension getPageHeight = nullptr;
    CreateBitmap createBitmap = nullptr;
    FillBitmap fillBitmap = nullptr;
    RenderPageBitmap renderPageBitmap = nullptr;
    DestroyBitmap destroyBitmap = nullptr;
    ClosePage closePage = nullptr;
    CloseDocument closeDocument = nullptr;

private:
    template <typename T>
    T Resolve(const char* name) {
        return reinterpret_cast<T>(GetProcAddress(module_, name));
    }

    HMODULE module_ = nullptr;
    bool initialized_ = false;
};

template <typename T>
T& Field(BYTE* mapping, size_t offset) {
    return *reinterpret_cast<T*>(mapping + offset);
}

struct Request {
    uint32_t command = 0;
    int64_t generation = 0;
    int64_t listInstance = 0;
    int64_t panelSession = 0;
    int64_t requestId = 0;
    uint32_t maxWidth = 0;
    uint32_t maxHeight = 0;
    uint32_t maxFileMB = 64;
    uint32_t maxEdge = 65535;
    uint32_t maxPixelsMP = 160;
    uint32_t maxExpandedMB = 256;
    bool cacheEnabled = true;
    uint32_t cacheMaxMB = 256;
    uint32_t cacheMaxItems = 1000;
    uint32_t cacheItemMaxKB = 2048;
    uint32_t cacheUnreferencedDays = 7;
    uint32_t cacheTargetEdge = 1024;
    uint32_t dpi = 96;
    uint32_t themeVersion = 1;
    std::wstring path;
    std::wstring cacheRoot;
};

struct Image {
    UINT width = 0;
    UINT height = 0;
    UINT stride = 0;
    bool hasAlpha = false;
    std::vector<BYTE> pixels; // premultiplied BGRA, top down
};

struct FileIdentity {
    DWORD volumeSerial = 0;
    uint64_t fileId = 0;
    uint64_t size = 0;
    FILETIME writeTime{};
};

bool SafeMultiply(uint64_t a, uint64_t b, uint64_t limit,
                  uint64_t& result) {
    if (a != 0 && b > std::numeric_limits<uint64_t>::max() / a)
        return false;
    result = a * b;
    return result <= limit;
}

Request SnapshotRequest(BYTE* mapping) {
    Request request;
    request.command = Field<uint32_t>(mapping, 8);
    request.generation = Field<int64_t>(mapping, 16);
    request.listInstance = Field<int64_t>(mapping, 24);
    request.panelSession = Field<int64_t>(mapping, 32);
    request.requestId = Field<int64_t>(mapping, 40);
    request.maxWidth = std::clamp(Field<uint32_t>(mapping, 48), 1u, 1024u);
    request.maxHeight = std::clamp(Field<uint32_t>(mapping, 52), 1u, 1024u);
    request.maxFileMB = std::clamp(Field<uint32_t>(mapping, 56), 1u, 256u);
    request.maxEdge = std::clamp(Field<uint32_t>(mapping, 60), 1024u, 65535u);
    request.maxPixelsMP = std::clamp(Field<uint32_t>(mapping, 64), 1u, 500u);
    request.maxExpandedMB = std::clamp(
        Field<uint32_t>(mapping, 68), 16u, 512u);
    request.cacheEnabled = Field<uint32_t>(mapping, 72) != 0;
    request.cacheMaxMB = std::clamp(
        Field<uint32_t>(mapping, 76), 16u, 4096u);
    request.cacheMaxItems = std::clamp(
        Field<uint32_t>(mapping, 80), 10u, 50000u);
    request.cacheItemMaxKB = std::clamp(
        Field<uint32_t>(mapping, 84), 128u, 2048u);
    request.cacheUnreferencedDays = std::clamp(
        Field<uint32_t>(mapping, 88), 1u, 365u);
    request.cacheTargetEdge = std::clamp(
        Field<uint32_t>(mapping, 92), 180u, 1024u);
    request.dpi = std::clamp(
        Field<uint32_t>(mapping, 96), 96u, 480u);
    request.themeVersion = std::clamp(
        Field<uint32_t>(mapping, 100), 1u, 1000u);
    request.path.assign(
        reinterpret_cast<wchar_t*>(mapping + kPathOffset),
        wcsnlen_s(reinterpret_cast<wchar_t*>(mapping + kPathOffset),
                  kPathChars));
    request.cacheRoot.assign(
        reinterpret_cast<wchar_t*>(mapping + kCacheRootOffset),
        wcsnlen_s(reinterpret_cast<wchar_t*>(mapping + kCacheRootOffset),
                  kCacheRootChars));
    return request;
}

bool SameRequest(BYTE* mapping, const Request& request) {
    return Field<int64_t>(mapping, 16) == request.generation
        && Field<int64_t>(mapping, 24) == request.listInstance
        && Field<int64_t>(mapping, 32) == request.panelSession
        && Field<int64_t>(mapping, 40) == request.requestId;
}

bool GetIdentity(const std::wstring& path, FileIdentity& identity,
                 DWORD& attributes) {
    WIN32_FILE_ATTRIBUTE_DATA data{};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &data))
        return false;
    attributes = data.dwFileAttributes;
    if ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0)
        return false;
    constexpr DWORD cloudOnly = FILE_ATTRIBUTE_OFFLINE
        | FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS
        | FILE_ATTRIBUTE_RECALL_ON_OPEN;
    if ((attributes & cloudOnly) != 0)
        return false; // Never hydrate an online-only placeholder.
    identity.size = (static_cast<uint64_t>(data.nFileSizeHigh) << 32)
        | data.nFileSizeLow;
    identity.writeTime = data.ftLastWriteTime;

    HANDLE file = CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (file == INVALID_HANDLE_VALUE)
        return true; // Path/size/write time remains the stable fallback.
    BY_HANDLE_FILE_INFORMATION info{};
    if (GetFileInformationByHandle(file, &info)) {
        identity.volumeSerial = info.dwVolumeSerialNumber;
        identity.fileId = (static_cast<uint64_t>(info.nFileIndexHigh) << 32)
            | info.nFileIndexLow;
    }
    CloseHandle(file);
    return true;
}

std::wstring Hex(const BYTE* bytes, size_t count) {
    static constexpr wchar_t digits[] = L"0123456789abcdef";
    std::wstring result(count * 2, L'0');
    for (size_t i = 0; i < count; ++i) {
        result[i * 2] = digits[bytes[i] >> 4];
        result[i * 2 + 1] = digits[bytes[i] & 0x0f];
    }
    return result;
}

std::wstring LowerExtension(const std::wstring& path) {
    std::wstring extension = std::filesystem::path(path).extension().wstring();
    std::transform(extension.begin(), extension.end(), extension.begin(),
        [](wchar_t value) { return std::towlower(value); });
    return extension;
}

bool ExtensionIn(const std::wstring& path,
                 const std::unordered_set<std::wstring>& extensions) {
    return extensions.count(LowerExtension(path)) != 0;
}

bool IsMarkdownDocument(const std::wstring& path) {
    static const std::unordered_set<std::wstring> extensions{
        L".md", L".markdown"};
    return ExtensionIn(path, extensions);
}

bool IsDelimitedDocument(const std::wstring& path) {
    static const std::unordered_set<std::wstring> extensions{
        L".csv", L".tsv"};
    return ExtensionIn(path, extensions);
}

bool IsTextDocument(const std::wstring& path) {
    static const std::unordered_set<std::wstring> extensions{
        L".txt", L".log", L".ini", L".cfg", L".conf",
        L".json", L".jsonc", L".yaml", L".yml", L".xml", L".ahk",
        L".c", L".cc", L".cpp", L".cxx", L".h", L".hh", L".hpp",
        L".cs", L".java", L".kt", L".kts", L".go", L".rs", L".swift",
        L".py", L".pyw", L".js", L".jsx", L".ts", L".tsx",
        L".html", L".htm", L".css", L".scss", L".less", L".sql",
        L".ps1", L".psm1", L".bat", L".cmd", L".sh", L".zsh",
        L".toml", L".properties", L".gradle", L".cmake",
        L".dockerfile", L".vue", L".svelte", L".rb", L".php",
        L".lua", L".r", L".dart", L".ex", L".exs",
        L".md", L".markdown", L".csv", L".tsv"};
    return ExtensionIn(path, extensions);
}

bool IsPdfDocument(const std::wstring& path) {
    return LowerExtension(path) == L".pdf";
}

bool IsDocxDocument(const std::wstring& path) {
    return LowerExtension(path) == L".docx";
}

bool IsDocument(const std::wstring& path) {
    return IsTextDocument(path) || IsPdfDocument(path)
        || IsDocxDocument(path);
}

std::wstring RendererId(const std::wstring& path) {
    if (IsMarkdownDocument(path)) return L"markdown-semantic";
    if (IsDelimitedDocument(path)) return L"delimited-table";
    if (IsTextDocument(path)) return L"text-code";
    if (IsPdfDocument(path))
        return L"pdf-pdfium-or-winrt-or-shell-first-page";
    if (IsDocxDocument(path)) return L"docx-semantic-or-shell";
    return L"image-wic-shell";
}

std::wstring CacheKey(const Request& request,
                      const FileIdentity& identity) {
    const std::wstring& path = request.path;
    std::wstring material;
    if (identity.fileId != 0) {
        material = std::to_wstring(identity.volumeSerial) + L"|"
            + std::to_wstring(identity.fileId);
    } else {
        material = std::filesystem::path(path).lexically_normal().wstring();
        std::transform(material.begin(), material.end(), material.begin(),
            [](wchar_t value) { return std::towlower(value); });
    }
    const uint64_t write = (static_cast<uint64_t>(
        identity.writeTime.dwHighDateTime) << 32)
        | identity.writeTime.dwLowDateTime;
    material += L"|" + std::to_wstring(identity.size)
        + L"|" + std::to_wstring(write)
        + L"|" + RendererId(path)
        + L"|" + std::to_wstring(kPreviewSpecVersion)
        + L"|" + std::to_wstring(request.cacheTargetEdge)
        + L"|" + std::to_wstring(request.dpi)
        + L"|" + std::to_wstring(request.themeVersion);

    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    std::array<BYTE, 32> digest{};
    DWORD objectBytes = 0;
    DWORD returned = 0;
    std::vector<BYTE> object;
    if (BCryptOpenAlgorithmProvider(
            &algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0)
        return L"";
    if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
            reinterpret_cast<BYTE*>(&objectBytes), sizeof(objectBytes),
            &returned, 0) < 0)
        goto cleanup;
    object.resize(objectBytes);
    if (BCryptCreateHash(algorithm, &hash, object.data(),
            static_cast<ULONG>(object.size()), nullptr, 0, 0) < 0)
        goto cleanup;
    if (BCryptHashData(hash, reinterpret_cast<BYTE*>(material.data()),
            static_cast<ULONG>(material.size() * sizeof(wchar_t)), 0) < 0)
        goto cleanup;
    if (BCryptFinishHash(hash, digest.data(),
            static_cast<ULONG>(digest.size()), 0) < 0)
        digest.fill(0);
cleanup:
    if (hash) BCryptDestroyHash(hash);
    if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
    const bool valid = std::any_of(digest.begin(), digest.end(),
        [](BYTE value) { return value != 0; });
    return valid ? Hex(digest.data(), digest.size()) : L"";
}

bool IsSafeCacheRoot(const std::wstring& root) {
    if (root.empty())
        return false;
    std::filesystem::path path(root);
    if (_wcsicmp(path.filename().c_str(), L"preview-cache-v1") != 0)
        return false;
    const DWORD attributes = GetFileAttributesW(root.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES)
        return CreateDirectoryW(root.c_str(), nullptr) != FALSE;
    return (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0
        && (attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0;
}

WICBitmapTransformOptions ReadOrientation(IWICBitmapFrameDecode* frame) {
    ComPtr<IWICMetadataQueryReader> reader;
    if (FAILED(frame->GetMetadataQueryReader(reader.put())))
        return WICBitmapTransformRotate0;
    PROPVARIANT value;
    PropVariantInit(&value);
    HRESULT hr = reader->GetMetadataByName(
        L"/app1/ifd/{ushort=274}", &value);
    if (FAILED(hr))
        hr = reader->GetMetadataByName(L"/ifd/{ushort=274}", &value);
    unsigned orientation = 1;
    if (SUCCEEDED(hr)) {
        if (value.vt == VT_UI2) orientation = value.uiVal;
        else if (value.vt == VT_UI4) orientation = value.ulVal;
    }
    PropVariantClear(&value);
    switch (orientation) {
    case 2: return WICBitmapTransformFlipHorizontal;
    case 3: return WICBitmapTransformRotate180;
    case 4: return WICBitmapTransformFlipVertical;
    case 5: return static_cast<WICBitmapTransformOptions>(
        WICBitmapTransformRotate90 | WICBitmapTransformFlipHorizontal);
    case 6: return WICBitmapTransformRotate90;
    case 7: return static_cast<WICBitmapTransformOptions>(
        WICBitmapTransformRotate270 | WICBitmapTransformFlipHorizontal);
    case 8: return WICBitmapTransformRotate270;
    default: return WICBitmapTransformRotate0;
    }
}

void Fit(UINT sourceWidth, UINT sourceHeight, UINT maxWidth, UINT maxHeight,
         UINT& targetWidth, UINT& targetHeight) {
    if (sourceWidth == 0 || sourceHeight == 0) {
        targetWidth = targetHeight = 0;
        return;
    }
    const double scale = std::min({
        1.0,
        static_cast<double>(maxWidth) / sourceWidth,
        static_cast<double>(maxHeight) / sourceHeight});
    targetWidth = std::max(1u, static_cast<UINT>(sourceWidth * scale));
    targetHeight = std::max(1u, static_cast<UINT>(sourceHeight * scale));
}

bool CopyWicSource(IWICBitmapSource* source, UINT width, UINT height,
                   Image& image) {
    uint64_t bytes = 0;
    if (!SafeMultiply(width, 4, kMaxPixelBytes, bytes)
        || !SafeMultiply(bytes, height, kMaxPixelBytes, bytes))
        return false;
    image.width = width;
    image.height = height;
    image.stride = width * 4;
    image.pixels.assign(static_cast<size_t>(bytes), 0);
    if (FAILED(source->CopyPixels(nullptr, image.stride,
            static_cast<UINT>(image.pixels.size()), image.pixels.data())))
        return false;
    image.hasAlpha = false;
    for (size_t offset = 3; offset < image.pixels.size(); offset += 4) {
        if (image.pixels[offset] != 255) {
            image.hasAlpha = true;
            break;
        }
    }
    return true;
}

bool DecodeWicFile(const std::wstring& path, UINT maxWidth, UINT maxHeight,
                   const Request& request, Image& image) {
    ComPtr<IWICImagingFactory> factory;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
            CLSCTX_INPROC_SERVER, IID_PPV_ARGS(factory.put()))))
        return false;
    ComPtr<IWICBitmapDecoder> decoder;
    if (FAILED(factory->CreateDecoderFromFilename(path.c_str(), nullptr,
            GENERIC_READ, WICDecodeMetadataCacheOnDemand, decoder.put())))
        return false;
    ComPtr<IWICBitmapFrameDecode> frame;
    if (FAILED(decoder->GetFrame(0, frame.put())))
        return false; // Animated formats intentionally use the first frame.
    UINT width = 0;
    UINT height = 0;
    if (FAILED(frame->GetSize(&width, &height)) || width == 0 || height == 0)
        return false;
    if (width > request.maxEdge || height > request.maxEdge)
        return false;
    uint64_t pixels = 0;
    if (!SafeMultiply(width, height,
            static_cast<uint64_t>(request.maxPixelsMP) * 1000000, pixels))
        return false;
    const WICBitmapTransformOptions orientation = ReadOrientation(frame.get());
    UINT colorContextCount = 0;
    const bool hasEmbeddedColorContext =
        SUCCEEDED(frame->GetColorContexts(0, nullptr, &colorContextCount))
        && colorContextCount != 0;
    const bool swapsAxes = (orientation & WICBitmapTransformRotate90)
        || (orientation & WICBitmapTransformRotate270);
    UINT orientedWidth = swapsAxes ? height : width;
    UINT orientedHeight = swapsAxes ? width : height;
    UINT targetWidth = 0;
    UINT targetHeight = 0;
    Fit(orientedWidth, orientedHeight, maxWidth, maxHeight,
        targetWidth, targetHeight);

    // Prefer the codec's native transform path so very large JPEG/RAW images
    // need not be expanded to a full intermediate RGBA bitmap.
    ComPtr<IWICBitmapSourceTransform> nativeTransform;
    if (!hasEmbeddedColorContext
        && SUCCEEDED(frame.as(nativeTransform))) {
        UINT nativeWidth = targetWidth;
        UINT nativeHeight = targetHeight;
        WICPixelFormatGUID format = GUID_WICPixelFormat32bppPBGRA;
        BOOL supports = FALSE;
        if (SUCCEEDED(nativeTransform->DoesSupportTransform(
                orientation, &supports)) && supports
            && SUCCEEDED(nativeTransform->GetClosestSize(
                &nativeWidth, &nativeHeight))
            && SUCCEEDED(nativeTransform->GetClosestPixelFormat(&format))
            && IsEqualGUID(format, GUID_WICPixelFormat32bppPBGRA)) {
            uint64_t bytes = 0;
            if (SafeMultiply(nativeWidth, 4, kMaxPixelBytes, bytes)
                && SafeMultiply(bytes, nativeHeight,
                    kMaxPixelBytes, bytes)) {
                image.width = nativeWidth;
                image.height = nativeHeight;
                image.stride = nativeWidth * 4;
                image.pixels.resize(static_cast<size_t>(bytes));
                if (SUCCEEDED(nativeTransform->CopyPixels(nullptr,
                        nativeWidth, nativeHeight, &format, orientation,
                        image.stride, static_cast<UINT>(image.pixels.size()),
                        image.pixels.data()))) {
                    image.hasAlpha = false;
                    for (size_t i = 3; i < image.pixels.size(); i += 4) {
                        if (image.pixels[i] != 255) {
                            image.hasAlpha = true;
                            break;
                        }
                    }
                    return true;
                }
            }
        }
    }

    uint64_t expanded = 0;
    if (!SafeMultiply(width, height,
            std::numeric_limits<uint64_t>::max(), expanded)
        || !SafeMultiply(expanded, 4,
            static_cast<uint64_t>(request.maxExpandedMB) * 1024 * 1024,
            expanded))
        return false;

    ComPtr<IWICBitmapSource> current;
    frame->AddRef();
    current.reset(frame.get());
    if (targetWidth != orientedWidth || targetHeight != orientedHeight) {
        UINT preWidth = swapsAxes ? targetHeight : targetWidth;
        UINT preHeight = swapsAxes ? targetWidth : targetHeight;
        ComPtr<IWICBitmapScaler> scaler;
        if (FAILED(factory->CreateBitmapScaler(scaler.put()))
            || FAILED(scaler->Initialize(current.get(), preWidth, preHeight,
                WICBitmapInterpolationModeFant)))
            return false;
        current.reset();
        scaler->AddRef();
        current.reset(scaler.get());
    }
    if (orientation != WICBitmapTransformRotate0) {
        ComPtr<IWICBitmapFlipRotator> rotator;
        if (FAILED(factory->CreateBitmapFlipRotator(rotator.put()))
            || FAILED(rotator->Initialize(current.get(), orientation)))
            return false;
        current.reset();
        rotator->AddRef();
        current.reset(rotator.get());
    }
    // Convert embedded profiles to the standard sRGB color space after
    // scaling/orientation, keeping large intermediates bounded.
    if (hasEmbeddedColorContext) {
        ComPtr<IWICColorContext> sourceContext;
        ComPtr<IWICColorContext> destinationContext;
        ComPtr<IWICColorTransform> colorTransform;
        IWICColorContext* sourceArray[1]{};
        UINT actualContexts = 0;
        if (SUCCEEDED(factory->CreateColorContext(sourceContext.put()))) {
            sourceArray[0] = sourceContext.get();
        }
        if (sourceArray[0]
            && SUCCEEDED(frame->GetColorContexts(
                1, sourceArray, &actualContexts))
            && actualContexts > 0) {
            if (SUCCEEDED(factory->CreateColorContext(
                    destinationContext.put()))
                && SUCCEEDED(destinationContext->InitializeFromExifColorSpace(1))
                && SUCCEEDED(factory->CreateColorTransformer(
                    colorTransform.put()))
                && SUCCEEDED(colorTransform->Initialize(current.get(),
                    sourceContext.get(), destinationContext.get(),
                    GUID_WICPixelFormat32bppBGRA))) {
                current.reset();
                colorTransform->AddRef();
                current.reset(colorTransform.get());
            }
        }
    }
    ComPtr<IWICFormatConverter> converter;
    if (FAILED(factory->CreateFormatConverter(converter.put()))
        || FAILED(converter->Initialize(current.get(),
            GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone,
            nullptr, 0.0, WICBitmapPaletteTypeCustom)))
        return false;
    return CopyWicSource(converter.get(), targetWidth, targetHeight, image);
}

bool DecodeWicStream(IStream* stream, Image& image) {
    if (!stream)
        return false;
    ComPtr<IWICImagingFactory> factory;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
            CLSCTX_INPROC_SERVER, IID_PPV_ARGS(factory.put()))))
        return false;
    ComPtr<IWICBitmapDecoder> decoder;
    if (FAILED(factory->CreateDecoderFromStream(stream, nullptr,
            WICDecodeMetadataCacheOnLoad, decoder.put())))
        return false;
    ComPtr<IWICBitmapFrameDecode> frame;
    if (FAILED(decoder->GetFrame(0, frame.put())))
        return false;
    UINT width = 0;
    UINT height = 0;
    if (FAILED(frame->GetSize(&width, &height)) || width == 0 || height == 0)
        return false;
    uint64_t pixels = 0;
    if (!SafeMultiply(width, height, kMaxPixelBytes / 4, pixels))
        return false;
    ComPtr<IWICFormatConverter> converter;
    if (FAILED(factory->CreateFormatConverter(converter.put()))
        || FAILED(converter->Initialize(frame.get(),
            GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone,
            nullptr, 0.0, WICBitmapPaletteTypeCustom)))
        return false;
    return CopyWicSource(converter.get(), width, height, image);
}

bool DecodeWicMemory(std::vector<BYTE>& bytes, Image& image) {
    if (bytes.empty() || bytes.size() > std::numeric_limits<DWORD>::max())
        return false;
    ComPtr<IWICImagingFactory> factory;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
            CLSCTX_INPROC_SERVER, IID_PPV_ARGS(factory.put()))))
        return false;
    ComPtr<IWICStream> stream;
    if (FAILED(factory->CreateStream(stream.put()))
        || FAILED(stream->InitializeFromMemory(
            bytes.data(), static_cast<DWORD>(bytes.size()))))
        return false;
    return DecodeWicStream(stream.get(), image);
}

bool RenderPdfFirstPagePdfium(const Request& request, Image& image,
                              uint32_t& failureStatus) {
    PdfiumApi pdfium;
    if (!pdfium.Load())
        return false;
    PdfiumFileContext context;
    context.file = CreateFileW(request.path.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_RANDOM_ACCESS,
        nullptr);
    if (context.file == INVALID_HANDLE_VALUE) {
        failureStatus = kStatusInaccessible;
        return false;
    }
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(context.file, &size) || size.QuadPart <= 0
        || static_cast<uint64_t>(size.QuadPart)
            > std::numeric_limits<unsigned long>::max()) {
        CloseHandle(context.file);
        failureStatus = kStatusResourceLimit;
        return false;
    }
    PdfiumFileAccess access{
        static_cast<unsigned long>(size.QuadPart),
        PdfiumReadBlock,
        &context
    };
    PdfiumDocument document = pdfium.loadCustomDocument(&access, nullptr);
    if (!document) {
        const unsigned long error = pdfium.getLastError();
        CloseHandle(context.file);
        failureStatus = context.resourceLimit ? kStatusResourceLimit
            : (error == 4 ? kStatusPasswordProtected
            : (error == 2 ? kStatusInaccessible
            : kStatusCorruptOrUnsupported));
        return false;
    }
    if (pdfium.getPageCount(document) <= 0) {
        pdfium.closeDocument(document);
        CloseHandle(context.file);
        return false;
    }
    PdfiumPage page = pdfium.loadPage(document, 0);
    if (!page) {
        pdfium.closeDocument(document);
        CloseHandle(context.file);
        return false;
    }
    const float pageWidth = pdfium.getPageWidth(page);
    const float pageHeight = pdfium.getPageHeight(page);
    if (!(pageWidth > 0.0f) || !(pageHeight > 0.0f)) {
        pdfium.closePage(page);
        pdfium.closeDocument(document);
        CloseHandle(context.file);
        return false;
    }
    UINT targetWidth = 0;
    UINT targetHeight = 0;
    Fit(std::max(1u, static_cast<UINT>(pageWidth + 0.5f)),
        std::max(1u, static_cast<UINT>(pageHeight + 0.5f)),
        request.maxWidth, request.maxHeight, targetWidth, targetHeight);
    uint64_t pixelBytes = 0;
    if (!SafeMultiply(targetWidth, targetHeight, kMaxPixelBytes / 4,
            pixelBytes)
        || !SafeMultiply(pixelBytes, 4, kMaxPixelBytes, pixelBytes)) {
        pdfium.closePage(page);
        pdfium.closeDocument(document);
        CloseHandle(context.file);
        failureStatus = kStatusResourceLimit;
        return false;
    }
    image.width = targetWidth;
    image.height = targetHeight;
    image.stride = targetWidth * 4;
    image.pixels.assign(static_cast<size_t>(pixelBytes), 255);
    PdfiumBitmap bitmap = pdfium.createBitmap(
        static_cast<int>(targetWidth), static_cast<int>(targetHeight),
        4, image.pixels.data(), static_cast<int>(image.stride));
    if (!bitmap) {
        image = {};
        pdfium.closePage(page);
        pdfium.closeDocument(document);
        CloseHandle(context.file);
        failureStatus = kStatusResourceLimit;
        return false;
    }
    pdfium.fillBitmap(bitmap, 0, 0,
        static_cast<int>(targetWidth), static_cast<int>(targetHeight),
        0xFFFFFFFF);
    constexpr int renderFlags =
        0x02 /* FPDF_LCD_TEXT */ | 0x200 /* limited image cache */;
    pdfium.renderPageBitmap(bitmap, page, 0, 0,
        static_cast<int>(targetWidth), static_cast<int>(targetHeight),
        0, renderFlags);
    pdfium.destroyBitmap(bitmap);
    pdfium.closePage(page);
    pdfium.closeDocument(document);
    CloseHandle(context.file);
    if (context.resourceLimit) {
        image = {};
        failureStatus = kStatusResourceLimit;
        return false;
    }
    for (size_t index = 3; index < image.pixels.size(); index += 4)
        image.pixels[index] = 255;
    image.hasAlpha = false;
    failureStatus = kStatusReady;
    return true;
}

bool RenderPdfFirstPageWinRt(const Request& request, Image& image,
                             uint32_t& failureStatus) {
    failureStatus = kStatusCorruptOrUnsupported;
    try {
        using namespace winrt::Windows;
        Storage::Streams::IRandomAccessStream input{nullptr};
        const HRESULT openResult = CreateRandomAccessStreamOnFile(
            request.path.c_str(),
            static_cast<DWORD>(Storage::FileAccessMode::Read),
            winrt::guid_of<Storage::Streams::IRandomAccessStream>(),
            winrt::put_abi(input));
        if (FAILED(openResult)) {
            if (HRESULT_FACILITY(openResult) == FACILITY_WIN32) {
                const DWORD error = HRESULT_CODE(openResult);
                if (error == ERROR_ACCESS_DENIED
                    || error == ERROR_SHARING_VIOLATION
                    || error == ERROR_LOCK_VIOLATION
                    || error == ERROR_FILE_NOT_FOUND
                    || error == ERROR_PATH_NOT_FOUND)
                    failureStatus = kStatusInaccessible;
            }
            return false;
        }
        const auto document =
            Data::Pdf::PdfDocument::LoadFromStreamAsync(input).get();
        if (document.PageCount() == 0)
            return false;
        const auto page = document.GetPage(0);
        const auto dimensions = page.Dimensions();
        const auto mediaBox = dimensions.MediaBox();
        if (mediaBox.Width <= 0.0f || mediaBox.Height <= 0.0f)
            return false;
        UINT targetWidth = 0;
        UINT targetHeight = 0;
        Fit(static_cast<UINT>(mediaBox.Width + 0.5f),
            static_cast<UINT>(mediaBox.Height + 0.5f),
            request.maxWidth, request.maxHeight,
            targetWidth, targetHeight);
        Data::Pdf::PdfPageRenderOptions options;
        options.DestinationWidth(targetWidth);
        options.DestinationHeight(targetHeight);
        options.BackgroundColor(UI::Colors::White());
        Storage::Streams::InMemoryRandomAccessStream output;
        page.PreparePageAsync().get();
        page.RenderToStreamAsync(output, options).get();
        page.Close();
        constexpr uint64_t encodedBudget = 16ull * 1024 * 1024;
        const uint64_t encodedBytes = output.Size();
        if (encodedBytes == 0 || encodedBytes > encodedBudget
            || encodedBytes > std::numeric_limits<uint32_t>::max()) {
            failureStatus = kStatusResourceLimit;
            return false;
        }
        output.Seek(0);
        ComPtr<IStream> encoded;
        if (FAILED(CreateStreamOverRandomAccessStream(
                winrt::get_unknown(output), IID_IStream,
                reinterpret_cast<void**>(encoded.put()))))
            return false;
        if (!DecodeWicStream(encoded.get(), image))
            return false;
        failureStatus = kStatusReady;
        return true;
    } catch (const winrt::hresult_error& error) {
        if (error.code() == E_ACCESSDENIED)
            failureStatus = kStatusInaccessible;
        return false;
    } catch (...) {
        return false;
    }
}

bool RenderPdfFirstPage(const Request& request, Image& image,
                        uint32_t& failureStatus) {
    if (RenderPdfFirstPagePdfium(request, image, failureStatus))
        return true;
    const uint32_t pdfiumFailure = failureStatus;
    if (RenderPdfFirstPageWinRt(request, image, failureStatus))
        return true;
    if (pdfiumFailure == kStatusPasswordProtected
        || pdfiumFailure == kStatusResourceLimit
        || pdfiumFailure == kStatusInaccessible)
        failureStatus = pdfiumFailure;
    return false;
}

bool ReadBoundedPrefix(const std::wstring& path, uint64_t budget,
                       std::vector<BYTE>& bytes, DWORD& error) {
    error = ERROR_SUCCESS;
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN,
        nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        error = GetLastError();
        return false;
    }
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(file, &size)) {
        error = GetLastError();
        CloseHandle(file);
        return false;
    }
    const DWORD wanted = static_cast<DWORD>(std::min<uint64_t>(
        std::max<LONGLONG>(0, size.QuadPart), budget));
    bytes.resize(wanted);
    DWORD read = 0;
    const bool success = wanted == 0
        || ReadFile(file, bytes.data(), wanted, &read, nullptr) != FALSE;
    error = success ? ERROR_SUCCESS : GetLastError();
    CloseHandle(file);
    if (!success)
        return false;
    bytes.resize(read);
    return true;
}

bool DecodeTextPrefix(const std::vector<BYTE>& bytes, std::wstring& text) {
    text.clear();
    if (bytes.empty())
        return true;
    size_t zeros = 0;
    for (BYTE value : bytes)
        zeros += value == 0;
    const bool utf16Bom = bytes.size() >= 2
        && ((bytes[0] == 0xff && bytes[1] == 0xfe)
            || (bytes[0] == 0xfe && bytes[1] == 0xff));
    if (!utf16Bom && zeros > std::max<size_t>(8, bytes.size() / 50))
        return false;
    if (bytes.size() >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
        const size_t count = (bytes.size() - 2) / sizeof(wchar_t);
        text.assign(reinterpret_cast<const wchar_t*>(bytes.data() + 2), count);
        return true;
    }
    if (bytes.size() >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
        const size_t count = (bytes.size() - 2) / 2;
        text.resize(count);
        for (size_t index = 0; index < count; ++index)
            text[index] = static_cast<wchar_t>(
                (bytes[2 + index * 2] << 8) | bytes[3 + index * 2]);
        return true;
    }
    size_t offset = bytes.size() >= 3 && bytes[0] == 0xef
        && bytes[1] == 0xbb && bytes[2] == 0xbf ? 3 : 0;
    const char* source = reinterpret_cast<const char*>(bytes.data() + offset);
    const int sourceBytes = static_cast<int>(bytes.size() - offset);
    int chars = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        source, sourceBytes, nullptr, 0);
    UINT codePage = CP_UTF8;
    DWORD flags = MB_ERR_INVALID_CHARS;
    if (!chars) {
        codePage = CP_ACP;
        flags = 0;
        chars = MultiByteToWideChar(codePage, flags,
            source, sourceBytes, nullptr, 0);
    }
    if (!chars)
        return false;
    text.resize(chars);
    MultiByteToWideChar(codePage, flags,
        source, sourceBytes, text.data(), chars);
    return true;
}

std::vector<std::wstring> SplitBoundedLines(const std::wstring& text) {
    std::vector<std::wstring> lines;
    size_t start = 0;
    while (start <= text.size() && lines.size() < kTextLineLimit) {
        size_t end = text.find(L'\n', start);
        if (end == std::wstring::npos)
            end = text.size();
        size_t length = end - start;
        if (length && text[start + length - 1] == L'\r')
            --length;
        std::wstring line = text.substr(
            start, std::min(length, kTextLineCharacterLimit));
        if (length > kTextLineCharacterLimit)
            line += L" …";
        lines.push_back(std::move(line));
        if (end == text.size())
            break;
        start = end + 1;
    }
    if (start < text.size() && !lines.empty())
        lines.back() += L"  ⋯";
    return lines;
}

std::vector<std::wstring> ParseDelimitedPreview(
        const std::wstring& text, wchar_t delimiter) {
    std::vector<std::wstring> result;
    std::wstring row;
    std::vector<std::wstring> cells;
    std::wstring cell;
    bool quoted = false;
    auto finishRow = [&]() {
        if (cells.size() < 12)
            cells.push_back(cell);
        std::wstring rendered;
        for (size_t index = 0; index < cells.size() && index < 12; ++index) {
            std::wstring value = cells[index];
            if (value.size() > 36)
                value = value.substr(0, 35) + L"…";
            if (index) rendered += L"  │  ";
            rendered += value;
        }
        if (cells.size() > 12)
            rendered += L"  │  ⋯";
        result.push_back(std::move(rendered));
        cells.clear();
        cell.clear();
    };
    for (size_t index = 0; index < text.size() && result.size() < 30; ++index) {
        const wchar_t value = text[index];
        if (value == L'"') {
            if (quoted && index + 1 < text.size() && text[index + 1] == L'"') {
                cell += L'"';
                ++index;
            } else {
                quoted = !quoted;
            }
        } else if (value == delimiter && !quoted) {
            if (cells.size() < 12)
                cells.push_back(cell);
            cell.clear();
        } else if ((value == L'\r' || value == L'\n') && !quoted) {
            if (value == L'\r' && index + 1 < text.size()
                && text[index + 1] == L'\n')
                ++index;
            finishRow();
        } else if (cell.size() < kTextLineCharacterLimit) {
            cell += value;
        }
    }
    if ((!cell.empty() || !cells.empty()) && result.size() < 30)
        finishRow();
    if (result.size() == 30)
        result.push_back(L"⋯");
    return result;
}

std::wstring MarkdownDisplayLine(std::wstring line) {
    size_t first = line.find_first_not_of(L" \t");
    if (first == std::wstring::npos)
        return L"";
    size_t hashes = 0;
    while (first + hashes < line.size() && line[first + hashes] == L'#')
        ++hashes;
    const bool heading = hashes && first + hashes < line.size()
        && line[first + hashes] == L' ';
    const bool bold = line.find(L"**") != std::wstring::npos
        || line.find(L"__") != std::wstring::npos;
    const bool italic = !bold
        && (line.find(L'*') != std::wstring::npos
            || line.find(L'_') != std::wstring::npos);
    const bool code = first >= 4
        || line.compare(first, 3, L"```") == 0
        || line.compare(first, 3, L"~~~") == 0
        || line.compare(first, 1, L"\t") == 0;
    if (heading
        && line[first + hashes] == L' ')
        line.erase(first, hashes + 1);
    if (line.compare(first, 3, L"- [") == 0
        && first + 5 < line.size() && line[first + 4] == L']') {
        line.replace(first, 5,
            (line[first + 3] == L'x' || line[first + 3] == L'X')
                ? L"☑" : L"☐");
    } else if (line.compare(first, 2, L"- ") == 0
        || line.compare(first, 2, L"* ") == 0
        || line.compare(first, 2, L"+ ") == 0) {
        line.replace(first, 2, L"• ");
    } else if (line[first] == L'>') {
        line.replace(first, 1, L"│");
    }
    for (const wchar_t marker : {L'*', L'_', L'`'})
        line.erase(std::remove(line.begin(), line.end(), marker), line.end());
    if (heading) line.insert(line.begin(), L'\x1');
    else if (code) line.insert(line.begin(), L'\x4');
    else if (bold) line.insert(line.begin(), L'\x2');
    else if (italic) line.insert(line.begin(), L'\x3');
    return line;
}

int MeasureTextWidth(HDC dc, const std::wstring& text) {
    if (text.empty())
        return 0;
    SIZE size{};
    return GetTextExtentPoint32W(dc, text.c_str(),
        static_cast<int>(text.size()), &size) ? size.cx : 0;
}

std::vector<std::wstring> WrapVisualLines(
        HDC dc, std::wstring text, int maxWidth, size_t maxLines) {
    std::replace(text.begin(), text.end(), L'\t', L' ');
    std::vector<std::wstring> result;
    size_t position = 0;
    while (position < text.size() && result.size() < maxLines) {
        while (position < text.size() && text[position] == L' ')
            ++position;
        if (position >= text.size())
            break;
        size_t low = 1;
        size_t high = text.size() - position;
        size_t fit = 0;
        while (low <= high) {
            const size_t middle = low + (high - low) / 2;
            if (MeasureTextWidth(dc, text.substr(position, middle))
                    <= maxWidth) {
                fit = middle;
                low = middle + 1;
            } else {
                high = middle - 1;
            }
        }
        if (fit == 0)
            fit = 1;
        size_t take = fit;
        if (position + fit < text.size()) {
            const size_t space = text.rfind(L' ', position + fit - 1);
            if (space != std::wstring::npos && space > position)
                take = space - position;
        }
        std::wstring visual = text.substr(position, take);
        position += take;
        while (position < text.size() && text[position] == L' ')
            ++position;
        const bool lastAllowed = result.size() + 1 == maxLines;
        if (lastAllowed && position < text.size()) {
            const std::wstring ellipsis = L"…";
            while (!visual.empty()
                && MeasureTextWidth(dc, visual + ellipsis) > maxWidth)
                visual.pop_back();
            visual += ellipsis;
            position = text.size();
        }
        result.push_back(std::move(visual));
    }
    if (result.empty())
        result.push_back(L"");
    return result;
}

bool RenderTextDocument(const Request& request, Image& image,
                        uint32_t& failureStatus,
                        const std::wstring* suppliedText = nullptr,
                        const std::wstring* suppliedTitle = nullptr) {
    std::wstring text;
    if (suppliedText) {
        text = *suppliedText;
    } else {
        std::vector<BYTE> bytes;
        DWORD error = ERROR_SUCCESS;
        if (!ReadBoundedPrefix(request.path, kTextReadBudget, bytes, error)) {
            failureStatus = kStatusInaccessible;
            return false;
        }
        if (!DecodeTextPrefix(bytes, text)) {
            failureStatus = kStatusCorruptOrUnsupported;
            return false;
        }
    }
    std::vector<std::wstring> lines;
    if (IsDelimitedDocument(request.path)) {
        lines = ParseDelimitedPreview(text,
            LowerExtension(request.path) == L".tsv" ? L'\t' : L',');
    } else {
        lines = SplitBoundedLines(text);
        if (IsMarkdownDocument(request.path)) {
            for (std::wstring& line : lines)
                line = MarkdownDisplayLine(std::move(line));
        }
    }
    const UINT width = std::clamp(request.maxWidth, 240u, 1024u);
    const UINT height = std::clamp(request.maxHeight, 180u, 1024u);
    uint64_t bytesNeeded = 0;
    if (!SafeMultiply(width, 4, kMaxPixelBytes, bytesNeeded)
        || !SafeMultiply(bytesNeeded, height, kMaxPixelBytes, bytesNeeded)) {
        failureStatus = kStatusResourceLimit;
        return false;
    }
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = static_cast<LONG>(width);
    info.bmiHeader.biHeight = -static_cast<LONG>(height);
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void* bits = nullptr;
    HDC dc = CreateCompatibleDC(nullptr);
    HBITMAP bitmap = CreateDIBSection(
        dc, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (!dc || !bitmap || !bits) {
        if (bitmap) DeleteObject(bitmap);
        if (dc) DeleteDC(dc);
        failureStatus = kStatusResourceLimit;
        return false;
    }
    HGDIOBJ oldBitmap = SelectObject(dc, bitmap);
    RECT page{0, 0, static_cast<LONG>(width), static_cast<LONG>(height)};
    HBRUSH paper = CreateSolidBrush(RGB(250, 250, 248));
    FillRect(dc, &page, paper);
    DeleteObject(paper);
    RECT header{0, 0, static_cast<LONG>(width), 42};
    HBRUSH headerBrush = CreateSolidBrush(RGB(238, 240, 244));
    FillRect(dc, &header, headerBrush);
    DeleteObject(headerBrush);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, RGB(42, 46, 54));
    const int baseSize = std::clamp<int>(
        MulDiv(14, request.dpi, 96), 13, 28);
    const wchar_t* face = (IsMarkdownDocument(request.path)
        || IsDelimitedDocument(request.path)) ? L"Segoe UI" : L"Consolas";
    HFONT bodyFont = CreateFontW(-baseSize, 0, 0, 0, FW_NORMAL,
        FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
        DEFAULT_PITCH | FF_DONTCARE, face);
    HFONT titleFont = CreateFontW(-std::clamp(baseSize + 2, 15, 30),
        0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
        DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
    HFONT headingFont = CreateFontW(-std::clamp(baseSize + 4, 17, 34),
        0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
        DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
    HFONT boldFont = CreateFontW(-baseSize, 0, 0, 0, FW_SEMIBOLD,
        FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
        DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
    HFONT italicFont = CreateFontW(-baseSize, 0, 0, 0, FW_NORMAL,
        TRUE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
        DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
    HFONT codeFont = CreateFontW(-baseSize, 0, 0, 0, FW_NORMAL,
        FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
        FIXED_PITCH | FF_MODERN, L"Consolas");
    HGDIOBJ oldFont = SelectObject(dc, titleFont);
    const std::wstring title = suppliedTitle ? *suppliedTitle
        : std::filesystem::path(request.path).filename().wstring();
    RECT titleRect{18, 9, static_cast<LONG>(width) - 18, 36};
    DrawTextW(dc, title.c_str(), static_cast<int>(title.size()), &titleRect,
        DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX | DT_VCENTER);
    SelectObject(dc, bodyFont);
    int y = 54;
    const int lineHeight = baseSize + 7;
    const int contentRight = static_cast<int>(width) - 18;
    for (const std::wstring& sourceLine : lines) {
        if (y + lineHeight > static_cast<int>(height) - 12)
            break;
        std::wstring line = sourceLine;
        HFONT lineFont = bodyFont;
        if (!line.empty() && line[0] >= L'\x1' && line[0] <= L'\x4') {
            const wchar_t style = line[0];
            line.erase(line.begin());
            lineFont = style == L'\x1' ? headingFont
                : (style == L'\x2' ? boldFont
                : (style == L'\x3' ? italicFont : codeFont));
        }
        SelectObject(dc, lineFont);
        TEXTMETRICW metrics{};
        GetTextMetricsW(dc, &metrics);
        const int fontLineHeight = std::max(lineHeight,
            static_cast<int>(metrics.tmHeight + metrics.tmExternalLeading));
        if (line.empty()) {
            y += std::max(4, fontLineHeight / 2);
            continue;
        }
        const std::vector<std::wstring> visualLines =
            WrapVisualLines(dc, line, contentRight - 18, 3);
        bool exhausted = false;
        for (const std::wstring& visual : visualLines) {
            if (y + fontLineHeight > static_cast<int>(height) - 12) {
                exhausted = true;
                break;
            }
            RECT lineRect{18, y, contentRight, y + fontLineHeight};
            DrawTextW(dc, visual.c_str(), static_cast<int>(visual.size()),
                &lineRect, DT_LEFT | DT_TOP | DT_SINGLELINE
                    | DT_END_ELLIPSIS | DT_NOPREFIX);
            y += fontLineHeight;
        }
        if (exhausted)
            break;
        if (!sourceLine.empty() && sourceLine[0] == L'\x1')
            y += std::max(2, baseSize / 4);
    }
    SelectObject(dc, oldFont);
    DeleteObject(bodyFont);
    DeleteObject(titleFont);
    DeleteObject(headingFont);
    DeleteObject(boldFont);
    DeleteObject(italicFont);
    DeleteObject(codeFont);
    image.width = width;
    image.height = height;
    image.stride = width * 4;
    image.pixels.assign(static_cast<BYTE*>(bits),
        static_cast<BYTE*>(bits) + bytesNeeded);
    for (size_t index = 3; index < image.pixels.size(); index += 4)
        image.pixels[index] = 255;
    image.hasAlpha = false;
    SelectObject(dc, oldBitmap);
    DeleteObject(bitmap);
    DeleteDC(dc);
    failureStatus = kStatusReady;
    return true;
}

bool ExtractDocxSemanticText(const std::wstring& path, std::wstring& text) {
    text.clear();
    ComPtr<IFilter> filter;
    if (FAILED(LoadIFilter(path.c_str(), nullptr,
            reinterpret_cast<void**>(filter.put()))))
        return false;
    ULONG flags = 0;
    const ULONG init = IFILTER_INIT_CANON_PARAGRAPHS
        | IFILTER_INIT_HARD_LINE_BREAKS
        | IFILTER_INIT_APPLY_INDEX_ATTRIBUTES;
    if (FAILED(filter->Init(init, 0, nullptr, &flags)))
        return false;
    STAT_CHUNK chunk{};
    size_t chunks = 0;
    constexpr size_t maxCharacters = 128 * 1024;
    while (chunks++ < 512 && text.size() < maxCharacters) {
        const SCODE chunkStatus = filter->GetChunk(&chunk);
        if (chunkStatus == FILTER_E_END_OF_CHUNKS)
            break;
        if (FAILED(chunkStatus))
            return false;
        if ((chunk.flags & CHUNK_TEXT) == 0)
            continue;
        for (;;) {
            wchar_t buffer[2049]{};
            ULONG characters = 2048;
            const SCODE status = filter->GetText(&characters, buffer);
            if (characters) {
                const size_t remaining = maxCharacters - text.size();
                text.append(buffer, std::min<size_t>(characters, remaining));
            }
            if (status == FILTER_S_LAST_TEXT || status == FILTER_E_NO_MORE_TEXT)
                break;
            if (FAILED(status))
                return false;
        }
        text += L"\n";
    }
    return !text.empty();
}

bool RenderDocxDocument(const Request& request, Image& image,
                        uint32_t& failureStatus) {
    std::wstring text;
    if (!ExtractDocxSemanticText(request.path, text)) {
        failureStatus = kStatusCorruptOrUnsupported;
        return false;
    }
    const std::wstring title =
        std::filesystem::path(request.path).filename().wstring();
    return RenderTextDocument(
        request, image, failureStatus, &text, &title);
}

bool LooksPasswordProtected(const std::wstring& path) {
    std::vector<BYTE> bytes;
    DWORD error = ERROR_SUCCESS;
    if (!ReadBoundedPrefix(path, 1024 * 1024, bytes, error))
        return false;
    if (IsPdfDocument(path)) {
        static const char marker[] = "/Encrypt";
        return std::search(bytes.begin(), bytes.end(),
            marker, marker + sizeof(marker) - 1) != bytes.end();
    }
    if (IsDocxDocument(path)) {
        static const BYTE compoundHeader[] =
            {0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1};
        return bytes.size() >= sizeof(compoundHeader)
            && std::equal(std::begin(compoundHeader),
                std::end(compoundHeader), bytes.begin());
    }
    return false;
}

bool DecodeShellThumbnail(const std::wstring& path, UINT maxWidth,
                          UINT maxHeight, bool cacheOnly, Image& image) {
    ComPtr<IShellItemImageFactory> factory;
    if (FAILED(SHCreateItemFromParsingName(path.c_str(), nullptr,
            IID_PPV_ARGS(factory.put()))))
        return false;
    SIZE requested{
        static_cast<LONG>(maxWidth), static_cast<LONG>(maxHeight)};
    HBITMAP bitmap = nullptr;
    // THUMBNAILONLY always forbids icon fallback. Hover requests additionally
    // use INCACHEONLY; hidden low-priority cache work may generate a thumbnail.
    SIIGBF flags = SIIGBF_THUMBNAILONLY; // 0x08
    if (cacheOnly)
        flags = static_cast<SIIGBF>(flags | SIIGBF_INCACHEONLY); // 0x10
    if (FAILED(factory->GetImage(requested, flags, &bitmap)) || !bitmap)
        return false;
    BITMAP object{};
    bool success = false;
    if (GetObjectW(bitmap, sizeof(object), &object)
        && object.bmWidth > 0 && object.bmHeight != 0) {
        const UINT width = static_cast<UINT>(object.bmWidth);
        const UINT height = static_cast<UINT>(std::abs(object.bmHeight));
        uint64_t bytes = 0;
        if (SafeMultiply(width, 4, kMaxPixelBytes, bytes)
            && SafeMultiply(bytes, height, kMaxPixelBytes, bytes)) {
            image.width = width;
            image.height = height;
            image.stride = width * 4;
            image.pixels.resize(static_cast<size_t>(bytes));
            BITMAPINFO info{};
            info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
            info.bmiHeader.biWidth = static_cast<LONG>(width);
            info.bmiHeader.biHeight = -static_cast<LONG>(height);
            info.bmiHeader.biPlanes = 1;
            info.bmiHeader.biBitCount = 32;
            info.bmiHeader.biCompression = BI_RGB;
            HDC dc = GetDC(nullptr);
            success = GetDIBits(dc, bitmap, 0, height,
                image.pixels.data(), &info, DIB_RGB_COLORS) == height;
            ReleaseDC(nullptr, dc);
            if (success) {
                bool anyAlpha = false;
                for (size_t i = 3; i < image.pixels.size(); i += 4)
                    anyAlpha = anyAlpha || image.pixels[i] != 0;
                if (!anyAlpha) {
                    for (size_t i = 3; i < image.pixels.size(); i += 4)
                        image.pixels[i] = 255;
                }
                image.hasAlpha = anyAlpha;
            }
        }
    }
    DeleteObject(bitmap);
    return success;
}

bool DecodeShellCache(const std::wstring& path, UINT maxWidth,
                      UINT maxHeight, Image& image) {
    return DecodeShellThumbnail(path, maxWidth, maxHeight, true, image);
}

bool DecodeCache(const Request& request, const FileIdentity& identity,
                 Image& image) {
    if (!request.cacheEnabled || !IsSafeCacheRoot(request.cacheRoot))
        return false;
    const std::wstring key = CacheKey(request, identity);
    if (key.empty())
        return false;
    for (const wchar_t* extension : {L".png", L".jpg"}) {
        const std::filesystem::path candidate =
            std::filesystem::path(request.cacheRoot) / (key + extension);
        WIN32_FILE_ATTRIBUTE_DATA data{};
        if (!GetFileAttributesExW(candidate.c_str(),
                GetFileExInfoStandard, &data))
            continue;
        const uint64_t bytes =
            (static_cast<uint64_t>(data.nFileSizeHigh) << 32)
            | data.nFileSizeLow;
        if (bytes == 0
            || bytes > static_cast<uint64_t>(
                request.cacheItemMaxKB) * 1024)
            continue;
        if (DecodeWicFile(candidate.wstring(), request.maxWidth,
                request.maxHeight, request, image)) {
            HANDLE file = CreateFileW(candidate.c_str(),
                FILE_WRITE_ATTRIBUTES, FILE_SHARE_READ, nullptr,
                OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (file != INVALID_HANDLE_VALUE) {
                FILETIME now{};
                GetSystemTimeAsFileTime(&now);
                SetFileTime(file, nullptr, &now, nullptr);
                CloseHandle(file);
            }
            return true;
        }
        DeleteFileW(candidate.c_str()); // corrupt, key-validated cache only
    }
    return false;
}

bool EncodeImage(const std::filesystem::path& destination,
                 const Image& image, bool png, float jpegQuality) {
    ComPtr<IWICImagingFactory> factory;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
            CLSCTX_INPROC_SERVER, IID_PPV_ARGS(factory.put()))))
        return false;
    ComPtr<IWICBitmap> bitmap;
    if (FAILED(factory->CreateBitmapFromMemory(image.width, image.height,
            GUID_WICPixelFormat32bppPBGRA, image.stride,
            static_cast<UINT>(image.pixels.size()),
            const_cast<BYTE*>(image.pixels.data()), bitmap.put())))
        return false;
    ComPtr<IWICStream> stream;
    if (FAILED(factory->CreateStream(stream.put()))
        || FAILED(stream->InitializeFromFilename(
            destination.c_str(), GENERIC_WRITE)))
        return false;
    ComPtr<IWICBitmapEncoder> encoder;
    const GUID container = png
        ? GUID_ContainerFormatPng : GUID_ContainerFormatJpeg;
    if (FAILED(factory->CreateEncoder(container, nullptr, encoder.put()))
        || FAILED(encoder->Initialize(
            stream.get(), WICBitmapEncoderNoCache)))
        return false;
    ComPtr<IWICBitmapFrameEncode> frame;
    ComPtr<IPropertyBag2> properties;
    if (FAILED(encoder->CreateNewFrame(frame.put(), properties.put())))
        return false;
    if (!png && properties) {
        PROPBAG2 option{};
        option.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
        VARIANT value;
        VariantInit(&value);
        value.vt = VT_R4;
        value.fltVal = jpegQuality;
        properties->Write(1, &option, &value);
        VariantClear(&value);
    }
    if (FAILED(frame->Initialize(properties.get()))
        || FAILED(frame->SetSize(image.width, image.height)))
        return false;
    WICPixelFormatGUID format = png
        ? GUID_WICPixelFormat32bppBGRA : GUID_WICPixelFormat24bppBGR;
    if (FAILED(frame->SetPixelFormat(&format)))
        return false;
    ComPtr<IWICFormatConverter> converter;
    IWICBitmapSource* source = bitmap.get();
    if (!IsEqualGUID(format, GUID_WICPixelFormat32bppPBGRA)) {
        if (FAILED(factory->CreateFormatConverter(converter.put()))
            || FAILED(converter->Initialize(bitmap.get(), format,
                WICBitmapDitherTypeNone, nullptr, 0.0,
                WICBitmapPaletteTypeCustom)))
            return false;
        source = converter.get();
    }
    if (FAILED(frame->WriteSource(source, nullptr))
        || FAILED(frame->Commit()) || FAILED(encoder->Commit()))
        return false;
    // IWICStream::InitializeFromFilename does not expose sharing flags. The
    // stream therefore still owns an exclusive file handle after Commit;
    // reopening it for FlushFileBuffers before releasing the COM chain always
    // fails with a sharing violation and made every cache encode look failed.
    converter.reset();
    properties.reset();
    frame.reset();
    encoder.reset();
    stream.reset();
    bitmap.reset();
    HANDLE output = CreateFileW(destination.c_str(), GENERIC_WRITE,
        FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
        nullptr);
    if (output == INVALID_HANDLE_VALUE)
        return false;
    const bool flushed = FlushFileBuffers(output) != FALSE;
    CloseHandle(output);
    return flushed;
}

bool WriteCache(const Request& request, const FileIdentity& identity,
                uint32_t* failureStatusOut = nullptr) {
    if (failureStatusOut)
        *failureStatusOut = kStatusNoContent;
    if (!request.cacheEnabled || !IsSafeCacheRoot(request.cacheRoot))
        return false;
    const std::wstring key = CacheKey(request, identity);
    if (key.empty())
        return false;
    const std::array<UINT, 3> edges{1024, 768, 512};
    for (UINT edge : edges) {
        edge = std::min(edge, request.cacheTargetEdge);
        Image image;
        Request renderRequest = request;
        renderRequest.maxWidth = edge;
        renderRequest.maxHeight = edge;
        uint32_t failureStatus = kStatusNoContent;
        const bool renderedText = IsTextDocument(request.path)
            && RenderTextDocument(renderRequest, image, failureStatus);
        const bool renderedDocx = IsDocxDocument(request.path)
            && RenderDocxDocument(renderRequest, image, failureStatus);
        const bool renderedPdf = IsPdfDocument(request.path)
            && RenderPdfFirstPage(renderRequest, image, failureStatus);
        if (!renderedText && !renderedDocx && !renderedPdf
            && !DecodeWicFile(request.path, edge, edge, request, image)
            && !DecodeShellThumbnail(
                request.path, edge, edge, false, image)) {
            if (failureStatusOut)
                *failureStatusOut = failureStatus;
            return false;
        }
        // Text-like documents favor lossless PNG so small glyphs stay crisp.
        // Photographic/image previews retain the existing JPEG/alpha choice.
        const bool png = IsDocument(request.path) || image.hasAlpha;
        const std::filesystem::path finalPath =
            std::filesystem::path(request.cacheRoot)
            / (key + (png ? L".png" : L".jpg"));
        const std::filesystem::path temporary =
            finalPath.wstring() + L".writing";
        DeleteFileW(temporary.c_str());
        if (!EncodeImage(temporary, image, png, 0.82f)) {
            DeleteFileW(temporary.c_str());
            continue;
        }
        WIN32_FILE_ATTRIBUTE_DATA data{};
        const bool stat = GetFileAttributesExW(temporary.c_str(),
            GetFileExInfoStandard, &data) != FALSE;
        const uint64_t bytes = stat
            ? (static_cast<uint64_t>(data.nFileSizeHigh) << 32)
                | data.nFileSizeLow
            : std::numeric_limits<uint64_t>::max();
        if (bytes <= static_cast<uint64_t>(
                request.cacheItemMaxKB) * 1024
            && MoveFileExW(temporary.c_str(), finalPath.c_str(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
            if (failureStatusOut)
                *failureStatusOut = kStatusReady;
            return true;
        }
        DeleteFileW(temporary.c_str());
    }
    return false; // Immediate preview is unaffected by cache refusal.
}

bool IsCacheName(const std::wstring& name) {
    const size_t dot = name.rfind(L'.');
    if (dot != 64)
        return false;
    const std::wstring extension = name.substr(dot);
    if (_wcsicmp(extension.c_str(), L".png") != 0
        && _wcsicmp(extension.c_str(), L".jpg") != 0)
        return false;
    for (size_t i = 0; i < 64; ++i) {
        if (!std::iswxdigit(name[i]))
            return false;
    }
    return true;
}

void CleanCache(const Request& request) {
    if (!IsSafeCacheRoot(request.cacheRoot))
        return;
    struct Entry {
        std::filesystem::path path;
        uint64_t bytes;
        FILETIME access;
    };
    std::vector<Entry> entries;
    uint64_t total = 0;
    const std::filesystem::path search =
        std::filesystem::path(request.cacheRoot) / L"*";
    WIN32_FIND_DATAW data{};
    HANDLE find = FindFirstFileW(search.c_str(), &data);
    if (find == INVALID_HANDLE_VALUE)
        return;
    const ULONGLONG now = [] {
        FILETIME value{};
        GetSystemTimeAsFileTime(&value);
        return (static_cast<ULONGLONG>(value.dwHighDateTime) << 32)
            | value.dwLowDateTime;
    }();
    do {
        if ((data.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY
                | FILE_ATTRIBUTE_REPARSE_POINT)) != 0)
            continue;
        const std::wstring name(data.cFileName);
        const std::filesystem::path path =
            std::filesystem::path(request.cacheRoot) / name;
        const auto hasSuffix = [&name](const wchar_t* suffix) {
            const size_t suffixLength = wcslen(suffix);
            return name.size() >= suffixLength
                && _wcsicmp(name.c_str() + name.size() - suffixLength,
                    suffix) == 0;
        };
        if (name.size() > 8
            && (hasSuffix(L".writing") || hasSuffix(L".part"))) {
            const ULONGLONG write =
                (static_cast<ULONGLONG>(data.ftLastWriteTime.dwHighDateTime)
                    << 32) | data.ftLastWriteTime.dwLowDateTime;
            if (now > write + 24ull * 60 * 60 * 10000000)
                DeleteFileW(path.c_str());
            continue;
        }
        if (!IsCacheName(name))
            continue;
        const uint64_t bytes =
            (static_cast<uint64_t>(data.nFileSizeHigh) << 32)
            | data.nFileSizeLow;
        entries.push_back({path, bytes, data.ftLastAccessTime});
        total += bytes;
    } while (FindNextFileW(find, &data));
    FindClose(find);
    std::sort(entries.begin(), entries.end(),
        [](const Entry& left, const Entry& right) {
            return CompareFileTime(&left.access, &right.access) < 0;
        });
    const ULONGLONG retention =
        static_cast<ULONGLONG>(request.cacheUnreferencedDays)
        * 24 * 60 * 60 * 10000000;
    entries.erase(std::remove_if(entries.begin(), entries.end(),
        [&](const Entry& entry) {
            const ULONGLONG access =
                (static_cast<ULONGLONG>(entry.access.dwHighDateTime) << 32)
                | entry.access.dwLowDateTime;
            if (now <= access + retention)
                return false;
            if (DeleteFileW(entry.path.c_str())) {
                total -= entry.bytes;
                return true;
            }
            return false;
        }), entries.end());
    const uint64_t maxBytes =
        static_cast<uint64_t>(request.cacheMaxMB) * 1024 * 1024;
    size_t index = 0;
    while ((total > maxBytes
            || entries.size() - index > request.cacheMaxItems)
        && index < entries.size()) {
        if (DeleteFileW(entries[index].path.c_str()))
            total -= entries[index].bytes;
        ++index;
    }
}

uint32_t AcquirePreview(const Request& request, Image& image,
                        uint32_t& sourceKind) {
    FileIdentity identity;
    DWORD attributes = 0;
    if (!GetIdentity(request.path, identity, attributes))
        return kStatusInaccessible;
    if (DecodeCache(request, identity, image)) {
        sourceKind = IsDocument(request.path) ? 6 : 1;
        return kStatusReady;
    }
    if (IsTextDocument(request.path)) {
        uint32_t status = kStatusNoContent;
        if (RenderTextDocument(request, image, status)) {
            sourceKind = 4;
            if (request.cacheEnabled)
                WriteCache(request, identity);
            return kStatusReady;
        }
        return status;
    }
    if ((IsPdfDocument(request.path) || IsDocxDocument(request.path))
        && LooksPasswordProtected(request.path))
        return kStatusPasswordProtected;
    if (IsDocxDocument(request.path)) {
        if (DecodeShellCache(
                request.path, request.maxWidth, request.maxHeight, image)) {
            sourceKind = 5;
            return kStatusReady;
        }
        uint32_t status = kStatusNoContent;
        if (RenderDocxDocument(request, image, status)) {
            sourceKind = 4;
            if (request.cacheEnabled)
                WriteCache(request, identity);
            return kStatusReady;
        }
        return kStatusNeedsGeneration;
    }
    if (IsPdfDocument(request.path)) {
        if (DecodeShellCache(
                request.path, request.maxWidth, request.maxHeight, image)) {
            sourceKind = 5;
            return kStatusReady;
        }
        if (DecodeShellThumbnail(
                request.path, request.maxWidth, request.maxHeight,
                false, image)) {
            sourceKind = 5;
            if (request.cacheEnabled)
                WriteCache(request, identity);
            return kStatusReady;
        }
        return kStatusNeedsGeneration;
    }
    const bool mayDecodeOriginal =
        identity.size <= static_cast<uint64_t>(
            request.maxFileMB) * 1024 * 1024;
    if (mayDecodeOriginal && DecodeWicFile(request.path,
            request.maxWidth, request.maxHeight, request, image)) {
        sourceKind = 3;
        return kStatusReady;
    }
    // Shell cache is strictly the final fallback: it covers non-image formats,
    // oversized originals and image codecs unavailable through WIC.
    if (DecodeShellCache(
        request.path, request.maxWidth, request.maxHeight, image)) {
        sourceKind = 2;
        return kStatusReady;
    }
    return kStatusNoContent;
}

void Publish(BYTE* mapping, const Request& request, HANDLE response,
             const Image* image, uint32_t sourceKind, uint32_t status) {
    if (!SameRequest(mapping, request))
        return;
    if (image && image->width && image->height
        && image->pixels.size() <= kMaxPixelBytes) {
        memcpy(mapping + kPixelOffset, image->pixels.data(),
            image->pixels.size());
        Field<uint32_t>(mapping, 128) = image->width;
        Field<uint32_t>(mapping, 132) = image->height;
        Field<uint32_t>(mapping, 136) = image->stride;
        Field<uint32_t>(mapping, 140) = sourceKind;
        MemoryBarrier();
        Field<uint32_t>(mapping, 12) = kStatusReady;
    } else {
        Field<uint32_t>(mapping, 128) = 0;
        Field<uint32_t>(mapping, 132) = 0;
        Field<uint32_t>(mapping, 136) = 0;
        Field<uint32_t>(mapping, 140) = 0;
        MemoryBarrier();
        Field<uint32_t>(mapping, 12) = status;
    }
    SetEvent(response);
}

int RunShared(const std::wstring& base) {
    HANDLE mappingHandle = OpenFileMappingW(
        FILE_MAP_ALL_ACCESS, FALSE, (base + L"-Map").c_str());
    HANDLE requestEvent = OpenEventW(
        SYNCHRONIZE | EVENT_MODIFY_STATE, FALSE,
        (base + L"-Request").c_str());
    HANDLE responseEvent = OpenEventW(
        SYNCHRONIZE | EVENT_MODIFY_STATE, FALSE,
        (base + L"-Response").c_str());
    HANDLE shutdownEvent = OpenEventW(
        SYNCHRONIZE | EVENT_MODIFY_STATE, FALSE,
        (base + L"-Shutdown").c_str());
    if (!mappingHandle || !requestEvent || !responseEvent || !shutdownEvent)
        return 2;
    BYTE* mapping = static_cast<BYTE*>(MapViewOfFile(
        mappingHandle, FILE_MAP_ALL_ACCESS, 0, 0, kMapBytes));
    if (!mapping || Field<uint32_t>(mapping, 0) != kMagic
        || Field<uint32_t>(mapping, 4) != kProtocolVersion)
        return 3;
    HANDLE waits[2]{shutdownEvent, requestEvent};
    for (;;) {
        const DWORD wait = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
        if (wait == WAIT_OBJECT_0)
            break;
        if (wait != WAIT_OBJECT_0 + 1)
            break;
        Request request = SnapshotRequest(mapping);
        if (request.path.empty())
            continue;
        if (request.command == kCommandCache
            || request.command == kCommandGenerateDocument) {
            SetPriorityClass(GetCurrentProcess(), IDLE_PRIORITY_CLASS);
            FileIdentity identity;
            DWORD attributes = 0;
            const bool accessible = GetIdentity(
                request.path, identity, attributes);
            const bool passwordProtected = accessible
                && LooksPasswordProtected(request.path);
            uint32_t failureStatus = kStatusCorruptOrUnsupported;
            const bool success = accessible && !passwordProtected
                && WriteCache(request, identity, &failureStatus);
            CleanCache(request);
            SetPriorityClass(GetCurrentProcess(), BELOW_NORMAL_PRIORITY_CLASS);
            if (SameRequest(mapping, request)) {
                Field<uint32_t>(mapping, 12) = success ? kStatusReady
                    : (!accessible ? kStatusInaccessible
                    : (passwordProtected ? kStatusPasswordProtected
                    : failureStatus));
                SetEvent(responseEvent);
            }
            continue;
        }
        Image image;
        uint32_t sourceKind = 0;
        const uint32_t status =
            AcquirePreview(request, image, sourceKind);
        Publish(mapping, request, responseEvent,
            status == kStatusReady ? &image : nullptr, sourceKind, status);
    }
    UnmapViewOfFile(mapping);
    CloseHandle(mappingHandle);
    CloseHandle(requestEvent);
    CloseHandle(responseEvent);
    CloseHandle(shutdownEvent);
    return 0;
}

} // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || argc != 3 || wcscmp(argv[1], L"--shared") != 0) {
        if (argv) LocalFree(argv);
        return 1;
    }
    const std::wstring base(argv[2]);
    LocalFree(argv);
    SetPriorityClass(GetCurrentProcess(), BELOW_NORMAL_PRIORITY_CLASS);
    try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
    } catch (const winrt::hresult_error&) {
        return 4;
    }
    const int result = RunShared(base);
    winrt::uninit_apartment();
    return result;
}
