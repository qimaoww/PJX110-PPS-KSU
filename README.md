# OnePlus Ace 3 Pro PPS Profiles — v1.2.0

> **兼容性声明：PPS 33W/55W 仅在 `PJX110_16.0.2.400` 固件上实机测试通过。内置 ColorOS 15/16 共 19 个固件的完整镜像，其余版本已完成结构与哈希校验，但尚未实机验证。**

新增 ColorOS 15 的 401、500、600、701、703、801、820、830、831、840、850、860、861，
以及 ColorOS 16 的 500、501。每个版本均使用自身原厂 DTBO，保留原有 301/400/701/1001
镜像不变。完整版本、文件标识和 SHA256 见 [FIRMWARES.md](FIRMWARES.md)。
安装包内以 19 个独立压缩集保存镜像，刷模块时只根据当前 DTBO 的完整 SHA256 解压匹配
版本的原厂/33W/55W 三个镜像，镜像占用约 **72 MiB**。其余压缩集和自检临时镜像在安装
完成后删除，未知版本不保留内置原始镜像，只保留受校验约束的补丁模式工具。压缩存储仍是
全分区镜像，不是补丁。OTA 换入其他内置固件后，WebUI 禁用缺失镜像的操作并提示重装模块。
如果确认是与安装时不同的新原厂 DTBO，且驱动与动态资源可用，也会提供“检测并使用补丁”
入口；必须手动确认并完成完整校验、双档位试生成、原厂备份和救援快照，不会自动转换模式。
跨系统大版本的 500、701 等尾号
通过独立标识区分，镜像选择仍只依赖完整 DTBO SHA256。

v1.1.1 修复 301、701、1001 PPS 镜像缺失固件专属 AVB metadata/footer 的问题；400 镜像未改动。

v1.2.0 在 WebUI 加入动态补丁模式。内置白名单版本继续使用全分区模式；其他 PJX110
固件只有通过逐 entry 结构检查、AVB/footer 检查和原厂备份校验后才能手动启用补丁模式。
用户可在 WebUI 手动把补丁模式切换为全分区模式，切换前会重新生成并校验
stock/33W/55W 三个完整镜像；同一 DTBO 版本切换成功后不能返回补丁模式。

如果 OTA 在同一物理槽位换入新的原厂 DTBO，旧的补丁 manifest 不会被直接沿用；
WebUI 会要求重新进行驱动、结构、AVB/footer 和双档位试生成校验，并以新 DTBO
重新登记原厂备份。全分区 manifest、补丁器和模板完整性异常时，所有 PPS 生成/写入控制均关闭。
如果动态模式已处于 PPS 档，而后续 OTA 导致驱动 ABI、补丁器/模板或完整镜像集失效，
WebUI 仍只保留通过 manifest SHA256 校验的精确原厂备份恢复入口，不允许继续生成或写入 PPS。

补丁模式登记时会保存 33W/55W 双档位试生成的完整 SHA256；再次重建必须与登记结果一致，
否则拒绝 PPS 写入。备份和全分区镜像采用“临时复制、哈希/AVB 校验、原子重命名”保存。
动态主备份损坏时，独立救援快照中同槽、同原厂 SHA256 的副本只能用于恢复原厂，不放行 PPS。
原厂恢复不会因救援工具或写入日志损坏而被误挡，但仍必须通过槽位、分区大小、原厂 SHA256、
AVB 和完整回读检查。写入前会再次读取活动槽与当前 DTBO SHA256；状态变化即拒绝覆盖。
恢复到原厂后，可在 WebUI 的“状态详情”手动“重检补丁”，重建双档位登记并修复精确原厂
备份与救援文件；该动作不写入 DTBO。PPS 档位和任何全分区模式均不能执行此重检动作。

## 强制 AVB 要求

这是项目的硬性安全规则：任何被本项目接受、生成、恢复或写入的 DTBO 镜像都必须保留
有效的 AVB footer（`AVBf`）和对应 VBMeta。禁止删除、截断、清空或绕过 DTBO AVB
校验；缺失或结构损坏时，后端必须拒绝写入。动态 patcher 会在解析和输出验证时检查
AVB，最终写入路径还会再次检查 footer，并在分区回读后验证完整 SHA256。

## 强制分区边界

本项目只允许写入由可信底层槽位来源唯一确定的 `dtbo_a` 或 `dtbo_b`。所有目标路径均由
固定 DTBO by-name 路径解析，脚本不接受任意块设备或任意分区名作为写入参数。项目绝不写入
`boot`、`vendor_boot`、`init_boot`、`vbmeta`、`super`、`userdata` 或其他任何分区。

## 无法开机时的独立恢复

每次写入 PPS DTBO 前，后端必须先生成并验证当前物理槽的不可变原厂救援快照，然后持久化
最后写入槽日志。快照位于 `/data/adb/PJX110_PPS_KSU/rescue/`，不依赖 KernelSU 模块目录；
即使模块目录被删除，只要 `/data` 尚在且 Recovery 能挂载它，仍可执行：

```sh
sh /data/adb/PJX110_PPS_KSU/rescue/restore_stock.sh check last
sh /data/adb/PJX110_PPS_KSU/rescue/restore_stock.sh restore last
```

救援脚本只允许恢复 manifest 登记槽的精确原厂完整 DTBO，写入前检查镜像大小、SHA256、
`AVBf`、VBMeta/DTBO 结构和目标槽，写入后回读整个分区 SHA256。救援快照创建或验证失败时，
PPS 写入会在修改分区前终止。完整分级说明见 [RECOVERY.md](RECOVERY.md)。

本项目采用 [GNU General Public License v3.0](LICENSE) 开源。根据 GPL-3.0，修改或衍生版本在分发时也必须以 GPL-3.0（或兼容条款）提供对应源代码。

**Author:** qimaoaa  
**Target:** OnePlus Ace 3 Pro / PJX110 / corvette  
**PPS 已测试固件：** `PJX110_16.0.2.400`

**内置原厂固件：** ColorOS 15 共 13 个版本、ColorOS 16 共 6 个版本，详见固件清单。

**重要：除 `PJX110_16.0.2.400` 外的 PPS 档位均需实机验证；未知 DTBO 哈希仍不允许使用全分区模式。**

## WebUI profiles

WebUI 使用重新设计的充电概览和档位控制卡，哈希、节点与恢复信息放入折叠详情。
充电采集只读取固定 sysfs 节点；按 OPlus 驱动区分电池 mA 与 USB µA，优先读取两路电芯
电压和实时 `ppschg_ing`。无独立双电芯数据时明确标记估算；读失败或断充时不沿用旧值。
充电轻量轮询与完整 DTBO 校验分离；写入前的槽位、SHA256 和 AVB 门禁不使用显示缓存。
参考源码与固定版本记录在 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

- 原厂
- 33W PPS（11V / 3A，仅 `PJX110_16.0.2.400` 已实机验证）
- 55W PPS（11V / 5A，仅 `PJX110_16.0.2.400` 已实机验证）

## WebUI management modes

- **内置全分区模式：** 19 个固件均按完整 DTBO SHA256 选择对应镜像；同一 DTBO 版本不能使用补丁模式。
- **补丁模式：** 用于未内置的 PJX110 原厂 DTBO，或 OTA 换入与安装时不同且缺少镜像集的新内置原厂 DTBO。启用前必须通过所有 entry 的 corvette/CPA/UFCS CP/DPDM/ADSP 结构检查、PPS 驱动 ABI 标记检查，并验证 AVB metadata/footer 和原厂备份。
- **动态全分区模式：** 用户只能从补丁模式手动切换。切换时重新生成、持久化并校验 stock/33W/55W 三个完整镜像，同时确认当前活动槽哈希属于其中一个端点。

同一 DTBO 版本的模式转换是单向的：补丁模式到动态全分区模式。全分区模式禁止返回补丁。
唯一 OTA 例外是换入不同版本的、精确匹配内置原厂 SHA256 的 DTBO，当前镜像集缺失，且安装记录与旧 manifest 校验通过；可手动登记新的补丁版本，不能沿用旧端点或绕过校验。
同版本镜像损坏、PPS 状态、安装记录缺失或冲突、损坏的 manifest 均不开放此例外。补丁模式和全分区模式不会共用写入命令。

所有写入操作都要求 bootconfig/cmdline/bootctl 至少提供一个可信且不冲突的活动槽位来源；
只有 Android 属性而没有可信底层来源时，即使 SHA 能识别也不会选择写入目标。

切换只通过 WebUI 完成。模块内置清单中 19 个固件各自的原厂、33W、55W 完整镜像；
未知 DTBO SHA256 不允许使用内置全分区镜像。卸载模块时，如果当前活动分区
仍处于 33W/55W 配置，会按当前哈希识别出的固件版本恢复对应原厂镜像。

物理活动槽只用于定位当前要写入的 DTBO 分区，不参与镜像选择、固件版本判断或
哈希白名单匹配。实际目标镜像只由当前 DTBO 的完整 SHA256 决定，不假定物理
A/B 槽必然对应某个固件版本。因此，OTA 后 400 位于物理 B 槽时仍按 400
处理；301 位于物理 A 槽时仍按 301 处理；未知哈希仍会拒绝写入。
模块切换和卸载只操作当前活动分区，不会遍历或刷写另一槽。
如果底层槽位来源互相冲突，模块会因无法可靠定位当前分区而拒绝写入；该检查
只保护写入目标，不参与镜像选择。镜像选择始终只看当前 DTBO 的完整 SHA256。

WebUI 的“系统固件版本”直接读取 Android 系统属性，依次尝试
`ro.build.version.ota`、`ro.oplus.version.ota`、`ro.build.display.id` 和 incremental 属性。
“DTBO 匹配版本”仍由完整 DTBO SHA256 映射，仅用于兼容性与写入保护。

## 55W profile changes

相对已验证的 33W DTBO，55W 档仅修改 PPS/CP 相关电流与功率上限：

- CPA PPS power: 33 -> 55 W
- SC8517-backed `ufcs_virtual_cp` input max: 3000 -> 5000 mA
- PPS `curr_max_ma`: 3000 -> 5000 mA
- PPS `pps_strategy_normal_current`: 3000 -> 5000 mA
- 两套 PPS strategy 中原本的 3000 mA 最大档提升为 5000 mA
- `pps_ibat_over_third/oplus`: 4000 -> 7400 mA

保持不变：
- target_vbus = 11000 mV
- 高温降流 `pps_strategy_high_current`
- 低温/高温退出电流
- 满充电压、SOC、温度范围
- 所有低电流 taper 档
- 33W 和原厂 DTBO 镜像

## WebUI current direction

- 充电中：电池电流显示正值，例如 `2.80 A`
- 放电中：电池电流显示负值，例如 `-0.85 A`
- 功率计算始终使用电流绝对值

## Exact hashes

| 固件版本 | 配置 | DTBO SHA256 |
| --- | --- | --- |
| `PJX110_16.0.2.400` | 原厂 | `1e9b72599353e5d0009fcfe081185ebabd715a2e8ed1e2a8f0b695bc12c3cf17` |
| `PJX110_16.0.2.400` | 33W PPS | `6a51bf1c7aa527e11a1c92a975ccda634798ce7cc9a2cfbac3d960feb6b54471` |
| `PJX110_16.0.2.400` | 55W PPS | `0e09c040605aa44de44179969d57a4829180adeada10a65c45d844137ed29aaa` |
| `PJX110_16.0.1.301` | 原厂 | `4e6e85b2e4029a862e64bf7d5e74704a7563c980b696ee904cd72aaf59b4674e` |
| `PJX110_16.0.1.301` | 33W PPS | `053b3f3105cb30f9a2f09c3d8e510467561778ab847b1aae035c84c24ba9e8a2` |
| `PJX110_16.0.1.301` | 55W PPS | `8695bf93da80e1c4e7eb4734998cb3b6826cd8f9193f7cc749b14e09e291db97` |
| `PJX110_16.0.5.701` | 原厂 | `e8dd37efa99c0f59dc839e8b4582db9d619b6624e99bbdb0aee3e3f4c1336918` |
| `PJX110_16.0.5.701` | 33W PPS | `ee3ef9ca6edb70438a7fa77e1592501f99a170b0befcc3f383bac8d2b9161f5f` |
| `PJX110_16.0.5.701` | 55W PPS | `e0185cf9ae023d9dfbe685d1f859ed07c6948f7ac16bdeaf15a5e74f6d1bc949` |
| `PJX110_16.0.5.1001` | 原厂 | `ad6897d8a52cc8fdcb4423f1716c6c4506ee53338c218b2eaf2811162e7cb011` |
| `PJX110_16.0.5.1001` | 33W PPS | `abcf2d37de193e0146c401332537ce34bd8c1444a5f8a4ea8ff880c8177195cc` |
| `PJX110_16.0.5.1001` | 55W PPS | `817f4f34b2c320cbd9bd5833e3ba6393759c92627945fcc822aa3815e442c990` |

**Bootloader 必须保持真实解锁。** 动态生成镜像会保留对应原厂 VBMeta 并重写 AVB footer
定位信息；VBMeta 内的原厂 hash descriptor 不会伪造为新的签名，因此锁定状态下不能把
这些镜像当作可验证启动镜像使用。

## 兼容性说明

- 400 的 33W/55W PPS 已在 `PJX110_16.0.2.400` 实机测试通过。
- `PJX110_16.0.1.301`、`PJX110_16.0.5.701` 和 `PJX110_16.0.5.1001` 的 PPS 镜像均基于对应版本原厂 DTBO 重新合成，尚未实机验证。
- 其他固件版本不保证可以正常工作；需要自行重新校验 DTBO 哈希、分区布局和 PPS 参数。
- 在未完成校验前，不要尝试写入 33W / 55W DTBO。
- 55W 仍要求支持 5A PPS 的充电器与线材。
