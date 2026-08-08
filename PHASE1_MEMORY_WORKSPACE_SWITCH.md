# 第一阶段：纯内存工作区切换

本阶段把工作区切换的同步关键路径收敛为：绑定启动时已解析的工作区运行时状态、恢复对应
内存扫描快照、提交当前列表首帧。切换不再同步重读或改写 `config.ini`，也不再重复安装
工作区快捷键。

## 已实现行为

- `ActivateWorkspace()` 通过 `BindRuntimeWorkspace()` 直接切换工作区 ID、类型、来源、固定项、
  验证错误、配置指纹与扫描快照。
- 已访问工作区优先恢复 `WorkspaceScanSnapshots`；没有内存快照时才读取持久化扫描缓存，随后
  继续沿用现有后台校准流程。
- Tab 成员不变时只调用 `Choose()` 更新选中项，不删除并重建全部 Tab。
- 当前工作区与最近文件工作区在新画面同步绘制完成后延迟 250 ms 合并写入配置；快速连续
  切换只保存最后目标。
- 退出或显式重载设置前强制冲刷待保存状态。
- 切换时若旧工作区仍有待写扫描缓存，异步任务会捕获旧工作区 ID、指纹和结果，防止写入
  新工作区的缓存命名空间。
- 目标工作区激活后会取消已失效的前台扫描 worker，再按缓存状态与更新模式在后台校准。

## 后续提速

在本阶段之上已继续实现工作区热视图缓存。已访问工作区保留独立的原生 `ListView`、行映射
和图像列表；缓存有效时切换只交换活动状态并 Hide/Show 控件。详见
`HOT_WORKSPACE_VIEWS.md`。

## 验证

跨平台静态与契约测试：

```powershell
python -m unittest discover -s tests -p 'test_*.py' -v
```

Windows 交付门禁：

```powershell
AutoHotkey64.exe .\PopDrop.ahk --self-test
powershell -ExecutionPolicy Bypass -File .\native\build.ps1
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

当前交付环境没有 AutoHotkey、PowerShell/MSVC 和 Windows Shell/OLE，故 Windows 运行时自测、
Helper 构建与 Ahk2Exe 构建仍需在 Windows 构建机执行。
