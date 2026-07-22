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

不需要装其他东西。脚本只调用 AutoHotkey 和 Windows 自带的 API。**它不会修改、移动、删除你的文件**——只负责展示和操作。

### 配置示例

编辑同目录下的 `config.ini`，保存后在面板点「刷新」就行：

```ini
[General]
Hotkey=F2
MaxFilesPerFolder=8
IncludeSubfolders=0
ThumbnailSize=96
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
| `IncludeSubfolders=1` | 递归扫描子目录。如果目录很大，第一次刷新可能稍慢。 |
| `ThumbnailSize` | 缩略图边长，48～256。建议 72、96、128 或 160。 |
| `WindowWidth` / `WindowHeight` | 面板打开时的尺寸。 |
| `ViewMode` | `Thumbnail`=缩略图，`List`=文件名+修改时间。也可以在面板顶部手动切换。 |
| `ShowRecentSidebar` | `1`=显示最近打开侧边栏，`0`=关闭。面板顶部按钮也可以随时开关。 |
| `RecentFileCount` | 侧边栏最多显示多少个近期文件，范围 1～100。 |
| `CachePath` | 扫描结果缓存目录。留空时使用软件目录下的 `cache` 文件夹；不可写时退化为内存缓存。 |
| `ThumbnailPolicy` | `Fast`（默认）只读取已有 Shell 缩略图缓存，缺失时显示文件类型图标；`Full` 允许现场生成缩略图，可能造成短暂停顿。 |
| `WindowMode` | 窗口显示模式：`temporary`（默认，置顶，切换到其他窗口后自动隐藏）、`always_on_top`（始终置顶）、`normal`（普通窗口，不置顶）。 |
| `SortMode` | 排序模式：`ModifiedDesc`（修改时间从新到旧，默认）、`NameAsc`（文件名自然升序）。支持文件夹级覆盖。 |
| 快捷键语法 | AutoHotkey v2 格式：`^`=Ctrl，`!`=Alt，`+`=Shift，`#`=Win。例如 `^!Space`=Ctrl+Alt+Space。 |

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

- 筛选只作用于对应文件夹的扫描结果，不影响固定文件和 Windows 最近打开侧边栏。
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

### 右键打开分组文件夹

Launcher 项目右键菜单中有「打开分组文件夹」选项，可以直接跳到配置的根目录，方便添加或删除快捷方式。空目录或没有符合筛选条件的占位项也支持此功能。

### 应用场景

| 场景 | 做法 |
|---|---|
| **便携软件启动器** | 收集各软件的 `.exe` 到同一个目录，按分类放入不同子目录 |
| **常用网址菜单** | 收藏 `.url` 文件到文件夹，按用途分组 |
| **开发工具集合** | 将 VS Code 项目、终端、数据库工具的快捷方式分门别类 |
| **文档模板** | 混合 `.lnk` 和文档文件，调整 `FilterMode=All` 即可显示所有文件 |

### 注意事项

- 分类由 `[Folders]` 中的分组承担，项目顺序由数字前缀决定。
- `.exe` 适合便携软件，普通安装软件推荐使用 `.lnk`（后者能正确解析图标和名称）。
- Launcher 模式不会改变 `WindowMode` 行为；是否在打开软件后自动隐藏由 `WindowMode` 决定。
- 固定文件和最近打开侧边栏不受 Launcher 模式影响，它们始终以 `Files` 模式工作。

---

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

**自动隐藏的保护机制**：面板弹出消息框、文件选择对话框、右键菜单或进行拖放操作时，自动隐藏会被暂停，直到这些操作结束。这样你在配置面板或拖拽文件时，面板不会中途消失。

### 切换模式

编辑 `config.ini` 中的 `WindowMode` 行，保存后点面板顶部的「刷新」按钮即可生效，无需重启程序。`always_on_top` 和 `temporary` 都保持面板置顶，区别仅在于是否自动隐藏。

### 为什么要用 temporary 模式？

PopDrop 的设计初衷是「按一下出现，用完就走」。`temporary` 模式让这个流程变得更自然——你不需要手动按快捷键关闭面板，切换到其他窗口时面板自动消失，下次按快捷键又会出现。这比 `always_on_top` 少了一个操作步骤，也比 `normal` 模式更符合「用完即走」的心理模型。

---

## 刷新与缓存

面板会先显示上次扫描得到的结果，然后在独立后台进程中更新文件夹和 Windows 近期文件；新结果完整写出后才一次性刷新界面。缓存默认位于软件目录下的 `cache\scan-cache-v2.ini`，可以通过 `CachePath` 指定其他目录。缓存只保存路径和修改时间，不保存文件内容或缩略图；删除缓存不会删除任何用户文件。软件目录不可写时，程序仍可运行，但本次只使用内存缓存。

后台刷新改善的是面板响应体验，目录本身仍需要完整枚举；它不是实时文件系统监听，也不会让大目录扫描消失。

---

## 固定文件

点击「添加固定文件」选择文件，它们会出现在面板的固定区域。固定列表保存在 `config.ini` 的 `[PinnedFiles]` 里，下次启动还在。选择固定项后点击「取消固定」，只移除面板里的记录，不会碰原始文件。

## 最近打开侧边栏

侧边栏读取 Windows 维护的「最近文件」记录（`%APPDATA%\Microsoft\Windows\Recent`），只展示仍然存在的文件。双击、拖拽、右键菜单都作用于原文件。

如果 Windows 隐私设置里关闭了「显示最近打开的项目」，或者系统没有留下记录，侧边栏会显示为空——这不是 PopDrop 的问题，是系统没有给它数据。

## 小技巧

- 多选后点击「取消固定」，会批量取消所有选中项的固定，不会删除源文件。
- 多选后拖拽任意一个已选文件，所有选中文件一起发送——支持跨文件夹、跨磁盘。
- 某些以管理员权限运行的软件，不会接受普通权限程序的拖放。这是 Windows 的安全机制。如果遇到这种情况，让 PopDrop 和目标软件使用相同权限级别即可。
- 右键菜单直接调用 Windows 完整 Shell 菜单，样式接近「显示更多选项」后的菜单，而不是 Win11 的简化版——该有的选项都在。
- 网络盘、离线盘、权限受限的目录会显示为不可用；恢复连接后点「刷新」即可回来。

## 开机启动（可选）

按 `Win+R`，输入 `shell:startup`，把 `PopDrop.exe` 或 `PopDrop.ahk` 的快捷方式放进去。

## 编译为 EXE

详见 [BUILD.md](BUILD.md)。