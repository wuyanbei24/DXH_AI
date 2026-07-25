# Xilinx 7系列FPGA双向4路LVDS通信设计文档\_V2

**版本**：V2\.0（XPM FIFO优化版）
**适配环境**：Vivado 2018\.3 / Xilinx 7系列FPGA
**文档范围**：需求定义、架构设计、RTL实现、仿真验证、硬件约束全流程

---

## 1 文档概述

### 1\.1 设计背景

本设计针对两片FPGA点对点通信场景，基于Xilinx 7系列FPGA原生SerDes资源，实现**全双工4路LVDS高速串行通信**。设计遵循分层解耦、三段式状态机、可复用可扩展原则，完整覆盖链路训练、主从握手、心跳检测、自动重训练等工业级可靠性功能。

### 1\.2 最终需求清单

|需求类别|具体需求项|
|---|---|
|物理通道|共4路LVDS差分对：FPGA1→FPGA2方向1路时钟\+1路数据；FPGA2→FPGA1方向1路时钟\+1路数据|
|主从架构|FPGA1为主机，FPGA2为从机；上电后两端默认发送训练序列|
|建链流程|从机完成接收链路训练后，通过反向链路通知主机；主机确认双向链路均建立完成后，开启用户数据传输|
|训练机制|每个接收方向独立执行IO延迟校准、位对齐、字对齐全流程自动训练|
|延迟校准|基于IDELAYE2实现32级全量延迟扫描\+最大稳定窗口中心选取算法|
|帧协议|标准化统一帧格式，硬区分训练帧、控制帧、心跳帧、用户数据帧|
|心跳机制|双向链路独立心跳检测，实时监控链路连通性，心跳与用户数据帧间调度|
|重训练机制|支持心跳超时、连续校验错误、外部强制三种触发方式，重训练后自动重建握手|
|编码规范|所有状态机严格遵循三段式设计；FIFO采用Vivado原生XPM\_FIFO\_SYNC原语实现|
|可靠性|帧级原子传输、错误隔离、连续错误触发链路级恢复，保障传输稳定性|

---

## 2 总体架构设计

### 2\.1 系统整体架构

采用**全双工点对点**架构，两片FPGA完全对称，各集成1路发送通道\+1路接收通道，通过4路LVDS差分对互连。每个方向独立完成SerDes、延迟校准、帧解析；新增链路管理模块实现主从握手、建链控制与重训练联动。

```Plaintext
FPGA1(主机)
┌───────────────────────────────────────────────────┐
│  ┌──────────┐          链路管理器(主模式)          │
│  │ 用户逻辑 │◀─────────────┐      ┌──────────────▶│
│  └────┬─────┘              │      │               │
│       │                    │      │               │
│  ┌────▼─────┐         ┌────▼──────▼─────┐         │
│  │ 发送通道 │──▶LVDS  │  接收通道       │◀──LVDS  │
│  │(CLK+DATA)│  输出  │  (CLK+DATA)     │  输入   │
│  └──────────┘         └─────────────────┘         │
└───────────────────────────┬───────────────────────┘
                            │
                     4路LVDS互连
                            │
┌───────────────────────────┴───────────────────────┐
│  FPGA2(从机)                                       │
│  ┌──────────┐         ┌─────────────────┐         │
│  │ 接收通道 │◀──LVDS  │  发送通道       │──▶LVDS  │
│  │(CLK+DATA)│  输入  │  (CLK+DATA)     │  输出   │
│  └────┬─────┘         └─────────────────┘         │
│       │                    ▲                      │
│  ┌────▼─────┐              │                      │
│  │ 用户逻辑 │◀─────────────┘ 链路管理器(从模式)   │
│  └──────────┘                                     │
└───────────────────────────────────────────────────┘
```

### 2\.2 主从角色定义

|角色|核心职责|
|---|---|
|主机FPGA1|1\. 上电发送训练序列；2\. 等待接收从机就绪通知；3\. 确认双向链路就绪后，发起正式数据传输；4\. 统一管控双向链路状态|
|从机FPGA2|1\. 上电发送训练序列；2\. 完成接收链路训练后，通过发送通道回复「从机就绪」控制帧；3\. 收到主机确认帧后，进入正常数据传输模式|

### 2\.3 模块划分与职责

每个FPGA内部包含4个核心模块，收发通道完全复用，仅通过参数配置主从模式：

|模块名|层级|核心职责|
|---|---|---|
|`lvds_tx_channel`|物理发送层|训练序列生成、帧调度、心跳插入、XPM FIFO缓存、OSERDESE2串行化、OBUFDS差分输出|
|`lvds_rx_channel`|物理\+链路接收层|IBUFDS差分输入、IDELAYE2延迟校准、ISERDESE2解串、帧解析、数据/心跳/控制帧分流、重训练检测|
|`lvds_link_manager`|链路控制层|主/从模式可配置，控制训练流程、处理握手帧、管理用户数据使能、联动双向重训练|
|`lvds_bidirectional_top`|顶层|集成收发通道与链路管理器，对外提供统一用户接口与状态输出|

### 2\.4 建链握手全流程

1. **上电复位阶段**：主机、从机发送通道均持续发送训练序列（`8'h55`位训练码\+`8'hB5`字同步字），接收通道启动自动校准。

2. **从机接收就绪**：从机接收通道完成延迟扫描、位对齐、字对齐，物理层锁定，输出`phy_ready`信号。

3. **从机发就绪通知**：从机链路管理器检测到本地接收就绪，控制发送通道周期性发送「从机就绪」控制帧。

4. **主机接收就绪**：主机接收通道完成物理层校准，开始解析帧，成功收到「从机就绪」控制帧。

5. **主机确认建链**：主机判定双向链路均建立，控制发送通道发送「主机确认」控制帧，随后开启用户数据传输与心跳。

6. **从机进入正常态**：从机收到「主机确认」帧，正式进入正常传输模式，开启用户数据接收与心跳检测。

---

## 3 核心机制详细设计

### 3\.1 物理层设计

#### 3\.1\.1 SerDes串行/解串方案

基于Xilinx 7系列原生OSERDESE2/ISERDESE2原语，采用DDR双数据速率模式，串行化因子为8：

- 发送端：8bit并行数据转换为1bit串行数据，随路时钟同步输出

- 接收端：1bit串行数据恢复为8bit并行数据，由随路时钟经BUFIO\+BUFR生成串行时钟与并行时钟

- 串行速率：并行时钟频率 × 8，100MHz并行时钟对应800Mbps串行速率

#### 3\.1\.2 输入延迟校准算法

采用IDELAYE2原语实现32级可调延迟（每级约78ps，总范围约2\.5ns），通过眼图扫描法定位最佳采样点：

1. **全量扫描**：延迟值从0到31逐阶递增，每阶延迟稳定后连续采样16次训练码`8'h55`

2. **有效性判定**：单阶延迟下16次采样全部匹配训练码，标记为有效采样点

3. **最大窗口搜索**：遍历32个采样点，寻找最长连续有效区间

4. **最佳点计算**：取窗口中点作为最终延迟值，最大化采样时序裕量

5. **失败判定**：最大连续有效窗口长度小于4级时，判定校准失败

#### 3\.1\.3 链路训练流程

训练分为两个核心阶段，由三段式状态机全程控制：

1. **位对齐阶段**：发送端持续发送翻转训练码`8'h55`；接收端执行全量延迟扫描，锁定最佳采样延迟

2. **字对齐阶段**：发送端切换发送同步字`8'hB5`；接收端通过BITSLIP指令逐bit移位，连续16次匹配后判定对齐成功

### 3\.2 链路层设计

#### 3\.2\.1 统一帧格式

所有有效传输均遵循标准帧格式，通过`Type`字段硬区分帧类型，帧结构如下：

|字段名|长度\(字节\)|说明|心跳帧|用户数据帧|从机就绪帧|主机确认帧|
|---|---|---|---|---|---|---|
|SOF帧头|2|固定`16'hAA55`帧起始标志|`16'hAA55`|`16'hAA55`|`16'hAA55`|`16'hAA55`|
|Type类型|1|帧类型标识|`8'h10`|`8'h20`|`8'h02`|`8'h03`|
|Length长度|1<br>|Payload字节数|2|0\~255|1|1|
|Payload载荷|N|有效内容|16bit心跳计数器|用户原始数据|8bit链路状态码|8bit确认码|
|Checksum校验|1|帧头\+类型\+长度\+载荷累加和（低8位）|自动计算|自动计算|自动计算|自动计算|

> 空闲填充：非帧传输期间持续发送`8'h55`，维持链路同步，支持重训练时快速锁定。

#### 3\.2\.2 发送端帧调度机制

**调度规则**：

1. 优先级：控制帧 \> 用户数据帧 \> 心跳帧 \> 空闲填充

2. 原子性：任何帧一旦开始发送，必须完整发送完毕，中途不允许切换

3. 心跳防饿死：用户数据连续传输超过2倍心跳周期后，当前帧结束强制优先发送心跳帧

4. 用户数据打包：用户流式数据先进入XPM同步FIFO缓存，按「数据量达最大帧长/缓存超时」规则打包成帧

**调度状态机**：采用三段式设计，状态流转：`TX_IDLE`→`TX_SOF1`→`TX_SOF2`→`TX_TYPE`→`TX_LEN`→`TX_PAYLOAD`→`TX_CHECKSUM`→`TX_IDLE`。

#### 3\.2\.3 接收端帧解析与解复用

1. **帧头锁定**：仅空闲态检测连续`AA`\+`55`判定帧起始，帧体内不检测帧头，避免用户数据误同步

2. **类型分流**：解析Type字段后切换对应分支，用户数据直接输出，心跳送入检测模块，控制帧送入链路管理器

3. **校验收尾**：比对校验和，正确则确认有效，错误则丢弃当前帧并累加错误计数

4. **错误隔离**：单帧错误不影响全局，连续错误达到阈值才触发链路级重训练

#### 3\.2\.4 心跳通讯机制

- 每个发送方向独立维护心跳定时器，按周期插入心跳帧，携带独立递增计数器

- 每个接收方向独立维护心跳超时检测，连续丢失5个心跳周期判定链路断开

- 心跳与用户数据、控制帧共用通道，遵循帧间调度、原子传输规则

- 心跳功能对用户透明，建链完成后自动启动，重训练期间自动暂停

#### 3\.2\.5 重训练机制

**触发条件**（任意方向满足任一即触发全链路重训练）：

1. 心跳超时：连续5个心跳周期未检测到有效心跳帧

2. 连续校验错误：累计10帧校验和错误

3. 外部强制：上层控制信号拉高重训练请求

**执行流程**：

1. 链路管理器检测到异常，拉低用户数据使能，进入重训练状态

2. 复位本端收发通道物理层与链路层状态，发送通道重新输出训练序列

3. 重新执行「单向训练→主从握手→双向建链」全流程

4. 内置重试计数器，连续3次训练失败进入故障锁定状态，需系统复位解除

### 3\.3 链路管理设计

链路管理器支持`MASTER`/`SLAVE`两种模式，通过参数配置，均采用三段式状态机实现握手流程。

#### 主机模式状态机

|状态|功能说明|跳转条件|
|---|---|---|
|`MST_IDLE`|空闲复位|复位后进入`MST_TRAINING`|
|`MST_TRAINING`|训练阶段，发送训练码，等待本地接收锁定|本地接收`phy_ready`拉高后进入`MST_WAIT_SLAVE`|
|`MST_WAIT_SLAVE`|本地接收就绪，等待从机就绪帧|收到「从机就绪」控制帧后进入`MST_LINK_UP`|
|`MST_LINK_UP`|双向建链完成，正常数据传输|检测到重训练请求后进入`MST_RETRAIN`|
|`MST_RETRAIN`|重训练复位，延时后重启训练|延时达到阈值后回到`MST_TRAINING`|

#### 从机模式状态机

|状态|功能说明|跳转条件|
|---|---|---|
|`SLV_IDLE`|空闲复位|复位后进入`SLV_TRAINING`|
|`SLV_TRAINING`|训练阶段，发送训练码，等待本地接收锁定|本地接收`phy_ready`拉高后进入`SLV_SEND_READY`|
|`SLV_SEND_READY`|周期性发送「从机就绪」帧|收到「主机确认」控制帧后进入`SLV_LINK_UP`|
|`SLV_LINK_UP`|建链完成，正常数据传输|检测到重训练请求后进入`SLV_RETRAIN`|
|`SLV_RETRAIN`|重训练复位，延时后重启训练|延时达到阈值后回到`SLV_TRAINING`|

---

## 4 RTL代码实现

### 4\.1 发送通道 `lvds_tx_channel.v`（XPM FIFO优化版）

```Plaintext
`timescale 1ns / 1ps

module lvds_tx_channel #(
    parameter DATA_WIDTH     = 8,
    parameter SERIAL_FACTOR  = 8,
    parameter CLK_FREQ       = 100_000_000,
    parameter HEARTBEAT_MS   = 1,
    parameter MAX_PAYLOAD    = 255,
    parameter USER_FIFO_DEPTH= 512
)(
    input  wire clk_ref,
    input  wire rst_n,
    
    // 链路管理器控制接口
    input  wire train_en,
    input  wire ctrl_frame_send,
    input  wire [7:0] ctrl_frame_type,
    input  wire [7:0] ctrl_frame_payload,
    
    // 用户数据接口
    input  wire [DATA_WIDTH-1:0] tx_data_in,
    input  wire                    tx_data_valid,
    output wire                    tx_ready,
    
    // LVDS差分输出
    output wire lvds_clk_p,
    output wire lvds_clk_n,
    output wire lvds_data_p,
    output wire lvds_data_n
);

// 内部信号定义
localparam TX_IDLE=0, TX_SOF1=1, TX_SOF2=2, TX_TYPE=3, TX_LEN=4, TX_PAYLOAD=5, TX_CHECKSUM=6;
reg [2:0] tx_curr_state, tx_next_state;
reg [7:0] tx_data_mux;
reg [31:0] heartbeat_timer;
reg [15:0] heartbeat_cnt;
reg heartbeat_pending;
reg [7:0] payload_len, payload_cnt, checksum_reg, tx_type_sel;
reg fifo_rd_en;

wire [7:0]  fifo_dout;
wire        fifo_empty;
wire        fifo_full;
wire [8:0]  fifo_data_cnt;

wire clk_ser, clk_div;
wire s_data_out, s_clk_out;

localparam FRAME_SOF1=8'hAA, FRAME_SOF2=8'h55;
localparam TYPE_HB=8'h10, TYPE_USR=8'h20;
localparam HEARTBEAT_CNT_MAX = (CLK_FREQ / 1000) * HEARTBEAT_MS;
localparam HEARTBEAT_PAYLOAD_LEN = 8'd2;

assign clk_div = clk_ref;
assign clk_ser = clk_ref; // 实际工程需MMCM倍频为8倍并行时钟
assign tx_ready = ~fifo_full && ~train_en && (tx_curr_state == TX_IDLE);

// ==================================================
// XPM_FIFO_SYNC 同步FIFO（首字直通模式）
// ==================================================
xpm_fifo_sync #(
    .DOUT_RESET_VALUE    ("0"),
    .ECC_MODE            ("no_ecc"),
    .FIFO_MEMORY_TYPE    ("auto"),
    .FIFO_READ_LATENCY   (0),
    .FIFO_WRITE_DEPTH    (USER_FIFO_DEPTH),
    .FULL_RESET_VALUE    (0),
    .PROG_EMPTY_THRESH   (10),
    .PROG_FULL_THRESH    (10),
    .RD_DATA_COUNT_WIDTH (9),
    .READ_DATA_WIDTH     (DATA_WIDTH),
    .READ_MODE           ("fwft"),
    .SIM_ASSERT_CHK      (0),
    .USE_ADV_FEATURES    ("0000"),
    .WAKEUP_TIME         (0),
    .WRITE_DATA_WIDTH    (DATA_WIDTH),
    .WR_DATA_COUNT_WIDTH (9)
) u_user_fifo (
    .wr_clk         (clk_div),
    .rst            (~rst_n),
    .wr_en          (tx_data_valid),
    .din            (tx_data_in),
    .full           (fifo_full),
    .wr_data_count  (fifo_data_cnt),
    
    .rd_en          (fifo_rd_en),
    .dout           (fifo_dout),
    .empty          (fifo_empty),
    .rd_data_count  (),
    
    .prog_empty     (),
    .prog_full      (),
    .data_valid     (),
    .overflow       (),
    .underflow      (),
    .wr_rst_busy    (),
    .rd_rst_busy    (),
    .injectsbiterr  (1'b0),
    .injectdbiterr  (1'b0),
    .sbiterr        (),
    .dbiterr        ()
);

// 心跳生成逻辑
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        heartbeat_timer <= 32'd0;
        heartbeat_cnt   <= 16'd0;
        heartbeat_pending <= 1'b0;
    end else if(~train_en) begin
        heartbeat_timer <= heartbeat_timer + 1'b1;
        if(heartbeat_timer >= HEARTBEAT_CNT_MAX) begin
            heartbeat_timer   <= 32'd0;
            heartbeat_pending <= 1'b1;
            heartbeat_cnt     <= heartbeat_cnt + 1'b1;
        end
        if(tx_curr_state == TX_CHECKSUM && tx_next_state == TX_IDLE && tx_type_sel == TYPE_HB) begin
            heartbeat_pending <= 1'b0;
        end
    end else begin
        heartbeat_timer   <= 32'd0;
        heartbeat_cnt     <= 16'd0;
        heartbeat_pending <= 1'b0;
    end
end

// 帧调度三段式状态机 - 第一段：状态寄存器
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) tx_curr_state <= TX_IDLE;
    else tx_curr_state <= tx_next_state;
end

// 第二段：次态跳转逻辑
always @(*) begin
    tx_next_state = tx_curr_state;
    if(train_en) begin
        tx_next_state = TX_IDLE;
    end else begin
        case(tx_curr_state)
            TX_IDLE: begin
                if(ctrl_frame_send)          tx_next_state = TX_SOF1;
                else if(~fifo_empty)         tx_next_state = TX_SOF1;
                else if(heartbeat_pending)   tx_next_state = TX_SOF1;
            end
            TX_SOF1:    tx_next_state = TX_SOF2;
            TX_SOF2:    tx_next_state = TX_TYPE;
            TX_TYPE:    tx_next_state = TX_LEN;
            TX_LEN:     tx_next_state = (payload_len == 8'd0) ? TX_CHECKSUM : TX_PAYLOAD;
            TX_PAYLOAD: tx_next_state = (payload_cnt >= payload_len - 1'b1) ? TX_CHECKSUM : TX_PAYLOAD;
            TX_CHECKSUM:tx_next_state = TX_IDLE;
            default:    tx_next_state = TX_IDLE;
        endcase
    end
end

// 第三段：输出与数据控制
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        payload_cnt <= 8'd0;
        payload_len <= 8'd0;
        checksum_reg <= 8'd0;
        tx_type_sel <= 8'd0;
        fifo_rd_en  <= 1'b0;
    end else begin
        fifo_rd_en <= 1'b0;
        case(tx_curr_state)
            TX_IDLE: begin
                payload_cnt <= 8'd0;
                checksum_reg <= 8'd0;
                if(train_en) begin
                    tx_type_sel <= 8'd0;
                    payload_len <= 8'd0;
                end else if(ctrl_frame_send) begin
                    tx_type_sel <= ctrl_frame_type;
                    payload_len <= 8'd1;
                end else if(~fifo_empty) begin
                    tx_type_sel <= TYPE_USR;
                    payload_len <= (fifo_data_cnt > MAX_PAYLOAD) ? MAX_PAYLOAD : fifo_data_cnt[7:0];
                end else if(heartbeat_pending) begin
                    tx_type_sel <= TYPE_HB;
                    payload_len <= HEARTBEAT_PAYLOAD_LEN;
                end
            end
            
            TX_SOF1: checksum_reg <= FRAME_SOF1;
            TX_SOF2: checksum_reg <= checksum_reg + FRAME_SOF2;
            TX_TYPE: checksum_reg <= checksum_reg + tx_type_sel;
            
            TX_LEN: begin
                checksum_reg <= checksum_reg + payload_len;
                if(payload_len != 8'd0 && tx_type_sel == TYPE_USR) begin
                    fifo_rd_en <= 1'b1;
                end
            end
            
            TX_PAYLOAD: begin
                payload_cnt <= payload_cnt + 1'b1;
                case(tx_type_sel)
                    TYPE_USR: begin
                        checksum_reg <= checksum_reg + fifo_dout;
                        fifo_rd_en <= (payload_cnt < payload_len - 1'b1);
                    end
                    TYPE_HB: begin
                        checksum_reg <= checksum_reg + (payload_cnt == 8'd0 ? heartbeat_cnt[15:8] : heartbeat_cnt[7:0]);
                    end
                    default: begin
                        checksum_reg <= checksum_reg + ctrl_frame_payload;
                    end
                endcase
            end
            
            default: ;
        endcase
    end
end

// 发送数据多路选择
always @(*) begin
    if(train_en) begin
        tx_data_mux = 8'h55;
    end else begin
        case(tx_curr_state)
            TX_SOF1:     tx_data_mux = FRAME_SOF1;
            TX_SOF2:     tx_data_mux = FRAME_SOF2;
            TX_TYPE:     tx_data_mux = tx_type_sel;
            TX_LEN:      tx_data_mux = payload_len;
            TX_PAYLOAD: begin
                case(tx_type_sel)
                    TYPE_USR: tx_data_mux = fifo_dout;
                    TYPE_HB:  tx_data_mux = (payload_cnt == 8'd0) ? heartbeat_cnt[15:8] : heartbeat_cnt[7:0];
                    default:  tx_data_mux = ctrl_frame_payload;
                endcase
            end
            TX_CHECKSUM: tx_data_mux = checksum_reg;
            default:     tx_data_mux = 8'h55;
        endcase
    end
end

// OSERDESE2 数据通道串行化
OSERDESE2 #(
    .DATA_RATE_OQ   ("DDR"),
    .DATA_WIDTH     (DATA_WIDTH),
    .SERDES_MODE    ("MASTER"),
    .TRISTATE_WIDTH (1)
) u_oserdes_data (
    .OQ         (s_data_out),
    .CLK        (clk_ser),
    .CLKDIV     (clk_div),
    .D1         (tx_data_mux[0]), .D2(tx_data_mux[1]), .D3(tx_data_mux[2]), .D4(tx_data_mux[3]),
    .D5         (tx_data_mux[4]), .D6(tx_data_mux[5]), .D7(tx_data_mux[6]), .D8(tx_data_mux[7]),
    .OCE        (1'b1),
    .RST        (~rst_n),
    .SHIFTIN1   (1'b0), .SHIFTIN2(1'b0),
    .T1         (1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0),
    .TBYTEIN    (1'b0), .TCE(1'b0)
);

// OSERDESE2 时钟通道串行化
OSERDESE2 #(
    .DATA_RATE_OQ   ("DDR"),
    .DATA_WIDTH     (DATA_WIDTH),
    .SERDES_MODE    ("MASTER"),
    .TRISTATE_WIDTH (1)
) u_oserdes_clk (
    .OQ         (s_clk_out),
    .CLK        (clk_ser),
    .CLKDIV     (clk_div),
    .D1(1'b1), .D2(1'b0), .D3(1'b1), .D4(1'b0), .D5(1'b1), .D6(1'b0), .D7(1'b1), .D8(1'b0),
    .OCE        (1'b1),
    .RST        (~rst_n),
    .SHIFTIN1   (1'b0), .SHIFTIN2(1'b0),
    .T1         (1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0),
    .TBYTEIN    (1'b0), .TCE(1'b0)
);

// OBUFDS 差分输出
OBUFDS #(.IOSTANDARD("LVDS_25"), .SLEW("FAST")) u_obufds_data (
    .O(lvds_data_p), .OB(lvds_data_n), .I(s_data_out)
);
OBUFDS #(.IOSTANDARD("LVDS_25"), .SLEW("FAST")) u_obufds_clk (
    .O(lvds_clk_p), .OB(lvds_clk_n), .I(s_clk_out)
);

endmodule
```

### 4\.2 接收端物理层 `lvds_rx_phy.v`

```Plaintext
`timescale 1ns / 1ps

module lvds_rx_phy #(
    parameter DATA_WIDTH    = 8,
    parameter DELAY_STEPS   = 32,
    parameter SAMPLE_CNT    = 16,
    parameter MIN_WIN_SIZE  = 4
)(
    input  wire rst_n,
    
    // LVDS差分输入
    input  wire lvds_clk_p,
    input  wire lvds_clk_n,
    input  wire lvds_data_p,
    input  wire lvds_data_n,
    
    // 控制接口
    input  wire retrain_req,
    
    // 并行数据输出
    output wire [DATA_WIDTH-1:0] rx_data,
    output wire                    rx_data_valid,
    
    // 状态输出
    output reg  phy_ready,
    output reg  align_err,
    output reg  [4:0] best_delay_val,
    output wire clk_div
);

// 主训练状态机定义
localparam M_IDLE       = 3'd0,
           M_DELAY_SCAN = 3'd1,
           M_BIT_ALIGN  = 3'd2,
           M_WORD_ALIGN = 3'd3,
           M_LOCK_CHECK = 3'd4,
           M_NORMAL     = 3'd5,
           M_FAULT      = 3'd6;

reg [2:0] m_curr_state;
reg [2:0] m_next_state;

// 延迟校准状态机定义
localparam D_IDLE     = 3'd0,
           D_SET_DELAY= 3'd1,
           D_WAIT     = 3'd2,
           D_SAMPLE   = 3'd3,
           D_CALC_WIN = 3'd4,
           D_DONE     = 3'd5;

reg [2:0] d_curr_state;
reg [2:0] d_next_state;

// 内部信号
wire clk_bufio;
wire clk_ibuf;
wire data_ibuf;
wire data_delay;
wire [DATA_WIDTH-1:0] iserdes_q;

reg  delay_ce;
reg  delay_inc;
reg  delay_ld;
reg  [4:0] delay_cnt_val;
wire [4:0] delay_cur_val;

reg  [3:0] sample_cnt;
reg        sample_valid;
reg  [31:0] valid_window;
reg  [4:0]  scan_step;
reg         scan_start;
reg         scan_done;

reg  [3:0] bitslip_cnt;
reg         bitslip_req;
reg  [7:0] align_check_cnt;
reg  [15:0] lock_timer;
reg  [1:0]  retry_cnt;
localparam MAX_RETRY = 2'd3;

// 差分输入缓冲
IBUFDS #(.DIFF_TERM("TRUE"), .IOSTANDARD("LVDS_25")) u_ibufds_data (
    .I(lvds_data_p), .IB(lvds_data_n), .O(data_ibuf)
);
IBUFDS #(.DIFF_TERM("TRUE"), .IOSTANDARD("LVDS_25")) u_ibufds_clk (
    .I(lvds_clk_p), .IB(lvds_clk_n), .O(clk_ibuf)
);

// IDELAYE2 输入延迟单元
IDELAYE2 #(
    .IDELAY_TYPE    ("VARIABLE"),
    .DELAY_SRC      ("IDATAIN"),
    .IDELAY_VALUE   (0),
    .REFCLK_FREQUENCY(200.0),
    .HIGH_PERFORMANCE_MODE("TRUE")
) u_idelay_data (
    .IDATAIN    (data_ibuf),
    .DATAOUT    (data_delay),
    .C          (clk_div),
    .CE         (delay_ce),
    .INC        (delay_inc),
    .LD         (delay_ld),
    .LDPIPEEN   (1'b0),
    .CNTVALUEIN (delay_cnt_val),
    .CNTVALUEOUT(delay_cur_val),
    .DATAIN     (1'b0),
    .CINVCTRL   (1'b0),
    .REGRST     (~rst_n)
);

// 时钟缓冲
BUFIO u_bufio_clk (.I(clk_ibuf), .O(clk_bufio));
BUFR #(.BUFR_DIVIDE("8"), .SIM_DEVICE("7SERIES")) u_bufr_div (
    .I(clk_ibuf), .O(clk_div), .CE(1'b1), .CLR(~rst_n)
);

// ISERDESE2 解串器
ISERDESE2 #(
    .DATA_RATE     ("DDR"),
    .DATA_WIDTH    (DATA_WIDTH),
    .SERDES_MODE   ("MASTER"),
    .INTERFACE_TYPE("NETWORKING"),
    .NUM_CE        (1),
    .IOBDELAY      ("IFD")
) u_iserdes_data (
    .Q1(iserdes_q[0]), .Q2(iserdes_q[1]), .Q3(iserdes_q[2]), .Q4(iserdes_q[3]),
    .Q5(iserdes_q[4]), .Q6(iserdes_q[5]), .Q7(iserdes_q[6]), .Q8(iserdes_q[7]),
    .BITSLIP  (bitslip_req),
    .CE1      (1'b1), .CE2(1'b1),
    .CLK      (clk_bufio),
    .CLKB     (~clk_bufio),
    .CLKDIV   (clk_div),
    .D        (data_delay),
    .RST      (~rst_n),
    .SHIFTIN1 (1'b0), .SHIFTIN2(1'b0),
    .OCLK     (1'b0), .OCLKB(1'b0), .OFB(1'b0)
);

assign rx_data = iserdes_q;
assign rx_data_valid = phy_ready;

// 主训练状态机 - 三段式
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) m_curr_state <= M_IDLE;
    else m_curr_state <= m_next_state;
end

always @(*) begin
    m_next_state = m_curr_state;
    case(m_curr_state)
        M_IDLE:       m_next_state = M_DELAY_SCAN;
        M_DELAY_SCAN: if(scan_done) m_next_state = (|best_delay_val) ? M_BIT_ALIGN : M_FAULT;
        M_BIT_ALIGN:  m_next_state = M_WORD_ALIGN;
        M_WORD_ALIGN: if(align_check_cnt >= 8'd16) m_next_state = M_LOCK_CHECK;
        M_LOCK_CHECK: if(lock_timer >= 16'd5000) m_next_state = (iserdes_q == 8'hB5) ? M_NORMAL : M_FAULT;
        M_NORMAL:     if(retrain_req) m_next_state = M_IDLE;
        M_FAULT:      if(retry_cnt < MAX_RETRY) m_next_state = M_IDLE;
        default:      m_next_state = M_IDLE;
    endcase
end

always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        phy_ready <= 1'b0;
        align_err <= 1'b0;
        scan_start <= 1'b0;
        lock_timer <= 16'd0;
        retry_cnt <= 2'd0;
        align_check_cnt <= 8'd0;
        bitslip_req <= 1'b0;
        bitslip_cnt <= 4'd0;
    end else begin
        case(m_curr_state)
            M_IDLE: begin
                phy_ready <= 1'b0;
                align_err <= 1'b0;
                scan_start <= 1'b1;
                lock_timer <= 16'd0;
                align_check_cnt <= 8'd0;
                bitslip_cnt <= 4'd0;
            end
            M_DELAY_SCAN: begin
                scan_start <= 1'b0;
                retry_cnt <= retry_cnt + 1'b1;
            end
            M_BIT_ALIGN: begin
                bitslip_cnt <= 4'd0;
                align_check_cnt <= 8'd0;
            end
            M_WORD_ALIGN: begin
                bitslip_req <= 1'b0;
                if(iserdes_q == 8'hB5) begin
                    align_check_cnt <= align_check_cnt + 1'b1;
                end else begin
                    align_check_cnt <= 8'd0;
                    bitslip_req <= 1'b1;
                    bitslip_cnt <= bitslip_cnt + 1'b1;
                end
            end
            M_LOCK_CHECK: lock_timer <= lock_timer + 1'b1;
            M_NORMAL: begin
                phy_ready <= 1'b1;
                align_err <= 1'b0;
                retry_cnt <= 2'd0;
            end
            M_FAULT: begin
                phy_ready <= 1'b0;
                align_err <= 1'b1;
            end
            default: ;
        endcase
    end
end

// 延迟校准状态机 - 三段式
always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) d_curr_state <= D_IDLE;
    else d_curr_state <= d_next_state;
end

always @(*) begin
    d_next_state = d_curr_state;
    case(d_curr_state)
        D_IDLE:     if(scan_start) d_next_state = D_SET_DELAY;
        D_SET_DELAY:d_next_state = D_WAIT;
        D_WAIT:     if(sample_cnt >= SAMPLE_CNT[3:0]) d_next_state = D_SAMPLE;
        D_SAMPLE:   d_next_state = (scan_step >= DELAY_STEPS - 1) ? D_CALC_WIN : D_SET_DELAY;
        D_CALC_WIN: d_next_state = D_DONE;
        D_DONE:     if(!scan_start) d_next_state = D_IDLE;
        default:    d_next_state = D_IDLE;
    endcase
end

always @(posedge clk_div or negedge rst_n) begin
    if(!rst_n) begin
        delay_ce <= 1'b0;
        delay_inc <= 1'b0;
        delay_ld <= 1'b0;
        delay_cnt_val <= 5'd0;
        scan_step <= 5'd0;
        sample_cnt <= 4'd0;
        sample_valid <= 1'b1;
        valid_window <= 32'd0;
        scan_done <= 1'b0;
        best_delay_val <= 5'd0;
    end else begin
        delay_ce <= 1'b0;
        delay_ld <= 1'b0;
        
        case(d_curr_state)
            D_IDLE: begin
                scan_step <= 5'd0;
                sample_cnt <= 4'd0;
                valid_window <= 32'd0;
                scan_done <= 1'b0;
                best_delay_val <= 5'd0;
            end
            D_SET_DELAY: begin
                delay_cnt_val <= scan_step;
                delay_ld <= 1'b1;
                sample_cnt <= 4'd0;
                sample_valid <= 1'b1;
            end
            D_WAIT: begin
                sample_cnt <= sample_cnt + 1'b1;
                if(iserdes_q != 8'h55) sample_valid <= 1'b0;
            end
            D_SAMPLE: begin
                valid_window[scan_step] <= sample_valid;
                scan_step <= scan_step + 1'b1;
            end
            D_CALC_WIN: begin
                begin : find_max_window
                    reg [4:0] curr_start, curr_len, max_start, max_len;
                    integer i;
                    curr_start = 5'd0; curr_len = 5'd0;
                    max_start  = 5'd0; max_len  = 5'd0;
                    
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
                    
                    if(max_len >= MIN_WIN_SIZE)
                        best_delay_val <= max_start + (max_len >> 1);
                    else
                        best_delay_val <= 5'd0;
                end
            end
            D_DONE: begin
                scan_done <= 1'b1;
                delay_cnt_val <= best_delay_val;
                delay_ld <= 1'b1;
            end
            default: ;
        endcase
    end
end

endmodule
```

### 4\.3 接收端链路层 `lvds_rx_link.v`

```Plaintext
`timescale 1ns / 1ps

module lvds_rx_link #(
    parameter DATA_WIDTH = 8,
    parameter HEARTBEAT_TIMEOUT_CNT = 16'd50000,
    parameter MAX_ERR_CNT = 4'd10
)(
    input  wire clk,
    input  wire rst_n,
    
    // 物理层输入
    input  wire [DATA_WIDTH-1:0] rx_data_in,
    input  wire                    rx_data_valid,
    input  wire                    phy_ready,
    
    // 用户数据输出
    output reg  [DATA_WIDTH-1:0] rx_data_out,
    output reg                    rx_data_out_valid,
    
    // 控制帧输出
    output reg                    ctrl_frame_valid,
    output reg  [7:0]             ctrl_frame_type,
    output reg  [7:0]             ctrl_frame_payload,
    
    // 控制与状态
    output reg  retrain_req,
    output reg  link_up,
    output reg  heartbeat_err,
    output reg  [15:0] heartbeat_recv_cnt
);

// 帧解析状态机定义
localparam F_IDLE     = 3'd0,
           F_SOF1     = 3'd1,
           F_SOF2     = 3'd2,
           F_TYPE     = 3'd3,
           F_LEN      = 3'd4,
           F_PAYLOAD  = 3'd5,
           F_CHECKSUM = 3'd6,
           F_DONE     = 3'd7;

reg [2:0] f_curr_state;
reg [2:0] f_next_state;

// 内部信号
reg [7:0] frame_type;
reg [7:0] frame_len;
reg [7:0] payload_cnt;
reg [7:0] checksum_calc;
reg [3:0] frame_err_cnt;

reg [15:0] heartbeat_timer;
reg [3:0]  heartbeat_miss_cnt;

localparam SOF_BYTE1 = 8'hAA;
localparam SOF_BYTE2 = 8'h55;
localparam TYPE_HB   = 8'h10;
localparam TYPE_USR  = 8'h20;

// 帧解析状态机 - 三段式
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        f_curr_state <= F_IDLE;
    else if(phy_ready && rx_data_valid)
        f_curr_state <= f_next_state;
end

always @(*) begin
    f_next_state = f_curr_state;
    case(f_curr_state)
        F_IDLE: if(rx_data_in == SOF_BYTE1) f_next_state = F_SOF1;
        F_SOF1: f_next_state = (rx_data_in == SOF_BYTE2) ? F_SOF2 : F_IDLE;
        F_SOF2: f_next_state = F_TYPE;
        F_TYPE: f_next_state = F_LEN;
        F_LEN:  f_next_state = (frame_len == 8'd0) ? F_CHECKSUM : F_PAYLOAD;
        F_PAYLOAD: if(payload_cnt >= frame_len - 1'b1) f_next_state = F_CHECKSUM;
        F_CHECKSUM: f_next_state = F_DONE;
        F_DONE: f_next_state = F_IDLE;
        default: f_next_state = F_IDLE;
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        frame_type <= 8'd0;
        frame_len <= 8'd0;
        payload_cnt <= 8'd0;
        checksum_calc <= 8'd0;
        rx_data_out <= 8'd0;
        rx_data_out_valid <= 1'b0;
        ctrl_frame_valid <= 1'b0;
        ctrl_frame_type <= 8'd0;
        ctrl_frame_payload <= 8'd0;
        frame_err_cnt <= 4'd0;
        heartbeat_recv_cnt <= 16'd0;
        heartbeat_timer <= 16'd0;
        heartbeat_miss_cnt <= 4'd0;
        retrain_req <= 1'b0;
        link_up <= 1'b0;
        heartbeat_err <= 1'b0;
    end else if(!phy_ready) begin
        frame_type <= 8'd0;
        frame_len <= 8'd0;
        payload_cnt <= 8'd0;
        checksum_calc <= 8'd0;
        rx_data_out_valid <= 1'b0;
        ctrl_frame_valid <= 1'b0;
        frame_err_cnt <= 4'd0;
        heartbeat_timer <= 16'd0;
        heartbeat_miss_cnt <= 4'd0;
        retrain_req <= 1'b0;
        link_up <= 1'b0;
        heartbeat_err <= 1'b0;
    end else if(rx_data_valid) begin
        rx_data_out_valid <= 1'b0;
        ctrl_frame_valid <= 1'b0;
        heartbeat_timer <= heartbeat_timer + 1'b1;
        
        case(f_curr_state)
            F_IDLE: begin
                checksum_calc <= rx_data_in;
                payload_cnt <= 8'd0;
            end
            
            F_SOF1: checksum_calc <= checksum_calc + rx_data_in;
            
            F_SOF2: begin
                frame_type <= rx_data_in;
                checksum_calc <= checksum_calc + rx_data_in;
            end
            
            F_TYPE: begin
                frame_len <= rx_data_in;
                checksum_calc <= checksum_calc + rx_data_in;
                payload_cnt <= 8'd0;
            end
            
            F_LEN: begin
                if(frame_len != 8'd0) begin
                    payload_cnt <= payload_cnt + 1'b1;
                    checksum_calc <= checksum_calc + rx_data_in;
                    
                    case(frame_type)
                        TYPE_USR: begin
                            rx_data_out <= rx_data_in;
                            rx_data_out_valid <= 1'b1;
                        end
                        TYPE_HB: begin
                            if(payload_cnt == 8'd0) heartbeat_recv_cnt[15:8] <= rx_data_in;
                            else heartbeat_recv_cnt[7:0] <= rx_data_in;
                        end
                        default: begin // 控制帧
                            ctrl_frame_payload <= rx_data_in;
                        end
                    endcase
                end
            end
            
            F_PAYLOAD: begin
                payload_cnt <= payload_cnt + 1'b1;
                checksum_calc <= checksum_calc + rx_data_in;
                
                case(frame_type)
                    TYPE_USR: begin
                        rx_data_out <= rx_data_in;
                        rx_data_out_valid <= 1'b1;
                    end
                    TYPE_HB: begin
                        if(payload_cnt == 8'd0) heartbeat_recv_cnt[15:8] <= rx_data_in;
                        else heartbeat_recv_cnt[7:0] <= rx_data_in;
                    end
                    default: begin
                        ctrl_frame_payload <= rx_data_in;
                    end
                endcase
            end
            
            F_CHECKSUM: begin
                if(rx_data_in == checksum_calc) begin
                    frame_err_cnt <= 4'd0;
                    if(frame_type == TYPE_HB) begin
                        heartbeat_timer <= 16'd0;
                        heartbeat_miss_cnt <= 4'd0;
                        heartbeat_err <= 1'b0;
                        link_up <= 1'b1;
                    end
                end else begin
                    frame_err_cnt <= frame_err_cnt + 1'b1;
                end
            end
            
            F_DONE: begin
                // 控制帧输出脉冲
                if(frame_type != TYPE_HB && frame_type != TYPE_USR) begin
                    ctrl_frame_valid <= 1'b1;
                    ctrl_frame_type <= frame_type;
                end
                // 连续错误触发重训练
                if(frame_err_cnt >= MAX_ERR_CNT) retrain_req <= 1'b1;
            end
            
            default: ;
        endcase
        
        // 心跳超时检测
        if(heartbeat_timer >= HEARTBEAT_TIMEOUT_CNT) begin
            heartbeat_timer <= 16'd0;
            heartbeat_miss_cnt <= heartbeat_miss_cnt + 1'b1;
            if(heartbeat_miss_cnt >= 4'd5) begin
                heartbeat_err <= 1'b1;
                retrain_req <= 1'b1;
            end
        end
        
        if(retrain_req) retrain_req <= 1'b0;
    end
end

endmodule
```

### 4\.4 接收通道顶层 `lvds_rx_channel.v`

```Plaintext
`timescale 1ns / 1ps

module lvds_rx_channel #(
    parameter DATA_WIDTH = 8,
    parameter DELAY_STEPS = 32,
    parameter SAMPLE_CNT  = 16,
    parameter MIN_WIN_SIZE= 4,
    parameter HEARTBEAT_TIMEOUT_CNT = 16'd50000,
    parameter MAX_ERR_CNT = 4'd10
)(
    input  wire rst_n,
    
    // LVDS差分输入
    input  wire lvds_clk_p,
    input  wire lvds_clk_n,
    input  wire lvds_data_p,
    input  wire lvds_data_n,
    
    // 重训练控制
    input  wire retrain_req,
    
    // 用户数据输出
    output wire clk_div,
    output wire [DATA_WIDTH-1:0] rx_data_out,
    output wire                    rx_data_valid,
    
    // 控制帧输出
    output wire                    ctrl_frame_valid,
    output wire [7:0]             ctrl_frame_type,
    output wire [7:0]             ctrl_frame_payload,
    
    // 状态输出
    output wire phy_ready,
    output wire link_up,
    output wire heartbeat_err,
    output wire align_err,
    output wire retrain_trigger
);

wire [DATA_WIDTH-1:0] phy_data;
wire phy_valid;
wire retrain_req_inner;

assign retrain_trigger = retrain_req_inner;

lvds_rx_phy #(
    .DATA_WIDTH(DATA_WIDTH), .DELAY_STEPS(DELAY_STEPS),
    .SAMPLE_CNT(SAMPLE_CNT), .MIN_WIN_SIZE(MIN_WIN_SIZE)
) u_phy (
    .rst_n(rst_n),
    .lvds_clk_p(lvds_clk_p), .lvds_clk_n(lvds_clk_n),
    .lvds_data_p(lvds_data_p), .lvds_data_n(lvds_data_n),
    .retrain_req(retrain_req),
    .rx_data(phy_data), .rx_data_valid(phy_valid),
    .phy_ready(phy_ready), .align_err(align_err),
    .best_delay_val(), .clk_div(clk_div)
);

lvds_rx_link #(
    .DATA_WIDTH(DATA_WIDTH),
    .HEARTBEAT_TIMEOUT_CNT(HEARTBEAT_TIMEOUT_CNT),
    .MAX_ERR_CNT(MAX_ERR_CNT)
) u_link (
    .clk(clk_div), .rst_n(rst_n),
    .rx_data_in(phy_data), .rx_data_valid(phy_valid), .phy_ready(phy_ready),
    .rx_data_out(rx_data_out), .rx_data_out_valid(rx_data_valid),
    .retrain_req(retrain_req_inner),
    .link_up(link_up), .heartbeat_err(heartbeat_err),
    .heartbeat_recv_cnt(),
    .ctrl_frame_valid(ctrl_frame_valid),
    .ctrl_frame_type(ctrl_frame_type),
    .ctrl_frame_payload(ctrl_frame_payload)
);

endmodule
```

### 4\.5 链路管理模块 `lvds_link_manager.v`

```Plaintext
`timescale 1ns / 1ps

module lvds_link_manager #(
    parameter IS_MASTER = 1  // 1=主机模式，0=从机模式
)(
    input  wire clk,
    input  wire rst_n,
    
    // 接收通道状态
    input  wire rx_phy_ready,
    input  wire rx_link_up,
    input  wire rx_retrain_req,
    input  wire ctrl_frame_valid,
    input  wire [7:0] ctrl_frame_type,
    input  wire [7:0] ctrl_frame_payload,
    
    // 发送通道控制
    output reg  tx_train_en,
    output reg  ctrl_frame_send,
    output reg  [7:0] ctrl_frame_type_out,
    output reg  [7:0] ctrl_frame_payload_out,
    
    // 用户数据使能
    output reg  user_tx_en,
    output reg  user_rx_en,
    
    // 外部控制
    input  wire ext_retrain_req,
    output reg  link_all_up
);

localparam S_IDLE     = 3'd0,
           S_TRAINING = 3'd1,
           S_WAIT_PEER= 3'd2,
           S_LINK_UP  = 3'd3,
           S_RETRAIN  = 3'd4;

reg [2:0] curr_state;
reg [2:0] next_state;

reg [15:0] retrain_timer;
reg [15:0] ctrl_send_timer;
localparam CTRL_SEND_INTERVAL = 16'd1000;
localparam RETRAIN_WAIT_CYCLES = 16'd1000;

localparam TYPE_SLAVE_READY = 8'h02;
localparam TYPE_MASTER_ACK  = 8'h03;

// 三段式状态机 - 第一段：状态寄存器
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) curr_state <= S_IDLE;
    else curr_state <= next_state;
end

// 第二段：次态跳转
always @(*) begin
    next_state = curr_state;
    case(curr_state)
        S_IDLE: begin
            next_state = S_TRAINING;
        end
        
        S_TRAINING: begin
            if(rx_phy_ready) begin
                next_state = S_WAIT_PEER;
            end
        end
        
        S_WAIT_PEER: begin
            if(IS_MASTER) begin
                if(ctrl_frame_valid && ctrl_frame_type == TYPE_SLAVE_READY) begin
                    next_state = S_LINK_UP;
                end
            end else begin
                if(ctrl_frame_valid && ctrl_frame_type == TYPE_MASTER_ACK) begin
                    next_state = S_LINK_UP;
                end
            end
        end
        
        S_LINK_UP: begin
            if(rx_retrain_req || ext_retrain_req) begin
                next_state = S_RETRAIN;
            end
        end
        
        S_RETRAIN: begin
            if(retrain_timer >= RETRAIN_WAIT_CYCLES) begin
                next_state = S_TRAINING;
            end
        end
        
        default: next_state = S_IDLE;
    endcase
end

// 第三段：输出控制
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        tx_train_en <= 1'b1;
        ctrl_frame_send <= 1'b0;
        ctrl_frame_type_out <= 8'd0;
        ctrl_frame_payload_out <= 8'd0;
        user_tx_en <= 1'b0;
        user_rx_en <= 1'b0;
        link_all_up <= 1'b0;
        retrain_timer <= 16'd0;
        ctrl_send_timer <= 16'd0;
    end else begin
        ctrl_frame_send <= 1'b0;
        
        case(curr_state)
            S_IDLE: begin
                tx_train_en <= 1'b1;
                user_tx_en <= 1'b0;
                user_rx_en <= 1'b0;
                link_all_up <= 1'b0;
                retrain_timer <= 16'd0;
            end
            
            S_TRAINING: begin
                tx_train_en <= 1'b1;
                user_tx_en <= 1'b0;
                user_rx_en <= 1'b0;
                link_all_up <= 1'b0;
                ctrl_send_timer <= 16'd0;
            end
            
            S_WAIT_PEER: begin
                tx_train_en <= 1'b0;
                user_tx_en <= 1'b0;
                user_rx_en <= 1'b0;
                link_all_up <= 1'b0;
                
                ctrl_send_timer <= ctrl_send_timer + 1'b1;
                if(ctrl_send_timer >= CTRL_SEND_INTERVAL) begin
                    ctrl_send_timer <= 16'd0;
                    ctrl_frame_send <= 1'b1;
                    
                    if(IS_MASTER) begin
                        ctrl_frame_type_out <= TYPE_MASTER_ACK;
                        ctrl_frame_payload_out <= 8'h01;
                    end else begin
                        ctrl_frame_type_out <= TYPE_SLAVE_READY;
                        ctrl_frame_payload_out <= 8'h01;
                    end
                end
            end
            
            S_LINK_UP: begin
                tx_train_en <= 1'b0;
                user_tx_en <= 1'b1;
                user_rx_en <= 1'b1;
                link_all_up <= 1'b1;
                ctrl_send_timer <= 16'd0;
            end
            
            S_RETRAIN: begin
                tx_train_en <= 1'b1;
                user_tx_en <= 1'b0;
                user_rx_en <= 1'b0;
                link_all_up <= 1'b0;
                retrain_timer <= retrain_timer + 1'b1;
            end
            
            default: ;
        endcase
    end
end

endmodule
```

### 4\.6 双向顶层模块 `lvds_bidirectional_top.v`

```Plaintext
`timescale 1ns / 1ps

module lvds_bidirectional_top #(
    parameter IS_MASTER = 1,
    parameter DATA_WIDTH = 8,
    parameter CLK_FREQ = 100_000_000
)(
    input  wire clk_ref,
    input  wire rst_n,
    
    // 发送方向：本端→对端
    output wire tx_lvds_clk_p, output wire tx_lvds_clk_n,
    output wire tx_lvds_data_p, output wire tx_lvds_data_n,
    
    // 接收方向：对端→本端
    input  wire rx_lvds_clk_p, input  wire rx_lvds_clk_n,
    input  wire rx_lvds_data_p, input  wire rx_lvds_data_n,
    
    // 用户数据发送接口
    input  wire [DATA_WIDTH-1:0] user_tx_data,
    input  wire                    user_tx_valid,
    output wire                    user_tx_ready,
    
    // 用户数据接收接口
    output wire [DATA_WIDTH-1:0] user_rx_data,
    output wire                    user_rx_valid,
    
    // 状态与控制
    input  wire ext_retrain_req,
    output wire link_all_up,
    output wire heartbeat_err,
    output wire align_err
);

wire tx_train_en;
wire ctrl_frame_send;
wire [7:0] ctrl_frame_type_out;
wire [7:0] ctrl_frame_payload_out;
wire rx_clk_div;
wire rx_phy_ready;
wire rx_link_up;
wire rx_retrain_req;
wire ctrl_frame_valid;
wire [7:0] ctrl_frame_type;
wire [7:0] ctrl_frame_payload;
wire user_tx_en;
wire user_rx_en;

// 发送通道
lvds_tx_channel #(
    .DATA_WIDTH(DATA_WIDTH), .CLK_FREQ(CLK_FREQ)
) u_tx (
    .clk_ref(clk_ref), .rst_n(rst_n),
    .train_en(tx_train_en),
    .ctrl_frame_send(ctrl_frame_send),
    .ctrl_frame_type(ctrl_frame_type_out),
    .ctrl_frame_payload(ctrl_frame_payload_out),
    .tx_data_in(user_tx_data),
    .tx_data_valid(user_tx_valid & user_tx_en),
    .tx_ready(user_tx_ready),
    .lvds_clk_p(tx_lvds_clk_p), .lvds_clk_n(tx_lvds_clk_n),
    .lvds_data_p(tx_lvds_data_p), .lvds_data_n(tx_lvds_data_n)
);

// 接收通道
lvds_rx_channel #(
    .DATA_WIDTH(DATA_WIDTH)
) u_rx (
    .rst_n(rst_n),
    .lvds_clk_p(rx_lvds_clk_p), .lvds_clk_n(rx_lvds_clk_n),
    .lvds_data_p(rx_lvds_data_p), .lvds_data_n(rx_lvds_data_n),
    .retrain_req(ext_retrain_req),
    .clk_div(rx_clk_div),
    .rx_data_out(user_rx_data),
    .rx_data_valid(user_rx_valid & user_rx_en),
    .ctrl_frame_valid(ctrl_frame_valid),
    .ctrl_frame_type(ctrl_frame_type),
    .ctrl_frame_payload(ctrl_frame_payload),
    .phy_ready(rx_phy_ready),
    .link_up(rx_link_up),
    .heartbeat_err(heartbeat_err),
    .align_err(align_err),
    .retrain_trigger(rx_retrain_req)
);

// 链路管理器
lvds_link_manager #(
    .IS_MASTER(IS_MASTER)
) u_link_mgr (
    .clk(clk_ref), .rst_n(rst_n),
    .rx_phy_ready(rx_phy_ready),
    .rx_link_up(rx_link_up),
    .rx_retrain_req(rx_retrain_req),
    .ctrl_frame_valid(ctrl_frame_valid),
    .ctrl_frame_type(ctrl_frame_type),
    .ctrl_frame_payload(ctrl_frame_payload),
    .tx_train_en(tx_train_en),
    .ctrl_frame_send(ctrl_frame_send),
    .ctrl_frame_type_out(ctrl_frame_type_out),
    .ctrl_frame_payload_out(ctrl_frame_payload_out),
    .user_tx_en(user_tx_en),
    .user_rx_en(user_rx_en),
    .ext_retrain_req(ext_retrain_req),
    .link_all_up(link_all_up)
);

endmodule
```

---

## 5 仿真验证方案

### 5\.1 仿真环境架构

Testbench中例化**主机DUT \+ 从机DUT**，通过4路LVDS信号互连，内置链路延迟模型、故障注入模块、双向数据自动比对逻辑，覆盖建链、传输、故障全场景。

### 5\.2 测试场景总览

|场景编号|测试场景|验证目标|
|---|---|---|
|1|双向建链握手测试|上电后自动完成双向训练、主从握手，`link_all_up`正确拉高|
|2|双向用户数据传输|主机、从机同时发送数据，双向均零错误|
|3|心跳与数据混合传输|双向心跳周期稳定，与用户数据调度无冲突|
|4|正向链路故障重训练|断开主机→从机方向，验证超时触发重训练，恢复后自动握手建链|
|5|反向链路故障重训练|断开从机→主机方向，验证重训练与握手恢复|
|6|外部强制重训练|主机触发外部重训练，双向复位后重新完成握手建链|

### 5\.3 完整Testbench代码

```Plaintext
`timescale 1ns / 1ps

module lvds_bidirectional_tb;

localparam CLK_PERIOD = 10;
localparam DATA_WIDTH = 8;

reg clk_ref_master;
reg clk_ref_slave;
reg rst_n;

// 主机接口
reg  [DATA_WIDTH-1:0] mst_tx_data;
reg                    mst_tx_valid;
wire                   mst_tx_ready;
wire [DATA_WIDTH-1:0] mst_rx_data;
wire                   mst_rx_valid;
wire                   mst_link_up;
wire                   mst_hb_err;
wire                   mst_align_err;
reg                    mst_ext_retrain;

// 从机接口
reg  [DATA_WIDTH-1:0] slv_tx_data;
reg                    slv_tx_valid;
wire                   slv_tx_ready;
wire [DATA_WIDTH-1:0] slv_rx_data;
wire                   slv_rx_valid;
wire                   slv_link_up;
wire                   slv_hb_err;
wire                   slv_align_err;

// LVDS互连信号
wire m2s_clk_p, m2s_clk_n, m2s_data_p, m2s_data_n;
wire s2m_clk_p, s2m_clk_n, s2m_data_p, s2m_data_n;

// 故障注入信号
reg link_m2s_disable;
reg link_s2m_disable;

// 比对队列
reg [7:0] mst_send_queue [$];
reg [7:0] slv_send_queue [$];
integer mst_err_cnt, slv_err_cnt;
integer test_pass, test_fail;

// 时钟与复位
initial begin
    clk_ref_master = 1'b0;
    clk_ref_slave  = 1'b0;
    fork
        forever #(CLK_PERIOD/2) clk_ref_master = ~clk_ref_master;
        forever #(CLK_PERIOD/2) clk_ref_slave  = ~clk_ref_slave;
    join
end

initial begin
    rst_n = 1'b0;
    #200;
    rst_n = 1'b1;
end

// 链路延迟与故障注入
wire m2s_data_p_dly, m2s_data_n_dly;
wire s2m_data_p_dly, s2m_data_n_dly;

assign #2.5 m2s_data_p_dly = m2s_data_p;
assign #2.5 m2s_data_n_dly = m2s_data_n;
assign #2.5 s2m_data_p_dly = s2m_data_p;
assign #2.5 s2m_data_n_dly = s2m_data_n;

assign m2s_data_p_final = link_m2s_disable ? 1'b0 : m2s_data_p_dly;
assign m2s_data_n_final = link_m2s_disable ? 1'b1 : m2s_data_n_dly;
assign s2m_data_p_final = link_s2m_disable ? 1'b0 : s2m_data_p_dly;
assign s2m_data_n_final = link_s2m_disable ? 1'b1 : s2m_data_n_dly;

// 主机DUT
lvds_bidirectional_top #(
    .IS_MASTER(1), .DATA_WIDTH(DATA_WIDTH)
) u_master (
    .clk_ref(clk_ref_master), .rst_n(rst_n),
    .tx_lvds_clk_p(m2s_clk_p), .tx_lvds_clk_n(m2s_clk_n),
    .tx_lvds_data_p(m2s_data_p), .tx_lvds_data_n(m2s_data_n),
    .rx_lvds_clk_p(s2m_clk_p), .rx_lvds_clk_n(s2m_clk_n),
    .rx_lvds_data_p(s2m_data_p_final), .rx_lvds_data_n(s2m_data_n_final),
    .user_tx_data(mst_tx_data), .user_tx_valid(mst_tx_valid), .user_tx_ready(mst_tx_ready),
    .user_rx_data(mst_rx_data), .user_rx_valid(mst_rx_valid),
    .ext_retrain_req(mst_ext_retrain),
    .link_all_up(mst_link_up), .heartbeat_err(mst_hb_err), .align_err(mst_align_err)
);

// 从机DUT
lvds_bidirectional_top #(
    .IS_MASTER(0), .DATA_WIDTH(DATA_WIDTH)
) u_slave (
    .clk_ref(clk_ref_slave), .rst_n(rst_n),
    .tx_lvds_clk_p(s2m_clk_p), .tx_lvds_clk_n(s2m_clk_n),
    .tx_lvds_data_p(s2m_data_p), .tx_lvds_data_n(s2m_data_n),
    .rx_lvds_clk_p(m2s_clk_p), .rx_lvds_clk_n(m2s_clk_n),
    .rx_lvds_data_p(m2s_data_p_final), .rx_lvds_data_n(m2s_data_n_final),
    .user_tx_data(slv_tx_data), .user_tx_valid(slv_tx_valid), .user_tx_ready(slv_tx_ready),
    .user_rx_data(slv_rx_data), .user_rx_valid(slv_rx_valid),
    .ext_retrain_req(1'b0),
    .link_all_up(slv_link_up), .heartbeat_err(slv_hb_err), .align_err(slv_align_err)
);

// 自动比对逻辑
always @(posedge clk_ref_slave) begin
    if(slv_rx_valid && slv_link_up) begin
        if(mst_send_queue.size() == 0) mst_err_cnt = mst_err_cnt + 1;
        else if(slv_rx_data !== mst_send_queue.pop_front()) mst_err_cnt = mst_err_cnt + 1;
    end
end

always @(posedge clk_ref_master) begin
    if(mst_rx_valid && mst_link_up) begin
        if(slv_send_queue.size() == 0) slv_err_cnt = slv_err_cnt + 1;
        else if(mst_rx_data !== slv_send_queue.pop_front()) slv_err_cnt = slv_err_cnt + 1;
    end
end

// 测试任务
task wait_both_link_up;
    begin
        $display("\n[%0t] 等待双向链路建链...", $time);
        wait(mst_link_up && slv_link_up);
        repeat(200) @(posedge clk_ref_master);
        $display("[%0t] 双向链路建链成功", $time);
    end
endtask

task send_master_data;
    input integer len;
    integer i;
    begin
        wait(mst_tx_ready);
        for(i = 0; i < len; i = i + 1) begin
            @(posedge clk_ref_master);
            mst_tx_valid = 1'b1;
            mst_tx_data = i[7:0];
            mst_send_queue.push_back(i[7:0]);
        end
        @(posedge clk_ref_master);
        mst_tx_valid = 1'b0;
    end
endtask

task send_slave_data;
    input integer len;
    integer i;
    begin
        wait(slv_tx_ready);
        for(i = 0; i < len; i = i + 1) begin
            @(posedge clk_ref_slave);
            slv_tx_valid = 1'b1;
            slv_tx_data = i[7:0];
            slv_send_queue.push_back(i[7:0]);
        end
        @(posedge clk_ref_slave);
        slv_tx_valid = 1'b0;
    end
endtask

// 主测试流程
initial begin
    mst_tx_data = 0; mst_tx_valid = 0;
    slv_tx_data = 0; slv_tx_valid = 0;
    link_m2s_disable = 0; link_s2m_disable = 0;
    mst_ext_retrain = 0;
    mst_err_cnt = 0; slv_err_cnt = 0;
    test_pass = 0; test_fail = 0;
    
    $display("==================================================");
    $display("  双向4路LVDS通信仿真测试开始");
    $display("==================================================");
    wait(rst_n);
    
    // 场景1：建链握手测试
    $display("\n--- 场景1：双向建链握手 ---");
    wait_both_link_up();
    if(mst_link_up && slv_link_up) begin
        $display("✓ 场景1通过");
        test_pass = test_pass + 1;
    end else begin
        $display("✗ 场景1失败");
        test_fail = test_fail + 1;
    end
    
    // 场景2：双向数据传输
    $display("\n--- 场景2：双向数据传输 ---");
    fork
        send_master_data(256);
        send_slave_data(256);
    join
    wait(mst_send_queue.size() == 0 && slv_send_queue.size() == 0);
    if(mst_err_cnt == 0 && slv_err_cnt == 0) begin
        $display("✓ 场景2通过：双向数据零错误");
        test_pass = test_pass + 1;
    end else begin
        $display("✗ 场景2失败");
        test_fail = test_fail + 1;
    end
    
    // 场景3：心跳混合传输
    $display("\n--- 场景3：心跳与数据混合 ---");
    #2000000;
    if(mst_hb_err == 0 && slv_hb_err == 0) begin
        $display("✓ 场景3通过：双向心跳正常");
        test_pass = test_pass + 1;
    end else begin
        $display("✗ 场景3失败");
        test_fail = test_fail + 1;
    end
    
    // 场景4：正向链路故障重训练
    $display("\n--- 场景4：正向链路故障重训练 ---");
    mst_err_cnt = 0;
    link_m2s_disable = 1'b1;
    wait(~slv_link_up);
    #10000;
    link_m2s_disable = 1'b0;
    wait_both_link_up();
    send_master_data(128);
    wait(mst_send_queue.size() == 0);
    if(mst_err_cnt == 0) begin
        $display("✓ 场景4通过：正向重训练恢复正常");
        test_pass = test_pass + 1;
    end else begin
        $display("✗ 场景4失败");
        test_fail = test_fail + 1;
    end
    
    // 场景5：反向链路故障重训练
    $display("\n--- 场景5：反向链路故障重训练 ---");
    slv_err_cnt = 0;
    link_s2m_disable = 1'b1;
    wait(~mst_link_up);
    #10000;
    link_s2m_disable = 1'b0;
    wait_both_link_up();
    send_slave_data(128);
    wait(slv_send_queue.size() == 0);
    if(slv_err_cnt == 0) begin
        $display("✓ 场景5通过：反向重训练恢复正常");
        test_pass = test_pass + 1;
    end else begin
        $display("✗ 场景5失败");
        test_fail = test_fail + 1;
    end
    
    // 场景6：外部强制重训练
    $display("\n--- 场景6：外部强制重训练 ---");
    mst_err_cnt = 0;
    @(posedge clk_ref_master);
    mst_ext_retrain = 1'b1;
    repeat(10) @(posedge clk_ref_master);
    mst_ext_retrain = 1'b0;
    wait_both_link_up();
    send_master_data(128);
    wait(mst_send_queue.size() == 0);
    if(mst_err_cnt == 0 && slv_err_cnt == 0) begin
        $display("✓ 场景6通过：外部重训练恢复正常");
        test_pass = test_pass + 1;
    end else begin
        $display("✗ 场景6失败");
        test_fail = test_fail + 1;
    end
    
    // 最终总结
    #10000;
    $display("\n\n==================================================");
    $display("  仿真测试结束");
    $display("  总用例：6 | 通过：%0d | 失败：%0d", test_pass, test_fail);
    if(test_fail == 0)
```

> （注：部分内容可能由 AI 生成）
