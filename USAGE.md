# PopDrop 使用指南

## 文本块工作区

在“设置 → 来源与工作区 → 管理工作区”中新建工作区，类型选择“文本块”。工作区类型
创建后保持不变；已有配置会自动迁移为文件工作区。文本块工作区不显示文件夹层级，
而是递归平铺所有来源及子目录中的 `.md`、`.txt` 文件。

### 捕获与固定

| 操作 | 结果 |
| --- | --- |
| 从外部拖入选中文字到某个来源 | 在该来源根目录创建 UTF-8 `.md` 文件 |
| 从外部拖入选中文字到固定项 | 创建应用管理的独立文本块，并置于固定项最前 |
| 点击“📋+” | 把非空白剪贴板文字创建为独立文本块并固定 |
| 在卡片区或列表空白处按 `Ctrl+V` | 与“📋+”相同；输入控件中仍为普通粘贴 |
| 把已有 `.md/.txt` 加入固定项 | 只保存链接；原来源卡片继续显示，固定卡片右下角显示链接图标 |
| 从固定项移除独立文本块 | 二次确认后把实体文件移入回收站 |
| 把独立文本块拖到文本来源 | 默认移动实体完成归类并从固定项消失；按住 `Ctrl` 则复制并保留固定项 |
| 把固定项文件链接拖到文本来源 | 默认复制；按住 `Shift` 时拒绝移动原文件 |
| 混选独立文本块与文件链接 | 默认拒绝移动；按住 `Ctrl` 可统一复制 |

工具栏把固定项操作置于两条分隔线之间：文件工作区显示“＋固定项 / －固定项”，文本
工作区显示“＋固定项 / 📋+”。“📋+”仅在剪贴板含非空白文字时可用。`Ctrl+V` 只在
文本工作区的卡片列表、列表空白区或面板容器接管；搜索框、重命名框、编辑器及其他控件
不会被拦截。通过按钮或快捷键创建的内容使用与拖入固定项相同的 UTF-8 Markdown、命名、
去空白、2 MiB 上限及原子固定流程。

新建内容有 24 小时优先展示保护，之后按最近使用、近 30
天使用次数和历史次数进行智能排序。连续 10 秒的同一文本块重复使用只计一次。
所有文本块使用相同背景、边框和选中样式，不再显示“未分类”前缀。固定项中的文件链接
仅通过卡片右下角的轻量链接图标表达；来源区域始终显示实体卡片且不显示该图标。

### 分类内置顶

- 在来源卡片的 PopDrop 右键菜单中选择“在当前文件夹置顶”；已置顶卡片可选择“取消置顶”。
  多选可一次处理多个来源，每个卡片只修改自己所属来源的状态。
- 置顶卡片始终排在所属来源的普通卡片之前，并在右下角显示 `pin.ico` 图标；其余背景、
  边框和文字样式不变。固定项中的链接仍只显示链接图标。
- 单个置顶卡片在同一来源内拖到另一个置顶卡片，可调整顺序并立即保存；拖离该来源时按
  原有文本块拖放规则处理，不会把普通卡片误当成排序目标。
- 每个来源的普通显示数量只限制普通卡片。置顶卡片全部显示，不占普通配额；普通卡片仍
  使用现有智能排序。搜索结果保留来源身份，可直接执行置顶或取消置顶。
- 配置按稳定来源 ID 保存为 `[TextSourcePinned:<SourceId>]`。来源内重命名或移动会同步
  更新路径；移出来源或删除实体文件时会移除该来源的置顶记录。

### 查找、发送与编辑

- 面板内直接打字即可筛选；`/` 或 `Ctrl+F` 聚焦搜索框，`Esc` 先清空搜索。
- 双击或 `Enter`：复制正文，并粘贴到呼出 PopDrop 前的窗口；无法粘贴时正文仍留在剪贴板。
- `Ctrl+C`：复制正文；多选时以两个换行连接。
- 默认拖出：提供 `CF_UNICODETEXT` 正文；按住 `Alt` 拖出：提供真实文件。
- `F4`：使用内置编辑器编辑；支持 `Ctrl+S`、未保存关闭确认和“另存为副本”，右键菜单也可交给系统默认编辑器。
- `Ctrl+1`～`Ctrl+9`、`Ctrl+Tab`：切换工作区。设置中还可给每个工作区指定独立快捷键；面板隐藏时，主快捷键单击进入最近文件区、快速双击进入“默认文本区”；面板显示时按主快捷键只关闭面板。

## 快速开始

### 安装

**EXE 版本：**
1. 从 [GitHub Releases](https://github.com/forfreeday/PopDrop/releases) 下载最新 `PopDrop.exe`
2. 保持 `PopDrop.exe` 和 `config.ini` 位于同一目录
3. 双击运行 `PopDrop.exe`
4. 按 `F2` 试试看

**AHK 源码版本：**
1. 安装 [AutoHotkey v2](https://www.autohotkey.com/)（注意：v1 不行，必须装 v2）
2. 将 `config.example.ini` **复制一份**并改名为 `config.ini`
3. 双击 `PopDrop.ahk`
4. 按 `F2` 试试看

外部内容投放需要 `native\bin\<架构>\PopDropTransfer.exe`，文件预览需要
对应架构的 `native\bin\<架构>\PopDropPreview.exe`。正式发布包应已包含；源码运行时可用
Windows 自带的 MSVC Build Tools 执行 `native\build.ps1` 构建。除此之外不需要第三方
运行库。除了右键菜单中的
“复制到…”和“移动到…”，把项目投放到来源分组也可能操作真实文件；具体安全语义见
“按来源投放本地文件”。

### 配置示例

编辑同目录下的 `config.ini`，保存后在面板点「刷新」就行：

```ini
[General]
ConfigVersion=27
Hotkey=F2
DoubleHotkeyWorkspaceId=workspace-text-default
LastFileWorkspaceId=workspace-default
OpenFileMode=DoubleClick
DefaultContextMenu=PopDrop
MaxFilesPerFolder=8
DisplayScope=FilesOnly
FolderTimeMode=DirectoryModified
IncludeSubfolders=0
ThumbnailSize=96
ThumbnailHorizontalGap=24
ThumbnailVerticalGap=4
ThumbnailTextLines=2
WindowWidth=766
WindowHeight=576
ViewMode=Thumbnail
ShowRecentSidebar=0
RecentFileCount=12
CachePath=
ConsistencyCheckHours=2
ThumbnailPolicy=Full
WindowMode=temporary

[Preview]
Enabled=1
Side=Auto
HoverDelayMs=350
SwitchDelayMs=120
LeaveGraceMs=140
PreviousPreviewHoldMs=500
BackgroundColor=#000000
BackgroundOpacity=255
KeyboardDelayMs=250
Width=400
CacheEnabled=1
CacheStartAfterHiddenSeconds=10
CacheMaxMB=256
CacheMaxItems=1000
CacheItemMaxKB=2048
CacheUnreferencedDays=7
DirectImageMaxFileMB=64
DirectImageMaxEdge=65535
DirectImageMaxPixelsMP=160
DirectImageMaxExpandedMB=256
DocumentEnabled=1

[QuickPreview]
ExternalQuickPreviewProvider=Off
SeerIntegrationEnabled=0
QuickLookPath=

[Workspaces]
Order=workspace-default
Active=workspace-default
PinnedScopeVersion=1

[Workspace:workspace-default]
Name=默认工作区
Type=Files
Hotkey=
SourceOrder=source-documents,source-downloads

[WorkspacePinned:workspace-default]
File001=%USERPROFILE%\Desktop\常用文档.docx

[Source:source-documents]
WorkspaceId=workspace-default
Name=文档
Path=%USERPROFILE%\Documents

[Source:source-downloads]
WorkspaceId=workspace-default
Name=下载
Path=%USERPROFILE%\Downloads
```

配置文件使用 UTF-16LE 和 CRLF。六个 `; <PopDrop:area N>` 行是普通 INI
注释，同时也是程序的布局锚点，请勿删除或重复。程序保存时会保留未修改的注释和
未知配置项，并在完整校验通过后原子替换原文件。

### 配置项说明

| 配置项 | 作用 |
|---|---|
| `[Folders]` | 每一行是一个分组，格式是 `显示名称=文件夹路径`。路径支持 `%USERPROFILE%` 等环境变量。 |
| `[Workspaces]` | 保存稳定工作区顺序、当前工作区和固定项作用域迁移标记。 |
| `[WorkspacePinned:<WorkspaceId>]` | 对应稳定工作区身份的固定项列表，键为 `File001`、`File002` 等。 |
| `[TextSourcePinned:<SourceId>]` | 文本来源内部置顶顺序，键为 `File001`、`File002` 等；与全局固定项互不替代。 |
| `Type` | 工作区类型：`Files` 或 `Text`。旧工作区缺失时自动补为 `Files`。 |
| 工作区 `Hotkey` | 可选的独立呼出快捷键；不得与主快捷键或其他工作区重复。 |
| `DoubleHotkeyWorkspaceId` | 可选的默认文本区 ID，只能选择文本块工作区。两次主快捷键须在 240 ms 内完成；单击动作提交后手势立即结束，窗口出现后的下一次按键不会继续上一组双击。 |
| `LastFileWorkspaceId` | 最近使用的文件工作区。主快捷键单击始终进入这里；从文本块工作区按主快捷键也会返回这里。目标失效时回退到首个文件工作区。 |
| `DisplayScope` | `FilesOnly`=仅当前目录文件；`FilesAndFolders`=当前目录文件和直接子文件夹；`RecursiveFiles`=递归文件平铺。 |
| `FolderTimeMode` | `DirectoryModified`=文件夹自身时间；`LatestContent`=允许扫描的后代文件最新时间。 |
| `IncludeSubfolders` | v0.6 及更早版本兼容项；缺少 `DisplayScope` 时，`0` 迁移为 `FilesOnly`，`1` 迁移为 `RecursiveFiles`。 |
| `ThumbnailSize` | 缩略图边长，48～256。建议 72、96、128 或 160。 |
| `ThumbnailHorizontalGap` | 相邻图标之间的水平留白，0～128 像素，默认 24。 |
| `ThumbnailVerticalGap` | 相邻图标行之间的垂直留白，0～128 像素，默认 4。文件名高度由 `ThumbnailTextLines` 另行预留，设为 0 也不会压扁缩略图。 |
| `ThumbnailTextLines` | 缩略图文件名显示并预留的行数。`1`=单行紧凑，过长名称按图标宽度显示省略号，完整路径仍可在状态栏查看；`2`=双行，默认 2；其他值会自动限制到 1～2。 |
| `WindowWidth` / `WindowHeight` | 面板打开时的尺寸。 |
| `TextBlockCardWidth` / `TextBlockCardHeight` | 文本块卡片宽高，单位 DIP；范围分别为 140–640 和 48–320。增大宽度可显示更长的横向文字，增大高度会自动容纳更多行。 |
| `ViewMode` | `Thumbnail`=缩略图，`List`=文件名+修改时间。也可以从面板顶部“显示 ▾”菜单切换。 |
| `ShowRecentSidebar` | `1`=显示最近打开侧边栏，`0`=关闭。也可以从“显示 ▾”菜单随时开关。 |
| `RecentFileCount` | 侧边栏最多显示多少个近期文件，范围 1～100。 |
| `CachePath` | 运行时索引目录。留空时优先使用软件目录下的 `cache`；目录不可写或位于网络盘时回退到 `%LOCALAPPDATA%\PopDrop\cache`。 |
| `ConsistencyCheckHours` | 轻量一致性检查间隔（小时），默认 2，`0`=关闭。不启用常驻计时器：呼出窗口时判断是否到期，窗口关闭后只校验未被健康监听覆盖的来源。 |
| `ThumbnailPolicy` | `Full`（默认）首帧先读取 Shell 缓存或显示类型图标，再逐项增强未缓存缩略图；`Fast` 只使用已有缓存和类型图标。 |
| `WindowMode` | 窗口显示模式：`temporary`（默认，置顶，切换到其他窗口后自动隐藏）、`always_on_top`（始终置顶）、`normal`（普通窗口，不置顶）。 |
| `OpenFileMode` | 普通文件的鼠标激活方式：`DoubleClick`（默认）或 `SingleClick`。缺失、空值或未知值都回退为双击。 |
| `DefaultContextMenu` | 默认右键菜单：`PopDrop`（默认、推荐）或 `System`。缺失、空值或未知值都安全回退为 PopDrop 快捷菜单。 |
| `EscapeHidesPanel` | 按 Esc 时隐藏面板：`1`=隐藏（默认）| `0`=不隐藏。 |
| `SortMode` | 排序模式：`ModifiedDesc`（修改时间从新到旧，默认）、`NameAsc`（文件名自然升序）。支持文件夹级覆盖。 |
| 快捷键语法 | AutoHotkey v2 格式：`^`=Ctrl，`!`=Alt，`+`=Shift，`#`=Win。例如 `^!Space`=Ctrl+Alt+Space。 |

### 文件内容预览（v0.10+）

主面板顶部的“显示 ▾”打开一个 Windows 原生菜单，结构为：

- “缩略图”和“列表”是互斥视图，圆点表示当前模式；
- “文件预览”和“近期栏”是独立开关，勾选表示开启；
- 点击当前视图不会重复刷新；切换其他项目会立即生效并持久化；
- 按钮可通过 Tab 聚焦，并可用 Space/Enter、方向键、Enter 和 Esc 操作。

“显示 ▾”按钮宽度小于固定项按钮，固定项按钮组两侧使用竖向分隔线，避免与刷新、显示、
设置等独立操作混在一起。

菜单打开时会临时暂停 temporary 模式的自动隐藏并抑制当前预览，关闭后恢复判断。
设置窗口或配置重载改变状态后，下次打开菜单会按真实运行状态重新同步，而不是沿用
上一次的菜单勾选。

设置页“显示”中可以分别控制文件预览、文档预览、位置、静态快照缓存和外部空格键
预览。保存后立即生效。原图允许安全解码时优先使用原图；Windows 已有
缩略图只作为最后回退，并会等比放大到可用区域。后台缓存从面板隐藏后开始计时；
到达设定时间后由 IDLE 优先级 Helper 串行生成，不会因长时间扫描而永久跳过；
WIC 不支持的格式会在后台尝试系统缩略图处理器。其余参数保留在 `[Preview]`：

| 配置项 | 作用 |
|---|---|
| `Enabled` | `1` 开启，`0` 关闭；关闭时立即取消当前请求并隐藏窗口。 |
| `Side` | `Auto`、`Right` 或 `Left`；Auto 在普通文件切换期间锁定侧边，优先放在面板左侧（新文件列表侧），左侧空间不足时才放右侧；面板移动或缩放结束后按新工作区重算。 |
| `HoverDelayMs` / `SwitchDelayMs` / `LeaveGraceMs` | 首次悬浮、已显示时切换和未出现预览时的离开宽限。 |
| `PreviousPreviewHoldMs` | 已有预览时跨过项目空隙或等待下一项加载，旧预览最多继续保留多久；默认 500 ms，范围 0–3000。 |
| `BackgroundColor` | 预览背景色，必须使用 `#RRGGBB` 格式；默认 `#000000`。 |
| `BackgroundOpacity` | 背景不透明度，范围 0–255；默认 255，204 等同 80% 不透明。 |
| `KeyboardDelayMs` | 真实键盘导航改变焦点后的延迟。 |
| `Width` | 最大内容宽度，单位 DIP，范围 180–640。 |
| `CacheEnabled` | 只控制写入新缓存；关闭后仍可读取已有有效缓存。 |
| `DocumentEnabled` | `1` 允许文档悬浮预览；关闭后立即隐藏文档卡并失效显示请求，已有缓存保留。 |
| `CacheStartAfterHiddenSeconds` | 面板连续隐藏多久后开始低优先级生成。 |
| `CacheMaxMB` / `CacheMaxItems` | 自有预览缓存的软容量和项目数上限。 |
| `CacheItemMaxKB` | 单项硬上限，最大允许值为 2048。 |
| `DirectImageMaxFileMB` | 图片原文件即时解码的文件大小上限，默认 64 MiB。 |
| `DirectImageMaxEdge` / `DirectImageMaxPixelsMP` | 源图边长和总像素安全边界。 |
| `DirectImageMaxExpandedMB` | 解码器无法原生缩小时允许的预计展开内存上限。 |

只有本次实际悬浮且尚无静态快照的图片或文档才进入隐藏后生成队列；关闭面板不会
扫描当前工作区、固定项或最近项。文件大小与最后修改时间都未变化时直接复用现有
快照，不重新解码或压缩。每次面板隐藏会话最多成功生成 50 项；失败不占成功额度，
单轮最多尝试 100 项。
缓存运行状态写入
`cache\preview-cache-v1\cache-status.ini`；其中 `Stage`、`Attempted`、
`Succeeded`、`Failed` 和剩余队列可用于判断缓存是否启动及失败位置。

鼠标可命中整个实际项目边界。单击和 Ctrl/Shift 多选不会改变悬浮候选；拖拽超过
系统阈值后、固定项排序、框选、滚动、菜单、工作区/视图切换和窗口实时移动缩放会
立即抑制。滚动、菜单、框选或移动结束后会读取当前屏幕坐标自动恢复。

键盘使用方向键、Home、End、Page Up、Page Down 建立候选；Enter、Esc、列表失焦
或隐藏面板会立即关闭预览。鼠标静止在 A 上而键盘移到 B 时显示 B，只有鼠标再次
真实移动才切回鼠标候选。

Markdown、纯文本、日志、配置和常见代码最多读取开头 512 KiB；支持 BOM、UTF-8、
UTF-16，并在二进制嗅探通过后有限回退系统代码页。CSV/TSV 最多显示 30 行 × 12 列，
不执行公式。Markdown 只绘制静态标题、段落、强调、列表、任务、引用、代码、表格和
分隔线；原始 HTML、脚本、Mermaid、插件、网络资源和链接点击均不会执行。

PDF 预览默认关闭。可在“设置 → 显示与过滤”中勾选“PDF 预览”；组件尚未安装时
PopDrop 会先征求同意，再异步下载当前架构的 PDFium 并校验 SHA-256。PDF 卡只显示
第一页：已有 Shell 缩略图可直接使用，否则隔离 Helper 优先动态加载
同目录的非 V8/XFA `pdfium.dll`，使用按需随机读取生成静态快照；PDFium 不可用时
再通过原生只读随机访问流调用 Windows 自带 `Windows.Data.Pdf`。组件来源由
`native\pdfium-component.ini` 集中维护，默认填写固定 GitHub TGZ 发行包地址；
也可改为自托管 HTTPS DLL、ZIP 或 TGZ，并填写 SHA-256。ZIP/TGZ 会自动安全解压并
定位唯一的 `pdfium.dll`。也可显式运行 `native\install-pdfium.ps1`；
DOCX 优先使用 Windows IFilter
提取开头语义文本，无法提取时尝试系统真实缩略图。它们都在可终止 Helper 内运行，
不会启动 Word、执行宏/OLE/ActiveX、访问远程关系或自动下载云端占位文件。复杂
DOCX 版式、分页、页眉页脚和嵌入图片可能被简化或忽略。

首次生成约 120 ms 内完成时直接显示；之后显示“首次预览正在生成…”，5 秒后更新为
长耗时提示，12 秒硬超时。结果只有在 Generation、列表实例和面板会话仍匹配时才
能显示；移开后完成的安全任务只写共享快照缓存。错误按资源超限、密码保护、超时、
不可访问和损坏/不支持区分，并使用分类负缓存。

### 外部空格键快速预览

`[QuickPreview]` 默认 `Off`。设置为 `Seer` 时还需
`SeerIntegrationEnabled=1` 且运行中的 Seer 通过 `SeerWindowClass` 检测；
设置为 `QuickLook` 时，`QuickLookPath` 必须是桌面版或便携版
`QuickLook.exe` 的绝对路径，并通过产品信息校验。Microsoft Store 版不具有可假定的
命令行接口。

能力检测失败时 PopDrop 不接管空格键。成功打开后进入临时 `QuickViewActive`：
temporary 模式不会因外部查看器获得焦点而隐藏；焦点项变化以 150 ms 防抖同步；
再次按 Space 或先按 Esc 关闭外部预览，Enter/双击正式打开文件前也会关闭。该状态
会把外部查看器维持在 PopDrop 之上，关闭时恢复查看器原来的窗口层级；不会修改或
保存 PopDrop 的置顶设置。PopDrop 不安装、捆绑或模拟按键调用任何外部查看器。

---

## 工作区（v0.9+）

工作区保存不同的文件来源组合及来源专属设置。主面板顶部常驻显示当前工作区；选择另一
项后立即刷新，只向扫描 worker 发送新工作区的来源，并显示该工作区自己的固定项。
Windows 最近文件区域仍然显示，因为它属于共享设置。

工作区包含来源名称、路径、顺序、Files/Launcher 类型、显示范围与数量、排序、文件夹
时间、过滤、噪音过滤覆盖、附加忽略规则、排除/允许子路径、来源打开方式及固定项。
它不包含快捷键、窗口行为、共享默认值、最近记录、打开软件或复制/移动常用位置。

在“PopDrop 设置 → 工作区设置 → 当前工作区”中：

1. 顶部下拉框切换已有工作区。
2. “管理工作区…”可以新建、复制当前工作区、重命名和删除。
3. 新建时可复制当前来源和固定项（推荐），也可创建不含来源和固定项的空白工作区。
4. 空工作区在主面板显示明确提示，不会被当作配置错误。

设置窗口只使用左侧树形导航切换页面，不再显示功能重复的顶部标签栏。单行下拉框、
文本框和按钮采用统一的紧凑高度。新配置的主窗口默认尺寸为 766×576，近期栏默认
关闭；已有配置仍沿用用户保存的值。主面板重新打开时会把保存过的超宽宽度限制到
980，避免恢复成接近最大化的宽屏状态，但显示后仍可自由拖动缩放。

如特定 Windows 缩放比例或字体造成控件仍有 1–2 像素偏差，可在 `PopDrop.ahk`
顶部集中调整以下参数；主面板、设置页和子窗口会一起生效：

- `UI_SINGLE_LINE_HEIGHT := 26`：按钮及单行文本框的逻辑像素总高度。
- `UI_DROPDOWN_FIELD_HEIGHT := 22`：下拉框内部文字选择区的逻辑像素高度。下拉框
  仍偏高时减小，偏矮时增大；每改 1，在 200% 缩放下约变化 2 个物理像素。
- `UI_DROPDOWN_Y_OFFSET_PX := 1`：所有下拉框的物理像素纵向偏移。正数向下，
  负数向上；这是物理像素值，不需要按 DPI 换算。
- `UI_EDIT_TEXT_Y_OFFSET_PX := 0`：只移动单行文本框中的文字和插入光标；正数向下，
  负数向上，不改变文本框外框。
- `UI_DROPDOWN_TEXT_Y_OFFSET_PX := 0`：只移动下拉框选择区和弹出列表中的文字；
  正数向下，负数向上，不改变下拉框外框、箭头或位置。

后两个文字偏移参数使用物理像素，可以直接按截图中看到的像素差调整。例如文字仍偏上
2 个物理像素时，把对应参数从 `0` 改为 `2`。不要为了移动文字而修改
`UI_SINGLE_LINE_HEIGHT` 或 `UI_DROPDOWN_FIELD_HEIGHT`，否则会破坏已经对齐的外框。

工作区名称不区分大小写且不能重复。名称只是显示文本；内部使用稳定 `WorkspaceId`。
复制工作区时会为副本及其中每个来源生成新 ID，因此两个工作区可以使用同一路径和不同
来源设置，后续修改互不影响。同一工作区内仍禁止来源重名或路径重复。

设置窗口有未保存修改时，切换工作区或打开管理窗口会询问“保存并继续、放弃修改并继续、
取消”。保存失败时保留原草稿和当前工作区。至少保留一个工作区；删除当前工作区前会
明确显示将切换到哪个剩余工作区。删除工作区不会删除真实文件。

配置结构：

```ini
[Workspaces]
Order=workspace-default,workspace-design
Active=workspace-design
PinnedScopeVersion=1

[Workspace:workspace-design]
Name=设计项目
SourceOrder=source-design-assets

[WorkspacePinned:workspace-design]
File001=D:\Design\项目说明.docx

[Source:source-design-assets]
WorkspaceId=workspace-design
Name=设计素材
Path=D:\Design\Assets
Mode=Files
DisplayScope=RecursiveFiles
MaxFilesPerFolder=30
SortMode=ModifiedDesc
OpenFileMode=Inherit
```

`[Workspaces]` 保存顺序、当前 ID 和固定项作用域迁移标记；`[Workspace:<ID>]` 保存显示
名称与来源顺序；`[WorkspacePinned:<ID>]` 保存该工作区自己的固定项；
`[Source:<ID>]` 保存来源本身及全部来源专属设置。来源的排除、允许和附加忽略规则继续
使用 `[SourceExclude:<SourceId>]`、`[SourceAllow:<SourceId>]` 和
`[SourceIgnore:<SourceId>]`，因此重命名工作区或来源不会丢失规则。

首次启动 v0.9 时，旧 `[Folders]` 顺序、`[Folder:名称]` 覆盖及稳定 `SourceId` 会在
一个原子事务中迁移到“默认工作区”，当前工作区也设为它。写入前创建 `config.ini.bak`；
临时文件经过完整布局、重复节/键、UTF‑16LE BOM 校验后才替换原文件。失败时原配置不变。
旧节作为兼容快照保留，不再作为 v0.9 的运行时来源。

从早期 v0.9 配置升级到配置版本 14 时，旧 `[PinnedFiles]` 中的共享固定项会在同一套
备份和原子写入机制下迁移到当时的当前工作区。以后移动或删除真实文件时，PopDrop 会
同步修正所有工作区中指向该项目的固定记录，但不会影响其他不相关的工作区固定项。

---

## 单击或双击打开文件

点击托盘菜单中的“PopDrop 设置…”或在面板顶部点击“设置”打开图形化设置窗口，在
“共享设置 · 通用”和“当前工作区”页中选择共享默认打开方式，并为每个来源选择：

- `Inherit`：使用共享默认值（默认）
- `SingleClick`：单击普通文件立即打开
- `DoubleClick`：双击普通文件打开

也可以直接编辑：

```ini
[General]
OpenFileMode=DoubleClick

[Folder:下载]
OpenFileMode=SingleClick

[Folder:项目]
OpenFileMode=Inherit
```

单击模式只改变普通文件的鼠标激活次数。`Ctrl`/`Shift` 选择、框选和拖拽不会打开
文件；文件夹（包括直接显示的子文件夹和固定文件夹）仍然需要双击。固定项和最近文件
使用共享默认值。同一个文件显示在两个来源分组时，分别使用当前分组的来源设置。

来源首次迁移时会获得稳定 `SourceId`，并在 `[Sources]` / `[Source:<ID>]` 中保留身份；
单独修改来源名称或路径、以及调整顺序，都不会丢失打开方式。通常无需手工编辑这些
内部字段。

---

## 文件筛选（v0.3+）

从 v0.3 开始，PopDrop 支持按文件扩展名筛选，可以在全局和文件夹级别独立配置。

### 临时、锁定及系统文件过滤（v0.7.1）

在“PopDrop 设置 → 过滤与显示”中可以开启总开关，并通过“管理忽略规则…”配置
Hidden、System、Temporary 属性、未完成下载文件和自定义文件名通配规则。自定义规则
每行一条，只支持 `*` 和 `?`，不区分大小写，也不会删除或修改真实文件。

新安装和升级安装都采用“配置项缺失即使用默认值”的兼容策略：总开关、Hidden、System
默认开启；Temporary 和未完成下载默认关闭。每个来源可选择使用共享默认值、启用或禁用，并可
添加来源专属规则。固定项目始终优先显示。

```ini
[NoiseFilter]
; Enabled：总开关；1=排除噪音文件，0=全部显示。
Enabled=1
; HideHidden / HideSystem：排除相应 Windows 文件属性。
HideHidden=1
HideSystem=1
; Temporary 属性和未完成下载默认不排除。
HideTemporaryAttribute=0
HideIncompleteDownloads=0
; CustomPatternCount 是下方 CustomPatternNNN 规则的数量。
CustomPatternCount=2
CustomPattern001=*.myapp-lock
CustomPattern002=__temp__?

[Folder:下载]
NoiseFilterMode=Inherit

[SourceIgnore:source-example]
PatternCount=1
Pattern001=*.download-marker
```

### 筛选模式

| 模式 | 含义 |
|---|---|
| `All` | 显示所有文件（默认，不筛选） |
| `Include` | 只显示扩展名列表中的文件 |
| `Exclude` | 排除扩展名列表中的文件 |
| `Inherit` | 仅文件夹级可用，整体继承全局筛选模式及扩展名列表 |

### 全局配置

```ini
[General]
; All / Include / Exclude
FilterMode=All
FileExtensions=
```

- `FilterMode=All` 时，`FileExtensions` 被忽略，显示所有文件。
- `FilterMode=Include` 时，只显示扩展名匹配的文件。
- `FilterMode=Exclude` 时，排除扩展名匹配的文件。

### 文件夹级独立配置

每个文件夹可以独立覆盖筛选设置。名称必须与 `[Folders]` 中的显示名称一致。

```ini
[Folder:下载]
IncludeSubfolders=0
MaxFilesPerFolder=12
FilterMode=Exclude
FileExtensions=.tmp,.part,.crdownload,.download

[Folder:素材]
FilterMode=Include
FileExtensions=.png,.jpg,.jpeg,.webp,.gif
```

**继承规则：**

- 没有 `[Folder:名称]` 配置节：完全继承共享设置。
- `IncludeSubfolders` 缺失：继承共享默认值。
- `MaxFilesPerFolder=Inherit` 或缺失：继承共享默认值；设置界面可直接选择
  “继承全局”。`0` 或 `All` 仍表示显示全部。
- `FilterMode=Inherit` 或缺失：**整体**继承全局筛选模式及扩展名列表。
- `FilterMode=All`：该文件夹显示所有文件，忽略 `FileExtensions`。
- `FilterMode=Include` 或 `Exclude`：使用自己的 `FileExtensions`，不会继承全局扩展名列表。

### 扩展名规则

- 大小写不敏感：`jpg`、`.JPG`、`.jpg` 都一致对待。
- 自动补 `.` 前缀：`jpg` 等同于 `.jpg`。
- 支持多段后缀：`.tar.gz`。
- 逗号分隔，前后空格自动忽略。
- 重复扩展名自动去重。

### 完整示例

```ini
[General]
Hotkey=F2
MaxFilesPerFolder=8
DisplayScope=FilesOnly
FolderTimeMode=DirectoryModified
ThumbnailSize=96
ThumbnailHorizontalGap=24
ThumbnailVerticalGap=4
ThumbnailTextLines=2
; 窗口模式：temporary（默认）| always_on_top（始终置顶）| normal（普通窗口）
WindowMode=temporary
; 全局：显示所有文件
FilterMode=All

[Folders]
下载=%USERPROFILE%\Downloads
素材=D:\Assets
项目=D:\Projects

[Folder:下载]
; 排除临时文件和下载片段
DisplayScope=FilesOnly
MaxFilesPerFolder=12
FilterMode=Exclude
FileExtensions=.tmp,.part,.crdownload,.download

[Folder:素材]
; 只显示图片文件
DisplayScope=RecursiveFiles
MaxFilesPerFolder=20
FilterMode=Include
FileExtensions=.png,.jpg,.jpeg,.webp,.gif

[Folder:项目]
; 未配置独立节，完全继承共享设置（All）
```

### 注意事项

- 筛选只作用于对应文件夹的扫描结果，不影响固定项和 Windows 最近打开侧边栏。
- 筛选发生在文件枚举时，但**不能避免对目录的完整枚举**，因此不能将其作为解决超大目录扫描速度的主要手段。
- 如果配置了 Include/Exclude 但没有文件命中，分组标题会显示「没有符合筛选条件的文件」，以区别于目录本身为空的情况。
- 如果配置的目录不存在，面板会显示「目录不可用」，不会报错退出。

---

## 快捷启动文件夹（Launcher 模式，v0.5+）

从 v0.5 开始，PopDrop 支持 `Mode=Launcher` 模式，将普通文件夹变成快捷启动面板。这是一个完全不同于 `Files` 模式的工作方式：不再按修改时间排序的文件列表，而是按你指定的顺序排列的启动器。

### 工作方式

`Launcher` 模式的核心思路是：**把文件夹当作程序分类，把文件当作菜单项**。

- 每个 `[Folders]` 中的分组成为分类标题
- 分组内的快捷方式（.lnk、.url、.exe）按文件名排序后显示
- 文件名中的数字前缀控制排序、不参与显示
- 双击或回车直接启动程序，拖拽发送文件路径

### 默认行为

当 `Mode=Launcher` 且未显式配置对应选项时，使用以下默认值：

| 配置项 | Launcher 默认值 | 说明 |
|---|---|---|
| `IncludeSubfolders` | `0` | 不递归子目录 |
| `DisplayScope` | `FilesOnly` | 仅显示当前文件夹中的文件 |
| `SortMode` | `NameAsc` | 按文件名自然升序 |
| `FilterMode` | `Include` | 只显示扩展名列表中的文件 |
| `FileExtensions` | `.lnk,.url,.exe` | 只显示快捷方式和可执行文件 |
| `StripOrderPrefix` | `1` | 隐藏数字排序前缀 |
| `HideExtensions` | `1` | 隐藏文件扩展名 |

用户显式配置的选项会覆盖这些默认值。在“PopDrop 设置 → 文件来源”中将“文件夹类型”
改为“启动器文件夹（Launcher）”时，界面会立即把这些推荐值写入当前草稿；只有点击
“保存”后才会写入 `config.ini`。切回“普通文件夹（Files）”时，界面会恢复按修改时间
排序、显示数字前缀和扩展名，并恢复共享默认的显示范围及文件类型过滤，避免残留
Launcher 的 `.lnk/.url/.exe` 限制。

### 数字前缀排序

文件名中的数字前缀用于自定义排序，界面不显示数字和扩展名：

```text
010 Chrome.lnk     → Chrome
020 Firefox.lnk    → Firefox
030 7-Zip.lnk      → 7-Zip
040 Everything Search.url  → Everything Search
```

排序始终使用原始文件名，前缀只影响显示。规则：只移除 `^\d+[ \t]+` 模式（数字开头，后面至少一个空格或制表符）。

```text
7-Zip.lnk          → 7-Zip          （无前缀，保留原名）
3D Viewer.lnk      → 3D Viewer      （3D 不是前缀，保留原名）
```

### 配置方式

推荐在“PopDrop 设置 → 文件来源”中选择来源，然后通过“文件夹类型”下拉框切换
“普通文件夹（Files）”或“启动器文件夹（Launcher）”。也可以按下面方式高级编辑：

在 `[Folders]` 中定义分组，然后在对应的 `[Folder:名称]` 节中设置 `Mode=Launcher`：

```ini
[Folders]
工具=D:\Launcher\工具
网络=D:\Launcher\网络

[Folder:工具]
Mode=Launcher

[Folder:网络]
Mode=Launcher
FileExtensions=.lnk,.url,.exe
```

支持的文件夹级配置项（全部可选，不配置时使用 Launcher 默认值）：

| 配置项 | 作用 |
|---|---|
| `Mode=Launcher` | 启用 Launcher 模式 |
| `IncludeSubfolders` | 是否递归子目录（默认 `0`） |
| `MaxFilesPerFolder` | 最大显示数量（默认 `All`，不限制） |
| `SortMode` | `NameAsc`（默认）或 `ModifiedDesc` |
| `FilterMode` | `Include`（默认）或 `Exclude`、`All` |
| `FileExtensions` | 筛选的扩展名列表（默认 `.lnk,.url,.exe`） |
| `StripOrderPrefix` | 隐藏数字前缀（默认 `1`） |
| `HideExtensions` | 隐藏扩展名（默认 `1`） |

## 窗口模式（v0.4+）

PopDrop 支持三种窗口模式，通过 `[General]` 中的 `WindowMode` 配置。默认模式为 `temporary`，适合随手使用、用完即走的工作流。

```ini
WindowMode=temporary
```

### 工作方式

窗口模式决定了面板的显示行为，核心区别在于「按快捷键后面板如何出现」和「离开面板后面板如何消失」：

| 模式 | 说明 |
|---|---|
| `temporary` | **默认值**。面板置顶，但当您切换到其他窗口、点击桌面或 Alt+Tab 后，面板自动隐藏。软件自身的消息框、文件选择对话框、右键菜单和拖放操作不会触发自动隐藏。 |
| `always_on_top` | 始终置顶，面板保持在其他窗口上方，直到手动按快捷键关闭。 |
| `normal` | 普通窗口。不置顶，按照普通 Windows 窗口方式显示。被其他窗口覆盖时按快捷键先恢复面板，再按一次才隐藏。 |

### 默认行为（temporary）的典型流程

> 按 `F2` → 面板出现 → 找到文件拖到目标软件 → 切换到目标软件（面板自动隐藏）→ 继续工作

**自动隐藏的保护机制**：面板弹出消息框、文件选择对话框、右键菜单或进行拖放操作时，自动隐藏会被暂停。外部文件或文件夹拖入后，PopDrop 会保持打开并重新获得焦点，避免松开鼠标时被待执行的自动隐藏计时器关闭。

### 切换模式

顶部按钮可以实时切换两种常用模式，并立即保存到 `config.ini`：

- 「置顶：开」对应 `always_on_top`，失去焦点后仍保持显示。
- 「置顶：关」对应 `temporary`，失去焦点后自动隐藏。

也可以直接编辑 `config.ini` 中的 `WindowMode`。`normal` 模式仍可通过配置启用；在 `normal` 模式下点击置顶按钮，会切换到 `always_on_top`。

### 为什么要用 temporary 模式？

PopDrop 的设计初衷是「按一下出现，用完就走」。`temporary` 模式让这个流程变得更自然——你不需要手动按快捷键关闭面板，切换到其他窗口时面板自动消失，下次按快捷键又会出现。这比 `always_on_top` 少了一个操作步骤，也比 `normal` 模式更符合「用完即走」的心理模型。

---

## 刷新与缓存

v1.1.0 使用 `cache\index.db` 保存每个工作区的事务快照。留空 `CachePath` 时优先放在
软件目录；不可写或不是本地磁盘时自动回退到 `%LOCALAPPDATA%\PopDrop\cache`。旧的
`scan-cache-v4.ini` 只在升级时作为一次性种子，SQLite 不可用时仍可作为安全回退。
缓存只保存路径、名称、时间和呈现状态，不保存用户文件内容；删除缓存不会删除用户文件。

重复呼出同一工作区且视图未变化时，PopDrop 不清空 ListView、不重建 ImageList，也不
再次全量扫描。本地来源由异步 `ReadDirectoryChangesW` 监听，50～120 ms 内的连续事件
合并后只重扫受影响来源。首次无缓存或手动刷新时，各来源按本地优先、配置顺序串行扫描；
一个来源完成后立即以完整分组提交，其他来源继续扫描。这样机械盘仍保持单路顺序 I/O，
但首个分组不再等待整个工作区完成。

Windows Recent 是独立结果流。关闭“近期栏”时不扫描、不解析 Recent；启用时监听 Recent
目录。UNC、WebDAV 和映射网络目标不会在刷新关键路径执行同步存在性检查，因此失效快捷
方式不会拖住来源呈现。

进程启动、跨日首次呼出、睡眠恢复、监听溢出/句柄错误、来源配置变化和手动刷新会安排
后台校准。监听失败只使对应来源失效并重建句柄，不清空其他来源的缓存结果。

---

## 按来源投放本地文件（第一期）

拖动文件进入 PopDrop 时，鼠标经过的目标会被实时解析。有效来源分组会高亮，状态栏会
显示“复制/移动 N 个项目到「来源」”“添加到固定项”或“创建快捷方式”，系统拖拽光标
与最终动作保持一致。目标命中使用 ListView 的实时分组矩形，因此缩略图/列表视图、
滚动、窗口缩放和 DPI 变化都不需要固定坐标。

### 拖拽文件夹快速添加为来源

当一次拖拽中的对象全部是可访问的真实文件系统目录时，普通工具栏会在原位置临时切换
为两个投放区域：

- **＋ 添加为来源**：约占工具栏 70%，显示当前工作区名称。放下后按拖拽顺序追加为
  当前工作区的 `Files` 来源，不复制、不移动、不创建也不删除真实文件夹。
- **☆ 加入固定项**：约占工具栏 30%，只把文件夹路径加入当前工作区固定项。

这两个区域不会改变主列表位置。下方 Files、Launcher 和固定项分组仍可命中，因此也
可以继续把文件夹拖到 Files 来源进行复制或移动，或拖到 Launcher 创建快捷方式。
`Ctrl`、`Shift` 不改变“添加为来源”和“加入固定项”的非破坏性语义；“添加为来源”
只向 OLE 来源返回 `COPY` 或 `NONE`，绝不返回 `MOVE`。

普通文件不会显示新操作区。文件与文件夹混合选择也不会显示，且不会只取出其中的
文件夹；仍可按原规则拖到 Files、Launcher 或固定项。虚拟文件、URL、网页图片、特殊
Shell 对象和无法在拖动阶段可靠判断的对象保持 `Unknown`，继续走外部内容接收链路。

放到“添加为来源”后，PopDrop 会在写配置前再次逐项确认路径仍存在且仍是可持久保存的
文件系统目录：

- 来源名称默认取文件夹名，当前工作区同名时使用 `名称 (2)` 等唯一名称。
- 当前工作区已存在的相同规范路径会跳过；其他工作区使用相同路径不受影响。
- 有效候选一次性追加到当前工作区 `SourceOrder`；无效候选计入失败详情。
- 整批配置使用现有原子事务，保留注释、未知键、UTF-16LE、CRLF 和六个布局锚点；
  保存失败不会留下部分来源。
- 成功后只触发一次后台扫描，不在拖放回调中同步枚举新目录。

### 在主面板管理来源

在 Files 或 Launcher 来源的分组标题上右键，会显示独立的来源管理菜单：

- **打开来源文件夹**：在当前设置的文件管理器中打开来源；目录离线或不存在时禁用。
- **刷新此来源**：通过现有后台扫描 worker 请求刷新。当前扫描协议以工作区为单位，
  因而内部会安全刷新当前工作区，并继续校验 generation、配置 fingerprint 和
  WorkspaceId。
- **设置此来源…**：复用现有“PopDrop 设置”窗口，通过 WorkspaceId 和 SourceId
  切到“工作区设置 → 当前工作区”，选中正确工作区和来源并滚动到可见位置。
- **从当前工作区移除…**：删除当前工作区对该 SourceId 的引用和来源专属配置；
  不访问或修改真实文件夹。

来源标题菜单与文件项目菜单相互独立：右键具体文件仍使用现有 PopDrop/Windows 菜单，
`Shift` 反转规则不变；左键来源标题仍打开来源文件夹。固定项标题和空工作区占位不会
显示来源管理菜单，离线来源仍可进入设置或执行安全移除。

如果设置窗口有未保存修改，精确跳转和移除都会先提供“保存并继续、放弃并继续、取消”
三条路径。取消不会改变原页面、工作区、来源选择或配置。设置窗口已经打开时只恢复并
置前现有窗口，不会创建第二个。

移除来源前会显示以“取消”为默认按钮的确认窗口，并再次按 SourceId 检查活动外部传输。
正在接收内容时不会取消传输，而是阻止移除。确认后，PopDrop 在临时配置上更新
`SourceOrder`，删除 `[Source:<SourceId>]`、`[SourceIgnore:<SourceId>]`、
`[SourceExclude:<SourceId>]`、`[SourceAllow:<SourceId>]` 及其他明确以该 SourceId
归属的扩展节，验证所有工作区后原子替换配置。固定项、Windows 最近记录、复制/移动
常用目标和旧版兼容快照均不会改变。

移除最后一个来源后，主面板会提示：

> 当前工作区还没有来源。
>
> 将文件夹拖到顶部“添加为来源”，或前往设置添加。

### 默认动作与修饰键

| 拖拽来源 | 投放目标 | 默认动作 |
|---|---|---|
| 全部为可验证真实文件夹 | 顶部「＋ 添加为来源」 | 追加为当前工作区 Files 来源；不操作真实文件夹 |
| PopDrop 普通 Files 来源项目 | 另一个 Files 来源 | 移动真实文件 |
| Windows 资源管理器本地项目 | Files 来源 | 复制真实文件 |
| PopDrop 固定项或最近文件 | Files 来源 | 复制真实文件 |
| 包含固定项、最近文件或来源不确定项的混合选择 | Files 来源 | 复制真实文件 |
| 任意有效本地文件或文件夹 | 固定项分组或「＋ 固定项」按钮 | 只加入固定项 |
| 任意有效本地文件或文件夹 | Launcher 来源 | 创建快捷方式；已有 `.lnk/.url` 只复制 |

- 按住 `Ctrl` 请求复制。
- 按住 `Shift` 请求移动。
- 如果来源数据不允许请求的效果，移动请求可以安全回退为复制；复制请求不会回退成
  可能删除源项目的移动。
- 固定项和 Launcher 的安全语义不受 `Ctrl`/`Shift` 改变。它们绝不会因为修饰键而
  移动原文件。

### Files 来源

投放到 Files 来源继续使用 Windows `IFileOperation`。多选、文件和文件夹混合、多个
源目录、跨磁盘、网络目录、重名、文件夹合并、权限提升、取消和部分成功都由 Shell
处理。移动固定项对应的真实文件时，PopDrop 根据 Shell 返回的实际新名称更新固定路径。
整批操作只触发一次后台刷新。

下列项目会安全跳过，并在结果中计数：

- 项目已经属于目标来源；这也包括名称不同但规范化后指向同一真实路径的两个来源。
- 移动项目的父目录就是目标目录。
- 文件夹将被投放到自身或后代目录。
- 路径失效、无法由 Shell 解析或当前不可访问。

同一多选中可以只有部分项目被跳过，其余有效项目仍会执行。拖到来源内的某个文件图块
仍表示投放到该来源根目录，不会覆盖或替换图块对应文件。

完成后状态栏显示实际成功、失败/跳过及取消数量和目标来源。状态文字可点击打开目标
文件夹；有失败时先显示详情，并可继续打开目标。如果项目已经保存，但可能因扩展名
过滤、噪音规则、显示范围或最大显示数量不出现在分组中，会明确提示：
“文件已保存到目标文件夹；部分项目因当前显示或筛选规则未显示。”

### Launcher 来源

Launcher 不是普通收纳目录：

- 普通文件、文件夹和 `.exe` 会在 Launcher 目录创建指向原项目的 `.lnk`。
- 本地 `.lnk` 和 `.url` 使用 Shell 复制，原文件不会移动。
- 快捷方式名来自可读原名；非法字符、Windows 保留名称和尾部点/空格会被清理。
- 重名时自动使用 `名称 (2).lnk` 等唯一名称，不静默覆盖。
- 快捷方式先写到同目录临时名称、验证目标后再无覆盖重命名；失败会清理临时文件。

### 固定项与无效区域

拖到固定项分组或顶部「＋ 固定项」按钮只记录路径，不复制、不移动、不删除真实文件。
没有任何固定项时，拖拽期间按钮仍会突出显示为可发现的投放目标。重复路径继续跳过，
新加入的一批保持原顺序并置于最前。

最近文件侧栏、状态栏、普通工具按钮以及不能映射到目录的主列表空白区域均不可投放，
系统光标显示禁止并在状态栏说明原因。不存在、离线、无法解析或写入权限检查失败的来源
同样不可投放；执行前还会再次验证。

### 支持范围与权限

第一期本地链路仍只处理 `CF_HDROP`，并保持最高优先级。v0.8 在它之外增加独立的
虚拟文件、标准图片和受限公开 URL 适配器；详细边界见下一节。HTML 文本和普通
Unicode 文本仍不会被误当作文件或 URL。

Windows UIPI 会阻止不同管理员权限级别进程之间的拖放。例如资源管理器为普通权限、
PopDrop 以管理员身份运行时，资源管理器可能根本无法把数据送入面板。请让来源程序和
PopDrop 使用相同权限级别；PopDrop 不绕过这项系统安全限制。

temporary 模式在拖拽进入、OLE 循环、Shell 冲突/权限窗口和投放执行期间暂停自动隐藏。
成功、失败、取消或离开目标后都会成对恢复；成功投放后面板保持可见并恢复焦点。

---

## 外部内容投放（v0.8）

### 支持格式与优先级

PopDrop 对同一个 Windows `IDataObject` 只选择一条链路：

1. `CF_HDROP` 本地路径；
2. `FileGroupDescriptorW + FileContents` 虚拟文件；
3. 注册的 `PNG`、`CF_DIBV5`、`CF_DIB`；
4. `UniformResourceLocatorW`、`UniformResourceLocator` 或
   `text/uri-list` 中的公开 URL；
5. 都不存在时拒绝。

因此浏览器或聊天软件同时提供文件和 URL 时，文件始终优先；虚拟 JPEG/GIF/WebP
也会保留原始文件流，不会错误转换成 PNG。普通 `CF_UNICODETEXT` 不会被当成 URL。
拖动鼠标期间默认只检测格式和目标，不读取大文件、不访问网络；唯一例外是为了显示
“添加为来源”反馈，对同步、纯 `CF_HDROP`、且没有 URL、虚拟文件或图片格式信号的
稳定本地对象读取一次路径列表。路径缓存在当前拖拽 Session 中，`Drop` 不会再次调用
`GetData(CF_HDROP)`。任何安全条件不足的对象都保持 `Unknown`，松开后才进入原有链路。

当前 Chrome、Edge、Firefox、网盘网页和聊天软件是否可用，取决于它们是否向 Windows
提供上述标准格式。页面内部排序、私有格式、网盘目录树、空目录、需要浏览器 Cookie
或特殊请求头的内容不承诺支持。

### 本地路径和 QQ/微信

资源管理器以及当前 QQ、微信提供的稳定 `CF_HDROP` 继续使用第一期 `IFileOperation`，
包括复制/移动、Shell 冲突、权限、取消、部分成功和一次刷新。外部默认复制，
PopDrop 普通 Files 来源之间默认移动。

任何外部来源只要为 `CF_HDROP` 声明异步能力，PopDrop 就不会先读取路径，而是在
`Drop` 内完成有界 COM 接管，由 helper 执行唯一一次 `GetData(CF_HDROP)` 并分块
复制。这里不依赖来源是否同时提供明确 URL，因为部分浏览器链接图片不会通过标准 URL
格式查询暴露该信息。这避免 Chromium 把主程序和 helper 的两次数据读取分别解释为
两次延迟下载。helper 缺失时会在 marshaling 和读取 HDROP 前失败，不会在传输中心
之外留下另一份文件。同一次拖放只由一个接收器处理，旧 `DropFiles` 仍未启用。

外部同步 HDROP 也不是一律预读：只有适配器为 HDROP、未声明
`IDataObjectAsyncCapability`，且格式探测没有发现明确 URL、虚拟文件描述符/流、
PNG 或 DIB 图片时才允许预读。预读无论成功、返回空值还是抛出异常，本 Session 都不会
第二次读取同一数据对象。资源管理器、Directory Opus 等稳定本地来源可因此获得文件夹
操作区；QQ、微信或浏览器若提供了上述不确定信号，则保持原有 Drop 后处理。

浏览器也可能把 HDROP 文件直接生成在自己的下载目录。如果这个目录正好就是投放目标，
PopDrop 会等待浏览器完成写入并直接认领该文件，不再把它复制回相同目录，因此不会
生成 `image (2).jpg`。目录判断使用文件系统标识，可处理大小写和 junction 别名。
这项认领只用于外部拖放；用户在精简菜单中主动选择“复制到当前目录”时，仍保留 Shell
正常创建副本的行为。

网页中的图片被链接包裹时，浏览器可能同时提供缩略图、原图或链接派生项。异步 HDROP
图片会等待候选写入完成，再读取真实像素宽高：优先保留像素面积较大的版本，像素相同
时再保留文件字节数较大的版本。`image.jpg` 与浏览器/Shell 生成的
`image (1).jpg` 也会视为同批候选。若浏览器把一张小图直接写入目标目录、另把大图放在
缓存中，PopDrop 会用大图安全替换本批小图，最终只保留一份；较早存在的同名文件不参与
替换。虚拟文件仍会在请求第二个重复 `FILECONTENTS` 流之前按描述符大小选择，不会先
下载两份再删除。资源管理器、QQ、微信的稳定本地文件链路不使用网页图片去重。

部分浏览器会在 PopDrop 已保存图片、异步拖放结束通知发出后，再自行生成一个同名或
带数字后缀的文件。helper 会在后台继续进行五秒有界收敛：晚到的小图或等大副本会被
移除，晚到的大图会替换此前版本。此阶段传输中心可能短暂显示“正在完成”，但不阻塞
主面板，也不会占用其他传输的并发名额。该收敛独立于实际适配器，对 HDROP、虚拟
文件、PNG/DIB 和公开 URL 最终保存的图片统一生效。

源码运行时会优先使用 `native\bin\x64` 或 `native\bin\x86` 中与 AutoHotkey 位数
匹配的 helper。PopDrop 会在接管握手中核对 helper 版本；如果脚本目录残留旧 EXE 或
忘记重新构建，会明确提示版本不匹配，不会继续执行旧逻辑。

### 虚拟文件与图片

虚拟文件支持单个和多个 `FILEDESCRIPTORW`、Unicode 名称、已知/未知大小、空文件、
`TYMED_ISTREAM` 和 `TYMED_HGLOBAL`。每个项目独立完成或失败；恶意相对/绝对路径会被
收敛为安全文件名，保留名、尾部点/空格和超长名称会清理。虚拟目录会提示：

> 当前来源提供的是虚拟文件夹，PopDrop 本期只支持拖入文件。

`TYMED_ISTORAGE` 当前明确不支持，不会伪装成成功。没有更高优先级文件格式时，
PNG 原样保存；DIB/DIBV5 通过 Windows Imaging Component 编码为 PNG。不会截图屏幕。

### 公开 URL

默认允许公开 HTTPS 文件 URL，HTTP 默认关闭。拒绝 `file:`、`javascript:`、`blob:`、
`data:`、UNC、带用户名/密码的 URL。使用系统代理和正常 TLS 证书验证，不自动发送
Windows 凭据，不读取浏览器 Cookie 或密码。

支持最多 10 次自动重定向、`Content-Disposition`、RFC 5987 UTF-8 文件名、未知
`Content-Length`、分块传输、超时、断流和用户取消。全局最多 3 个后台任务，同一主机
最多 2 个。公开 URL 失败项可在传输中心重试；完整 URL 只以当前用户 DPAPI 加密形式
短暂保存，不进入普通日志。

返回未声明附件的 HTML 时提示：

> 该拖拽只提供了网页地址，服务器没有返回可下载文件。

疑似登录态来源还会提示：

> 来源网站没有通过系统拖放提供文件内容，PopDrop也无法继承浏览器登录状态。请先在浏览器中完成下载。

### 后台任务与界面

松开鼠标并成功接管后，temporary 自动隐藏暂停立即恢复；下载本身不持有暂停计数。
隐藏或关闭主面板不会取消任务，再次打开会恢复最新进度。

主面板底栏固定为 42 逻辑像素高。左侧文件路径和操作反馈最多显示两行、在该区域内
垂直居中，第三行截断；右侧“↓ 下载”与左侧区域顶部对齐。任务持续超过
约 300 ms 后才切换为整体任务数/进度，并至少保留约 800 ms；完成提示显示约 3 秒后
恢复，未查看的失败保持提示。来源标题显示该目标的接收项数或真实百分比。
未知总长度只显示已收字节和速度，不显示虚假百分比。点击下载入口打开非模态传输中心，
可按批次查看文件名、来源、目标、进度、速度和状态，取消单项/整批、重试公开 URL、
打开目标文件夹或清除记录。完成项显示 100% 和全程平均传输速度，轮询更新不会清除
当前选择。不会为每个下载创建占位图块。

任务排队时取消不会创建临时文件。退出 PopDrop 时如果仍有活动任务，会要求返回或
取消任务并退出；当前版本不提供“退出界面但继续传输”的虚假选项。

### 临时文件、重名和安全

所有 helper 写入都先使用目标目录中的隐藏 `.popdrop-part`。成功时刷新文件缓冲、
重新确认唯一名称后用同卷原子改名；`image.png` 重名会成为 `image (2).png`，
不会静默覆盖。失败和取消会删除半成品。`.popdrop-part` 无论普通“未完成下载过滤”
是否开启，都不会进入面板。

公开 URL 以及带明确网络 URL 的虚拟文件会通过 Windows
`IAttachmentExecute` 添加网络来源信息；异步 HDROP 会尽量复制已有
`Zone.Identifier`。PopDrop 不自动打开 EXE、MSI、脚本、快捷方式或宏文档，也不执行
杀毒命令行。安全标记失败时文件保留，但任务进入“需要处理”并明确显示原因。

### 设置

“PopDrop 设置 → 常规 → 下载”提供：

- 是否启用公开 HTTPS URL 兜底；
- 是否允许 HTTP（默认关闭）；
- 后台最大并发 1～6（默认 3）；
- 面板隐藏时是否显示批次完成通知。

手工配置对应：

```ini
[ExternalTransfer]
EnablePublicUrlFallback=1
AllowHttp=0
MaxConcurrent=3
ShowCompletionNotifications=1
```

配置仍使用 UTF-16LE、单 BOM、CRLF；设置界面通过布局感知文档写入，只修改相关键，
保留注释、未知项和六个区域锚点。

### 诊断

使用 `PopDrop.ahk --inspect-drop` 启动可在系统临时目录生成本次会话的格式诊断日志，
记录格式名称、数值 ID、`TYMED`、`lIndex`、异步能力和最终适配器。不会记录聊天文本、
图片内容或完整 URL。该开关不改变正常分类和接收行为。

---

## 固定项

点击「＋ 固定项」可以选择一个或多个文件。也可以从资源管理器把文件、文件夹拖到
固定项分组或「＋ 固定项」按钮；文件夹会作为单独的固定项加入，不会展开或添加其中
的内容。拖到 Files/Launcher 来源时则按上一节的来源投放规则执行。

文件工作区中的固定文件和固定文件夹均在项目右下角显示链接图标，表示这里是原项目的
快捷入口。文本块工作区只有指向来源文件的固定卡片显示该图标；PopDrop 管理的独立文本
块不显示。图标不改变文件类型，也不会在磁盘上额外创建 `.lnk`。

每个工作区拥有独立固定列表，保存在
`[WorkspacePinned:<WorkspaceId>]`。切换工作区会立即切换固定项；同一路径可以在多个
工作区分别固定、排序或移除。旧版 `[PinnedFiles]` 会安全迁移到升级时的当前工作区。
选择固定项后点击「－ 固定项」，只移除当前工作区的面板记录，不会影响原文件、文件夹
或其他工作区。双击固定文件夹会在当前设置的文件管理器中打开。

- 新加入的一批固定项会显示在最前面，并保持这批项目拖入时的原始顺序。
- 拖动单个固定项到另一个固定项上，可以调整前后顺序；顺序会立即保存。
- 将固定项拖出主列表时，会继续使用原有的 Windows 文件拖放。
- 多选拖拽仍然用于向其他软件发送项目，不执行内部排序。

- 重复路径会自动跳过。
- 文件和文件夹可以同时拖入。
- 使用 PopDrop 菜单重命名或移动项目时会同步固定路径；如果项目在外部被移动、
  重命名或删除，旧固定路径仍会显示为「项目不存在」。
- 如果 PopDrop 与来源程序使用不同的管理员权限级别，Windows 可能阻止拖放。

## 最近打开侧边栏

侧边栏读取 Windows 维护的「最近文件」记录（`%APPDATA%\Microsoft\Windows\Recent`），只展示仍然存在的文件。双击、拖拽、右键菜单都作用于原文件。

如果 Windows 隐私设置里关闭了「显示最近打开的项目」，或者系统没有留下记录，侧边栏会显示为空——这不是 PopDrop 的问题，是系统没有给它数据。

## 小技巧

- 多选后点击「－ 固定项」，会批量将所有选中项目移出固定项，不会删除源文件。
- 多选后拖拽任意一个已选文件，所有选中文件一起发送——支持跨文件夹、跨磁盘。
- 某些以管理员权限运行的软件，不会接受普通权限程序的拖放。这是 Windows 的安全机制。如果遇到这种情况，让 PopDrop 和目标软件使用相同权限级别即可。
- 右键打开默认菜单；按住 Shift 右键或按 `Shift + F10` 打开另一个菜单。
- 网络盘、离线盘、权限受限的目录会显示为不可用；恢复连接后点「刷新」即可回来。

## v0.7 文件操作与打开方式

### 精简右键菜单和快捷键

在“PopDrop 设置 → 共享设置 → 通用 → 右键菜单”中，可以把“PopDrop 快捷菜单
（推荐）”或“Windows 系统菜单”设为默认。右键和键盘菜单键打开默认菜单；按住 Shift
右键或按 `Shift + F10` 打开另一个菜单。设置保存后立即生效，所有工作区、主文件区、
固定项和最近文件区共用同一选择。

手工配置对应：

```ini
[General]
DefaultContextMenu=PopDrop
```

允许值为 `PopDrop` 和 `System`。旧配置缺少该项、配置为空或值未知时都回退为
`PopDrop`，因此普通右键行为与旧版本一致；未知非空值会显示配置警告。

右击当前多选中的项目会保留整个选择；右击未选中项目会先改为单选。PopDrop 快捷菜单
始终作用于全部有效选择。同一父文件夹的多选会整体交给 Windows 系统菜单；跨父文件夹
多选时，系统菜单只作用于当前右击或聚焦项目，并在状态栏提示这一限制。

当 PopDrop 快捷菜单是默认菜单时，菜单底部显示“更多系统操作… Shift + F10”；
当 Windows 系统菜单是默认菜单时，备用 PopDrop 菜单不再显示这个重复入口。

“重命名…”只在单选有效文件或子文件夹时可用。操作由 Windows Shell 执行，成功后
PopDrop 会刷新列表、恢复选择，并同步所有工作区中指向该项目及其后代的固定路径。
磁盘/共享根目录不能重命名；如果目标文件夹本身是已配置来源或包含已配置来源，
PopDrop 会拒绝操作，避免来源路径在配置中失效。输入文件新名称时应保留所需扩展名。

| 操作 | 快捷键 |
|---|---|
| 使用默认关联打开 | `Enter` |
| 移入回收站 | `Delete` |
| 在文件管理器中显示 | `Ctrl + Enter` |
| 复制文件对象到剪贴板 | `Ctrl + C` |
| 复制完整路径文本 | `Ctrl + Shift + C` |
| 打开另一个右键菜单 | 按住 `Shift` 右键或 `Shift + F10` |
| 打开默认右键菜单 | 右键或键盘菜单键 |

使用 Windows 系统行为时，同一文件所在文件夹中的多选会保留原有的整体定位与选择；
跨文件夹多选时菜单项禁用。Directory Opus 对单个项目执行精确定位，多选则按文件所在
文件夹去重后打开；Total Commander 的定位操作始终按文件所在文件夹去重后打开，不
尝试自动选中文件；XYplorer 和 Files 对单个项目执行精确定位，Double Commander 与
FreeCommander XE 对单个文件执行精确定位，多选均按文件所在文件夹去重后打开。
复制文件使用 `CF_HDROP`，可以直接粘贴到资源管理器或支持文件粘贴的软件；复制路径则
按当前显示顺序每行一条，不添加引号。“重命名”和“删除”位于“更多系统操作”上方，
分别使用 Windows Shell 重命名和回收站操作；PopDrop 不会在回收站不可用时改用永久
删除。

### 文件管理器

在“PopDrop 设置 → 共享设置 → 打开与文件操作”的“文件管理器”区域中，可以选择：

- **跟随 Windows 系统行为**：默认选项，保持旧版本的文件夹打开方式和 Windows Shell
  文件定位；也会继续尊重系统级的 Explorer Replacement 配置。
- **Directory Opus**：程序路径使用 `dopusrt.exe`。手动选择同目录中的 `dopus.exe`
  时，PopDrop 会尝试转换到 `dopusrt.exe`。单个项目可以打开文件所在文件夹并选中，
  多选按文件所在文件夹去重后打开。
- **Total Commander**：程序路径使用 `TOTALCMD64.EXE` 或 `TOTALCMD.EXE`，优先复用
  已运行实例并在当前源面板打开目录。受其公开命令行接口限制，PopDrop 暂不自动选中
  普通文件。
- **XYplorer**：程序路径使用 `XYplorer.exe`。打开文件夹时传入带末尾反斜杠的目录
  路径；定位单个文件或文件夹时传入完整项目路径，由 XYplorer 打开父目录并选中项目。
  多选时不注入脚本，而是按项目所在文件夹去重后打开。
- **Double Commander**：程序路径使用 `doublecmd.exe`。PopDrop 使用 `-C` 优先把
  请求交给已运行实例；传入完整文件路径时，Double Commander 打开父目录并把光标移到
  该文件。文件夹路径直接打开，多选按项目所在文件夹去重后打开。
- **Files**：程序路径使用 `Files.exe`，或 `files-stable.exe`、
  `files-preview.exe`、`files-dev.exe` 官方启动别名。PopDrop 使用 `-directory`
  打开文件夹，使用 `-select` 定位单个项目；多选按项目所在文件夹去重后打开。
- **FreeCommander XE**：程序路径使用 `FreeCommander.exe`。PopDrop 使用 `/C`
  优先把请求交给已运行实例；传入完整文件路径时，FreeCommander XE 打开父目录并把
  光标定位到该文件。文件夹路径直接打开，多选按项目所在文件夹去重后打开。

“自动查找”只检查常用安装位置与合理的系统注册信息，不扫描整个磁盘；Directory Opus
、Total Commander、XYplorer、Double Commander、FreeCommander XE 的便携版都可以
使用“浏览…”手动选择；Files 会检查 Windows 应用执行别名。两个测试按钮使用设置页中
尚未保存的选择和路径，取消设置不会写入这些临时修改。

手工配置对应：

```ini
[FileManager]
Provider=WindowsShell
Executable=
```

`Provider` 允许值为 `WindowsShell`、`DirectoryOpus`、`TotalCommander`、
`XYplorer`、`DoubleCommander`、`Files` 和 `FreeCommander`。配置版本 19 会为缺少
该节或键的旧配置补齐 `WindowsShell` 与空程序路径，已有选择和路径保持不变；第三方
程序路径仅在执行相关操作或点击测试按钮时检查，不会在程序启动时弹窗。

One Commander 未出现在选择列表中：截至本版本调研时，其公开命令行接口只承诺打开
路径、面板或标签，没有稳定的指定项目选择参数。PopDrop 不会用键盘、鼠标模拟或未公开
窗口消息补足该能力。

### 应用与工具操作

PopDrop 把“打开方式”和“工具动作”作为两个不同概念：

- 打开方式表示“用某个程序打开当前文件”，只对单个普通文件显示。
- 工具动作表示由应用执行的文件操作，可用于文件、文件夹、混合选择或多选。

在“PopDrop 设置 → 共享设置 → 打开与文件操作”的“应用与工具操作”区域中，可以添加
或编辑应用，并通过“管理动作…”打开独立动作窗口。应用列表的“打开方式”列显示所有
文件、指定扩展名或“不显示”；“动作”列显示动作数量。关闭“显示在‘打开方式’菜单中”
后，应用仍可作为纯工具应用提供动作；禁用整个应用会同时隐藏它的打开方式和全部动作。
同一个主程序路径只能保存一条应用记录，不能通过重复 EXE 模拟多个动作。

动作管理窗口支持添加、编辑、复制、移除和排序。“复制动作”会生成新的稳定动作 ID；
应用或动作改名、改路径和排序都不会改变已有 ID。应用和动作只先修改设置草稿，只有
主设置窗口的“保存”会原子写入配置；取消不会改变运行时或磁盘。

动作不再要求单独设置“仅单个/单个或多个”，而是选择执行模式：

- **逐个项目串行执行**：为当前选择生成多个独立命令，在后台等待前一个外部进程退出后
  再启动下一项。等待过程不阻塞 PopDrop 界面。
- **一次传入全部项目**：只启动一个外部进程，并把 `{items}` 展开为当前选择中的多个
  独立路径参数，适合把多个文件压缩到同一个归档。

#### 参数与变量

参数模板使用多行文本框，**每行表示一个参数**。空格、中文、`&`、括号等字符不会造成
参数拆分。支持以下变量：

| 变量 | 含义 |
|---|---|
| `{item}` | 逐个模式中为当前处理项目；全部传入模式中为右击或键盘聚焦项目 |
| `{items}` | 生成菜单时的全部选择，按当前显示顺序展开为多个独立参数 |
| `{folder}` | 标量项目所在的文件夹，例如 `D:\Images` |
| `{parent}` | `{folder}` 的上一级目录，例如 `D:\` |
| `{name}` | 标量项目的完整文件名，例如 `旅行视频.mov` |
| `{stem}` | 标量项目去掉最后一个扩展名后的文件名，例如 `旅行视频` |
| `{ext}` | 标量项目最后一个扩展名，不包含开头的 `.`；无扩展名时为空 |
| `{date}` | 动作开始时的日期，格式为 `yyyyMMdd` |
| `{time}` | 动作开始时的时间，格式为 `HHmmss` |
| `{index}` | 逐个模式中为当前序号；全部传入模式中为右击项目在选择中的序号 |
| `{count}` | 本次选择的项目总数 |
| `{size}` | 文件大小的可读值，例如 `15KB`、`2.4MB`；文件夹为空 |

逐个模式中的标量变量随当前处理项目变化；全部传入模式中的标量变量稳定指向右击或
键盘聚焦项目。日期和时间在一次动作开始时获取，逐个队列中的全部命令共用同一时间戳。
项目本身为文件夹时，`{folder}` 仍表示该项目所在的目录，而不是项目自身；`{size}`
不会递归统计目录内容。大小单位按 1024 进位。

`{items}` 只允许用于“一次传入全部项目”，且必须单独占一行，不能写成
`--files={items}`。其他标量变量可以嵌入同一个参数，例如
`-o{folder}\{stem}-{date}`；替换完成后，这一整行仍作为一个参数。未知变量、不完整
大括号、自定义工作目录为空或覆盖程序不是现有 `.exe` 时，设置窗口会阻止保存。

工作目录可选择所选项目所在文件夹、程序所在文件夹或自定义目录。自定义目录支持环境
变量和上述标量变量，但不支持 `{items}`。逐个模式会分别计算每一项的 `{folder}` 与
`{parent}`。全部传入模式使用 `{folder}` 或“所选项目所在文件夹”时，全部选择必须
具有相同 `{folder}`；使用 `{parent}` 时则必须具有相同 `{parent}`。启用“所选项目
必须位于同一文件夹”会额外要求整个选择具有相同 `{folder}`。

动作扩展名不区分大小写，会自动补全 `.`、去重，并支持 `<none>`。与旧打开方式只比较
最后扩展名不同，工具动作按完整文件名做最长后缀匹配，因此 `.tar.gz` 可以作为独立
类型。扩展名条件必须对全部选中文件成立；文件夹不参与扩展名检查，但仍需满足动作的
适用对象条件。

#### 7-Zip 示例

以下动作使用 `7zFM.exe` 作为应用主程序用于“打开方式”，并用 `7z.exe` 覆盖工具动作
的执行程序。参数中没有自动加入 `-y` 或其他覆盖确认选项：

```ini
[OpenApps]
Order=7z

[OpenApp:7z]
Path=C:\Program Files\7-Zip\7zFM.exe
Name=7-Zip
Icon=C:\Program Files\7-Zip\7zFM.exe
Extensions=.zip,.7z
Enabled=1
ShowInOpenMenu=1
ActionOrder=extract-folder

[OpenAppAction:7z:extract-folder]
Name=解压到同名文件夹
Executable=C:\Program Files\7-Zip\7z.exe
TargetTypes=Files
ExecutionMode=PerItem
Extensions=.zip,.7z,.rar,.tar.gz
RequireCommonFolder=1
WorkingDirectoryMode=Folder
WorkingDirectory=
Confirm=0
Enabled=1
ArgCount=3
Arg001=x
Arg002={item}
Arg003=-o{folder}\{stem}
```

同一应用还可以增加一个批量压缩动作：

```ini
[OpenAppAction:7z:compress-7z]
Name=压缩为 7z
Executable=C:\Program Files\7-Zip\7z.exe
TargetTypes=Both
ExecutionMode=Batch
Extensions=
RequireCommonFolder=1
WorkingDirectoryMode=Folder
WorkingDirectory=
Confirm=1
Enabled=1
ArgCount=3
Arg001=a
Arg002={folder}\archive-{date}_{time}.7z
Arg003={items}
```

该动作只启动一次 7-Zip，并把全部选择作为独立参数传入。它没有自动加入 `-y`；归档
名称使用动作开始时的时间戳，避免多个手动任务默认使用同一文件名。

`Executable` 留空时继承应用主程序。`TargetTypes` 可为 `Files`、`Folders`、`Both`；
`ExecutionMode` 可为 `PerItem`、`Batch`；`WorkingDirectoryMode` 可为 `Folder`、
`ProgramDirectory`、`Custom`。`ActionOrder` 是应用内动作的唯一排序来源。

#### 右键菜单和执行安全

打开应用仍按当前选择实际适用的前 5 个直接显示，其余进入“更多已配置应用…”；菜单
文案为“用 {应用名} 打开”。工具动作按 `[OpenApps] Order` 的应用顺序和各应用的
`ActionOrder` 排序，过滤禁用、无效、不适用或程序不存在的动作后，前 5 个直接显示，
其余进入“更多工具操作…”。重名动作会追加应用名称。

工具动作的回调固定保存生成菜单时的完整选择副本和当前右击项目，执行前再次验证文件、
文件夹、扩展名、共同文件夹与 EXE。EXE 路径、逐项转义后的参数和工作目录分别
传给 `ShellExecuteExW`，不经过 `cmd.exe`、PowerShell、批处理、脚本或 Shell 管道。
最终命令行超过 Windows 安全长度限制时不会启动。

全部传入模式的“已启动”只表示 Windows 接受了启动请求。逐个模式会等待当前启动的
进程退出再处理下一项，但只能观察进程是否退出，无法判断工具是否实际处理成功；部分
启动器还可能创建子进程后立即退出。因此任何状态提示都不代表压缩、解压或转换已经完成。
需要确认的动作会先显示动作、应用、选择数量、是否包含文件夹和执行模式。

旧动作配置继续兼容：`SelectionMode=Single` 迁移为 `ExecutionMode=PerItem`，
`SelectionMode=Any` 迁移为 `ExecutionMode=Batch`；`RequireCommonParent` 迁移为
`RequireCommonFolder`，旧的 `WorkingDirectoryMode=Parent` 迁移为 `Folder`。
由于旧 `{parent}` 实际表示项目所在文件夹，迁移时会改写为 `{folder}`，保持原动作
输出位置不变。只有成功完成原子保存后，旧键才会被替换；注释、未知键和布局锚点保留。

#### 打开方式与旧配置兼容

“选择其他程序…”只允许选择 `.exe`。Windows 接受启动请求后，PopDrop 才会保存程序，
并自动合并当前文件的扩展名。路径按 Windows 大小写不敏感规则规范比较，同一程序不会
重复添加。没有扩展名使用 `<none>` 表示；空扩展名列表表示适用于所有普通文件。

配置使用一份容易手工编辑的 ID 顺序列表：

```ini
[OpenApps]
Order=typora,notepad-plus-plus

[OpenApp:typora]
Path=C:\Program Files\Typora\Typora.exe
Extensions=.md,.txt,<none>
```

`Order=` 是唯一排序来源；调整其中 ID 的先后顺序即可改变菜单顺序。ID 只需保持唯一，
建议使用 EXE 文件名并只包含字母、数字、`-`、`_`，例如 `7z`、`everedit`。
通过“选择其他程序…”添加时，PopDrop 会自动从 EXE 文件名生成 ID；重名时追加
`-2`、`-3`。

每个 ID 对应一个 `[OpenApp:<ID>]` 配置段。`Path` 必填；`Name`、`Icon`、`Enabled`
和 `ShowInOpenMenu` 均可省略，分别默认使用程序产品名、EXE 内置图标、启用状态和
显示打开方式。`Extensions` 留空或省略表示适用于所有普通文件。完整写法如下：

```ini
[OpenApps]
Order=7z,everedit

[OpenApp:7z]
Path=C:\Program Files\7-Zip\7zFM.exe
Name=7-Zip
Icon=C:\Program Files\7-Zip\7zFM.exe
Extensions=.7z,.zip
Enabled=1
ShowInOpenMenu=1

[OpenApp:everedit]
Path=D:\Tools\EverEdit\EverEdit.exe
Extensions=.txt,.md,.png
```

早期 v0.7 的 `App001=<UUID>` 与单项 `Order=1` 格式仍可读取。首次加载后，PopDrop
会通过原子写入迁移为新的 `Order=id1,id2,...` 格式；自动生成的 UUID 会转换为可读
ID。迁移失败时原配置不会被破坏，并会显示配置错误。

扩展名不区分大小写，可写 `pdf` 或 `.pdf`，保存时统一为带点小写形式。v0.7 按最后一个
扩展名匹配，不支持把 `.tar.gz` 当作一个打开类型。未填写扩展名的通用程序排在精确匹配
之后；顶层最多 5 个，其余放在“更多已配置应用…”中。程序移动或卸载后，点击该程序会
提供“重新选择”或“移除”。

配置版本 16 在应用动作中引入执行模式和明确的文件夹路径语义。旧配置缺少
`ShowInOpenMenu` 时默认为
`1`，缺少 `ActionOrder` 时视为没有动作；不会自动生成 7-Zip 或 WinRAR 动作，也不会
拆分旧应用。无动作时行为与升级前一致。保存动作时继续保留配置文件中的未知字段、
未知节、人工注释、UTF-16LE、CRLF 和六个布局锚点，并在完整校验后原子替换。

### 复制到、移动到和目标位置

复制和移动使用 Windows `IFileOperation`，支持文件、文件夹、混合选择、跨来源目录和
跨磁盘。重名、文件夹合并、权限提升、进度、占用、网络位置、取消与部分完成均由 Shell
处理；程序会额外检查 `GetAnyOperationsAborted`。不会静默覆盖，也不会自行用“复制后
删除”模拟移动。

常用目标最多 5 个，全部写在配置文件中。首次升级时，PopDrop 会把系统“桌面”和“下载”
路径迁移为前两项；它们和其他常用位置一样可以删除，删除后不会自动恢复：

新建配置中的“文档”“下载”“桌面”均通过 Windows 已知文件夹解析，会遵循系统属性中
把这些目录移动到其他磁盘后的设置。仅当旧配置仍是
`%USERPROFILE%\Documents`、`%USERPROFILE%\Downloads` 等历史默认值时才自动迁移；
自定义路径不会被覆盖。

```ini
[General]
TransferFavoritesInitialized=1

[TransferFavorites]
Path001=%USERPROFILE%\Desktop
Path002=%USERPROFILE%\Downloads
Path003=D:\项目交付
Path004=E:\素材归档
```

最近目标最多 3 个，只记录确实产生文件变化的成功复制或移动目标。无效目标会标记为
不可用，可从菜单移除。移动或重命名固定项时，PopDrop 根据 Shell 返回的实际新项目
更新固定路径；文件夹路径变化时也同步其后代固定项。移动操作包括冲突对话框造成的
自动改名。整批操作完成后只请求一次后台刷新，并尽量恢复选择、焦点和滚动位置。

### 三种子文件夹显示范围

`DisplayScope` 可以全局配置，也可以在 `[Folder:名称]` 中覆盖：

```ini
[General]
DisplayScope=FilesOnly
FolderTimeMode=DirectoryModified

[Folder:项目]
DisplayScope=FilesAndFolders
FolderTimeMode=LatestContent
```

- `FilesOnly`：仅显示当前目录中的文件。
- `FilesAndFolders`：显示当前目录文件和直接子文件夹；不会平铺子文件夹内容。
- `RecursiveFiles`：递归显示全部后代文件，与根目录文件一起排序。

文件夹不强制置顶，与文件参与同一排序。`LatestContent` 在后台扫描进程中计算所有允许
后代文件的最大修改时间，界面显示“内容更新于”；空文件夹、离线、无权限或扫描失败时
回退到文件夹自身修改时间。递归扫描默认不进入符号链接、目录联接和其他重解析点。
旧 `IncludeSubfolders=0/1` 在没有 `DisplayScope` 时分别兼容为 `FilesOnly` 和
`RecursiveFiles`。

### 配置写入与测试

v0.7 新增配置以及固定项批量更新使用临时文件和同卷原子替换，减少异常退出造成的配置
损坏。Windows 上可运行：

```powershell
AutoHotkey64.exe PopDrop.ahk --self-test
```

非 Windows CI 可运行 `python -m unittest discover -s tests -v` 做配置/API 接线和
关键规范化规则检查。

## 开机启动（可选）

按 `Win+R`，输入 `shell:startup`，把 `PopDrop.exe` 或 `PopDrop.ahk` 的快捷方式放进去。

## 编译为 EXE

详见 [BUILD.md](BUILD.md)。
