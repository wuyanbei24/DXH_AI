`timescale 1ns / 1ps
//============================================================================
// test_data_gen.v
// ----------------------------------------------------------------------------
// 可配置位宽测试数据发生器（AXI4-Stream Master 输出）
//
// 功能：
//   生成可配置的测试数据流，通过 AXI4-Stream Master 接口送出。
//   输出数据位宽由参数 DATA_WIDTH 配置（支持 8/16/32/64 等）。
//   支持多种数据生成模式：自增计数 / PRBS 伪随机 / 常数 / 走 1。
//   每帧由 cfg_frame_beats 个 beat 组成，帧尾置 tlast。
//
// 生成模式（cfg_mode）：
//   2'b00 INCREMENT : tdata = seed, seed+1, seed+2, ...
//   2'b01 PRBS      : 线性反馈移位寄存器（位宽 = DATA_WIDTH，通用抽头 最高位/次高位/bit1/bit0）
//   2'b10 CONSTANT  : tdata 恒等于 seed
//   2'b11 WALK_ONE  : 单 bit 循环左移（0x1 -> 0x2 -> 0x4 -> ...）
//
// AXI4-Stream 握手：m_axis_tvalid 仅在 S_RUN 状态有效；
//   下游 m_axis_tready=0 时暂停输出，数据不丢、计数不前进（天然反压）。
//
// 设计约束：
//   - Verilog-2001，无 SystemVerilog / 无 Xilinx 原语，纯 RTL 可跨平台综合
//   - 单时钟域 aclk，低有效异步复位 aresetn（异步断言、同步释放）
//   - 单时钟域 aclk，低有效异步复位 aresetn（异步断言、同步释放）
//   - DATA_WIDTH >= 8（PRBS/走 1 模式的位宽下限，PRBS 抽头要求 >= 2）
//
// 详细设计：doc/test_data_gen_详细设计文档.md
//============================================================================
module test_data_gen #(
    parameter integer DATA_WIDTH         = 32,   // 可配置输出位宽（核心需求）
    parameter integer TUSER_WIDTH        = 8,    // tuser 位宽（承载帧内 beat 序号）
    parameter [1:0]  DEFAULT_MODE        = 2'b00, // 默认生成模式（当 cfg_mode 未驱动时参考）
    parameter integer DEFAULT_FRAME_BEATS = 16   // 默认每帧 beat 数
)(
    input  wire                     aclk,
    input  wire                     aresetn,

    // -------- 运行控制 --------
    input  wire                     ctrl_start,         // 脉冲启动一帧生成（高有效 1 拍）
    input  wire [1:0]               cfg_mode,           // 生成模式选择
    input  wire [DATA_WIDTH-1:0]    cfg_seed,           // 起始 / 种子值
    input  wire [15:0]              cfg_frame_beats,    // 每帧 beat 数（必须 >= 1）

    // -------- AXI4-Stream Master 输出 --------
    output wire [DATA_WIDTH-1:0]    m_axis_tdata,
    output wire                     m_axis_tvalid,
    output wire                     m_axis_tlast,
    output wire [TUSER_WIDTH-1:0]   m_axis_tuser,
    input  wire                     m_axis_tready,

    // -------- 状态指示 --------
    output wire                     busy                // 正在生成（S_RUN）
);

    // ========== 模式编码 ==========
    localparam [1:0] MODE_INC   = 2'b00;
    localparam [1:0] MODE_PRBS  = 2'b01;
    localparam [1:0] MODE_CONST = 2'b10;
    localparam [1:0] MODE_WALK  = 2'b11;

    // ========== 状态定义（三段式，2 状态足够）==========
    localparam [0:0] S_IDLE = 1'b0;   // 空闲，等待 ctrl_start
    localparam [0:0] S_RUN  = 1'b1;   // 生成并发送数据

    reg        curr_state;
    reg        next_state;

    // ========== 内部寄存器 ==========
    reg [DATA_WIDTH-1:0] gen_reg;    // 当前输出数据（INC/CONST/WALK）
    reg [DATA_WIDTH-1:0] prbs_reg;   // PRBS LFSR 状态（位宽 = DATA_WIDTH）
    reg [15:0]           beat_cnt;   // 当前帧内已输出 beat 数（0-based）
    reg [TUSER_WIDTH-1:0] frame_id;  // 已完成帧计数（每帧结束 +1）

    // ========== 握手 ==========
    wire axis_hs = m_axis_tvalid && m_axis_tready;

    // ========== 模式选择（带默认值）==========
    wire [1:0] mode_sel = (cfg_mode == 2'b00) ? cfg_mode : cfg_mode; // 直接采用运行时配置

    // ========== PRBS 下一拍（Fibonacci LFSR，位宽 = DATA_WIDTH）==========
    // 通用抽头：最高位、次高位、bit1、bit0（要求 DATA_WIDTH >= 8）
    // 反馈 bit 移入最高位，整体右移
    wire prbs_fb   = prbs_reg[DATA_WIDTH-1] ^ prbs_reg[DATA_WIDTH-2] ^ prbs_reg[1] ^ prbs_reg[0];
    wire [DATA_WIDTH-1:0] prbs_next = {prbs_fb, prbs_reg[DATA_WIDTH-1:1]};

    // ========== 下一拍数据（组合逻辑）==========
    reg [DATA_WIDTH-1:0] gen_next;
    always @(*) begin
        case (mode_sel)
            MODE_INC:   gen_next = gen_reg + 1'b1;
            MODE_CONST: gen_next = cfg_seed;
            MODE_WALK:  gen_next = {gen_reg[DATA_WIDTH-2:0], gen_reg[DATA_WIDTH-1]}; // 循环左移
            MODE_PRBS:  gen_next = prbs_next;                                         // 与数据位宽一致
            default:    gen_next = gen_reg + 1'b1;
        endcase
    end

    //=====================================================================
    // 三段式 FSM —— 第一段：状态寄存器（时序逻辑）
    //=====================================================================
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) curr_state <= S_IDLE;
        else          curr_state <= next_state;
    end

    //=====================================================================
    // 三段式 FSM —— 第二段：下一状态逻辑（组合逻辑）
    //=====================================================================
    always @(*) begin
        case (curr_state)
            S_IDLE: begin
                if (ctrl_start) next_state = S_RUN;
                else            next_state = S_IDLE;
            end
            S_RUN: begin
                // 当前 beat 是帧尾且握手成功 -> 一帧完成，回到 IDLE
                if (axis_hs && (beat_cnt == cfg_frame_beats - 1))
                    next_state = S_IDLE;
                else
                    next_state = S_RUN;
            end
            default: next_state = S_IDLE;
        endcase
    end

    //=====================================================================
    // 三段式 FSM —— 第三段：数据 / 计数 / 输出驱动
    //=====================================================================
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            gen_reg  <= {DATA_WIDTH{1'b0}};
            prbs_reg <= {DATA_WIDTH{1'b1}};   // 非零初值，避免全零 LFSR 死锁
            beat_cnt <= 16'd0;
            frame_id <= {TUSER_WIDTH{1'b0}};
        end else begin
            case (curr_state)
                // -------- IDLE：等待启动，加载首拍数据 --------
                S_IDLE: begin
                    if (ctrl_start) begin
                        gen_reg  <= cfg_seed;                                   // 首拍 = seed
                        prbs_reg <= (|cfg_seed) ? cfg_seed
                                                 : {DATA_WIDTH{1'b1}};          // PRBS 初值（避免全零）
                        beat_cnt <= 16'd0;
                        // frame_id 在本帧结束时 +1，此处不重复累加
                    end
                end
                // -------- RUN：每个握手输出一拍并更新 --------
                S_RUN: begin
                    if (axis_hs) begin
                        gen_reg  <= gen_next;
                        prbs_reg <= prbs_next;
                        if (beat_cnt == cfg_frame_beats - 1) begin
                            frame_id <= frame_id + 1'b1;   // 帧结束，帧计数 +1
                            beat_cnt <= 16'd0;
                        end else begin
                            beat_cnt <= beat_cnt + 1'b1;
                        end
                    end
                end
                default: ;
            endcase
        end
    end

    // ========== 输出端口 ==========
    assign m_axis_tdata  = gen_reg;
    assign m_axis_tvalid = (curr_state == S_RUN);
    assign m_axis_tlast  = (curr_state == S_RUN) && (beat_cnt == cfg_frame_beats - 1);
    assign m_axis_tuser  = beat_cnt[TUSER_WIDTH-1:0];  // 帧内 beat 序号（诊断用）
    assign busy          = (curr_state == S_RUN);

endmodule
