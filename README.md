<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="YUANNotch 图标">
</p>

# YUANNotch

一款藏在 Mac 屏幕顶部、尽量不打扰你的桌面记录与提醒应用。

YUANNotch 的出发点，是让记录尽可能自然、无感：平时安静地留在屏幕顶部，需要时随手展开，用完便回到正在做的事情里。它不是一个庞大的知识库或任务管理系统，而是一个始终在手边的入口——接住突然出现的想法、眼前要做的事，以及工作中需要反复查看的内容。

<p align="center">
  <img src="Resources/YUANNotch-Hero.png" width="1000" alt="YUANNotch 在银色 MacBook 上展开的效果图">
</p>

## 核心功能

### 顶部常驻，随时展开

YUANNotch 常驻在屏幕顶部中央，通过悬停或点击即可打开；面板可以拖出成为独立的悬浮窗口，也可以双击或拖回顶部自动归位。支持多显示器，并可在设置中调整触发方式、响应延迟、外观和开机启动。

### 本地 Markdown 笔记

在 Notes 中快速创建和切换多个页面，内容以独立 Markdown 文件保存在本地。笔记目录可以指定为自己的文件夹或 Obsidian 仓库，粘贴的图片会保存到同目录的 `attachments` 文件夹，方便继续使用现有的文件工作流。

### Apple 提醒事项

在 Reminders 中直接切换提醒事项列表，创建、编辑、设置到期时间并完成提醒。数据由 macOS Reminders 管理；选择 iCloud 列表后，提醒会继续通过 Apple 的服务同步到其他设备。

### 每日计划与番茄钟

在 Plans 中建立可重复的每日时长目标，为每个计划设置专属的专注与休息节奏。支持开始、暂停和切换计划，显示当前番茄轮次、当天累计进度，并保留历史完成记录；收起面板或切换到其他页面不会中断计时。

### 文件暂存区

将文件拖到顶部区域或展开的面板即可暂存，之后再拖到 Finder、其他应用或网页上传区域。暂存区支持排序和多选操作，只保存文件位置，不会移动、复制或删除原文件。

### 本地优先与可控的数据

YUANNotch 不要求账户，也不提供自有云端同步。笔记、图片、计划和计时状态保存在本机；提醒事项直接使用系统数据。你可以在设置中更改笔记目录，并单独启用或关闭文件暂存区和提醒事项集成。

## 如何使用

### 打开面板

默认情况下，把鼠标停在屏幕顶部中央即可展开 YUANNotch。也可以在 **设置 → Trigger** 中改为点击打开，并调整悬停触发的等待时间。

### 记录、提醒与每日计划

在 Notes 页面直接输入即可开始记录；使用左上方的 `+` 和 `−` 新建或移除笔记页面。切换到 Reminders 页面后，可以查看、创建和完成 Apple 提醒事项。第一次启用时，需要在 **设置 → Integrations** 中打开同步，并授予系统提醒事项权限。

在 Plans 页面点击 **Add Daily Plan** 可以设置目标时长、启用日期和番茄钟节奏。点击计划右侧的播放按钮开始计时；Today 会把当前倒计时固定在计划列表上方，并显示当天整体与单项进度。专注阶段计入每日目标，休息阶段不计入。

### 使用暂存区

暂存区默认启用，但没有文件时不会一直占用面板空间。将文件拖到屏幕顶部的 YUANNotch 区域或已经展开的面板，暂存区会自动出现。之后可以把文件从暂存区直接拖入其他应用；有暂存内容时，也可以点击编辑区下方的托盘图标收起或重新展开。

如果暂存区已被关闭，可以前往 **设置 → File Shelf**，打开 **Enable file shelf**。

### 拖出浮动与自动归位

- **拖出浮动：** 按住面板底部中央的灰色短线，向下拖动，面板就会脱离屏幕顶部，成为可以自由移动的悬浮窗口。
- **自动归位：** 双击灰色短线，或者把悬浮窗口拖到屏幕顶部，面板都会自动吸附回原位。

## 下载

[下载最新版本](https://github.com/Hy0IU/YUANNotch/releases/latest)

目前支持 macOS 14 或更高版本，以及 Apple Silicon Mac。

下载并解压 Release 中的 ZIP 安装包，再将应用拖入“应用程序”文件夹。当前版本尚未经过 Apple 公证；若首次打开时被 macOS 拦截，请前往“系统设置 → 隐私与安全性”，选择“仍要打开”。

## 数据与隐私

笔记以普通 Markdown 文件保存在本机，图片也存放在同一个笔记目录中。每日计划、计时状态和完成进度保存在应用的本地 Application Support 目录。提醒事项直接读写 macOS 的系统提醒数据库。YUANNotch 不提供自己的账户、云端或同步服务。

## 从源码构建

需要 macOS 14+ 和 Swift 6：

```bash
git clone https://github.com/Hy0IU/YUANNotch.git
cd YUANNotch
bash Scripts/package-app.sh
```

## 致谢

- [swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine) 提供 Markdown 编辑器内核。
- [Atoll](https://github.com/Ebullioscopic/Atoll) 为 macOS 顶部面板的交互与实现提供了参考。
