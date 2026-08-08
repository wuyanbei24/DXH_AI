# lvds_rx_lane_phy.v 详细设计报告

> **文档版本**: V1.0  
> **生成日期**: 2026-08-08  
> **对应源文件**: `LVDS3DLane/lvds_rx_lane_phy.v`  
> **设计基线**: Xilinx 7系列FPGA双向3路数据LVDS通信设计文档 V4.0  
> **V4修复覆盖**: LT-06, LT-08, LT-11

---

## 目录

1. [模块概述](#1-模块概述)
2. [端口定义](#2-端口定义)
3. [参数配置](#3-参数配置)
4. [内部架构](#4-内部架构)
5. [Xilinx原语例化](#5-xilinx原语例化)
6. [延迟校准状态机](#6-延迟校准状态机)
7. [字对齐状态机](#7-字对齐状态机)
8. [延迟窗口查找组合逻辑](#8-延迟窗口查找组合逻辑)
9. [lane_calib_err 集中管理](#9-lane_calib_err-集中管理)
10. [信号质量监测机制](#10-信号质量监测机制)
11. [V4修复详情](#11-v4修复详情)
12. [时序分析](#12-时序分析)
13. [设计约束与注意事项](#13-设计约束与注意事项)
14. [信号清单速查表](#14-信号清单速查表)

---

## 1. 模块概述

### 1.1 功能定位

`lvds_rx_lane_phy` 是 LVDS 接收链路的**单通道物理层子模块**，负责一条 LVDS 差分数据线的完整接收端校准与数据恢复。在 3 通道系统中，上层模块 `lvds_rx_phy` 会例化 3 个本模块实例，各通道独立完成校准。

### 1.2 核心职责

| 职责 | 描述 |
|------|------|
| **差分接收** | 通过 IBUFDS 将 LVDS 差分信号转为单端 |
| **延迟校准** | 通过 IDELAYE2 扫描 32 级抽头延迟，找到最佳采样窗口 |
| **数据解串** | 通过 ISERDESE2 将串行数据（800Mbps）解串为 8 位并行数据（100MHz） |
| **字对齐** | 通过 BITSLIP 机制调整解串输出边界，使输出对齐到已知训练码型 |
| **信号质量监测** | 对齐成功后持续监测信号质量，恶化时自动触发重新对齐 |

### 1.3 数据流

```
lvds_data_p/n ──► IBUFDS ──► IDELAYE2 ──► ISERDESE2 ──► rx_data[7:0]
                   (差分转      (延迟       (DDR 8:1       (并行输出)
                    单端)       校准)       解串)
                                  │              │
                                  │              ▼
                                  │        BITSLIP控制
                                  │        (字对齐FSM)
                                  ▼
                            延迟校准FSM
                            (扫描32级延迟)
```

### 1.4 时钟域

| 时钟 | 频率 | 用途 |
|------|------|------|
| `clk_bufio` | 400 MHz | ISERDESE2 串行时钟（DDR，等效 800Mbps） |
| `clk_div` | 100 MHz | ISERDESE2 并行时钟，所有 FSM 与控制逻辑运行于此域 |
| `ref_clk_200m` | 200 MHz | IDELAYCTRL 参考时钟（本模块仅预留，IDELAYCTRL 在上层例化） |

> **注意**: `clk_bufio` 与 `clk_div` 由同一 MMCM/PLL 生成，保持 4:1 精确比值，无需跨时钟域同步。

---

## 2. 端口定义

### 2.1 端口列表

| 端口名 | 方向 | 位宽 | 时钟域 | 描述 |
|--------|------|------|--------|------|
| `rst_n` | input | 1 | — | 异步低有效复位 |
| `lvds_data_p` | input | 1 | — | LVDS 差分正端 |
| `lvds_data_n` | input | 1 | — | LVDS 差分负端 |
| `clk_bufio` | input | 1 | 400MHz | ISERDESE2 串行时钟 |
| `clk_div` | input | 1 | 100MHz | 并行时钟，FSM 主时钟 |
| `ref_clk_200m` | input | 1 | 200MHz | IDELAYCTRL 参考时钟 |
| `retrain_req` | input | 1 | clk_div | 重新训练请求，高有效 |
| `rx_data` | output | 8 | clk_div | 解串后的并行数据 |
| `lane_align_done` | output reg | 1 | clk_div | 通道字对齐完成标志 |
| `lane_calib_err` | output reg | 1 | clk_div | 通道校准错误标志 |
| `best_delay_val` | output reg | 5 | clk_div | 最佳延迟值（0~31） |

### 2.2 接口分组示意

```
                    ┌─────────────────────────────────┐
  lvds_data_p ────► │                                 │
  lvds_data_n ────► │      lvds_rx_lane_phy           │ ────► rx_data[7:0]
                    │                                 │
  clk_bufio ──────► │                                 │ ────► lane_align_done
  clk_div ────────► │                                 │ ────► lane_calib_err
  ref_clk_200m ───► │                                 │ ────► best_delay_val[4:0]
  rst_n ──────────► │                                 │
  retrain_req ────► │                                 │
                    └─────────────────────────────────┘
```

---

## 3. 参数配置

### 3.1 参数列表

| 参数名 | 默认值 | 描述 |
|--------|--------|------|
| `DATA_WIDTH` | 8 | 解串数据宽度（DDR 模式下支持 4/6/8/10） |
| `DELAY_STEPS` | 32 | IDELAYE2 扫描总步数（7系列固定 32 级抽头） |
| `SAMPLE_CNT` | 16 | 每个延迟抽头的采样次数 |
| `MIN_WIN_SIZE` | 4 | 有效窗口最小宽度（低于此值判定校准失败） |

### 3.2 内部 localparam

| localparam | 值 | 描述 |
|------------|-----|------|
| `SAMPLE_ERR_TOLERANCE` | 2 | 每个抽头采样允许的最大错误数 |
| `SETTLE_CYCLES` | 3 | IDELAY 设置后等待稳定的时钟周期数 |
| `MAX_BITSLIP` | 8 | BITSLIP 最大尝试次数（8 位数据最多 8 次滑动） |
| `BITSLIP_WAIT_CYCLES` | 5 | BITSLIP 脉冲后等待 ISERDESE2 稳定的周期数 |
| `BAD_WORD_THRESHOLD` | 32 | 连续非 0xB5 的阈值，超过则判定信号恶化 |

### 3.3 延迟校准 FSM 状态编码

| 状态名 | 编码 | 描述 |
|--------|------|------|
| `D_IDLE` | 3'd0 | 空闲，等待启动条件 |
| `D_SET_DELAY` | 3'd1 | 加载延迟值到 IDELAYE2 |
| `D_SETTLE` | 3'd2 | **[V4]** 等待 IDELAY 输出稳定 |
| `D_WAIT` | 3'd3 | 采样窗口，统计错误数 |
| `D_SAMPLE` | 3'd4 | 记录当前抽头有效性，步进到下一抽头 |
| `D_CALC_WIN` | 3'd5 | 计算最佳延迟窗口 |
| `D_DONE` | 3'd6 | 输出 scan_done 脉冲，加载最佳延迟 |

### 3.4 字对齐 FSM 状态编码

| 状态名 | 编码 | 描述 |
|--------|------|------|
| `W_IDLE` | 3'd0 | 空闲，等待延迟校准完成 |
| `W_BITSLIP` | 3'd1 | 发送 BITSLIP 脉冲 |
| `W_WAIT` | 3'd2 | 等待 ISERDESE2 输出稳定 |
| `W_CHECK` | 3'd3 | 检查输出是否匹配训练码型 |
| `W_DONE` | 3'd4 | **[V4]** 对齐成功保持状态，持续监测信号质量 |

---

## 4. 内部架构

### 4.1 内部信号总览

```
┌──────────────────────────────────────────────────────────────────┐
│                    lvds_rx_lane_phy 内部架构                      │
│                                                                  │
│  ┌─────────┐    ┌──────────┐    ┌───────────┐                   │
│  │ IBUFDS  │───►│ IDELAYE2 │───►│ ISERDESE2 │──► rx_data[7:0]   │
│  └─────────┘    └────┬─────┘    └─────┬─────┘                   │
│                      │                │                          │
│                      │   ┌────────────┘                          │
│                      ▼   ▼                                       │
│              ┌───────────────┐    ┌──────────────────┐          │
│              │ 延迟校准FSM    │    │ 字对齐FSM         │          │
│              │ (D_IDLE→...   │    │ (W_IDLE→...      │          │
│              │  →D_DONE)     │    │  →W_DONE)        │          │
│              └───────┬───────┘    └────────┬─────────┘          │
│                      │ scan_done           │ bitslip_req         │
│                      ▼                     ▼                     │
│              ┌───────────────┐    ┌──────────────────┐          │
│              │ 延迟窗口查找   │    │ 信号质量监测      │          │
│              │ (组合逻辑)     │    │ (bad_word_cnt)   │          │
│              └───────────────┘    └──────────────────┘          │
│                                                                  │
│              ┌───────────────────────────────┐                  │
│              │ lane_calib_err 集中管理        │                  │
│              └───────────────────────────────┘                  │
└──────────────────────────────────────────────────────────────────┘
```

### 4.2 关键内部信号

| 信号名 | 位宽 | 类型 | 描述 |
|--------|------|------|------|
| `data_ibuf` | 1 | wire | IBUFDS 单端输出 |
| `data_delay` | 1 | wire | IDELAYE2 延迟后输出 |
| `iserdes_q` | 8 | wire | ISERDESE2 并行输出 |
| `delay_ce` | 1 | reg | IDELAYE2 CE 使能 |
| `delay_inc` | 1 | reg | IDELAYE2 INC 递增/递减 |
| `delay_ld` | 1 | reg | IDELAYE2 LD 加载 |
| `delay_cnt_val` | 5 | reg | IDELAYE2 CNTVALUEIN |
| `delay_cur_val` | 5 | wire | IDELAYE2 CNTVALUEOUT |
| `scan_step` | 5 | reg | 当前延迟扫描步（0~31） |
| `sample_cnt` | 5 | reg | 当前抽头已采样次数 |
| `sample_valid` | 1 | reg | 采样有效标志 |
| `sample_err_cnt` | 4 | reg | 当前抽头采样错误计数 |
| `valid_window` | 32 | reg | 有效窗口位图（bit i = 抽头 i 有效） |
| `scan_done` | 1 | reg | 延迟扫描完成脉冲 |
| `delay_win_valid` | 1 | reg | 窗口查找组合结果：窗口足够大 |
| `best_delay_comb` | 5 | reg | 窗口查找组合结果：最佳延迟值 |
| `settle_cnt` | 3 | reg | IDELAY 稳定等待计数器 |
| `bitslip_req` | 1 | reg | ISERDESE2 BITSLIP 脉冲 |
| `bitslip_wait` | 4 | reg | BITSLIP 后等待计数器 |
| `align_check_cnt` | 8 | reg | 连续匹配训练码型计数 |
| `bitslip_cnt` | 4 | reg | BITSLIP 尝试次数 |
| `bad_word_cnt` | 8 | reg | 连续非 0xB5 计数（信号质量监测） |
| `scan_done_prev` | 1 | reg | scan_done 上升沿检测寄存器 |

---

## 5. Xilinx原语例化

### 5.1 IBUFDS — 差分输入缓冲

```verilog
IBUFDS #(
    .DIFF_TERM("FALSE"),       // 差分终端（由外部约束指定）
    .IBUF_LOW_PWR("FALSE"),   // 高性能模式
    .IOSTANDARD("DEFAULT")     // I/O 标准（由 XDC 约束覆盖）
) u_ibufds_data (
    .I  (lvds_data_p),
    .IB (lvds_data_n),
    .O  (data_ibuf)
);
```

**设计说明**:
- `DIFF_TERM("FALSE")`: 差分终端通过 XDC 约束 `DIFF_TERM` 指定，不在 RTL 中硬编码。
- `IBUF_LOW_PWR("FALSE")`: 选择高性能模式以降低抖动。
- `IOSTANDARD("DEFAULT")`: 实际 I/O 标准由 XDC 约束文件指定（如 `LVDS_25`）。

### 5.2 IDELAYE2 — 输入延迟单元

```verilog
IDELAYE2 #(
    .DELAY_SRC("IDATAIN"),         // 延迟源：IBUFDS 输出
    .IDELAY_TYPE("VAR_LOAD"),      // 可变加载模式
    .IDELAY_VALUE(0),              // 初始延迟值
    .HIGH_PERFORMANCE_MODE("FALSE"), // 低功耗模式
    .REFCLK_FREQUENCY(200.0),      // 200MHz 参考时钟
    .SIGNAL_PATTERN("DATA")        // 数据信号模式
) u_idelay_data (
    .IDATAIN    (data_ibuf),       // 来自 IBUFDS
    .DATAOUT    (data_delay),      // 延迟后输出 → ISERDESE2 DDLY
    .C          (clk_div),         // 控制时钟
    .CE         (delay_ce),        // 使能
    .INC        (delay_inc),       // 递增/递减
    .LD         (delay_ld),        // 加载 CNTVALUEIN
    .CNTVALUEIN (delay_cnt_val),   // 加载值
    .CNTVALUEOUT(delay_cur_val),   // 当前值回读
    .REGRST     (~rst_n)           // 寄存器复位
);
```

**设计说明**:
- **VAR_LOAD 模式**: 允许通过 `LD` + `CNTVALUEIN` 直接加载任意延迟值（0~31），适合扫描式校准。
- 每级抽头延迟约 78ps（200MHz 参考时钟下，31 级覆盖约 2.4ns）。
- `HIGH_PERFORMANCE_MODE("FALSE")`: 选择低功耗模式；如需进一步降低抖动可改为 `"TRUE"`。
- IDELAYCTRL 在上层模块例化（每个 I/O Bank 一个），本模块仅预留 `ref_clk_200m` 端口。

### 5.3 ISERDESE2 — 解串器

```verilog
ISERDESE2 #(
    .DATA_RATE      ("DDR"),         // 双数据率
    .DATA_WIDTH     (DATA_WIDTH),    // 8 位解串
    .INTERFACE_TYPE ("NETWORKING"),  // 网络接口模式
    .IOBDELAY       ("IFD"),         // 使用 IDELAY 路径
    .SERDES_MODE    ("MASTER"),      // 主模式（单级即可满足 8:1）
    .NUM_CE         (2)
) u_iserdes_data (
    .CLK      (clk_bufio),           // 400MHz 串行时钟
    .CLKB     (~clk_bufio),          // 反相串行时钟
    .CLKDIV   (clk_div),             // 100MHz 并行时钟
    .DDLY     (data_delay),          // 来自 IDELAYE2
    .D        (data_ibuf),           // 直通路径（未使用，IOBDELAY=IFD）
    .BITSLIP  (bitslip_req),         // 字对齐控制
    .Q1-Q8    (iserdes_q[0:7]),      // 并行输出
    .RST      (~rst_n)
);
```

**设计说明**:
- **DDR 8:1 模式**: 400MHz × 2(DDR) = 800Mbps 串行速率，100MHz 并行时钟输出 8 位数据。
- **IOBDELAY("IFD")**: 选择 IDELAY 路径（`DDLY` 输入），而非直通 `D` 输入。
- **BITSLIP**: 每次 `bitslip_req` 拉高一个 `clk_div` 周期，ISERDESE2 输出滑动 1 bit。
- **MASTER 模式**: 8:1 解串在单级 ISERDESE2 即可完成，无需级联 SLAVE。

---

## 6. 延迟校准状态机

### 6.1 状态转移图

```
                    ┌──────────────────────────────────────────────┐
                    │                                              │
                    ▼                                              │
              ┌──────────┐    ~lane_align_done    ┌──────────────┐ │
              │ D_IDLE   │────& ~retrain_req─────►│ D_SET_DELAY  │ │
              │          │                        │              │ │
              └────┬─────┘                        └──────┬───────┘ │
                   │                                     │         │
                   │ retrain_req                         │         │
                   │ (从任意状态回到D_IDLE)               │         │
                   │                                     ▼         │
                   │                              ┌────────────┐   │
                   │                              │ D_SETTLE   │   │
                   │                              │ (V4新增)   │   │
                   │                              │ settle_cnt │   │
                   │                              │ >= 3       │   │
                   │                              └─────┬──────┘   │
                   │                                    │          │
                   │                                    ▼          │
                   │                              ┌────────────┐   │
                   │                              │ D_WAIT     │   │
                   │                              │ sample_cnt │   │
                   │                              │ >= 16      │   │
                   │                              └─────┬──────┘   │
                   │                                    │          │
                   │                                    ▼          │
                   │                              ┌────────────┐   │
                   │              scan_step < 31  │ D_SAMPLE   │   │
                   │            ┌─────────────────│            │   │
                   │            │                 └─────┬──────┘   │
                   │            │                       │          │
                   │            │          scan_step=31 │          │
                   │            └───────────────────────┘          │
                   │                                    │          │
                   │                                    ▼          │
                   │                              ┌────────────┐   │
                   │                              │ D_CALC_WIN │   │
                   │                              │ 计算最佳   │   │
                   │                              │ 延迟窗口   │   │
                   │                              └─────┬──────┘   │
                   │                                    │          │
                   │                                    ▼          │
                   │                              ┌────────────┐   │
                   │                              │ D_DONE     │   │
                   │                              │ scan_done=1│   │
                   │                              │ 加载最佳值 │   │
                   │                              └─────┬──────┘   │
                   └────────────────────────────────────┘          │
                                                                    │
                              retrain_req ──────────────────────────┘
                              (任意状态→D_IDLE)
```

### 6.2 各状态行为详解

#### D_IDLE — 空闲等待

- **进入条件**: 复位 / retrain_req / D_DONE 完成后
- **行为**: 清零 `scan_step`、`sample_cnt`、`valid_window`、`settle_cnt`
- **退出条件**: `~lane_align_done & ~retrain_req` → 进入 D_SET_DELAY

#### D_SET_DELAY — 加载延迟值

- **行为**:
  - `delay_cnt_val <= scan_step` — 将当前扫描步作为延迟值
  - `delay_ld <= 1'b1` — 触发 IDELAYE2 加载
  - 清零 `sample_cnt`、`sample_err_cnt`
- **下一状态**: 无条件进入 D_SETTLE

#### D_SETTLE — 等待 IDELAY 稳定 **[V4 LT-11 新增]**

- **行为**: `settle_cnt` 递增
- **退出条件**: `settle_cnt >= SETTLE_CYCLES (3)` → 进入 D_WAIT
- **设计目的**: IDELAYE2 在 `LD` 脉冲后需要若干周期输出才稳定，直接采样会导致误判

#### D_WAIT — 采样窗口

- **行为**:
  - `sample_cnt` 递增
  - 每个周期检查 `iserdes_q != 8'h55`，若不匹配则 `sample_err_cnt` 递增
- **退出条件**: `sample_cnt >= SAMPLE_CNT (16)` → 进入 D_SAMPLE
- **训练码型**: `0x55`（01010101），Phase 0 阶段发送

#### D_SAMPLE — 记录抽头有效性

- **行为**:
  - `valid_window[scan_step] <= (sample_err_cnt <= SAMPLE_ERR_TOLERANCE)` — 错误数 ≤ 2 则标记有效
  - `scan_step` 递增
- **退出条件**:
  - `scan_step < 31` → 回到 D_SET_DELAY（扫描下一抽头）
  - `scan_step == 31` → 进入 D_CALC_WIN

#### D_CALC_WIN — 计算最佳延迟

- **行为**: `best_delay_val <= delay_win_valid ? best_delay_comb : 5'd0`
- **组合逻辑**: 由 `calc_delay_window` 块计算最大连续有效窗口
- **下一状态**: 无条件进入 D_DONE

#### D_DONE — 扫描完成

- **行为**:
  - `scan_done <= 1'b1` — 产生单周期脉冲通知字对齐 FSM
  - `delay_cnt_val <= best_delay_val` — 准备加载最佳延迟
  - `delay_ld <= 1'b1` — 将最佳延迟写入 IDELAYE2
- **下一状态**: 回到 D_IDLE

### 6.3 延迟校准时序示例

以 `scan_step=0` 为例，单个抽头的校准时序：

```
clk_div    __|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾
状态        IDLE  SET_D  SETTLE  SETTLE  SETTLE   WAIT    WAIT  ...  WAIT(16) SAMPLE  SET_D(next)
scan_step   0      0       0       0       0       0       0          0        0        1
delay_ld    0      1       0       0       0       0       0          0        0        1
settle_cnt  0      0       1       2       3       -       -          -        -        0
sample_cnt  0      0       0       0       0       1       2         16        -        0
sample_err  0      0       0       0       0       ?       ?          ?        -        0
valid_win   0      0       0       0       0       0       0          0     [bit0=?]    0
```

单个抽头耗时: 1(SET_DELAY) + 3(SETTLE) + 16(WAIT) + 1(SAMPLE) = **21 个 clk_div 周期**  
32 个抽头总耗时: 21 × 32 + 1(CALC_WIN) + 1(DONE) = **674 个 clk_div 周期** ≈ 6.74μs @100MHz

---

## 7. 字对齐状态机

### 7.1 状态转移图

```
              ┌──────────┐   scan_done &     ┌────────────┐
              │ W_IDLE   │──~lane_calib_err─►│ W_BITSLIP  │
              │          │                    │            │
              └────┬─────┘                    └─────┬──────┘
                   │                                │
                   │ retrain_req /                  │
                   │ lane_calib_err /               ▼
                   │ bad_word_cnt>=32         ┌────────────┐
                   │ (从W_DONE返回)           │ W_WAIT     │
                   │                          │ bitslip_   │
                   │                          │ wait >= 5  │
                   │                          └─────┬──────┘
                   │                                │
                   │                                ▼
                   │                          ┌────────────┐
                   │           ┌──────────────│ W_CHECK    │
                   │           │              │            │
                   │           │              └─────┬──────┘
                   │           │                    │
                   │     iserdes_q != 0xB5    align_check_cnt
                   │     & bitslip_cnt < 8    >= 16
                   │           │                    │
                   │           │                    ▼
                   │           │              ┌────────────┐
                   │           │              │ W_DONE     │
                   │           │              │ (V4新增)   │
                   │           │              │ 持续监测   │
                   │           │              │ 信号质量   │
                   │           │              └─────┬──────┘
                   │           │                    │
                   │           │          bad_word_cnt >= 32
                   │           │                    │
                   │     iserdes_q != 0xB5          │
                   │     & bitslip_cnt >= 8         │
                   │           │                    │
                   │           ▼                    │
                   │     ┌────────────┐             │
                   └────►│ (回到W_IDLE)│◄────────────┘
                         └────────────┘
```

### 7.2 各状态行为详解

#### W_IDLE — 空闲等待

- **行为**:
  - 清零 `align_check_cnt`、`bitslip_wait`、`bad_word_cnt`
  - **[V4 LT-06]** 在 `scan_done` 上升沿清零 `bitslip_cnt`（确保每次新扫描从 0 开始计数）
- **退出条件**: `scan_done & ~lane_calib_err` → 进入 W_BITSLIP

#### W_BITSLIP — 发送 BITSLIP 脉冲

- **行为**:
  - `bitslip_req <= 1'b1` — 产生 BITSLIP 脉冲
  - `bitslip_cnt` 递增
  - `lane_align_done <= 1'b0` — 清除已对齐标志
  - 清零 `bad_word_cnt`
- **下一状态**: 无条件进入 W_WAIT

#### W_WAIT — 等待 ISERDESE2 稳定

- **行为**: `bitslip_wait` 递增
- **退出条件**: `bitslip_wait >= BITSLIP_WAIT_CYCLES (5)` → 进入 W_CHECK
- **设计目的**: BITSLIP 后 ISERDESE2 输出需要若干周期才稳定

#### W_CHECK — 检查对齐结果

- **行为**:
  - `iserdes_q == 8'hB5` → `align_check_cnt` 递增
  - `iserdes_q != 8'hB5` → `align_check_cnt` 清零
- **退出条件**:
  - `align_check_cnt >= 16` → 进入 W_DONE（连续 16 拍匹配，对齐成功）
  - `iserdes_q != 0xB5` 且 `bitslip_cnt < 8` → 回到 W_BITSLIP（再滑一位）
  - `iserdes_q != 0xB5` 且 `bitslip_cnt >= 8` → 回到 W_IDLE（放弃，触发错误）
- **训练码型**: `0xB5`（10110101），Phase 1 阶段发送

#### W_DONE — 对齐成功保持 **[V4 LT-08 新增]**

- **行为**:
  - `iserdes_q == 0xB5` → `bad_word_cnt` 清零
  - `iserdes_q != 0xB5` → `bad_word_cnt` 递增
  - `bad_word_cnt >= BAD_WORD_THRESHOLD (32)` → `lane_align_done <= 1'b0`（通知上游信号恶化）
- **退出条件**:
  - `bad_word_cnt >= 32` → 回到 W_IDLE（重新对齐）
  - `retrain_req | lane_calib_err` → 回到 W_IDLE

### 7.3 字对齐时序示例

假设第 3 次 BITSLIP 后对齐成功：

```
clk_div     __|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾
状态         IDLE  BSLIP  WAIT   WAIT   WAIT   WAIT   WAIT  CHECK  CHECK  ...  CHECK(16) DONE   DONE   DONE
bitslip_cnt  0      1      1      1      1      1      1      1      1          1        1      1      1
bitslip_req  0      1      0      0      0      0      0      0      0          0        0      0      0
bitslip_wait 0      0      1      2      3      4      5      0      0          0        0      0      0
align_check  0      0      0      0      0      0      0      1      2         16        -      -      -
align_done   0      0      0      0      0      0      0      0      0          1        1      1      1
iserdes_q    --     --     --     --     --     --     --    B5     B5         B5       B5     B5     B5
```

单次 BITSLIP 尝试耗时: 1(BITSLIP) + 5(WAIT) + 1~16(CHECK) = **7~22 个 clk_div 周期**  
最坏情况（8 次 BITSLIP 全失败）: 8 × (1+5) + 16 = **64 个 clk_div 周期** ≈ 0.64μs @100MHz

---

## 8. 延迟窗口查找组合逻辑

### 8.1 实现方式

```verilog
always @(*) begin : calc_delay_window
    reg [4:0] curr_start, curr_len, max_start, max_len;
    integer i;
    // 遍历 32 位 valid_window，查找最长连续 1 序列
    for(i = 0; i < 32; i = i + 1) begin
        if(valid_window[i]) begin
            if(curr_len == 0) curr_start = i[4:0];
            curr_len = curr_len + 1'b1;
            if(curr_len > max_len) begin
                max_len = curr_len;
                max_start = curr_start;
            end
        end else begin
            curr_len = 5'd0;
        end
    end
    delay_win_valid = (max_len >= MIN_WIN_SIZE);        // 窗口 >= 4
    best_delay_comb = max_start + (max_len >> 1);       // 窗口中心
end
```

### 8.2 算法说明

1. **输入**: 32 位 `valid_window`，每位对应一个延迟抽头的采样结果
2. **遍历**: 从 bit 0 到 bit 31，查找最长的连续 `1` 序列
3. **输出**:
   - `delay_win_valid`: 最长窗口 ≥ `MIN_WIN_SIZE (4)` 时为 1
   - `best_delay_comb`: 最长窗口的中心位置 = `max_start + max_len / 2`

### 8.3 示例

```
valid_window = 32'b0000_0011_1111_0000_0000_0000_0000_0000
                          ↑ max_start=5, max_len=6

best_delay_comb = 5 + (6 >> 1) = 5 + 3 = 8
delay_win_valid = (6 >= 4) = 1
```

选择窗口中心作为最佳延迟值，确保最大裕量。

---

## 9. lane_calib_err 集中管理

### 9.1 设计原则

`lane_calib_err` 由独立的 always 块集中管理，避免多驱动冲突。清零和置位条件明确分离。

### 9.2 清零条件

| 条件 | 描述 |
|------|------|
| `!rst_n` | 复位 |
| `retrain_req` | 重新训练请求 |
| `d_curr_state == D_IDLE` | 新一轮扫描开始 |

### 9.3 置位条件

| 条件 | 描述 |
|------|------|
| `d_curr_state == D_CALC_WIN` 且 `~delay_win_valid` | 延迟窗口不足，校准失败 |
| `w_curr_state == W_CHECK` 且 `iserdes_q != 0xB5` 且 `bitslip_cnt >= MAX_BITSLIP` | BITSLIP 溢出，字对齐失败 |

### 9.4 完整代码

```verilog
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n)
        lane_calib_err <= 1'b0;
    else if(retrain_req)
        lane_calib_err <= 1'b0;
    else if(d_curr_state == D_IDLE)
        lane_calib_err <= 1'b0;
    else if(d_curr_state == D_CALC_WIN)
        lane_calib_err <= ~delay_win_valid;
    else if(w_curr_state == W_CHECK && iserdes_q != 8'hB5 && bitslip_cnt >= MAX_BITSLIP)
        lane_calib_err <= 1'b1;
end
```

---

## 10. 信号质量监测机制

### 10.1 设计目的 **[V4 LT-08]**

在字对齐成功（进入 W_DONE 状态）后，持续监测接收数据质量。如果信号持续恶化（连续 32 拍非训练码型），自动清除 `lane_align_done` 并回到 W_IDLE 重新对齐，避免在错误状态下持续输出脏数据。

### 10.2 工作流程

```
对齐成功 (W_DONE)
    │
    ├── iserdes_q == 0xB5 → bad_word_cnt = 0 (信号正常)
    │
    └── iserdes_q != 0xB5 → bad_word_cnt++ (信号异常)
            │
            ├── bad_word_cnt < 32 → 继续监测
            │
            └── bad_word_cnt >= 32 → lane_align_done = 0
                                      → 回到 W_IDLE 重新对齐
```

### 10.3 阈值选择

`BAD_WORD_THRESHOLD = 32`:
- @100MHz 并行时钟，32 拍 = 320ns
- 足够短以快速响应信号恶化
- 足够长以避免偶发单 bit 错误误触发重训练

---

## 11. V4修复详情

### 11.1 LT-06: BITSLIP 计数器清零时机

**问题**: `bitslip_cnt` 在延迟校准完成后未正确清零，导致新一轮字对齐时 BITSLIP 尝试次数被错误累加，可能过早判定对齐失败。

**修复方案**:
1. 新增 `scan_done_prev` 寄存器，检测 `scan_done` 上升沿
2. 在 W_IDLE 状态中，当检测到 `scan_done` 上升沿时清零 `bitslip_cnt`

```verilog
// scan_done 上升沿检测
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) scan_done_prev <= 1'b0;
    else       scan_done_prev <= scan_done;
end

// W_IDLE 中清零
W_IDLE: begin
    if(scan_done & ~scan_done_prev)
        bitslip_cnt <= 4'd0;
end
```

### 11.2 LT-08: 对齐成功后状态保持与信号质量监测

**问题**: 原设计中字对齐成功后直接回到 W_IDLE，`lane_align_done` 仅在 `align_check_cnt >= 16` 时拉高但无持续监测，信号恶化后无法自动恢复。

**修复方案**:
1. 新增 W_DONE 状态，对齐成功后保持
2. 在 W_DONE 中持续监测 `bad_word_cnt`
3. `bad_word_cnt >= 32` 时清除 `lane_align_done` 并回到 W_IDLE

```verilog
W_DONE: begin
    if(iserdes_q == 8'hB5)
        bad_word_cnt <= 8'd0;
    else
        bad_word_cnt <= bad_word_cnt + 1'b1;
    if(bad_word_cnt >= BAD_WORD_THRESHOLD)
        lane_align_done <= 1'b0;
end
```

### 11.3 LT-11: IDELAY 稳定等待与采样容错

**问题**: 
1. IDELAYE2 加载新延迟值后输出需要稳定时间，原设计直接采样导致窗口边缘误判
2. 采样容错采用"先错即弃"策略，单次噪声即判定抽头无效，过于严格
3. 采样次数判断条件为 `==` 而非 `>=`，存在溢出风险

**修复方案**:
1. 新增 D_SETTLE 状态，等待 3 个 `clk_div` 周期确保 IDELAY 输出稳定
2. 采样容错改为统计总错误数 `sample_err_cnt <= SAMPLE_ERR_TOLERANCE (2)`
3. 采样次数判断改为 `sample_cnt >= SAMPLE_CNT`

```verilog
// D_SETTLE: 等待稳定
D_SETTLE: begin
    settle_cnt <= settle_cnt + 1'b1;
end
// 退出条件: settle_cnt >= SETTLE_CYCLES

// D_WAIT: 统计总错误数
D_WAIT: begin
    sample_cnt <= sample_cnt + 1'b1;
    if(iserdes_q != 8'h55)
        sample_err_cnt <= sample_err_cnt + 1'b1;
end
// 退出条件: sample_cnt >= SAMPLE_CNT

// D_SAMPLE: 容错判定
D_SAMPLE: begin
    valid_window[scan_step] <= (sample_err_cnt <= SAMPLE_ERR_TOLERANCE);
    scan_step <= scan_step + 1'b1;
end
```

---

## 12. 时序分析

### 12.1 延迟校准总耗时

| 阶段 | 周期数 | 说明 |
|------|--------|------|
| 单个抽头 | 21 | 1(SET_DELAY) + 3(SETTLE) + 16(WAIT) + 1(SAMPLE) |
| 32 个抽头 | 672 | 21 × 32 |
| CALC_WIN + DONE | 2 | 1 + 1 |
| **总计** | **674** | **6.74μs @100MHz** |

### 12.2 字对齐总耗时

| 场景 | 周期数 | 说明 |
|------|--------|------|
| 最佳情况（1次成功） | 22 | 1(BITSLIP) + 5(WAIT) + 16(CHECK) |
| 最坏情况（8次全失败） | 64 | 8 × (1+5) + 16 |
| 典型情况（2~3次成功） | 28~34 | 2~3 × 6 + 16 |

### 12.3 单通道总校准时间

```
延迟校准 + 字对齐 = 674 + 22~64 = 696~738 周期 ≈ 6.96~7.38μs @100MHz
```

### 12.4 关键时序路径

| 路径 | 源 → 目的 | 时钟域 | 备注 |
|------|-----------|--------|------|
| 数据路径 | IBUFDS → IDELAYE2 → ISERDESE2 → rx_data | clk_bufio/clk_div | 800Mbps 串行，100MHz 并行 |
| BITSLIP 路径 | bitslip_req → ISERDESE2.BITSLIP | clk_div | 单周期脉冲 |
| IDELAY 加载 | delay_ld → IDELAYE2.LD | clk_div | 单周期脉冲，需 SETTLE 等待 |
| scan_done 脉冲 | D_DONE → W_IDLE | clk_div | 同时钟域，上升沿检测 |

---

## 13. 设计约束与注意事项

### 13.1 XDC 约束要求

1. **I/O 标准**: LVDS 差分引脚需在 XDC 中指定 `IOSTANDARD`（如 `LVDS_25`）
2. **差分终端**: `DIFF_TERM` 属性需在 XDC 中设置
3. **时钟约束**: `clk_bufio` (400MHz) 和 `clk_div` (100MHz) 需约束并确保来源于同一 MMCM
4. **IDELAYCTRL**: 每个 I/O Bank 需例化一个 IDELAYCTRL，参考时钟 200MHz

### 13.2 使用注意事项

1. **IDELAYCTRL 就绪**: 使用前需确保 IDELAYCTRL 的 `RDY` 信号已拉高（上层模块管理）
2. **训练码型协调**: Phase 0 发送 `0x55`，Phase 1 发送 `0xB5`，需与 TX 侧严格同步
3. **retrain_req 脉冲宽度**: `retrain_req` 需保持至少 1 个 `clk_div` 周期
4. **多通道独立性**: 各通道独立校准，完成时间可能不同，上层需等待所有通道完成
5. **信号恶化阈值**: `BAD_WORD_THRESHOLD` 可根据实际噪声环境调整

### 13.3 已知限制

1. **IDELAYCTRL 未在本模块例化**: 注释掉了，需在上层模块或约束中处理
2. **ISERDESE2 O 输出未使用**: 组合输出 `O` 端口悬空，仅使用寄存器输出 Q1-Q8
3. **无位翻转处理**: 本模块不处理 LVDS 数据线的位翻转（P/N 接反），需在 PCB 设计时保证正确极性
4. **单级 ISERDESE2**: 8:1 解串使用单级 MASTER 模式，如需更宽（如 10:1）需级联 SLAVE

---

## 14. 信号清单速查表

### 14.1 延迟校准 FSM 信号

| 信号 | 位宽 | 复位值 | 描述 |
|------|------|--------|------|
| `d_curr_state` | 3 | D_IDLE | 当前状态 |
| `d_next_state` | 3 | — | 下一状态（组合） |
| `scan_step` | 5 | 0 | 延迟扫描步 0~31 |
| `sample_cnt` | 5 | 0 | 采样计数 0~16 |
| `sample_err_cnt` | 4 | 0 | 采样错误计数 |
| `valid_window` | 32 | 0 | 有效窗口位图 |
| `scan_done` | 1 | 0 | 扫描完成脉冲 |
| `best_delay_val` | 5 | 0 | 最佳延迟值 |
| `settle_cnt` | 3 | 0 | IDELAY 稳定计数 |
| `delay_ce/inc/ld` | 1 each | 0 | IDELAYE2 控制信号 |
| `delay_cnt_val` | 5 | 0 | IDELAYE2 加载值 |

### 14.2 字对齐 FSM 信号

| 信号 | 位宽 | 复位值 | 描述 |
|------|------|--------|------|
| `w_curr_state` | 3 | W_IDLE | 当前状态 |
| `w_next_state` | 3 | — | 下一状态（组合） |
| `bitslip_req` | 1 | 0 | BITSLIP 脉冲 |
| `bitslip_wait` | 4 | 0 | BITSLIP 等待计数 |
| `align_check_cnt` | 8 | 0 | 连续匹配计数 |
| `bitslip_cnt` | 4 | 0 | BITSLIP 尝试次数 |
| `bad_word_cnt` | 8 | 0 | 连续非0xB5计数 |
| `lane_align_done` | 1 | 0 | 对齐完成标志 |
| `scan_done_prev` | 1 | 0 | scan_done 延迟寄存器 |

### 14.3 输出信号汇总

| 信号 | 位宽 | 有效电平 | 描述 |
|------|------|----------|------|
| `rx_data` | 8 | — | 并行数据输出 |
| `lane_align_done` | 1 | 高 | 通道对齐完成 |
| `lane_calib_err` | 1 | 高 | 通道校准错误 |
| `best_delay_val` | 5 | — | 最佳延迟值（0~31） |

---

> **文档结束** | lvds_rx_lane_phy.v 详细设计报告 V1.0 | 2026-08-08
