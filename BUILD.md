# PopDrop 构建与验证

PopDrop 主程序使用 AutoHotkey v2；外部内容投放 helper 使用 Windows C++。本次应用
工具动作功能没有增加第三方运行库，也不需要重新设计 native helper 协议。

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

使用 Ahk2Exe 选择 `PopDrop.ahk` 作为入口。入口文件中的编译指令会设置应用图标、
托盘资源、产品名和 `0.9.0.0` 文件版本；本次只升级配置架构到 15，不修改应用市场
版本号。发布前请同时带上：

- `config.ini`（UTF-16LE BOM、CRLF）
- 与目标架构一致的 `PopDropTransfer.exe`
- README、使用指南和其他发布文档

不要把 x86 helper 与 x64 主程序混用。启动时的 helper 版本握手会明确拒绝不兼容
组件，而不是继续运行旧二进制。
