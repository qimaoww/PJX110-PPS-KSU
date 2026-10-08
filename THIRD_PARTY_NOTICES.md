# Third-Party Notices

## LuckyTool charging-information reference

The read-only charging collector and UI conversion logic were independently
implemented with reference to LuckyTool by luckyzyx (GPL-3.0), commit
`2de5cf1f5bbbe07d8a072244bb14296486856c04`.
Reference: https://github.com/luckyzyx/LuckyTool

Relevant sources: `IChargerUtils.kt`, `StatusBarBatteryInfoNotify.kt`,
`BatteryControllerUtils.kt`, and `DevicesConfigUtils.kt`. This project does not
bundle LuckyTool or invoke its hooks/HAL transaction IDs. It reads known sysfs
nodes and keeps source-specific units and live PPS/UFCS state separate.

Units were cross-checked against OnePlusOSS
`android_kernel_modules_and_devicetree_oneplus_sm8650`, tree/commit
`38d50357db2728300a61b6f757f2d3a09651c155`, charger v2
`oplus_chg_gki.c` and `oplus_configfs.c`. These are references, not device-side
verification of every ColorOS version. No charging-policy or sysfs writes are
performed by the telemetry collector.

The bin/dtbo-profile-patcher executable includes code from the following projects.

## u-root and uio

BSD 3-Clause License

Copyright (c) 2012-2021, u-root Authors
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that:

1. Source redistributions retain the copyright notice, conditions, and disclaimer.
2. Binary redistributions reproduce the copyright notice, conditions, and disclaimer in documentation or other materials.
3. The copyright holder or contributor names may not endorse derived products without permission.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND. THE AUTHORS ARE NOT LIABLE FOR ANY CLAIM, DAMAGES, OR OTHER LIABILITY ARISING FROM USE OF THE SOFTWARE.

## lz4 for Go

Copyright (c) 2015, Pierre Curto
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the copyright notice, conditions, and disclaimer are retained. The name of xxHash and contributor names may not endorse derived products without permission.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND. THE AUTHORS ARE NOT LIABLE FOR ANY CLAIM, DAMAGES, OR OTHER LIABILITY ARISING FROM USE OF THE SOFTWARE.

## Go x/exp

Copyright 2009 The Go Authors.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the copyright notice, conditions, and disclaimer are retained. The name of Google LLC and contributor names may not endorse derived products without permission.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND. THE AUTHORS ARE NOT LIABLE FOR ANY CLAIM, DAMAGES, OR OTHER LIABILITY ARISING FROM USE OF THE SOFTWARE.
