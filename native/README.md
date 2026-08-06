# PopDrop 原生 helper

`PopDropTransfer.exe` 是 PopDrop 外部内容投放的最小后台组件。它只负责：

- 解封送 `IDataObject`；
- 对所有外部异步 HDROP 执行唯一一次 `GetData(CF_HDROP)`，并读取来源路径；
- 若 HDROP 来源已经位于目标目录，等待来源写入完成后认领原文件，不再同目录复制；
- 在 `IDataObjectAsyncCapability::EndOperation()` 后短暂观察所有适配器保存的本批
  图片，收敛来源程序延迟生成的同名缩略图或原图；
- 读取 `FILEDESCRIPTORW/FILECONTENTS`、
  PNG/DIB 和明确 URL；
- 分块写入隐藏的 `.popdrop-part`；
- 原子落盘、安全自动改名、网络来源标记；
- 以原子 INI 状态文件向 AHK 报告进度，并响应取消标记。

它不读取浏览器 Cookie、聊天数据库或应用私有缓存，不注入其他进程，也不执行下载结果。

`PopDropPreview.exe` 是 0.10.0 的文件内容预览组件。它是惰性启动的常驻进程，
通过当前 PopDrop 进程独占命名的共享内存和事件收发请求。主界面不读取文件，
也不调用 Shell/WIC/IFilter。组件严格按以下顺序取内容：

1. `preview-cache-v1` 中身份、时间、尺寸桶和规格版本都匹配的自有缓存；
2. WIC 对大小与安全边界允许的本地普通图片执行首帧缩放解码；
3. 仅在原图超限、解码器不可用或非图片格式时，最后使用
   `SIIGBF_THUMBNAILONLY | SIIGBF_INCACHEONLY` 返回的 Windows 已有真实缩略图。

文本/Markdown/CSV 使用最多 512 KiB 的有界读取和 GDI 静态绘制；长逻辑行先按当前
字体显式切分为视觉行，再逐行单行绘制。PDF 优先复用系统已有缩略图，首次生成时
优先调用同目录的非 V8/XFA `pdfium.dll` 按需读取并渲染第一页；DLL 不存在或加载
失败时，回退到 Win32 原生只读随机访问流和 Windows 自带 `Windows.Data.Pdf`。
DOCX 在 Helper 内调用 Windows IFilter 提取开头语义文本，
失败时回退系统真实缩略图。IFilter 和 Shell 扩展都只运行在可终止 Helper 中；
不启动 Word，不使用 Office COM，也不执行宏、OLE、ActiveX 或外部关系。

直接解码会拒绝仅在线云占位、超出配置边界的源文件和无法安全缩小的图像。
优先使用 `IWICBitmapSourceTransform`；不支持缩放转换的解码器只有在预计展开内存
不超限时才进入回退路径。预览进程由主程序放入约 512 MiB 的 Job Object；
图片请求 3 秒、文档请求 12 秒达到硬期限后会被真正终止并惰性重启。

清晰图片缓存仅在面板隐藏期由低优先级 Helper 串行生成。无 Alpha 使用质量约
82 的 JPEG；有 Alpha 使用真彩压缩 PNG。本版本没有引入调色板量化依赖：
编码超过 2 MiB 时按 1024、768、512 逐级缩小，仍超限便不落盘。缓存文件使用
SHA-256 名称，清理只接受 `preview-cache-v1` 下符合格式且非重解析点的普通文件。
WIC 无法解码的格式会在这一后台阶段调用 Windows Shell 缩略图处理器生成真实
缩略图；`THUMBNAILONLY` 仍禁止图标回退。即时悬浮阶段继续使用 `INCACHEONLY`。

## 构建

要求 Windows 10/11、PowerShell 5.1+，以及 Visual Studio 2022 Build Tools 的
“使用 C++ 的桌面开发”工作负载和随附的当前 Windows SDK。先构建 Helper：

```powershell
powershell -ExecutionPolicy Bypass -File .\native\build.ps1
```

为了获得更可靠的 PDF 首屏预览，可在设置页启用“PDF 预览”并确认下载，或显式安装
PDFium 非 V8 构建：

```powershell
powershell -ExecutionPolicy Bypass -File .\native\install-pdfium.ps1
```

下载信息由 `native\pdfium-component.ini` 集中维护，默认写入固定 GitHub TGZ
发行包地址。`PackageType` 支持 `Dll`、`Zip`、`Tgz`；改用自托管 HTTPS 地址时
必须同时填写 SHA-256。ZIP/TGZ 会自动检查并解压。64 位 Windows 默认只下载 x64
包并把 `pdfium.dll` 放到 `native\bin\x64`；如需同时
测试 32 位 AutoHotkey，追加 `-Architecture All`。安装脚本固定发布版本并验证 GitHub
发布元数据中的 SHA-256。Helper 通过运行时动态加载 PDFium，因此安装 DLL 后无需再次
编译，只需重启 PopDrop。未执行安装脚本时仍可使用 Windows 内置 PDF 后备。

脚本同时生成：

- `native\bin\x64\PopDropTransfer.exe`
- `native\bin\x86\PopDropTransfer.exe`
- `native\bin\x64\PopDropPreview.exe`
- `native\bin\x86\PopDropPreview.exe`

源码包中的 Helper 二进制仅作为历史构建产物。发布 v1.1.0 前必须在 Windows SDK / MSVC
环境运行本目录的 `build.ps1`，确保 `HelperVersion=1.1.0`；PDFium 安装可在构建前后进行。

AHK 源码和编译版都根据自身位数选择 `native\bin\<架构>` 中对应文件；发布包还需将
同架构的 `pdfium.dll`（若启用）放在该目录。Helper 协议版本写在请求或共享内存头中；
不兼容版本会失败而不会猜测字段。握手还会校验 `HelperVersion`。

## 故障隔离

helper 为独立、非提权进程。崩溃不会终止 PopDrop；主程序检测到进程退出后把批次标记
为失败。未完成文件始终使用 `.popdrop-part` 且带 Hidden 属性，启动时/定时清理陈旧
运行目录及可验证的同批孤立 part；目标离线时保留清理记录供以后重试。活动任务只能
由当前 PopDrop 会话的取消文件控制。

`TYMED_ISTORAGE` 目前会明确拒绝；支持 `TYMED_ISTREAM` 和 `TYMED_HGLOBAL`。

## 第三方组件

两个 Helper 的编译仍只链接 Windows SDK、Shell、WIC、Windows Search IFilter、
BCrypt 和 MSVC 运行库。PDFium 是用户显式安装、运行时动态加载的 BSD 风格许可
组件；源码包不捆绑它。没有引入 MuPDF、Poppler、pngquant、libimagequant 或商业
授权组件。
