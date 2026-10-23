# Codex Usage Badge · Codex 用量条

为 Codex 桌面端增加剩余额度、项目配色、文件夹容量和会话 Token 显示，支持浅色与深色主题。

![Codex 用量条界面示意](assets/cover.png)

## 当前版本

| 平台 | 版本 | 状态 | 安装说明 |
| --- | --- | --- | --- |
| Windows | **0.10.5** | 已通过本机安装与原图标启动验收，已封版 | [Windows 手册](docs/windows.md) |
| macOS · Apple Silicon / Intel | **0.10.4** | 自动化测试通过，真实账号环境待实机验收 | [macOS 手册](docs/macos.md) |

从 [当前构建](https://github.com/sz6660/codex-usage-badge/actions/workflows/ci.yml?query=branch%3Amain) 下载对应平台的安装包，完整解压后运行。每份构建产物包含 ZIP 和 SHA-256 校验文件。构建产物保留 30 天，过期后可手动运行工作流重新生成；仓库不自动发布 Release。

## 三个操作入口

| 操作 | Windows | macOS |
| --- | --- | --- |
| 安装或升级 | `Install.cmd` | `安装.command` |
| 查看安装与连接状态 | `Status.cmd` | `查看状态.command` |
| 卸载并恢复环境 | `Uninstall.cmd` | `卸载.command` |

安装时自动备份并配置环境变量、安装插件后台；重复安装保留原环境备份，卸载自动恢复。由用户完全退出 Codex，再从原商店入口、应用图标或 Dock 启动。无需额外的环境设置或启动命令。

插件不会关闭或重启运行中的 Codex。Windows 检测到原入口启动请求进入正在退出的旧容器并丢失时，会等旧容器销毁且主进程稳定退出，再补交一次原入口请求；普通退出不会自动拉起。

## 功能

- **额度显示**：Plus 显示短周期和每周额度；Pro 显示每周额度。数据不可用时明确显示未知状态。
- **项目配色**：项目菜单提供颜色选择。
- **文件夹容量**：在本地项目旁显示目录占用，自动缓存和刷新。
- **会话 Token**：色块与悬停提示显示累计用量。
- **本机处理**：界面连接仅使用回环端口，插件不上传聊天和项目数据，不自动检查或下载更新。

此方式依赖客户端内部环境开关 `BUILD_FLAVOR=dev`，也会影响开发工具及客户端内置更新判断。安装时固定已有配置目录，保留登录状态；不修改原应用包或原图标。兼容范围和恢复方式见各平台手册。

[版本与更新说明](CHANGELOG.md) · [开发说明](docs/development.md) · [隐私与安全](SECURITY.md) · [问题反馈](https://github.com/sz6660/codex-usage-badge/issues)

非官方项目，与 OpenAI 无关联。采用 [MIT 许可](LICENSE)，保留 Codex Usage Badge 原项目及贡献者的版权声明。
