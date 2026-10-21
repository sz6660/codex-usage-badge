# Codex Usage Badge · Codex 用量条

为 Codex 桌面端增加额度显示、项目配色、文件夹容量和会话 Token 统计，适配浅色与深色主题。

![Codex Usage Badge：原生风格额度圆环、项目配色与 Token 色块](assets/cover.png)

## 功能

- **额度圆环**：查看订阅剩余额度，绿、黄、红对应充足、偏低和即将耗尽。Plus 支持 5 小时与每周额度双圆环。
- **文件夹配色**：在项目菜单中选择颜色，方便区分不同项目。
- **文件夹容量（macOS）**：在本地项目名称旁显示目录占用，支持 KB、MB、GB 等单位，自动缓存并刷新。
- **会话 Token**：用蓝色色块表示用量，悬停查看累计 Token，按万、千万、亿显示。
- **原入口加载**：安装时自动配置环境变量，后台连接已启动的客户端，不再退出重开。
- **手动升级**：后台不请求 GitHub，升级时运行新安装包中的安装命令。

## 安装与下载

本 fork 当前版本为 Windows / macOS **0.10.4**，来自 [原项目](https://github.com/jaykinhoo9/codex-usage-badge)。从 [本仓库 Actions](https://github.com/sz6660/codex-usage-badge/actions) 下载对应平台的构建产物，完整解压后操作。不自动发布 Release。

| 系统 | 安装／升级 | 查看状态 | 卸载 | 说明 |
| --- | --- | --- | --- | --- |
| Windows 10 / 11 | `Install.cmd` | `Status.cmd` | `Uninstall.cmd` | [Windows 手册](docs/windows.md) |
| macOS Apple Silicon / Intel | `安装.command` | `查看状态.command` | `卸载.command` | [macOS 手册](docs/macos.md) |

安装命令同时处理插件和环境变量；重复安装保留原环境备份，卸载自动恢复。安装后由用户完全退出 Codex，再从原来的图标打开。插件不启动或重开 Codex，不依赖点击是否发生在其他软件中，也没有加载冷却期。

此方式依赖内部 `BUILD_FLAVOR=dev` 开关，还会影响客户端开发工具和内置更新判断。配置目录固定为已有目录以沿用登录状态。Windows 已在真实客户端验证；macOS 原入口在真实账号环境的加载仍需实际 Mac 验收，详见各平台手册。客户端应用包和原快捷方式不改动。

[更新记录](CHANGELOG.md) · [问题反馈](https://github.com/sz6660/codex-usage-badge/issues) · [开发说明](docs/development.md) · [隐私与安全](SECURITY.md)

非官方项目，与 OpenAI 无关联。采用 [MIT 许可](LICENSE)。
