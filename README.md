# PopDrop（AutoHotkey v2）

这是一个 Windows 置顶文件面板。按快捷键即可显示或隐藏；文件按配置目录分组，并按修改时间从新到旧排列。

## 功能

- 默认按 `F2` 显示/隐藏置顶面板，也可在 `config.ini` 自定义快捷键。
- 每个配置文件夹独立分组，以资源管理器式缩略图网格展示最新文件。
- 图片、视频、PDF 等优先使用 Windows Shell 缩略图，其他文件自动回退为类型图标。
- 可在面板内即时切换“缩略图”与“文件名列表”视图，并自动保存选择。
- 可选“最近打开”侧边栏，读取 Windows Recent Items 记录并直接操作原文件。
- 面板打开宽度和高度可在配置文件中设置。
- 支持 Ctrl 多选、Shift 连续选择，以及在空白区域按住左键拖出选择框。
- 支持永久固定常用文件；可在面板内添加或取消固定。
- 双击文件：使用 Windows 默认程序打开。
- 从文件名按住左键拖出：以标准 Windows Shell 文件拖放方式发送到其他软件；多选后可一次拖出来自不同分组、文件夹或磁盘的文件。
- 右键文件：显示 Windows Shell 完整传统右键菜单，包括已注册的第三方扩展项。
- 面板内关闭按钮、标题栏关闭按钮、Esc 和再次按快捷键均可隐藏面板。

## 运行

1. 安装 [AutoHotkey v2](https://www.autohotkey.com/)。本项目不能使用 v1 运行。
2. 双击 `PopDrop.ahk`。
3. 按 `F2` 打开面板。

脚本只调用 AutoHotkey 与 Windows 自带 API，不需要安装其他依赖。它不会修改、移动或删除面板中展示的源文件。

## 配置目录和快捷键

编辑同目录下的 `config.ini`，保存后在面板点“刷新”。示例：

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

[Folders]
文档=%USERPROFILE%\Documents
下载=D:\download
项目=D:\Projects\Current
```

说明：

- `[Folders]` 中每一行都是 `分组名称=目录路径`。
- 路径支持 `%USERPROFILE%` 等 Windows 环境变量。
- `IncludeSubfolders=1` 会递归扫描子目录；目录很大时首次刷新可能稍慢。
- `ThumbnailSize` 控制缩略图边长，可设为 48～256；建议使用 72、96、128 或 160。
- `WindowWidth`、`WindowHeight` 控制面板每次打开时的尺寸。
- `ViewMode=Thumbnail` 使用缩略图，`ViewMode=List` 使用文件名和修改时间列表；也可点击面板顶部按钮切换。
- `ShowRecentSidebar=1` 显示最近打开侧边栏，设为 `0` 关闭；顶部按钮也可即时开关。
- `RecentFileCount` 控制侧边栏最多显示多少个近期文件，范围 1～100。
- 快捷键使用 AutoHotkey v2 语法：`^`=Ctrl，`!`=Alt，`+`=Shift，`#`=Win。例如 `^!Space` 是 Ctrl+Alt+Space。
- 如果示例中的 `D:\download` 不存在，面板会标注“目录不可用”，不会报错退出。

## 固定文件

点击“添加固定文件”可一次选择一个或多个文件。固定项保存在 `config.ini` 的 `[PinnedFiles]` 中，下次运行仍会出现。选择固定项后点击“取消固定”，只会从面板移除固定记录，不会删除源文件。

## 最近打开侧边栏

侧边栏读取 `%APPDATA%\Microsoft\Windows\Recent` 中由 Windows 维护的快捷方式，解析后展示仍然存在的原文件。双击、拖拽和右键菜单都作用于原文件。如果 Windows 隐私设置关闭了“显示最近打开的项目”，或系统没有留下记录，该栏会显示为空。

## 设为开机启动（可选）

按 `Win+R`，输入 `shell:startup`，然后在打开的启动文件夹中放入 `PopDrop.ahk` 的快捷方式。

## 编译为 EXE（可选）

安装 AutoHotkey v2 时勾选编译器（Ahk2Exe），右键 `PopDrop.ahk` 选择 “Compile Script”。编译后的 EXE 仍需与 `config.ini` 放在同一目录，配置和固定文件才能持久保存。

## 使用提示

- 多选后点击“取消固定”，会批量取消所选项目中的固定文件，不会删除源文件。
- 多选后从任意一个已选文件开始拖动，会将全部选中文件一起发送；支持跨文件夹、跨磁盘组合。
- 某些以管理员权限运行的软件不会接受普通权限进程发起的拖放；这是 Windows 权限隔离机制。需要时让本工具与目标软件保持相同权限级别。
- Windows 11 的原生顶层精简菜单与传统完整菜单是两套接口。本工具直接调用完整 Shell 菜单，因此样式更接近“显示更多选项”后的菜单。
- 网络盘、离线盘或权限受限目录会显示为不可用；恢复连接后点“刷新”即可。
