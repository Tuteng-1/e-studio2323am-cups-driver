# e-STUDIO2323AM / 2823AM — macOS 原生驱动

TOSHIBA e-STUDIO2323AM（同系列 2823AM）只有 Windows GDI 驱动。这个项目把它的
真实线缆协议逆向出来，做成 **原生 CUPS 驱动**：一个 filter + 一个 PPD，
直接用系统自带的 `socket` backend，不依赖 Windows、不需要共享打印、不需要桥接。

```
PDF/图片 → cupsfilter → CUPS raster → rastertoestudio → PJL + JBIG → socket://ip:9100
```

协议结论全部来自实体 Windows 驱动抓包（`eSTUDIO2323AM-captures/`），
并且用 25 份抓包（29 页）做了逐字节回归：解码每页 → 重新编码 → 与原文件比较。

## 当前状态

| 部分 | 状态 |
|---|---|
| 协议 | ✅ PJL + JBIG-1（不是私有命令流） |
| 编码参数 | ✅ 与抓包**逐字节一致**（`make test-capture` 25/25 文件通过） |
| 页尺寸 / 物理原点 | ✅ 可打印区居中贴回整页，位置与 Windows 驱动一致 |
| 纸张 / 纸盒 / 省墨 / 平滑 | ✅ 映射为 PJL 行 |
| 多页 / 多份 | ✅ 与驱动相同的 `COPYEND` 作业重复方式，`make test-replay` 逐字节通过 |
| 横向 | ⚠️ 已实现旋转 + `ORIENTATION=LANDSCAPE`，方向待上机确认 |
| 双面 | ➖ 机器本身没有自动双面单元；始终单面（`DUPLEX=OFF`），PPD 不再提供该选项 |
| 实机打印 | ✅ 2026-10-29 把 filter 生成的一页 A4 直发 9100，TopAccess 打印计数 45002 → 45003（纸面位置/方向待目视确认） |

## 构建与自测

```sh
make                 # 编译 filter（含 vendored jbigkit）
make test            # 合成 raster → filter → 解码/DOTCOUNT/重编码校验
make test-pdf        # 真实链路：PDF → cgpdftoraster → filter（两页 A4 600dpi）
make test-options    # PPD 选项 → PJL 行 / 纸张尺寸 / 多份结构映射
make test-capture    # 25 份实体机抓包逐字节回归
make test-replay     # 抓包位图还原成 raster 重放 filter，再逐字节比对（最强验证）
make test-appctl     # 打印机管理 CLI 自测（PATH 桩，无需 root、不碰系统）
make app             # 打包「eSTUDIO 打印机管理.app」
```

`make test-capture` 会调用 `tools/prncheck`：它把每页的 `IMAGELEN` 分块拼回去，
用 jbig 解码器解回位图，核对 `DOTCOUNT`，再用 `estudio_jbig_encode()` 重新编码，
要求与原抓包**完全一致**。全部 29 页样本（含 900KB 的灰阶页、多页作业、
三份重复作业）都通过。

`make test-replay` 更进一步：把每份抓包解码出的位图按 PPD 的 99 px 可印区裁回，
重建成 CUPS raster，重新跑一遍 filter，输出与 Windows 原始打印流逐字节比对
（只忽略时间戳）。它同时验证了页面拼装、贴回位置、方向、纸张、份数结构，
不只是编码器。23 份可重放样本全部通过；`12_*_300`（4960 px 宽）和
`19_*_custom100x150`（自定义纸）因为 PPD 里没有对应固定纸型而跳过。

## 安装

```sh
sudo ./scripts/install.sh --queue 192.0.2.10    # 装驱动 + 建 socket:// 队列
sudo ./scripts/install.sh                        # 只装驱动
```

手动等价操作：

```sh
sudo lpadmin -p eSTUDIO2823AM -E -v socket://192.0.2.10:9100 \
     -P /Library/Printers/PPDs/Contents/Resources/eSTUDIO2823AM.ppd
```

USB 连接请先 `system_profiler SPUSBDataType` 确认型号，再建
`usb://TOSHIBA/e-STUDIO2823AM` 队列。

## 图形界面（推荐）

```sh
make app      # 产出 app/build/eSTUDIO 打印机管理.app
```

双击打开即可：

- 安装 / 卸载驱动（卸载时可选一并删除本驱动创建的打印机）；
- 添加打印机：填队列名（默认 `eSTUDIO2823AM`）与 IP，可选设为默认、添加后立即打印测试页；
- 设置端口：选中已有打印机，改成新的 IP（自动补 `socket://` 与 `:9100`）；
- 打印测试页；
- 删除打印机：连同该队列的配置文件一起清理；
- 查看状态：驱动是否已安装、当前有哪些本驱动的打印机及其地址。

需要管理员权限的步骤会弹系统标准密码框。app 只是外壳，所有实际操作都由
`scripts/estudioctl.sh` 完成，它也能直接命令行使用：

```sh
./scripts/estudioctl.sh status
sudo ./scripts/estudioctl.sh install-driver
sudo ./scripts/estudioctl.sh add eSTUDIO2823AM 192.0.2.10 --default --test
sudo ./scripts/estudioctl.sh set-port eSTUDIO2823AM 192.0.2.20
sudo ./scripts/estudioctl.sh testpage eSTUDIO2823AM
sudo ./scripts/estudioctl.sh remove eSTUDIO2823AM
sudo ./scripts/estudioctl.sh list
sudo ./scripts/estudioctl.sh uninstall-driver [--remove-queues]
./scripts/estudioctl.sh --dry-run add eSTUDIO2823AM 192.0.2.10   # 只打印将执行的命令
```

### 人工测试清单

1. `make app`，双击 `app/build/eSTUDIO 打印机管理.app`；未装驱动时应提示安装。
2. 安装驱动后，「系统设置 → 打印机与扫描仪」应出现该打印机。
3. 添加打印机（填真实 IP）→ `lpstat -v` 能看到 `socket://IP:9100`。
4. 打印测试页 → 出纸一页。
5. 设置端口改成另一个 IP → `lpstat -v` 显示新 URI。
6. 删除打印机 → `lpstat -v` 不再有该队列，`/etc/cups/ppd/<名字>.ppd` 被删除。
7. 卸载驱动 → `/usr/libexec/cups/filter/rastertoestudio` 与
   `/Library/Printers/PPDs/Contents/Resources/eSTUDIO2823AM.ppd` 都消失。

## PPD 选项

| 选项 | 说明 |
|---|---|
| `PageSize` | A4 A5 A3 B4 B5 Letter Legal Tabloid Statement FanFoldGermanLegal Env10 EnvDL EnvC5 EnvMonarch Postcard 8.5x8.5 |
| `Resolution` | 只有 600×600（引擎固定 600dpi） |
| `InputSlot` | 自动 / 纸盒 1 / 纸盒 2 / 手送（→ `MEDIASOURCE`） |
| `MediaType` | Plain / Thin / Thick / Envelope / Transparency / Recycle（→ `MEDIATYPE`） |
| `TonerSave` | → `TONERSAVE=ON/OFF` |
| `Smoothing` | → `SMOOTHING=ON/OFF` |

纸张的 PJL 拼写（`A4`、`JISB5`、`ENV_10`、`JPOST`…）取自 `eSSh6OCM.dll` 的字符串表，
不是猜的。所有纸型的 `*ImageableArea` 四边留 99 px（11.88 pt ≈ 4.19 mm）——
抓包显示 Windows 驱动 DC 的 (0,0) 落在整页位图的 (99,99)，五种纸型一致。

2323AM/2823AM 没有自动双面单元，所以 PPD 不提供 `Duplex` 选项，filter 也始终
发 `@PJL SET DUPLEX=OFF`、不发 `BINDING`（与所有抓包一致）。

## 调试

```sh
# 直接把 CUPS raster 转成打印流，并校验
ESTUDIO_DEBUG=1 ./rastertoestudio 1 user title 1 "PageSize=A4" page.raster > out.prn
./tools/prncheck out.prn --pbm /tmp/bands     # 解码每页并导出 PBM
```

`ESTUDIO_DEBUG=1` 会往 stderr 打印每页的 raster 尺寸、JBIG 字节数、黑点数；
CUPS 把 filter 的 stderr 写进 `/var/log/cups/error_log`。

## 已知不确定的地方

- **横向旋转方向**：抓包里 `ORIENTATION=LANDSCAPE` 时位图仍是纵向页框、内容被
  逆时针旋转过（原始左上角落到纸面左下角）。正常 CUPS 队列里 pdftopdf 已按
  `orientation-requested=4` 转好，filter 只置标志；若上游直接给横向 raster，
  filter 自己旋转。方向若在实机上是反的，改 `rotate_mono()`。
- **空白页会被跳过**：`DOTCOUNT=0` 的页设备不计数（Windows 驱动同样如此）。
  双面抓包 `20_duplex_2p` 里也始终是 `DUPLEX=OFF`，这台机器没有自动双面单元。
- **多份打印**：Windows 驱动是整份作业重复 N 次、每次以 `@PJL COPYEND` 结束，
  filter 照做；`COPIES` 恒为 1（设备似乎不认这个字段）。

## 目录

```
src/rastertoestudio.c     CUPS filter（raster → PJL + JBIG）
src/estudio_jbig.c/.h     JBIG 编码封装（实测参数 + DOTCOUNT）
third_party/jbigkit/      jbigkit 2.1（GPL-2+，含一个本地编译开关）
ppd/eSTUDIO2823AM.ppd     PPD
tools/prncheck.c          打印流校验器（解码 + DOTCOUNT + 重编码比对）
tools/mkraster.c          生成测试用 CUPS raster
tools/checkopts.sh        PPD 选项 → PJL 行映射自测
tools/replay.py           抓包位图 → raster 重放 → 与原始打印流逐字节比对
tools/mkpdf.py            生成测试用多页 PDF（走真实 CUPS 链路）
scripts/estudioctl.sh     打印机管理 CLI（安装/添加/改端口/测试页/删除/卸载）
scripts/install.sh        安装脚本（estudioctl.sh 的薄封装）
app/main.applescript      「eSTUDIO 打印机管理.app」界面（只调 estudioctl.sh）
scripts/build-app.sh      打包 app（osacompile + 塞入 filter/PPD/ctl）
tools/checkappctl.sh      estudioctl.sh 自测（PATH 桩，无需 root）
app/build/                打包产物（不入库）
docs/protocol-notes.md    协议笔记（实测结论 + 未验证项）
docs/capture-guide.md     Windows 抓包方案
eSTUDIO2323AM-captures/   抓包样本与实测报告
```

## 许可

filter、PPD、工具为本项目代码；`third_party/jbigkit/` 为 GPL-2+，
分发时请一并保留 `COPYING`。
