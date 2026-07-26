# PopDrop

当前版本：**v0.9.0**

<img src="assets/logo.webp" width="192px">

按一下 `F2`，一个文件面板出现在屏幕最前面。找到文件，操作，关掉。全程不到三秒。

PopDrop 是一款 Windows 文件快捷面板，把你常用的文件夹、最近打开的文件、固定好的文件集中在一个面板里，随时取用，用完就关。面板默认使用临时窗口模式，切换到其他窗口后自动隐藏。

## 快速开始

### 使用 EXE 版本（推荐）

1. 从 [GitHub Releases](https://github.com/forfreeday/PopDrop/releases) 下载最新 zip 文件
2. 解压，保持 `PopDrop.exe` 和 `config.ini` 在同一目录
3. 双击运行 `PopDrop.exe`
4. 按 `F2` 试试看

### 使用 AHK 源码版本

1. 安装 [AutoHotkey v2](https://www.autohotkey.com/)（注意：v1 不行，必须装 v2）
2. 将 `config.example.ini` **复制一份**并改名为 `config.ini`
3. 双击 `PopDrop.ahk`
4. 按 `F2` 试试看

> 把 PopDrop 普通来源中的项目拖到另一个普通来源时，默认会移动真实文件；
> 从资源管理器拖入则默认复制。拖到固定项只保存面板记录，不会改动真实文件。

详细配置和使用说明请查看 **[使用指南](USAGE.md)**。

## 功能一览

- **一键呼出**：默认 `F2`，在任何软件中按一下，面板就在最前面打开
- **多目录最新文件**：同时添加下载、桌面、文档、项目等多个目录，每个分组独立显示
- **多工作区**：主面板直接切换不同来源组合和各自的固定项；最近文件和通用设置继续共享
- **缩略图网格**：图片、视频、PDF 优先显示系统缩略图，也可切换为文件名列表
- **固定项**：把常用文件或文件夹加入面板顶部，移出固定项不会影响原项目
- **按来源投放**：拖到 Files 来源即可复制或移动到对应真实文件夹，拖动中实时显示目标、动作和系统光标
- **外部内容投放**：标准虚拟文件、PNG/DIB 图片和公开文件 URL 在后台接收，不占用主面板
- **浏览器文件认领**：浏览器若已把拖出文件直接生成在目标目录，PopDrop 认领原文件而不再复制一份
- **网页图片质量选择**：同次拖放出现缩略图和原图时，等待候选完成并按真实像素尺寸
  保留较大版本，目标目录最终只落一份
- **下载入口与传输中心**：状态栏右侧稳定显示“↓ 下载”；必要时显示整体进度、短暂完成
  提示或未查看失败。传输中心按批次保留选择，并显示完成进度及平均传输速度
- **统一表单文字对齐**：单行文本框和下拉框在不改变外框尺寸的前提下垂直居中文字，
  并提供按物理像素微调的集中参数
- **Launcher 投放**：普通文件、文件夹和程序会创建 `.lnk`；已有 `.lnk/.url` 只复制，不移动原项目
- **固定项投放区**：拖到固定项分组或「＋ 固定项」按钮只加入固定项，不复制、移动或删除真实文件
- **新项目优先**：新加入的一批固定项显示在最前，并保持这批项目原有顺序
- **拖拽自由排序**：在固定项区域内拖到另一个固定项上即可调整顺序
- **拖入保持可见**：temporary 模式下接收拖入项目时暂停自动隐藏，完成后窗口保持打开
- **实时置顶切换**：顶部按钮可在 temporary 与 always_on_top 模式之间即时切换
- **完整拖放支持**：从面板拖拽文件到 Photoshop、浏览器、微信等任何软件
- **PopDrop 精简右键菜单**：打开、应用选择、Explorer 定位、复制、复制/移动到、固定项和回收站删除
- **完整系统菜单仍保留**：`Shift + 右击` 或 `Shift + F10`，包括第三方 Shell 扩展
- **键盘操作**：`Enter` 打开、`Delete` 移入回收站、`Ctrl + Enter` 定位、`Ctrl + C` 复制文件对象、`Ctrl + Shift + C` 复制路径
- **可选单击打开**：普通文件可全局或按来源切换单击/双击；多选、拖拽和文件夹双击不变
- **配置打开软件**：按扩展名显示最多 5 个常用应用，其余进入二级菜单
- **Shell 文件操作**：多选、跨目录复制/移动，使用 Windows `IFileOperation` 处理冲突、进度与取消
- **三种显示范围**：仅文件、文件和直接子文件夹、递归文件平铺
- **最近打开侧边栏**：右侧显示 Windows 近期文件记录，双击即可再次打开
- **多选操作**：`Ctrl` 多选、`Shift` 连续选、拖框选——支持跨文件夹、跨磁盘
- **Launcher 模式**：将文件夹变成快捷启动面板，按数字前缀排序 [详细说明](USAGE.md#快捷启动文件夹launcher模式v05)
- **窗口模式**：temporary（失焦自动隐藏）、always_on_top（始终置顶）、normal（普通窗口）[详细说明](USAGE.md#窗口模式v04)

## 快速配置

优先使用托盘菜单中的“PopDrop 设置…”：左侧导航把页面分为“共享设置”和“工作区设置”，
可管理通用选项、当前工作区来源、打开软件、复制/移动常用位置和排除规则。只有高级选项才需要直接编辑同目录下的
`config.ini`；左侧树形导航是唯一的页面切换入口，设置窗口底部保留了“高级设置…”入口。
监控来源的“文件夹类型”可直接
选择普通文件夹（Files）或启动器文件夹（Launcher）。选择 Launcher 会自动套用启动器
推荐值；切回 Files 会恢复按修改时间排序、显示完整文件名及普通文件类型过滤。
示例：

```ini
[General]
ConfigVersion=14
Hotkey=F2
OpenFileMode=DoubleClick
EscapeHidesPanel=1
MaxFilesPerFolder=10
DisplayScope=FilesOnly
FolderTimeMode=DirectoryModified
WindowMode=temporary
ViewMode=Thumbnail
ThumbnailSize=96
ThumbnailHorizontalGap=24
ThumbnailVerticalGap=4
ThumbnailTextLines=2
WindowWidth=766
WindowHeight=576
ShowRecentSidebar=0

[NoiseFilter]
Enabled=1
HideHidden=1
HideSystem=1
HideTemporaryAttribute=0
HideIncompleteDownloads=0
CustomPatternCount=0

[Workspaces]
Order=workspace-default
Active=workspace-default
PinnedScopeVersion=1

[Workspace:workspace-default]
Name=默认工作区
SourceOrder=source-downloads

[WorkspacePinned:workspace-default]

[Source:source-downloads]
WorkspaceId=workspace-default
Name=下载
Path=%USERPROFILE%\Downloads
OpenFileMode=SingleClick
```

`ThumbnailTextLines=1` 时，过长文件名会按图标宽度显示省略号；选择项目后，状态栏仍会
显示完整路径，切换到列表视图时也会恢复完整文本。双行模式维持原有显示方式。

## 工作区

主面板顶部的“工作区”下拉框显示并切换当前工作区，切换后会自动刷新，只扫描新工作区
的来源。工作区保存来源列表、顺序、来源专属设置和固定项；快捷键、窗口行为、共享
默认值、最近文件、软件列表和常用位置始终应用于所有工作区。

在“PopDrop 设置 → 工作区设置 → 当前工作区”中编辑来源，点击“管理工作区…”可以新建、
复制、重命名或删除工作区。复制会复制来源和固定项，并为工作区和每个来源生成新的
稳定身份，后续修改互不影响。新建空白工作区不包含来源或固定项。至少保留一个工作区；
删除工作区只删除其配置记录，不会删除任何真实文件。

v0.8 及更早版本的 `[Folders]`、`[Folder:名称]` 和来源规则会在首次启动 v0.9 时，通过
原子配置事务迁移到“默认工作区”。原配置会先保存在 `config.ini.bak`；共享设置及人工
注释、未知键、编码、换行和六个布局锚点保持不变。

旧版共享 `[PinnedFiles]` 会在首次启动配置版本 14 时迁移到当时的当前工作区；之后每个
工作区分别保存在 `[WorkspacePinned:<WorkspaceId>]`，切换工作区时固定项同步切换。

外部内容投放的安全默认值位于 `[ExternalTransfer]`：公开 HTTPS URL 兜底开启、
HTTP 关闭、全局最大并发 3、面板隐藏时按批次通知。均可在“PopDrop 设置 → 常规”中
修改。源码版还需要先运行 `native\build.ps1` 生成与 AutoHotkey 位数一致的
`PopDropTransfer.exe`；发布包应把对应 helper 放在 `PopDrop.exe` 同目录。

“PopDrop 设置”的“共享设置 · 通用”和“当前工作区”页可选择共享默认打开方式，并为每个来源选择
“使用共享默认值”、“单击”或“双击”。各工作区的固定项和共享的最近文件都使用共享默认值；文件夹始终需要双击。单击模式只在
无修饰键且未发生拖拽的左键释放时打开文件。

所有配置项详解见 **[使用指南](USAGE.md)**。

`config.ini` 中的 `; <PopDrop:area 1>`～`; <PopDrop:area 6>` 是注释形式的
布局锚点。程序用它们把自动维护的配置节放回正确区域；请保留这些标记。设置界面和
面板快捷操作只改动相关键或受管理列表，其他注释、未知键和人工排版保持原样。

手工配置打开软件时，只需在 `[OpenApps]` 的 `Order=` 中列出可读 ID，再添加对应的
`[OpenApp:<ID>]` 段；例如 `Order=7z,everedit`。应用段中只有 `Path` 必填，
`Name`、`Icon`、`Enabled` 均有安全默认值。旧版 `App001=<UUID>` 格式会自动迁移。

## 安全说明

PopDrop 不会静默覆盖文件，也不会通过“复制后删除”模拟跨盘移动。复制和移动由
Windows Shell 原生文件操作完成；重名、合并、权限提升、取消和部分完成由系统处理。
拖放默认规则为：PopDrop 普通来源之间默认移动，外部文件默认复制；按住 `Ctrl` 请求
复制，按住 `Shift` 请求移动。固定项和 Launcher 的安全语义不受修饰键改变：
固定项只保存路径，Launcher 只创建快捷方式或复制已有快捷方式。

拖放严格按 `CF_HDROP`、`FILEDESCRIPTORW/FILECONTENTS`、PNG/DIB、明确 URL 的顺序
选择唯一适配器。QQ、微信当前提供的本地路径继续走原有 `IFileOperation` 链路；不会
因为同时存在 URL 就改成下载。外部虚拟内容和 URL 只能放入普通 Files 来源，Launcher
和固定项会明确拒绝。

URL 兜底只用于公开可访问文件。PopDrop 不读取或继承浏览器 Cookie、密码和登录态，
不注入浏览器/聊天/网盘进程，也不读取聊天数据库。登录页、验证码页和普通 HTML 导航
会失败并提示先在浏览器完成下载。HTTP 默认关闭，TLS 证书验证不会被绕过。

后台写入使用隐藏的 `.popdrop-part`，完成并刷新文件缓冲后才原子改为最终唯一名称；
面板不会显示半成品，也不会静默覆盖。网络文件通过 Windows Attachment Execution
Services 记录来源，PopDrop 不自动打开或执行下载结果。temporary 模式隐藏面板不会
取消后台任务。

PopDrop 支持标准 Windows 拖放格式，但不承诺所有网站和应用；只提供私有格式、页面内
排序、依赖登录态或特殊请求头的来源可能无法接收。由于 Windows UIPI 安全限制，PopDrop
与来源程序处于不同管理员权限级别时，拖放仍可能被系统阻止。

程序路径和文件参数分别交给 Windows API，v0.7 只允许配置 `.exe`。软件由 AutoHotkey
开发，可能被安全软件误报。

`[TransferFavorites]` 中的每条 `PathNNN` 都是可删除的常用目标；桌面和下载也作为普通
配置项保存，删除后不会被程序重新添加。
