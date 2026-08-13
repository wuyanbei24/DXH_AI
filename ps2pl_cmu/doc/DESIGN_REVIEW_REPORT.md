# ps2pl_cmu 设计 Review 报告

**项目**：Zynq-7020 PS-PL AXI4-Lite BRAM 双向通信模块  
**Review日期**：2026-07-28  
**Review范围**：`ps2pl_cmu/` 目录下6个Verilog源文件（5个RTL + 1个TB）  
**审查方法**：逐文件逐行审查 + 跨模块数据流/时序追踪

---

## 1. 设计概览

### 1.1 系统架构

```
PS (ARM, AXI4-Lite Master, 100MHz)
    │
    ▼
┌─────────────────────────────────────────────────┐
│  pl_bram_comm_top                                │
│  ┌──────────────┐  ┌──────────────┐             │
│  │axi_lite_slave│──│ctrl_reg_bank │──CDC──┐     │
│  │(协议解析+    │  │(寄存器+CDC)  │       │     │
│  │ 地址译码)    │  └──────────────┘       │     │
│  └──┬────┬──────┘                         │     │
│     │    │        ┌──────────┐    ┌───────▼──┐  │
│     │    ├──A口──│TX BRAM IP│B口──│tx_data   │──▶ PL TX
│     │    │        │32b×128   │16b  │ _path    │  │
│     │    │        └──────────┘    └──────────┘  │
│     │    │        ┌──────────┐    ┌──────────┐  │
│     │    └──A口──│RX BRAM IP│B口──│rx_data   │◀── PL RX
│     │             │32b×128   │16b  │ _path    │  │
│     │             └──────────┘    └──────────┘  │
└─────────────────────────────────────────────────┘
```

### 1.2 文件清单

| 文件 | 模块 | 职责 | 行数 |
|------|------|------|------|
| `axi_lite_slave.v` | `axi_lite_slave` | AXI4-Lite从机协议+地址译码 | ~200 |
| `ctrl_reg_bank.v` | `ctrl_reg_bank` | 控制/状态寄存器 + 6路CDC同步 | ~230 |
| `tx_data_path.v` | `tx_data_path` | TX数据通路（BRAM→PL, 三段式FSM） | ~120 |
| `rx_data_path.v` | `rx_data_path` | RX数据通路（PL→BRAM, 三段式FSM） | ~115 |
| `pl_bram_comm_top.v` | `pl_bram_comm_top` | 顶层集成 | ~200 |
| `tb_bram_comm.v` | testbench | 仿真验证 | ~200 |

---

## 2. 问题发现

### 问题汇总

| 编号 | 严重程度 | 模块 | 问题简述 |
|------|----------|------|----------|
| P-01 | 🔴 致命 | axi_lite_slave / top | `reg_wr_strb`端口缺失，编译报错 |
| P-02 | 🔴 致命 | axi_lite_slave | `reg_addr`/`tx_bram_addr`多驱动 |
| P-03 | 🔴 致命 | rx_data_path | 首拍数据丢失 |
| P-04 | 🔴 致命 | ctrl_reg_bank | RX_LEN握手条件引用错误信号 |
| P-05 | 🔴 致命 | ctrl_reg_bank | `rx_len_hold_ps`多驱动 |
| P-06 | 🟠 严重 | ctrl_reg_bank | TX_START toggle同步方向错误 |
| P-07 | 🟠 严重 | ctrl_reg_bank | RX_LEN握手ack非真正CDC |
| P-08 | 🟠 严重 | rx_data_path | `rx_len`计算在data_cnt=255时溢出 |
| P-09 | 🟠 严重 | axi_lite_slave | 读通道`rd_hit_*`使用旧地址判断 |
| P-10 | 🟡 一般 | tx_data_path | 注释声称独热编码实际为二进制 |
| P-11 | 🟡 一般 | tx_data_path | `tx_len_latch-1`潜在下溢 |
| P-12 | 🟡 一般 | axi_lite_slave | 越界读返回OKAY而非DECERR |
| P-13 | 🟡 一般 | ctrl_reg_bank | `tx_start_ps`写1置位后无自动回清机制 |
| P-14 | 🟡 一般 | tx_data_path | `pl_tx_req`仅在启动时检查 |

---

### P-01 🔴 致命：`reg_wr_strb`端口缺失导致编译错误

**文件**：`axi_lite_slave.v` / `pl_bram_comm_top.v`

**问题**：`axi_lite_slave`模块端口列表中**没有**`reg_wr_strb`输出端口，但顶层`pl_bram_comm_top`例化时连接了：

```verilog
// pl_bram_comm_top.v L94
.reg_wr_strb    (reg_wr_strb),   // ← axi_lite_slave 无此端口！
```

而 `ctrl_reg_bank` 的输入端口 `reg_wr_strb` 依赖此信号进行按字节写选通。

**影响**：Vivado综合**必定报错**，设计无法编译。

**修复建议**：在 `axi_lite_slave` 模块端口中增加：
```verilog
output reg [3:0] reg_wr_strb,
```
并在写通道执行逻辑中将 `w_strb_latch` 透传到 `reg_wr_strb`。

---

### P-02 🔴 致命：`reg_addr`和`tx_bram_addr`被两个always块多驱动

**文件**：`axi_lite_slave.v`

**问题**：`reg_addr`在**写通道**always块（L87）和**读通道**always块（L149）中都有赋值：

```verilog
// 写通道 always块
if(hit_reg) begin
    reg_addr <= wr_addr_latch[7:0];  // ← 驱动1
    ...
end

// 读通道 always块
if(rd_hit_reg) begin
    reg_addr <= s_axi_araddr[7:0];   // ← 驱动2
    ...
end
```

同样，`tx_bram_addr` 在写通道（L93）和读通道（L152）各被驱动一次。

**影响**：Verilog中同一`reg`不能在两个`always`块中赋值——综合工具报**多驱动错误**，行为仿真结果不确定。

**修复建议**：将读/写通道的地址输出分离为独立信号（如`reg_wr_addr`/`reg_rd_addr`），或合并到单一always块中用仲裁逻辑复用。由于AXI4-Lite不支持同时读写，可用简单优先级复用：

```verilog
always @(*) begin
    if(wr_pending && hit_reg)
        reg_addr = wr_addr_latch[7:0];
    else
        reg_addr = rd_addr_latch[7:0];
end
```

---

### P-03 🔴 致命：RX数据通路首拍数据丢失

**文件**：`rx_data_path.v`

**问题**：三段式状态机中，当`curr_state=IDLE`且`pl_rx_valid=1`时：
- 第二段：`next_state = RX_WRITE`
- 第三段：走`IDLE`分支 → `nxt_bram_wr_en = 0`（默认值）

下一个时钟沿：`curr_state`变为`RX_WRITE`，但此时`bram_wr_en`刚从第一段寄存器输出，值为0（来自IDLE分支的默认值）。**第一拍`pl_rx_data`的写使能为0，数据未写入BRAM**。

到第二拍`curr_state=RX_WRITE`，第三段才走`RX_WRITE`分支置`nxt_bram_wr_en=1`，但此时`pl_rx_data`已变为第二拍的数据。

**影响**：每帧接收数据的**首个16bit字丢失**，后续数据地址错位。

**修复建议**：在IDLE状态的输出逻辑中，当检测到 `next_state == RX_WRITE` 时立即置写使能和数据：

```verilog
IDLE: begin
    nxt_data_cnt = 8'd0;
    if(next_state == RX_WRITE) begin
        nxt_bram_addr  = 8'd0;
        nxt_bram_wr_en = 1'b1;        // 首拍写使能
        nxt_bram_wdata = pl_rx_data;   // 首拍数据
        nxt_data_cnt   = 8'd1;        // 计数从1开始
    end
end
```

---

### P-04 🔴 致命：RX_LEN握手条件引用了错误信号

**文件**：`ctrl_reg_bank.v` L80

**问题**：PS域always块中RX_LEN的采样条件为：

```verilog
if(rx_len_req_s2 && !tx_len_ack_sync2) begin  // ← tx_len_ack_sync2是TX方向的信号！
    rx_len_ps <= rx_len_hold_ps;
end
```

应使用**RX方向**的ack信号`rx_len_ack_s2`，但代码引用了**TX方向**的`tx_len_ack_sync2`。

**影响**：RX_LEN的采样时机完全由TX_LEN的握手状态控制，RX帧长度数据**随机错误或永远不更新**。

**修复建议**：
```verilog
if(rx_len_req_s2 && !rx_len_ack_s2) begin
    rx_len_ps <= rx_len_hold_ps;
end
```

---

### P-05 🔴 致命：`rx_len_hold_ps`在两个时钟域always块中多驱动

**文件**：`ctrl_reg_bank.v`

**问题**：`rx_len_hold_ps`在两处被赋值：

```verilog
// PL域 always块 (L195, clk_1m)
always @(posedge clk_1m or negedge rst_n_1m) begin
    if(!rst_n_1m) begin
        rx_len_hold_ps <= 8'd0;   // ← 驱动1（复位）
    end
    ...
end

// PS域 always块 (L205, s_axi_aclk)
always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if(!s_axi_aresetn) begin
        rx_len_hold_ps <= 8'd0;   // ← 驱动2（复位+正常赋值）
    end else begin
        if(rx_len_req_s2 && !rx_len_ack_s2) begin
            rx_len_hold_ps <= rx_len_pl;  // ← 驱动2
        end
    end
end
```

**影响**：同一寄存器在两个不同时钟的always块中驱动，**不可综合**，综合工具报错。

**修复建议**：`rx_len_hold_ps`仅在PS域always块中驱动，从PL域always块中删除该寄存器的复位赋值。

---

### P-06 🟠 严重：TX_START toggle同步方向检测异常

**文件**：`ctrl_reg_bank.v` L37

**问题**：`tx_start_pl`的生成逻辑为：

```verilog
assign tx_start_pl = tgl_sync2 & ~tgl_sync2_d;  // 仅检测上升沿
```

但`tx_start_toggle_q`是**取反翻转**（`~tx_start_toggle_q`），每次toggle交替产生上升沿和下降沿。仅检测上升沿意味着**每两次PS写操作才产生一次PL脉冲**。

实际分析：
- 第1次写1：toggle从0→1，PL端检测到上升沿 → 产生脉冲 ✅
- 第2次写1：toggle从1→0，PL端只有下降沿 → **无脉冲** ❌
- 第3次写1：toggle从0→1 → 产生脉冲 ✅

**影响**：TX_START命令有50%概率不生效。

**修复建议**：改为异或边沿检测（检测任意翻转）：
```verilog
assign tx_start_pl = tgl_sync2 ^ tgl_sync2_d;
```

---

### P-07 🟠 严重：RX_LEN握手ack非真正跨时钟域同步

**文件**：`ctrl_reg_bank.v` L205-220

**问题**：RX_LEN握手的ack链为：

```verilog
// PS域 always块
rx_len_ack_s1 <= 1'b1;   // 本域内直接产生
rx_len_ack_s2 <= rx_len_ack_s1;  // 本域内延迟1拍
```

`rx_len_ack_s1`和`rx_len_ack_s2`都在**同一个PS域always块**中赋值，并非从PL域跨过来的2FF同步。`rx_len_ack_s2`实际上只是`rx_len_ack_s1`的1拍延迟。

同时，PL域需要看到ack来撤销req，但ack信号`rx_len_ack_s2`根本不在PL域——PL域的`rx_len_req`撤销条件是`rx_len_ack_s2`（L199），但`rx_len_ack_s2`在PS域时钟下赋值，PL域直接采样存在**跨时钟域亚稳态风险**。

**影响**：PL域直接读取PS域的ack信号，违反CDC规则，可能导致握手死锁或数据采样错误。

**修复建议**：参照TX_LEN的握手模式——ack在PS域产生后，需经**2FF同步**传回PL域：
```verilog
// PL域
reg rx_len_ack_sync_to_pl_1, rx_len_ack_sync_to_pl_2;
always @(posedge clk_1m) begin
    rx_len_ack_sync_to_pl_1 <= rx_len_ack_s1;  // 从PS域同步到PL域
    rx_len_ack_sync_to_pl_2 <= rx_len_ack_sync_to_pl_1;
end
// PL域 req 撤销条件改用 rx_len_ack_sync_to_pl_2
```

---

### P-08 🟠 严重：`rx_len`在data_cnt=255时溢出为0

**文件**：`rx_data_path.v` L105

**问题**：

```verilog
RX_FINISH: begin
    nxt_rx_len = data_cnt + 1'b1;  // data_cnt=255时：255+1=0（8bit溢出）
end
```

当接收满256个16bit字（触发溢出保护`data_cnt==255`跳转），计算出的帧长度为0。

**影响**：PS侧读到的RX帧长度为0，软件无法正确解析帧。

**修复建议**：
```verilog
nxt_rx_len = (data_cnt == 8'd255) ? 8'd255 : data_cnt + 1'b1;
```
或将`rx_len`扩展为9bit。

---

### P-09 🟠 严重：读通道`rd_hit_*`使用旧地址判断数据源

**文件**：`axi_lite_slave.v` L130-147

**问题**：AR握手时，`rd_addr_latch`通过`<=`赋值在**时钟沿后**才更新，但组合逻辑`rd_hit_reg/rd_hit_tx/rd_hit_rx`基于`rd_addr_latch`：

```verilog
// 时钟沿：AR握手
if(s_axi_arvalid && s_axi_arready) begin
    rd_addr_latch <= s_axi_araddr[10:0];  // 下一拍生效
    // 同时用 s_axi_araddr 直接驱动 BRAM 地址（正确）
    if(rd_hit_reg) ...  // ← 但此时 rd_hit_reg 基于旧 rd_addr_latch!
end
```

AR握手当拍，BRAM地址用`s_axi_araddr`（正确），但地址空间判断用`rd_hit_reg`（基于旧`rd_addr_latch`），**两者不匹配**。

**时序分析**：
- 周期N：AR握手，`rd_addr_latch`仍为旧值，`rd_hit_*`判断错误 → 可能发错BRAM地址
- 周期N+1：`rd_addr_latch`更新为新值，`rd_hit_*`正确 → 取数时走正确分支

因为发地址（周期N）和取数（周期N+1）用的地址判断不同，**如果前后两次读地址在不同区域，第一次地址发送可能发错BRAM口**。

**修复建议**：AR握手时直接用`s_axi_araddr`判断区域（而非`rd_addr_latch`）：
```verilog
wire [10:0] ar_addr_wire = s_axi_araddr[10:0];
wire ar_hit_reg = (ar_addr_wire >= REG_BASE) && (ar_addr_wire <= REG_END);
// ...在AR握手时使用 ar_hit_* 驱动地址
```

---

### P-10 🟡 一般：TX状态机注释声称独热编码实际为二进制

**文件**：`tx_data_path.v` L22

**问题**：
```verilog
//===================== 状态定义（独热） =====================
localparam IDLE     = 2'b00;  // 2bit二进制编码
localparam TX_ADDR  = 2'b01;
```

注释写"独热"但编码为`2'b00/01/10/11`，独热编码应为`4'b0001/0010/0100/1000`。

**影响**：功能无影响，但注释误导Code Review和维护。

**修复建议**：将注释改为"二进制编码"。

---

### P-11 🟡 一般：`tx_len_latch - 1`潜在下溢

**文件**：`tx_data_path.v` L95, L105

**问题**：
```verilog
TX_OUT: begin
    if(data_cnt == tx_len_latch - 1'b1) ...  // tx_len_latch=0时下溢为255
    if(data_cnt < tx_len_latch - 1'b1) ...
end
```

虽然IDLE进入条件检查了`tx_len > 0`，但`tx_len_latch`在IDLE→TX_ADDR时才锁存。如果CDC握手链传播期间PS修改了`tx_len`，`tx_len_latch`**可能锁存到0**。

**影响**：如果发生，`tx_len_latch - 1 = 255`，状态机循环255次空读BRAM。

**修复建议**：在TX_OUT中增加`tx_len_latch == 0`的保护跳出。

---

### P-12 🟡 一般：越界地址读返回OKAY

**文件**：`axi_lite_slave.v` L159-162

**问题**：

```verilog
// 读地址未命中任何区域
end else begin
    s_axi_rdata <= 32'd0;
end
s_axi_rresp <= 2'b00;  // 固定OKAY
```

越界写正确返回DECERR（`2'b11`），但越界读返回OKAY+全0数据。AXI规范建议返回DECERR。

**修复建议**：越界读时设置`s_axi_rresp <= 2'b11`。

---

### P-13 🟡 一般：`tx_start_ps`写1置位后无自动回清

**文件**：`ctrl_reg_bank.v` L89

**问题**：`tx_start_ps`在PS写1时置位，但从不回清。PS读CTRL_REG时bit[0]永远读到1（一旦触发过）。设计意图是W1S（Write-1-to-Set），但缺少消费后清除逻辑。

**影响**：PS软件无法通过读bit[0]判断上次TX_START是否已被PL消费。

**修复建议**：在检测到toggle被PL消费后（如`tx_len_ack_sync2`回来时）回清`tx_start_ps`。

---

### P-14 🟡 一般：TX数据通路`pl_tx_req`仅在启动时检查

**文件**：`tx_data_path.v` L77

**问题**：
```verilog
IDLE: if(tx_start_pulse && pl_tx_req && tx_len > 8'd0) ...
```

`pl_tx_req`仅在启动条件中检查。启动后TX持续输出数据直到完成，不再检查PL侧是否准备好接收。

**影响**：如果PL侧需要流控（暂停/恢复），当前设计不支持。

---

## 3. CDC跨时钟域安全审查

### 3.1 CDC路径清单

| 信号 | 方向 | 同步方式 | 评估 |
|------|------|----------|------|
| tx_start_toggle_q | PS→PL | toggle + 2FF + 边沿 | ⚠️ P-06：仅检测上升沿 |
| tx_len_ps | PS→PL | req/ack握手 | ✅ 基本正确（数据在req期间稳定） |
| tx_irq_en → irq_en_s2 | PS→PL | 电平2FF | ✅ 正确 |
| txd_tgl_q (tx_done) | PL→PS | toggle + 2FF + 边沿 | ✅ 异或边沿 → 但代码用`& ~`仅检上升沿 ⚠️ |
| rxr_tgl_q (rx_ready) | PL→PS | toggle + 2FF + 边沿 | ✅ 同上 ⚠️ |
| rx_len_pl | PL→PS | req/ack握手 | ❌ P-04/P-05/P-07 |
| reg_addr/tx_bram_addr | 共享 | 无CDC（同域） | ❌ P-02 多驱动 |

### 3.2 TX_DONE / RX_READY 边沿检测问题

与P-06相同的模式，`tx_done_edge`和`rx_ready_edge`使用`& ~`仅检测上升沿：
```verilog
wire tx_done_edge  = txd_s2 & ~txd_s2_d;   // 仅上升沿
wire rx_ready_edge = rxr_s2 & ~rxr_s2_d;   // 仅上升沿
```

toggle方式每次翻转交替产生上升/下降沿，仅检上升沿导致**每两次PL事件只有一次被PS感知**。

**修复建议**：统一改为异或检测：
```verilog
wire tx_done_edge  = txd_s2 ^ txd_s2_d;
wire rx_ready_edge = rxr_s2 ^ rxr_s2_d;
```

---

## 4. 三段式状态机检查

### 4.1 tx_data_path

| 段 | 类型 | 行号 | 评估 |
|----|------|------|------|
| 第一段 | 时序：状态+输出寄存器 | L50-64 | ✅ |
| 第二段 | 组合：次态跳转 | L67-82 | ✅ |
| 第三段 | 组合：输出逻辑 | L85-112 | ✅ |

**结论**：✅ 标准三段式，结构正确。

### 4.2 rx_data_path

| 段 | 类型 | 行号 | 评估 |
|----|------|------|------|
| 第一段 | 时序：状态+输出寄存器 | L40-56 | ✅ |
| 第二段 | 组合：次态跳转 | L59-74 | ✅ |
| 第三段 | 组合：输出逻辑 | L77-113 | ⚠️ P-03首拍丢失 |

**结论**：结构正确但输出逻辑有首拍丢失Bug。

---

## 5. AXI4-Lite协议合规检查

| 检查项 | 结果 | 说明 |
|--------|------|------|
| AW/W独立缓存 | ✅ | 支持乱序到达 |
| BRESP握手 | ✅ | bvalid+bready正确 |
| AR握手 | ✅ | arvalid+arready正确 |
| R通道握手 | ✅ | rvalid+rready正确 |
| 写时WSTRB处理 | ⚠️ | BRAM区拒绝部分写(SLVERR)，寄存器区透传但端口缺失(P-01) |
| 读BRAM 1拍延迟 | ✅ | rd_addr_sent等待1拍 |
| 越界读RRESP | ⚠️ | 返回OKAY而非DECERR(P-12) |
| 同时读写 | ❌ | reg_addr多驱动(P-02) |

---

## 6. 问题严重程度统计

| 严重程度 | 数量 | 编号 |
|----------|------|------|
| 🔴 致命 | 5 | P-01, P-02, P-03, P-04, P-05 |
| 🟠 严重 | 4 | P-06, P-07, P-08, P-09 |
| 🟡 一般 | 5 | P-10, P-11, P-12, P-13, P-14 |
| **合计** | **14** | |

---

## 7. 修复优先级建议

### 第一优先级（编译无法通过）

1. **P-01**：axi_lite_slave增加`reg_wr_strb`输出端口
2. **P-02**：reg_addr/tx_bram_addr拆分为读写独立信号或合并always块
3. **P-05**：rx_len_hold_ps仅在PS域驱动

### 第二优先级（功能错误）

4. **P-03**：rx_data_path首拍数据IDLE状态预写使能
5. **P-04**：RX_LEN握手条件改用rx_len_ack_s2
6. **P-06**：tx_start_pl边沿检测改为异或（`^`）
7. **P-07**：RX_LEN ack信号增加PL→PS方向2FF同步
8. **P-08**：rx_len溢出保护
9. **P-09**：读通道AR握手时用s_axi_araddr直接判断区域

### 第三优先级（健壮性改进）

10. TX_DONE/RX_READY边沿检测改为异或
11. P-11/P-12/P-13/P-14

---

## 8. 总体评价

### 优点

- ✅ 整体架构分层清晰（协议层/寄存器层/数据通路层解耦）
- ✅ 数据通路采用三段式状态机，结构规范
- ✅ CDC设计意图正确（toggle同步、握手同步、电平同步三种模式选择合理）
- ✅ AXI4-Lite协议层支持AW/W乱序到达
- ✅ BRAM区部分写检测返回SLVERR
- ✅ 真双口BRAM位宽不对称（32b/16b）方案合理

### 主要风险

- ❌ **5项致命问题**中3项导致编译失败（P-01/P-02/P-05），2项导致数据错误（P-03/P-04）
- ❌ CDC同步的toggle边沿检测**全部使用`& ~`而非`^`**（P-06及TX_DONE/RX_READY），导致每两次事件漏检一次
- ❌ RX_LEN握手同步实现**不符合CDC规范**（P-07），ack信号未真正跨时钟域同步

**建议**：修复全部致命和严重问题后，进行完整仿真验证，重点覆盖：
1. 连续两次TX_START（验证P-06修复）
2. RX接收首拍数据正确性（验证P-03修复）
3. RX帧长度传递正确性（验证P-04/P-05/P-07修复）
4. 读写交替访问不同地址空间（验证P-02/P-09修复）
