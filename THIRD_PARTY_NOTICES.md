# 第三方组件与许可证说明

本源码包没有捆绑 PDFium、Seer、QuickLook、Office、pngquant、libimagequant、
GPL 代码或商业组件。

`PopDropPreview.exe` 使用 Windows SDK 提供的 Win32、WIC、Shell、BCrypt、
Windows Search IFilter 和 `Windows.Data.Pdf` 接口，随 Windows/Visual Studio SDK
的适用许可分发。

PDFium 是可选的 PDF 第一页渲染组件。用户可在设置页明确同意下载，或主动运行
`native\install-pdfium.ps1`。`native\pdfium-component.ini` 默认指向固定 GitHub
TGZ 发行资产，也可指定自托管 HTTPS DLL、ZIP/TGZ 和 SHA-256。脚本按上游发行元
数据或显式哈希校验下载，压缩包自动安全解压。对应架构的 `pdfium.dll` 放到 Helper
同目录。PDFium 的
公共 API 与源代码采用 BSD 风格许可；预编译发行项目采用 MIT 许可。安装脚本会把
发行包内的 `LICENSE` 与版本记录保留到 `native\third_party\pdfium`。PopDrop 仅
动态加载该 DLL，不复制 PDFium 源码。

- PDFium: https://pdfium.googlesource.com/pdfium/
- 预编译发行: https://github.com/bblanchon/pdfium-binaries

Seer 与 QuickLook 只是用户可选、默认关闭的外部程序：

- PopDrop 不下载、安装、复制或再分发它们；
- Seer 通过其公开 Win32 IPC 协议调用；
- QuickLook 通过桌面版/便携版公开命令行入口调用；
- QuickLook Microsoft Store 版本不会被假定具有命令行能力；
- PopDrop 不复制 QuickLook 的 GPL 源代码。

用户应自行取得外部程序，并遵守对应软件的许可条款。
