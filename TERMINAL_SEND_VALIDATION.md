# Windows 终端兼容发送：实现与验证记录

## 实际实现

- 以顶层宿主窗口类和窗口拥有者进程识别 Windows Terminal 与 Windows Console Host；
  不使用内部 `cmd.exe`、`powershell.exe` 或 `pwsh.exe` 作为判断依据。
- 仅在终端分支清除绝对首尾连续 CRLF/LF/CR，保留内部换行、普通空格、缩进和原文件。
- 清理后无有效内容停止；单行直接投送；多行默认确认，高置信度中文自然语言规则可免除
  PopDrop 自身确认。
- Console Host 使用一次 `WM_PASTE`；Windows Terminal 使用一次兼容 Claude Code 等原始
  输入 TUI 的 `Shift+Insert`
  粘贴动作。不发送回车，不以右键为唯一通道，不在结果未知时盲目重试。
- 确认前写入清理后的正文；取消和失败均保留。投送前重新验证宿主身份、前台窗口和本次
  剪贴板正文，整笔文本发送使用会话互斥防止快速连续动作交叉。
- 普通窗口继续使用原正文和原 `Ctrl+V`；普通前置发送仍使用既有焦点验证和开头定位。
  终端中的前置发送不发送 `Ctrl+Home`，只粘贴到当前活动窗格。

## 中文自然语言免确认规则

规则每次只分析待投送正文，不建立文件名、路径、哈希或固定内容名单。判定同时要求：

1. 至少存在一个非标题正文行，整体至少四个汉字；
2. 每个非空、非标题有效行都含汉字；英文只可作为 Markdown 标题结构行或夹在中文句中；
3. 非标题主体的汉字在“汉字 + 拉丁字母”中占比不低于 35%；
4. 允许 Markdown 标题、列表、任务列表、引用、粗体，以及中文句子中的常见英文术语；
5. 代码围栏、独立英文命令/未知行、提示符、独立路径/URL/参数、变量赋值、调用前缀、
   不安全反引号片段、管道、连接、分号、命令替换或重定向任一出现即否决免确认。

该规则只减少中文自然语言提示词的重复确认，不解释命令语义，不代表安全审查。

## 已执行验证

执行命令：

```text
python -m unittest discover -s tests -v
```

结果：101 项通过，0 项失败。覆盖原有工作区、搜索、IME、剪贴板、前置发送、缓存、拖放、
预览和构建契约，以及新增的：

- 宿主类/拥有者进程识别契约；
- CRLF、LF、CR、混合换行和首尾空格边界；
- 普通窗口不进入终端清理；
- 清理后空白停止和取消后剪贴板保底；
- 中文 Markdown 正例与独立命令、代码围栏、管道反例；
- 单次粘贴通道、宿主/前台重验证、终端不执行前置定位；
- 发送会话互斥和既有前置发送回归。
- 底栏状态、项目计数和文件选择摘要的自绘分发及主动重绘。

同时检查了项目全部 `#Include`、AHK 括号/函数名静态契约、Python 测试语法、原生 helper
PE 架构及交付 ZIP 完整性。

## 当前环境未执行的验证

本次工作环境为 Linux，没有 AutoHotkey v2、Ahk2Exe、PowerShell、MSVC、Windows Terminal
或 Console Host，因此以下项目没有伪称已通过：

- `AutoHotkey64.exe .\PopDrop.ahk --self-test`；
- `native\build.ps1` 的 MSVC x64/x86 重建；
- `build.ps1` 的 Ahk2Exe 主程序编译；
- Windows Terminal / Console Host 的真实焦点、选择、多标签、多窗格、原生警告和跨权限
  人工验证。

本功能未修改 C++ helper 或其协议，包内原有 x64/x86 helper 二进制保持不变。Windows 发布
前仍应按 `BUILD.md` 和 `DELIVERY_NOTES.md` 的终端专项清单执行上述门禁。

## 已知兼容边界

- 用户解绑 Windows Terminal 的 `Shift+Insert` 后，PopDrop 无法确认动作是否生效，因此
  不做第二次按键或右键重试；正文留在剪贴板。
- 宿主窗口无法判断活动窗格内是 Shell、REPL、SSH、全屏程序还是文本选择。Windows
  Terminal 仍可能显示自身多行或大文本警告。
- IDE 集成终端、第三方终端和旧式 `ApplicationFrameWindow` 宿主不在首版承诺范围。
- 权限等级不一致可能被 Windows 阻止激活或输入；此时安全停止，不向其他窗口降级发送。
