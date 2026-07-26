# PopDrop v0.9.0 开发报告

## 默认右键菜单

新增共享配置 `[General] DefaultContextMenu`，允许 `PopDrop` 和 `System`。解析器对大小写
不敏感；缺失、空值和未知值统一回退 `PopDrop`，未知非空值进入现有配置警告列表。
设置值进入隔离草稿、变更签名、保存校验和布局感知写入；只有原子保存成功并重新
`LoadSettings()` 后才改变运行时，失败继续使用既有备份回滚链路。
该项是带安全默认值的可选共享键，不需要结构迁移，因此保持 `ConfigVersion=14`，避免
仅为新增可选行为制造无意义的升级事务；新建配置和设置页保存都会显式写入该键。

主文件区、固定项和最近文件区的 `ContextMenu` 事件现在统一调用集中分派器：

- 普通操作使用默认菜单，Shift 操作通过同一解析器反转菜单；
- 鼠标 Shift 状态在 `WM_RBUTTONDOWN` 时保存，避免事件到达前松键造成误判；
- `WM_KEYDOWN/WM_SYSKEYDOWN` 区分 AppsKey 与 `Shift + F10`：菜单键始终使用默认菜单，
  只有确认的 `Shift + F10` 才反转；
- `Shift + F10` 不再另注册 AHK 热键，由原生控件事件唯一处理，消除双弹路径；
- 键盘事件缺少显式行号时回退到焦点行，再回退到有效选中行；
- 分派期间使用重入保护，两种菜单继续复用自动隐藏暂停计数。

系统菜单仍只向一个父 ShellFolder 提交 child PIDL。同父目录多选保持整组选中；跨父
目录时只提交当前右击或聚焦项目，并先写入状态栏提示“所选项目来自不同位置；系统菜单
仅作用于当前项目。”PopDrop 菜单继续保留跨目录多选语义。只有 PopDrop 菜单为默认时
才显示底部“更多系统操作… Shift + F10”，系统菜单为默认时不显示循环入口。

AHK `--self-test` 增加配置回退与四格选择矩阵断言；跨平台测试新增菜单事件唯一入口、
AppsKey/F10 区分、两区域集中分派、选择退化、自动隐藏平衡、设置草稿生命周期、配置
编码和文档契约检查。本次 Linux 环境执行 86 项测试，全部通过。

## 下载完成即时呈现

传输状态轮询现在把“文件已安全落盘”和“批次后台收敛完成”视为两个独立刷新时点。
每个任务首次报告 `Completed`，或带有最终路径的 `NeedsAttention` 时，立即请求后台
扫描；扫描仍由原有 worker 完成并自动合并并发请求，不在 UI 线程枚举目录。

图片质量比较、五秒晚到候选观察、较大图片原子替换和较小副本清理均保持在 helper
后台执行。批次进入最终状态时仍会再请求一次扫描，确保面板反映后台替换或删除后的
最终结果。每个任务 ID 只触发一次即时呈现刷新，普通进度变化不会引起目录扫描。

## v0.9.0 工作区

工作区模型把共享设置与来源作用域明确分离：`[Workspaces]` 保存稳定 ID 顺序和当前
工作区，`[Workspace:<ID>]` 保存显示名称与 `SourceOrder`，`[Source:<ID>]` 保存完整
来源专属配置。显示名称不参与身份解析，复制时为工作区及来源生成新 GUID。

旧配置迁移继续复用 `PopDropConfigDocument` 和 `AtomicConfigEdit`。迁移先创建 `.bak`，
把 `[Folders]` 顺序、`[Folder:名称]` 覆盖、已有 `SourceId` 及来源规则写入默认工作区，
然后通过六锚点、重复节/键、BOM 和原子替换校验。旧节保留为兼容快照。

扫描 IPC 升级后在请求、结果和缓存指纹中同时携带 `WorkspaceId`。主进程验收结果时要求
generation、fingerprint 和 WorkspaceId 全部匹配；快速连续切换只会把旧 worker 标记为
待刷新，不能把旧结果提交给当前视图。

设置窗口继续使用隔离草稿，但草稿现在包含全部工作区。当前来源数组只是当前工作区的
引用；保存一次性校验所有工作区，然后在一个配置事务中写入共享设置和工作区来源。
切换与管理前复用三路径保护，保存失败保留草稿。

## v0.8.8 跨适配器统一图片收敛

v0.8.7 的 EndOperation 后置观察仍只在 `request.adapter == "HDrop"` 且
`ExtractHDrop()` 产生图片计划时启用。浏览器的数据格式优先级允许同一类网页图片走
`FILEDESCRIPTORW/FILECONTENTS`、PNG/DIB 或公开 URL；这些路径保存的大图同样可能与
浏览器自行写入下载目录的小图并存，但不会进入 HDROP 专用观察。这解释了实机仍稳定
出现“大图先一秒、小图带 `(1)` 后缀随后出现”的结果。

新实现把 `HDropReconcileContext` 提升为与适配器无关的
`ImageReconcileContext`：

- 在选择任何适配器前保存目标目录基线；
- HDROP 可继续附带其明确网络来源，其余适配器在落盘后从统一任务状态中的
  `finalPath` 自动收集图片计划；
- `VirtualFiles`、`HDrop`、PNG、DIB/DIBV5、URL 和 URL 重试产生的图片全部进入相同
  后置收敛；
- 同批多个合法最终图片路径会整体排除，不会互相误判为延迟副本；
- 只有相对传输开始基线新建或改变、名称归一后属于本批、且不是任何任务最终路径的
  文件才允许删除或替换。
- 后置观察按每个规范名称构造窄范围候选模式并以 200 ms 节流轮询，不在五秒窗口内
  反复枚举整个下载目录。

因此浏览器无论把被跟踪的大图交给哪种标准 Windows 数据格式，晚到的
`name (1).jpg` 都会与 `name.jpg` 按 WIC 像素尺寸和字节数比较。

反复实测无变化还暴露了部署层风险：`ResolveTransferHelper()` 原先始终优先脚本目录
根部 EXE，`build.ps1` 却输出到 `native\bin\<架构>`。只要根部残留旧版本，重新构建
不会改变实际执行组件。源码模式现改为优先 `native\bin`，编译发布模式仍优先同目录。
helper 状态新增 `HelperVersion=0.8.8`，`WaitForTransferHandshake()` 强制与
`APP_VERSION` 比较；旧 helper 因缺少版本字段也会被拒绝并终止。

## v0.8.7 EndOperation 后置收敛

实机文件时间给出了新的因果证据：两组大小图均为 helper 保存的大图先创建，另一张小图
约一秒后创建。v0.8.6 只在 `GetData(CF_HDROP)` 前后和最终落盘前扫描候选；而 helper
原先在落盘后调用 `IDataObjectAsyncCapability::EndOperation()`，随后立即退出。来源
程序可以把 `EndOperation` 当作继续或完成自身拖放动作的信号，因此晚到文件不可能被
此前的任何去重阶段看到。

v0.8.7 增加 `HDropReconcileContext`，在 `EndOperation` 前保存目标目录的精确快照和
每个已保存图片的最终路径、WIC 尺寸、字节数、任务行及安全来源。调用
`EndOperation` 后，后台 helper 继续执行五秒有界观察：

- 只检查相对于结束前快照新建或发生变化的文件；
- 文件名必须与本批图片的规范候选键匹配；
- 排除当前已选择的最终路径和未变化的既有文件；
- 等待晚到文件关闭写句柄后再读取尺寸，避免比较半成品；
- 晚到图片更小或完全相同时删除晚到副本；
- 晚到图片像素更大时，写入隐藏 part 后原子替换原最终文件，再删除晚到路径；
- 替换后重新应用 Zone Identifier / `IAttachmentExecute` 安全来源；
- 清理或安全标记失败时转为 `NeedsAttention`，不会伪装成功。

批次在观察期间保持 `Finalizing`，完成后才触发最终状态和刷新；主面板不等待该过程，
全局传输槽也已提前释放，因此不会阻塞其他下载。

## v0.8.6 网页图片质量收敛

v0.8.5 的“目标目录候选绝对优先”解决了同目录重复复制，却会在浏览器先写入缩略图、
稍后提供缓存原图时保留较小版本。新的实现把一次拖放中的网页图片视为候选组，而不是
互相独立的文件：

- `WaitForPathReady()` 在后台 helper 中等待候选写句柄关闭，比较时不再使用仍在增长的
  瞬时大小；
- WIC 解码第一帧元数据并取得真实宽高，选择顺序为像素面积、文件字节数、目标路径；
- 数字副本后缀在图片候选键中被规范化，`photo.jpg` 与 `photo (1).jpg` 可以正确归组；
- Chromium 在渲染 `CF_HDROP` 时可能把缩略图直接写入默认下载目录，却不把该路径列入
  DROPFILES。helper 在 `GetData` 前取得目标目录文件快照，随后只把名称匹配、相对快照
  新建或发生变化的图片补入候选组；未变化的既有文件不参与替换；
- 若原图来自缓存而缩略图已经位于目标，原图先分块写入同卷隐藏 part，刷盘后使用
  `MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH` 原子替换精确的小图路径。该路径
  必须来自本批候选且仍位于目标目录，不会按名称覆盖任意旧文件；
- 若较大候选本身已在目标，则直接认领它并删除本批中其余较小目标候选。

AHK 启动告警的根因是 `adoptedPaths := []` 被误插入 `PerformRecycleDelete()`，
实际使用它的 `PerformShellFileOperation()` 没有初始化。初始化现已移动到正确函数，
并由静态测试约束其必须出现在第一次 `.Push()` 之前。

## v0.8.5 同目录来源认领

继续实测后，重复文件仍可能在只执行一次 `GetData(CF_HDROP)` 时出现。新的证据与路径
模型表明：浏览器可把延迟文件自身建立在默认下载目录，而 PopDrop Files 来源也指向
同一目录。此时来源路径已经是最终目标文件；旧 helper 仍执行
`source → hidden part → unique final`，于是同目录内产生自动改名副本。浏览器持有原
文件继续写入时，还会形成“一份较小、一份稍后完成”的尺寸差异。

helper 的 `SameDirectoryPath()` 优先比较目录句柄的卷序列号与文件索引，无法获得可靠
标识时才回退到完整路径比较。命中后进入 `WaitForSourceReady()`：

- 不创建 part 或目标文件；
- 用不包含 `FILE_SHARE_WRITE` 的只读打开检测来源写句柄是否已经关闭；
- 每 100 ms 可取消轮询，状态写入仍受 125 ms 节流；
- 未完成时只显示已观察字节，不提供百分比和剩余时间；
- 最长等待 30 分钟，来源退出、取消、超时和其他 Win32 错误分别结束；
- 完成后以原来源路径作为 `finalPath`，必要时调用 `IAttachmentExecute`。

同名 HDROP 候选去重也调整了优先级：目标目录中的候选优先于初始大小。否则浏览器刚
建立的目标文件可能暂时较小，旧“保留较大项”规则会选择另一个 Temp 候选并复制回目标，
再次形成 `(2)`。只有候选是否已在目标一致时才继续按已知大小选择。

同步外部 HDROP 在 `PerformShellFileOperation()` 中也记录 `adoptedPaths`。只有
`FromDrop=true && SourceKind=External` 才会认领同目录路径；上下文菜单主动选择
“复制到当前目录”仍交给 Shell 创建副本。纯认领批次排队一次扫描并返回成功结果，
混合批次与其他 Shell 成功项共用一次刷新。

## v0.8.4 异步 HDROP 零预读

v0.8.3 仍把“明确 URL”作为直接接管异步 HDROP 的条件。实机截图和行为证明另一条路径
仍存在：浏览器对象支持异步能力，但当前 URL 格式查询没有命中；AHK 因此先调用
`ReadHDropPaths()`，随后发现路径位于 Temp，才调用 `CreateExternalTransfer()`。
helper 缺失时后者报错，但前一次 `GetData(CF_HDROP)` 已经让浏览器生成了一张图片。

v0.8.4 删除 `HDropRequiresAsyncTakeover(paths, asyncInfo)` 及其调用。新的决策只依赖：

- 来源是外部应用；
- 目标是普通 Files 来源；
- 适配器为 `CF_HDROP`；
- 数据对象声明 `IDataObjectAsyncCapability`。

满足条件时直接进入 `CreateExternalTransfer()`；该函数首先解析 helper，成功后才进行
COM marshaling。主进程不会读取路径。内部拖放和同步外部 HDROP 才进入
`ReadHDropPaths() → ExecuteLocalDrop() → IFileOperation`。因此 Drop 中不再存在
“读取路径后又把同一数据对象交给 helper”的控制流。

## v0.8.3 单次延迟渲染接管

第二轮实机反馈提供了决定性证据：首个文件瞬间完成且不进入传输中心，第二个文件稍后
才由 helper 完成；将 `native` 改名后虽然 PopDrop 报 helper 缺失，首个文件仍会出现。
这与 Chromium 延迟渲染的行为一致：旧 Drop 路径先由 AHK 调用
`GetData(CF_HDROP)` 读取路径，再把同一个 `IDataObject` 交给 helper，helper 又调用
一次 `GetData(CF_HDROP)`。每次读取都可能让浏览器启动一条独立文件生成通道。

v0.8.3 对“外部来源 + Files 目标 + 明确 URL + 异步能力”的 HDROP 改为：

1. 在读取任何 HDROP 数据前检查 helper 是否存在；
2. 直接将 `IDataObject` marshaling 给 helper；
3. helper 完成唯一一次 `GetData(CF_HDROP)`；
4. 若这一次返回多个同名网页候选，再在 helper 内按大小稳定收敛；
5. helper 缺失或接管失败时不读取 HDROP，因此不会留下传输中心之外的文件。

普通资源管理器、QQ、微信没有网页 URL 特征，仍由 AHK 读取一次稳定路径并交给原
`IFileOperation`，没有改写回归基线。

同版还新增 `IFileOperation` 回收站删除（右键“删除”和 `Delete` 键），不使用
`FileDelete/DirDelete` 永久删除回退；缩略图默认策略改为 `Full`，实际
`IShellItemImageFactory` 标志继续只在 `Fast` 时附加缓存限定标志 `0x10`。

## v0.8.2 链接图片重复接收修正

实机反馈表明，链接包裹图片的重复内容不一定进入异步 Temp HDROP helper：浏览器可能
提供非 Temp `CF_HDROP`，也可能提供同一批次内的多个虚拟文件描述符。v0.8.2 以
“同一数据对象存在明确 URL + 安全文件名相同”为网页重复候选条件：

- `CF_HDROP` 在 Drop 后、`IFileOperation` 前按文件名和大小收敛；
- 虚拟文件在 `GetData(FILECONTENTS)` 前按描述符名称和已知大小收敛；
- 大小不同保留较大项，等大/均未知时保留第一项；
- 没有明确 URL 的本地或虚拟多文件不参与去重。

因此第二个网络流不会被请求，而不是下载完成后再删除重复文件。

## v0.8.1 实机反馈修正

- 传输中心改用任务内容签名判断真实变化，重建行时保存并恢复批次/项目选择。
- 成功历史统一显示 100%，原生 helper 保存全程平均速度。
- 下载入口与主状态栏合并为一行右对齐，并增加 300 ms 启动延迟、800 ms 最短活动
  展示、3 秒完成提示及需要查看后才消失的失败状态。
- 浏览器异步临时 `CF_HDROP` 中的同名图片候选按大小保留更完整文件；稳定本地文件
  链路不执行这项去重。
- 设置页分组标题改为“下载”。

## 实现摘要

本次在第一期 `IDropTarget`、目标识别、`IFileOperation` 和 temporary 生命周期之上，
增加独立的格式分类、`TransferManager` UI 模型和最小原生后台 helper。第一期稳定本地
路径链路没有重写：资源管理器、当前 QQ/微信提供的 `CF_HDROP` 仍在 Drop 后读取，并
调用原 `ExecuteLocalDrop()` / `PerformShellFileOperation()`。

格式选择固定为：

```text
CF_HDROP
  → FileGroupDescriptorW + FileContents
  → PNG / CF_DIBV5 / CF_DIB
  → UniformResourceLocatorW/A / text/uri-list
  → Unsupported
```

`DragEnter/DragOver` 只执行 `QueryGetData`，诊断模式才额外
`EnumFormatEtc`；两处均不调用 `GetData`。`CF_UNICODETEXT` 只可显示为诊断格式名，
不参与 URL 判定。

## 修改文件

- `PopDrop.ahk`：v0.8 接线、Drop 延迟提取、传输状态控件、来源标题、退出处理、
  `.popdrop-part` 强制过滤及内置分类测试。
- `ExternalDrop.ahk`：集中分类器、COM marshaling、任务/批次模型、状态轮询、
  传输中心、取消、URL 重试、通知和诊断模式。
- `SettingsGui.ahk`：外部投放四项设置草稿、验证、保存和运行时刷新。
- `ConfigDocument.ahk`：将 `[ExternalTransfer]` 纳入全局布局区域。
- `config.ini`：ConfigVersion 12 及安全默认值，保持 UTF-16LE、单 BOM、CRLF。
- `native/PopDropTransfer/PopDropTransfer.cpp`：独立后台提取/下载 helper 源码。
- `native/build.ps1`、`native/README.md`：x86/x64 可重复构建和打包说明。
- `native/tests/SyntheticDataObjectTest.cpp`：Windows 合成虚拟文件数据对象。
- `tests/test_external_drop.py`：分类、接线、安全和配置静态/纯函数测试。
- `tests/slow_http_server.py`、`tests/test_http_fixture.py`：本地 HTTP 故障夹具和测试。
- `tests/WINDOWS_MANUAL_TEST_MATRIX.md`：Windows、浏览器、网盘、聊天客户端和 DPI
  人工验收清单，未执行项不标记为通过。
- `README.md`、`USAGE.md`、`CHANGELOG.md`、本报告：产品、边界和验证说明。

## Drop 与后台架构

```text
IDropTarget::DragEnter
  └─ QueryGetData / optional EnumFormatEtc
IDropTarget::Drop
  ├─ stable CF_HDROP → one GetData → existing IFileOperation
  └─ async web HDROP or external adapter (no UI GetData)
       ├─ CoMarshalInterface(IDataObject)
       ├─ launch PopDropTransfer.exe
       ├─ helper CoUnmarshalInterface + StartOperation
       ├─ helper-only GetData for async web HDROP
       ├─ bounded ready handshake
       └─ return OLE loop
            └─ helper stream/HTTP → hidden part → flush → atomic final
                 └─ atomic state.ini → AHK poll (250 ms) → one batch refresh
```

没有把裸 COM 指针写入请求。AHK 写入的是标准 `CoMarshalInterface` marshal packet；
helper 在自己的 STA 中 `CoUnmarshalInterface`，并在 ready 文件出现前完成
`IDataObjectAsyncCapability::StartOperation`。完成、部分成功、失败和取消分别调用
`EndOperation`，释放 `IDataObject`、异步接口、每个 `STGMEDIUM` 和 stream 引用。

helper 是普通权限独立进程，不注入来源，不共享主进程地址空间。崩溃不会终止 PopDrop；
轮询检测 PID 退出并标记批次失败。协议请求/状态使用 UTF-16 INI 和原子替换；取消使用
单个会话目录内的标记文件。

## 三条外部适配器链路

### 虚拟文件

helper 读取并验证 `FILEGROUPDESCRIPTORW` 数量和总结构尺寸，复制每个
`FILEDESCRIPTORW`，再以同一序号作为 `FORMATETC.lIndex` 请求 `FILECONTENTS`。
`IStream` 分 1 MiB 块读取；`HGLOBAL` 分块写入；空文件、未知大小和 Unicode 名称
可用。每项独立状态，因此一项失败不影响同批后续文件。

文件名只取 basename，清理绝对路径、`..`、控制字符、非法字符、保留名、尾部点/空格
和超长名称。虚拟目录显示指定产品文案。`TYMED_ISTORAGE` 明确报“当前支持 IStream
和 HGLOBAL”，没有不完整实现。

### 图片

仅在本地/虚拟文件均不存在时进入。注册 PNG 的 HGLOBAL 原样分块写入；DIB/DIBV5
校验 `BITMAPINFOHEADER`、调色板/bitfield 偏移，通过 GDI 创建 HBITMAP，并用 WIC PNG
编码器写入临时文件。名称为 `拖入图片_yyyyMMdd_HHmmss.png`，重名统一自动编号。

### 公开 URL

只读取明确注册 URL/URI-list。WinHTTP 使用系统自动代理、正常 TLS 验证、15/30 秒
阶段超时和最多 10 次重定向；不配置自动 Windows 凭据，也不设置忽略证书错误的安全
标志。拒绝非 HTTP(S)、默认拒绝 HTTP、拒绝用户名/密码、空主机。识别标准和 RFC 5987
Content-Disposition；HTML/XHTML 且非附件时返回产品指定的网页/登录态文案。

未知 Content-Length 使用不确定进度；已知长度会验证实际接收字节，提前断流失败。
全局命名 semaphore 限制 1～6（默认 3），按主机哈希的 semaphore 限制每主机 2。
URL 重试数据只以 `CryptProtectData` 当前用户 DPAPI 密文保存在批次目录，不出现在
普通状态或日志。

## 安全落盘

- 每项先在目标目录创建 `Hidden | Temporary` 的唯一 `.popdrop-part`；
- 所有适配器分块写入，内存不随总文件大小增长；
- 完成后 `FlushFileBuffers`，关闭句柄并以 `MoveFileExW(MOVEFILE_WRITE_THROUGH)`
  在同卷原子改名；
- 最终落盘前再次生成唯一 `name (N).ext`，不覆盖；
- 失败/取消由 RAII 删除 part；任务排队取消不创建 part；
- 启动时及每小时复查 24 小时以上的已终止会话，按批次前缀清理目标目录中的孤立
  part；目标离线时保留清理记录供以后重试；
- PopDrop 扫描入口无条件隐藏 `.popdrop-part`，不受普通下载过滤开关或固定项影响；
- URL 和带明确 URL 的虚拟文件调用 `IAttachmentExecute`；安全标记失败时文件已保存，
  任务进入 NeedsAttention；
- 异步 HDROP 尽量复制 `Zone.Identifier`，稳定路径仍由 Shell 复制以保留元数据；
- 不自动打开、执行或调用杀毒命令行处理结果。

## UI、temporary 与刷新

主状态栏右侧新增固定下载入口，点击打开非模态传输中心。中心按批次列显示文件、
安全来源值、目标、已完成/总大小、速度和状态；提供取消单项、取消整批、公开 URL
重试、打开目标和清除记录。完成记录最多保留 80 个批次并在 24 小时后清理。

Files 分组标题从渲染时保存的 BaseHeader 临时派生接收项数/百分比，不写配置。未知总量
不显示百分比。任务进度最多每 125 ms 写一次状态，AHK 每 250 ms 轮询；进度不调用
`PopulatePanel()` 或扫描。每个文件安全落盘后请求一次即时扫描；批次成为终态后再请求
一次最终扫描，用于呈现图片替换或重复清理结果。扫描 worker 会合并重叠请求。

DragEnter 到 helper ready 或本地 Drop 完成期间沿用一层 temporary 暂停；后台任务不持有
暂停。隐藏、窗口模式切换或关闭主面板不取消；完成不激活面板。明确退出时只提供“返回”
或“取消并退出”，没有伪造后台继续选项。

## 自动测试结果

当前 Linux 环境执行：

```text
python3 -m unittest discover -s tests -v
Ran 44 tests
OK
```

覆盖：

- 10 组格式优先级、Unicode 文本拒绝及 URL 协议/凭据策略；
- DragEnter 无 GetData、Drop 后两类执行入口和旧 IFileOperation 接线；
- 网页异步 HDROP 在 AHK 预读前直接接管、helper 缺失检查早于 marshaling、
  helper 内只有一次 `GetData(CF_HDROP)`；
- COM marshaling、AsyncCapability、STGMEDIUM 和 IStream/HGLOBAL 接线；
- part 隐藏/刷盘/原子落盘、AttachmentExecute、DPAPI 和 TLS 不降级；
- TransferManager 状态区、传输中心、取消、URL 重试、分组标题和退出；
- ExternalTransfer 配置的 UTF-16LE/BOM/CRLF/布局区域；
- 回收站删除菜单/快捷键/`IFileOperation` 标志，以及 `ThumbnailPolicy=Full`
  的模板、缺省读取和 Shell 缩略图标志；
- 本地 HTTP 重定向、UTF-8 Content-Disposition、HTML 登录页、未知长度、
  chunked、Range 和提前断流；
- 第一期原 11 项静态/逻辑回归测试。

Windows 合成工具覆盖两个 `FILEDESCRIPTORW`、Unicode、空文件、IStream、lIndex、
`sizeof(FILEDESCRIPTORW)==592` 和 `offsetof(FILEGROUPDESCRIPTORW, fgd)==4`。

## 当前环境未执行

当前容器不是 Windows，没有 AutoHotkey v2、MSVC/Windows SDK 或 Windows Shell，
因此以下项目没有执行，也不能声明通过：

- `native\build.ps1` 的 x64/x86 实际编译和 `SyntheticDataObjectTest.exe`；
- `AutoHotkey64.exe /ErrorStdOut=UTF-8 PopDrop.ahk --self-test`；
- Windows 10/11 的 COM apartment、WIC、WinHTTP、AttachmentExecute 端到端；
- Chrome、Edge、Firefox 的网页图片、下载列表和公开链接实拖；
- 各网盘网页的标准虚拟文件、公开下载和登录失败；
- 当前 Windows QQ、微信、TIM 的文件/图片回归；
- 资源管理器、PopDrop 内部移动/复制、固定项排序和向外拖放回归；
- temporary/always_on_top/normal、100%/150%/200% DPI 和退出活动任务。

尝试在容器内安装 Zig Windows 交叉工具链，但该沙箱没有 `/proc/self/exe`，Zig 无法
启动编译驱动；未用未经验证的二进制替代。交付包因此包含完整 helper 源码和 Windows
构建脚本，不包含声称已验证的 helper 二进制。

## Windows 验收步骤

```powershell
powershell -ExecutionPolicy Bypass -File .\native\build.ps1
.\native\bin\x64\SyntheticDataObjectTest.exe
AutoHotkey64.exe /ErrorStdOut=UTF-8 .\PopDrop.ahk --self-test
python -m unittest discover -s tests -v
AutoHotkey64.exe .\PopDrop.ahk --inspect-drop
```

然后按 `USAGE.md` 人工测试矩阵分别验证资源管理器、QQ、微信、三种浏览器、公开 URL、
网盘登录失败、慢速/未知长度、取消、重试、三并发、多目标、temporary 隐藏、三种窗口
模式和 DPI。`--inspect-drop` 日志只记录格式名称、TYMED、lIndex、异步能力和适配器，
应用实拖失败时应连同来源应用版本一起保存。

## 已知限制

- `TYMED_ISTORAGE`、虚拟文件夹/目录树和空目录不支持。
- DIB 使用 GDI + WIC；极少数私有压缩 DIB 或非标准色彩空间可能无法解码。
- HTTP 手工断点续传尚未实现；Range 夹具已提供，但当前 Resumable 保持 false，
  不显示暂停/继续。WinHTTP 会处理单次连接的分块传输，失败后公开 URL 可整项重试。
- AutoHotkey `TrayTip` 不提供稳定的自定义动作按钮；完成通知按批次聚合，目标文件夹和
  传输中心从托盘菜单进入，不声称通知本身带动作。
- 远端服务器错误地把登录页标为二进制附件时，只能按服务器声明保存；PopDrop 不读取
  浏览器登录态来进一步探测。
- helper 构建产物必须与 AHK/EXE 位数匹配；源码模式自动选择
  `native\bin\x64` 或 `native\bin\x86`。

---

# PopDrop 第一期：本地文件投放开发报告

## 交付范围

本期在现有单脚本 AutoHotkey v2 架构中实现按来源分组投放本地文件。没有增加配置项、
运行时依赖或浏览器下载能力；`config.ini` 未被重写，仍为 UTF-16LE、单 BOM、CRLF，
未知键、注释和六个布局锚点的既有写入链路没有变化。

附件不是 Git 工作树，没有提交历史或上游基线可用于区分用户修改。本次把压缩包当前
内容视为唯一基线，只修改 `PopDrop.ahk`、四份文档并新增静态测试，未格式化
`SettingsGui.ahk`、`ConfigDocument.ahk`、`config.ini` 或资源文件。

## 核心架构修改

### OLE Drop Target 生命周期

- 新增完整 `IUnknown/IDropTarget` vtable：`QueryInterface`、`AddRef`、`Release`、
  `DragEnter`、`DragOver`、`DragLeave` 和 `Drop`。
- `OleInitialize` 后在 Panel 及所有现有子 HWND 上调用 `RegisterDragDrop`。这避免只
  注册父窗口时 ListView、按钮和状态栏截获命中的问题。
- `DRAGDROP_E_ALREADYREGISTERED` 被识别并记录，不会撤销或覆盖不属于 PopDrop 的
  外部注册。退出时先 `RevokeDragDrop`，再释放基础 COM 引用和 Callback。
- `POINTL` 按值参数为 32 位和 64 位分别提供回调包装；`FORMATETC`、`STGMEDIUM`、
  `LVGROUP` 和 vtable 偏移均由 `A_PtrSize` 计算。
- `DragEnter` 对 `IDataObject` 增加引用，只查询并读取一次 `CF_HDROP`；
  `DragLeave`、取消、失败、成功和退出均释放。`ReleaseStgMedium` 始终成对调用。
- 旧 `Panel.OnEvent("DropFiles", PinDroppedFiles)` 已移除，避免 WM_DROPFILES 与 OLE
  对同一次投放重复执行。

### 集中目标解析与反馈

`ResolveDropTarget(screenX, screenY)` 返回 `Type`、`SourceId`、`Name`、规范路径、
`Available/Reason` 和 `GroupId`。主 ListView 内先命中实时项目行，再使用
`LVM_GETGROUPRECT` 读取当前滚动、视图、缩放和 DPI 下的原生分组矩形；不根据顺序、
文件数或固定高度推算。

`GroupDropTargets` 在 `PopulatePanel()` 中与原 `GroupFolderPaths` 同步创建。
`ResolveDropTargetDescriptor()` 提供可独立测试的非 GUI 部分。Files/Launcher 目标在
拖动阶段检查目录存在性，并用目录 `FILE_ADD_FILE` 打开做不产生文件的写入权限检查；
Drop 执行前强制再次验证。

反馈使用 `LVGS_SELECTED` 临时设置目标分组状态，固定项按钮在任何受支持拖拽进入时显示
可投放轮廓、悬停时显示按下态。状态栏显示动作、数量和目标；离开或取消立即恢复进入前
文字和点击动作。所有高亮均为窗口状态，不修改分组标题、配置或用户数据。

### 动作解析与内部来源上下文

向外拖拽开始前记录每个项目的 `Area/SourceId/SourcePath/SourceMode`，并在
`DoDragDrop` 嵌套循环期间通过 `ActiveInternalDragContext` 识别本程序发起的拖拽。
数据按规范路径去重；同一路径若来自不一致的显示上下文会标记为 Mixed，默认复制。
拖拽返回后无条件清理内部上下文。

`ResolveDropEffect()` 是纯函数：

| 来源 | Files | Launcher | Pinned |
|---|---|---|---|
| PopDrop 纯普通来源选择 | 默认 Move | Copy/创建快捷方式 | Copy/加入记录 |
| 外部、固定项、最近文件、Mixed | 默认 Copy | Copy/创建快捷方式 | Copy/加入记录 |
| `Ctrl` | 请求 Copy | 不改变安全语义 | 不改变安全语义 |
| `Shift` | 请求 Move | 不改变安全语义 | 不改变安全语义 |

Move 请求在来源不允许时可回退为 Copy；Copy 请求绝不回退为 Move。

### Files 与 IFileOperation

`PerformShellFileOperation()` 仍是唯一真实复制/移动入口，并继续使用
`IFileOperationProgressSink` 接收实际结果。新增可选投放上下文用于：

- 按 `SourceId` 和规范化 `SourcePath` 跳过同来源、同真实路径项目，包括递归来源项；
- 允许一批多选中部分无操作、部分继续执行；
- 继续阻止文件夹到自身/后代，移动到原父目录也视为无操作；
- 记录 Copy 和 Move 的 Shell 实际结果路径；
- Move 后继续更新固定项路径；
- 在状态中区分 Success、Failed、Skipped、Aborted，显示目标来源并提供打开目标；
- 根据来源筛选、噪音规则、显示范围和最大数量提示“已保存但可能未显示”；
- 整批成功后只调用一次 `QueueSingleRefreshAfterFileOperation()`。

冲突、合并、跨盘、撤销、权限提升、取消、占用和部分成功仍由 Shell 处理；没有使用
`FileCopy`、`FileMove` 或复制后删除替代。

### Launcher

普通文件、目录和 EXE 通过系统 `WScript.Shell.CreateShortcut` 创建 `.lnk`。
名称会移除非法字符、保留名称和尾部点/空格，并限制到安全长度。快捷方式先写入目标
目录中的唯一临时名，重新读取验证 `TargetPath` 后用无覆盖 `MoveFileExW` 改为最终
唯一名称；失败时删除临时项。已有 `.lnk/.url` 始终交给 `IFileOperation` Copy，
不允许 Move。全部完成后最多触发一次来源刷新。

### 固定项、手势与 temporary 模式

固定项投放继续调用 `PinDroppedItems()`，保留重复跳过、批次置前、原顺序和不改真实
文件的语义。修订后的单个固定项手势在整个固定项原生分组矩形（含图块留白）内保持
内部排序；释放目标由 `LVM_HITTEST` 和 `LVIR_BOUNDS` 联合解析，进入 Files/Launcher
分组或离开面板才转入 OLE。因此固定项既能稳定调整顺序，也能复制到 Files 或拖出到
其他软件。排序源根据按下行的 `ItemOpenContexts` 判断，不会因同一路径也存在于来源
分组而误判。多选不进入排序。

`DragEnter` 获得一层自动隐藏暂停，`DragLeave/Drop/异常/退出` 成对释放；
`PerformOperations` 的既有暂停作为嵌套层保留。Drop 完成后 temporary 模式恢复面板
可见性和焦点。向外拖拽的既有保护没有移除。

## 自动测试

内置 `--self-test` 新增：

- Ctrl/Shift 与 Copy/Move 解析；
- Source、Pinned、Recent、External、Mixed 默认动作；
- 危险的 Copy→Move 回退禁止；
- 同来源、同真实路径无操作；
- 文件夹自身和后代路径；
- Files、Launcher、Pinned、Invalid 描述符解析；
- 非 CF_HDROP 格式拒绝；
- 重复固定项；
- Launcher 名称清理和唯一名称；
- success、failure、cancel、leave 状态清理。
- 固定项分组内保持排序、固定项按钮不进入排序、进入 Files 时切换 OLE。

`tests/test_phase1_static.py` 检查 OLE 生命周期接线、旧 DropFiles 移除、
`IFileOperation` 复用、CF_HDROP 限定、32/64 位包装、固定项排序手势回归、
AHK 分隔符、顶层函数重名、配置编码和文档边界。本次在 Linux 执行
`python3 -m unittest discover -s tests -v`，11 项全部通过。当前环境未安装
Windows AutoHotkey v2，因此不能把 Windows
`--self-test` 或 GUI 拖放描述为已通过。

交付 ZIP 使用 `unzip -t` 完整校验，所有源码、四份文档、`config.ini`、测试和资源均
可正常解压；包内不含 `__pycache__` 或 `.pyc`。未修改的配置、设置代码、配置文档代码
和资源文件均与输入附件逐字节一致。

Windows 上执行：

```powershell
AutoHotkey64.exe /ErrorStdOut=UTF-8 PopDrop.ahk --self-test
python -m unittest discover -s tests -v
```

## Windows 手动测试矩阵

以下项目在当前 Linux 环境均未执行，交付后应在 Windows 10/11、AutoHotkey v2 上逐项
记录结果：

| # | 场景 | 预期 |
|---:|---|---|
| 1 | 资源管理器单文件到 Files | 默认 Copy，目标/光标/状态一致 |
| 2 | 资源管理器多文件+文件夹到 Files | 混合批次 Copy，一次刷新 |
| 3 | 外部拖拽按 Shift | 请求 Move；不支持时安全回退 Copy |
| 4 | PopDrop 普通来源之间 | 默认 Move |
| 5 | 内部拖拽按 Ctrl | Copy |
| 6 | 同一来源投放 | 全部无操作并说明 |
| 7 | 两个来源指向同一目录 | 视为无操作 |
| 8 | 跨磁盘移动 | Shell 移动、可撤销、无复制后删除实现 |
| 9 | 重名冲突 | Shell 标准冲突 UI，实际名称被记录 |
| 10 | 文件夹合并 | Shell 标准合并行为 |
| 11 | 取消 Shell 操作 | 显示取消和实际成功数 |
| 12 | 部分失败 | 成功/失败/跳过分别计数 |
| 13 | 网络目录断开 | DragOver 禁止或 Drop 再验证失败 |
| 14 | 只读/无权限目录 | 禁止投放并说明写入权限 |
| 15 | 管理员权限级别不同 | Windows UIPI 阻止；文档说明，不绕过 |
| 16 | Launcher 普通文件/目录/EXE/.lnk/.url | 创建或 Copy 快捷方式，原项不移动 |
| 17 | 固定项加入和单项排序 | 加入不改文件；排序仍保存 |
| 18 | 固定项拖到 Files | 默认 Copy，不触发排序 |
| 19 | 多选跨分组混合拖拽 | 默认 Copy；各项目上下文正确 |
| 20 | 缩略图/列表视图 | 分组命中和高亮一致 |
| 21 | 窗口缩放、滚动、100%/150%/200% DPI | 实时矩形命中正确 |
| 22 | temporary/always_on_top/normal | 拖放中不隐藏；结束后模式行为恢复 |
| 23 | 最近文件栏、状态栏、按钮、无效空白 | DROPEFFECT_NONE 并清除旧高亮 |
| 24 | 扩展名/噪音/范围/最大数量隐藏结果 | 显示“已保存但未显示”提示 |
| 25 | 向 Photoshop、浏览器、微信等拖出 | 单选/多选向外拖放无回归 |

## 已知限制与后续建议

- 只消费 `CF_HDROP`。浏览器 URL、HTML、HTTP、`FILEDESCRIPTOR/FILECONTENTS` 和需
  登录态的虚拟文件属于后续阶段；当前格式检查和 `ReadHDropPaths()` 已集中封装，
  便于以后增加独立数据提供器而不改变目标/动作层。
- Windows 不会把不同完整性级别之间的拖放交给应用；这是 UIPI 限制。
- 拖动阶段的写权限检查是只读 ACL/共享检查，网络状态和 ACL 仍可能在 Drop 前变化，
  因此执行阶段必定再次验证，Shell 仍可能报告竞争条件或权限变化。
- `LVGS_SELECTED` 的具体颜色由当前 Windows 主题决定；状态栏和系统光标始终提供第二、
  第三通道反馈。
- 当前项目没有实时文件系统监听器。投放完成后的“增量”仍沿用现有后台全量扫描，但
  每个批次只排队一次。

---

# PopDrop 0.7.3 临时、锁定及系统文件过滤开发报告

## 0.7.3 修复

- 修复“文件夹类型”从 Launcher 切回 Files 时只修改 `Mode`、未撤销 Launcher
  自动默认值的问题。
- 切回 Files 现在统一恢复 `SortMode=ModifiedDesc`、
  `StripOrderPrefix=0`、`HideExtensions=0`，并恢复全局默认显示范围与文件过滤。
- 类型切换仍只修改设置草稿；点击“保存”后才写入 `config.ini`。
- 已完成修改文件的字符串与括号结构检查、Files/Launcher 双向默认值静态矩阵、
  原始 `config.ini` 字节一致性检查及 ZIP 完整性检查。当前 Linux 环境不能直接运行
  Windows AutoHotkey GUI，类型切换的实际控件交互仍建议在 Windows 上复核一次。

## 0.7.2 补充修改

- `SettingsGui.ahk`
  - 来源设置新增“文件夹类型”下拉框，默认显示 `Files`，并可选择 `Launcher`。
  - 首次从 Files 切换为 Launcher 时统一应用
    `IncludeSubfolders=0`、`DisplayScope=FilesOnly`、`SortMode=NameAsc`、
    `FilterMode=Include`、`FileExtensions=.lnk,.url,.exe`、
    `StripOrderPrefix=1`、`HideExtensions=1`。
  - “噪音文件”改为“排除噪音文件”，来源附加规则窗口补充通配符含义、
    不显示效果和示例。
- `ConfigDocument.ahk`、`PopDrop.ahk`
  - 新增幂等的 `[NoiseFilter]` 配置说明块；首次生成、升级规范化和 GUI 保存均会
    保证说明存在，未知配置项继续保留。
- `config.ini`
  - 增加 `[NoiseFilter]` 默认项及逐项说明，继续保持 UTF-16LE、单 BOM、CRLF。
- 测试新增 Launcher 默认特性矩阵和噪音配置说明写入检查。

0.7.2 在当前 Linux 环境完成了三份 AHK 源文件的字符串、圆括号、方括号、花括号和
顶层函数重复检查，结果通过。第三方 AHK 静态分析器在修改前后报告的错误类别及数量
完全相同（均为该分析器不支持的既有合法 v2 语法），未出现新增错误。`config.ini`
已验证为 UTF-16LE、单 BOM、全 CRLF，且 `[NoiseFilter]` 六项说明和默认值齐全。
Windows GUI 与内置 `--self-test` 仍需在 Windows AutoHotkey v2 环境执行。

## 架构识别

- AutoHotkey 版本：`#Requires AutoHotkey v2.0`。
- 主扫描入口：后台 worker 的 `RunScanWorkerMode()` 调用 `GetSortedItems()`。
- 递归扫描入口：`GetSortedItems()` 的显式目录栈；文件夹最新内容时间由
  `GetLatestDescendantFileTime()` 递归计算。
- 缓存：`LoadDiskScanCache()`、`ReadScanResult()`、`WriteScanResultAtomic()`；
  缓存目录由 `ResolveCacheDirectory()` 决定。
- 配置：`LoadSettings()`、`ValidateConfig()` 和 `WriteSettingsDraft()`；
  `PopDropConfigDocument` 负责 UTF-16LE、CRLF、未知项保留和原子写回。
- 固定项目：`PopulatePanel()` 先于来源结果渲染 `PinnedPaths`；worker 还会收到固定
  路径集合，使固定文件在来源扫描和文件夹时间计算中也优先于过滤。
- 基础配置和来源配置 GUI：`OpenSettingsGui()`、`BuildDisplaySettingsPage()` 和
  `BuildSourcesSettingsPage()`。
- 文件夹最新内容时间：`GetLatestDescendantFileTime()`。
- 项目没有独立的文件系统变化监听器；手动刷新、显示面板和文件操作后的刷新均进入
  `StartBackgroundScan()`，使用同一个 worker 扫描路径。

## 修改文件

- `PopDrop.ahk`
  - 新增统一的 `ShouldIncludeEntry()` 文件可见性入口和原因标识。
  - 新增通配规则预处理、来源覆盖、同目录文件名索引、属性规则和固定项覆盖。
  - 普通、递归和“文件夹内最新内容时间”均改用一次目录枚举生成的文件名集合。
  - worker 请求升级为 v4，扫描结果/缓存升级为 v3，缓存文件改为
    `scan-cache-v3.ini`。
  - 缓存只持久化隐藏总数，不持久化最多 200 条的详细诊断记录。
  - 增加 `--self-test` 过滤测试。
- `SettingsGui.ahk`
  - “过滤与显示”页新增推荐总开关、规则管理按钮、隐藏数量和查看窗口。
  - 规则窗口新增 Hidden、System、Temporary、未完成下载及全局通配规则。
  - 每个来源新增继承/启用/禁用和来源附加规则。
  - 保存前检查 `*`、`*.*` 并要求确认；取消不写配置。
- `ConfigDocument.ahk`
  - 将 `[NoiseFilter]` 纳入全局配置区域。
  - 将 `[SourceIgnore:<SourceId>]` 纳入扫描规则区域。
- `README.md`、`USAGE.md`、`CHANGELOG.md`
  - 更新版本、配置示例、使用说明和更新日志。
- `config.ini`
  - 0.7.2 交付样例显式写入 `[NoiseFilter]` 默认项及逐项说明；旧配置仍按缺失项
    默认值兼容，并在启动规范化时补充说明块。

## 配置项

| 配置节/配置项 | 默认值 | 缺失时行为 |
|---|---:|---|
| `[NoiseFilter] Enabled` | `1` | 开启 |
| `HideHidden` | `1` | 开启 |
| `HideSystem` | `1` | 开启 |
| `HideTemporaryAttribute` | `0` | 关闭 |
| `HideIncompleteDownloads` | `0` | 关闭 |
| `CustomPatternCount` | `0` | 无全局自定义规则 |
| `CustomPatternNNN` | 无 | 忽略空行，去首尾空格，大小写不敏感去重 |
| `[Folder:<名称>] NoiseFilterMode` | `Inherit` | 跟随全局 |
| `[Source:<ID>] NoiseFilterMode` | `Inherit` | 文件夹项缺失时作为稳定 ID 回退 |
| `[SourceIgnore:<ID>] PatternNNN` | 无 | 无来源附加规则 |

新安装和升级安装统一采用“配置项缺失即使用默认值”。这避免依赖当前项目没有的安装状态
标记，同时保证旧 `config.ini` 可直接使用。配置文档写入器保留未管理的配置项和注释。

## 过滤规则

默认开启：

- `~$*`：Office/WPS 锁定文件。
- `.~lock.*#`：LibreOffice/OpenOffice 锁定文件。
- `desktop.ini`、`Thumbs.db`、`ehthumbs.db`、`.DS_Store`。
- Hidden、System 文件属性。

同目录关联后才隐藏：

- `.laccdb` ↔ `.accdb`；`.ldb` ↔ `.mdb`。
- `.dwl`/`.dwl2` ↔ `.dwg`。

默认关闭：

- Temporary 属性。
- `*.crdownload`、`*.part`、`*.download`。

不会默认隐藏 `.tmp`、`.bak`、`.sv$`、`.ac$`、无扩展名文件、所有点文件、所有
`~` 文件或所有 `.lock` 文件。固定路径在统一入口最先检查，命中后返回
`PinnedOverride` 并继续显示。

## 验证结果

已完成：

- 三个 AHK 文件通过第三方 AutoHotkey v2 AST 解析：0 个 parse error。
- 自定义静态检查通过：字符串、括号、方括号、花括号平衡，无重复顶层函数。
- 全项目仅保留两个 `Loop Files`：Windows Recent 记录和统一目录枚举器。
- 参考规则矩阵通过：Office、LibreOffice、Windows/macOS 元数据、Access、
  AutoCAD、恢复文件保留、下载文件默认保留、属性开关和通配转义。
- 静态性能检查通过：关联判断只使用每目录文件名 Map，统一入口内没有
  `FileExist`/`FileGetAttrib` 的逐文件磁盘查询。
- `config.ini` 与附件逐字节一致，升级兼容不会预先覆盖用户配置。
- 内置 `RunNoiseFilterSelfTests()` 覆盖中文文件名、关联文件、固定项、来源覆盖、
  通配规则、扫描结果、诊断计数和文件夹最新内容时间。

当前环境是 Linux，未安装 Windows AutoHotkey 解释器，因此没有实际打开 GUI，也没有
执行 Windows 文件属性和网络共享的端到端测试。Windows 本地可执行：

```powershell
AutoHotkey64.exe /ErrorStdOut=UTF-8 PopDrop.ahk --self-test
```

随后建议手动打开设置窗口，分别保存/取消一次；用 `attrib +h`、`attrib +s` 和
`attrib +t` 创建属性测试文件；断开一个网络来源后刷新，确认界面保持可用。

## 风险与遗留

- 没有遗漏已存在的自动扫描入口。Windows Recent 是用户主动打开历史，按原语义保留，
  没有应用噪音过滤。
- 目录上下文是扫描期间的临时数组和 Map，目录完成后释放；代价是每个正在处理的目录
  暂存一份条目列表，属于 O(目录条目数) 内存，没有 N+1 磁盘查询。
- “查看已隐藏项目”已完整实现：累计总数，内存最多保留 200 条；缓存不保存详细路径。
- 旧缓存通过新文件名和新格式版本整体失效，不会读取后短暂显示旧噪音文件。
- 项目没有独立增量监听器，因此“增量更新”沿用现有架构，实际是文件操作后排队执行同一
  后台全量扫描。

## 用户可见更新说明

PopDrop 现在会自动隐藏常见的 Office/WPS、LibreOffice、Access、AutoCAD 锁定文件和
系统目录信息。你可以在“过滤与显示”中调整文件属性、未完成下载和自定义通配规则，并为
每个来源单独继承、启用或禁用。固定项目始终显示，所有过滤只影响列表展示，不会修改或
删除真实文件。
