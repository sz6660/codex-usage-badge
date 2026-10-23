# macOS 安装说明（0.10.5）

将 ZIP 完整解压，先确保原版 Codex 已经运行过一次。Apple Silicon 和 Intel 使用同一安装包。

只需要三个入口：

| 命令 | 用途 |
| --- | --- |
| `安装.command` | 安装或覆盖升级插件，同时备份并设置所需环境变量 |
| `查看状态.command` | 查看是否安装、环境、后台和窗口连接状态，不启动 Codex |
| `卸载.command` | 停止插件后台、移除登录自动启动、恢复安装前的环境变量并清理插件界面 |

安装后由你使用 Codex 菜单完全退出（Command-Q），再从原来的应用图标／Dock 打开，等待约 5–10 秒。插件不关闭、启动或重开客户端，也不使用全局输入保护或冷却期。

安装器会优先寻找客户端内置 Node.js 24+；未找到时请安装 Node.js 24 LTS。若系统阻止未签名的 `.command`，请通过系统的“打开”流程确认来源后执行，不需要修改原版 Codex 的签名或权限。

## 原理和恢复

通过当前用户的 `launchctl setenv` 设置 `BUILD_FLAVOR=dev`、`CODEX_ELECTRON_CHROMIUM_SWITCHES`（仅 `127.0.0.1:39222`）和 `CODEX_ELECTRON_USER_DATA_PATH`（固定已有配置目录）。登录任务在以后登录时重新应用这些环境值，后台只连接已开启的端口加载界面，不修改应用包、原图标或 shell 配置。

开发模式还影响客户端开发工具与内置更新判断；这些内部开关可能随客户端版本变化。不会改写聊天或账号文件。后台不查询 GitHub，升级时手动下载新包，再运行 `安装.command`。

首次安装前的环境值保存在 `~/Library/Application Support/CodexUsageBadge-Environment`；重复安装不会覆盖原备份。卸载会恢复原值，发现外部改动时拒绝覆盖。插件后台和文件位于 `~/Library/Application Support/CodexUsageBadge`，登录任务使用 `com.codexusagebadge.agent` 和 `com.codexusagebadge.startup`。

卸载后由你完全退出并重新打开 Codex，让当前进程恢复原环境。安装器不会代你重启。

## 验证范围

安装、重复安装、登录恢复、失败回滚与卸载在隔离环境测试。Windows 原入口方案已有实际客户端验证；macOS 原生助手由 macOS Actions 编译，真实 Mac 登录账号后的原入口加载仍需实际机器验收。
