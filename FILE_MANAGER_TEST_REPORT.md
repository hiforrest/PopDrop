# 第三方文件管理器支持：开发与验证说明

## 实现概览

新增 `FileManager.ahk`，提供两个明确的业务语义入口：

- `OpenFolderInFileManager(folderPath)`：打开指定文件夹；
- `RevealItemsInFileManager(itemPaths)`：打开文件所在文件夹，并在适配器能力允许时
  选中项目。

`FileManagerRouter` 只读取稳定 Provider ID，并分派到
`WindowsShellFileManagerAdapter`、`DirectoryOpusFileManagerAdapter`、
`TotalCommanderFileManagerAdapter`、`XYplorerFileManagerAdapter`、
`DoubleCommanderFileManagerAdapter`、`FilesFileManagerAdapter` 或
`FreeCommanderFileManagerAdapter`。主面板、设置窗口和传输中心均不判断具体文件
管理器。

普通文件继续由 `OpenItemWithDefaultApplication()` 的 `Run(path)` 使用默认关联打开；
配置文件继续使用 `ShellExecuteW`；外部传输 helper 和扫描 worker 的进程启动也保持
原样。这些调用都不是文件夹浏览或文件定位入口。

## 配置

配置版本升级为 19。第一区配置节为：

```ini
[FileManager]
Provider=WindowsShell
Executable=
```

`Provider` 允许 `WindowsShell`、`DirectoryOpus`、`TotalCommander`、`XYplorer`、
`DoubleCommander`、`Files` 和 `FreeCommander`。v19 迁移会为缺少该节、缺少键或
Provider 为空的旧配置显式补齐 `WindowsShell` 与空 `Executable`；已有 Provider 和
程序路径保持不变，因此旧配置升级后的行为不变。
设置草稿包含这两个字段；保存走现有配置备份、布局感知写入、验证、原子替换和失败
回滚，取消不写盘。

程序启动只读取并规范 Provider，不主动验证或提示第三方路径。用户执行目录操作或点击
测试按钮时才检查路径。

## 已迁移的原有入口

以下入口现在全部调用统一路由：

1. 主文件区双击文件夹；
2. 固定项中的文件夹打开；
3. 来源分组标题左键打开；
4. 来源标题右键菜单“打开来源文件夹”；
5. 来源设置中的“打开”按钮；
6. `Ctrl+Enter`“在文件管理器中显示”；
7. PopDrop 文件项目右键菜单“在文件管理器中显示”；
8. 复制或移动完成状态中的“打开目标文件夹”；
9. 无操作、来源直接落盘和操作取消等状态中的“打开目标文件夹”；
10. 文件操作详情对话框中的“打开目标文件夹”；
11. Launcher 快捷方式创建完成状态中的“打开目标文件夹”；
12. 外部内容接收完成状态中的“打开目标文件夹”；
13. 下载任务窗口中的“打开目标文件夹”。

全量检索后保留的直接启动调用及原因：

- `OpenItemWithDefaultApplication()` 的 `Run(path)`：普通文件默认关联，明确不属于本
  功能替换范围；
- `OpenConfigFile()` 的 `ShellExecuteW`：打开普通配置文件；
- 扫描 worker、外部传输 helper 的 `Run(...)`：启动 PopDrop 自身进程，不是浏览目录。

## 适配器命令

所有外部参数先形成 argv 数组，再由项目既有 `BuildWindowsParameterString()` 和
`QuoteWindowsArgument()` 逐项引用，通过 `ShellExecuteExW` 的 `lpFile` /
`lpParameters` 分离传递。不会经过 `cmd.exe`、PowerShell、批处理或自定义命令模板。

### Windows 系统行为

- 打开文件夹：继续执行 `Run(folderPath)`，不固定调用 `explorer.exe`；
- 定位文件：继续执行 `SHParseDisplayName` +
  `SHOpenFolderAndSelectItems`；
- 同一文件所在文件夹中的多选继续一次性传给 Windows Shell；
- 跨文件夹多选继续保持原有约束。

因此系统级 Directory Opus Explorer Replacement 等关联仍可继续接管系统文件夹打开。

### Directory Opus

- 打开文件夹 argv：
  `["/acmd", "Go", folderPath, "NEWTAB=deflister,findexisting", "TOFRONT"]`
- 定位单个项目 argv：
  `["/acmd", "Go", fullItemPath, "OPENCONTAINER",`
  `"NEWTAB=deflister,findexisting", "TOFRONT"]`

执行程序必须是 `dopusrt.exe`。若手动选择 `dopus.exe` 且同目录存在
`dopusrt.exe`，保存和执行时会转换到后者。单个项目支持打开文件所在文件夹并选中；
`deflister` 确保没有 Lister 时打开默认 Lister，`findexisting` 优先复用已打开标签，
独立的 `TOFRONT` 将承载结果的 Lister 带到前台。多选不发送异步命令序列，而是按文件
所在文件夹去重后各打开一次。

### Total Commander

- 打开文件夹 argv：
  `["/O", "/S", "/L=" folderPath]`

支持 `TOTALCMD64.EXE` 与 `TOTALCMD.EXE`。`/O` 请求复用现有实例，`/S` 将 `/L=`
解释为当前源面板路径。定位单个或多个项目均只按文件所在文件夹去重后打开，不尝试
自动选中文件，不使用窗口消息、用户命令、剪贴板或键盘模拟。

### XYplorer

- 打开文件夹 argv：`[folderPath + "\"]`
- 定位单个项目 argv：`[fullItemPath]`

执行程序必须是 `XYplorer.exe`。XYplorer 的命令行路径语义以末尾反斜杠区分操作：
带末尾反斜杠的目录路径进入该目录；无末尾反斜杠的项目路径打开父目录并选中项目。
因此单个文件或文件夹可精确定位。多选不使用 `/script` 注入，而是沿用统一降级策略，
按项目所在文件夹保序去重后各打开一次。该语义依据 XYplorer 官方论坛管理员对
[启动目录](https://www.xyplorer.com/xyfc/viewtopic.php?t=23911)与
[末尾反斜杠选择行为](https://www.xyplorer.com/xyfc/viewtopic.php?t=15588)的说明。

### Double Commander

- 打开文件夹 argv：`["-C", folderPath]`
- 定位单个项目 argv：`["-C", fullItemPath]`

执行程序必须是 `doublecmd.exe`。`-C` 优先把请求交给已有实例；没有实例时正常启动。
Double Commander 官方命令行文档明确说明，传入完整文件名会打开其父目录并把光标移到
该文件，因此单文件可精确定位；文件夹路径直接打开。多选按父目录去重后打开。依据：
[Double Commander Command Line](https://doublecmd.github.io/doc/en/commandline.html)。

### Files

- 打开文件夹 argv：`["-directory", folderPath]`
- 定位单个项目 argv：`["-select", fullItemPath]`

支持 `Files.exe` 以及 `files-stable.exe`、`files-preview.exe`、`files-dev.exe`
官方启动别名。当前源码的命令行解析器把 `Select` 映射为 `SelectItem`，主窗口收到绝对
项目路径后拆出父目录和文件名，并在导航完成后选中该名称。多选时不连续发送异步选择
命令，而是按父目录去重后打开。依据：
[命令行解析器](https://github.com/files-community/Files/blob/main/src/Files.App/Utils/CommandLine/CommandLineParser.cs)、
[主窗口定位实现](https://github.com/files-community/Files/blob/main/src/Files.App/MainWindow.xaml.cs)和
[官方启动别名说明](https://files.community/docs/getting-started/faq)。

### FreeCommander XE

- 打开文件夹 argv：`["/C", folderPath]`
- 定位单个项目 argv：`["/C", fullItemPath]`

执行程序必须是 `FreeCommander.exe`。`/C` 优先把命令行参数传给已有实例；直接传入
完整文件路径时，FreeCommander XE 打开父目录并把光标定位到该文件。多选按父目录去重
后打开；文件夹路径直接打开。该能力由 FreeCommander 作者在
[Select file on startup FC](https://freecommander.eu/viewtopic.php?t=3699) 中明确确认，
当前用户也在
[DOS command to “select file(s)”](https://freecommander.eu/viewtopic.php?t=7069)
中确认完整文件路径会把光标定位到搜索结果。

## 调研后未接入

- **One Commander**：官方[命令行文档](https://www.onecommander.com/help/3._Full_reference_guide/Starting_from_Command_line.html)
  只列出路径、面板和标签页打开参数，没有指定项目选择语义。

One Commander 不使用键盘/鼠标模拟、剪贴板或未公开窗口消息兜底，因此没有注册
Provider。

## 自动查找与错误处理

自动查找只检查：

- Windows `App Paths` 的当前用户、机器和 32 位注册位置；
- Program Files 常用安装目录；
- Total Commander 的 `COMMANDER_PATH`（若当前环境存在）；
- XYplorer 的 `App Paths`、Program Files 常用目录和
  `%LOCALAPPDATA%\Programs\XYplorer`；
- Double Commander 的 `App Paths` 与 Program Files 常用目录；
- Files 的 `App Paths`、Program Files 和
  `%LOCALAPPDATA%\Microsoft\WindowsApps` 官方执行别名；
- FreeCommander XE 的 `App Paths` 与 Program Files 常用目录；
- `C:\totalcmd`、`C:\totalcmd64`。

不递归扫描磁盘。自动查找失败后仍可浏览选择任意便携版路径。

目标文件夹或项目不存在时先报告目标路径错误。第三方程序路径为空、失效、类型不符或
启动失败时，显示明确错误，并让用户选择：

- 打开文件管理器设置；
- 本次主动改用 Windows 系统方式；
- 取消，不执行其他操作。

不会静默失败，也不会自动同时启动两个文件管理器。

## 自动测试

### 2026-07-29 实机反馈修复

- PopDrop 右键菜单不再把 `RevealItemsInFileManager` 直接注册为菜单回调。新增专用
  `RevealItemsFromPopDropMenu` 包装器，以明确的四参数签名接收绑定的路径数组以及
  AutoHotkey 自动追加的菜单项名称、位置和菜单对象；包装器再以单个业务参数调用统一
  文件管理器接口。这将菜单事件协议与业务接口彻底隔离。
- 设置页测试按钮现在在按钮下方显示“正在测试”“命令已发送”或失败状态；失败仍显示
  详细错误。测试打开文件夹改用确定存在的系统临时目录，避免脚本目录恰好已打开时
  看不出变化。
- Directory Opus 的两条 `Go` 命令加入文档化的 `tofront` 标志；命中既有标签时也将
  对应 Lister 带到前台，测试与正式业务继续共用同一适配器和参数构造函数。
- 静态回归禁止再次把 `RevealItemsInFileManager` 直接绑定为菜单回调，并检查专用
  包装器的精确参数签名、可见测试状态、临时目录测试及 `findexisting,tofront` 参数。
- 构建包包含 `HOTFIX_BUILD.txt`。若错误窗口仍显示
  `Specifically: RevealItemsInFileManager`，或源码中找不到
  `RevealItemsFromPopDropMenu`，说明当前进程加载的仍是修复前文件。

### 2026-07-29 Directory Opus 命令无响应修复

- 修复统一参数引用函数无条件为每个参数添加双引号，导致 DOpusRT 实际收到
  `"/acmd" "Go" ...` 的兼容性问题。Windows 标准解析器能接受这种形式，但 DOpusRT
  对控制开关使用自己的原始命令行解析，可能无法识别被引用的 `/acmd`，表现为进程
  启动成功、PopDrop 显示“命令已发送”，但 Directory Opus 没有动作。
- 引用函数现在采用 Windows 标准的最小引用方式：`/acmd`、`Go`、`OPENCONTAINER`、
  `TOFRONT` 等简单常量保持裸参数；空值以及包含空格、制表符或双引号的路径仍使用统一
  的反斜杠/双引号转义。执行仍通过 `ShellExecuteExW` 的 `lpFile` 与 `lpParameters`
  分离传递，不经过命令解释器。
- Directory Opus 打开参数改为官方文档化组合
  `NEWTAB=deflister,findexisting TOFRONT`；自测试新增原始参数字符串必须以
  `/acmd Go ` 开头且不得包含 `"/acmd"` 的断言。

非 Windows 环境：

```bash
python3 -m py_compile tests/*.py
python3 tests/verify_folder_drop_contract.py
python3 tests/verify_source_management_contract.py
python3 tests/verify_file_manager_contract.py
```

`verify_file_manager_contract.py` 检查适配器结构、两个语义入口、所有已知业务入口迁移、
设置草稿与配置写回、各适配器 argv 与能力说明、v19 配置迁移、自动查找、中性菜单
文案、禁止 UI 模拟、明确不注册 One Commander，以及剩余 `Run` 调用边界。

本次 Linux 交付环境实际结果：

- `python3 -m py_compile tests/*.py`：通过；
- `verify_folder_drop_contract.py`：PASS；
- `verify_source_management_contract.py`：PASS；
- `verify_file_manager_contract.py`：PASS；
- AutoHotkey `--self-test`：未执行（当前环境没有 Windows/AutoHotkey）；
- Directory Opus / Total Commander / XYplorer / Double Commander /
  FreeCommander XE / Files 实际启动：未执行（当前环境不是 Windows）。

Windows AHK 自测试新增：

- 缺失或未知 Provider 回退 `WindowsShell`；
- 七个稳定 ID 解析；
- Directory Opus 打开与单文件定位 argv；
- Total Commander `/O /S /L=` argv；
- XYplorer 目录末尾反斜杠与单项目完整路径 argv；
- Double Commander `-C` 目录与单项目 argv；
- Files `-directory` 与 `-select` argv；
- FreeCommander XE `/C` 目录与单项目 argv；
- 空格、中文、括号、`&` 和双引号路径经统一引用后用
  `CommandLineToArgvW` 无损还原。

## 仍需 Windows 人工验证

当前交付环境不是 Windows，以下项目需在安装对应软件的 Windows 10/11 桌面会话中
验证：

1. Directory Opus 未运行、已运行、目标标签已存在三种状态；
2. Directory Opus 单个文件实际选中与窗口/标签复用；
3. Total Commander 32/64 位、便携版、未运行与已运行实例；
4. Total Commander 当前源面板切换；
5. XYplorer 安装版、便携版、未运行与已运行实例；
6. XYplorer 单文件、单文件夹定位及多选父目录去重；
7. Double Commander 安装版、便携版、未运行与已运行实例及单项目光标定位；
8. Files 稳定版/预览版/开发版执行别名、未运行与已运行实例及 `-select` 定位；
9. FreeCommander XE 安装版、便携版、未运行与已运行实例及单项目光标定位；
10. 本地盘、UNC、中文、空格、括号、`&` 和含引号文件名；
11. 六个第三方程序卸载后错误恢复选项；
12. Windows Shell 同目录多选与系统级 Explorer Replacement；
13. 100%/125%/150%/200% DPI 下设置页控件布局；
14. 保存、取消、重新打开设置后的 Provider/Executable 状态。

当前有意不支持 Total Commander 精确选中、第三方文件管理器多选精确选择、自定义命令
模板、键盘/鼠标模拟及复杂面板或标签策略；One Commander 因无公开定位接口而不注册。
