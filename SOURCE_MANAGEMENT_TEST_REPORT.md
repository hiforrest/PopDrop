# 主面板来源管理：测试与兼容说明

## 自动测试

Windows 10/11 上运行完整 AHK 自测试：

```powershell
AutoHotkey64.exe PopDrop.ahk --self-test
```

本次新增自测试覆盖：

- 缩略图、列表、滚动和缩放后的来源标题矩形命中；
- 标题边界、固定项标题、空工作区和离线来源；
- WorkspaceId/SourceId 精准导航、同名同路径隔离和目标来源消失；
- 设置草稿的保存、放弃、取消决策；
- 活动传输的 TargetSourceId 门禁及缺少身份时的保守路径门禁；
- Files、Launcher、离线来源和最后一个来源的配置移除；
- SourceOrder、来源专属节、跨工作区同路径、固定项、最近记录、常用目标及兼容快照；
- UTF-16LE BOM、CRLF、人工注释、未知键和六个布局锚点；
- 注入原子事务失败后活动配置字节级不变。

非 Windows 环境可运行：

```bash
python3 tests/verify_folder_drop_contract.py
python3 tests/verify_source_management_contract.py
```

第二项检查来源标题命中调用结构、文件行优先级、菜单文字、自动隐藏暂停、`Menu`
类名不被同名局部变量遮蔽、稳定身份设置精准导航、传输门禁、原子配置清理、后台扫描、
空工作区提示和文档同步。第一项继续保护此前
拖拽添加来源与外部 HDROP 单次读取链路。

本次 Linux 交付环境的实际结果：

- `python3 -m py_compile ...`：通过；
- `verify_folder_drop_contract.py`：PASS；
- `verify_source_management_contract.py`：PASS；
- AutoHotkey `--self-test`：未执行（环境没有 Windows/AutoHotkey）；
- 原生 `SyntheticDataObjectTest.cpp`：未重新编译或执行（环境没有 Windows SDK）。

## 分组标题命中

鼠标坐标先从 GUI 客户区转换为 ListView 客户区。命中优先使用原生
`LVM_HITTEST + LVHT_EX_GROUP_HEADER`；若系统没有返回分组扩展标记，则读取
`LVM_GETGROUPRECT(LVGGR_HEADER)`。个别系统若 Header 子矩形不可用，再以整个分组矩形
和该组第一个项目的原生边界推导标题底边。整个过程没有视图、DPI 或像素位置常量。

只有同时具有稳定 SourceId 且类型为 Files/Launcher 的 `GroupDropTargets` 描述符可以
打开来源菜单。固定项和空工作区占位不会进入来源管理路径。

## 配置和真实文件安全

来源删除回调不调用文件删除、目录删除、回收站或 Shell 文件操作。原子事务只修改临时
配置副本：

1. 校验目标仍是当前工作区并且 SourceId 未被其他工作区引用；
2. 从目标工作区 SourceOrder 删除 SourceId；
3. 删除 Source、SourceIgnore、SourceExclude、SourceAllow 和其他明确归属于该
   SourceId 的扩展节；
4. 完整验证所有工作区；
5. 原子替换配置，成功后才重新加载运行时对象和界面。

若保存后的运行时重载失败，会尝试使用保存前备份恢复配置。真实来源目录从不参与事务。

## Windows 人工兼容矩阵

以下项目必须在真实 Windows 桌面会话中验收：

| 场景 | 重点检查 | 当前状态 |
| --- | --- | --- |
| 缩略图/列表视图 | 标题右键菜单正确；具体文件仍显示文件菜单 | 待 Windows 实测 |
| 垂直/水平滚动 | 命中可见标题对应的正确 GroupId | 待 Windows 实测 |
| 100%/125%/150%/200% DPI | 标题边界无偏移、边界外不误触 | 待 Windows 实测 |
| Files/Launcher/离线来源 | 两类来源都有菜单；离线来源可设置和移除 | 待 Windows 实测 |
| 固定项/空工作区 | 不出现“移除来源”菜单 | 待 Windows 实测 |
| 左键来源标题 | 继续打开真实来源文件夹 | 待 Windows 实测 |
| 文件右键、Shift+右键、Shift+F10 | PopDrop/系统菜单切换保持不变 | 待 Windows 实测 |
| 设置窗口关闭/打开/最小化 | 精准跳转且不创建第二窗口 | 待 Windows 实测 |
| 同名来源、路径已修改 | 仅按 WorkspaceId/SourceId 选中 | 待 Windows 实测 |
| 设置在其他页面 | 切到“当前工作区”并显示全部来源控件 | 待 Windows 实测 |
| 未保存草稿：保存/放弃/取消 | 三条路径均不丢失或误覆盖配置 | 待 Windows 实测 |
| 目标来源已消失 | 正确工作区、空选择和明确提示 | 待 Windows 实测 |
| 移除 Files/Launcher/离线/最后来源 | 分组立即消失；最后来源显示新占位 | 待 Windows 实测 |
| 其他工作区同路径来源 | 完全不受影响 | 待 Windows 实测 |
| 固定项、Windows 最近记录、常用目标 | 移除来源后全部保留 | 待 Windows 实测 |
| 活动 Chrome/Edge/QQ/微信传输 | 阻止移除且传输不中断 | 待 Windows 实测 |
| 扫描正在进行时移除 | 旧 generation/fingerprint 结果不重新显示来源 | 待 Windows 实测 |
| temporary/always_on_top/normal | 菜单和确认框期间面板不隐藏，计数平衡 | 待 Windows 实测 |
| 拖拽添加来源及 Files/Launcher/Pinned 投放 | 原有拖放语义和 HDROP 安全链路不变 | 待 Windows 实测 |
| 注入配置写入/验证失败 | 分组、内存和设置窗口保持原状态 | 待 Windows 实测 |

## 当前环境与已知限制

当前交付环境不是 Windows，不能执行 AutoHotkey、OLE、ListView 原生通知、Shell 菜单和
真实 DPI 测试。上述两项 Python 静态契约检查会在交付前执行；Windows AHK 自测试和
人工矩阵不会被标记为已验证。

- “刷新此来源”当前安全退化为刷新当前工作区，不扩展扫描 IPC 协议。
- 设置窗口正在显示一个子对话框时，精准跳转或移除会要求先完成该子窗口。
- 第一版不提供跨会话撤销；配置备份用于失败恢复，不作为伪撤销入口。
- 无 TargetSourceId 的旧活动批次只有在目标路径相同时才保守阻止移除。
