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
//   读响应帧（4拍）: HEAD | RDATA | {RRESP} | TAIL
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
    localparam [2:0] S_IDLE       = 3'd0;
    localparam [2:0] S_RESYNC     = 3'd1;  // 帧错误后丢弃残余拍至 tlast
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
    reg [7:0]  payload_cnt;
    reg [31:0] addr_reg;
    reg [3:0]  wstrb_reg;
    reg [31:0] wdata_reg;
    reg [31:0] rdata_reg;
    reg        is_write_cmd;
    reg        addr_err;          // 地址越界标志（修正 M-03）
    reg [7:0]  tx_payload_cnt;    // TX 净荷拍计数器

    // 握手信号
    wire cmd_hs = s_axis_cmd_tvalid && s_axis_cmd_tready;
    wire rsp_hs = m_axis_rsp_tvalid && m_axis_rsp_tready;

    // 地址安全比较
    wire addr_in_range = (addr_reg[31:2] < C_REG_NUM);
    // 修正 H-05：动态位宽索引，支持 C_REG_NUM > 4
    localparam REG_IDX_W = (C_REG_NUM <= 2) ? 1 :
                           (C_REG_NUM <= 4) ? 2 :
                           (C_REG_NUM <= 8) ? 3 : 4;
    wire [REG_IDX_W-1:0] reg_index = addr_in_range ?
        addr_reg[REG_IDX_W+1:2] : {REG_IDX_W{1'b0}};

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
            // 修正 C-01：S_IDLE 同拍完成包头校验与类型锁存，消除首拍消耗漏洞
            S_IDLE: begin
                if (cmd_hs) begin
                    if (s_axis_cmd_tdata[31:24] == FRAME_MAGIC_HEAD)
                        next_state = S_RX_PAYLOAD;
                    // 魔数不匹配则忽略该拍，留在 S_IDLE
                end
            end

            // 修正 M-01：帧错误后丢弃残余拍直到 tlast
            S_RESYNC: begin
                if (cmd_hs && s_axis_cmd_tlast)
                    next_state = S_IDLE;
            end

            S_RX_PAYLOAD: begin
                if (cmd_hs) begin
                    if (payload_cnt == (payload_len_reg - 8'd1))
                        next_state = S_RX_TAIL;
                end
            end

            S_RX_TAIL: begin
                if (cmd_hs) begin
                    if (s_axis_cmd_tlast &&
                        (s_axis_cmd_tdata[31:24] == FRAME_MAGIC_TAIL))
                        next_state = S_EXECUTE;
                    else if (s_axis_cmd_tlast)
                        next_state = S_IDLE;     // tlast 已到但魔数错
                    else
                        next_state = S_RESYNC;   // 无 tlast，需丢弃残余拍
                end
            end

            S_EXECUTE: begin
                next_state = S_TX_HEAD;
            end

            // 修正 H-01：TX 使用 rsp_hs（tvalid&&tready）作为转移条件
            S_TX_HEAD: begin
                if (rsp_hs)
                    next_state = S_TX_PAYLOAD;
            end

            S_TX_PAYLOAD: begin
                if (rsp_hs) begin
                    // 写响应 1 拍净荷，读响应 2 拍净荷（RDATA + RRESP）
                    if (is_write_cmd || tx_payload_cnt == 8'd1)
                        next_state = S_TX_TAIL;
                end
            end

            S_TX_TAIL: begin
                if (rsp_hs)
                    next_state = S_IDLE;
            end

            default: next_state = S_IDLE;
        endcase
    end

    // 修正 H-01/M-02：TX 响应输出改为组合逻辑，消除状态-输出错位
    always @(*) begin
        m_axis_rsp_tdata  = {C_AXIS_DATA_WIDTH{1'b0}};
        m_axis_rsp_tvalid = 1'b0;
        m_axis_rsp_tlast  = 1'b0;
        case (curr_state)
            S_TX_HEAD: begin
                m_axis_rsp_tvalid = 1'b1;
                if (is_write_cmd)
                    m_axis_rsp_tdata = {FRAME_MAGIC_HEAD, FRAME_TYPE_WR_RSP, 8'd1, 8'h00};
                else
                    m_axis_rsp_tdata = {FRAME_MAGIC_HEAD, FRAME_TYPE_RD_RSP, 8'd2, 8'h00};
            end
            S_TX_PAYLOAD: begin
                m_axis_rsp_tvalid = 1'b1;
                if (is_write_cmd) begin
                    // 修正 M-03：地址越界返回 DECERR
                    m_axis_rsp_tdata = {30'h0, addr_err ? 2'b11 : 2'b00};
                end else begin
                    case (tx_payload_cnt)
                        8'd0: m_axis_rsp_tdata = rdata_reg;                        // RDATA
                        8'd1: m_axis_rsp_tdata = {30'h0, addr_err ? 2'b11 : 2'b00}; // RRESP
                        default: m_axis_rsp_tdata = {C_AXIS_DATA_WIDTH{1'b0}};
                    endcase
                end
            end
            S_TX_TAIL: begin
                m_axis_rsp_tvalid = 1'b1;
                m_axis_rsp_tlast  = 1'b1;
                m_axis_rsp_tdata  = {FRAME_MAGIC_TAIL, 16'h0000, 8'h00};
            end
            default: ;
        endcase
    end

    // 第三段：时序逻辑（RX 数据通路 + TX 计数器 + 寄存器读写）
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s_axis_cmd_tready <= 1'b0;
            frame_type_reg    <= 8'd0;
            payload_len_reg   <= 8'd0;
            payload_cnt       <= 8'd0;
            addr_reg          <= 32'd0;
            wstrb_reg         <= 4'd0;
            wdata_reg         <= 32'd0;
            rdata_reg         <= 32'd0;
            is_write_cmd      <= 1'b0;
            addr_err          <= 1'b0;
            tx_payload_cnt    <= 8'd0;
            for (i = 0; i < C_REG_NUM; i = i + 1)
                reg_file[i] <= {C_AXIS_DATA_WIDTH{1'b0}};
        end else begin
            s_axis_cmd_tready <= 1'b0;

            case (curr_state)
                // 修正 C-01：S_IDLE 同拍处理包头（校验魔数 + 锁存类型/长度）
                S_IDLE: begin
                    s_axis_cmd_tready <= 1'b1;
                    payload_cnt       <= 8'd0;
                    tx_payload_cnt    <= 8'd0;
                    if (cmd_hs && (s_axis_cmd_tdata[31:24] == FRAME_MAGIC_HEAD)) begin
                        frame_type_reg  <= s_axis_cmd_tdata[23:16];
                        payload_len_reg <= s_axis_cmd_tdata[15:8];
                        is_write_cmd    <= (s_axis_cmd_tdata[23:16] == FRAME_TYPE_WR_CMD);
                    end
                end

                // 修正 M-01：帧错误恢复，丢弃至 tlast
                S_RESYNC: begin
                    s_axis_cmd_tready <= 1'b1;
                end

                S_RX_PAYLOAD: begin
                    s_axis_cmd_tready <= 1'b1;
                    if (cmd_hs) begin
                        payload_cnt <= payload_cnt + 8'd1;
                        if (frame_type_reg == FRAME_TYPE_WR_CMD) begin
                            case (payload_cnt)
                                8'd0: addr_reg  <= s_axis_cmd_tdata;
                                8'd1: wdata_reg <= s_axis_cmd_tdata;
                                8'd2: wstrb_reg <= s_axis_cmd_tdata[3:0];
                                default: ;
                            endcase
                        end else if (frame_type_reg == FRAME_TYPE_RD_CMD) begin
                            if (payload_cnt == 8'd0)
                                addr_reg <= s_axis_cmd_tdata;
                        end
                    end
                end

                S_RX_TAIL: begin
                    s_axis_cmd_tready <= 1'b1;
                end

                // 修正 M-03：地址越界时设置 addr_err 标志
                S_EXECUTE: begin
                    addr_err <= !addr_in_range;
                    if (is_write_cmd) begin
                        if (addr_in_range) begin
                            if (wstrb_reg[0]) reg_file[reg_index][7:0]   <= wdata_reg[7:0];
                            if (wstrb_reg[1]) reg_file[reg_index][15:8]  <= wdata_reg[15:8];
                            if (wstrb_reg[2]) reg_file[reg_index][23:16] <= wdata_reg[23:16];
                            if (wstrb_reg[3]) reg_file[reg_index][31:24] <= wdata_reg[31:24];
                        end
                    end else begin
                        if (addr_in_range)
                            rdata_reg <= reg_file[reg_index];
                        else
                            rdata_reg <= 32'hDEAD_BEEF;
                    end
                end

                S_TX_PAYLOAD: begin
                    if (rsp_hs)
                        tx_payload_cnt <= tx_payload_cnt + 8'd1;
                end

                default: ;
            endcase
        end
    end

endmodule
