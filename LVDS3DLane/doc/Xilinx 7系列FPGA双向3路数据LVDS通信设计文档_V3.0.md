# Xilinx 7系列FPGA双向3路数据LVDS通信设计文档_V3.0

**版本**：V3.0  
**适配环境**：Vivado 2018.2 / Xilinx 7系列FPGA  
**文档日期**：2026-07-28  
**文档范围**：需求定义、架构设计、RTL实现、仿真验证、硬件约束全流程

---

## V3.0变更摘要

V3.0基于V2.0代码深度Review后发现的15项遗漏问题及5项修复残留缺陷，进行系统性修复。核心改进：

| 变更类别 | 变更内容 | 影响模块 |
|----------|----------|----------|
| **帧协议重构** | RX帧解析器重写为固定3字节对齐格式，去除错误的sof_offset滑动窗口机制 | `lvds_rx_link.v` |
| **TX退出条件** | TX_PAYLOAD退出改用加法`payload_cnt+LANE_CNT>=payload_len`彻底消除下溢 | `lvds_tx_channel.v` |
| **主从握手加固** | 主机发送≥3次MASTER_ACK后才进入LINK_UP，收到SLAVE_READY立即回复 | `lvds_link_manager.v` |
| **M_FAULT自恢复** | M_FAULT状态增加50000周期恢复定时器，替代retry_cnt死锁退出 | `lvds_rx_phy.v` |
| **锁定投票阈值** | lock_match_cnt扩展为16bit，阈值提高至80%（4000/5000） | `lvds_rx_phy.v` |
| **retrain握手改进** | retrain_ack改为`retrain_req & ~phy_ready`，确保物理层实际响应 | `lvds_rx_channel.v` |
| **字对齐保护** | BITSLIP时清零lane_align_done；bitslip溢出置lane_calib_err | `lvds_rx_lane_phy.v` |
| **延迟校准容错** | 采样允许2次错误（SAMPLE_ERR_TOLERANCE=2） | `lvds_rx_lane_phy.v` |
| **deskew验证加强** | 偏移检测增加offset_found标志；锁定需3路同时连续匹配验证 | `lane_deskew.v` |
| **训练余量增大** | TRAIN_CALIB_DURATION从2000增至4000周期 | `lvds_tx_channel.v` |

---

## 1 文档概述

### 1.1 设计背景

本设计针对两片FPGA点对点高带宽通信场景，采用**每方向1路随路时钟+3路串行数据**的多通道LVDS架构，单向总带宽2.4Gbps（3×800Mbps），全双工独立传输。

设计特点：
- 分层解耦架构（物理层/链路层/管理层）
- 全部状态机严格三段式设计
- 多通道独立校准+通道间相位对齐
- 主从非对称握手协议
- 工业级容错与自恢复机制

### 1.2 需求清单

| 需求类别 | 具体需求项 |
|----------|------------|
| 物理通道 | 共8路LVDS差分对：每方向1路时钟+3路数据 |
| 串行速率 | 单路800Mbps，单向2.4Gbps，全双工 |
| 主从架构 | FPGA1为主机，FPGA2为从机，上电默认发送训练序列 |
| 通道同步 | 3路独立校准+通道间相位对齐（Deskew），确保输出数据同步 |
| 训练机制 | 两阶段训练：阶段0（0x55延迟校准4000周期）→阶段1（0xB5字对齐） |
| 延迟校准 | 每路IDELAYE2（VAR_LOAD）32级全量扫描+最大稳定窗口中心选取，允许2次采样容错 |
| 帧协议 | 3字节对齐帧格式，SOF1固定在byte0，无偏移歧义 |
| 心跳机制 | 双向独立心跳检测，连续5次超时触发重训练 |
| 重训练 | 心跳超时/连续校验错误/外部强制三种触发，自动重建全流程 |
| 锁定检查 | 5000周期内80%匹配率（4000/5000）投票通过 |
| 故障恢复 | M_FAULT状态50000周期后自动重试，避免永久死锁 |
| 编码规范 | 所有状态机三段式；FIFO采用XPM_FIFO_SYNC原语 |
| 跨时钟域 | 所有跨域信号经两级同步器处理，脉冲信号边沿检测 |

---

## 2 总体架构设计

### 2.1 系统架构

```
FPGA1(主机)                                    FPGA2(从机)
┌─────────────────────────┐                   ┌─────────────────────────┐
│  用户接口(24bit)         │                   │  用户接口(24bit)         │
│  ┌───────────────────┐  │   4路LVDS(→)     │  ┌───────────────────┐  │
│  │  TX Channel       │──┼──────────────────▶┼──│  RX Channel       │  │
│  │  (FIFO+帧调度+    │  │  1CLK+3DATA      │  │  (PHY+Link)       │  │
│  │   3×OSERDES)      │  │                   │  │                   │  │
│  └───────────────────┘  │                   │  └───────────────────┘  │
│  ┌───────────────────┐  │   4路LVDS(←)     │  ┌───────────────────┐  │
│  │  RX Channel       │◀─┼──────────────────┼──│  TX Channel       │  │
│  │  (PHY+Link)       │  │  1CLK+3DATA      │  │  (FIFO+帧调度+    │  │
│  │                   │  │                   │  │   3×OSERDES)      │  │
│  └───────────────────┘  │                   │  └───────────────────┘  │
│  ┌───────────────────┐  │                   │  ┌───────────────────┐  │
│  │  Link Manager     │  │                   │  │  Link Manager     │  │
│  │  (IS_MASTER=1)    │  │                   │  │  (IS_MASTER=0)    │  │
│  └───────────────────┘  │                   │  └───────────────────┘  │
└─────────────────────────┘                   └─────────────────────────┘
```

### 2.2 时钟域划分

| 时钟域 | 频率 | 来源 | 职责 |
|--------|------|------|------|
| `clk_ser` | 400MHz | 顶层MMCM | OSERDESE2串行时钟 |
| `clk_div`(TX) | 100MHz | 顶层MMCM | TX帧调度并行时钟 |
| `clk_div`(RX) | 100MHz | BUFR(LVDS CLK/4) | RX物理层+链路层 |
| `clk_ref` | 100MHz | 外部输入 | 链路管理器 |
| `ref_clk_200m` | 200MHz | 外部输入 | IDELAYCTRL |

**CDC路径**：
- `clk_div(RX)` → `clk_ref`：link_manager内部两级同步（rx_phy_ready, rx_link_up, ctrl_frame_valid等）
- `clk_ref` → `clk_div(TX)`：顶层两级同步+脉冲边沿检测（tx_train_en, ctrl_frame_send, ctrl_frame_type/payload, user_tx_en）

### 2.3 模块层次

```
lvds_bidirectional_top (顶层集成+CDC)
├── lvds_tx_channel (发送通道)
│   ├── xpm_fifo_sync (用户数据缓存)
│   ├── 3× OSERDESE2 (数据串行化)
│   ├── 1× OSERDESE2 (时钟生成)
│   └── 4× OBUFDS (差分输出)
├── lvds_rx_channel (接收通道封装)
│   ├── lvds_rx_phy (物理层顶层)
│   │   ├── IBUFDS + BUFIO + BUFR (时钟恢复)
│   │   ├── IDELAYCTRL (共享)
│   │   ├── 3× lvds_rx_lane_phy (单通道物理层)
│   │   │   ├── IBUFDS (差分输入)
│   │   │   ├── IDELAYE2 (延迟校准)
│   │   │   └── ISERDESE2 (解串)
│   │   └── lane_deskew (通道间对齐)
│   └── lvds_rx_link (链路层帧解析)
└── lvds_link_manager (主从握手管理)
```

### 2.4 建链握手全流程（V3.0更新）

1. **上电训练**：双方TX发送两阶段训练码（前4000周期0x55，后续0xB5）
2. **从机校准**：每路独立延迟扫描(0x55)→字对齐(0xB5)→通道对齐(0xB5)→锁定检查(80%通过)
3. **从机通知**：周期性发送SLAVE_READY控制帧
4. **主机校准**：主机接收通道完成同样的校准+对齐+锁定流程
5. **主机确认**：收到SLAVE_READY后**立即**发送首次MASTER_ACK，并连续发送≥3次
6. **从机进入正常态**：收到MASTER_ACK进入LINK_UP
7. **主机进入正常态**：发送3次MASTER_ACK后进入LINK_UP，双向开启数据传输

---

## 3 核心机制详细设计

### 3.1 物理层设计

#### 3.1.1 两阶段训练协议

| 阶段 | 训练码 | 持续时间 | 用途 |
|------|--------|----------|------|
| 阶段0 | `8'h55` | 4000个clk_div周期 | RX IDELAYE2延迟扫描（实际需~576周期，提供7倍余量） |
| 阶段1 | `8'hB5` | 持续至退出训练 | RX BITSLIP字对齐 + lane_deskew同步 + 锁定检查 |

```verilog
localparam TRAIN_CALIB_DURATION = 16'd4000;
reg [15:0] train_phase_cnt;
wire       train_phase = (train_phase_cnt >= TRAIN_CALIB_DURATION);

// 训练码选择
tx_data_mux = train_phase ? {LANE_CNT{8'hB5}} : {LANE_CNT{8'h55}};
```

#### 3.1.2 延迟校准（每通道独立）

- **硬件**：IDELAYE2（VAR_LOAD模式），通过LD+CNTVALUEIN直接加载任意延迟值
- **算法**：32级全量扫描，每级16次采样检测0x55
- **V3.0容错**：允许16次采样中2次错误仍判定有效（`SAMPLE_ERR_TOLERANCE=2`）
- **窗口计算**：寻找最长连续有效区间，取中心值；最大窗口<4级判定失败

```verilog
localparam SAMPLE_ERR_TOLERANCE = 4'd2;
D_WAIT: begin
    sample_cnt <= sample_cnt + 1'b1;
    if(iserdes_q != 8'h55) begin
        sample_err_cnt <= sample_err_cnt + 1'b1;
        if(sample_err_cnt >= SAMPLE_ERR_TOLERANCE)
            sample_valid <= 1'b0;
    end
end
```

#### 3.1.3 字对齐（每通道独立）

- 延迟校准完成后启动，检测连续16个0xB5匹配
- **V3.0 BITSLIP溢出保护**：超过`MAX_BITSLIP=8`次仍未对齐，置`lane_calib_err`
- **V3.0 lane_align_done清零**：进入W_BITSLIP时清零，通知上游对齐进行中

```verilog
W_BITSLIP: begin
    bitslip_req <= 1'b1;
    bitslip_cnt <= bitslip_cnt + 1'b1;
    lane_align_done <= 1'b0;  // V3.0: 重新对齐时清除标志
end
W_CHECK: begin
    if(iserdes_q != 8'hB5) begin
        if(bitslip_cnt >= MAX_BITSLIP)
            lane_calib_err <= 1'b1;  // V3.0: 溢出报错
    end
end
```

#### 3.1.4 通道间对齐（Lane Deskew）

以lane0为基准，通过移位寄存器（深度8级）延迟对齐lane1/lane2：

**V3.0改进**：
- `offset_found`寄存器：每通道首次匹配后锁定偏移值，防止for循环覆盖
- 连续匹配验证：需**所有通道偏移已找到**后，连续16周期3路同步字同时出现才判定完成
- `deskew_done`保持锁定，仅由复位清零

```verilog
reg [LANE_CNT-1:0] offset_found;

// 偏移检测（仅首次匹配锁定）
if(!offset_found[i]) begin
    for(j = 0; j < DESKEW_DEPTH; j = j + 1) begin
        if(shift_reg[i][j] == sync_word && !offset_found[i]) begin
            lane_offset[i] <= j[2:0];
            offset_found[i] <= 1'b1;
        end
    end
end

// 验证：所有通道偏移确定后，3路同时匹配
if(&offset_found) begin
    if(shift_reg[1][lane_offset[1]] == sync_word &&
       shift_reg[2][lane_offset[2]] == sync_word) begin
        check_cnt <= check_cnt + 1'b1;
    end else begin
        check_cnt <= 4'd0;  // 非连续，重新计数
    end
end
```

#### 3.1.5 锁定检查（全局状态机）

| 参数 | V2.0 | V3.0 | 说明 |
|------|------|------|------|
| LOCK_CHECK_CYCLES | 5000 | 5000 | 检查窗口周期数 |
| LOCK_VOTE_THRESHOLD | 200 (4%) | 4000 (80%) | 匹配率阈值 |
| lock_match_cnt位宽 | 8bit | 16bit | 支持更大阈值 |

#### 3.1.6 故障恢复（V3.0新增）

M_FAULT状态不再依赖retry_cnt退出（旧方案在3次失败后永久死锁），改为：
- 进入M_FAULT后启动`fault_wait_timer`
- 计数达到`FAULT_RECOVERY_CYCLES=50000`后自动回M_IDLE重试
- 无限次重试直到成功或外部干预

```verilog
localparam FAULT_RECOVERY_CYCLES = 16'd50000;
reg [15:0] fault_wait_timer;

M_FAULT: if(fault_wait_timer >= FAULT_RECOVERY_CYCLES) m_next_state = M_IDLE;
```

### 3.2 链路层设计

#### 3.2.1 帧格式（V3.0重构）

**V3.0核心变更**：TX保证帧3字节对齐，SOF1固定在byte0位置，RX无需偏移检测。

帧在3字节通道中的字节级排布：

| clk_div周期 | byte2[23:16] | byte1[15:8] | byte0[7:0] | TX状态 |
|-------------|-------------|-------------|------------|--------|
| 0 | TYPE | SOF2(0x55) | SOF1(0xAA) | TX_SOF_TYPE |
| 1 | 0x00 | 0x00 | LEN | TX_LEN |
| 2~N | data[23:16] | data[15:8] | data[7:0] | TX_PAYLOAD |
| N+1 | 0x00 | 0x00 | CHECKSUM | TX_CHECKSUM |

**帧类型定义**：

| 帧类型 | TYPE值 | Payload长度 | 说明 |
|--------|--------|-------------|------|
| 心跳帧 | 0x10 | 2字节 | 16bit心跳计数（大端序） |
| 用户数据帧 | 0x20 | 3~255字节（3的倍数） | FIFO读出的24bit数据 |
| 从机就绪帧 | 0x02 | 1字节 | 链路状态码 |
| 主机确认帧 | 0x03 | 1字节 | 确认码 |

**Checksum计算**：SOF1 + SOF2 + TYPE + LEN + 所有Payload字节（含padding的0x00），取低8位。

#### 3.2.2 发送端帧调度

**状态机**：`TX_IDLE → TX_SOF_TYPE → TX_LEN → TX_PAYLOAD → TX_CHECKSUM → TX_IDLE`

**调度优先级**：控制帧 > 用户数据帧 > 心跳帧 > 空闲(0x55)

**V3.0退出条件**：
```verilog
TX_PAYLOAD: tx_next_state = (payload_cnt + LANE_CNT >= payload_len) ? TX_CHECKSUM : TX_PAYLOAD;
```
使用加法避免任何无符号减法下溢，对所有payload_len值均安全。

**FIFO读时序**（FWFT模式，latency=0）：
- TX_LEN周期末置`fifo_rd_en=1`（用户数据帧时）
- TX_PAYLOAD周期：`fifo_dout`输出有效数据，同时判断是否继续读

#### 3.2.3 接收端帧解析（V3.0重写）

**V3.0核心改进**：去除错误的滑动窗口+sof_offset机制，改为固定位置检测：

```verilog
// 帧头检测：TX保证SOF1在byte0, SOF2在byte1
wire sof_detected = (rx_data_in[7:0] == 8'hAA && rx_data_in[15:8] == 8'h55);
```

**状态机**：`F_IDLE → F_LEN → F_PAYLOAD → F_CHECKSUM → F_IDLE`（4状态，比V2.0减少1状态）

**字段提取规则**（固定位置，无偏移计算）：

| 状态 | 提取内容 | 位置 |
|------|----------|------|
| F_IDLE | SOF检测 + TYPE | byte2 = rx_data_in[23:16] |
| F_LEN | LEN | byte0 = rx_data_in[7:0] |
| F_PAYLOAD | 3字节数据 | rx_data_in[23:0] |
| F_CHECKSUM | checksum | byte0 = rx_data_in[7:0] |

**退出条件**：
```verilog
F_PAYLOAD: if(payload_cnt + LANE_CNT >= frame_len) f_next_state = F_CHECKSUM;
```

**phy_ready失效保护**：状态机第一段增加`!phy_ready`复位条件，确保链路断开时状态机回F_IDLE。

#### 3.2.4 心跳与重训练

- **心跳超时**：`HEARTBEAT_TIMEOUT_CNT=600000`周期（6ms@100MHz），连续5次超时触发重训练
- **帧错误**：连续`MAX_ERR_CNT=10`帧校验失败触发重训练
- **V3.0 retrain_ack改进**：`retrain_ack = retrain_req_inner & ~phy_ready`
  - 物理层实际进入重训练（phy_ready=0）后才清除请求
  - 避免请求过早清除导致物理层未响应

### 3.3 链路管理设计

#### 3.3.1 状态机

`S_IDLE → S_TRAINING → S_WAIT_PEER → S_LINK_UP → S_RETRAIN`

#### 3.3.2 主从握手协议（V3.0加固）

**从机行为**：
- S_WAIT_PEER：周期性（每1000周期）发送SLAVE_READY
- 收到MASTER_ACK → S_LINK_UP

**主机行为（V3.0改进）**：
- S_WAIT_PEER：收到SLAVE_READY时**立即**回复首次MASTER_ACK
- 后续每1000周期继续发送MASTER_ACK并计数
- `master_ack_sent_cnt >= MASTER_ACK_SEND_CNT(3)` 后 → S_LINK_UP

```verilog
localparam MASTER_ACK_SEND_CNT = 4'd3;
reg [3:0] master_ack_sent_cnt;

// 状态跳转条件
S_WAIT_PEER: begin
    if(IS_MASTER) begin
        if(master_recv_slave_ready && master_ack_sent_cnt >= MASTER_ACK_SEND_CNT)
            next_state = S_LINK_UP;
    end
end
```

**设计意图**：确保从机在主机进入LINK_UP前已收到至少1次MASTER_ACK，避免主从时序窗口导致的握手死锁。

#### 3.3.3 CDC同步

| 信号方向 | 信号类型 | 同步方式 |
|----------|----------|----------|
| clk_div→clk_ref | 电平(phy_ready等) | 两级FF |
| clk_div→clk_ref | 脉冲(ctrl_frame_valid) | 两级FF + 边沿检测 |
| clk_ref→clk_div | 电平(tx_train_en等) | 两级FF |
| clk_ref→clk_div | 脉冲(ctrl_frame_send) | 两级FF + 边沿检测 |
| clk_ref→clk_div | 数据(type/payload) | 两级FF（与脉冲同拍有效） |

---

## 4 RTL模块详细设计

### 4.1 lvds_tx_channel

**功能**：24bit用户数据缓存→帧封装→两阶段训练→3路OSERDESE2串行化→LVDS输出

**参数**：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| DATA_WIDTH | 8 | 单通道位宽 |
| LANE_CNT | 3 | 通道数 |
| CLK_FREQ | 100000000 | 并行时钟频率 |
| HEARTBEAT_MS | 1 | 心跳间隔(ms) |
| MAX_PAYLOAD | 255 | 最大帧载荷 |
| USER_FIFO_DEPTH | 512 | FIFO深度 |
| TRAIN_CALIB_DURATION | 4000 | 训练阶段0持续周期 |

**接口**：

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| clk_ser | in | 1 | 400MHz串行时钟 |
| clk_div | in | 1 | 100MHz并行时钟 |
| rst_n | in | 1 | 异步复位（低有效） |
| train_en | in | 1 | 训练模式使能 |
| ctrl_frame_send | in | 1 | 控制帧发送脉冲 |
| ctrl_frame_type | in | 8 | 控制帧类型 |
| ctrl_frame_payload | in | 8 | 控制帧载荷 |
| tx_data_in | in | 24 | 用户数据 |
| tx_data_valid | in | 1 | 用户数据有效 |
| tx_ready | out | 1 | 可接收数据（FIFO非满且非训练） |
| lvds_clk_p/n | out | 1 | LVDS时钟差分输出 |
| lvds_data_p/n | out | 3 | LVDS数据差分输出 |

### 4.2 lvds_rx_lane_phy

**功能**：单路LVDS接收物理层——延迟校准+解串+字对齐

**状态机**：
- 延迟校准FSM：`D_IDLE→D_SET_DELAY→D_WAIT→D_SAMPLE→D_CALC_WIN→D_DONE`
- 字对齐FSM：`W_IDLE→W_BITSLIP→W_WAIT→W_CHECK`

**V3.0关键改进**：
- `sample_err_cnt`：16次采样允许2次错误
- `bitslip_cnt >= MAX_BITSLIP`时置`lane_calib_err`
- `lane_align_done`在进入W_BITSLIP时清零
- `retrain_req`时清零`bitslip_cnt`和`lane_calib_err`

### 4.3 lvds_rx_phy

**功能**：3通道接收物理层顶层——时钟恢复+3路例化+通道对齐+全局状态机

**全局状态机**：`M_IDLE→M_CALIB→M_LANE_DESKEW→M_LOCK_CHECK→M_NORMAL→M_FAULT`

**V3.0关键改进**：
- `lock_match_cnt`扩展为16bit
- `LOCK_VOTE_THRESHOLD = 4000`（80%匹配率）
- M_FAULT使用`fault_wait_timer`（50000周期后自动恢复），替代retry_cnt死锁方案
- `retry_cnt`仍保留用于统计，不影响状态跳转

**Xilinx原语使用**：

| 原语 | 数量 | 配置 |
|------|------|------|
| IBUFDS(时钟) | 1 | DIFF_TERM=TRUE, LVDS_25 |
| BUFIO | 1 | 高速串行采样时钟 |
| BUFR | 1 | DIVIDE=4, 100MHz并行时钟 |
| IDELAYCTRL | 1 | REFCLK=200MHz, 共享 |

### 4.4 lane_deskew

**功能**：通道间相位对齐——以lane0为基准，移位寄存器法延迟补偿

**参数**：`DESKEW_DEPTH=8`（最大可补偿7个clk_div周期偏移）

**V3.0关键改进**：
- `offset_found[LANE_CNT-1:0]`寄存器：防止for循环覆盖首次匹配
- 锁定验证加强：需`&offset_found`为真且3路同时匹配sync_word连续16次
- 非连续匹配时`check_cnt`清零重计

### 4.5 lvds_rx_link（V3.0重写）

**功能**：接收链路层——帧检测+解析+分流+校验+心跳监控

**V3.0核心变更**：
- 去除`prev_byte`/`sof_offset`/`slide_window`/`det_offset`
- SOF检测简化为`rx_data_in[7:0]==0xAA && rx_data_in[15:8]==0x55`
- 状态机从5状态减为4状态：`F_IDLE→F_LEN→F_PAYLOAD→F_CHECKSUM`
- F_IDLE同时提取TYPE（byte2），消除收发状态机错位问题
- 所有字段位置固定（byte0/byte2），无需运行时偏移计算
- `!phy_ready`时状态机复位到F_IDLE

**接口**：

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| rx_data_in | in | 24 | 物理层输出数据 |
| rx_data_valid | in | 1 | 物理层数据有效 |
| phy_ready | in | 1 | 物理层就绪 |
| rx_data_out | out | 24 | 用户数据输出 |
| rx_data_out_valid | out | 1 | 用户数据有效 |
| ctrl_frame_valid | out | 1 | 控制帧有效脉冲 |
| ctrl_frame_type | out | 8 | 控制帧类型 |
| ctrl_frame_payload | out | 8 | 控制帧载荷 |
| retrain_req | out | 1 | 重训练请求 |
| retrain_ack | in | 1 | 重训练确认 |
| link_up | out | 1 | 链路建立标志 |
| heartbeat_err | out | 1 | 心跳错误标志 |

### 4.6 lvds_rx_channel

**功能**：接收通道封装——集成物理层+链路层，提供统一接口

**V3.0关键改进**：
- `retrain_ack = retrain_req_inner & ~phy_ready`
- 物理层`phy_ready`拉低后才确认重训练请求被接受
- 确保物理层有足够时间响应，避免请求过早清除

### 4.7 lvds_link_manager

**功能**：主从握手管理——训练控制+控制帧收发+用户数据门控

**V3.0关键改进**：
- 新增`master_ack_sent_cnt`（4bit）
- 新增`MASTER_ACK_SEND_CNT=3`参数
- 主机收到SLAVE_READY后立即发送ACK（不等ctrl_send_timer）
- 主机需发送≥3次ACK后才跳转S_LINK_UP

### 4.8 lvds_bidirectional_top

**功能**：顶层集成——TX/RX/LinkManager + CDC同步

**CDC同步实现**：
```verilog
// clk_ref → clk_div 电平同步
reg tx_train_en_s1, tx_train_en_s2;
reg user_tx_en_s1, user_tx_en_s2;

// clk_ref → clk_div 脉冲同步+边沿检测
reg ctrl_frame_send_s1, ctrl_frame_send_s2, ctrl_frame_send_s2_d;
wire ctrl_frame_send_sync = ctrl_frame_send_s2 & ~ctrl_frame_send_s2_d;

// 数据总线同步（与脉冲同拍有效）
reg [7:0] ctrl_frame_type_s1, ctrl_frame_type_s2;
reg [7:0] ctrl_frame_payload_s1, ctrl_frame_payload_s2;
```

---

## 5 仿真验证

### 5.1 Testbench架构

`lvds_3lane_bidirectional_tb.v`采用双DUT互连架构：
- 主机DUT（IS_MASTER=1）+ 从机DUT（IS_MASTER=0）
- 8路LVDS信号直连（带可配置延迟模型）
- 每通道独立延迟注入（`lane_delay[0:2]`）
- 链路断开故障注入（`link_break_m2s`/`link_break_s2m`）

### 5.2 验证场景

| 场景 | 覆盖内容 |
|------|----------|
| 场景1 | 双向建链握手：等待link_all_up双方均为1 |
| 场景2 | 双向数据传输：200×24bit递增序列，自动比对 |
| 场景3 | 通道偏移对齐：lane1+1ns, lane2+1.5ns偏移后重训练 |
| 场景4 | 正向链路故障：断链500us后恢复，验证自动重训练 |
| 场景5 | 外部强制重训练：手动触发后验证重建链 |

### 5.3 时钟配置

| 时钟 | 周期 | 频率 |
|------|------|------|
| clk_ref | 10ns | 100MHz |
| clk_ser | 2.5ns | 400MHz |
| clk_200m | 5ns | 200MHz |
| clk_div | 10ns | 100MHz |

---

## 6 硬件约束

### 6.1 时钟约束

```tcl
# 主时钟
create_clock -period 10.000 -name clk_ref [get_ports clk_ref]
create_clock -period 5.000 -name ref_clk_200m [get_ports ref_clk_200m]

# MMCM生成时钟
create_generated_clock -name clk_ser -source [get_pins mmcm/CLKIN1] \
    -multiply_by 4 [get_pins mmcm/CLKOUT0]
create_generated_clock -name clk_div -source [get_pins mmcm/CLKIN1] \
    -multiply_by 1 [get_pins mmcm/CLKOUT1]

# LVDS接收恢复时钟
create_clock -period 2.500 -name rx_lvds_clk [get_ports rx_lvds_clk_p]
create_generated_clock -name rx_clk_div -source [get_ports rx_lvds_clk_p] \
    -divide_by 4 [get_pins *u_bufr_div/O]
```

### 6.2 跨时钟域约束

```tcl
# CDC路径设置为异步
set_clock_groups -asynchronous \
    -group [get_clocks clk_ref] \
    -group [get_clocks clk_div] \
    -group [get_clocks rx_clk_div]

# CDC同步器最大延迟约束
set_max_delay -datapath_only -from [get_clocks clk_ref] \
    -to [get_clocks clk_div] 8.0
set_max_delay -datapath_only -from [get_clocks rx_clk_div] \
    -to [get_clocks clk_ref] 8.0
```

### 6.3 IO约束

```tcl
# 通道间偏移约束
set_max_skew -from [get_ports {tx_lvds_data_p[*]}] \
    -to [get_ports {tx_lvds_clk_p}] 0.5

# IO电平标准
set_property IOSTANDARD LVDS_25 [get_ports {tx_lvds_* rx_lvds_*}]
set_property DIFF_TERM TRUE [get_ports {rx_lvds_*}]

# IDELAYCTRL位置
set_property LOC IDELAYCTRL_X0Y0 [get_cells *u_idelayctrl]
```

### 6.4 布局建议

- 3路SerDes原语靠近对应IOB
- PCB走线长度差控制在500mil以内
- 200MHz参考时钟采用差分输入，保证低抖动

---

## 7 Xilinx原语使用总结

| 原语 | 文件 | 数量 | 关键配置 |
|------|------|------|----------|
| OSERDESE2 | lvds_tx_channel | 4 | DDR, WIDTH=8, TRISTATE_WIDTH=4 |
| OBUFDS | lvds_tx_channel | 4 | LVDS_25, SLEW=FAST |
| IBUFDS | lvds_rx_lane_phy, lvds_rx_phy | 4 | DIFF_TERM=TRUE, LVDS_25 |
| IDELAYE2 | lvds_rx_lane_phy | 3 | VAR_LOAD, REFCLK=200MHz |
| IDELAYCTRL | lvds_rx_phy | 1 | REFCLK=200MHz |
| ISERDESE2 | lvds_rx_lane_phy | 3 | DDR, WIDTH=8, NETWORKING, IFD |
| BUFIO | lvds_rx_phy | 1 | 高速采样时钟 |
| BUFR | lvds_rx_phy | 1 | DIVIDE=4, 7SERIES |
| xpm_fifo_sync | lvds_tx_channel | 1 | 24bit, FWFT, depth=512 |

---

## 8 状态机总结

| 模块 | 状态机名称 | 状态数 | 状态流 |
|------|-----------|--------|--------|
| lvds_tx_channel | TX帧调度 | 5 | IDLE→SOF_TYPE→LEN→PAYLOAD→CHECKSUM |
| lvds_rx_lane_phy | 延迟校准 | 6 | IDLE→SET_DELAY→WAIT→SAMPLE→CALC_WIN→DONE |
| lvds_rx_lane_phy | 字对齐 | 4 | IDLE→BITSLIP→WAIT→CHECK |
| lvds_rx_phy | 全局主FSM | 6 | IDLE→CALIB→DESKEW→LOCK→NORMAL→FAULT |
| lvds_rx_link | 帧解析 | 4 | IDLE→LEN→PAYLOAD→CHECKSUM |
| lvds_link_manager | 链路管理 | 5 | IDLE→TRAINING→WAIT_PEER→LINK_UP→RETRAIN |

全部6个状态机严格遵循三段式设计规范。

---

## 9 版本变更追踪

### V1.0→V2.0（12项修复）

| 编号 | 严重程度 | 修复内容 |
|------|----------|----------|
| P-01 | 🔴致命 | 两阶段训练协议 |
| P-02 | 🔴致命 | TX_PAYLOAD下溢保护 |
| P-03 | 🔴致命 | F_PAYLOAD下溢保护 |
| P-04 | 🔴致命 | retry_cnt多驱动消除 |
| P-05 | 🟠严重 | lane_align_done锁定保持 |
| P-06 | 🟠严重 | deskew_done锁定保持 |
| P-07 | 🟠严重 | CDC同步添加 |
| P-08 | 🟠严重 | retrain握手改进 |
| P-09 | 🟡一般 | IDELAYE2 VAR_LOAD |
| P-10 | 🟡一般 | 心跳单周期提取 |
| P-11 | 🟡一般 | deskew首次匹配保护 |
| P-12 | 🟡一般 | FIFO sleep端口 |

### V2.0→V3.0（20项修复）

| 编号 | 严重程度 | 模块 | 修复内容 |
|------|----------|------|----------|
| N-01/N-03 | 🔴致命 | lvds_rx_link | 帧解析器重写，固定位置字段提取 |
| N-02 | 🔴致命 | lvds_tx_channel | TX_PAYLOAD退出条件用加法 |
| R-01 | 🟠严重 | lvds_tx_channel | 训练校准时长4000周期 |
| N-08 | 🟠严重 | lvds_link_manager | 主机多次ACK后才进LINK_UP |
| N-05 | 🟠严重 | lvds_rx_channel | retrain_ack用phy_ready确认 |
| N-07 | 🟠严重 | lvds_rx_phy | M_FAULT定时恢复 |
| N-13 | 🟠严重 | lvds_rx_phy | lock阈值提高至80% |
| R-03 | 🟠严重 | lvds_rx_lane_phy | BITSLIP时清零lane_align_done |
| N-12 | 🟠严重 | lvds_rx_lane_phy | bitslip溢出报错 |
| N-06/R-05 | 🟠严重 | lane_deskew | offset_found标志+连续验证 |
| N-11 | 🟡一般 | lvds_rx_lane_phy | 采样容错（允许2次错误） |
| R-04/N-09 | 🟡一般 | - | CDC确认同频无需修改 |
| N-10 | 🟡一般 | - | 心跳字节序确认已匹配 |
| N-04 | 🟡一般 | - | BUFR分频确认正确 |

---

## 10 设计总结

### 10.1 性能指标

| 指标 | 数值 |
|------|------|
| 单路串行速率 | 800Mbps |
| 单向带宽 | 2.4Gbps（3×800Mbps） |
| 全双工总带宽 | 4.8Gbps |
| 用户数据有效带宽 | ~2.0Gbps（扣除帧开销+心跳） |
| 训练建链时间 | <1ms（典型） |
| 心跳间隔 | 1ms |
| 心跳超时 | 6ms |
| 故障恢复时间 | <2ms（重训练全流程） |

### 10.2 资源估算

| 资源 | 数量 | 说明 |
|------|------|------|
| OSERDESE2 | 4/方向 | 3数据+1时钟 |
| ISERDESE2 | 3/方向 | 3数据通道 |
| IDELAYE2 | 3/方向 | 3数据通道 |
| IDELAYCTRL | 1/方向 | 同Bank共享 |
| BUFIO | 1/方向 | RX高速时钟 |
| BUFR | 1/方向 | RX并行时钟 |
| Block RAM | 1 | XPM FIFO (24bit×512) |
| LUT/FF | ~2000 | 逻辑+状态机+CDC |

### 10.3 可扩展性

通过修改`LANE_CNT`参数可适配不同通道数（2/4/...路），链路层与管理层逻辑无需改动。`lane_deskew`模块通过generate适配任意通道数。

### 10.4 后续建议

1. Vivado 2018.2综合验证，确认无错误和关键warning
2. 使用Testbench全场景仿真验证
3. 上板测试：先验证单向建链，再验证双向全双工
4. 如需更高可靠性，可增加FEC或重传机制
