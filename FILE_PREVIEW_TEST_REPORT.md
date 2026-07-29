# PopDrop 0.10.0 文件内容预览测试报告

日期：2026-07-29  
当前环境：Linux 容器（无 Windows GUI、AutoHotkey v2、MSVC/Windows SDK）

## 结论

0.10.0 的 AHK 交互状态机、配置迁移、设置页、共享内存协议、原生
`PopDropPreview` 源码、x86/x64 构建配置、缓存策略和文档已完成。现有四组跨平台
契约测试及新增预览契约/状态模型测试全部通过；AHK 文件结构、INI BOM 和 CRLF
检查通过。

本环境不能编译或运行 Windows 二进制，也不能进行真实窗口、Shell/WIC、DPI、
焦点、拖放和性能实测。下列 Windows 项目仍必须在发布前执行，报告没有把它们标记
为已通过。

收到首次源码运行反馈后，已修复 `Preview.ahk` 把 AutoHotkey v2 保留字
`local` 用作变量名而导致的启动解析错误，并在预览契约测试中加入保留字赋值扫描，
防止同类问题回归。

收到 Windows 实机预览反馈后，已修复小尺寸 Shell 缓存缩略图限制预览图片和容器
尺寸的问题：缓存图明显小于目标时继续尝试 WIC 原图缩放解码，失败才回退缓存图。
自动侧边也会在面板移动或缩放结束后清除旧方向并按新工作区重算，避免窗口贴近
右边缘后预览仍尝试显示在右侧。

第二轮 Windows 实机反馈显示图片仍可能得到很小的系统缩略图，并且隐藏后台缓存
可能完全没有启动。获取顺序现已改为自有缓存 → WIC 原图 → Shell 最后回退，最后
回退的小图会等比放大。缓存 Helper 已是 IDLE 优先级且逐项串行，隐藏计时到达后
不再被后台扫描、设置窗口或传输无限阻塞；WIC 不支持的格式可在后台通过 Shell
缩略图处理器生成真实缩略图。协议号同步升级至 3 以拒绝旧 Helper。

后续 `cache-status.ini` 实机证据显示调度完成 17 项但成功为 0。根因定位到 WIC
编码后的文件句柄生命周期：独占 `IWICStream` 尚未释放时重新打开同一临时文件，
必然发生共享冲突并删除已编码结果。实现现已在刷新前释放完整编码 COM 链，协议
升级至 4；新增静态顺序检查防止该问题回归。

## 实际运行的自动化测试

```text
python3 tests/verify_file_manager_contract.py
file-manager contract checks: PASS

python3 tests/verify_file_preview_contract.py
file-preview contract and model checks: PASS

python3 tests/verify_folder_drop_contract.py
folder-source drop contract checks: PASS

python3 tests/verify_source_management_contract.py
source-management contract checks: PASS
```

附加检查：

- `PopDrop.ahk`、`Preview.ahk`、`SettingsGui.ahk`、`ConfigDocument.ahk`、
  `FileManager.ahk`、`ExternalDrop.ahk` 的字符串/注释感知大括号检查：PASS。
- `config.ini` 与 `config.example.ini` 单一 UTF-16LE BOM、CRLF：PASS。
- Python 测试脚本 `compileall`：PASS。
- 应用版本 `0.10.0`、配置版本 `20`、示例配置迁移字段一致性：PASS。

新增预览测试覆盖：

- 350/120/140/250 ms 默认时序和鼠标/键盘最后输入仲裁模型；
- Hidden、Armed、Loading、Visible、Suppressed 状态及 Generation、列表实例、
  面板会话、路径/请求 ID 校验；
- 整个 ListView 项目边界命中、主区/固定项/最近栏候选约束；
- 点击/多选不抑制，拖拽阈值后、固定排序、框选、滚动、菜单、刷新、视图/工作区、
  移动缩放和隐藏时抑制；
- 静止鼠标屏幕坐标恢复、150 ms 旧内容上限、60 秒负缓存、3 秒硬超时及
  60 秒最多 3 次重启；
- 自有缓存 → 原图解码 → Shell 最后回退顺序；
- Shell `THUMBNAILONLY | INCACHEONLY`，并确认没有 `CROPTOSQUARE` 或图标回退；
- Shell 最后回退等比放大、隐藏缓存不受长扫描无限阻塞、后台 Shell 真实缩略图
  生成，以及移动缩放后 Auto 侧边先重算再恢复预览；
- WIC 首帧、EXIF 方向、Alpha、sRGB、原生缩放转换和受展开内存保护的回退；
- 云占位拒绝、64 MiB / 65535 / 160 MP / 256 MiB 安全边界；
- Job Object 256 MiB 限制和有界 4 MiB 共享像素区；
- 隐藏 10 秒、低优先级、单任务、200 ms 让出、50 项成功限额和 100 次尝试硬上限；
- 缓存 Helper 启动失败/单项超时后继续队列、后台超时不触发预览熔断，以及
  `cache-status.ini` 调度与成功/失败计数；
- JPEG 0.82、Alpha PNG、1024/768/512 递降和 2 MiB 硬上限；
- SHA-256 名称、`preview-cache-v1` 限域、重解析点拒绝、陈旧临时文件、容量和
  数量清理；
- `[Preview]` 默认值、非法值回退、配置版本迁移、设置页三项保存；
- x86/x64 构建脚本和无第三方图像依赖声明。

## Windows 发布前测试清单（尚未执行）

### 构建与启动

- 在 VS 2022 Build Tools 环境运行 `native\build.ps1`，确认生成：
  - `native\bin\x64\PopDropPreview.exe`
  - `native\bin\x86\PopDropPreview.exe`
- 分别使用 x64/x86 AutoHotkey v2 执行 `PopDrop.ahk --self-test`。
- 源码模式和编译发布模式分别验证 Helper 路径、启动、正常退出、超时终止和重启。

### 交互与回归

- 主区、固定项、最近栏逐项验证首次、切换、离开宽限。
- 单击、Ctrl/Shift 多选、框选、滚轮/滚动条、右键菜单、内部/外部拖拽、固定排序。
- 键盘方向、Home、End、Page Up、Page Down、Enter、Esc、失焦与最后输入仲裁。
- 刷新、扫描晚到结果、工作区/视图/近期栏切换、文件删除/移动。
- 复跑打开、选择、多选、框选、拖拽、固定项排序、扫描、窗口模式、文件传输和退出
  全部既有手工回归。

### 内容与故障

- JPEG、PNG、GIF、BMP、TIFF、ICO、WebP、HEIF、AVIF、RAW；带/不带相应扩展。
- PDF、视频、Office、无扩展、错误扩展、损坏文件及只有普通图标的文件。
- EXIF 1–8、透明/半透明边缘、动画首帧、嵌入 ICC 配置。
- 新下载且无两级缓存的普通图片直接解码。
- 本地盘、USB、只读盘、UNC、断开网络盘、云端仅在线占位。
- 64 MiB、65535 边长、160 MP、256 MiB 展开内存边界两侧。
- 人工挂起 Shell/WIC 调用，确认 3 秒后 Helper 被结束，重启后新请求可用。

### 窗口、DPI 与性能

- 100%、150%、200%，混合 DPI 双屏、负坐标副屏、任务栏四边。
- 面板靠屏幕边缘、跨屏、接近全屏、实时移动和缩放。
- temporary、always_on_top、normal 的层级、无焦点、Alt+Tab/任务栏隐藏。
- 记录自有缓存、Shell 缓存、常见原图 P95，以及 UI 单次预览相关耗时；
  验收目标分别为 80/150/250/8 ms。

## 已知限制

- 本次交付没有 Windows 环境生成新的 `PopDropPreview.exe` 二进制；发布包必须先在
  Windows 构建并完成上述测试。
- HEIF、AVIF、WebP、RAW 等格式依赖系统安装的 WIC 编解码器。
- PDF、视频、Office 等非图片只使用 Windows 已存在的真实缩略图，不现场调用
  Shell 扩展生成。
- Alpha 缓存采用 WIC 真彩压缩 PNG；没有内建调色板量化。超过 2 MiB 时降尺寸，
  512px 仍超限则不保存，但当前即时预览仍可显示。

## 依赖与数据安全

- 没有下载、捆绑、链接或调用 pngquant、libimagequant、GPL 或商业组件。
- 缓存清理目标严格限定为 `preview-cache-v1` 的校验后普通缓存文件；不会删除原文件、
  扫描缓存、下载文件或其他应用数据。
- 既有文件打开、拖放、固定项、工作区、扫描、近期栏、窗口和传输实现均保留；自动化
  回归契约全部通过。Windows GUI 回归仍按上方清单待执行。
