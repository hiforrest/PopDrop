# PopDrop

<img src="assets/logo.webp" width="192px">

按一下 `F2`，一个文件面板出现在屏幕最前面。找到文件，拖走，关掉。全程不到三秒。

PopDrop 是一款 Windows 文件快捷面板，把你常用的文件夹、最近打开的文件、固定好的文件集中在一个面板里，随时取用，用完就关。面板默认使用临时窗口模式，切换到其他窗口后自动隐藏。

## 快速开始

### 使用 EXE 版本（推荐）

1. 从 [GitHub Releases](https://github.com/forfreeday/PopDrop/releases) 下载最新 zip 文件
2. 解压，保持 `PopDrop.exe` 和 `config.ini` 在同一目录
3. 双击运行 `PopDrop.exe`
4. 按 `F2` 试试看

### 使用 AHK 源码版本

1. 安装 [AutoHotkey v2](https://www.autohotkey.com/)（注意：v1 不行，必须装 v2）
2. 将 `config.example.ini` **复制一份**并改名为 `config.ini`
3. 双击 `PopDrop.ahk`
4. 按 `F2` 试试看

> 无论哪种方式，**PopDrop 不会修改、移动、删除你的文件**——只负责展示和操作。

详细配置和使用说明请查看 **[使用指南](USAGE.md)**。

## 功能一览

- **一键呼出**：默认 `F2`，在任何软件中按一下，面板就在最前面打开
- **多目录最新文件**：同时添加下载、桌面、文档、项目等多个目录，每个分组独立显示
- **缩略图网格**：图片、视频、PDF 优先显示系统缩略图，也可切换为文件名列表
- **固定常用项目**：将常用文件或文件夹固定在面板顶部，取消固定不会影响原项目
- **拖入即可固定**：从资源管理器把文件或文件夹拖进 PopDrop，立即加入固定项目
- **拖入保持可见**：temporary 模式下接收拖入项目时暂停自动隐藏，完成后窗口保持打开
- **实时置顶切换**：顶部按钮可在 temporary 与 always_on_top 模式之间即时切换
- **完整拖放支持**：从面板拖拽文件到 Photoshop、浏览器、微信等任何软件
- **Windows 完整右键菜单**：包括你装过的第三方扩展（7-Zip、Notepad++、VS Code 等）
- **最近打开侧边栏**：右侧显示 Windows 近期文件记录，双击即可再次打开
- **多选操作**：`Ctrl` 多选、`Shift` 连续选、拖框选——支持跨文件夹、跨磁盘
- **Launcher 模式**：将文件夹变成快捷启动面板，按数字前缀排序 [详细说明](USAGE.md#快捷启动文件夹launcher模式v05)
- **窗口模式**：temporary（失焦自动隐藏）、always_on_top（始终置顶）、normal（普通窗口）[详细说明](USAGE.md#窗口模式v04)

## 快速配置

编辑同目录下的 `config.ini`，保存后按 `F2` 打开面板，点「刷新」即可生效。示例：

```ini
[General]
Hotkey=F2
MaxFilesPerFolder=8
WindowMode=temporary
ViewMode=Thumbnail
ShowRecentSidebar=1

[Folders]
文档=%USERPROFILE%\Documents
下载=D:\download
项目=D:\Projects\Current
```

所有配置项详解见 **[使用指南](USAGE.md)**。

## 安全说明

PopDrop 不会主动修改、移动或删除你的文件。软件由 AutoHotkey 开发，可能被安全软件误报。
