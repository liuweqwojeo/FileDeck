// 使用实际 CEF ZIP/资源响应实现验证压缩帮助；不启动浏览器，也不需要联网。
#include <iostream>
#include <stdexcept>
#include <string>
#include <sys/stat.h>

// 读取器只有这两项文件路径依赖。测试提供相同接口，避免链接整个 Office 内核。
namespace NSFile {
std::wstring GetDirectoryName(const std::wstring& value);
class CFileBinary {
public:
    static bool Exists(const std::wstring& value);
};
}

#include "filedeck_compressed_help.h"
#include "include/wrapper/cef_library_loader.h"

std::wstring NSFile::GetDirectoryName(const std::wstring& value) {
    return value.substr(0, value.find_last_of(L'/'));
}

bool NSFile::CFileBinary::Exists(const std::wstring& value) {
    struct stat metadata;
    const std::string path = CefString(value).ToString();
    return stat(path.c_str(), &metadata) == 0;
}

static unsigned checks = 0;

static void Check(bool passed, const char* description) {
    if (!passed) throw std::runtime_error(description);
    ++checks;
}

static int Run(const std::wstring& base) {
    const std::wstring settings = base + L"/api/documents/index.html";
    const std::wstring help = base + L"/documenteditor/main/resources/help";
    FileDeckHelp::Location location;
    std::vector<unsigned char> bytes;

    Check(FileDeckHelp::LocateUrl(settings, L"file://" + help + L"/en/a.htm?x=1#fragment", location),
          "file URL 的查询参数和片段不应进入归档路径");
    Check(FileDeckHelp::ReadEntry(location, location.entry, 10000, bytes), "普通条目读取失败");
    Check(std::string(bytes.begin(), bytes.end()) == "<html><body>offline original bytes</body></html>",
          "读取后的原始字节发生变化");
    Check(FileDeckHelp::Index(location)->valid, "版本 1 的链接索引未被识别");
    Check(FileDeckHelp::Index(location)->links.size() == 22, "链接索引不完整");
    Check(!FileDeckHelp::ReadEntry(location, location.entry, 10, bytes), "单条目大小限制未生效");
    Check(!FileDeckHelp::LocateUrl(settings, L"https://a.invalid" + help + L"/en/a.htm", location),
          "远程 URL 被错误接管");
    Check(!FileDeckHelp::LocateUrl(settings, L"file://remotehost" + help + L"/en/a.htm", location),
          "远程 file 主机被错误接管");
    Check(!FileDeckHelp::LocateUrl(settings, L"file://" + help + L"/en%2fa.htm", location),
          "编码分隔符未被拒绝");

    // 软链接保留原先的跨编辑器目标，不能通过解引用重新引入成千上万份重复图片。
    auto response = FileDeckHelp::Handle(settings, L"file://" + help + L"/en/link.htm");
    if (!response) throw std::runtime_error("包内帮助请求没有返回 handler");
    CefRefPtr<CefResponse> info = CefResponse::Create();
    int64 length = 0;
    CefString redirect;
    response->GetResponseHeaders(info, length, redirect);
    Check(info->GetStatus() == 200, "跨归档软链接未成功解析");
    Check(info->GetMimeType() == "text/html", "软链接响应没有保留原 URL 的 MIME");
    char buffer[1024];
    int read = 0;
    Check(response->Read(buffer, sizeof(buffer), read, nullptr), "响应体读取失败");
    Check(std::string(buffer, read) == "cross-root target bytes", "软链接响应内容不正确");

    auto errorFor = [&](const std::wstring& path) {
        auto handler = FileDeckHelp::Handle(settings, L"file://" + base + path);
        if (!handler) throw std::runtime_error("压缩帮助错误应返回明确状态，而非明文文件回退");
        bool handled = false;
        const bool opened = handler->Open(nullptr, handled, nullptr);
        if (!handled) throw std::runtime_error("读取结果未同步确定");
        CefRefPtr<CefResponse> details = CefResponse::Create();
        handler->GetResponseHeaders(details, length, redirect);
        if (opened) return ERR_NONE;
        return details->GetError();
    };
    Check(errorFor(L"/documenteditor/main/resources/help/en/missing.htm") == ERR_FILE_NOT_FOUND,
          "缺失文件没有触发原 file URL 的失败语义");
    Check(!FileDeckHelp::Handle(settings, L"file:///tmp/no-help.htm"), "包外请求被错误接管");
    Check(errorFor(L"/documenteditor/main/resources/help/en/cyclea.htm") == ERR_FAILED,
          "循环链接未被拒绝");
    Check(errorFor(L"/documenteditor/main/resources/help/en/escape.htm") == ERR_FAILED,
          "帮助目录之外的目标未被拒绝");
    Check(errorFor(L"/documenteditor/main/resources/help/en/mismatch.htm") == ERR_FAILED,
          "链接索引与归档条目不匹配时仍然成功");
    Check(errorFor(L"/documenteditor/main/resources/help/en/chain0.htm") == ERR_FAILED,
          "超过 16 级的链接未被拒绝");
    Check(errorFor(L"/documenteditor/main/resources/help/en/chain1.htm") == ERR_NONE,
          "合法的 16 级链接被错误拒绝");
    Check(errorFor(L"/pdfeditor/main/resources/help/en/bad.htm") == ERR_FILE_NOT_FOUND,
          "损坏 CRC 的条目仍然成功返回");
    Check(errorFor(L"/visioeditor/main/resources/help/en/a.htm") == ERR_FAILED,
          "未知版本的归档索引未被拒绝");
    // 本地 fetch 兼容层会将 HTTP 404 当成成功，故语言回退必须先收到网络错误。
    Check(errorFor(L"/documenteditor/main/resources/help/zh/Contents.json") == ERR_FILE_NOT_FOUND,
          "缺失中文帮助目录没有触发默认语言回退所需的网络错误");
    Check(errorFor(L"/documenteditor/main/resources/help/en/a.htm") == ERR_NONE,
          "默认英语帮助不能在失败后继续读取");
    Check(FWCompressedHelpVersion() == 1, "打包能力版本不匹配");
    std::cout << "PASS: " << checks << " compressed help reader checks\n";
    return 0;
}

int main(int argc, char** argv) {
    if (argc != 3) {
        std::cerr << "Usage: CompressedHelpReader <fixture-apps-root> <CEF-library>\n";
        return 2;
    }
    try {
        // 本项目 macOS 的 CEF wrapper 使用延迟加载，直接链接 framework 无法初始化函数表。
        if (!cef_load_library(argv[2])) throw std::runtime_error("无法加载锁定的 CEF framework");
        return Run(CefString(argv[1]).ToWString());
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
