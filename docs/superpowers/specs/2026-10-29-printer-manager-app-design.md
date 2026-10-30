# 设计：eSTUDIO 打印机管理 app

日期：2026-10-29
状态：已与用户确认，待评审

## 目标

给 e-STUDIO2323AM / 2823AM macOS 驱动补一个图形界面，让用户**像正常打印机驱动一样**
完成：安装驱动、添加打印机、设置/修改端口（IP）、打印测试页、删除打印机、卸载驱动。

不做：局域网打印机扫描、USB 队列、Windows 桥接/共享。

## 用户交互（形态）

一个独立 app：**eSTUDIO 打印机管理.app**，双击打开。技术选型：AppleScript
Application（`osacompile` 打包），UI 使用系统原生 `display dialog` / `choose from list`，
提权使用 `do shell script … with administrator privileges`（系统标准密码框）。
零第三方依赖、体积小、构建简单。界面语言为简体中文。

主流程：

1. 启动时检查驱动是否已安装（filter + PPD 是否在系统目录）。
   - 未安装 → 询问「驱动未安装，是否现在安装？」→ 安装。
2. 主菜单（`choose from list`）：添加打印机 / 设置端口 / 打印测试页 / 删除打印机 /
   卸载驱动 / 退出。
3. 添加打印机：依次询问
   - 队列名（默认 `eSTUDIO2823AM`，可改；校验仅允许字母数字 `_` `-`，非空、不与现有队列冲突）
   - IP 或主机名（可填纯 IP/主机名，或完整 `socket://host:port`；默认端口 9100）
   - 是否设为默认打印机（是/否）
   - 是否立即打印测试页（是/否）
4. 设置端口：从已有队列列表选中 → 填新 IP/主机名 → `lpadmin -p NAME -v …`。
5. 打印测试页：从已有队列列表选中 → `lp -d NAME /etc/hosts`。
6. 删除打印机：从已有队列列表选中 → 确认 → 删队列 + 对应 PPD 配置 + app 偏好。
7. 卸载驱动：确认 → 移除 filter + PPD、重启 cupsd；再问是否连带删除本驱动创建的队列。

只读操作（列队列）不提权；所有写操作都弹管理员密码框。错误一律弹红色错误框并显示
stderr 末尾内容，不静默失败。

## 架构与分工

界面与权限操作解耦成两个单元：

- `app/main.applescript` —— 仅界面流程：收集输入、展示结果、串起来。不含业务逻辑。
- `scripts/estudioctl.sh` —— 非交互命令行，所有实际操作的单点实现。子命令：
  - `status` —— 输出驱动是否已安装（供 app 判断）
  - `install-driver` —— 安装 filter + PPD，重启 cupsd
  - `uninstall-driver [--remove-queues]` —— 卸载驱动，可选删除队列
  - `list` —— 列出本驱动的队列（`队列名<TAB>URI`）
  - `add NAME IP [--default] [--test]` —— 建 `socket://IP:9100` 队列
  - `set-port NAME IP` —— 修改已有队列的端口
  - `testpage NAME` —— 打印测试页
  - `remove NAME` —— 删除队列及其配置
  - 全局 `--dry-run` —— 只打印将要执行的命令，不改系统

AppleScript 调用方式：

```
do shell script "<ctl 绝对路径> <子命令> …" with administrator privileges
```

`scripts/install.sh` 改为薄封装，内部调用 `estudioctl.sh install-driver`
（可选 `--queue` 时再调 `add`），保证 README 里现有命令继续可用。

### 单元职责与接口

- `estudioctl.sh`：
  - 输入：子命令 + 参数；`--dry-run` 开关。
  - 输出：成功向 stdout 打印人类可读结果；失败向 stderr 打印原因，返回非 0。
  - 依赖：`lpadmin`、`lpstat`、`lp`、`install`、`launchctl`（均为系统自带）。
  - 可脱离 GUI 单独测试与使用。
- `main.applescript`：
  - 输入：用户点击与输入框内容。
  - 输出：弹窗/列表。
  - 依赖：`estudioctl.sh`（仅通过子命令交互，不直接碰系统）。

## 数据流

用户操作 → AppleScript 收集参数并拼出子命令 → `do shell script … with administrator
privileges` → `estudioctl.sh` 执行 `lpadmin`/`install` → stdout/stderr 回传 →
AppleScript 展示结果。app 不直接读写 CUPS 文件。

## 端口 / URI 规则

- 输入是纯 IP 或主机名 → URI = `socket://<输入>:9100`。
- 输入已含 `://` → 原样作为 URI。
- 校验：去掉空白；含 `://` 时必须以 `socket://` 开头（其它 scheme 拒绝并提示）；
  否则只允许 `[A-Za-z0-9._-]` 与可选的 `:端口`。

## 卸载时清理的内容

- 删除打印机：`lpadmin -x NAME`，CUPS 连带删除 `/etc/cups/ppd/NAME.ppd`。
- 卸载驱动：删除 `/usr/libexec/cups/filter/rastertoestudio` 与
  `/Library/Printers/PPDs/Contents/Resources/eSTUDIO2823AM.ppd`，重启 cupsd；
  `--remove-queues` 时逐个 `lpadmin -x`。
- 不直接编辑 `/etc/cups/printers.conf`（由 cupsd 维护）。
- app 不保存额外状态（默认值与列表都实时从系统读取），因此没有需要单独清理的
  偏好文件；“删除配置文件”即删除队列与 `/etc/cups/ppd/NAME.ppd`。

## 构建

- `make app` → `osacompile -o "app/build/eSTUDIO 打印机管理.app" app/main.applescript`，
  将 `scripts/estudioctl.sh` 复制进 `Contents/Resources/`，写 `Info.plist`
  （`CFBundleName`、`CFBundleDisplayName`、`LSMinimumSystemVersion`、
  `NSHighResolutionCapable`）。
- 构建后可选 `codesign --force --deep --sign -`（ad-hoc）。本机构建可直接打开；
  分发到其它机器后首次需右键 →「打开」。

## 测试

- `make test-appctl`：调用 `tools/checkappctl.sh`，对每个子命令用 `--dry-run`
  断言拼出的 `lpadmin`/`install`/`lp` 命令行正确（不需要 root、不碰系统）。
  覆盖：装/卸驱动、add（含 `--default`/`--test`/完整 URI）、set-port、remove、
  非法输入（空队列名、非法字符、非 socket scheme）返回非 0。
- 人工测试清单（写入 README）：装驱动 → 添加打印机 → 改 IP → 打印测试页 →
  删除打印机 → 卸载驱动，每步在「系统设置 → 打印机与扫描仪」与 `lpstat` 核对。
- 真机集成（可选）：对 `192.0.2.10` 走一遍添加 → 测试页 → 删除。

## 明确不做 / 边界

- 不做 UDP/mDNS 扫描；IP 由用户手动填写。
- 不支持 USB 队列。
- 不接管/替换系统自带「添加打印机」流程；app 只做本驱动的管理入口。
- 不改动本仓库既有 filter / PPD / 协议逻辑，仅新增 app 与把安装逻辑抽到
  `estudioctl.sh`。
