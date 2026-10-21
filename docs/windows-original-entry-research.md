# Windows 原入口、无重启加载实验

验证日期：2026-10-21。测试只在 GitHub 托管的独立 Windows 虚拟机内运行，没有操作开发机器上的 Codex、已安装插件、用户环境变量或账号配置。

## 结论和边界

当前客户端可以通过环境变量，在原 Windows 应用入口首次启动时开放连接，由已运行的插件后台自动加载脚本，过程中无需退出并重开 Codex，也无需修改原生程序文件。

必要条件是同时使用 `BUILD_FLAVOR=dev` 和 `CODEX_ELECTRON_CHROMIUM_SWITCHES`。仅设置后一个变量在正式模式下无效。这个结论验证的是启动、连接和自动执行插件脚本；云端没有登录 ChatGPT，未验证真实账号用量及登录后侧栏用量条的显示，不能据此宣布完整安装方案已稳定可交付。

`BUILD_FLAVOR=dev` 是内部开发模式开关，作用范围超过用量条加载：客户端默认应用数据目录会选择 `Codex (Dev)`，客户端内置的更新启用判断也会改变。实验明确指定了独立数据目录；后续实现必须审查已有数据目录、登录状态、更新行为及环境变量作用范围，不能直接将实验变量应用到用户机器。Microsoft Store 自身的更新机制没有在本实验中验证。

## 实验方法

- 从 OpenAI 官方地址下载同版本 `26.1013.4894.0` 的 x64 / ARM64 MSIX，使用系统包管理注册。未重打包或修改客户端。
- 通过 `IApplicationActivationManager.ActivateApplication` 激活 `OpenAI.Codex_2p2nqsd0c76g0!App`，参数为空，选项为 `AO_NONE`。没有替换快捷方式，也没有给原入口添加调试参数。
- 环境变量写入云端临时用户环境并广播环境变更。连接参数为回环地址 `127.0.0.1`、实验端口 `49327`。每组使用独立的 `CODEX_HOME` 和 `CODEX_ELECTRON_USER_DATA_PATH`。
- 正式测试先启动本仓库生成的真实 `agent.cjs`，然后激活客户端。没有运行启动控制器或 supervisor。每次只调用一次应用激活；测试组之间的关闭仅用于准备下一次独立启动。
- 检查程序使用 `--observe-only`，读取已经存在的插件状态，不注入脚本。`preexistingAgentBootstrap=true` 与 agent 日志共同证明自动加载来自已运行的后台。
- 记录进程启动/退出、可见主窗口、端口就绪、后台附加时间，以及插件附加前后主进程 PID。实验开始与结束核对原始 `app.asar` 的 SHA-256。

## 结果

[真实后台自动附加实验及证据](https://github.com/sz6660/codex-usage-badge/actions/runs/39543869302)，提交 `98a8307003ac1bba2c5f75a31ffe4574bfb48ec9`。

| 环境 | 默认模式 | 仅参数变量 | dev 模式首次：窗口 / 自动附加 | dev 模式重复：窗口 / 自动附加 |
| --- | --- | --- | --- | --- |
| Windows Server 2025 x64 | 窗口正常，无调试端口 | 窗口正常，无调试端口 | 4.81 秒 / 9.23 秒 | 4.26 秒 / 4.27 秒 |
| Windows 11 Enterprise ARM64 | 窗口正常，无调试端口 | 窗口正常，无调试端口 | 5.08 秒 / 5.09 秒 | 4.77 秒 / 4.77 秒 |

四次 dev 模式启动均满足：

- 只出现一个应用主进程，主窗口进程没有在加载期间被替换。
- 插件自动附加前后主进程 PID 相同，未调用退出/重开逻辑。
- 检查程序未注入，已读取到 usage v46、colors v2、tokens v7、sizes v2 的实际插件状态。
- 原生 `app.asar` 哈希保持一致。

截图处于真实登录页，`usage.placed=false`、`badgeCount=0`，没有伪造登录状态、侧栏或账号用量。这些结果也不能代表 Windows 11 x64 本机验收、macOS 验证、长期稳定性或未来 Codex 版本的兼容性。

较早的[手动脚本连接实验](https://github.com/sz6660/codex-usage-badge/actions/runs/39543121111)也在两种架构上成功。首轮实验的日志订阅错误已修正，其不完整的后续测试组不作为通过证据。

## 证据和代码

Actions 附件分别包含 `report.json`、各组 `*-renderer.json`、空账号登录页截图和插件后台日志；不包含客户端安装包、账号目录或开发机器文件。

- [隔离工作流](../.github/workflows/startup-research.yml)
- [MSIX 注册、原入口激活与进程采集](../scripts/research/windows-original-entry.ps1)
- [只读插件状态检查](../scripts/research/probe-renderer.cjs)

脚本拒绝在普通本地环境执行。此研究分支没有生成新的交付安装包，也没有安装插件、发布 Release 或更改开发机器的应用环境。
