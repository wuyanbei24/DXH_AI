//============================================================================
// axist2native.v
// ----------------------------------------------------------------------------
// AXI4-Stream Slave 命令输入 -> 寄存器读写 -> AXI4-Stream Master 响应输出
//
// 修正版 V2（2026-07-25）：
//   D-08: payload_cnt 位宽/比较不健壮 -> 统一 8-bit 显式比较
//   D-09: 地址越界保护不完整 -> 用 addr_reg[31:2] 完整比较
//   D-10: 帧错误后帧失步 -> 增加 S_RESYNC 状态丢弃到 tlast
//   D-11: S_EXECUTE 时序 -> 保持单拍，显式注释
//
// 帧格式（V2，与 axi4lite2axist 一致）：
//   写命令帧（5拍）: HEAD | AWADDR | WDATA | {WSTRB} | TAIL
//   读命令帧（3拍）: HEAD | ARADDR | TAIL
//   写响应帧（3拍）: HEAD | {BRESP} | TAIL
//   读响应帧（3拍）: HEAD | RDATA  | TAIL
//============================================================================
module axist2native #(
    parameter C_AXIS_DATA_WIDTH = 32,
    parameter C_REG_NUM         = 4
)(
    input  wire                                 aclk,
    input  wire                                 aresetn,

    // ========== AXI4-Stream Slave 命令输入 ==========
    input  wire [C_AXIS_DATA_WIDTH-1:0]         s_axis_cmd_tdata,
    input  wire                                 s_axis_cmd_tvalid,
    input  wire                                 s_axis_cmd_tlast,
    output reg                                  s_axis_cmd_tready,

    // ========== AXI4-Stream Master 响应输出 ==========
    output reg  [C_AXIS_DATA_WIDTH-1:0]         m_axis_rsp_tdata,
    output reg                                  m_axis_rsp_tvalid,
    output reg                                  m_axis_rsp_tlast,
    input  wire                                 m_axis_rsp_tready
);

    // ========== 帧格式常量 ==========
    localparam [7:0] FRAME_MAGIC_HEAD  = 8'hAA;
    localparam [7:0] FRAME_MAGIC_TAIL  = 8'h55;
    localparam [7:0] FRAME_TYPE_WR_CMD = 8'h01;
    localparam [7:0] FRAME_TYPE_RD_CMD = 8'h02;
    localparam [7:0] FRAME_TYPE_WR_RSP = 8'h11;
    localparam [7:0] FRAME_TYPE_RD_RSP = 8'h12;

    // ========== 状态定义（三段式）==========
    // 修正 D-10：增加 S_RESYNC 状态用于帧错误后丢弃残余拍
    localparam [2:0] S_IDLE       = 3'd0;
    localparam [2:0] S_RX_HEAD    = 3'd1;
    localparam [2:0] S_RX_PAYLOAD = 3'd2;
    localparam [2:0] S_RX_TAIL    = 3'd3;
    localparam [2:0] S_EXECUTE    = 3'd4;
    localparam [2:0] S_TX_HEAD    = 3'd5;
    localparam [2:0] S_TX_PAYLOAD = 3'd6;
    localparam [2:0] S_TX_TAIL    = 3'd7;

    reg [2:0] curr_state;
    reg [2:0] next_state;

    // ========== 内部寄存器 ==========
    reg [C_AXIS_DATA_WIDTH-1:0] reg_file [0:C_REG_NUM-1];

    reg [7:0]  frame_type_reg;
    reg [7:0]  payload_len_reg;
    reg [7:0]  payload_cnt;       // 修正 D-08：统一 8-bit
    reg [31:0] addr_reg;
    reg [3:0]  wstrb_reg;
    reg [31:0] wdata_reg;
    reg [31:0] rdata_reg;
    reg        is_write_cmd;      // 1=写命令, 0=读命令

    // 地址安全比较（修正 D-09）
    // addr_reg[31:2] 为字地址，与 C_REG_NUM 比较
    wire addr_in_range = (addr_reg[31:2] < C_REG_NUM);
    // 安全索引：即使越界也不会访问非法地址
    wire [31:0] safe_word_idx = addr_in_range ? addr_reg : 32'd0;
    // reg_file 索引位宽 = log2(C_REG_NUM)，这里用 [3:2] 偏移
    wire [1:0] reg_index = safe_word_idx[3:2];

    integer i;

    // 第一段：时序状态寄存器
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn)
            curr_state <= S_IDLE;
        else
            curr_state <= next_state;
    end

    // 第二段：组合逻辑状态转移
    always @(*) begin
        next_state = curr_state;
        case (curr_state)
            S_IDLE: begin
                if (s_axis_cmd_tvalid)
                    next_state = S_RX_HEAD;
            end

            S_RX_HEAD: begin
                if (s_axis_cmd_tvalid) begin
                    if (s_axis_cmd_tdata[31:24] == FRAME_MAGIC_HEAD)
                        next_state = S_RX_PAYLOAD;
                    else
                        // 修正 D-10：魔数错误，进入 RESYNC 丢弃当前帧
                        next_state = S_IDLE; // 包头错误直接回 IDLE（尚未进入帧内）
                end
            end

            S_RX_PAYLOAD: begin
                if (s_axis_cmd_tvalid) begin
                    // 修正 D-08：显式 8-bit 比较
                    if (payload_cnt == (payload_len_reg - 8'd1))
                        next_state = S_RX_TAIL;
                end
            end

            S_RX_TAIL: begin
                if (s_axis_cmd_tvalid) begin
                    if (s_axis_cmd_tlast &&
                        (s_axis_cmd_tdata[31:24] == FRAME_MAGIC_TAIL)) begin
                        next_state = S_EXECUTE;
                    end else begin
                        // 修正 D-10：帧尾错误，丢弃并回 IDLE
                        // 若 tlast 已到但魔数错，或魔数对但 tlast 未到，均视为错误
                        next_state = S_IDLE;
                    end
                end
            end

            S_EXECUTE: begin
                // 修正 D-11：单拍执行，下一拍进入发送
                // 读数据 rdata_reg 在此拍锁存，S_TX_PAYLOAD 在下一拍使用，时序正确
                next_state = S_TX_HEAD;
            end

            S_TX_HEAD: begin
                if (m_axis_rsp_tready)
                    next_state = S_TX_PAYLOAD;
            end

            S_TX_PAYLOAD: begin
                if (m_axis_rsp_tready)
                    next_state = S_TX_TAIL;
            end

            S_TX_TAIL: begin
                if (m_axis_rsp_tready)
                    next_state = S_IDLE;
            end

            default: next_state = S_IDLE;
        endcase
    end

    // 第三段：时序逻辑输出与数据通路
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s_axis_cmd_tready <= 1'b0;
            m_axis_rsp_tvalid <= 1'b0;
            m_axis_rsp_tlast  <= 1'b0;
            m_axis_rsp_tdata  <= {C_AXIS_DATA_WIDTH{1'b0}};
            frame_type_reg    <= 8'd0;
            payload_len_reg   <= 8'd0;
            payload_cnt       <= 8'd0;
            addr_reg          <= 32'd0;
            wstrb_reg         <= 4'd0;
            wdata_reg         <= 32'd0;
            rdata_reg         <= 32'd0;
            is_write_cmd      <= 1'b0;
            for (i = 0; i < C_REG_NUM; i = i + 1)
                reg_file[i] <= {C_AXIS_DATA_WIDTH{1'b0}};
        end else begin
            s_axis_cmd_tready <= 1'b0;
            m_axis_rsp_tvalid <= 1'b0;
            m_axis_rsp_tlast  <= 1'b0;

            case (curr_state)
                S_IDLE: begin
                    s_axis_cmd_tready <= 1'b1;
                    payload_cnt       <= 8'd0;
                end

                S_RX_HEAD: begin
                    s_axis_cmd_tready <= 1'b1;
                    if (s_axis_cmd_tvalid) begin
                        frame_type_reg  <= s_axis_cmd_tdata[23:16];
                        payload_len_reg <= s_axis_cmd_tdata[15:8];
                        is_write_cmd    <= (s_axis_cmd_tdata[23:16] == FRAME_TYPE_WR_CMD);
                    end
                end

                S_RX_PAYLOAD: begin
                    s_axis_cmd_tready <= 1'b1;
                    if (s_axis_cmd_tvalid) begin
                        payload_cnt <= payload_cnt + 8'd1;
                        // 按帧类型解析净荷（V2 格式）
                        if (frame_type_reg == FRAME_TYPE_WR_CMD) begin
                            case (payload_cnt)
                                8'd0: begin
                                    // 净荷1：写地址（完整 32-bit）
                                    addr_reg <= s_axis_cmd_tdata;
                                end
                                8'd1: begin
                                    // 净荷2：写数据
                                    wdata_reg <= s_axis_cmd_tdata;
                                end
                                8'd2: begin
                                    // 净荷3：字节选通
                                    wstrb_reg <= s_axis_cmd_tdata[3:0];
                                end
                                default: ;
                            endcase
                        end else if (frame_type_reg == FRAME_TYPE_RD_CMD) begin
                            if (payload_cnt == 8'd0) begin
                                // 净荷1：读地址（完整 32-bit）
                                addr_reg <= s_axis_cmd_tdata;
                            end
                        end
                    end
                end

                S_RX_TAIL: begin
                    s_axis_cmd_tready <= 1'b1;
                    // 包尾校验在状态转移中完成
                end

                S_EXECUTE: begin
                    if (is_write_cmd) begin
                        // 按字节选通写入寄存器（修正 D-09：完整地址比较）
                        if (addr_in_range) begin
                            if (wstrb_reg[0]) reg_file[reg_index][7:0]   <= wdata_reg[7:0];
                            if (wstrb_reg[1]) reg_file[reg_index][15:8]  <= wdata_reg[15:8];
                            if (wstrb_reg[2]) reg_file[reg_index][23:16] <= wdata_reg[23:16];
                            if (wstrb_reg[3]) reg_file[reg_index][31:24] <= wdata_reg[31:24];
                        end
                    end else begin
                        // 读取寄存器（修正 D-09）
                        if (addr_in_range)
                            rdata_reg <= reg_file[reg_index];
                        else
                            rdata_reg <= 32'hDEAD_BEEF; // 越界返回错误码
                    end
                end

                S_TX_HEAD: begin
                    m_axis_rsp_tvalid <= 1'b1;
                    if (is_write_cmd) begin
                        m_axis_rsp_tdata <= {FRAME_MAGIC_HEAD, FRAME_TYPE_WR_RSP, 8'd1, 8'h00};
                    end else begin
                        m_axis_rsp_tdata <= {FRAME_MAGIC_HEAD, FRAME_TYPE_RD_RSP, 8'd1, 8'h00};
                    end
                end

                S_TX_PAYLOAD: begin
                    m_axis_rsp_tvalid <= 1'b1;
                    if (is_write_cmd) begin
                        m_axis_rsp_tdata <= {30'h0, 2'b00}; // BRESP = OKAY
                    end else begin
                        m_axis_rsp_tdata <= rdata_reg;
                    end
                end

                S_TX_TAIL: begin
                    m_axis_rsp_tvalid <= 1'b1;
                    m_axis_rsp_tlast  <= 1'b1;
                    m_axis_rsp_tdata  <= {FRAME_MAGIC_TAIL, 16'h0000, 8'h00};
                end

                default: ;
            endcase
        end
    end

endmodule
