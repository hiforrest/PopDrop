# PopDrop 构建与验证

PopDrop 主程序使用 AutoHotkey v2；外部内容投放和文件预览 helper 使用 Windows C++。

## 环境

- Windows 10 或 Windows 11
- AutoHotkey v2（运行源码与 `--self-test`）
- Ahk2Exe（仅编译 `PopDrop.exe` 时需要）
- Visual Studio 2022 Build Tools，“使用 C++ 的桌面开发”工作负载
  （仅构建 `PopDropTransfer.exe` 时需要）

## 验证源码

在项目目录运行：

```powershell
AutoHotkey64.exe .\PopDrop.ahk --self-test
python -m unittest discover -s tests -v
```

第一条执行 Windows API、配置文档往返、动作参数转义和现有纯逻辑自检。第二条执行
跨平台静态与纯逻辑回归测试。

## 构建外部投放 helper

```powershell
powershell -ExecutionPolicy Bypass -File .\native\build.ps1
```

输出位置及 x86/x64 打包规则见 [native/README.md](native/README.md)。源码模式按
AutoHotkey 位数从 `native\bin\<架构>` 加载；发布包应把对应架构的
`PopDropTransfer.exe` 放在 `PopDrop.exe` 同目录。

## 编译主程序

使用 Ahk2Exe 编译 `PopDrop.ahk`。入口文件中的编译指令会设置应用图标、托盘资源、
产品名和文件版本。

### 编译命令

```powershell
& 'C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe' /in 'PopDrop.ahk' /out 'PopDrop.exe' /icon 'assets\app.ico'
```

> **注意：** Ahk2Exe 是 GUI 程序，在 Git Bash 中运行可能静默失败（退出码 3 且无有效
> 错误信息）。建议使用 **PowerShell** 执行编译。
> 
> 在 Git Bash 中可通过 `MSYS2_ARG_CONV_EXCL='*'` 禁止路径转换来绕过：
> ```bash
> MSYS2_ARG_CONV_EXCL='*' '/c/Program Files/AutoHotkey/Compiler/Ahk2Exe.exe' \
>   /in 'D:\GProgram\PopDrop\PopDrop.ahk' \
>   /out 'D:\GProgram\PopDrop\PopDrop.exe' \
>   /base 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
> ```

### 常见问题

#### 编译报 "Failed to compile" 但脚本自测通过

**根因：** 解释器存根文件（`*.bin`）是 v1 版本，无法解析 `#Requires AutoHotkey v2.0`。

**正确的修复——使用 `/base` 参数：** 不要替换 `.bin` 文件。直接指定 v2 解释器为 Base 文件：

```powershell
& 'C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe' `
  /in 'PopDrop.ahk' `
  /out 'PopDrop.exe' `
  /base 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' `
  /compress 0
```

**原理：** Ahk2Exe 根据 Base 文件的扩展名决定脚本嵌入方式：
- `.exe` 后缀 → 脚本写入 `RCDATA #1` 资源，v2 解释器启动时自动加载
- `.bin` 后缀 → 使用旧式 `>AUTOHOTKEY SCRIPT<` 资源名，v2 解释器无法识别

因此不能把 `AutoHotkey64.exe` 改名为 `.bin` 使用——编译出来的 EXE 会退化为普通解释器模式，
运行时找同名的 `.ahk` 文件，报 "Script file not found"。

#### 编译后运行报 "Script file not found"

**现象：** 编译成功，但运行 `PopDrop.exe` 时报找不到 `PopDrop.ahk`。

**根因：** 编译时用了错误的 Base 文件（被替换为 `AutoHotkey64.exe` 的 `.bin` 存根）。
生成的 EXE 实际上是解释器，不是独立程序。

**验证：** 把 `PopDrop.exe` 复制到没有 `PopDrop.ahk` 的空目录运行，如果报 "Script file not found"
说明编译有问题。正确编译的 EXE 是独立运行的。

**修复：** 使用上一条 `/base` 参数重新编译。

### 发布清单

发布前请同时带上：

- `PopDropTransfer.exe`（与主程序同目录，x64 架构）
- `PopDropPreview.exe`（与主程序同目录，x64 架构）
- `config.example.ini`（用户复制为 `config.ini` 使用）
- `assets/`（图标资源，编译版运行时需要）
- `README.md`、`USAGE.md`、`CHANGELOG.md`、`THIRD_PARTY_NOTICES.md`
- `native/install-pdfium.ps1` 和 `native/pdfium-component.ini`（可选 PDF 预览）
- 第三方许可（`native/third_party/pdfium/LICENSE`）

不要把 x86 helper 与 x64 主程序混用。启动时的 helper 版本握手会明确拒绝不兼容
组件，而不是继续运行旧二进制。
