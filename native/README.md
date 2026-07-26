# PopDropTransfer 原生 helper

`PopDropTransfer.exe` 是 PopDrop 外部内容投放的最小后台组件。它只负责：

- 解封送 `IDataObject`；
- 对所有外部异步 HDROP 执行唯一一次 `GetData(CF_HDROP)`，并读取来源路径；
- 若 HDROP 来源已经位于目标目录，等待来源写入完成后认领原文件，不再同目录复制；
- 在 `IDataObjectAsyncCapability::EndOperation()` 后短暂观察所有适配器保存的本批
  图片，收敛来源程序延迟生成的同名缩略图或原图；
- 读取 `FILEDESCRIPTORW/FILECONTENTS`、
  PNG/DIB 和明确 URL；
- 分块写入隐藏的 `.popdrop-part`；
- 原子落盘、安全自动改名、网络来源标记；
- 以原子 INI 状态文件向 AHK 报告进度，并响应取消标记。

它不读取浏览器 Cookie、聊天数据库或应用私有缓存，不注入其他进程，也不执行下载结果。

## 构建

要求 Windows 10/11、PowerShell 5.1+，以及 Visual Studio 2022 Build Tools 的
“使用 C++ 的桌面开发”工作负载。无需第三方包：

```powershell
powershell -ExecutionPolicy Bypass -File .\native\build.ps1
```

脚本同时生成：

- `native\bin\x64\PopDropTransfer.exe`
- `native\bin\x86\PopDropTransfer.exe`

AHK 源码运行时根据自身位数选择对应文件。发布编译版时，将对应架构 helper 复制到
`PopDrop.exe` 同目录。helper 协议版本写在请求和状态文件中；不兼容版本会失败而不会
猜测字段。源码模式优先加载 `native\bin\<架构>`，编译版优先加载程序同目录组件；
握手还会校验 `HelperVersion`，防止根目录残留旧 EXE 掩盖最新构建。

## 故障隔离

helper 为独立、非提权进程。崩溃不会终止 PopDrop；主程序检测到进程退出后把批次标记
为失败。未完成文件始终使用 `.popdrop-part` 且带 Hidden 属性，启动时/定时清理陈旧
运行目录及可验证的同批孤立 part；目标离线时保留清理记录供以后重试。活动任务只能
由当前 PopDrop 会话的取消文件控制。

`TYMED_ISTORAGE` 目前会明确拒绝；支持 `TYMED_ISTREAM` 和 `TYMED_HGLOBAL`。
