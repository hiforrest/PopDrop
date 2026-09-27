PopDrop 拖放诊断版 r14

用途：
  这不是新的修复尝试，只增加诊断日志，用来比较 Windows Explorer
  “拖文件”和“拖文件夹”时实际提供的 OLE/IDataObject 数据。

测试步骤：
  1. 正常启动本诊断版 PopDrop。
  2. 从 Windows 文件资源管理器拖一个普通本地文件到 PopDrop，
     悬停 1~2 秒后取消或松开。
  3. 再从同一位置拖一个普通本地文件夹到 PopDrop，
     同样悬停 1~2 秒后取消。
  4. 按 Win+R，输入：
       %TEMP%
  5. 找到：
       PopDrop-drop-diagnostic.log
  6. 把该日志文件发给 ChatGPT。

日志记录：
  - QueryGetData 对 CF_HDROP / Shell IDList / FileDescriptor 等格式的结果
  - EnumFormatEtc 实际枚举到的格式
  - IDataObjectAsyncCapability 状态
  - CF_HDROP 预读取后的路径数量
  - Shell IDList 解析后的路径数量
  - FileExist / FilesOnly / FoldersOnly 分类
  - 被现有 try/catch 吞掉的异常

本版不增加额外的 GetData 调用，不改变文本块布局和正常拖放决策。
