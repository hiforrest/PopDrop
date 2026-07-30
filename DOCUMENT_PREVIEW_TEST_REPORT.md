# PopDrop 0.10.0 文档与外部快速预览测试报告

日期：2026-07-29

## 自动化结果

Linux 交付环境已执行全部 Python 契约测试、Python `compileall`、源码结构检查、
配置 BOM/CRLF 检查和最终差异检查。文档专项测试覆盖：

- 集中扩展名、512 KiB / 180 行 / 4096 字符边界；
- CSV/TSV 30×12、引号和省略；
- 120 ms / 5 秒 / 12 秒状态节点及全部用户文案；
- Generation、列表实例、面板会话和 request id；
- Renderer/DPI/主题缓存键、SHA-256、原子发布和共享 LRU；
- 云占位拒绝、密码嗅探、IFilter 隔离和 Job Object；
- Seer 官方 4000/4001/5000/5004/5005 协议与超时；
- QuickLook 绝对路径、产品信息校验、无模拟按键；
- `QuickViewActive`、150 ms 选择防抖、外部窗口层级维护和 temporary 自动隐藏恢复；
- 设置窗口期间的悬浮抑制、覆盖窗口命中拒绝和默认 400 DIP 预览宽度。

## 当前环境不能执行

此容器没有 Windows GUI、AutoHotkey v2、MSVC/Windows SDK、Windows PDF Runtime、
PDF/DOCX Shell 处理器、Seer 或 QuickLook，因此没有声称下列实机项目已通过：

- x86/x64 原生编译和 AHK 启动解析；
- PDFium/Windows PDF 第一页及 DOCX IFilter 的真实视觉内容；
- 100%/150%/200% DPI、多显示器负坐标、焦点和无激活窗口；
- 加密/损坏/超大/NAS/云占位的端到端时间与内存；
- Seer/QuickLook 的真实打开、更新、关闭和崩溃恢复。

## Windows 人工验收步骤

1. 在 VS 2022 Developer PowerShell 运行 `native\build.ps1`，再运行
   `native\install-pdfium.ps1`；分别以 x64/x86 AutoHotkey v2 执行
   `PopDrop.ahk --self-test`。测试 x86 时安装脚本使用 `-Architecture All`。
2. 准备 Markdown、UTF-8/UTF-16 文本、巨型日志、CSV/TSV、普通/加密/损坏 PDF、
   普通/大量图片/损坏 DOCX；逐项验证首次、5 秒后、12 秒、移开和再次悬浮。
3. 验证缓存命中无加载卡，修改文件后旧缓存立即失效；检查缓存总量仍受 256 MiB /
   1000 项和 2 MiB 单项限制。
4. 在约 30 项的工作区只悬浮 2 个未缓存图片，关闭面板等待 10 秒；确认最多只尝试
   这 2 项。再次打开/关闭但不悬浮文件，确认没有新增生成任务。
5. 在设置页勾选 PDF 预览，验证下载确认、架构选择、SHA-256 失败拒绝安装，以及
   安装成功后自动勾选；保存并重启后验证 PDF 第一页。
6. 在 100%/150%/200% DPI 和不同 DPI 多屏（含负坐标）验证状态卡与最终内容外框不动、
   不抢焦点、拖拽/选择/滚动/右键不回归。
7. 分别测试未安装、安装未启用、启用 Seer、QuickLook 桌面/便携版及 Store 版；
   验证 Space、Esc、Enter、双击、150 ms 切换、外部崩溃与 temporary 恢复。
8. 回归图片预览、固定项、近期栏、工作区、扫描、拖入/拖出及三种窗口模式。

## 2026-07-30 实机反馈回归

- 使用两个实际出现覆盖的 Markdown 样本检查了输入特征。绘制契约不再依赖
  `DrawTextW` 的多行测量，而是按当前字体显式切分最多三条视觉行，并逐条使用
  `DT_SINGLELINE` 绘制和推进。
- 设置页契约固定检查压缩后的排除区域和完整的两行预览设置坐标，保证 Space Provider
  行位于底部操作栏上方。
- PDF 契约新增 PDFium 动态加载、自定义随机读取、64 MiB 读取预算、错误分类和
  首屏位图输出；同时保留 Win32 随机访问流、Windows 内置 `PdfDocument`、16 MiB
  编码流上限及系统链接项。安装脚本固定版本并校验发布 SHA-256。当前交付容器仍
  不能代替 Windows 实机执行这些渲染路径。
- 外部查看器契约检查进入 topmost 窗口带、250 ms 健康维护和关闭时层级恢复；
  设置页契约检查打开即抑制预览、关闭后恢复及覆盖坐标拒绝。
- 包内原有 x86/x64 `PopDropPreview.exe` 按用户要求原样保留；验证本轮 PDF 与
  Markdown 修复前，必须在 Windows 上运行 `native\build.ps1` 生成新 Helper。
