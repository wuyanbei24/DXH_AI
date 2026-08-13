# Zynq-7020 PS-PL AXI4-Lite BRAM 双向通信设计文档（优化版）V02

**版本**：V02（基于V3.1代码Review后全面修复版）  
**开发环境**：Vivado 2018.2  
**目标芯片**：XC7Z020  
**文档日期**：2026-07-28

---

## 修订摘要

V02基于V3.1代码深度Review发现的14项设计缺陷（5项致命/4项严重/5项一般），进行系统性修复。核心改进：

| 类别 | 修复内容 | 影响模块 |
|------|----------|----------|
| 编译修复 | 新增`reg_wr_strb`端口透传WSTRB | `axi_lite_slave` |
| 多驱动消除 | 读写地址分离为独立寄存器+组合复用 | `axi_lite_slave` |
| 数据丢失修复 | RX首拍数据IDLE状态预写入 | `rx_data_path` |
| CDC全面修复 | toggle边沿改XOR/RX_LEN握手重写/ack真正2FF同步 | `ctrl_reg_bank` |
| 溢出保护 | rx_len/tx_len_latch下溢防护 | `rx_data_path`/`tx_data_path` |
| 协议合规 | 越界读返回DECERR | `axi_lite_slave` |

---

## 一、整体架构设计

### 1.1 系统分层架构

```
┌───────────────────────── PS 端 ────────────────────────────┐
│                ARM Cortex-A9 / AXI4-Lite Master             │
└──────────────────────────┬─────────────────────────────────┘
                           │ AXI4-Lite (s_axi_aclk: 100MHz)
┌──────────────────────────┴─────────────────────────────────┐
│  axi_lite_slave  协议层                                     │
│  地址译码 → REG区(0x000~0xFF) / TX BRAM(0x100~0x2FF)       │
│                               / RX BRAM(0x300~0x4FF)       │
├──────────────┬─────────────────────┬───────────────────────┤
│ ctrl_reg_bank│   TX True-DP BRAM   │   RX True-DP BRAM     │
│ 寄存器+CDC   │  A口32b(PS写/读)    │  A口32b(PS读)         │
│ 6路同步      │  B口16b(PL读)       │  B口16b(PL写)         │
├──────────────┴──────┬──────────────┴───────────────────────┤
│   tx_data_path      │            rx_data_path              │
│   三段式FSM(1MHz)   │            三段式FSM(1MHz)           │
│   BRAM→PL数据输出    │            PL数据→BRAM写入            │
└─────────────────────┴──────────────────────────────────────┘
                    PL 端 (clk_1m: 1MHz)
```

### 1.2 模块划分与职责

| 模块 | 层级 | 时钟域 | 职责 |
|------|------|--------|------|
| `pl_bram_comm_top` | 顶层 | — | 子模块例化、信号互联、接口封装 |
| `axi_lite_slave` | 协议层 | s_axi_aclk | AXI4-Lite协议解析、地址译码(3区域)、读写通道握手 |
| `ctrl_reg_bank` | 寄存器层 | s_axi_aclk + clk_1m | 控制/状态/长度寄存器、6路CDC同步 |
| `tx_data_path` | 数据通路 | clk_1m | TX BRAM读控制、三段式FSM、PL数据输出 |
| `rx_data_path` | 数据通路 | clk_1m | RX BRAM写控制、三段式FSM、中断生成 |
| `tx_bram_ip` | 存储 | 双异步 | 真双口BRAM, PS写/PL读, 32b×128 / 16b×256 |
| `rx_bram_ip` | 存储 | 双异步 | 真双口BRAM, PL写/PS读, 32b×128 / 16b×256 |

### 1.3 时钟域

| 时钟 | 频率 | 来源 | 驱动模块 |
|------|------|------|----------|
| `s_axi_aclk` | 100MHz | Zynq PS FCLK | axi_lite_slave, ctrl_reg_bank(PS域), BRAM A口 |
| `clk_1m` | 1MHz | PL外部/分频 | ctrl_reg_bank(PL域), tx/rx_data_path, BRAM B口 |
| `ref_clk_200m` | — | — | 未使用（本设计无IDELAY） |

---

## 二、地址空间分配

### 2.1 地址总表

基地址由Vivado地址编辑器分配（典型值`0x43C0_0000`），内部使用11位字节偏移地址：

| 分区 | 偏移地址 | 大小 | 访问属性 | 说明 |
|------|----------|------|----------|------|
| REG区 | 0x000~0x0FF | 256B | PS读写/PL同步 | 控制标志、状态、长度寄存器 |
| TX BRAM | 0x100~0x2FF | 512B | PS写/PL读 | 下发数据缓存,256×16bit |
| RX BRAM | 0x300~0x4FF | 512B | PL写/PS读 | 上传数据缓存,256×16bit |

**地址译码常量**（`axi_lite_slave.v`）：
```verilog
localparam [10:0] REG_BASE     = 11'h000;
localparam [10:0] REG_END      = 11'h0FF;
localparam [10:0] TX_BRAM_BASE = 11'h100;
localparam [10:0] TX_BRAM_END  = 11'h2FF;
localparam [10:0] RX_BRAM_BASE = 11'h300;
localparam [10:0] RX_BRAM_END  = 11'h4FF;
```

### 2.2 控制寄存器位域定义

#### CTRL_REG (偏移 0x00)

| 位段 | 名称 | 类型 | 操作方 | 说明 |
|------|------|------|--------|------|
| Bit[0] | TX_START | W1S(边沿) | PS写1触发 | 产生toggle脉冲通知PL读取，PL消费后自动回清 |
| Bit[1] | TX_DONE | W1C | PL置位/PS写1清 | PL读取完一帧后置1 |
| Bit[2] | RX_READY | W1C | PL置位/PS写1清 | PL上传完一帧后置1 |
| Bit[3] | RX_IRQ_EN | RW | PS读写 | 1=使能RX_READY中断 |
| Bit[31:4] | Reserved | RO | — | 读返回0 |

#### LEN_REG (偏移 0x04)

| 位段 | 名称 | 类型 | 操作方 | 说明 |
|------|------|------|--------|------|
| Bit[7:0] | TX_LEN | RW | PS写 | 下发帧长度(1~255, 0无效不启动) |
| Bit[15:8] | Reserved | — | — | 读返回0 |
| Bit[23:16] | RX_LEN | RO | PL写 | 上传帧长度(1~255) |
| Bit[31:24] | Reserved | — | — | 读返回0 |

### 2.3 BRAM数据区

- **位宽配置**：PS侧32bit（一次访问2个16bit），PL侧16bit逐点处理
- **深度**：256个16bit数据单元 = 512字节
- **地址映射**：AXI字节地址`TX_BASE + n*4`对应BRAM第`2n`和`2n+1`个16bit数据
- **BRAM A口地址**：`wr_addr_latch[8:2]`（7bit字地址，128个32bit字）
- **BRAM B口地址**：`data_cnt[7:0]`（8bit字地址，256个16bit字）

---

## 三、模块详细设计

### 3.1 axi_lite_slave — AXI4-Lite协议层

#### 3.1.1 接口定义

**AXI4-Lite从机侧**：标准5通道（AW/W/B/AR/R），32bit地址/数据。

**内部总线侧**：

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `reg_addr` | output wire | 8 | 寄存器地址（组合复用输出） |
| `reg_wr_en` | output reg | 1 | 写使能（单拍脉冲） |
| `reg_wr_data` | output reg | 32 | 写数据 |
| `reg_wr_strb` | output reg | 4 | WSTRB透传（V02新增） |
| `reg_rd_data` | input | 32 | 读数据 |
| `reg_rd_en` | output reg | 1 | 读使能（单拍脉冲） |
| `tx_bram_addr` | output wire | 7 | TX BRAM A口地址（组合复用输出） |
| `tx_bram_wr_en` | output reg | 1 | TX BRAM写使能 |
| `tx_bram_wdata` | output reg | 32 | TX BRAM写数据 |
| `tx_bram_rdata` | input | 32 | TX BRAM读数据 |
| `rx_bram_addr` | output wire | 7 | RX BRAM A口地址 |
| `rx_bram_rdata` | input | 32 | RX BRAM读数据 |

#### 3.1.2 写通道设计（AW/W独立缓存）

支持AW/W任意到达顺序（AW先到或W先到）：

```
AW通道: awvalid&&awready → 锁存 wr_addr_latch, 置 aw_captured=1
W 通道: wvalid&&wready   → 锁存 w_data_latch/w_strb_latch, 置 w_captured=1
均到齐: aw_captured && w_captured → 执行写操作 → 产生 BRESP
```

**地址区域译码与响应**：

| 命中区域 | 动作 | BRESP |
|----------|------|-------|
| REG区 | `reg_wr_en`脉冲, `reg_wr_strb`透传 | OKAY(0x00) |
| TX BRAM, WSTRB=4'b1111 | `tx_bram_wr_en`脉冲 | OKAY(0x00) |
| TX BRAM, WSTRB≠4'b1111 | 拒绝部分写 | SLVERR(0x10) |
| 越界/RX BRAM(只读) | 忽略 | DECERR(0x11) |

#### 3.1.3 读通道设计（两段式）

```
AR握手拍(N): 锁存rd_addr_latch, 用即时地址ar_addr_imm判断区域, 驱动BRAM地址
取数拍(N+1): 用已锁存的rd_addr_latch判断区域, 取对应源数据, 输出R通道
```

**V02改进**：
- AR握手时用即时`s_axi_araddr`判断区域（非旧`rd_addr_latch`），避免发错BRAM口
- 越界读返回`RRESP=DECERR(2'b11)`

#### 3.1.4 多驱动消除（V02核心修复）

`reg_addr`/`tx_bram_addr`/`rx_bram_addr`在V3.1中被读/写两个always块同时驱动。V02改为：

```verilog
// 读写通道独立地址寄存器
reg [7:0]  wr_reg_addr, rd_reg_addr;
reg [6:0]  wr_tx_bram_addr, rd_tx_bram_addr, rd_rx_bram_addr;

// 组合逻辑复用（读优先，AXI4-Lite不支持同时读写）
assign reg_addr     = rd_addr_sent ? rd_reg_addr     : wr_reg_addr;
assign tx_bram_addr = rd_addr_sent ? rd_tx_bram_addr : wr_tx_bram_addr;
assign rx_bram_addr = rd_rx_bram_addr;
```

### 3.2 ctrl_reg_bank — 控制寄存器组 + CDC同步

#### 3.2.1 6路CDC同步机制

| 信号 | 方向 | 类型 | 同步方法 | 详细说明 |
|------|------|------|----------|----------|
| TX_START | PS→PL | 脉冲 | Toggle + 2FF + XOR边沿检测 | PS每次写1翻转toggle,PL检测任意翻转产生脉冲 |
| TX_LEN[7:0] | PS→PL | 多bit数据 | Req/Ack握手 | PS置req→PL锁存数据回ack→PS撤req |
| RX_IRQ_EN | PS→PL | 电平 | 2FF同步 | 简单两级触发器 |
| TX_DONE | PL→PS | 脉冲 | Toggle + 2FF + XOR边沿检测 | PL事件翻转toggle,PS检测翻转 |
| RX_READY | PL→PS | 脉冲 | Toggle + 2FF + XOR边沿检测 | 同TX_DONE |
| RX_LEN[7:0] | PL→PS | 多bit数据 | Req/Ack握手(全路径2FF) | PL锁存数据置req→PS锁存回ack→ack同步回PL撤req |

#### 3.2.2 TX_START Toggle同步链

```
PS域: tx_start_toggle_q（每次写CTRL[0]=1时取反）
      ↓ 跨域
PL域: tgl_sync1 → tgl_sync2 → tgl_sync2_d (2FF + 延迟)
      tx_start_pl = tgl_sync2 ^ tgl_sync2_d  // XOR检测任意翻转
```

**V02修复**：V3.1使用`& ~`仅检测上升沿，导致每两次触发漏检一次。V02改为XOR`^`检测任意翻转。同样修复TX_DONE和RX_READY的边沿检测。

#### 3.2.3 TX_LEN 握手同步链（PS→PL）

```
PS域                          PL域
────────                      ────────
tx_len_ps ←── PS写LEN_REG      
tx_len_req=1 ──2FF──→ tx_len_req_sync1 → tx_len_req_sync2
                      检测req且!ack → 锁存tx_len_hold, 置tx_len_ack_pl=1
tx_len_ack_sync1 ← tx_len_ack_sync2 ←2FF── tx_len_ack_pl
收到ack → req=0, tx_start_ps回清
```

**V02改进**：收到PL的ack后自动回清`tx_start_ps`，PS可通过读CTRL[0]判断上次启动是否已被消费。

#### 3.2.4 RX_LEN 握手同步链（PL→PS，V02重写）

V3.1存在3个致命问题（P-04错误信号引用/P-05多驱动/P-07 ack未跨域同步），V02完全重写：

```
PL域                              PS域
────────                          ────────
rx_ready_pl触发:
  rx_len_hold_pl ← rx_len_pl      
  rx_len_req=1 ──2FF──→ rx_len_req_s1 → rx_len_req_s2
                        检测req且!ack → rx_len_hold_ps←rx_len_hold_pl
                                        rx_len_ack_ps=1
rx_len_ack_to_pl_s1 ← rx_len_ack_to_pl_s2 ←2FF── rx_len_ack_ps
收到同步ack → rx_len_req=0
```

**关键修复**：
- `rx_len_hold_pl`仅在PL域驱动（消除多驱动）
- `rx_len_hold_ps`仅在PS域驱动（消除多驱动）
- ack信号经2FF从PS域同步回PL域（真正CDC安全）
- 采样条件使用`rx_len_ack_ps`（非错误的`tx_len_ack_sync2`）

### 3.3 tx_data_path — TX数据通路（PS→PL）

#### 3.3.1 接口

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `bram_addr` | out reg | 8 | BRAM B口读地址 |
| `bram_rdata` | in | 16 | BRAM B口读数据 |
| `tx_start` | in | 1 | 启动脉冲（CDC后） |
| `tx_len` | in | 8 | 帧长度（CDC后） |
| `tx_done` | out reg | 1 | 完成脉冲 |
| `pl_tx_req` | in | 1 | PL请求数据 |
| `pl_tx_valid` | out reg | 1 | 数据有效 |
| `pl_tx_data` | out reg | 16 | 输出数据 |

#### 3.3.2 三段式状态机

```
状态编码（2bit二进制）：
  IDLE(00) → TX_ADDR(01) → TX_WAIT(10) → TX_OUT(11) → TX_ADDR/IDLE
```

**状态转移**：

| 当前态 | 条件 | 次态 |
|--------|------|------|
| IDLE | `tx_start_pulse && pl_tx_req && tx_len>0` | TX_ADDR |
| TX_ADDR | 无条件 | TX_WAIT |
| TX_WAIT | 无条件 | TX_OUT |
| TX_OUT | `tx_len_latch==0 ∥ data_cnt==tx_len_latch-1` | IDLE(+tx_done) |
| TX_OUT | 还有剩余 | TX_ADDR |

**每个16bit数据需3个clk_1m周期**（ADDR→WAIT→OUT），吞吐率1/3。

**V02改进**：
- TX_OUT状态增加`tx_len_latch==0`保护，防止减法下溢
- 注释更正为"二进制编码"（非独热）

#### 3.3.3 BRAM读时序

```
ADDR周期: bram_addr = data_cnt (发地址)
WAIT周期: bram_addr保持 (吸收BRAM 1拍读延迟)
OUT 周期: pl_tx_data = bram_rdata (数据已有效)
```

### 3.4 rx_data_path — RX数据通路（PL→PS）

#### 3.4.1 接口

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `bram_addr` | out reg | 8 | BRAM B口写地址 |
| `bram_wr_en` | out reg | 1 | 写使能 |
| `bram_wdata` | out reg | 16 | 写数据 |
| `rx_irq_en` | in | 1 | 中断使能（CDC后） |
| `rx_ready` | out reg | 1 | 帧完成脉冲（→CDC） |
| `rx_len` | out reg | 8 | 帧长度（→CDC） |
| `pl_rx_valid` | in | 1 | PL数据有效 |
| `pl_rx_data` | in | 16 | PL输入数据 |
| `pl_rx_done` | out reg | 1 | 帧完成脉冲（→PL业务） |
| `pl_rx_irq` | out reg | 1 | 中断脉冲 |

#### 3.4.2 三段式状态机

```
状态编码（2bit二进制）：
  IDLE(00) → RX_WRITE(01) → RX_FINISH(10) → IDLE
```

**状态转移**：

| 当前态 | 条件 | 次态 |
|--------|------|------|
| IDLE | `pl_rx_valid` | RX_WRITE |
| RX_WRITE | `!pl_rx_valid ∥ data_cnt==255` | RX_FINISH |
| RX_WRITE | else | RX_WRITE |
| RX_FINISH | 无条件 | IDLE |

#### 3.4.3 首拍数据写入（V02核心修复）

V3.1的三段式FSM在IDLE→RX_WRITE转换时，输出逻辑走IDLE分支（写使能为0），导致**首个16bit数据丢失**。

V02修复：在IDLE状态检测到`next_state==RX_WRITE`时，立即预置写使能和数据：

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

#### 3.4.4 长度计算溢出保护（V02修复）

V3.1中`rx_len = data_cnt + 1`在`data_cnt=255`时溢出为0。V02改为：

```verilog
nxt_rx_len = (data_cnt == 8'd0) ? 8'd1 : data_cnt;
```

### 3.5 pl_bram_comm_top — 顶层集成

纯接线模块，例化6个子模块：

```
u_axi_lite_slave   ← AXI4-Lite协议层
u_ctrl_reg_bank    ← 寄存器+CDC
u_tx_data_path     ← TX数据通路
u_rx_data_path     ← RX数据通路
u_tx_bram_ip       ← TX True-DP BRAM (A:32b×128, B:16b×256)
u_rx_bram_ip       ← RX True-DP BRAM (A:32b×128, B:16b×256)
```

**BRAM访问矩阵**：

| BRAM | Port A (s_axi_aclk) | Port B (clk_1m) |
|------|---------------------|-----------------|
| TX | PS写(`wea=wr_en`) + PS读 | PL只读(`web=0`) |
| RX | PS只读(`wea=0`) | PL写(`web=wr_en`) |

---

## 四、BRAM IP配置

### 4.1 Vivado IP参数

| 参数 | TX BRAM | RX BRAM |
|------|---------|---------|
| 类型 | True Dual Port RAM | True Dual Port RAM |
| Port A 数据宽度 | 32 bit | 32 bit |
| Port A 深度 | 128 | 128 |
| Port A 时钟 | s_axi_aclk (100MHz) | s_axi_aclk (100MHz) |
| Port B 数据宽度 | 16 bit | 16 bit |
| Port B 深度 | 256 | 256 |
| Port B 时钟 | clk_1m (1MHz) | clk_1m (1MHz) |
| 操作模式 | Write First / No Change | Write First / No Change |
| 使能ECC | No | No |
| 读延迟 | 1 cycle | 1 cycle |

### 4.2 BRAM例化接口

```verilog
tx_bram_ip u_tx_bram_ip(
    .clka (s_axi_aclk),   .wea  (tx_bram_a_wr_en),
    .addra(tx_bram_a_addr),.dina (tx_bram_a_wdata), .douta(tx_bram_a_rdata),
    .clkb (clk_1m),        .web  (1'b0),
    .addrb(tx_bram_b_addr),.dinb (16'd0),            .doutb(tx_bram_b_rdata)
);

rx_bram_ip u_rx_bram_ip(
    .clka (s_axi_aclk),   .wea  (1'b0),
    .addra(rx_bram_a_addr),.dina (32'd0),            .douta(rx_bram_a_rdata),
    .clkb (clk_1m),        .web  (rx_bram_b_wr_en),
    .addrb(rx_bram_b_addr),.dinb (rx_bram_b_wdata),  .doutb()
);
```

---

## 五、PS端软件设计

### 5.1 地址宏定义

```c
#define BRAM_COMM_BASE   0x43C00000
#define REG_CTRL         (BRAM_COMM_BASE + 0x00)
#define REG_LEN          (BRAM_COMM_BASE + 0x04)
#define TX_BRAM_BASE     (BRAM_COMM_BASE + 0x100)
#define RX_BRAM_BASE     (BRAM_COMM_BASE + 0x300)

// CTRL_REG 位定义
#define CTRL_TX_START    (1 << 0)
#define CTRL_TX_DONE     (1 << 1)
#define CTRL_RX_READY    (1 << 2)
#define CTRL_RX_IRQ_EN   (1 << 3)
```

### 5.2 PS下发数据到PL

```c
void ps_send_data_to_pl(uint16_t *data, uint8_t len) {
    volatile uint32_t *tx_bram = (volatile uint32_t *)TX_BRAM_BASE;

    // 1. 写入TX BRAM（两个16bit打包为一个32bit写入）
    for (int i = 0; i < len; i += 2) {
        uint32_t word = data[i];
        if (i + 1 < len) word |= ((uint32_t)data[i+1] << 16);
        tx_bram[i/2] = word;
    }

    // 2. 写入长度寄存器（同时触发CDC握手）
    Xil_Out32(REG_LEN, (uint32_t)len);

    // 3. 触发TX_START（写1产生toggle脉冲）
    Xil_Out32(REG_CTRL, CTRL_TX_START);

    // 4. 轮询等待TX_DONE
    while (!(Xil_In32(REG_CTRL) & CTRL_TX_DONE));

    // 5. W1C清除TX_DONE
    Xil_Out32(REG_CTRL, CTRL_TX_DONE);
}
```

### 5.3 PS接收PL上传数据

```c
void ps_receive_data_from_pl(uint16_t *buf, uint8_t *len) {
    // 1. 轮询等待RX_READY（或中断模式）
    while (!(Xil_In32(REG_CTRL) & CTRL_RX_READY));

    // 2. 读取RX长度
    *len = (Xil_In32(REG_LEN) >> 16) & 0xFF;

    // 3. 读取RX BRAM
    volatile uint32_t *rx_bram = (volatile uint32_t *)RX_BRAM_BASE;
    for (int i = 0; i < *len; i += 2) {
        uint32_t word = rx_bram[i/2];
        buf[i] = word & 0xFFFF;
        if (i + 1 < *len) buf[i+1] = (word >> 16) & 0xFFFF;
    }

    // 4. W1C清除RX_READY
    Xil_Out32(REG_CTRL, CTRL_RX_READY);
}
```

---

## 六、完整通信交互流程

### 6.1 PS下发 → PL接收

```
PS端                                PL端
────                                ────
1. 写TX BRAM (0x100~0x2FF)
2. 写LEN_REG.TX_LEN = N
3. 写CTRL_REG.TX_START = 1
   → toggle翻转 ─────CDC────→ tx_start_pl脉冲
   → tx_len_req ─────CDC────→ 锁存tx_len_hold
                                4. tx_data_path: IDLE→TX_ADDR
                                5. 逐字读BRAM B口(16bit×N)
                                6. pl_tx_valid/data输出到业务
                                7. 读完N字: tx_done脉冲
                                   → toggle ─────CDC────→
8. 读CTRL_REG: TX_DONE=1                       
9. 写CTRL_REG: TX_DONE W1C清除
```

### 6.2 PL上传 → PS接收

```
PL端                                PS端
────                                ────
1. pl_rx_valid=1, pl_rx_data输入
2. rx_data_path: IDLE→RX_WRITE
3. 逐拍写RX BRAM B口(16bit×M)
4. pl_rx_valid拉低 → RX_FINISH
5. rx_ready脉冲 + rx_len=M
   → toggle ────CDC────→ RX_READY置位
   → rx_len_req ─CDC──→ 锁存rx_len_hold_ps
6. (若rx_irq_en) pl_rx_irq脉冲                      
                                7. 读CTRL_REG: RX_READY=1
                                8. 读LEN_REG[23:16]=M
                                9. 读RX BRAM (0x300~0x4FF)
                                10. 写CTRL_REG: RX_READY W1C清除
```

---

## 七、CDC跨时钟域安全总结

### 7.1 CDC路径清单

| 路径 | 源时钟 | 目标时钟 | 方法 | 安全性 |
|------|--------|----------|------|--------|
| tx_start_toggle_q | s_axi_aclk | clk_1m | Toggle+2FF+XOR | ✅ |
| tx_len_req/ack/data | s_axi_aclk | clk_1m | Req/Ack握手 | ✅ |
| tx_irq_en | s_axi_aclk | clk_1m | 电平2FF | ✅ |
| txd_tgl_q(tx_done) | clk_1m | s_axi_aclk | Toggle+2FF+XOR | ✅ |
| rxr_tgl_q(rx_ready) | clk_1m | s_axi_aclk | Toggle+2FF+XOR | ✅ |
| rx_len_req→ack(全路径2FF) | clk_1m | s_axi_aclk | Req/Ack握手 | ✅ |

### 7.2 XDC时序约束

```tcl
# CDC false path 约束
set_false_path -from [get_cells *tx_start_toggle_q*] -to [get_cells *tgl_sync1*]
set_false_path -from [get_cells *tx_len_req*] -to [get_cells *tx_len_req_sync1*]
set_false_path -from [get_cells *tx_len_ack_pl*] -to [get_cells *tx_len_ack_sync1*]
set_false_path -from [get_cells *tx_irq_en*] -to [get_cells *irq_en_s1*]
set_false_path -from [get_cells *txd_tgl_q*] -to [get_cells *txd_s1*]
set_false_path -from [get_cells *rxr_tgl_q*] -to [get_cells *rxr_s1*]
set_false_path -from [get_cells *rx_len_req*] -to [get_cells *rx_len_req_s1*]
set_false_path -from [get_cells *rx_len_ack_ps*] -to [get_cells *rx_len_ack_to_pl_s1*]

# CDC max_delay 约束（握手数据总线）
set_max_delay -datapath_only -from [get_cells *tx_len_ps*] -to [get_cells *tx_len_hold*] 10.0
set_max_delay -datapath_only -from [get_cells *rx_len_hold_pl*] -to [get_cells *rx_len_hold_ps*] 10.0
```

---

## 八、状态机总结

| 模块 | 状态机 | 状态数 | 编码 | 状态流 |
|------|--------|--------|------|--------|
| tx_data_path | TX帧调度 | 4 | 2bit二进制 | IDLE→ADDR→WAIT→OUT→(ADDR/IDLE) |
| rx_data_path | RX帧接收 | 3 | 2bit二进制 | IDLE→WRITE→FINISH→IDLE |

两个状态机均严格遵循**三段式设计**（第一段时序打拍/第二段组合次态/第三段组合输出）。

---

## 九、仿真验证

### 9.1 Testbench架构

- DUT: `pl_bram_comm_top`
- 双时钟: AXI 100MHz + PL 1MHz
- 基地址: `0x43C0_0000`
- 内置BRAM行为模型（或Vivado仿真库）

### 9.2 验证矩阵

| 编号 | 测试项 | 验证目标 |
|------|--------|----------|
| T1 | AW/W乱序到达 | W先于AW，数据不丢不错 |
| T2 | 地址边界扫描 | REG/TX/RX边界命中，越界DECERR |
| T3 | WSTRB部分写BRAM | 返回SLVERR |
| T4 | 首帧发送 | 数据完整到达PL |
| T5 | 单字帧(len=1) | 边界长度正确 |
| T6 | 最大帧(len=255) | 数据完整、计数不溢出 |
| T7 | TX_START重复写 | PL仅触发一次 |
| T8 | RX完整流程 | RX_READY置位→PS读数据→W1C清除 |
| T9 | CDC长度一致性 | tx_len/rx_len无混码 |
| T10 | 复位恢复 | 状态机回IDLE，输出清零 |

---

## 十、V02修复清单

### V3.1 → V02 修复项（14项）

| 编号 | 级别 | 模块 | 问题 | 修复方案 |
|------|------|------|------|----------|
| P-01 | 🔴致命 | axi_lite_slave | 缺少`reg_wr_strb`端口 | 新增output端口并透传w_strb_latch |
| P-02 | 🔴致命 | axi_lite_slave | reg_addr/tx_bram_addr多驱动 | 拆分为读写独立寄存器+组合复用 |
| P-03 | 🔴致命 | rx_data_path | 首拍数据丢失 | IDLE状态预写使能+首拍数据 |
| P-04 | 🔴致命 | ctrl_reg_bank | RX_LEN条件引用tx信号 | 改用rx_len_ack_ps |
| P-05 | 🔴致命 | ctrl_reg_bank | rx_len_hold_ps多驱动 | PL域用rx_len_hold_pl, PS域用rx_len_hold_ps |
| P-06 | 🟠严重 | ctrl_reg_bank | Toggle仅检上升沿 | 三处改为XOR`^`检测 |
| P-07 | 🟠严重 | ctrl_reg_bank | RX_LEN ack未跨域同步 | ack经2FF从PS同步回PL域 |
| P-08 | 🟠严重 | rx_data_path | rx_len溢出为0 | 防溢出保护 |
| P-09 | 🟠严重 | axi_lite_slave | 读通道用旧地址判断区域 | AR握手时用即时araddr判断 |
| P-10 | 🟡一般 | tx_data_path | 注释误称独热编码 | 更正为二进制编码 |
| P-11 | 🟡一般 | tx_data_path | tx_len_latch-1下溢 | 增加==0保护 |
| P-12 | 🟡一般 | axi_lite_slave | 越界读返OKAY | 改返DECERR |
| P-13 | 🟡一般 | ctrl_reg_bank | tx_start_ps无自动回清 | 收到ack后自动清零 |
| P-14 | 🟡一般 | tx_data_path | pl_tx_req仅启动时检查 | 记录为设计限制（已知） |

---

## 十一、资源估算

| 资源 | 数量 | 说明 |
|------|------|------|
| BRAM 36Kb | 2 | TX + RX各一个(32b×128=4Kb, 实际占1个36Kb) |
| LUT | ~300 | 状态机+地址译码+CDC逻辑 |
| FF | ~200 | 寄存器+CDC同步器+状态 |
| 中断 | 1 | pl_rx_irq → IRQ_F2P[0] |

---

## 十二、设计总结

### 架构优势

- ✅ **分层解耦**：协议层/寄存器层/数据通路层独立，职责清晰
- ✅ **收发隔离**：TX/RX各自独立BRAM+状态机，互不干扰
- ✅ **CDC规范**：6路同步路径全覆盖（toggle/握手/电平三种模式）
- ✅ **AXI合规**：AW/W乱序支持、WSTRB校验、越界DECERR
- ✅ **三段式FSM**：标准编码，可维护性好

### 性能指标

| 指标 | 数值 |
|------|------|
| 单帧最大长度 | 255×16bit = 510字节 |
| TX吞吐率 | 1/3 × 1MHz × 16bit ≈ 5.33Mbps |
| RX吞吐率 | 1MHz × 16bit = 16Mbps |
| AXI读延迟 | 2 cycle (AR握手 + 取数) |
| AXI写延迟 | 2~3 cycle (AW/W缓存 + 执行 + BRESP) |
| CDC同步延迟 | 2~4 cycle (2FF) / 6~10 cycle (握手) |
