# PopDrop v1.1.0 交付说明

本源码包完成刷新、更新与内容呈现的专项迭代。应用版本为 1.1.0，配置版本为 27；
`config.ini` 继续作为可编辑配置，运行时文件索引迁移到 Windows WinSQLite3。

## 本次交付

- QuickLook/Seer 现在作为完整的外部预览会话参与 temporary 自动隐藏判断；查看器主窗口、
  同进程菜单/对话框及 owner 子窗口获得焦点时，PopDrop 保持在其下方且不会关闭查看器。
- 外部查看器获得焦点后不再被 PopDrop 的 Space/Esc 热键干扰。查看器关闭时会重新激活
  PopDrop 并恢复原列表焦点；QuickLook CLI 的异步窗口创建使用五秒有界握手保护。

- “极速显示”在多工作区共享同一来源时会把非当前工作区的扫描结果同时提交到内存与磁盘
  快照，切换后立即显示最新内容；监听器重建不会遗留阻断后续事件的 debounce 锁存。
- 固定项变化不再清空已有来源画面。扫描任务校验工作区/配置指纹，异常退出或超时会自动
  恢复一次；手动刷新可强制替换卡住的全量任务，最终失败会明确显示“加载失败，请点击刷新”。

- 设置导航新增独立“界面设置”页，并将“打开与文件操作”改名为“文件打开与操作”、
  “显示与过滤”改名为“文件显示与过滤”。界面缩放默认固定为 100%；旧配置中的
  `UiScale=System` 会自动迁移为 `UiScale=100`，不再叠加 Windows 系统缩放。
- 设置窗口新增“内容更新方式”页：默认“极速显示”保留缓存优先体验；“准确优先”会在呼出窗口和切换工作区时重新确认当前工作区内容。

- 已访问工作区使用内存/SQLite 快照立即恢复；同一工作区重复呼出不清空列表、不重建
  ImageList，也不因“显示窗口”本身启动全量扫描。
- 首次扫描按来源发布。扫描完一个文件夹就提交该文件夹的完整结果，来源之间无需等待；
  50～75 ms 内到达的结果自然合并为一次 UI 提交。
- 扫描保持单 worker 顺序 I/O，本地来源排在网络来源之前，避免离线网络盘阻挡本地来源。
- 所有工作区的本地来源共享异步 `ReadDirectoryChangesW` 监听器。事件在 120 ms 内折叠，并只重扫变化来源；
  缓冲区溢出、无效/报错/被关闭句柄会触发该来源校准和监听重建。
- 进程启动、跨日首次呼出、睡眠恢复、配置变化和手动刷新执行条件校准。新增
  `ConsistencyCheckMinutes=60`，默认按分钟检查点在窗口隐藏后校验 Dirty、监听失败或不可监听的来源。
- Recent 与来源结果分离；关闭近期栏时完全跳过。UNC、映射盘、WebDAV 目标不在扫描
  关键路径同步 `FileExist`，离线快捷方式不再拖慢无来源工作区。
- 缩略图首帧只取 Shell 缓存或类型图标，Full 模式随后逐项增强；跨刷新复用 ImageList
  和图标缓存。列表提交后强制完成绘制，再更新独立项目计数。
- 来源更新保留同工作区的多选、焦点与顶部可见位置。自动状态固定为短文案，并对
  180 ms 内完成的更新隐藏“更新中”。
- `index.db` 优先放在 `软件目录\cache`。目录不可写或位于网络盘时回退到
  `%LOCALAPPDATA%\PopDrop\cache`；数据库打开/迁移异常时隔离为 `.corrupt-时间` 后重建，
  WinSQLite3 不可用时回退每工作区 INI 快照。

## 兼容与迁移

- 配置自动升至版本 27，并补写 `ConsistencyCheckMinutes=60`，旧版 `ConsistencyCheckHours`
  自动换算，不改变工作区、来源、固定项
  或任何真实文件。
- 首次没有 SQLite 快照时会尝试读取旧 `scan-cache-v4.ini` 作为种子；失败可安全忽略。
- `PopDropTransfer` 源码版本已升至 1.1.0，协议本身未变。正式发布必须在 Windows 上
  重新构建 x64/x86 Helper，不能沿用源码包中的历史二进制。

## 验证

跨平台验证：

```powershell
python -m unittest discover -s tests -v
```

Windows 交付门禁：

```powershell
AutoHotkey64.exe .\PopDrop.ahk --self-test
powershell -ExecutionPolicy Bypass -File .\native\build.ps1
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

还应在 Windows 10/11 实机覆盖：无来源且 Recent 开/关、离线 UNC 快捷方式、SSD/HDD
多来源、递归大目录、连续复制/重命名/删除、睡眠恢复、快速切换工作区、删除/损坏数据库。

当前工作环境未提供 AutoHotkey、Windows Shell/OLE、PowerShell 或 MSVC，因此这里完成的
自动验证是 Python 静态/契约测试；Windows 运行时自测与 Helper/Ahk2Exe 构建必须在
Windows 构建机执行。构建脚本会在发布前再次执行上述门禁。
