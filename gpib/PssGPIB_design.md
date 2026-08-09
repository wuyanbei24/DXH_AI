# PssGPIB 模块详细设计说明书

| 项目 | 内容 |
|---|---|
| 模块名 | `PssGPIB` |
| 功能 | GPIB（IEEE-488）Talker/Listener 控制器，APB 从接口 |
| 目标器件 | Xilinx FPGA（Vivado / XPM FIFO） |
| 文件清单 | `PssGPIB.v`、`GPIB_fifo_in.v`、`GPIB_fifo_out.v` |
| 版本 | v1.1（FIFO 改用 Xilinx XPM 异步 FIFO，修复 CDC） |
| 日期 | 2026-08-09 |

---

## 1. 功能概述

`PssGPIB` 实现 GPIB 总线上的 **听者（Listener）/ 讲者（Talker）** 功能，使 FPGA（M1 核心）通过 GPIB 电平转换芯片与上位机（Keysight / NI / 士德等控者）进行命令与数据交互。模块要点：

- 标准 GPIB **三线握手**（NRFD / NDAC / DAV）的受方（AH）与源方（SH）状态机；
- **听者 L / 讲者 T / 器件清除 DC** 状态机，配合身份切换；
- 通过两个 **Xilinx XPM 异步 FIFO** 隔离 `APB_PCLK` 与 `sys_clk` 两个时钟域，做收发数据缓冲；
- APB 寄存器接口，软件可配地址、使能、中断，可读状态与数据；
- 电平转换芯片方向控制（`te_a/te_b/sc/dc`）；
- 兼容 NI、Keysight、士德控者的 ATN 时序差异（实测）。

> **设计范围声明**：本 IP 为**最小化 Talker/Listener**，仅实现 MLA/MTA 寻址 + 数据三线握手。GPIB 命令集中的 `DCL/GET/GTL/SDC/TCT/LLO/SPE/SPD/并行查询/UNL/副地址` 等命令**不译码**（详见 §11）。

---

## 2. 总体架构

```
                         ┌─────────────────────────────── PssGPIB ───────────────────────────────┐
                         │                                                                         │
   APB 总线              │   APB 接口                  寄存器           状态机                     │
 ┌──────────┐            │  ┌─────────┐  GPIB_Data_M1_w ┌──────┐   ┌──────────────────────────┐  │
 │ APB_PCLK │───────────►│  │ APB 时序│────────────────►│ CTRL │   │ DC  L  T  AH  SH 译码 EOI │  │
 │ APB_PADDR│            │  └─────────┘                  └──────┘   └──────────────────────────┘  │
 │ APB_PWDATA│─┐         │      │  ▲ GPIB_Data_M1_r              │  ▲                             │
 │ ...       │ │         │      │  │                            │  │ GPIB_State / 地址 / 使能    │
 └──────────┘ │         │      ▼  │                            ▼  │                             │
             │         │  ┌───┴───┴───┐   APB_PCLK   ┌──────┐  │  │  sys_clk 域                 │
             └────────►│  │ GPIB_fifo_│──写入侧─────►│      │  │  │  ┌──────────────────────┐  │
               读使能   │  │  out (XPM)│              │ SH   │◄─┘  │  │ 受方/源方握手 + IO 驱动  │  │
               写数据   │  │ 异步 FIFO │──读取侧(sys)─►│ 状态 │     │  │ (NRFD/NDAC/DAV/EOI)    │  │
                       │  └───────────┘              └──────┘     │  └──────────────────────┘  │
                       │  ┌───────────┐   sys_clk    ┌──────┐     │                             │
                       │  │ GPIB_fifo_│──写入侧─────►│ AH   │     │  ┌──────────────────────┐  │
                       │  │  in  (XPM)│              │ 状态 │     │  │ data[7:0] eoi 方向控制 │  │
                       │  │ 异步 FIFO │──读取侧(APB)─►│      │     │  │ te_a te_b sc dc       │  │
                       │  └───────────┘              └──────┘     │  └──────────────────────┘  │
                       │                                                         │             │
                       └─────────────────────────────────────────────────────────┼─────────────┘
                                                                                  │
                                                          GPIB 总线 / 电平转换芯片 │
                                                  data ifc atn ren srq eoi nrfd ndac dav
```

**数据流**：
- 接收（GPIB→M1）：GPIB 数据 → `GPIB_Data_FPGA_r` → in FIFO（写侧 sys_clk）→ APB 读 `GPIB_Data_M1_r`。
- 发送（M1→GPIB）：APB 写 `GPIB_Data_M1_w` → out FIFO（写侧 APB_PCLK）→ SH 取数 `GPIB_Data_FPGA_w` → GPIB 总线。

---

## 3. 接口定义

### 3.1 系统接口
| 信号 | 方向 | 说明 |
|---|---|---|
| `sys_clk` | in | GPIB 逻辑主时钟（建议 40~200MHz，决定上电就绪等待实际时长） |
| `sys_rstn` | in | 系统异步复位（低有效） |

### 3.2 APB 从接口
| 信号 | 方向 | 说明 |
|---|---|---|
| `APB_PCLK` | in | APB 总线时钟 |
| `APB_PRESET` | in | APB 复位（低有效） |
| `APB_PADDR[31:0]` | in | 地址（仅用低 16 位） |
| `APB_PENABLE` | in | 使能 |
| `APB_PWRITE` | in | 1=写，0=读 |
| `APB_PSTRB[3:0]` | in | 字节选通（**未使用**） |
| `APB_PPROT[2:0]` | in | 保护（**未使用**） |
| `APB_PWDATA[31:0]` | in | 写数据 |
| `APB_PSEL` | in | 从机选择 |
| `APB_PRDATA[31:0]` | out | 读数据 |
| `APB_PREADY` | out | 就绪（零等待，访问周期拉高 1 拍） |
| `APB_PSLVERR` | out | 恒 0 |

### 3.3 GPIB 电平转换控制
| 信号 | 方向 | 说明 |
|---|---|---|
| `te_a`, `te_b` | out | 方向使能，= `GPIB_State`（1=讲者/输出，0=听者/输入） |
| `sc` | out | 恒 0（本设备不作为控者） |
| `dc` | out | 恒 1（本设备不能作为控者） |

### 3.4 GPIB 总线（与电平转换芯片相连）
| 信号 | 方向 | 说明 |
|---|---|---|
| `data[7:0]` | inout | 8 位数据/命令总线（输出时取反） |
| `ifc` | in | 接口清除（控者驱动，低有效） |
| `atn` | in | 注意（控者驱动，低有效） |
| `ren` | in | 远程使能（控者驱动，低有效） |
| `srq` | out | 服务请求，恒 1（本设备不主动请求） |
| `eoi` | inout | 结束识别（输出时取反） |
| `nrfd` | inout | 未准备好接收（输出时取反） |
| `ndac` | inout | 未接收完数据（输出时取反） |
| `dav` | inout | 数据有效（输出时取反） |

> **负逻辑约定**：GPIB 总线为低有效。模块在 IO 边界统一取反：`assign data = GPIB_State ? (~GPIB_Data_FPGA_w) : 8'bz;` 等。内部所有握手/数据信号均以正逻辑运算。

### 3.5 状态输出
| 信号 | 方向 | 说明 |
|---|---|---|
| `GPIB_infifo_empty` | out | 接收 FIFO 空（APB 域，供状态寄存器） |

---

## 4. 寄存器定义（APB，字节地址）

所有寄存器 32 位访问；地址低 16 位译码。

### 4.1 `0x0010` 数据寄存器
| 访问 | 位域 | 说明 |
|---|---|---|
| W | `[7:0]` | 待发送数据 → `GPIB_Data_M1_w`，并产生 out FIFO 写脉冲 |
| R | `[7:0]` | 接收数据 `GPIB_Data_M1_r`（读后弹出 in FIFO 头） |

- 写：APB 写 `0x0010` 的**下降沿**生成单拍 `GPIB_outfifo_w`。
- 读：APB 读 `0x0010` 的**下降沿**生成单拍 `GPIB_infifo_r`。

### 4.2 `0x0014` 控制寄存器
| 位 | 名称 | 复位值 | 说明 |
|---|---|---|---|
| `[0]` | `GPIB_Ctl_En` | 1 | GPIB 使能（总使能接收 FIFO 写等） |
| `[1]` | `GPIB_Ctl_IRQ_R_En` | 1 | 接收完成中断使能 |
| `[2]` | `GPIB_Ctl_IRQ_T_En` | 0 | 发送完成中断使能 |
| `[3]` | `GPIB_Ctl_IRQ_R_Clr` | 0 | 接收中断清除（写 1 后下个周期自动清 0） |
| `[4]` | `GPIB_Ctl_IRQ_T_Clr` | 0 | 发送中断清除（写 1 后下个周期自动清 0） |
| `[12:8]` | `GPIB_Addr` | 5'd1 | 本设备 GPIB 地址（0~31） |

> **注意**：当前版本**无中断输出端口**，IRQ 相关位为冗余字段；软件应**轮询** `0x0018`。

### 4.3 `0x0018` 状态寄存器（读）
| 位 | 名称 | 说明 |
|---|---|---|
| `[0]` | `GPIB_State` | 1=讲者，0=听者 |
| `[1]` | `~GPIB_outfifo_empty` | 发送 FIFO 非空 |
| `[2]` | `~GPIB_infifo_empty` | 接收 FIFO 非空 |

### 4.4 `0x001C` 标识寄存器（读）
固定值 `0x21101312`，供软件识别本 IP。

---

## 5. 时钟与复位

- 两个时钟域：**`sys_clk`**（GPIB 逻辑、握手、FIFO 读/写侧之一）与 **`APB_PCLK`**（寄存器、FIFO 另一侧）。二者**允许异步**；跨域数据统一经 XPM 异步 FIFO 隔离。
- 复位：
  - `DC`（器件清除）、`L`（听者）状态机复位于 `sys_rstn`；
  - `T / AH / SH / 指令译码 / EOI / error / FIFO` 复位于 `GPIB_dvire_rstn = sys_rstn && ~DCAS`；
  - `DCAS`（Device Clear 作用态）由 `IFC` 下降沿触发，对所有 GPIB 逻辑做“软复位”。
- FIFO 复位：`Reset = ~GPIB_dvire_rstn`（高有效）接入 `xpm_fifo_async.rst`。

---

## 6. 状态机详细设计

### 6.1 器件清除 DC（复位：`sys_rstn`）
| 现态 | 条件 | 次态 | 动作 |
|---|---|---|---|
| `DCIS`(0) | `(~ifc_dly) & ifc_dly_dly & (~DCAS)` | `DCAS`(1) | 进入器件清除作用态 |
| `DCAS`(1) | `ifc_dly & (~DCIS)` | `DCIS`(0) | 退出清除（IFC 释放） |

> DCAS 拉低 `GPIB_dvire_rstn`，从而复位 T/AH/SH 等。

### 6.2 听者 L（复位：`sys_rstn`）
| 现态 | 条件 | 次态 |
|---|---|---|
| `LIDS` | `(~ren_dly | ~atn_dly) & ~LADS` | `LADS` |
| `LADS` | `atn_dly & LAD & ~LACS` | `LACS` |
| `LACS` | `(~atn_dly) & ~LADS` | `LADS` |

### 6.3 讲者 T（复位：`GPIB_dvire_rstn`）
| 现态 | 条件 | 次态 |
|---|---|---|
| `TIDS` | `(~ren_dly) & ~TADS` | `TADS` |
| `TADS` | `atn_dly & TAD & ~TACS` | `TACS` |
| `TADS` | `ren_dly & ~TIDS` | `TIDS`（本地/复位） |
| `TACS` | `(~atn_dly) & ~TADS` | `TADS` |
| `TACS` | `ren_dly & ~TIDS` | `TIDS` |

### 6.4 受方握手 AH（复位：`GPIB_dvire_rstn`）
| 现态 | 条件 | 次态 |
|---|---|---|
| `AIDS` | `(LAD | ~atn_dly) & ~ANRS` | `ANRS` |
| `ANRS` | `(LAD | ~atn_dly) & ~ACRS` | `ACRS` |
| `ACRS` | `davIn & ~ACDS` | `ACDS` |
| `ACRS` | `(~LAD) & atn_dly & ~AIDS` | `AIDS`（未寻址命令阶段返回） |
| `ACDS` | `(GPIB_infifo_w | LADS) & ~AWNS` | `AWNS` |
| `AWNS` | `(~davIn) & ~ANRS` | `AIDS` |

**AH 状态对应的总线驱动**（监听角色 `GPIB_State==0`）：
| 状态 | `nrfdOut`→`nrfd` | `ndacOut`→`ndac` | 含义 |
|---|---|---|---|
| `AIDS` | 0→1 | 0→1 | 空闲，不参与 |
| `ANRS` | 0→1 | 1→0 | 受者未就绪 |
| `ACRS` | 0→1 | 1→0 | 受者就绪 |
| `ACDS` | 1→0 | 1→0 | 接收数据 |
| `AWNS` | 1→0 | 0→1 | 等待新循环 |

> 因取反约定，`nrfdOut/ndacOut=0` 对应总线 `NRFD/NDAC=1`（释放/就绪），`=1` 对应总线 `=0`（驱动/未就绪）。

### 6.5 源方握手 SH（复位：`GPIB_dvire_rstn`）
| 现态 | 条件 | 次态 |
|---|---|---|
| `SIDS` | `(~GPIB_outfifo_empty) & TACS & ~SGNS` | `SGNS` |
| `SGNS` | `GPIB_outfifo_r & ~SDYS` | `SDYS`（**读 1 字**） |
| `SDYS` | `(~nrfdIn) & ~STRS` | `STRS` |
| `STRS` | `(~ndacIn) & ~SWNS` | `SWNS` |
| `SWNS` | `(~SIWS)` | `SIDS` |
| `SIWS` | `(~SIDS)` | `SIDS`（保留，正常不进入） |

**SH 状态对应的 `davOut`→`dav` 驱动**：仅 `STRS` 状态 `davOut=1`（`DAV=0`，数据有效）；其余 `=0`（`DAV=1`，无效）。

### 6.6 身份切换
- `GPIB_State`：进入讲者 `TAD & atn_dly` → 1；`~atn_dly` → 0（听者）。
- 讲者时驱动 `data/eoi/dav`；听者时驱动 `nrfd/ndac`；方向同时送 `te_a/te_b`。

---

## 7. FIFO 设计（Xilinx XPM 异步 FIFO）

### 7.1 选型与参数
采用 `xpm_fifo_async`（FWFT 首字直通模式）：

| 参数 | in FIFO | out FIFO | 说明 |
|---|---|---|---|
| `FIFO_MEMORY_TYPE` | `"auto"` | `"auto"` | 工具自动选 BRAM/分布式 |
| `FIFO_WRITE_DEPTH` | 16 | 16 | 2 的幂，GPIB 速率下足够 |
| `WRITE/RD_DATA_WIDTH` | 8 | 8 | 字节流 |
| `READ_MODE` | `"fwft"` | `"fwft"` | 首字直通 |
| `FIFO_READ_LATENCY` | 0 | 0 | FWFT 必须为 0 |
| `CDC_SYNC_STAGES` | 2 | 2 | 跨域同步级数 |
| `RELATED_CLOCKS` | 0（异步） | 0（异步） | 若两时钟同源可设 1 |
| `WR/RD_DATA_COUNT_WIDTH` | 11 | 11 | 计数位宽 |
| `USE_ADV_FEATURES` | `"0707"` | `"0707"` | 使能 data count |

### 7.2 时钟域分配（关键）
| FIFO | 写侧时钟 | 读侧时钟 | 写数据/使能域 | 读数据域 |
|---|---|---|---|---|
| `GPIB_fifo_in` | `sys_clk` | `APB_PCLK` | sys_clk（AH 握手产生） | APB_PCLK |
| `GPIB_fifo_out` | `APB_PCLK` | `sys_clk` | APB_PCLK（软件写） | sys_clk（SH 取数） |

写侧所有控制/数据信号均属于写时钟域，读侧均属于读时钟域，**无任何跨域组合/寄存器直连**，从根本上消除原 P0 级 CDC 风险。

### 7.3 端口连接（见 `PssGPIB.v` 实例化）
```
GPIB_fifo_in  : .WrClk(sys_clk) .RdClk(APB_PCLK) .Data(GPIB_Data_FPGA_r)
                .WrEn(GPIB_infifo_w & 上升沿) .RdEn(GPIB_infifo_r)
                .Reset(~GPIB_dvire_rstn) .Q(GPIB_Data_M1_r)
                .Empty(GPIB_infifo_empty) .Full(GPIB_infifo_full)
GPIB_fifo_out : .WrClk(APB_PCLK) .RdClk(sys_clk) .Data(GPIB_Data_M1_w)
                .WrEn(GPIB_outfifo_w) .RdEn(GPIB_outfifo_r)
                .Reset(~GPIB_dvire_rstn) .Wnum(GPIB_outfifo_num)
                .Q(GPIB_Data_FPGA_w) .Empty(GPIB_outfifo_empty) .Full(GPIB_outfifo_full)
```

### 7.4 残留微小 CDC（建议后续优化）
`GPIB_outfifo_full`（写侧 APB 域）被 `GPIB_error` 错误 FSM（sys_clk 域）读取（`PssGPIB.v` 错误逻辑）。该标志仅用于置位粘滞错误位，影响极小；如需完全消除，可对 `GPIB_outfifo_full` 做 2FF 同步或改用读侧 `almost_full`。

---

## 8. 关键功能时序

### 8.1 ATN 去抖延时
`atn` 经 32 级移位寄存器 `atn_32_dly`，`atn_dly <= atn_32_dly[31]`，约 **32 个 sys_clk**（@40MHz≈800ns）。用于吸收 NI/Keysight 在 ATN 与 NRFD 之间的时序差（实测约 110ns）。如两控者差异更大可加大级数。

### 8.2 上电就绪门控
- 计数 `INFO_RDY_DLY_CNT = 40_000_000 × INFO_RDY_DLY`（默认 35），即约 **35 秒 @40MHz**。
- `M1_ready_information` 置位前，指令译码**不**把本设备设为 `LAD/TAD` → 控者扫描时本设备“不在线”。
- **硬编码 40MHz 假设**：若 `sys_clk` 频率变化，实际等待时长随之改变（建议后续参数化）。

### 8.3 EOI（结束识别）
- 发送字节为 `0x0A`（换行）且 `eoiOut_can_set` 时，`eoiOut=1`（消息结束）。
- `eoiOut_can_set`：进入讲者态清零（防复用上次 FIFO 残留结束符误触发 EOI），在 `SGNS` 起始置位。
- 接收侧 `eoiIn` 反映对端 EOI，可供软件判断消息结束。

### 8.4 接收三线握手（AH）典型时序
```
控者: ATN↓(命令) → 发 MLA(本地址) → ATN↑(数据) → DAV↓(数据有效)
本端: NRFD/NDAC 随 AH 状态机在 ACDS 接收，AWNS 等待 DAV↑，随后 NDAC↑ 确认
```

### 8.5 发送三线握手（SH）典型时序
```
本端: 进入 SGNS 读 1 字 → SDYS 等 NRFD↑(听者就绪) → STRS 拉 DAV↓(有效)
      → SWNS 等 NDAC↑(听者收完) → 下一字循环，直至 out FIFO 空回到 SIDS
```

---

## 9. 跨时钟域（CDC）处理总结

| 路径 | 旧实现 | 新实现（v1.1） |
|---|---|---|
| APB 写数据 → GPIB 发送 | 单时钟 FIFO 直连（有风险） | `GPIB_fifo_out` 异步 FIFO 隔离 |
| GPIB 接收 → APB 读数据 | 单时钟 FIFO 直连（有风险） | `GPIB_fifo_in` 异步 FIFO 隔离 |
| 控制寄存器 → GPIB 逻辑 | 同域假定（有风险） | 仍为寄存器跨域（**建议**：`GPIB_Ctl_En`/`GPIB_Addr` 等可在 sys_clk 域做 2FF 同步；若 APB_PCLK 与 sys_clk 同源同相可忽略） |
| 状态 → APB 读 | 组合跨域 | 经 FIFO `Empty`/计数（已隔离）；`GPIB_State` 建议在 APB 域 2FF 同步 |

> 若设计中 `APB_PCLK` 与 `sys_clk` 实际为**同源同相**（如同一 MMCM 输出），则控制/状态跨域风险很低，可仅保留 FIFO 异步隔离；否则建议对 bit 级控制信号补 2FF 同步器。

---

## 10. 实现与集成

### 10.1 文件清单
| 文件 | 说明 |
|---|---|
| `PssGPIB.v` | 顶层控制器（已更新 FIFO 实例化为双时钟接口） |
| `GPIB_fifo_in.v` | 接收 FIFO 包装（XPM 异步 FIFO） |
| `GPIB_fifo_out.v` | 发送 FIFO 包装（XPM 异步 FIFO） |

### 10.2 XPM 库
- `xpm_fifo_async` 来自 Vivado XPM 库；本工程已含 `xilinx2018.2_XPM_Lib/`，需在综合/仿真编译顺序中包含 XPM 源（`xpm_fifo` 相关 `.v` / `.vhd`）。
- 在 Vivado 中通常自动从安装库解析，无需手动加源；若独立仿真，请将 XPM 源加入编译列表。

### 10.3 综合/实现建议约束
- `te_a/te_b/sc/dc` 与 GPIB IO 按电平转换芯片要求做 IO 标准与时序约束（通常慢速，无需苛刻时序）。
- `ATN/NRFD/NDAC/DAV` 为异步握手信号，建议设为 `set_false_path` 或 `set_clock_groups`（与其余同步逻辑隔离），仅按 GPIB 时序规范（≤ IEEE-488 速率）做板级约束。
- FIFO 深度 16，资源占用极小。

---

## 11. 设计约束与未实现项

- **命令集**：仅实现 MLA(`LAD`)/MTA(`TAD`) 寻址与数据握手；`DCL/GET/GTL/SDC/TCT/LLO/SPE/SPD/并行查询/UNL/副地址` 信号已声明但**未译码**。器件清除仅由硬件 `IFC` 线触发。
- **中断**：控制寄存器含 IRQ 位但**无 IRQ 输出端口**，软件须轮询 `0x0018`。
- **错误可见性**：`GPIB_error` 内部粘滞，未通过 APB 暴露（建议后续增加可读错误寄存器）。
- **听者握手门控**：数据阶段 AH 状态机 `无条件`参与握手（未被 `LACS` 严格门控），共享总线多设备场景下可能“抢答”；点对点/独占控者无影响。
- **复位域**：Device Clear 不复位听者 L 状态机（保留寻址态，靠后续 ATN 自行退出）。

---

## 12. 修改记录

| 版本 | 日期 | 修改 |
|---|---|---|
| v1.0 | 2023-06 | 初始版本（FIFO 为外部占位，单时钟假设） |
| v1.1 | 2026-08-09 | FIFO 改用 Xilinx XPM 异步 FIFO（`GPIB_fifo_in/out.v`），实例化改为双时钟接口，消除跨时钟域 CDC 风险；补充本详细设计文档 |
