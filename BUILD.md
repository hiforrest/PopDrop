# 编译为 EXE

```powershell
.\build.ps1
```

脚本会自动检查环境、调用 Ahk2Exe 编译，把详细日志写入 `build_logs/` 目录。

---

## 首次编译前准备

1. 安装 [AutoHotkey v2](https://www.autohotkey.com/)（安装时勾选 Ahk2Exe 编译器）。
2. 确认编译器路径：`C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe`
3. 确认 v2 Base 路径：`C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe`

## 编译产物

| 文件 | 说明 |
|---|---|
| `PopDrop.exe` | 编译后的程序，可以和 `config.ini`（从 `config.example.ini` 复制）一起分发 |
| `build_logs/build_yyyyMMdd_HHmmss.log` | 每次编译的完整日志 |

编译后的 EXE 需要和 `config.ini` 放在同一目录，配置和固定文件才能正常保存。从源码构建时，请先将 `config.example.ini` 复制为 `config.ini`。

## 两次编译的意义

编译一次看不出好处。当你改了两周代码，编译出新的 EXE 替换旧的——面板正常、拖拽正常、右键菜单正常——这时候 `build.ps1` 的价值才体现出来：**你知道改动没有破坏编译流程**。

---

## 构建经验

建立这个编译脚本时踩了一些坑，写下来供参考：

### 1. 确认 PowerShell 版本再写脚本

系统默认 PowerShell 5.1 很常见，`#Requires -Version 7.0` 会直接拒跑。先查版本再写版本号。

### 2. .ps1 文件必须用 UTF-8 with BOM

PowerShell 5.1 解析 UTF-8 without BOM 脚本时，中文字符串中的 `;` 会被误判为语句分隔符，导致大量解析错误。检查方法：读文件前 3 字节，`0xEF 0xBB 0xBF` 才是 BOM。

### 3. Ahk2Exe 是 GUI 应用，不是控制台应用

`& $compilerPath @arguments 2>&1` 配合 `$LASTEXITCODE` 只对控制台应用有效。Ahk2Exe 1.1.x 是 GUI 应用（`SUBSYSTEM:WINDOWS`），需要用 `Start-Process -Wait -PassThru` 获取退出码，验证结果靠检查输出文件是否存在且大小不为 0。

### 4. 复杂脚本不要通过 Bash 内联编写

在 Bash 中写 `powershell.exe -Command "..."` 时，`$`、`"`、反引号的多层转义极易出错。多行脚本应该直接写 .ps1 文件，然后用 `-File` 执行。

### 5. ICO 文件必须包含多尺寸

不能只有 256×256 的 PNG。Windows 资源管理器、任务栏、文件属性页需要不同尺寸时，没有合适尺寸的条目会导致显示模糊或缩放异常。

- `app.ico`：至少包含 16、32、48、64、256px
- `tray.ico`：至少包含 16、20、24、32、40、48、64px，**全部 32bpp**（16×16 的 8bpp 在深色托盘上会显示黑底）
- 用 ImageMagick `-define icon:auto-resize=16,24,32,...` 可以一步生成

### 6. 源文件引用必须与文件系统一致

修改脚本前 grep 检查所有对已删除或重命名文件的引用。CI 脚本也应该验证所有硬编码路径是否实际存在。

### 7. 从简单参数开始测试

先测试 `/in /out /base` 三个参数能否编译成功，再逐步添加 `/compress`、`/silent` 等参数。一步到位遇到失败时，难以判断是哪个参数的问题。