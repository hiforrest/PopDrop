# PopDrop 使用指南

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

不需要装其他东西。脚本只调用 AutoHotkey 和 Windows 自带的 API。只有在你明确执行
“复制到…”或“移动到…”后，PopDrop 才会请求 Windows Shell 操作真实文件。

### 配置示例

编辑同目录下的 `config.ini`，保存后在面板点「刷新」就行：

```ini
[General]
ConfigVersion=8
Hotkey=F2
OpenFileMode=DoubleClick
MaxFilesPerFolder=8
DisplayScope=FilesOnly
FolderTimeMode=DirectoryModified
IncludeSubfolders=0
ThumbnailSize=96
ThumbnailHorizontalGap=24
ThumbnailVerticalGap=4
ThumbnailTextLines=2
WindowWidth=980
WindowHeight=620
ViewMode=Thumbnail
ShowRecentSidebar=1
RecentFileCount=12
CachePath=
ThumbnailPolicy=Fast
WindowMode=temporary

[Folders]
文档=%USERPROFILE%\Documents
下载=D:\download
项目=D:\Projects\Current
```

### 配置项说明

| 配置项 | 作用 |
|---|---|
| `[Folders]` | 每一行是一个分组，格式是 `显示名称=文件夹路径`。路径支持 `%USERPROFILE%` 等环境变量。 |
| `DisplayScope` | `FilesOnly`=仅当前目录文件；`FilesAndFolders`=当前目录文件和直接子文件夹；`RecursiveFiles`=递归文件平铺。 |
| `FolderTimeMode` | `DirectoryModified`=文件夹自身时间；`LatestContent`=允许扫描的后代文件最新时间。 |
| `IncludeSubfolders` | v0.6 及更早版本兼容项；缺少 `DisplayScope` 时，`0` 迁移为 `FilesOnly`，`1` 迁移为 `RecursiveFiles`。 |
| `ThumbnailSize` | 缩略图边长，48～256。建议 72、96、128 或 160。 |
| `ThumbnailHorizontalGap` | 相邻图标之间的水平留白，0～128 像素，默认 24。 |
| `ThumbnailVerticalGap` | 相邻图标行之间的垂直留白，0～128 像素，默认 4。文件名高度由 `ThumbnailTextLines` 另行预留，设为 0 也不会压扁缩略图。 |
| `ThumbnailTextLines` | 缩略图文件名显示并预留的行数。`1`=单行紧凑，过长名称按图标宽度显示省略号，完整路径仍可在状态栏查看；`2`=双行，默认 2；其他值会自动限制到 1～2。 |
| `WindowWidth` / `WindowHeight` | 面板打开时的尺寸。 |
| `ViewMode` | `Thumbnail`=缩略图，`List`=文件名+修改时间。也可以在面板顶部手动切换。 |
| `ShowRecentSidebar` | `1`=显示最近打开侧边栏，`0`=关闭。面板顶部按钮也可以随时开关。 |
| `RecentFileCount` | 侧边栏最多显示多少个近期文件，范围 1～100。 |
| `CachePath` | 扫描结果缓存目录。留空时使用软件目录下的 `cache` 文件夹；不可写时退化为内存缓存。 |
| `ThumbnailPolicy` | `Fast`（默认）只读取已有 Shell 缩略图缓存，缺失时显示文件类型图标；`Full` 允许现场生成缩略图，可能造成短暂停顿。 |
| `WindowMode` | 窗口显示模式：`temporary`（默认，置顶，切换到其他窗口后自动隐藏）、`always_on_top`（始终置顶）、`normal`（普通窗口，不置顶）。 |
| `OpenFileMode` | 普通文件的鼠标激活方式：`DoubleClick`（默认）或 `SingleClick`。缺失、空值或未知值都回退为双击。 |
| `SortMode` | 排序模式：`ModifiedDesc`（修改时间从新到旧，默认）、`NameAsc`（文件名自然升序）。支持文件夹级覆盖。 |
| 快捷键语法 | AutoHotkey v2 格式：`^`=Ctrl，`!`=Alt，`+`=Shift，`#`=Win。例如 `^!Space`=Ctrl+Alt+Space。 |

---

## 单击或双击打开文件

点击面板顶部“配置”可选择全局打开方式，并为每个监控来源选择：

- `Inherit`：跟随全局设置（默认）
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
使用全局值。同一个文件显示在两个来源分组时，分别使用当前分组的来源设置。

来源首次迁移时会获得稳定 `SourceId`，并在 `[Sources]` / `[Source:<ID>]` 中保留身份；
单独修改来源名称或路径、以及调整顺序，都不会丢失打开方式。通常无需手工编辑这些
内部字段。

---

## 文件筛选（v0.3+）

从 v0.3 开始，PopDrop 支持按文件扩展名筛选，可以在全局和文件夹级别独立配置。

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

- 没有 `[Folder:名称]` 配置节：完全继承全局设置。
- `IncludeSubfolders` 缺失：继承全局值。
- `MaxFilesPerFolder` 缺失：继承全局值。
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
IncludeSubfolders=0
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
IncludeSubfolders=0
MaxFilesPerFolder=12
FilterMode=Exclude
FileExtensions=.tmp,.part,.crdownload,.download

[Folder:素材]
; 只显示图片文件
IncludeSubfolders=1
MaxFilesPerFolder=20
FilterMode=Include
FileExtensions=.png,.jpg,.jpeg,.webp,.gif

[Folder:项目]
; 未配置独立节，完全继承全局设置（All）
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
| `MaxFilesPerFolder` | `All` | 显示所有匹配项目 |
| `SortMode` | `NameAsc` | 按文件名自然升序 |
| `FilterMode` | `Include` | 只显示扩展名列表中的文件 |
| `FileExtensions` | `.lnk,.url,.exe` | 只显示快捷方式和可执行文件 |
| `StripOrderPrefix` | `1` | 隐藏数字排序前缀 |
| `HideExtensions` | `1` | 隐藏文件扩展名 |

用户显式配置的选项会覆盖这些默认值。

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

面板会先显示上次扫描得到的结果，然后在独立后台进程中更新文件夹和 Windows 近期文件；新结果完整写出后才一次性刷新界面。缓存默认位于软件目录下的 `cache\scan-cache-v2.ini`，可以通过 `CachePath` 指定其他目录。缓存只保存路径和修改时间，不保存文件内容或缩略图；删除缓存不会删除任何用户文件。软件目录不可写时，程序仍可运行，但本次只使用内存缓存。

后台刷新改善的是面板响应体验，目录本身仍需要完整枚举；它不是实时文件系统监听，也不会让大目录扫描消失。

---

## 固定项

点击「＋ 固定项」可以选择一个或多个文件。也可以从资源管理器把文件、文件夹直接拖进 PopDrop 窗口；文件夹会作为单独的固定项加入，不会展开或添加其中的内容。

固定列表继续保存在 `config.ini` 的 `[PinnedFiles]` 里，与旧配置完全兼容。选择固定项后点击「－ 固定项」，只移除面板里的记录，不会影响原文件或文件夹。双击固定文件夹会在资源管理器中打开。

- 新加入的一批固定项会显示在最前面，并保持这批项目拖入时的原始顺序。
- 拖动单个固定项到另一个固定项上，可以调整前后顺序；顺序会立即保存。
- 将固定项拖出主列表时，会继续使用原有的 Windows 文件拖放。
- 多选拖拽仍然用于向其他软件发送项目，不执行内部排序。

- 重复路径会自动跳过。
- 文件和文件夹可以同时拖入。
- 如果原项目以后被移动、重命名或删除，固定项会显示为「项目不存在」。
- 如果 PopDrop 与来源程序使用不同的管理员权限级别，Windows 可能阻止拖放。

## 最近打开侧边栏

侧边栏读取 Windows 维护的「最近文件」记录（`%APPDATA%\Microsoft\Windows\Recent`），只展示仍然存在的文件。双击、拖拽、右键菜单都作用于原文件。

如果 Windows 隐私设置里关闭了「显示最近打开的项目」，或者系统没有留下记录，侧边栏会显示为空——这不是 PopDrop 的问题，是系统没有给它数据。

## 小技巧

- 多选后点击「－ 固定项」，会批量将所有选中项目移出固定项，不会删除源文件。
- 多选后拖拽任意一个已选文件，所有选中文件一起发送——支持跨文件夹、跨磁盘。
- 某些以管理员权限运行的软件，不会接受普通权限程序的拖放。这是 Windows 的安全机制。如果遇到这种情况，让 PopDrop 和目标软件使用相同权限级别即可。
- 普通右击使用 PopDrop 精简菜单；需要第三方扩展或其他系统命令时，按住 `Shift` 右击或按 `Shift + F10`。
- 网络盘、离线盘、权限受限的目录会显示为不可用；恢复连接后点「刷新」即可回来。

## v0.7 文件操作与打开方式

### 精简右键菜单和快捷键

普通右击打开 PopDrop 精简菜单。右击当前多选中的项目会保留整个选择；右击未选中项目
会先改为单选。`Shift + 右击` 和 `Shift + F10` 直接打开完整 Windows Shell 菜单。

| 操作 | 快捷键 |
|---|---|
| 使用默认关联打开 | `Enter` |
| 在文件资源管理器中显示 | `Ctrl + Enter` |
| 复制文件对象到剪贴板 | `Ctrl + C` |
| 复制完整路径文本 | `Ctrl + Shift + C` |
| 更多系统操作 | `Shift + F10` |

多选定位只支持同一父目录；跨父目录时菜单项禁用，避免一次打开大量资源管理器窗口。
复制文件使用 `CF_HDROP`，可以直接粘贴到资源管理器或支持文件粘贴的软件；复制路径则
按当前显示顺序每行一条，不添加引号。

### 配置用于打开文件的软件

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
均可省略，分别默认使用程序产品名、EXE 内置图标和启用状态。`Extensions` 留空或省略
表示适用于所有普通文件。完整写法如下：

```ini
[OpenApps]
Order=7z,everedit

[OpenApp:7z]
Path=C:\Program Files\7-Zip\7zFM.exe
Name=7-Zip
Icon=C:\Program Files\7-Zip\7zFM.exe
Extensions=.7z,.zip
Enabled=1

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

### 复制到、移动到和目标位置

复制和移动使用 Windows `IFileOperation`，支持文件、文件夹、混合选择、跨来源目录和
跨磁盘。重名、文件夹合并、权限提升、进度、占用、网络位置、取消与部分完成均由 Shell
处理；程序会额外检查 `GetAnyOperationsAborted`。不会静默覆盖，也不会自行用“复制后
删除”模拟移动。

常用目标最多 5 个，全部写在配置文件中。首次升级时，PopDrop 会把系统“桌面”和“下载”
路径迁移为前两项；它们和其他常用位置一样可以删除，删除后不会自动恢复：

```ini
[General]
TransferFavoritesInitialized=1

[TransferFavorites]
Path001=C:\Users\用户名\Desktop
Path002=C:\Users\用户名\Downloads
Path003=D:\项目交付
Path004=E:\素材归档
```

最近目标最多 3 个，只记录确实产生文件变化的成功复制或移动目标。无效目标会标记为
不可用，可从菜单移除。移动固定项时，PopDrop 根据 Shell 返回的实际新项目更新固定
路径，包括冲突对话框造成的自动改名。整批操作完成后只请求一次后台刷新，并尽量恢复
选择、焦点和滚动位置。

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
