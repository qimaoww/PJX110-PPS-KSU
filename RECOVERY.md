# DTBO 启动失败恢复指南

补丁模式和全分区模式写入的都是当前活动槽的完整 DTBO 分区镜像。如果错误的 DTBO
导致系统卡开机，KernelSU 模块代码没有机会运行，因此“禁用模块”或“删除模块”本身
不能自动撤销已经写入分区的 DTBO。

本项目会在写入任何 PPS DTBO **之前**，为目标物理槽生成独立救援快照：

```text
/data/adb/PJX110_PPS_KSU/rescue/
├── restore_stock.sh
├── last_write
├── slot_a/
└── slot_b/
```

救援目录不在 `/data/adb/modules/PJX110_PPS_KSU` 模块目录内。删除模块后，只要
`/data` 没有被清除，它仍会保留。快照包含精确原厂完整镜像、槽位 manifest、SHA256、
AVB footer/VBMeta 校验器以及最后写入槽记录。救援写入完成后还会读取整个 DTBO 分区
并校验 SHA256。

缺失或损坏的最后写入日志不会触发自动猜槽；分区大小无法确认、目标不是真实 DTBO 块设备、
镜像 SHA256/AVB 异常时均拒绝恢复。模块更新后，原有快照保留其登记时的独立校验器与固定
哈希，不会因为新模块校验器的哈希不同而失效。

## 一、Android 还能启动

优先在 WebUI 点“原厂”。这条路径会按当前槽位、manifest、AVB 和 SHA256 校验后恢复。
确认恢复成功并重启正常后，再卸载模块。

## 二、Android 卡开机，但能进入第三方 Recovery

必须先让 Recovery 挂载并解密 `/data`。在 Recovery 的 ADB shell 或终端中运行：

```sh
sh /data/adb/PJX110_PPS_KSU/rescue/restore_stock.sh check last
sh /data/adb/PJX110_PPS_KSU/rescue/restore_stock.sh restore last
```

`last` 使用写入前保存的最后写入槽记录，不以 Recovery 当前启动槽盲猜。日志缺失或损坏时
会拒绝恢复，避免设备自动换槽后误刷另一槽。必须先确认故障物理槽，再明确执行其中一个：

```sh
sh /data/adb/PJX110_PPS_KSU/rescue/restore_stock.sh check a
sh /data/adb/PJX110_PPS_KSU/rescue/restore_stock.sh restore a
```

或把最后一个参数改为 `b`。不要在不确定槽位时轮流刷两个槽。

恢复输出必须包含：

```text
Stock DTBO restored and full-partition SHA256 readback verified.
```

没有该行就不能视为恢复成功。

## 三、模块目录已经删除

仍使用上面的 `/data/adb/PJX110_PPS_KSU/rescue/restore_stock.sh`。它是独立脚本，不依赖
KernelSU 模块目录。补丁模式启用及每次 PPS 写入前还会尽力把同样的救援目录复制到：

```text
/sdcard/Ace3Pro_PPS_Backup/recovery/
```

建议在第一次写 PPS 前把该目录通过 USB 复制到电脑。`/sdcard` 与 `/data` 通常属于同一
用户数据分区；清除数据会同时失去这两个副本，所以电脑副本才是离机备份。

Android 仍能进入 ADB 时可执行：

```powershell
adb pull /sdcard/Ace3Pro_PPS_Backup/recovery .\Ace3Pro_PPS_recovery
```

Recovery 中若 `/data` 可解密，优先使用 `/data/adb/.../rescue/restore_stock.sh`；只有
该路径不可用时，才把电脑保存的 `recovery` 目录传回 Recovery 的临时目录后执行。脚本
始终只查找固定名称的 `dtbo_a`/`dtbo_b`，不会接受其他分区参数。

## 四、Recovery 无法解密 `/data`

不要使用其他版本或来源不明的 `dtbo.img`。使用此前复制到电脑的本机救援目录，在能够
访问 DTBO 块设备的 Recovery 中传回 `/tmp` 后执行其中的脚本。若没有离机备份，只能从
**完全相同的 PJX110 固件版本**提取原厂完整 DTBO，并先核对镜像大小、AVB footer/VBMeta
及 SHA256。不能用 400、301、701、1001 中“看起来接近”的版本代替未知固件。

## 五、只能进 bootloader/fastboot

可以在电脑上**手动刷回故障槽的原厂 DTBO**。以下不是一键恢复脚本；仅操作
`dtbo_a` 或 `dtbo_b`，不刷其他分区，不解锁/重锁 Bootloader，不清除数据。

### 1. 确认镜像与故障槽

- Bootloader 必须已经解锁。使用与故障槽固件**完全一致**的原厂完整镜像：优先用救援目录
  `slot_a/<stock_sha>/stock.img` 或 `slot_b/<stock_sha>/stock.img`；也可用对应固件的 `*_stock.img`。
- 不能使用 33W/55W 镜像、`current` 档位备份、其他版本原厂镜像或来源不明的 `dtbo.img`。
- 原厂 SHA256 以备份 manifest 的 `stock_sha` 或 [固件清单](FIRMWARES.md) 的 `stock` 行为准。
  镜像须已通过完整 DTBO/VBMeta/AVB 校验；没有可信校验记录时，不刷。
- 故障槽以之前的写入记录/备份 manifest 为准。设备可能自动换槽，`current-slot` **不一定是故障槽**。
  无法确定槽位或版本时停止，不要轮流刷两个槽。

在 PowerShell 7 中检查连接与 Bootloader 信息：

```powershell
fastboot devices
fastboot getvar unlocked
fastboot getvar current-slot
```

如连接多台设备，后续每条 `fastboot` 命令都加 `-s <设备序列号>`。Bootloader 返回锁定、
变量不支持且无法另行确认，或读取失败时，不进入刷写步骤。

### 2. 校验电脑上的原厂镜像

将确认过的原厂镜像保存为 `dtbo_stock.img`，填写其可信 SHA256：

```powershell
$image = (Resolve-Path -LiteralPath .\dtbo_stock.img).Path
$expectedStockSha256 = '填写对应原厂镜像的64位SHA256'
if ($expectedStockSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw '请先填写可信的原厂 SHA256' }
if ((Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash -ine $expectedStockSha256) { throw '原厂镜像哈希不匹配，禁止刷写' }
$bytes = [IO.File]::ReadAllBytes($image)
if ($bytes.Length -lt 64 -or [Text.Encoding]::ASCII.GetString($bytes, $bytes.Length - 64, 4) -ne 'AVBf') { throw 'AVB footer 缺失，禁止刷写' }
(Get-Item -LiteralPath $image).Length
```

最后一行是镜像字节数，须与目标分区大小一致；本项目内置镜像为 `25165824` 字节
（`0x1800000`，24 MiB）。上述 footer 检查不能替代完整结构校验，只适用于前面确认过、
哈希完全一致的原厂白名单镜像或此前已完整验证的原厂备份。

### 3. 只刷已确认的故障槽

**故障槽为 A：** 先读取大小：

```powershell
fastboot getvar partition-size:dtbo_a
```

读取成功且大小与上一步一致后，单独执行：

```powershell
fastboot flash dtbo_a "$image"
```

**故障槽为 B：** 仅在记录明确指向 B 时使用，不要再执行 A 槽命令。

```powershell
fastboot getvar partition-size:dtbo_b
```

同样先确认读取成功、大小一致，再单独执行：

```powershell
fastboot flash dtbo_b "$image"
```

只执行其中一组。出现 `FAILED`、分区不存在或大小不一致时停止，不使用强制参数，不切换槽位，
也不刷 `boot`、`vendor_boot`、`init_boot`、`vbmeta`、`super`、`userdata`。

### 4. 区分“写入成功”和“恢复已验证”

fastboot 的 `OKAY` 只表示命令成功，**不等于完整分区回读验证通过**。若设备支持读取 DTBO，
可回读对应槽；下面以 A 为例，B 槽必须改为 `dtbo_b`：

```powershell
fastboot fetch dtbo_a .\dtbo_a_readback.img
if ($LASTEXITCODE -ne 0) { throw '设备不支持 DTBO 回读；不能据此认定恢复已验证' }
if ((Get-FileHash -LiteralPath .\dtbo_a_readback.img -Algorithm SHA256).Hash -ine $expectedStockSha256) { throw 'DTBO 回读哈希不一致，停止操作' }
```

`fetch` 支持取决于设备，很多实现不允许读取 DTBO；不要改为读取其他分区或跳过校验。
无法回读时，应进入能够读取 DTBO 的 Recovery，或在 Android 恢复启动且 Root 可用后，
读取同一槽的完整 SHA256 再与原厂值核对。A 槽示例：

```powershell
fastboot reboot
adb shell "su -c 'sha256sum /dev/block/by-name/dtbo_a'"
```

只有完整 SHA256 与原厂值一致才算恢复验证完成；不能启动或无法完成回读时，不要继续刷
其他分区。模块的自动写入/救援脚本仍保留原有 AVB、槽位、SHA256 和完整回读门禁。

## 六、bootloader、fastboot、Recovery 都无法进入

这已经不是模块能够自行处理的“卡开机/软砖”。软件救援脚本无法在设备上运行，需要使用
OPPO/OnePlus 官方售后或获授权的底层恢复方式。不要把来源不明的 EDL/工程工具当作本项目
的自动恢复方案。

## 必须避免

- 不要删除 DTBO 的 AVB footer 或 VBMeta。
- 不要写入 DTBO 之外的任何分区；本项目救援只允许恢复明确目标槽的 `dtbo_a` 或 `dtbo_b`。
- 不要因为设备处于解锁状态就跳过 SHA256、槽位和 AVB 校验。
- 不要把 A 槽备份写入 B 槽，也不要把 OTA 前的旧固件 DTBO 写到 OTA 后的新固件。
- 不要只凭文件名判断固件；本项目以完整 SHA256 和严格 manifest 为准。
