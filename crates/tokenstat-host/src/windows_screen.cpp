// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// The Windows desktop capture/encoder boundary. Every object is created, used,
// and destroyed on one capture thread. No window, shell, or external codec.
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <mferror.h>
#include <strmif.h>
#include <codecapi.h>
#include <wmcodecdsp.h>
#include <wrl/client.h>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <memory>
#include <vector>

using Microsoft::WRL::ComPtr;
static void check(HRESULT hr) { if (FAILED(hr)) throw hr; }
static BYTE clamp_byte(int n) { return static_cast<BYTE>(std::clamp(n, 0, 255)); }

static bool desktop_available() {
    HDESK input = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
    if (!input) return false;
    wchar_t name[128]{}; DWORD needed = 0;
    bool accessible = GetUserObjectInformationW(input, UOI_NAME, name, sizeof(name), &needed)
        && _wcsicmp(name, L"Default") == 0;
    CloseDesktop(input);
    return accessible;
}

struct Display { int32_t left, top, width, height; };
static BOOL CALLBACK monitor(HMONITOR handle, HDC, LPRECT, LPARAM context) {
    MONITORINFO info{}; info.cbSize = sizeof(info);
    if (GetMonitorInfoW(handle, &info)) {
        auto r = info.rcMonitor;
        auto& result = *reinterpret_cast<std::vector<Display>*>(context);
        Display display{r.left, r.top, r.right - r.left, r.bottom - r.top};
        if (info.dwFlags & MONITORINFOF_PRIMARY) result.insert(result.begin(), display);
        else result.push_back(display);
    }
    return TRUE;
}
static std::vector<Display> displays() {
    std::vector<Display> result;
    EnumDisplayMonitors(nullptr, nullptr, monitor, reinterpret_cast<LPARAM>(&result));
    return result;
}

extern "C" uint32_t ts_screen_displays(Display* target, uint32_t capacity) noexcept {
    try {
        SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        auto list = displays();
        auto count = std::min(capacity, static_cast<uint32_t>(list.size()));
        if (target) std::copy_n(list.begin(), count, target);
        return count;
    } catch (...) { return 0; }
}

class Capture {
public:
    ComPtr<IMFTransform> encoder;
    ComPtr<ICodecAPI> codec;
    HDC desktop = nullptr, memory = nullptr;
    HBITMAP bitmap = nullptr;
    HGDIOBJ previous = nullptr;
    BYTE* pixels = nullptr;
    Display display{};
    uint32_t width = 0, height = 0, fps = 0;
    uint64_t index = 0;
    bool com = false, mf = false, synthetic = false;
    std::vector<BYTE> encoded;

    ~Capture() {
        encoder.Reset(); codec.Reset();
        if (previous && memory) SelectObject(memory, previous);
        if (bitmap) DeleteObject(bitmap);
        if (memory) DeleteDC(memory);
        if (desktop) ReleaseDC(nullptr, desktop);
        if (mf) MFShutdown();
        if (com) CoUninitialize();
    }
    void initialize(uint32_t selected, uint32_t maxWidth, uint32_t frameRate, uint32_t bitrate, bool test) {
        check(CoInitializeEx(nullptr, COINIT_MULTITHREADED)); com = true;
        check(MFStartup(MF_VERSION, MFSTARTUP_LITE)); mf = true;
        synthetic = test;
        if (test) display = {0, 0, 320, 180};
        else {
            auto list = displays();
            if (selected >= list.size()) throw E_INVALIDARG;
            display = list[selected];
        }
        double scale = std::min(1.0, double(std::clamp(maxWidth, 320u, 3840u)) / display.width);
        width = std::max(2u, uint32_t(display.width * scale) & ~1u);
        height = std::max(2u, uint32_t(display.height * scale) & ~1u);
        fps = std::clamp(frameRate, 5u, 60u);
        check(CoCreateInstance(CLSID_CMSH264EncoderMFT, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&encoder)));
        encoder.As(&codec);
        ComPtr<IMFAttributes> attributes;
        if (SUCCEEDED(encoder->GetAttributes(&attributes))) attributes->SetUINT32(MF_LOW_LATENCY, TRUE);
        if (codec) {
            VARIANT value; VariantInit(&value); value.vt = VT_UI4;
            value.ulVal = fps; codec->SetValue(&CODECAPI_AVEncMPVGOPSize, &value);
            value.ulVal = 0; codec->SetValue(&CODECAPI_AVEncMPVDefaultBPictureCount, &value);
        }
        ComPtr<IMFMediaType> output;
        check(MFCreateMediaType(&output));
        check(output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video));
        check(output->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264));
        check(output->SetUINT32(MF_MT_AVG_BITRATE, std::clamp(bitrate, 300000u, 16000000u)));
        check(output->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive));
        check(output->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Base));
        check(MFSetAttributeSize(output.Get(), MF_MT_FRAME_SIZE, width, height));
        check(MFSetAttributeRatio(output.Get(), MF_MT_FRAME_RATE, fps, 1));
        check(MFSetAttributeRatio(output.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1));
        check(encoder->SetOutputType(0, output.Get(), 0));
        ComPtr<IMFMediaType> input;
        check(MFCreateMediaType(&input));
        check(input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video));
        check(input->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12));
        check(input->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive));
        check(MFSetAttributeSize(input.Get(), MF_MT_FRAME_SIZE, width, height));
        check(MFSetAttributeRatio(input.Get(), MF_MT_FRAME_RATE, fps, 1));
        check(MFSetAttributeRatio(input.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1));
        check(encoder->SetInputType(0, input.Get(), 0));
        check(encoder->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0));
        check(encoder->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0));
        if (!test) {
            desktop = GetDC(nullptr);
            if (!desktop) throw E_FAIL;
            memory = CreateCompatibleDC(desktop);
            if (!memory) throw E_FAIL;
            BITMAPINFO info{};
            info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
            info.bmiHeader.biWidth = width; info.bmiHeader.biHeight = -int(height);
            info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32;
            info.bmiHeader.biCompression = BI_RGB;
            bitmap = CreateDIBSection(desktop, &info, DIB_RGB_COLORS, reinterpret_cast<void**>(&pixels), nullptr, 0);
            if (!bitmap || !pixels) throw E_OUTOFMEMORY;
            previous = SelectObject(memory, bitmap);
            if (!previous || previous == HGDI_ERROR) throw E_FAIL;
            SetStretchBltMode(memory, HALFTONE);
        }
    }

    void image(BYTE* nv12) {
        if (synthetic) {
            std::fill_n(nv12, width * height, BYTE(80 + index % 100));
            std::fill_n(nv12 + width * height, width * height / 2, BYTE(128));
            return;
        }
        // Do not capture or inject into a locked/secure desktop.
        if (!desktop_available()) throw HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED);
        if (!StretchBlt(memory, 0, 0, width, height, desktop, display.left, display.top,
                display.width, display.height, SRCCOPY | CAPTUREBLT)) throw E_FAIL;
        CURSORINFO cursor{}; cursor.cbSize = sizeof(cursor);
        if (GetCursorInfo(&cursor) && (cursor.flags & CURSOR_SHOWING)) {
            ICONINFO icon{};
            if (GetIconInfo(cursor.hCursor, &icon)) {
                double sx = double(width) / display.width, sy = double(height) / display.height;
                int x = int((cursor.ptScreenPos.x - display.left - int(icon.xHotspot)) * sx);
                int y = int((cursor.ptScreenPos.y - display.top - int(icon.yHotspot)) * sy);
                DrawIconEx(memory, x, y, cursor.hCursor, std::max(1, int(GetSystemMetrics(SM_CXCURSOR) * sx)),
                    std::max(1, int(GetSystemMetrics(SM_CYCURSOR) * sy)), 0, nullptr, DI_NORMAL);
                if (icon.hbmColor) DeleteObject(icon.hbmColor);
                if (icon.hbmMask) DeleteObject(icon.hbmMask);
            }
        }
        // Complete GDI writes before reading the DIB's shared memory.
        GdiFlush();
        // BT.601 limited-range NV12, two-by-two averaged chroma.
        for (uint32_t y = 0; y < height; y += 2) {
            for (uint32_t x = 0; x < width; x += 2) {
                int sumR = 0, sumG = 0, sumB = 0;
                for (uint32_t dy = 0; dy < 2; ++dy) for (uint32_t dx = 0; dx < 2; ++dx) {
                    auto offset = (y + dy) * width + x + dx;
                    auto p = pixels + offset * 4;
                    int b = p[0], g = p[1], r = p[2];
                    nv12[offset] = clamp_byte(((66*r + 129*g + 25*b + 128) >> 8) + 16);
                    sumR += r; sumG += g; sumB += b;
                }
                int r = sumR / 4, g = sumG / 4, b = sumB / 4;
                auto uv = width * height + (y / 2) * width + x;
                nv12[uv] = clamp_byte(((-38*r - 74*g + 112*b + 128) >> 8) + 128);
                nv12[uv + 1] = clamp_byte(((112*r - 94*g - 18*b + 128) >> 8) + 128);
            }
        }
    }

    bool next(bool force, bool& key, uint64_t& stamp) {
        if (force && codec) {
            VARIANT value; VariantInit(&value); value.vt = VT_UI4; value.ulVal = 1;
            check(codec->SetValue(&CODECAPI_AVEncVideoForceKeyFrame, &value));
        }
        ComPtr<IMFMediaBuffer> inputBuffer;
        const DWORD bytes = width * height * 3 / 2;
        check(MFCreateMemoryBuffer(bytes, &inputBuffer));
        BYTE* data = nullptr;
        check(inputBuffer->Lock(&data, nullptr, nullptr));
        try { image(data); } catch (...) { inputBuffer->Unlock(); throw; }
        check(inputBuffer->Unlock()); check(inputBuffer->SetCurrentLength(bytes));
        ComPtr<IMFSample> input;
        check(MFCreateSample(&input)); check(input->AddBuffer(inputBuffer.Get()));
        const LONGLONG time = index++ * 10000000ULL / fps;
        check(input->SetSampleTime(time)); check(input->SetSampleDuration(10000000 / fps));
        check(encoder->ProcessInput(0, input.Get(), 0));
        MFT_OUTPUT_STREAM_INFO info{}; check(encoder->GetOutputStreamInfo(0, &info));
        ComPtr<IMFSample> supplied;
        if (!(info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES)) {
            check(MFCreateSample(&supplied));
            ComPtr<IMFMediaBuffer> buffer;
            check(MFCreateMemoryBuffer(std::max(info.cbSize, 1048576UL), &buffer));
            check(supplied->AddBuffer(buffer.Get()));
        }
        MFT_OUTPUT_DATA_BUFFER output{}; output.pSample = supplied.Get(); DWORD status = 0;
        HRESULT hr = encoder->ProcessOutput(0, 1, &output, &status);
        if (output.pEvents) output.pEvents->Release();
        ComPtr<IMFSample> produced;
        if (output.pSample && output.pSample != supplied.Get()) produced.Attach(output.pSample);
        if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return false;
        check(hr);
        IMFSample* sample = output.pSample;
        if (!sample) return false;
        UINT32 clean = 0; sample->GetUINT32(MFSampleExtension_CleanPoint, &clean); key = clean != 0;
        LONGLONG sampleTime = time; sample->GetSampleTime(&sampleTime); stamp = std::max(0LL, sampleTime) / 10;
        ComPtr<IMFMediaBuffer> buffer; check(sample->ConvertToContiguousBuffer(&buffer));
        DWORD length = 0; check(buffer->Lock(&data, nullptr, &length));
        try { encoded.assign(data, data + length); } catch (...) { buffer->Unlock(); throw; }
        check(buffer->Unlock());
        // The encoder's sequence header is Annex B. Repeat it with independent
        // frames so a fresh or recovering decoder has SPS/PPS immediately.
        if (key) {
            ComPtr<IMFMediaType> type;
            if (SUCCEEDED(encoder->GetOutputCurrentType(0, &type))) {
                UINT32 size = 0;
                if (SUCCEEDED(type->GetBlobSize(MF_MT_MPEG_SEQUENCE_HEADER, &size)) && size <= 65536) {
                    std::vector<BYTE> header(size);
                    if (SUCCEEDED(type->GetBlob(MF_MT_MPEG_SEQUENCE_HEADER, header.data(), size, nullptr)))
                        encoded.insert(encoded.begin(), header.begin(), header.end());
                }
            }
        }
        // Apple and Android consumers split four-byte start codes. Normalize
        // three-byte codes emitted by some Windows codec versions as well.
        std::vector<BYTE> normalized;
        for (size_t i = 0; i < encoded.size();) {
            size_t start = 0;
            if (i + 3 < encoded.size() && encoded[i] == 0 && encoded[i+1] == 0 && encoded[i+2] == 0 && encoded[i+3] == 1) start = 4;
            else if (i + 2 < encoded.size() && encoded[i] == 0 && encoded[i+1] == 0 && encoded[i+2] == 1) start = 3;
            if (start) {
                normalized.insert(normalized.end(), {0, 0, 0, 1});
                i += start;
                if (i < encoded.size() && (encoded[i] & 31) == 5) key = true;
            } else normalized.push_back(encoded[i++]);
        }
        encoded.swap(normalized);
        return !encoded.empty();
    }
};

extern "C" void* ts_screen_create(uint32_t display, uint32_t width, uint32_t fps, uint32_t bitrate,
        int test, int32_t* error) noexcept {
    try {
        auto capture = std::make_unique<Capture>();
        capture->initialize(display, width, fps, bitrate, test != 0);
        *error = 0; return capture.release();
    } catch (HRESULT hr) { *error = hr; } catch (...) { *error = E_FAIL; }
    return nullptr;
}
extern "C" void ts_screen_destroy(void* handle) noexcept { delete static_cast<Capture*>(handle); }
extern "C" int32_t ts_screen_next(void* handle, int force, const BYTE** bytes, uint32_t* length,
        uint32_t* width, uint32_t* height, int* key, uint64_t* stamp) noexcept {
    try {
        auto& capture = *static_cast<Capture*>(handle);
        bool independent = false;
        bool ready = capture.next(force != 0, independent, *stamp);
        *bytes = capture.encoded.data(); *length = ready ? static_cast<uint32_t>(capture.encoded.size()) : 0;
        *width = capture.width; *height = capture.height; *key = independent;
        return 0;
    } catch (HRESULT hr) { return hr; } catch (...) { return E_FAIL; }
}

// Input is admitted and bounded by the Rust session's live control grant.
extern "C" int ts_screen_mouse(int32_t x, int32_t y, uint32_t flags, int32_t wheel) noexcept {
    if (!desktop_available()) return 0;
    INPUT event{}; event.type = INPUT_MOUSE;
    event.mi.dx = x; event.mi.dy = y; event.mi.dwFlags = flags;
    event.mi.mouseData = static_cast<DWORD>(wheel);
    return SendInput(1, &event, sizeof(event)) == 1;
}
extern "C" int ts_screen_key(uint16_t code, int down, int unicode) noexcept {
    if (!desktop_available()) return 0;
    INPUT event{}; event.type = INPUT_KEYBOARD;
    event.ki.wVk = unicode ? 0 : code; event.ki.wScan = unicode ? code : 0;
    event.ki.dwFlags = (down ? 0 : KEYEVENTF_KEYUP) | (unicode ? KEYEVENTF_UNICODE : 0);
    if (!unicode && ((code >= VK_PRIOR && code <= VK_DOWN) || code == VK_DELETE || code == VK_INSERT
        || code == VK_RCONTROL || code == VK_RMENU || code == VK_LWIN || code == VK_RWIN))
        event.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
    return SendInput(1, &event, sizeof(event)) == 1;
}
