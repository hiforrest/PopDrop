# PopDrop 单击打开文件：实施与验证报告

## 修改文件

- `PopDrop.ahk`：配置、迁移、设置窗口、有效模式、鼠标状态机、去重和统一打开入口。
- `config.ini`：配置版本升级为 8，新增安全默认值和来源配置示例。
- `tests/test_single_click_open.py`：新增单击打开专项逻辑与接线测试。
- `tests/test_v07_static.py`：更新配置版本和默认值断言。
- `README.md`、`USAGE.md`、`CHANGELOG.md`：新增使用方法、兼容规则和变更说明。

## 配置

```ini
[General]
ConfigVersion=8
OpenFileMode=DoubleClick

[Folder:下载]
OpenFileMode=Inherit
SourceId=source-xxxxxxxx

[Sources]
Order=source-xxxxxxxx

[Source:source-xxxxxxxx]
Name=下载
Path=D:\Downloads
OpenFileMode=Inherit
```

全局允许 `DoubleClick` / `SingleClick`；来源允许 `Inherit` /
`SingleClick` / `DoubleClick`。缺失、空值或未知值分别回退为
`DoubleClick` 和 `Inherit`。迁移使用临时文件原子替换，不删除未知字段或注释。

来源稳定 ID 首先读取 `[Folder:名称] SourceId`，否则从来源注册表按名称、再按规范化
路径恢复，最后才生成确定性 ID。因此单独修改来源路径、单独重命名或调整顺序不会丢失
打开方式。

## 有效模式

- 普通来源行按其显示分组的 `SourceId` 查询来源设置。
- `Inherit` 回到全局设置。
- 固定项和最近文件始终使用全局设置，不根据物理路径猜来源。
- 直接子文件夹保留所属来源上下文，但文件夹本身始终只由双击激活。

设置保存后只重新加载配置；现有行在事件发生时查询最新模式，不依赖重建。

## 鼠标和拖拽

左键按下记录显示项键、路径、位置、时间、选择快照、修饰键、命中区域、拖拽和取消
状态。移动使用 Windows `SM_CXDRAG` / `SM_CYDRAG`。超过阈值后，无论拖拽完成、
放回原处或取消，本次释放都不会打开。

只有同一显示项、无修饰键、非文件夹、非框选、非拖拽、非子控件且未取消的左键释放
才会在 `SingleClick` 模式打开。已多选项目在按下时恢复选择快照以支持整组拖拽；若
最终没有拖动，释放时收敛到当前文件并只打开该文件。

右键、滚轮、水平滚轮、滚动条、取消模式、鼠标捕获丢失、焦点丢失、面板隐藏和列表
刷新都会取消待处理激活。

## 双击去重

第一次合法释放立即打开，并记录：

- 显示区域（来源、固定项或最近文件）；
- 来源稳定 ID（适用时）；
- 规范化路径；
- `A_TickCount` 时间。

同一显示项在 Windows `GetDoubleClickTime` 时间内的第二次释放被抑制；单击模式下的
ListView 双击通知也被忽略。不同文件不互相抑制，刷新后对象重建也不会绕过去重。
双击模式仍只由现有 `DoubleClick` 事件打开。

## 统一默认打开

普通文件的单击、双击、`Enter` 和右键“打开”最终都调用
`OpenItemWithDefaultApplication`，由 `Run(path)` 使用 Windows 默认文件关联。
配置软件列表只在用户明确选择“用某软件打开”时使用。

## 自动验证

在 Linux CI 环境执行：

```text
python -m unittest discover -s tests -v
Ran 22 tests
OK
```

覆盖安全回退、来源覆盖/继承、固定项/最近文件全局规则、释放条件、系统拖拽阈值、
系统双击时间、统一打开入口、取消消息、配置迁移，以及全部原 v0.7 静态回归测试。

## 仍需 Windows 人工验证

当前环境没有 Windows、AutoHotkey v2、真实 Shell 拖放目标或高 DPI 多显示器，无法
实际启动 GUI。建议在 Windows 上完成最终冒烟测试：设置窗口布局、原生 ListView
事件时序、习惯性双击、跨程序 OLE 拖放、固定项重排、触摸板滚动、捕获丢失和
125%/150%/200% DPI。源码已保留 `--self-test`，可在 Windows 运行时执行模式解析
安全回退测试。

## 实测反馈修复

首次交付后，Windows 实测发现正常鼠标释放期间的 `WM_CAPTURECHANGED` 可能先于脚本的
`WM_LBUTTONUP` 处理到达，使单击手势被当成捕获丢失而取消。修正版同时监听 ListView
原生 `Click` 释放通知，并仅在物理左键仍按下时把 `WM_CAPTURECHANGED` 视为取消。两条
释放入口共用同一状态机，先到者会消费手势，因此不会重复打开。
