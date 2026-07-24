# PopDrop 基础设置界面实施报告

## 实现概览

- 运行时：AutoHotkey v2.0，未混用 v1 语法。
- 界面：标准 `Gui`、`Tab3`、`ListView`、`GroupBox`、`Edit`、
  `DropDownList`、`Radio`、`CheckBox`、`Hotkey` 和 `Button`。
- 页面：常规、文件来源、文件操作、过滤与显示。
- 草稿：打开窗口时深拷贝来源、扩展名数组、排除路径、软件、目标和最近目标；
  控件事件只更新草稿，取消不写磁盘、不更新运行时。

## 配置与兼容

- `[General] EscapeHidesPanel=0|1`
- `[TransferFavoriteLabels] PathNNN=<显示名称>`
- `[ExcludedFolderNames] NameNNN=<精确文件夹名称>`
- `[SourceExclude:<SourceId>] PathNNN=<来源内相对路径>`
- `[SourceAllow:<SourceId>] PathNNN=<来源内相对路径>`
- `ConfigVersion=9`

旧配置缺少上述字段时分别回退为：Esc 隐藏启用、目标使用文件夹名、无新增排除规则。
旧的 `[Folders]`、`[Folder:<名称>]`、`[Sources]`、`[OpenApps]`、
`[OpenApp:<ID>]`、`[TransferFavorites]` 和 `[RecentTargets]` 格式继续使用。

## 保存和运行时应用

保存前完成来源/路径/枚举/数字/软件/目标/排除名称及快捷键验证。父子来源、
离线来源、无效旧软件和离线旧目标作为可确认警告。验证通过后先复制
`config.ini.bak`，再通过已有 `AtomicConfigEdit` 临时文件替换。写入成功后重新加载
一次运行时设置、应用窗口和快捷键，并启动一次后台扫描；应用失败会尝试从备份回滚。

## 未加入的选项

开机自动启动在当前源码中没有业务实现，因此未添加无效开关。缩略图缓存、扫描间隔和
内部 worker 参数没有暴露。Esc 原来是固定行为，本次接入了可配置开关；热键、窗口模式、
每来源显示数量、最近文件和现有两种排序方式均复用已有能力。

## 验证

跨平台静态回归共 36 项，覆盖旧单击打开状态机、默认打开统一入口、配置迁移、四页设置
结构、草稿隔离、稳定 ID 行映射、排除规则进入 worker、备份/原子写入和 AHK 分隔符检查。
Linux 构建环境无法启动 Windows 原生 AutoHotkey GUI；100%/125%/150% DPI、系统快捷键
占用、UNC/离线网络路径和真实配置写入失败回滚仍需在 Windows 上做最终人工冒烟测试。

底栏采用明确的逻辑坐标放置在 `Tab3` 下方，避免相对坐标以最后一个页面控件为参照、
导致按钮落入 Tab 客户区并被覆盖。

“添加排除名称”使用设置窗口拥有的模态子窗口；旧配置通过
`GlobalExcludedNamesInitialized` 标记完成一次性 `.git` 默认值迁移。
