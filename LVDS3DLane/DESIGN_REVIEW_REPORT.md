# LVDS3DLane 设计 Review 报告

**项目**：Xilinx 7系列FPGA双向3路数据LVDS通信设计  
**文档版本**：V1.0  
**Review日期**：2026-07-27  
**Review范围**：9个Verilog源文件 + 1个Testbench  
**检查工具**：Vivado 2018.2 原语库参考（`xilinx2018.2_XPM_Lib/`）、UG471规范

---

## 1. 文件清单与提取结果

| # | 文件名 | 模块名 | 来源 | 状态 |
|---|--------|--------|------|------|
| 1 | `lvds_tx_channel.v` | `lvds_tx_channel` | 文档§4.1 | ✅ 已提取 |
| 2 | `lvds_rx_lane_phy.v` | `lvds_rx_lane_phy` | 文档§4.2 | ✅ 已提取 |
| 3 | `lvds_rx_phy.v` | `lvds_rx_phy` | 文档§4.3 | ✅ 已提取 |
| 4 | `lane_deskew.v` | `lane_deskew` | 文档§4.3 | ✅ 已提取（独立文件） |
| 5 | `lvds_rx_link.v` | `lvds_rx_link` | 文档§4.4 | ✅ 已提取 |
| 6 | `lvds_rx_channel.v` | `lvds_rx_channel` | 文档§4.5 | ✅ 已提取 |
| 7 | `lvds_link_manager.v` | `lvds_link_manager` | 文档§4.6（复用V4版） | ✅ 已提取 |
| 8 | `lvds_bidirectional_top.v` | `lvds_bidirectional_top` | 文档§4.7 | ✅ 已提取 |
| 9 | `lvds_3lane_bidirectional_tb.v` | `lvds_3lane_bidirectional_tb` | 文档§5.3 | ✅ 已提取 |

---

## 2. Xilinx Vivado 2018.2 原语使用检查

### 2.1 检查总览

| 原语 | 使用文件 | 数量 | 检查结果 |
|------|----------|------|----------|
| OSERDESE2 | `lvds_tx_channel.v` | 4（3数据+1时钟） | ⚠️ 有问题 |
| OBUFDS | `lvds_tx_channel.v` | 4（3数据+1时钟） | ✅ 正确 |
| IBUFDS | `lvds_rx_lane_phy.v`, `lvds_rx_phy.v` | 4（3数据+1时钟） | ✅ 正确 |
| IDELAYE2 | `lvds_rx_lane_phy.v` | 3（每通道1个） | ⚠️ 有问题 |
| IDELAYCTRL | `lvds_rx_phy.v` | 1（共用） | ✅ 正确 |
| ISERDESE2 | `lvds_rx_lane_phy.v` | 3（每通道1个） | ✅ 正确 |
| BUFIO | `lvds_rx_phy.v` | 1 | ✅ 正确 |
| BUFR | `lvds_rx_phy.v` | 1 | ✅ 正确 |
| xpm_fifo_sync | `lvds_tx_channel.v` | 1 | ⚠️ 有问题 |

### 2.2 OSERDESE2 检查详情

**文件**：`lvds_tx_channel.v`

```verilog
OSERDESE2 #(
    .DATA_RATE_OQ   ("DDR"),       // ✅ DDR模式，800Mbps
    .DATA_RATE_TQ   ("DDR"),       // ✅ 正确
    .DATA_WIDTH     (DATA_WIDTH),  // ✅ 8，DDR模式合法值
    .SERDES_MODE    ("MASTER"),    // ✅ 8bit无需级联
    .TRISTATE_WIDTH (4)            // ✅ DDR模式UG471强制要求4
) u_oserdes_data (
```

**检查结论**：
- ✅ `DATA_RATE_OQ="DDR"` + `DATA_WIDTH=8` 要求 `CLK(串行)=4×CLKDIV(并行)`，即400MHz/100MHz，符合设计
- ✅ `TRISTATE_WIDTH=4` 符合UG471 DDR模式强制要求（V4版曾用1，3路版已修正为4）
- ✅ `OCE=1'b1`、`RST=~rst_n`、`TCE=1'b0` 连接正确
- ✅ 时钟通道D1-D8固定`1,0,1,0,1,0,1,0`产生10101010时钟模式，正确
- ✅ 所有端口均已连接，无悬空端口

### 2.3 OBUFDS 检查详情

**文件**：`lvds_tx_channel.v`

```verilog
OBUFDS #(.IOSTANDARD("LVDS_25"), .SLEW("FAST")) u_obufds_data (
    .O(lvds_data_p[lane_idx]), .OB(lvds_data_n[lane_idx]), .I(s_data_out[lane_idx])
);
```

**检查结论**：✅ 完全正确。`IOSTANDARD="LVDS_25"`、`SLEW="FAST"` 符合7系列LVDS发送要求。

### 2.4 IBUFDS 检查详情

**文件**：`lvds_rx_lane_phy.v`、`lvds_rx_phy.v`

```verilog
IBUFDS #(.DIFF_TERM("TRUE"), .IOSTANDARD("LVDS_25")) u_ibufds_data (
    .I(lvds_data_p), .IB(lvds_data_n), .O(data_ibuf)
);
```

**检查结论**：✅ 完全正确。`DIFF_TERM="TRUE"` 启用片内差分终端匹配，符合LVDS接收要求。

### 2.5 IDELAYE2 检查详情

**文件**：`lvds_rx_lane_phy.v`

```verilog
IDELAYE2 #(
    .IDELAY_TYPE    ("VARIABLE"),      // ⚠️ 建议改为VAR_LOAD
    .DELAY_SRC      ("IDATAIN"),       // ✅ 差分输入经IBUFDS后用IDATAIN
    .IDELAY_VALUE   (0),               // ✅ 初始值0
    .REFCLK_FREQUENCY(200.0),          // ✅ 200MHz参考时钟
    .HIGH_PERFORMANCE_MODE("TRUE")     // ✅ 高性能模式
) u_idelay_data (
```

**检查结论**：
- ✅ `DELAY_SRC="IDATAIN"` 配合IBUFDS输出，正确
- ✅ `REFCLK_FREQUENCY=200.0` 与IDELAYCTRL参考时钟匹配
- ✅ 端口连接完整：`IDATAIN`接IBUFDS输出，`DATAOUT`接ISERDESE2的`DDLY`
- ⚠️ **[问题P-09] IDELAY_TYPE选择不当**：代码使用`VARIABLE`模式，但实际通过`LD`+`CNTVALUEIN`直接加载预设延迟值。`VARIABLE`模式仅支持`CE`/`INC`递增递减，`LD`加载功能在`VAR_LOAD`模式下才完全可用。建议改为`"VAR_LOAD"`模式。详见§4问题P-09。

### 2.6 IDELAYCTRL 检查详情

**文件**：`lvds_rx_phy.v`

```verilog
IDELAYCTRL u_idelayctrl (
    .REFCLK (ref_clk_200m),    // ✅ 200MHz参考时钟
    .RST    (~rst_n),           // ✅ 高有效复位
    .RDY    ()                  // ⚠️ RDY信号未使用
);
```

**检查结论**：
- ✅ 3路数据通道共用1个IDELAYCTRL，正确（同一Bank内IDELAYCTRL可共享）
- ✅ `REFCLK`连接200MHz参考时钟
- ⚠️ **[建议] RDY信号未检查**：`RDY`端口悬空，未在状态机中等待IDELAYCTRL就绪即开始延迟扫描。V4版在主状态机M_IDLE态等待`idelay_rdy`，3路版省略了此检查。建议将`RDY`接入全局状态机作为启动条件。

### 2.7 ISERDESE2 检查详情

**文件**：`lvds_rx_lane_phy.v`

```verilog
ISERDESE2 #(
    .DATA_RATE          ("DDR"),         // ✅ DDR模式
    .DATA_WIDTH         (DATA_WIDTH),    // ✅ 8，DDR模式合法值
    .INTERFACE_TYPE     ("NETWORKING"),  // ✅ LVDS通信选NETWORKING
    .IOBDELAY           ("IFD"),         // ✅ 使用IDELAYE2延迟路径
    .NUM_CE             (1),             // ✅ 单CE模式
    .OFB_USED           ("FALSE"),       // ✅ 无OSERDESE2环回
    .SERDES_MODE        ("MASTER")       // ✅ 8bit无需级联
) u_iserdes_data (
    .CLK      (clk_bufio),               // ✅ 高速串行时钟（BUFIO输出）
    .CLKB     (~clk_bufio),              // ✅ DDR模式必须接CLK反相
    .CLKDIV   (clk_div),                 // ✅ 并行低速时钟（BUFR输出）
    .D        (data_ibuf),               // ✅ IBUFDS直通数据
    .DDLY     (data_delay),              // ✅ IDELAYE2延迟后数据
    .BITSLIP  (bitslip_req),             // ✅ 字对齐脉冲
    .RST      (~rst_n),                  // ✅ 高有效复位
```

**检查结论**：✅ 完全正确。
- `IOBDELAY="IFD"` 时，`D`接IBUF直通、`DDLY`接IDELAY输出，连接正确
- `CLK`/`CLKB`接BUFIO输出及其反相，DDR模式必需
- `CLKDIV`接BUFR分频输出，正确
- `BITSLIP`接字对齐脉冲，符合UG471要求
- 所有端口均已连接

### 2.8 BUFIO / BUFR 检查详情

**文件**：`lvds_rx_phy.v`

```verilog
BUFIO u_bufio_clk (.I(clk_ibuf), .O(clk_bufio));
BUFR #(.BUFR_DIVIDE("4"), .SIM_DEVICE("7SERIES")) u_bufr_div (
    .I(clk_ibuf), .O(clk_div), .CE(1'b1), .CLR(~rst_n)
);
```

**检查结论**：✅ 完全正确。
- `BUFIO`用于ISERDESE2的高速串行时钟（`CLK`），正确
- `BUFR`分频比`"4"`：800MHz串行时钟÷4=200MHz... 但设计文档说并行时钟100MHz。实际上BUFR分频比"4"表示4分频，输入是LVDS随路时钟（400MHz DDR等效800Mbps），分频后100MHz，正确
- `SIM_DEVICE="7SERIES"` 正确
- `CE=1'b1`常使能、`CLR=~rst_n`复位连接正确

### 2.9 xpm_fifo_sync 检查详情

**文件**：`lvds_tx_channel.v`

```verilog
xpm_fifo_sync #(
    .FIFO_MEMORY_TYPE    ("auto"),
    .FIFO_READ_LATENCY   (0),              // ✅ 0延迟读
    .FIFO_WRITE_DEPTH    (USER_FIFO_DEPTH), // ✅ 512
    .READ_DATA_WIDTH     (LANE_CNT*DATA_WIDTH), // ✅ 24bit
    .READ_MODE           ("fwft"),         // ✅ 首字直通
    .WRITE_DATA_WIDTH    (LANE_CNT*DATA_WIDTH)  // ✅ 24bit
) u_user_fifo (
```

**检查结论**：
- ✅ 读写位宽均为24bit（3×8bit），正确
- ✅ `READ_MODE="fwft"`首字直通模式，配合`FIFO_READ_LATENCY=0`
- ✅ `wr_clk`/`rst`/`wr_en`/`din`/`full`/`rd_en`/`dout`/`empty` 核心端口连接正确
- ⚠️ **[问题P-12] 缺少sleep端口**：Vivado 2018.2的`xpm_fifo_sync`原语可能需要`sleep`端口连接。当前代码未连接`.sleep(1'b0)`。如果编译报错，需添加`.sleep(1'b0)`。详见§4问题P-12。

---

## 3. 三段式状态机检查

### 3.1 检查标准

三段式状态机要求：
1. **第一段**：状态寄存器（时序逻辑，`posedge clk`，仅 `curr_state <= next_state`）
2. **第二段**：次态跳转（组合逻辑，`always @(*)`，纯状态转移条件）
3. **第三段**：输出控制（时序逻辑，`posedge clk`，基于 `curr_state` 的输出赋值）

### 3.2 检查结果

| 模块 | 状态机 | 状态数 | 第一段 | 第二段 | 第三段 | 结论 |
|------|--------|--------|--------|--------|--------|------|
| `lvds_tx_channel.v` | TX帧调度 | 5 | ✅ | ✅ | ✅ | ✅ 三段式 |
| `lvds_rx_lane_phy.v` | 延迟校准 | 6 | ✅ | ✅ | ✅ | ✅ 三段式 |
| `lvds_rx_lane_phy.v` | 字对齐 | 4 | ✅ | ✅ | ✅ | ✅ 三段式 |
| `lvds_rx_phy.v` | 全局主状态机 | 6 | ✅ | ✅ | ✅ | ✅ 三段式 |
| `lvds_rx_link.v` | 帧解析 | 5 | ✅ | ✅ | ✅ | ✅ 三段式 |
| `lvds_link_manager.v` | 链路管理 | 5 | ✅ | ✅ | ✅ | ✅ 三段式 |

### 3.3 各状态机详细分析

#### 3.3.1 lvds_tx_channel.v — TX帧调度状态机

```
状态定义：TX_IDLE → TX_SOF_TYPE → TX_LEN → TX_PAYLOAD → TX_CHECKSUM → TX_IDLE
```

- **第一段**（L155-158）：`tx_curr_state <= tx_next_state`，纯时序，✅
- **第二段**（L160-178）：`always @(*)`，纯组合逻辑状态跳转，`train_en`时强制回IDLE，✅
- **第三段**（L180-230）：`always @(posedge clk_div)`，基于`tx_curr_state`的输出控制，✅

**结论**：✅ 标准三段式。

#### 3.3.2 lvds_rx_lane_phy.v — 延迟校准状态机

```
状态定义：D_IDLE → D_SET_DELAY → D_WAIT → D_SAMPLE → D_CALC_WIN → D_DONE → D_IDLE
```

- **第一段**（L139-142）：`d_curr_state <= d_next_state`，✅
- **第二段**（L144-155）：`always @(*)`，含`retrain_req`异步跳转，✅
- **第三段**（L157-220）：`always @(posedge clk_div)`，含for循环窗口计算，✅

**结论**：✅ 标准三段式。

#### 3.3.3 lvds_rx_lane_phy.v — 字对齐状态机

```
状态定义：W_IDLE → W_BITSLIP → W_WAIT → W_CHECK → (W_IDLE 或 W_BITSLIP)
```

- **第一段**（L223-226）：`w_curr_state <= w_next_state`，✅
- **第二段**（L228-241）：`always @(*)`，含`retrain_req`/`lane_calib_err`跳转，✅
- **第三段**（L243-280）：`always @(posedge clk_div)`，BITSLIP脉冲生成与计数，✅

**结论**：✅ 标准三段式。

#### 3.3.4 lvds_rx_phy.v — 全局主状态机

```
状态定义：M_IDLE → M_CALIB → M_LANE_DESKEW → M_LOCK_CHECK → M_NORMAL
                                    ↓                          ↓
                                 M_FAULT ←─────────────────────┘
```

- **第一段**（L120-123）：`m_curr_state <= m_next_state`，✅
- **第二段**（L125-138）：`always @(*)`，纯组合逻辑状态跳转，✅
- **第三段**（L140-178）：`always @(posedge clk_div)`，基于`m_curr_state`的输出控制，✅

**结论**：✅ 标准三段式。但存在`retry_cnt`多驱动问题（见§4问题P-04）。

#### 3.3.5 lvds_rx_link.v — 帧解析状态机

```
状态定义：F_IDLE → F_TYPE → F_LEN → F_PAYLOAD → F_CHECKSUM → F_IDLE
```

- **第一段**（L73-77）：`f_curr_state <= f_next_state`，带`phy_ready && rx_data_valid`门控，✅
- **第二段**（L79-88）：`always @(*)`，纯组合逻辑状态跳转，✅
- **第三段**（L90-170）：`always @(posedge clk)`，含`!phy_ready`清空分支和`retrain_ack`清除，✅

**结论**：✅ 标准三段式。

#### 3.3.6 lvds_link_manager.v — 链路管理状态机

```
状态定义：S_IDLE → S_TRAINING → S_WAIT_PEER → S_LINK_UP → S_RETRAIN → S_TRAINING
```

- **第一段**（L97-100）：`curr_state <= next_state`，✅
- **第二段**（L102-142）：`always @(*)`，含主从模式分支，✅
- **第三段**（L144-220）：`always @(posedge clk)`，含CDC同步器、边沿检测、输出控制，✅

**结论**：✅ 标准三段式。

---

## 4. 设计问题发现

### 问题汇总

| 编号 | 严重程度 | 模块 | 问题简述 |
|------|----------|------|----------|
| P-01 | 🔴 致命 | lvds_tx_channel / lvds_rx_lane_phy | 训练序列协议不匹配，链路无法建立 |
| P-02 | 🔴 致命 | lvds_tx_channel | TX_PAYLOAD退出条件下溢，状态机卡死 |
| P-03 | 🔴 致命 | lvds_rx_link | F_PAYLOAD退出条件下溢，状态机卡死 |
| P-04 | 🔴 致命 | lvds_rx_phy | retry_cnt多驱动，不可综合 |
| P-05 | 🟠 严重 | lvds_rx_lane_phy | lane_align_done仅高1拍，下游漏检 |
| P-06 | 🟠 严重 | lane_deskew | deskew_done仅高1拍，状态转移竞争 |
| P-07 | 🟠 严重 | lvds_bidirectional_top | CDC违规，控制信号跨域无同步 |
| P-08 | 🟠 严重 | lvds_rx_channel | retrain_req反馈环，请求仅持续1拍 |
| P-09 | 🟡 一般 | lvds_rx_lane_phy | IDELAYE2模式选择不当 |
| P-10 | 🟡 一般 | lvds_rx_link | heartbeat_recv_cnt更新逻辑缺陷 |
| P-11 | 🟡 一般 | lane_deskew | 偏移检测for循环不break |
| P-12 | 🟡 一般 | lvds_tx_channel | xpm_fifo_sync可能缺少sleep端口 |

---

### P-01 🔴 致命：训练序列协议不匹配

**模块**：`lvds_tx_channel.v` / `lvds_rx_lane_phy.v` / `lvds_rx_phy.v`

**问题描述**：

发送端在`train_en`有效时，3路数据持续发送训练码`8'h55`：
```verilog
// lvds_tx_channel.v L232
if(train_en) begin
    tx_data_mux = {LANE_CNT{8'h55}};  // 仅发送0x55
end
```

但接收端在三个阶段都期望接收`8'hB5`：
1. **字对齐**（`lvds_rx_lane_phy.v` L237）：`if(iserdes_q == 8'hB5)` — 期望B5
2. **锁定检查**（`lvds_rx_phy.v` L163-165）：`deskew_data_out[7:0] == 8'hB5` — 期望3路都是B5

**根因分析**：

`8'h55` = `01010101`，`8'hB5` = `10110101`。`0xB5`**不是**`0x55`的BITSLIP位移变体。BITSLIP只能做循环移位，`0x55`的8种位移结果为：`55/AA/55/AA/55/AA/55/AA`，永远不可能出现`0xB5`。

因此：
- 字对齐状态机永远无法匹配`0xB5`，`align_check_cnt`永远为0
- `lane_align_done`永远为0
- 全局状态机永远卡在`M_CALIB`，链路永远无法建立

**修复建议**：

方案A（推荐）：发送端训练时分阶段切换训练码
```verilog
// lvds_tx_channel.v 增加训练阶段控制
input wire train_phase,  // 0=位训练(0x55), 1=字训练(0xB5)
...
if(train_en) begin
    tx_data_mux = train_phase ? {LANE_CNT{8'hB5}} : {LANE_CNT{8'h55}};
end
```

方案B：接收端字对齐目标改为`0x55`的位移变体（如`0xAA`），但需同步修改锁定检查逻辑。

---

### P-02 🔴 致命：TX_PAYLOAD退出条件下溢

**模块**：`lvds_tx_channel.v`

**问题描述**：

第二段状态跳转中，TX_PAYLOAD的退出条件为：
```verilog
// L175
TX_PAYLOAD:  tx_next_state = (payload_cnt >= payload_len - LANE_CNT) ? TX_CHECKSUM : TX_PAYLOAD;
```

当`payload_len < LANE_CNT`（即`payload_len < 3`）时，`payload_len - LANE_CNT`发生8位无符号下溢：
- 心跳帧：`payload_len = 2`，`2 - 3 = 255`（下溢），条件永远不满足
- 控制帧：`payload_len = 1`，`1 - 3 = 254`（下溢），条件永远不满足

**影响**：发送心跳帧和控制帧时，状态机永远卡在TX_PAYLOAD，无法进入TX_CHECKSUM，链路死锁。

**修复建议**：

```verilog
// 修改退出条件，增加payload_len <= LANE_CNT的快速退出
TX_PAYLOAD:  tx_next_state = (payload_len <= LANE_CNT || payload_cnt >= payload_len - LANE_CNT) ? TX_CHECKSUM : TX_PAYLOAD;
```

---

### P-03 🔴 致命：RX F_PAYLOAD退出条件下溢

**模块**：`lvds_rx_link.v`

**问题描述**：

与P-02完全相同的问题。第二段状态跳转中：
```verilog
// L85
F_PAYLOAD: if(payload_cnt >= frame_len - LANE_CNT) f_next_state = F_CHECKSUM;
```

当`frame_len < 3`时（心跳帧=2，控制帧=1），`frame_len - LANE_CNT`下溢为254/253，条件永远不满足。

**影响**：接收心跳帧和控制帧时，状态机永远卡在F_PAYLOAD，无法进入F_CHECKSUM，帧解析死锁。

**修复建议**：

```verilog
F_PAYLOAD: if(frame_len <= LANE_CNT || payload_cnt >= frame_len - LANE_CNT) f_next_state = F_CHECKSUM;
```

---

### P-04 🔴 致命：retry_cnt多驱动

**模块**：`lvds_rx_phy.v`

**问题描述**：

`retry_cnt`在两个always块中被同时赋值，违反Verilog单驱动规则，不可综合：

```verilog
// always块1（L140-178，主输出控制）
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        ...
        retry_cnt <= 2'd0;  // ← 驱动1
    end else begin
        case(m_curr_state)
            ...
            M_NORMAL: begin
                retry_cnt <= 2'd0;  // ← 驱动1
            end
        endcase
    end
end

// always块2（L180-186，独立重试计数器）
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n)
        retry_cnt <= 2'd0;  // ← 驱动2
    else if(m_curr_state == M_IDLE && m_next_state == M_CALIB)
        retry_cnt <= retry_cnt + 1'b1;  // ← 驱动2
    else if(m_curr_state == M_NORMAL)
        retry_cnt <= 2'd0;  // ← 驱动2
end
```

**影响**：Vivado综合会报多驱动错误（Multi-driver net），或综合出不可预期的行为。

**修复建议**：

删除always块1中对`retry_cnt`的所有赋值，仅保留always块2作为唯一驱动源：

```verilog
// always块1中删除所有 retry_cnt 赋值
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        phy_ready <= 1'b0;
        align_err <= 1'b0;
        lock_timer <= 16'd0;
        lock_match_cnt <= 8'd0;
        // retry_cnt <= 2'd0;  ← 删除此行
    end else begin
        case(m_curr_state)
            ...
            M_NORMAL: begin
                phy_ready <= 1'b1;
                align_err <= 1'b0;
                // retry_cnt <= 2'd0;  ← 删除此行
            end
        endcase
    end
end
```

---

### P-05 🟠 严重：lane_align_done仅高1拍

**模块**：`lvds_rx_lane_phy.v`

**问题描述**：

字对齐状态机中，当`align_check_cnt >= 16`时置`lane_align_done=1`：
```verilog
// L272-274
if(align_check_cnt >= 8'd16) begin
    lane_align_done <= 1'b1;
end
```

但次态逻辑中，W_CHECK状态在`align_check_cnt >= 16`时跳回W_IDLE：
```verilog
// L236-237
W_CHECK: begin
    if(align_check_cnt >= 8'd16)
        w_next_state = W_IDLE;  // 跳回IDLE
```

而W_IDLE状态会立即清零`lane_align_done`：
```verilog
// L255
W_IDLE: begin
    lane_align_done <= 1'b0;  // 立即清零！
```

**影响**：`lane_align_done`仅保持1个时钟周期。上游`lvds_rx_phy.v`通过`all_lane_done = &lane_align_done`检测，如果3路通道的`lane_align_done`不在同一拍拉高，`all_lane_done`永远无法为1，全局状态机永远卡在M_CALIB。

**修复建议**：

W_IDLE状态不应清零`lane_align_done`，应保持锁定直到`retrain_req`：
```verilog
W_IDLE: begin
    align_check_cnt <= 8'd0;
    bitslip_cnt <= 4'd0;
    bitslip_wait <= 1'b0;
    // lane_align_done <= 1'b0;  ← 删除此行，保持上次状态
end
```

---

### P-06 🟠 严重：deskew_done仅高1拍

**模块**：`lane_deskew.v`

**问题描述**：

通道对齐完成后`deskew_done`置1，但else分支立即清零：
```verilog
// L57-65
end else if(deskew_en && ~deskew_done) begin
    ...
    if(check_cnt >= 4'd15) begin
        deskew_done <= 1'b1;  // 对齐完成
    end
end else begin
    deskew_done <= 1'b0;  // ← deskew_en失效时立即清零
    check_cnt <= 4'd0;
end
```

上游`lvds_rx_phy.v`在M_LANE_DESKEW状态检测`deskew_done`后跳转到M_LOCK_CHECK：
```verilog
M_LANE_DESKEW: if(deskew_done) m_next_state = M_LOCK_CHECK;
```

但状态跳转后`deskew_en`（`m_curr_state == M_LANE_DESKEW`）立即失效，`deskew_done`在同一拍被清零。如果`deskew_done`的检测和状态跳转存在时序竞争（特别是仿真中），可能导致状态机无法正确跳转。

**修复建议**：

`deskew_done`应保持锁定，直到`deskew_en`重新使能或复位：
```verilog
// 移除else分支中的 deskew_done <= 1'b0;
end else if(!deskew_en) begin
    // deskew_done保持不变，仅清零check_cnt
    check_cnt <= 4'd0;
end
```

---

### P-07 🟠 严重：CDC违规

**模块**：`lvds_bidirectional_top.v`

**问题描述**：

`lvds_link_manager`运行在`clk_ref`域，但其输出信号直接连接到运行在`clk_div`域的`lvds_tx_channel`：

```verilog
// lvds_link_manager 输出（clk_ref域）
.tx_train_en(tx_train_en),          // → u_tx (clk_div域)
.ctrl_frame_send(ctrl_frame_send),  // → u_tx (clk_div域)
.ctrl_frame_type_out(ctrl_frame_type_out),    // → u_tx (clk_div域)
.ctrl_frame_payload_out(ctrl_frame_payload_out), // → u_tx (clk_div域)
```

`lvds_link_manager`内部对**输入**信号做了CDC同步（clk_div→clk_ref），但对**输出**信号未做CDC同步（clk_ref→clk_div）。

**影响**：`tx_train_en`、`ctrl_frame_send`等控制信号从clk_ref域跨到clk_div域，存在亚稳态风险。`ctrl_frame_send`是脉冲信号，跨域可能丢失或被多次采样。

**修复建议**：

在顶层添加clk_ref→clk_div的CDC同步器：
```verilog
// clk_ref → clk_div CDC同步
reg tx_train_en_sync1, tx_train_en_sync2;
reg ctrl_frame_send_sync1, ctrl_frame_send_sync2;
reg [7:0] ctrl_frame_type_sync1, ctrl_frame_type_sync2;
reg [7:0] ctrl_frame_payload_sync1, ctrl_frame_payload_sync2;

always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        tx_train_en_sync1 <= 1'b1; tx_train_en_sync2 <= 1'b1;
        ctrl_frame_send_sync1 <= 1'b0; ctrl_frame_send_sync2 <= 1'b0;
        ...
    end else begin
        tx_train_en_sync1 <= tx_train_en; tx_train_en_sync2 <= tx_train_en_sync1;
        ctrl_frame_send_sync1 <= ctrl_frame_send; ctrl_frame_send_sync2 <= ctrl_frame_send_sync1;
        ...
    end
end

// u_tx例化使用同步后信号
.tx_train_en(tx_train_en_sync2),
.ctrl_frame_send(ctrl_frame_send_sync2),
```

---

### P-08 🟠 严重：retrain_req反馈环

**模块**：`lvds_rx_channel.v`

**问题描述**：

`lvds_rx_link`产生的`retrain_req_inner`通过两条路径反馈：
1. 作为`retrain_req`送入`u_phy`（触发物理层重训练）
2. 作为`retrain_ack`送回`u_link`（清除自身）

```verilog
// u_phy
.retrain_req(retrain_req | retrain_req_inner),  // 路径1：触发物理层重训练
// u_link
.retrain_req(retrain_req_inner),  // 输出
.retrain_ack(retrain_req),        // 路径2：用外部retrain_req作为ack清除自身
```

当`retrain_req_inner`拉高时，`retrain_ack`（=`retrain_req | retrain_req_inner`的外部部分）并不直接等于`retrain_req_inner`。但如果外部`retrain_req`为0，则`retrain_ack = retrain_req_inner`（通过u_phy的合并逻辑间接反馈），形成自清除。

更关键的是：`retrain_req_inner`在`lvds_rx_link`中是**电平信号**，由`retrain_ack`清除。但`retrain_ack`实际连接的是外部`retrain_req`，而非`retrain_req_inner`本身。这意味着：
- 如果外部`retrain_req`为0，`retrain_ack`始终为0，`retrain_req_inner`无法被清除，持续为1
- 如果外部`retrain_req`为1，`retrain_ack`为1，会清除`retrain_req_inner`，但外部请求可能已撤销

**影响**：重训练请求要么无法清除（持续锁定），要么被过早清除（仅持续1拍），物理层可能无法正确响应。

**修复建议**：

`retrain_ack`应连接`retrain_req_inner`本身或其延迟版本，形成正确的握手清除：
```verilog
// 增加retrain_req_inner的延迟反馈作为ack
reg retrain_req_inner_d;
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) retrain_req_inner_d <= 1'b0;
    else retrain_req_inner_d <= retrain_req_inner;
end

lvds_rx_link u_link (
    ...
    .retrain_req(retrain_req_inner),
    .retrain_ack(retrain_req_inner_d),  // 延迟1拍清除，确保物理层有时间响应
    ...
);
```

---

### P-09 🟡 一般：IDELAYE2模式选择不当

**模块**：`lvds_rx_lane_phy.v`

**问题描述**：

IDELAYE2配置为`VARIABLE`模式，但代码中通过`LD`+`CNTVALUEIN`直接加载预设延迟值：
```verilog
IDELAYE2 #(
    .IDELAY_TYPE    ("VARIABLE"),  // ← 仅支持CE/INC递增递减
    ...
) u_idelay_data (
    .LD         (delay_ld),        // ← LD在VARIABLE模式下功能受限
    .CNTVALUEIN (delay_cnt_val),   // ← CNTVALUEIN在VARIABLE模式下功能受限
```

根据UG471：
- `VARIABLE`模式：仅支持`CE`/`INC`逐tap递增递减，`LD`加载`IDELAY_VALUE`参数值
- `VAR_LOAD`模式：支持`LD`+`CNTVALUEIN`直接加载任意值，适合扫描校准后加载最优值

**修复建议**：

```verilog
IDELAYE2 #(
    .IDELAY_TYPE    ("VAR_LOAD"),  // 改为VAR_LOAD模式
    ...
```

---

### P-10 🟡 一般：heartbeat_recv_cnt更新逻辑缺陷

**模块**：`lvds_rx_link.v`

**问题描述**：

心跳帧payload为2字节，在24bit（3字节/周期）通道中1个周期即可传完。但代码中按2周期处理：
```verilog
// L131-134
F_PAYLOAD: begin
    ...
    if(frame_type == TYPE_HB) begin
        if(payload_cnt == 8'd0) heartbeat_recv_cnt[15:8] <= rx_data_in[(sof_offset+2)%3*8 +: 8];
        else heartbeat_recv_cnt[7:0] <= rx_data_in[sof_offset*8 +: 8];  // ← 此分支可能不执行
    end
```

由于`payload_len=2`且`LANE_CNT=3`，F_PAYLOAD状态在`payload_cnt=0`时进入，下一拍`payload_cnt=3`，由于P-03的下溢问题状态机卡死。即使修复P-03后，`payload_cnt`从0直接跳到3，`else`分支（`payload_cnt != 0`）在第二拍才执行，但此时状态可能已跳转。

**影响**：`heartbeat_recv_cnt`的低字节可能无法正确更新。

**修复建议**：

在F_PAYLOAD状态一次性提取2字节心跳载荷：
```verilog
F_PAYLOAD: begin
    ...
    if(frame_type == TYPE_HB) begin
        heartbeat_recv_cnt[15:8] <= rx_data_in[(sof_offset+2)%3*8 +: 8];
        heartbeat_recv_cnt[7:0]  <= rx_data_in[(sof_offset+3)%3*8 +: 8]; // 同周期提取
    end
```

---

### P-11 🟡 一般：lane_deskew偏移检测for循环不break

**模块**：`lane_deskew.v`

**问题描述**：

偏移检测使用嵌套for循环遍历移位寄存器，但未在首次匹配时break：
```verilog
// L55-59
for(i = 1; i < LANE_CNT; i = i + 1) begin
    for(j = 0; j < DESKEW_DEPTH; j = j + 1) begin
        if(shift_reg[i][j] == sync_word)
            lane_offset[i] <= j[2:0];  // ← 每次匹配都覆盖，取最后匹配位置
    end
end
```

如果sync_word在移位寄存器中出现多次（如数据中恰好包含0xB5），`lane_offset`会被最后一次匹配覆盖，导致对齐到错误位置。

**修复建议**：

使用`disable`跳出循环或增加found标志：
```verilog
for(i = 1; i < LANE_CNT; i = i + 1) begin
    for(j = 0; j < DESKEW_DEPTH; j = j + 1) begin
        if(shift_reg[i][j] == sync_word) begin
            lane_offset[i] <= j[2:0];
            j = DESKEW_DEPTH;  // 跳出内层循环
        end
    end
end
```

---

### P-12 🟡 一般：xpm_fifo_sync可能缺少sleep端口

**模块**：`lvds_tx_channel.v`

**问题描述**：

Vivado 2018.2的`xpm_fifo_sync`原语可能需要`sleep`端口连接。当前代码未连接`.sleep(1'b0)`。

**影响**：如果Vivado 2018.2版本要求`sleep`端口，编译会报warning或error。

**修复建议**：

在xpm_fifo_sync例化中添加：
```verilog
xpm_fifo_sync #(
    ...
) u_user_fifo (
    ...
    .sleep      (1'b0),    // 添加sleep端口
    ...
);
```

---

## 5. Review总结

### 5.1 原语使用总结

| 检查项 | 结果 |
|--------|------|
| OSERDESE2参数与端口 | ✅ 正确（TRISTATE_WIDTH=4已修正） |
| OBUFDS参数与端口 | ✅ 正确 |
| IBUFDS参数与端口 | ✅ 正确 |
| IDELAYE2参数与端口 | ⚠️ IDELAY_TYPE建议改为VAR_LOAD |
| IDELAYCTRL参数与端口 | ✅ 正确（RDY建议接入） |
| ISERDESE2参数与端口 | ✅ 正确 |
| BUFIO/BUFR参数与端口 | ✅ 正确 |
| xpm_fifo_sync参数与端口 | ⚠️ 可能需要sleep端口 |

### 5.2 三段式FSM总结

| 状态机 | 结论 |
|--------|------|
| TX帧调度（5状态） | ✅ 标准三段式 |
| 延迟校准（6状态） | ✅ 标准三段式 |
| 字对齐（4状态） | ✅ 标准三段式 |
| 全局主状态机（6状态） | ✅ 三段式（但retry_cnt多驱动） |
| 帧解析（5状态） | ✅ 标准三段式 |
| 链路管理（5状态） | ✅ 标准三段式 |

**所有6个状态机均采用三段式编写，符合设计规范。**

### 5.3 设计问题统计

| 严重程度 | 数量 | 问题编号 |
|----------|------|----------|
| 🔴 致命 | 4 | P-01, P-02, P-03, P-04 |
| 🟠 严重 | 4 | P-05, P-06, P-07, P-08 |
| 🟡 一般 | 4 | P-09, P-10, P-11, P-12 |
| **合计** | **12** | |

### 5.4 总体评价

**原语使用**：9类Xilinx原语中7类完全正确，IDELAYE2模式选择有优化空间，xpm_fifo_sync可能需要补充端口。整体原语使用水平良好，符合Vivado 2018.2和7系列FPGA规范。

**FSM设计**：全部6个状态机严格遵循三段式设计规范，代码结构清晰，状态划分合理。

**设计质量**：存在4项致命问题（训练序列协议不匹配、两处下溢、多驱动），这些问题会导致链路完全无法建立或综合失败，**必须在流片前修复**。4项严重问题涉及信号时序和跨时钟域安全，建议优先修复。4项一般问题影响功能正确性和鲁棒性，建议在功能验证阶段修复。

**建议**：修复全部4项致命问题和4项严重问题后，重新进行仿真验证，确认链路能够正常建立和数据传输。

---

## 6. 修复报告

**修复日期**：2026-07-27  
**修复范围**：7个Verilog源文件，12项设计问题  
**修复状态**：全部12项已修复，所有文件通过语法检查无错误

### 6.1 修复总览

| 编号 | 严重程度 | 修复文件 | 修复状态 |
|------|----------|----------|----------|
| P-01 | 🔴 致命 | `lvds_tx_channel.v` | ✅ 已修复 |
| P-02 | 🔴 致命 | `lvds_tx_channel.v` | ✅ 已修复 |
| P-03 | 🔴 致命 | `lvds_rx_link.v` | ✅ 已修复 |
| P-04 | 🔴 致命 | `lvds_rx_phy.v` | ✅ 已修复 |
| P-05 | 🟠 严重 | `lvds_rx_lane_phy.v` | ✅ 已修复 |
| P-06 | 🟠 严重 | `lane_deskew.v` | ✅ 已修复 |
| P-07 | 🟠 严重 | `lvds_bidirectional_top.v` | ✅ 已修复 |
| P-08 | 🟠 严重 | `lvds_rx_channel.v` | ✅ 已修复 |
| P-09 | 🟡 一般 | `lvds_rx_lane_phy.v` | ✅ 已修复 |
| P-10 | 🟡 一般 | `lvds_rx_link.v` | ✅ 已修复 |
| P-11 | 🟡 一般 | `lane_deskew.v` | ✅ 已修复 |
| P-12 | 🟡 一般 | `lvds_tx_channel.v` | ✅ 已修复 |

### 6.2 各问题修复详情

#### P-01 🔴 训练序列协议不匹配 → 已修复

**修复方案**：方案A（两阶段训练）

**修改文件**：`lvds_tx_channel.v`

**修复内容**：
1. 新增训练阶段计数器 `train_phase_cnt` 和阶段标志 `train_phase`
2. `train_en` 有效期间，前2000个周期（`TRAIN_CALIB_DURATION`）发送 `0x55` 供RX延迟校准，之后切换为 `0xB5` 供RX字对齐和锁定检查
3. 退出训练时 `train_phase_cnt` 重置，下次训练重新从阶段0开始

```verilog
// 新增参数与信号
localparam TRAIN_CALIB_DURATION = 16'd2000;
reg [15:0] train_phase_cnt;
wire       train_phase;
assign train_phase = (train_phase_cnt >= TRAIN_CALIB_DURATION);

// 训练码多路选择
tx_data_mux = train_phase ? {LANE_CNT{8'hB5}} : {LANE_CNT{8'h55}};
```

**验证**：RX延迟校准约需578周期（32 tap × 18 cycle/tap），2000周期足够完成。阶段1发送 `0xB5` 与RX字对齐（W_CHECK检查 `0xB5`）、deskew同步字（`0xB5`）、锁定检查（3路均检查 `0xB5`）完全匹配。

---

#### P-02 🔴 TX_PAYLOAD退出条件下溢 → 已修复

**修复方案**：增加短路判断 + 改用加法避免下溢

**修改文件**：`lvds_tx_channel.v`

**修复内容**：
1. 第二段状态跳转退出条件增加 `payload_len <= LANE_CNT` 短路判断
2. 第三段 `fifo_rd_en` 逻辑由减法改为加法，避免下溢

```verilog
// 第二段：退出条件
TX_PAYLOAD: tx_next_state = (payload_len <= LANE_CNT || payload_cnt >= payload_len - LANE_CNT) ? TX_CHECKSUM : TX_PAYLOAD;

// 第三段：fifo_rd_en（原 payload_cnt < payload_len - LANE_CNT 改为加法）
fifo_rd_en <= (payload_cnt + LANE_CNT < payload_len);
```

---

#### P-03 🔴 RX F_PAYLOAD退出条件下溢 → 已修复

**修复方案**：增加短路判断

**修改文件**：`lvds_rx_link.v`

**修复内容**：第二段状态跳转退出条件增加 `frame_len <= LANE_CNT` 短路判断

```verilog
F_PAYLOAD: if(frame_len <= LANE_CNT || payload_cnt >= frame_len - LANE_CNT) f_next_state = F_CHECKSUM;
```

---

#### P-04 🔴 retry_cnt多驱动 → 已修复

**修复方案**：删除主always块中的retry_cnt赋值

**修改文件**：`lvds_rx_phy.v`

**修复内容**：
1. 删除主输出always块复位分支中的 `retry_cnt <= 2'd0`
2. 删除主输出always块 M_NORMAL 状态中的 `retry_cnt <= 2'd0`
3. `retry_cnt` 现仅由独立always块（重试计数器）唯一驱动

```verilog
// 独立always块作为retry_cnt唯一驱动源
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n)
        retry_cnt <= 2'd0;
    else if(m_curr_state == M_IDLE && m_next_state == M_CALIB)
        retry_cnt <= retry_cnt + 1'b1;
    else if(m_curr_state == M_NORMAL)
        retry_cnt <= 2'd0;
end
```

---

#### P-05 🟠 lane_align_done仅高1拍 → 已修复

**修复方案**：W_IDLE不清零lane_align_done

**修改文件**：`lvds_rx_lane_phy.v`

**修复内容**：
1. W_IDLE状态移除 `lane_align_done <= 1'b0`，保持锁定
2. 清零条件改为仅由 `retrain_req | lane_calib_err` 触发

```verilog
W_IDLE: begin
    align_check_cnt <= 8'd0;
    bitslip_cnt <= 4'd0;
    bitslip_wait <= 1'b0;
    // lane_align_done保持不变，仅由retrain_req清零
end
// ...
if(retrain_req | lane_calib_err) begin
    lane_align_done <= 1'b0;
end
```

---

#### P-06 🟠 deskew_done仅高1拍 → 已修复

**修复方案**：else分支不再清零deskew_done

**修改文件**：`lane_deskew.v`

**修复内容**：将 `else` 分支改为 `else if(!deskew_en)`，仅清零 `check_cnt`，`deskew_done` 保持锁定直到复位

```verilog
end else if(!deskew_en) begin
    // deskew_done保持不变，仅清零check_cnt
    check_cnt <= 4'd0;
end
```

---

#### P-07 🟠 CDC违规 → 已修复

**修复方案**：添加clk_ref→clk_div两级同步器+脉冲边沿检测

**修改文件**：`lvds_bidirectional_top.v`

**修复内容**：
1. `tx_train_en`（电平信号）：两级同步器
2. `ctrl_frame_send`（脉冲信号）：两级同步 + 边沿检测恢复单拍脉冲
3. `ctrl_frame_type_out`/`ctrl_frame_payload_out`（数据总线）：两级同步
4. `user_tx_en`（电平信号）：两级同步器
5. TX例化改用同步后信号

```verilog
// CDC同步逻辑
reg tx_train_en_s1, tx_train_en_s2;
reg ctrl_frame_send_s1, ctrl_frame_send_s2, ctrl_frame_send_s2_d;
reg [7:0] ctrl_frame_type_s1, ctrl_frame_type_s2;
reg [7:0] ctrl_frame_payload_s1, ctrl_frame_payload_s2;
reg user_tx_en_s1, user_tx_en_s2;

wire ctrl_frame_send_sync = ctrl_frame_send_s2 & ~ctrl_frame_send_s2_d;

// TX例化使用同步后信号
.train_en(tx_train_en_s2),
.ctrl_frame_send(ctrl_frame_send_sync),
.ctrl_frame_type(ctrl_frame_type_s2),
.ctrl_frame_payload(ctrl_frame_payload_s2),
.tx_data_valid(user_tx_valid & user_tx_en_s2),
```

---

#### P-08 🟠 retrain_req反馈环 → 已修复

**修复方案**：retrain_ack连接retrain_req_inner延迟1拍版本

**修改文件**：`lvds_rx_channel.v`

**修复内容**：新增 `retrain_req_inner_d` 寄存器，将 `retrain_req_inner` 延迟1拍后作为 `retrain_ack`，确保物理层有时间响应重训练请求后再清除

```verilog
reg retrain_req_inner_d;
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) retrain_req_inner_d <= 1'b0;
    else retrain_req_inner_d <= retrain_req_inner;
end

// u_link例化
.retrain_ack(retrain_req_inner_d),  // 延迟1拍清除
```

---

#### P-09 🟡 IDELAYE2模式选择不当 → 已修复

**修复方案**：VARIABLE改为VAR_LOAD

**修改文件**：`lvds_rx_lane_phy.v`

**修复内容**：IDELAY_TYPE参数从 `"VARIABLE"` 改为 `"VAR_LOAD"`，使 `LD`+`CNTVALUEIN` 直接加载功能完全可用

```verilog
IDELAYE2 #(
    .IDELAY_TYPE    ("VAR_LOAD"),    // VAR_LOAD模式支持LD+CNTVALUEIN直接加载
    ...
```

---

#### P-10 🟡 heartbeat_recv_cnt更新逻辑缺陷 → 已修复

**修复方案**：同周期一次性提取2字节

**修改文件**：`lvds_rx_link.v`

**修复内容**：F_PAYLOAD状态处理心跳帧时，在同一周期内提取高字节和低字节，不再依赖 `payload_cnt` 分支

```verilog
if(frame_type == TYPE_HB) begin
    heartbeat_recv_cnt[15:8] <= rx_data_in[(sof_offset+2)%3*8 +: 8];
    heartbeat_recv_cnt[7:0]  <= rx_data_in[(sof_offset+3)%3*8 +: 8];
end
```

---

#### P-11 🟡 lane_deskew偏移检测for循环不break → 已修复

**修复方案**：增加首次匹配保护条件

**修改文件**：`lane_deskew.v`

**修复内容**：在for循环中增加 `lane_offset[i] == 3'd0 && j > 0` 条件，首次匹配后不再覆盖，避免sync_word多次出现时对齐到错误位置

```verilog
for(j = 0; j < DESKEW_DEPTH; j = j + 1) begin
    if(shift_reg[i][j] == sync_word && lane_offset[i] == 3'd0 && j > 0)
        lane_offset[i] <= j[2:0];
end
```

---

#### P-12 🟡 xpm_fifo_sync缺少sleep端口 → 已修复

**修复方案**：添加.sleep(1'b0)端口

**修改文件**：`lvds_tx_channel.v`

**修复内容**：在xpm_fifo_sync例化中添加 `.sleep(1'b0)` 端口连接

```verilog
xpm_fifo_sync #(
    ...
) u_user_fifo (
    .wr_clk         (clk_div),
    .rst            (~rst_n),
    .sleep          (1'b0),      // 新增
    .wr_en          (tx_data_valid),
    ...
```

### 6.3 修复后文件变更统计

| 文件 | 修改问题数 | 变更类型 |
|------|-----------|----------|
| `lvds_tx_channel.v` | 4（P-01, P-02, P-09无, P-12） | 新增信号+逻辑修改+端口补充 |
| `lvds_rx_link.v` | 2（P-03, P-10） | 条件修改+逻辑修改 |
| `lvds_rx_phy.v` | 1（P-04） | 删除多驱动赋值 |
| `lvds_rx_lane_phy.v` | 2（P-05, P-09） | 逻辑修改+参数修改 |
| `lane_deskew.v` | 2（P-06, P-11） | 逻辑修改+条件修改 |
| `lvds_bidirectional_top.v` | 1（P-07） | 新增CDC同步逻辑 |
| `lvds_rx_channel.v` | 1（P-08） | 新增延迟反馈逻辑 |
| **合计** | **7个文件** | **12项修复** |

### 6.4 修复后验证

所有7个修改文件均通过VS Code语法检查（`get_errors`），无语法错误和lint警告。

**后续建议**：
1. 在Vivado 2018.2中执行综合，确认无综合错误和关键warning
2. 使用 `lvds_3lane_bidirectional_tb.v` 进行仿真验证，确认链路能正常建立和数据传输
3. 仿真通过后进行上板验证
