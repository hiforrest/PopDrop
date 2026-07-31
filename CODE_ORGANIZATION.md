# PopDrop 源码结构

## 为什么拆分

旧版 `PopDrop.ahk` 共 12,996 行、约 479 KB，同时承载启动、配置、UI、扫描、
文件操作、OLE 拖放和自测。程序可以运行，但单文件已经不利于代码审查、定位上下文、
并行修改和 AI 辅助开发。

本次整理采用 AutoHotkey v2 的文本 `#Include` 做低风险模块化：

- 函数名、参数和调用点保持不变；
- 全局变量仍由 `PopDrop.ahk` 集中初始化；
- 自动执行段、worker 分流和消息注册次序保持不变；
- 各模块只按职责迁移代码，不引入新的运行时抽象。

因此这次变化主要降低源码导航成本，而不改变应用行为。

## 文件职责

`PopDrop.ahk` 现在只负责版本与常量、共享状态、依赖加载、进程启动和消息注册。
业务实现位于 `modules`：

| 模块 | 职责 |
| --- | --- |
| `PanelDialogs.ahk` | 主面板拥有的消息框和文件选择器 |
| `Configuration.ahk` | 配置初始化、迁移、校验与过滤规则 |
| `OpenApps.ahk` | 配置应用、动作模板与进程执行 |
| `CoreUtilities.ahk` | 持久化、路径和通用筛选工具 |
| `UiControls.ahk` | 原生控件构造、Owner Draw 与 DPI 修正 |
| `PanelUi.ahk` | 主面板构造、布局、显示模式和窗口行为 |
| `ScanCache.ahk` | 列表填充、目录扫描、缓存与 worker IPC |
| `ItemActions.ahk` | 项目打开、选择、固定及旧设置入口 |
| `ContextMenus.ahk` | 列表通知、来源管理和右键菜单 |
| `PointerInput.ahk` | 指针手势、选择语义、拖动检测和固定项排序 |
| `FileOperations.ahk` | 复制、移动、删除与 `IFileOperation` 回调 |
| `DropTarget.ahk` | OLE `IDropTarget` 与面板内投放 |
| `ShellDrag.ahk` | Shell 数据对象与 `IDropSource` |
| `SelfTests.ahk` | `--self-test` Windows 运行时测试 |
| `Lifecycle.ahk` | 退出清理与原生资源释放 |

既有独立组件 `ConfigDocument.ahk`、`FileManager.ahk`、`SettingsGui.ahk`、
`ExternalDrop.ahk`、`Preview.ahk` 和 `QuickPreview.ahk` 保持原位。

## 修改约定

1. 新功能优先放进职责最接近的模块，不再把实现追加到入口文件。
2. `PopDrop.ahk` 只新增启动期常量、共享状态、初始化调用和消息注册。
3. `OnMessage`、GUI 回调和 COM vtable 回调暂时保留自由函数形式，以免增加
   AutoHotkey 回调绑定和生命周期风险。
4. 跨模块状态暂时沿用现有全局变量；后续可按 `PanelState`、`ScanState`、
   `DragDropState` 分阶段收拢，但应逐子系统迁移并配套 Windows 回归测试。
5. 移动函数后同步维护 `tests/project_source.py` 可识别的 `modules\*.ahk`
   包含关系，确保静态契约覆盖整个主程序。

## 验证

跨平台静态契约：

```text
python tests/verify_display_menu_contract.py
python tests/verify_document_preview_contract.py
python tests/verify_file_manager_contract.py
python tests/verify_file_preview_contract.py
python tests/verify_folder_drop_contract.py
python tests/verify_module_layout_contract.py
python tests/verify_rename_contract.py
python tests/verify_scattered_fixes_contract.py
python tests/verify_source_management_contract.py
```

Windows 上还应执行：

```text
AutoHotkey64.exe PopDrop.ahk --self-test
powershell -ExecutionPolicy Bypass -File .\native\build.ps1
```

打包或复制源码时，`modules` 目录是主程序的必需组成部分。
