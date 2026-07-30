# 文档预览技术说明

## 数据流

AHK 主进程只负责候选、延迟、Generation 校验、状态卡和 GDI 呈现。文件身份、读取、
解码、IFilter、Shell 缩略图和缓存写入都在 `PopDropPreview.exe` 中执行。共享内存
最多传递 4 MiB 的预乘 BGRA 像素；窗口使用 `WS_EX_NOACTIVATE`。

同一常驻 Helper 串行处理请求，所以同一路径不会并行解析。快速切换只保留共享内存中
最新请求；发布前必须同时匹配 request id、Generation、列表实例和面板显示会话。
已转入缓存生成阶段且工作超过 5 秒后，移开可继续写缓存但不重新弹窗；直接读取阶段或
较早移开会取消高成本 Helper。

## Renderer

| Renderer ID | 输入 | 边界 | 输出 |
| --- | --- | --- | --- |
| `markdown-semantic` | `.md/.markdown` | 512 KiB、180 行、单行 4096 字符 | 静态语义页 |
| `text-code` | 文本、日志、配置、代码 | 同上；BOM/UTF-8/UTF-16/有限系统代码页 | 静态文本页 |
| `delimited-table` | CSV/TSV | 30 行 × 12 列 | 静态表格页 |
| `pdf-pdfium-or-winrt-or-shell-first-page` | PDF | 目标边长 ≤1024；PDFium 实际读取 ≤64 MiB；WinRT 编码流 ≤16 MiB；Helper 硬期限 12 秒 | PDFium/Windows 第一页 |
| `docx-semantic-or-shell` | DOCX | IFilter 最多 512 chunk / 128K 字符 | 开头语义页或缩略图 |

Markdown 不创建 DOM，不执行 HTML、JavaScript、Mermaid、插件、链接或网络资源。CSV
只显示文本，不执行公式。DOCX IFilter 运行在隔离 Helper 内，不启动 Word；复杂版式、
嵌入图片、分页、页眉页脚可能丢失。PDF 缓存未命中后由隔离 Helper 优先动态加载
同目录的非 V8/XFA `pdfium.dll`，通过 `FPDF_LoadCustomDocument` 的随机读取回调只
渲染第 1 页；累计实际读取超过 64 MiB 即安全失败。PDFium 不可用时再通过
`CreateRandomAccessStreamOnFile` 调用 `Windows.Data.Pdf`，资源管理器已注册的
Shell 缩略图仍是快速候选。源码包不捆绑 DLL，由用户显式运行带 SHA-256 校验的
`native\install-pdfium.ps1` 安装，或在设置页确认后异步安装。下载版本、架构 URL
与哈希集中在 `native\pdfium-component.ini`；默认使用固定 GitHub TGZ 发行资产，
也支持自托管 DLL、ZIP 和 TGZ。自托管地址必须为 HTTPS 且必须提供 SHA-256；
压缩包限制条目数、路径穿越和展开量，并要求恰好包含一个 `pdfium.dll`。
`PdfEnabled` 默认关闭。

## 缓存

缓存键材料包含稳定文件身份（回退规范路径）、文件大小、最后修改时间、Renderer ID、
Renderer 规格版本、输出边长、DPI 和主题版本，最终以 SHA-256 命名。图片与文档共用
`preview-cache-v1`、默认 256 MiB / 1000 项预算和 2 MiB 单项限制。写入先使用
`.writing`，刷新句柄后以 `MoveFileEx(...WRITE_THROUGH)` 原子发布；清理拒绝重解析点，
只删除格式经过验证的缓存名。

面板隐藏不会遍历当前工作区预生成。前台显示结果的 `sourceKind` 已表示它来自静态
缓存、原图还是 Shell；只有本次实际悬浮且来源为未缓存原图/Shell 的项目才进入延迟
队列。缓存来源、以及前台已经写入缓存的文本/文档不会再次入队。文件大小或最后修改
时间变化会自然得到新键，并只在下一次悬浮时按需生成。

## 状态与错误

缓存命中直接显示。未命中文档在 120 ms 后显示首次生成状态，5 秒改为长耗时状态，
12 秒终止 Helper。状态卡与文档内容使用同一侧边、宽度和面板高度。

错误状态分别表示资源限制、密码保护、硬超时、不可访问和损坏/不支持。普通失败短期
负缓存；硬超时 10 分钟；不可访问 30 秒；密码和资源上限在文件修改前不重试。

## 外部快速预览

Seer 使用官方 `SeerWindowClass` 和 `WM_COPYDATA` 命令 4000、4001、5000、5004、
5005，发送设置 180 ms 超时。QuickLook 只接受绝对 `QuickLook.exe` 路径、文件存在、
文件名和产品信息校验；Store 版不推断 CLI 能力。两者默认关闭，能力失败时没有 Space
热键。`QuickViewActive` 只暂停 temporary 自动隐藏。由于 PopDrop 本身可能位于
topmost 窗口带，激活期间会以不激活、不移动的 `SetWindowPos` 持续把外部查看器
置于其上；关闭时恢复查看器进入前的置顶属性，不写入 PopDrop 配置。
