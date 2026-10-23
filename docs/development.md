# 开发与构建

## 版本规则

当前版本与验收状态见 [版本记录](../CHANGELOG.md)。Windows 0.10.5 已封版，后续运行代码修复必须递增 `windowsVersion` 和 Windows 管理脚本版本，不覆盖已交付版本。文档可以继续澄清当前行为。

macOS 版本由 `package.json` 的 `version`、`src/agent-main.js`、`manage.cjs` 及锁文件的根版本保持一致。Windows 安装包使用 `windowsVersion`，构建器替换包内后台版本标识。依赖锁文件只随元数据或依赖变更更新。

## 目录结构

| 目录／文件 | 用途 |
| --- | --- |
| `src/`、`build.py` | 界面、额度和本地统计；生成 `agent.cjs` |
| `windows/` | Windows 安装、环境备份、后台管理和界面诊断 |
| `startup/windows.cjs` | Windows 连接模式就绪与插件停止处理，启用丢失请求观察 |
| `startup/lost-launch.cjs` | 仅恢复有系统事件证据的丢失启动请求 |
| `startup/activation-watch.ps1` | 读取目标进程与容器事件，检查后调用原系统入口 |
| `manage.cjs`、`macos/` | macOS 安装、launchd 任务、会话环境与连接模式助手 |
| `updater/` | 保留安装锁和兼容校验组件；后台更新入口已停用 |
| `tests/` | 临时目录、模拟接口、独立 Chromium 和原生测试应用 |
| `scripts/build_release.py` | 按平台白名单打包、校验和及脚本权限 |
| `scripts/audit_release.py` | 检查源码及安装包中不应分发的数据 |

旧重开控制器及底层适配器保留用于兼容性回归测试，不是当前安装模式的自动启动路径。不要将其重新接入运行中的启动助手。仓库不包含开发阶段的原入口实验工作流或研究脚本。

## 构建与测试

开发依赖：Node.js 24+、Python 3.10+。macOS 原生助手需要 Xcode Command Line Tools，构建为 arm64 / x86_64 通用程序。

```bash
npm ci --ignore-scripts
npx playwright install chromium --only-shell
python scripts/build_release.py
npm test
python scripts/audit_release.py
```

单独构建 Windows：`python scripts/build_release.py --platform Windows`。单独构建 macOS：在 Mac 上执行 `python scripts/build_release.py --platform macOS`。输出到 `dist/`，包含 ZIP 和校验清单，每个平台只有三个用户操作入口。

PowerShell 的环境、安装与恢复测试分别使用 `tests/environment.ps1`、`tests/windows.ps1` 和 `tests/activation-watch.ps1`。Windows 原生安装测试为 `tests/windows-native.ps1`。测试中使用临时用户目录、独立端口和模拟环境 API，不修改真实环境变量、不连接开发机器的 Codex。

`main`、`fix/**` 推送及手动运行会触发双平台 Actions，测试及审计通过后上传安装包，保留 30 天，不创建 Release。macOS 作业同时生成两个平台的包；Windows 作业单独验证 Windows 包。

## 运行边界

额度约每分钟刷新，Token 和窗口连接约每五秒刷新。Token 是累计用量，不等同于当前上下文大小。未知、不可访问或过期数据必须保留明确的不可用状态。

后台仅连接已开启的回环端口，不通过退出重开启用调试连接。Windows 补交丢失请求必须有近期系统事件证据、旧容器销毁和稳定退出检查，单次消费、过期放弃、手动重试取消，禁止循环拉起或强制退出。

修改时不要读取真实账号与聊天内容，也不要用原生客户端作为可随意启停的测试应用。用户本机的安装、卸载和重启由用户执行。
