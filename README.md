# AppTrafficMonitor

原生 macOS 菜单栏流量监控工具，使用 Swift、AppKit 和系统 SQLite。当前可用功能基于正在运行的 Clash Verge/Mihomo，只读采集应用与访问目标的「Clash 已观测」上传、下载和合计用量。

## 功能与边界

- 应用、域名/IP、统计图三个页签，支持应用访问目标下钻。
- 应用与目标列表支持搜索、表头排序；数值排序直接比较原始字节数。
- 支持预设与自定义时间范围，以及小时、天、周、月统计粒度。
- 支持 Top 应用多选联动，按应用集合查看访问目标与历史趋势。
- 近期分钟汇总约保留 48 小时，更早压缩为日汇总，默认保留约 400 天。
- 菜单栏提供暂停/继续、统计窗口和退出入口；关闭窗口后继续采集。

Mihomo 活跃连接周期快照可能漏掉短连接和关闭前的末段数据，因此统计值标为「已观测」，不能当作服务商账单或完整网络用量。绕过 Clash 的直连不在此口径内；无法可靠关联的应用保留为未归属。

仓库保留 NetworkExtension 系统扩展源码，但当前应用不内嵌该扩展，全系统观测尚未完成激活与真机验收。

## 开发环境

- Apple Silicon Mac，macOS 14 或更高版本。
- 包含 Swift 6 工具链的 Xcode（本地 Swift Package 使用 tools version 6.0，源码语言模式为 Swift 5）。
- 重新生成 Xcode 工程时需要 XcodeGen；仓库已包含工程和共享 scheme。
- 运行采集功能时需要本机已启动 Clash Verge/Mihomo；构建与纯逻辑测试无需运行 Clash。

当前配置排除 x86_64，仅构建 arm64。最低系统版本兼容性、Intel 构建和正式分发须分别验证。

## 构建、测试与运行

```bash
make test
make CONFIG=Release build
make CONFIG=Release install-local
open /Applications/AppTrafficMonitor.app
```

`make config` 会从模板生成已被 Git 忽略的 `Config/Local.xcconfig`。当前主应用构建不使用开发者签名，逻辑测试使用 ad-hoc 签名；将来开发系统扩展时再填写自己的团队参数。不要将个人参数写入共享配置。

以下参数可在启动时直接打开统计页面：

```bash
open /Applications/AppTrafficMonitor.app --args --show-stats
open /Applications/AppTrafficMonitor.app --args --show-charts
```

安装目标会替换 `/Applications/AppTrafficMonitor.app`。退出时通过菜单栏「退出 AppTrafficMonitor」停止本应用的观测并提交已收到的数据；不会退出或修改 Clash。

## 打包

```bash
make CONFIG=Release dmg
```

产物为 `build/AppTrafficMonitor-0.1.0.dmg`。当前打包采用 ad-hoc 签名，未做 Apple 公证；其他机器下载后可能被 Gatekeeper 拦截。正式分发需要另外配置 Developer ID 签名和公证。

GitHub Actions 流水线尚未配置。后续可以使用 macOS arm64 runner 执行测试和上述打包目标；签名证书及凭据应通过仓库 Secrets 注入。

## 数据与隐私

- SQLite 数据库位于 `~/Library/Application Support/AppTrafficMonitor/traffic.sqlite`，记录应用、目标主机/IP、时间桶和字节计数。
- Mihomo 控制接口凭据在运行时从本机配置读取，不写入 SQLite 或日志。
- 不修改 Clash 节点、规则、模式或网络配置。
- 本地数据库、签名材料、私有配置、构建缓存和工具会话目录已加入 `.gitignore`。
- 如需清除历史，先退出应用，再删除上述专用数据目录；如需卸载，退出后删除应用。当前应用不内嵌系统扩展。

## 项目结构与文档

| 路径 | 内容 |
| --- | --- |
| `App/` | 菜单栏与统计窗口 |
| `Extension/` | 尚未完成激活验收的系统扩展 |
| `Modules/` | 统计、存储、Mihomo 只读适配与共享模块 |
| `Tests/LogicTests/` | 纯逻辑测试 |
| `Tools/mihomo-probe/` | 开发期只读诊断工具 |
| `project.yml` | XcodeGen 工程定义 |
| `PROMPT.md` | 原始产品需求 |
| `DEVELOPMENT_PLAN.md` | 原始架构规划与分阶段验收标准 |
| `docs/DEVELOPMENT.md` | 当前实现、技术决策、验证记录与后续事项 |

需求和计划包含尚未完成的目标；当前实现状态以本 README 和开发说明为准。
