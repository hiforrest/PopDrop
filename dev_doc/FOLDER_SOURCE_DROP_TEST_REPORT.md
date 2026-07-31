# 拖拽文件夹快速添加来源：测试与兼容说明

## 自动测试

Windows 上使用：

```powershell
AutoHotkey64.exe PopDrop.ahk --self-test
```

新增的内置自测试覆盖：

- 空路径、纯文件、纯目录、混合选择和不存在路径的载荷分类；
- 内部拖拽零 `GetData` 分类；
- 外部异步 HDROP、URL、虚拟文件、PNG/DIB 信号禁止预读；
- 稳定同步本地 HDROP 允许预读一次，Drop 复用 Session 缓存；
- 只有 `FoldersOnly` 可用 AddSource；混合选择与当前工作区重复路径拒绝；
- AddSource 在无修饰键、Ctrl、Shift 下均为 COPY，COPY 不可用时为 NONE；
- 拖拽结束状态清除顶部文件夹模式；
- 单个和多个 Files 来源创建、原顺序追加、当前工作区去重；
- 跨工作区相同路径、同名唯一化、部分无效候选；
- 注释、未知键、UTF-16LE BOM、CRLF、六个布局锚点保留；
- 注入配置事务失败后，活动配置字节级不变。

非 Windows 环境可运行：

```bash
python3 tests/verify_folder_drop_contract.py
```

该检查验证所有 `#Include`、AHK 大括号结构、DragEnter 无直接
`ReadHDropPaths()`、安全预读门禁、异步 helper 接管条件、Session 缓存优先级、
AddSource COPY-only 分支、集中清理、共享来源序列化和文档同步。

本次交付环境已执行上述 Python 静态契约检查并通过。当前 Linux 容器没有
AutoHotkey、Windows OLE 或 Shell 运行时，因此内置 AHK 自测试和下述桌面兼容矩阵
未在此环境执行。

## 外部 HDROP 安全判定

预读仅在以下条件全部满足时发生：

1. 数据适配器为 `CF_HDROP`；
2. PopDrop 内部拖拽，或外部对象不支持 `IDataObjectAsyncCapability`；
3. 格式探测没有明确 URL；
4. 没有 `FileGroupDescriptorW` / `FileContents` 虚拟文件信号；
5. 没有 PNG、DIBV5 或 DIB 图片信号。

内部拖拽直接使用 `ActiveInternalDragContext.Paths`，不读取 `IDataObject`。外部安全预读
一旦尝试，Session 会记录 `HDropReadAttempted` 和 `HDropReadCount`；成功、空结果或
异常都不会在 Drop 再次读取。外部异步 HDROP 投放到 Files 时仍由
`HDropShouldUseDirectAsyncTakeover()` 把数据对象直接交给 helper，主进程保持零提取。

## Windows 人工兼容矩阵

以下项目需要在真实 Windows 10/11 桌面会话中验收；自动测试不能模拟来源程序自己的
OLE 生命周期、Shell 冲突 UI、多显示器坐标或 DPI：

| 场景 | 重点检查 | 当前状态 |
| --- | --- | --- |
| 资源管理器：文件 | 不显示顶部模式；Files/Launcher/固定项行为不变 | 待 Windows 实测 |
| 资源管理器：单/多文件夹 | 显示 70/30 双区域；添加顺序和 COPY 光标 | 待 Windows 实测 |
| 资源管理器：混合选择 | 不显示顶部模式；下方复制/移动仍可用 | 待 Windows 实测 |
| PopDrop 内部拖拽 | 立即分类；Files 默认移动；AddSource 不移动 | 待 Windows 实测 |
| Directory Opus 本地文件夹 | 仅稳定同步 HDROP 显示顶部模式 | 待 Windows 实测 |
| QQ、微信 | 现有稳定 HDROP 和外部接收行为不变 | 待 Windows 实测 |
| Chrome、Edge | 不提前生成文件；无重复 HDROP；异步 helper 唯一读取 | 待 Windows 实测 |
| 本地磁盘与 UNC 网络目录 | 可访问目录可添加；离线/失效逐项失败 | 待 Windows 实测 |
| 空工作区 | 首批来源按拖拽顺序追加并后台刷新 | 待 Windows 实测 |
| temporary / always_on_top / normal | 暂停计数配对，结束后工具栏恢复 | 待 Windows 实测 |
| 100% / 125% / 150% / 200% DPI | 顶部区域不越界，ListView 不跳动 | 待 Windows 实测 |
| 拖入后离开、不放下 | 无文件操作、无配置写入、工具栏恢复 | 待 Windows 实测 |
| 快速拖入、取消、再次拖入 | 无残留高亮、无暂停计数泄漏 | 待 Windows 实测 |
| 保存期间配置被外部修改 | 事务拒绝覆盖，活动配置保持原状 | 待 Windows 实测 |

## 已知限制

- 为保护延迟渲染来源，任何声明异步能力或带 URL、虚拟文件、图片信号的外部 HDROP
  都不会在拖动阶段显示“添加为来源”；即使它最终实际落地为本地目录也保持 Unknown。
- 设置窗口存在未保存草稿时，AddSource 目标不可用，以免随后保存旧草稿覆盖新来源。
- 文件夹路径在拖动期间可用、放下前失效时按逐项失败处理；不会尝试解析 `.lnk`。
- 本次不提供撤销按钮；原子保存和 `config.ini.bak` 提供可靠恢复基础，但没有伪撤销。
