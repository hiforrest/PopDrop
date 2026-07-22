# PopDrop

<img src="assets/logo.webp" width="192px">

按一下 `F2`，一个文件面板出现在屏幕最前面。找到文件，拖走，关掉。全程不到三秒。

PopDrop 是一个 Windows 小工具，把你常用的文件夹、最近打开的文件、固定好的文件集中在一个面板里，随时取用，用完就关。面板的窗口行为可通过 `WindowMode` 配置。

## 为什么要用它？

Windows 桌面和文件管理器很好用，但当你频繁在几个文件夹之间穿梭——拿参考图、拖素材到 Photoshop、找文档贴在邮件里——来回切换窗口很烦人。

PopDrop 把这一切简化成一步：**按快捷键 → 面板出现 → 找到文件 → 拖走或用右键菜单操作 → 再按快捷键面板消失**。

## 它能做什么

- **一键呼出**：默认 `F2`。在任何软件中按一下，面板就在最前面打开。
- **按文件夹分组**：把你常用的几个目录配好，面板自动按组展示最新文件，一眼扫过去就知道有什么。
- **缩略图预览**：图片、视频、PDF 直接显示缩略图，其他文件显示类型图标——不用看文件名就能认出来。
- **两种视图**：缩略图网格或文件名列表，点一下按钮就能切换，它会记住你上次的选择。
- **拖拽到任何软件**：从面板直接把文件拖到 Photoshop、浏览器、微信、邮件——跟在资源管理器里拖文件一样自然。
- **完整右键菜单**：右键文件，显示 Windows 的完整菜单，包括你装过的第三方扩展（7-Zip、Notepad++、VS Code 等）。
- **最近打开侧边栏**：右侧显示你最近用过的文件，双击就能再次打开。
- **固定常用文件**：把最常用的文件固定到面板顶部，不管它藏在哪个目录，始终可见。
- **多选操作**：`Ctrl` 多选、`Shift` 连续选、拖框选——选中后一起拖拽或批量操作。
- **双击打开**：用 Windows 默认程序打开文件。

## 开始使用

### 安装

1. 安装 [AutoHotkey v2](https://www.autohotkey.com/)。（注意：v1 不行，必须装 v2。）
2. 双击 `PopDrop.ahk`。
3. 按 `F2` 试试看。

不需要装其他东西。脚本只调用 AutoHotkey 和 Windows 自带的 API。**它不会修改、移动、删除你的文件**——只负责展示和操作。

### 设置你的文件夹

编辑同目录下的 `config.ini`，保存后在面板点「刷新」就行。示例：

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
WindowMode=always_on_top

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
| `WindowMode` | 窗口显示模式：`always_on_top`（始终置顶，默认）、`temporary`（置顶，切换到其他窗口后自动隐藏）、`normal`（普通窗口，不置顶）。 |
| `SortMode` | 排序模式：`ModifiedDesc`（修改时间从新到旧，默认）、`NameAsc`（文件名自然升序）。支持文件夹级覆盖。 |
| 快捷键语法 | AutoHotkey v2 格式：`^`=Ctrl，`!`=Alt，`+`=Shift，`#`=Win。例如 `^!Space`=Ctrl+Alt+Space。 |

### 文件筛选（v0.3+）

从 v0.3 开始，PopDrop 支持按文件扩展名筛选，可以在全局和文件夹级别独立配置。

#### 筛选模式

| 模式 | 含义 |
|---|---|
| `All` | 显示所有文件（默认，不筛选） |
| `Include` | 只显示扩展名列表中的文件 |
| `Exclude` | 排除扩展名列表中的文件 |
| `Inherit` | 仅文件夹级可用，整体继承全局筛选模式及扩展名列表 |

#### 全局配置

```ini
[General]
; All / Include / Exclude
FilterMode=All
FileExtensions=
```

- `FilterMode=All` 时，`FileExtensions` 被忽略，显示所有文件。
- `FilterMode=Include` 时，只显示扩展名匹配的文件。
- `FilterMode=Exclude` 时，排除扩展名匹配的文件。

#### 文件夹级独立配置

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

#### 扩展名规则

- 大小写不敏感：`jpg`、`.JPG`、`.jpg` 都一致对待。
- 自动补 `.` 前缀：`jpg` 等同于 `.jpg`。
- 支持多段后缀：`.tar.gz`。
- 逗号分隔，前后空格自动忽略。
- 重复扩展名自动去重。

#### 完整示例

```ini
[General]
Hotkey=F2
MaxFilesPerFolder=8
IncludeSubfolders=0
ThumbnailSize=96
; 窗口模式：always_on_top（默认）| temporary（失焦自动隐藏）| normal（普通窗口）
WindowMode=always_on_top
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

#### 注意事项

- 筛选只作用于对应文件夹的扫描结果，不影响固定文件和 Windows 最近打开侧边栏。
- 筛选发生在文件枚举时，但**不能避免对目录的完整枚举**，因此不能将其作为解决超大目录扫描速度的主要手段。
- 如果配置了 Include/Exclude 但没有文件命中，分组标题会显示「没有符合筛选条件的文件」，以区别于目录本身为空的情况。

如果配置的目录不存在，面板会显示「目录不可用」，不会报错退出。

### 快捷启动文件夹（Launcher 模式，v0.5+）

从 v0.5 开始，PopDrop 支持 `Mode=Launcher` 模式，将普通文件夹变成快捷启动面板。

#### 基本用法

在 `config.ini` 中配置：

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

在 `D:\Launcher\工具` 目录中放入快捷方式：

```
010 Chrome.lnk
020 Firefox.lnk
030 7-Zip.lnk
040 Everything Search.url
```

界面显示为：

```
Chrome
Firefox
7-Zip
Everything Search
```

#### Launcher 默认值

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

#### 数字前缀排序

文件名中的数字前缀用于自定义排序，界面不显示数字和扩展名：

```text
010 Chrome.lnk     → Chrome
020 7-Zip.lnk      → 7-Zip
7-Zip.lnk          → 7-Zip          （无前缀，保留原名）
3D Viewer.lnk      → 3D Viewer      （3D 不是前缀，保留原名）
```

排序始终使用原始文件名，前缀只影响显示。规则：只移除 `^\d+[ \t]+` 模式（数字开头，后面至少一个空格或制表符）。

#### 右键打开分组文件夹

Launcher 项目（及其他文件夹分组）右键菜单中增加「打开分组文件夹」选项，可以快速打开配置的根目录添加快捷方式。空目录或没有符合筛选条件的占位项也支持此功能。

#### 注意事项

- 分类由 `[Folders]` 中的分组承担，项目顺序由数字前缀决定。
- `.exe` 适合便携软件，普通安装软件推荐使用 `.lnk`。
- Launcher 模式不会改变 `WindowMode` 行为；窗口是否在打开软件后隐藏完全由 `WindowMode` 配置决定。
- 固定文件和最近打开侧边栏不受 Launcher 模式影响。

### 窗口模式（v0.4+）

从 v0.4 开始，PopDrop 支持三种窗口模式，通过 `[General]` 中的 `WindowMode` 配置：

```ini
WindowMode=always_on_top
```

| 模式 | 说明 |
|---|---|
| `always_on_top` | **默认值**。始终置顶，面板保持在其他窗口上方，直到手动隐藏。 |
| `temporary` | 临时面板。面板置顶，但当您切换到其他窗口、点击桌面或 Alt+Tab 后，面板自动隐藏。软件自身的消息框、文件选择对话框、右键菜单和拖放操作不会触发自动隐藏。 |
| `normal` | 普通窗口。不置顶，按照普通 Windows 窗口方式显示。被其他窗口覆盖时按快捷键先恢复面板，再按一次才隐藏。 |

### 刷新与缓存

面板会先显示上次扫描得到的结果，然后在独立后台进程中更新文件夹和 Windows 近期文件；新结果完整写出后才一次性刷新界面。缓存默认位于软件目录下的 `cache\scan-cache-v1.ini`，可以通过 `CachePath` 指定其他目录。缓存只保存路径和修改时间，不保存文件内容或缩略图；删除缓存不会删除任何用户文件。软件目录不可写时，程序仍可运行，但本次只使用内存缓存。

后台刷新改善的是面板响应体验，目录本身仍需要完整枚举；它不是实时文件系统监听，也不会让大目录扫描消失。

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

按 `Win+R`，输入 `shell:startup`，把 `PopDrop.ahk` 的快捷方式放进去。

## 编译为 EXE

详见 [BUILD.md](BUILD.md) —— 包含编译命令、环境准备、构建经验总结。
