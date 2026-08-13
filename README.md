# OnePlus Ace 3 Pro PPS Profiles — v1.0.2

> **兼容性声明：PPS 33W/55W 仅在 `PJX110_16.0.2.400` 固件上实机测试通过；当前同时识别 `PJX110_16.0.1.301` 的原厂 DTBO。其他固件版本不保证可用，必须先自行重新校验 DTBO 哈希与兼容性。**

本项目采用 [GNU General Public License v3.0](LICENSE) 开源。根据 GPL-3.0，修改或衍生版本在分发时也必须以 GPL-3.0（或兼容条款）提供对应源代码。

**Author:** qimaoaa  
**Target:** OnePlus Ace 3 Pro / PJX110 / corvette  
**PPS 已测试固件：** `PJX110_16.0.2.400`

**另支持识别的原厂固件：** `PJX110_16.0.1.301`

**重要：`.301` 的原厂哈希已加入识别；其 PPS 档位仍需自行实机验证。其他固件版本不保证可用。**

## WebUI profiles

- 原厂
- 33W PPS（11V / 3A，`.400` 已实机验证；`.301` 镜像已加入但需自行验证）
- 55W PPS（11V / 5A，`.400` 已实机验证；`.301` 镜像已加入但需自行验证）

切换只通过 WebUI 完成。模块内置 `.400` 和 `.301` 两个固件版本各自的原厂、
33W、55W 镜像；未知 DTBO SHA256 会拒绝写入。卸载模块时，如果当前活动分区
仍处于 33W/55W 配置，会按当前哈希识别出的固件版本恢复对应原厂镜像。

物理活动槽只用于定位当前要写入的 DTBO 分区，不参与镜像选择、固件版本判断或
哈希白名单匹配。实际目标镜像只由当前 DTBO 的完整 SHA256 决定，不假定物理
A/B 槽必然对应某个固件版本。因此，OTA 后 `.400` 位于物理 B 槽时仍按 `.400`
处理；`.301` 位于物理 A 槽时仍按 `.301` 处理；未知哈希仍会拒绝写入。
模块切换和卸载只操作当前活动分区，不会遍历或刷写另一槽。
如果底层槽位来源互相冲突，模块会因无法可靠定位当前分区而拒绝写入；该检查
只保护写入目标，不参与镜像选择。镜像选择始终只看当前 DTBO 的完整 SHA256。

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
| `PJX110_16.0.1.301` | 33W PPS | `f93f19a824aa5f77e70f7473269e05c5d90b1a4a3c4b8631d63aa173ee3a0d98` |
| `PJX110_16.0.1.301` | 55W PPS | `af711da52dd6e67087465f658113bec8388abf13dd2cd2cabbb666309fa3f660` |

**Bootloader 必须保持真实解锁。**

## 兼容性说明

- `.400` 的 33W/55W PPS 已在 `PJX110_16.0.2.400` 实机测试通过。
- `.301` 当前加入的是基于该版本原厂 DTBO 的镜像，PPS 档位仍需自行实机验证。
- 其他固件版本不保证可以正常工作；需要自行重新校验 DTBO 哈希、分区布局和 PPS 参数。
- 在未完成校验前，不要尝试写入 33W / 55W DTBO。
- 55W 仍要求支持 5A PPS 的充电器与线材。
