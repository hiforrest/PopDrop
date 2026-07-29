#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <wincodec.h>
#include <shobjidl.h>
#include <shellapi.h>
#include <bcrypt.h>
#include <propidl.h>
#include <propvarutil.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cwctype>
#include <cstring>
#include <cstdlib>
#include <filesystem>
#include <limits>
#include <memory>
#include <string>
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
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "oleaut32.lib")
#pragma comment(lib, "user32.lib")

namespace {

constexpr uint32_t kMagic = 0x56504450; // PDPV
constexpr uint32_t kProtocolVersion = 4;
constexpr size_t kMapBytes = 4268288;
constexpr size_t kPathOffset = 256;
constexpr size_t kPathChars = 32768;
constexpr size_t kCacheRootOffset = 65792;
constexpr size_t kCacheRootChars = 4096;
constexpr size_t kPixelOffset = 73984;
constexpr size_t kMaxPixelBytes = 4 * 1024 * 1024;
constexpr uint32_t kCommandPreview = 1;
constexpr uint32_t kCommandCache = 2;
constexpr uint32_t kStatusReady = 2;
constexpr uint32_t kStatusNoContent = 3;
constexpr uint32_t kPreviewSpecVersion = 1;

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

std::wstring CacheKey(const std::wstring& path,
                      const FileIdentity& identity, uint32_t targetEdge) {
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
        + L"|" + std::to_wstring(targetEdge)
        + L"|" + std::to_wstring(kPreviewSpecVersion);

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
    const std::wstring key = CacheKey(
        request.path, identity, request.cacheTargetEdge);
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

bool WriteCache(const Request& request, const FileIdentity& identity) {
    if (!request.cacheEnabled || !IsSafeCacheRoot(request.cacheRoot))
        return false;
    const std::wstring key = CacheKey(
        request.path, identity, request.cacheTargetEdge);
    if (key.empty())
        return false;
    const std::array<UINT, 3> edges{1024, 768, 512};
    for (UINT edge : edges) {
        edge = std::min(edge, request.cacheTargetEdge);
        Image image;
        if (!DecodeWicFile(request.path, edge, edge, request, image)
            && !DecodeShellThumbnail(
                request.path, edge, edge, false, image))
            return false;
        const bool png = image.hasAlpha;
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
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            return true;
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

bool AcquirePreview(const Request& request, Image& image,
                    uint32_t& sourceKind) {
    FileIdentity identity;
    DWORD attributes = 0;
    if (!GetIdentity(request.path, identity, attributes))
        return false;
    if (DecodeCache(request, identity, image)) {
        sourceKind = 1;
        return true;
    }
    const bool mayDecodeOriginal =
        identity.size <= static_cast<uint64_t>(
            request.maxFileMB) * 1024 * 1024;
    if (mayDecodeOriginal && DecodeWicFile(request.path,
            request.maxWidth, request.maxHeight, request, image)) {
        sourceKind = 3;
        return true;
    }
    // Shell cache is strictly the final fallback: it covers non-image formats,
    // oversized originals and image codecs unavailable through WIC.
    if (DecodeShellCache(
            request.path, request.maxWidth, request.maxHeight, image)) {
        sourceKind = 2;
        return true;
    }
    return false;
}

void Publish(BYTE* mapping, const Request& request, HANDLE response,
             const Image* image, uint32_t sourceKind) {
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
        Field<uint32_t>(mapping, 12) = kStatusNoContent;
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
        if (request.command == kCommandCache) {
            SetPriorityClass(GetCurrentProcess(), IDLE_PRIORITY_CLASS);
            FileIdentity identity;
            DWORD attributes = 0;
            const bool success = GetIdentity(
                request.path, identity, attributes)
                && identity.size <= static_cast<uint64_t>(
                    request.maxFileMB) * 1024 * 1024
                && WriteCache(request, identity);
            CleanCache(request);
            SetPriorityClass(GetCurrentProcess(), BELOW_NORMAL_PRIORITY_CLASS);
            if (SameRequest(mapping, request)) {
                Field<uint32_t>(mapping, 12) =
                    success ? kStatusReady : kStatusNoContent;
                SetEvent(responseEvent);
            }
            continue;
        }
        Image image;
        uint32_t sourceKind = 0;
        const bool success = AcquirePreview(request, image, sourceKind);
        Publish(mapping, request, responseEvent,
            success ? &image : nullptr, sourceKind);
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
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(com))
        return 4;
    const int result = RunShared(base);
    CoUninitialize();
    return result;
}
