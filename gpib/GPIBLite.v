
module GPIBLite #
(
    parameter                       INFO_RDY_DLY    =   8'd35   
)(

    //System clock and reset_n from M1 core 
    input       wire                sys_clk                 ,
    input       wire                sys_rstn                ,
    
    //APB interface 
    input       wire                APB_PCLK                ,
    input       wire                APB_PRESET              ,
    input       wire        [31:0]  APB_PADDR               ,
    input       wire                APB_PENABLE             ,
    input       wire                APB_PWRITE              ,
    input       wire        [3:0]   APB_PSTRB               ,
    input       wire        [2:0]   APB_PPROT               ,
    input       wire        [31:0]  APB_PWDATA              ,
    input       wire                APB_PSEL                ,
    output      reg         [31:0]  APB_PRDATA              ,
    output      reg                 APB_PREADY              ,
    output      wire                APB_PSLVERR             ,

    //GPIB电平转换芯片的控制信号 
    output      wire                te_a                    ,
    output      wire                te_b                    ,
    output      wire                sc                      ,
    output      wire                dc                      ,

    //GPIB接口的16个IO
    inout       wire        [7:0]   data                    ,
    input       wire                ifc                     ,
    input       wire                atn                     ,
    input       wire                ren                     ,
    output      wire                srq                     ,
    inout       wire                eoi                     ,
    inout       wire                nrfd                    ,
    inout       wire                ndac                    ,
    inout       wire                dav                     ,
    
    output      wire                GPIB_infifo_empty       
);

//----------------------------------------------------------------------------------------
//参数定义
localparam GPIB_AH_AIDS       =     3'b000                  ;               //空闲状态
localparam GPIB_AH_ANRS       =     3'b001                  ;               //准备状态
localparam GPIB_AH_ACRS       =     3'b010                  ;               //等源方数据就绪状态
localparam GPIB_AH_ACDS       =     3'b011                  ;               //等待APB总线取走数据状态
localparam GPIB_AH_AWNS       =     3'b100                  ;               //等待源方确认状态


localparam GPIB_SH_SIDS       =     3'b000                  ;               //空闲状态
localparam GPIB_SH_SGNS       =     3'b001                  ;               //当前设备被被指为说者
localparam GPIB_SH_SDYS       =     3'b010                  ;               //此状态用于等待APB总线发过来数据并向总线上更新数据
localparam GPIB_SH_STRS       =     3'b011                  ;               //等待受方可以接收数据
localparam GPIB_SH_SWNS       =     3'b100                  ;               //等待受方全部接收数据
localparam GPIB_SH_SIWS       =     3'b101                  ;               //判断讲者数据是否发送完成

localparam INFO_RDY_DLY_CNT   =     32'd40_000_000 * INFO_RDY_DLY   ;       //判断讲者数据是否发送完成

//----------------------------------------------------------------------------------------
//外部输入信号时钟同步
reg                         [7:0]   data_dly                ;
reg                                 ifc_dly,atn_dly,ren_dly,eoi_dly,nrfd_dly,ndac_dly,dav_dly;
reg                                 atn_ff0, atn_ff1          ;  //ATN 2级同步(快速)，仅用于 in-FIFO 数据捕获门控
reg                         [31:0]  atn_32_dly              ;
// 跨时钟域输入两级同步寄存器（GPIB 总线信号相对 sys_clk 异步）
reg                         [7:0]   data_dly1               ;
reg                                 ifc_dly1,ren_dly1,eoi_dly1,nrfd_dly1,ndac_dly1,dav_dly1;

//----------------------------------------------------------------------------------------
//GPIB接口寄存器定义
reg                                 GPIB_Ctl_En             ;               //GPIB使能位
reg                                 GPIB_Ctl_IRQ_R_En       ;               //GPIB接收完成中断使能位
reg                                 GPIB_Ctl_IRQ_T_En       ;               //GPIB发送完成中断使能位
reg                                 GPIB_Ctl_IRQ_R_Clr      ;               //GPIB接收完成中断清除位
reg                                 GPIB_Ctl_IRQ_T_Clr      ;               //GPIB发送完成中断清除位
reg                         [4:0]   GPIB_Addr               ;               //GPIB设备地址
reg                                 M1_ready_information    ;               //1表示M1此时已经获取到了设备信息，上位机可以握手GPIB，握手后会立即读取*IDN？
reg                         [32:0]  M1_ready_count          ;               //开机等待就绪，单位：S

//----------------------------------------------------------------------------------------
//GPIB总线IO控制：data, eoi, nrfd, ndac, dav 双向
reg                                 GPIB_State              ;               //1:说者；0：听者
reg                                 GPIB_State_dly          ;
wire                                eoiIn                   ;
wire                                eoiOut                  ;
wire                                davIn                   ;
reg                                 davOut                  ;
wire                                nrfdIn                  ;
reg                                 nrfdOut                 ;
wire                                ndacIn                  ;
reg                                 ndacOut                 ;

//----------------------------------------------------------------------------------------
//GPIB指令
reg                                 LLO                     ;               //0x11:本地封锁
reg                                 DCL                     ;               //0x14:器件清除
reg                                 SPE                     ;               //0x18:串行查询可能
reg                                 SPD                     ;               //0x19:串行查询不可能
reg                                 PPU                     ;               //0x15:并行查询不组态

reg                                 GET                     ;               //0x08:群执行触发
reg                                 GTL                     ;               //0x01:进入本地
reg                                 PPC                     ;               //0x05:并行点名组态
reg                                 SDC                     ;               //0x04:有选择器件清除
reg                                 TCT                     ;               //0x09:接受控制

reg                                 LAD                     ;               //8b*01L5...L1:听地址（地址全1表示全部不听）
reg                                 TAD                     ;               //8b*10L5...L1:讲地址
reg                                 UNL                     ;               //8b*11L5...L1:不听地址

reg                                 SAD                     ;               //8b*01L5...L1:副地址
reg                                 PPD                     ;               //8b*111L4...L1:并行查询不可能
reg                                 PPE                     ;               //8b*110L4...L1:并行查询可能

//----------------------------------------------------------------------------------------
//GPIB器件清除接口：DC
reg                                 DCIS                    ;               //器件清除空闲态
reg                                 DCAS                    ;               //器件清除作用态

//----------------------------------------------------------------------------------------
//GPIB器件听者接口：L
reg                                 LIDS                    ;               //听者空闲状态
reg                                 LADS                    ;               //听者寻址状态
reg                                 LACS                    ;               //听者作用状态

//----------------------------------------------------------------------------------------
//GPIB器件讲者接口：T
reg                                 TIDS                    ;               //讲者空闲状态
reg                                 TADS                    ;               //讲者寻址状态
reg                                 TACS                    ;               //讲者作用状态

//----------------------------------------------------------------------------------------
//GPIB器件受方挂钩功能接口：AH
reg                                 AIDS                    ;               //受者空闲状态
reg                                 ANRS                    ;               //受者未准备好状态
reg                                 ACRS                    ;               //受者已准备好状态
reg                                 ACDS                    ;               //接收数据状态
reg                                 AWNS                    ;               //受者等待新循环状态

//----------------------------------------------------------------------------------------
//GPIB器件源方挂钩功能接口：SH
reg                                 SIDS                    ;               //源空闲状态
reg                                 SGNS                    ;               //源产生状态
reg                                 SDYS                    ;               //源延迟状态
reg                                 STRS                    ;               //源传递状态
reg                                 SWNS                    ;               //源等待新循环状态
reg                                 SIWS                    ;               //源闲等状态

//----------------------------------------------------------------------------------------
//GPIB各个状态
reg                                 GPIB_DC_State           ;               //器件清除状态，1：正在清除
reg                         [1:0]   GPIB_L_State            ;               //听者状态
reg                         [1:0]   GPIB_T_State            ;               //讲者状态
reg                         [2:0]   GPIB_AH_State           ;               //受者挂钩状态
reg                         [2:0]   GPIB_SH_State           ;               //源挂沟状态

//----------------------------------------------------------------------------------------
//变量定义
wire                                write_enable            ;
reg                                 write_enable_dly        ;
wire                                read_enable             ;
reg                                 read_enable_dly         ;
reg                         [31:0]  read_data               ;
reg                                 GPIB_infifo_w           ;               //GPIB接收数据后，写FIFO的写使能
reg                                 GPIB_infifo_w_dly       ;
reg                                 GPIB_infifo_r           ;               //GPIB接收数据后，写FIFO的读使能
wire                                GPIB_infifo_full        ;               //GPIB接收数据fifo满信号
reg                                 GPIB_outfifo_w          ;               //GPIB需要发数据时，读FIFO的写使能
reg                                 GPIB_outfifo_can_r_dly  ;
wire                                GPIB_outfifo_r          ;               //GPIB需要发数据时，读FIFO的读使能
wire                        [7:0]   GPIB_Data_M1_r          ;               //APB到M1的数据
reg                         [7:0]   GPIB_Data_M1_w          ;               //M1到APB的数据
wire                        [7:0]   GPIB_Data_FPGA_r        ;               //GPIB到FPGA的数据
wire                        [7:0]   GPIB_Data_FPGA_w        ;               //FPGA到GPIB的数据
reg                         [7:0]   GPIB_Data_FPGA_w_hold   ;               //发送数据保持寄存器(修复 FWFT 读指针提前推进导致首字节丢失)
wire                                GPIB_outfifo_empty      ;               //GPIB发送数据fifo空信号
wire                                GPIB_outfifo_full       ;               //GPIB发送数据fifo满信号
wire                        [10:0]  GPIB_outfifo_num        ;
reg                                 ifc_dly_dly             ;
wire                                GPIB_dvire_rstn         ;
reg                         [7:0]   GPIB_error              ;               //GPIB错误状态，置位后无法清零
reg                                 SGNS_dly                ;
reg                                 eoiOut_can_set          ;


//----------------------------------------------------------------------------------------
//跨时钟域同步：APB_PCLK -> sys_clk
//配置寄存器 GPIB_Ctl_En / GPIB_Addr 在 APB_PCLK 域写入，被 sys_clk 域状态机使用；
//GPIB_outfifo_full 在 APB 写侧产生，被 sys_clk 域错误 FSM 使用。采用 2 级同步器。
//----------------------------------------------------------------------------------------
reg                                 GPIB_Ctl_En_sync0, GPIB_Ctl_En_sync1          ;
reg                         [4:0]   GPIB_Addr_sync0,   GPIB_Addr_sync1            ;
reg                                 GPIB_outfifo_full_sync0, GPIB_outfifo_full_sync1;
always @(posedge sys_clk or negedge sys_rstn) begin
    if(~sys_rstn) begin
        GPIB_Ctl_En_sync0          <= 1'b0;            GPIB_Ctl_En_sync1          <= 1'b0;
        GPIB_Addr_sync0            <= 5'd0;            GPIB_Addr_sync1            <= 5'd0;
        GPIB_outfifo_full_sync0    <= 1'b0;            GPIB_outfifo_full_sync1    <= 1'b0;
    end else begin
        GPIB_Ctl_En_sync0          <= GPIB_Ctl_En;             GPIB_Ctl_En_sync1          <= GPIB_Ctl_En_sync0;
        GPIB_Addr_sync0            <= GPIB_Addr;               GPIB_Addr_sync1            <= GPIB_Addr_sync0;
        GPIB_outfifo_full_sync0    <= GPIB_outfifo_full;       GPIB_outfifo_full_sync1    <= GPIB_outfifo_full_sync0;
    end
end
wire                                GPIB_Ctl_En_sys      = GPIB_Ctl_En_sync1        ;
wire                        [4:0]   GPIB_Addr_sys        = GPIB_Addr_sync1          ;
wire                                GPIB_outfifo_full_sys= GPIB_outfifo_full_sync1  ;
// sys->APB 同步结果（声明提前，供 read_data 组合逻辑使用；赋值见文件后部 assign）
wire                                GPIB_State_apb        ;
wire                                GPIB_outfifo_empty_apb;

//----------------------------------------------------------------------------------------
//外部输入信号时钟同步
always @(posedge sys_clk or negedge sys_rstn) begin 
    if(~sys_rstn) begin 
        data_dly1           <=      8'd0                    ;
        data_dly            <=      8'd0                    ;
        ifc_dly1            <=      1'b0                    ;
        ifc_dly             <=      1'b0                    ;
        atn_32_dly          <=      32'd0                   ;
        atn_ff0             <=      1'b1                    ;  //ATN 默认释放(高)=数据阶段
        atn_ff1             <=      1'b1                    ;
        ren_dly1            <=      1'b0                    ;
        ren_dly             <=      1'b0                    ;
        eoi_dly1            <=      1'b0                    ;
        eoi_dly             <=      1'b0                    ;
        nrfd_dly1           <=      1'b0                    ;
        nrfd_dly            <=      1'b0                    ;
        ndac_dly1           <=      1'b0                    ;
        ndac_dly            <=      1'b0                    ;
        dav_dly1            <=      1'b0                    ;
        dav_dly             <=      1'b0                    ;
    end
    else begin 
        data_dly1           <=      data                    ;
        data_dly            <=      data_dly1               ;
        ifc_dly1            <=      ifc                     ;
        ifc_dly             <=      ifc_dly1                ;
        atn_32_dly          <=      {atn_32_dly[30:0],atn}  ;
        atn_ff0             <=      atn                     ;
        atn_ff1             <=      atn_ff0                 ;
        ren_dly1            <=      ren                     ;
        ren_dly             <=      ren_dly1                ;
        eoi_dly1            <=      eoi                     ;
        eoi_dly             <=      eoi_dly1                ;
        nrfd_dly1           <=      nrfd                    ;
        nrfd_dly            <=      nrfd_dly1               ;
        ndac_dly1           <=      ndac                    ;
        ndac_dly            <=      ndac_dly1               ;
        dav_dly1            <=      dav                     ;
        dav_dly             <=      dav_dly1                ;
    end 
end
//----------------------------------------------------------------------------------------
//经测试，NI的GPIB和keysight的GPIB，ATN信号时序有区别，NI的GPIB在ATN信号有效后，NRFD信号还未就绪，需要等待110ns（逻辑分析仪测试值）
always @(posedge sys_clk or negedge sys_rstn) begin 
    if(~sys_rstn) 
        atn_dly             <=      1'b0                    ;
    else 
        atn_dly             <=      atn_32_dly[31]          ;
end

//----------------------------------------------------------------------------------------
//APB接口
assign write_enable         =       APB_PSEL & APB_PENABLE & APB_PWRITE             ;
assign read_enable          =       APB_PSEL & APB_PENABLE & ~APB_PWRITE            ;

always@(posedge APB_PCLK or negedge APB_PRESET) begin 
    if(~APB_PRESET)
        APB_PREADY          <=      1'b0                    ;
    else if(write_enable | read_enable)
        APB_PREADY          <=      1'b1                    ;
    else 
        APB_PREADY          <=      1'b0                    ;
end 

always@(posedge APB_PCLK or negedge APB_PRESET) begin 
    if(~APB_PRESET) begin 
        GPIB_Data_M1_w      <=      8'd0                    ;
        GPIB_Ctl_En         <=      1'b1                    ;
        GPIB_Ctl_IRQ_R_En   <=      1'b1                    ;
        GPIB_Ctl_IRQ_T_En   <=      1'b0                    ;
        GPIB_Ctl_IRQ_R_Clr  <=      1'b0                    ;
        GPIB_Ctl_IRQ_T_Clr  <=      1'b0                    ;
        GPIB_Addr           <=      5'd1                    ;
    end
    else if(write_enable) begin 
        case (APB_PADDR[15:0])
            16'h0010    : GPIB_Data_M1_w                <=          APB_PWDATA[7:0]     ;
            16'h0014    : begin 
                          GPIB_Ctl_En                   <=          APB_PWDATA[0]       ;
                          GPIB_Ctl_IRQ_R_En             <=          APB_PWDATA[1]       ;
                          GPIB_Ctl_IRQ_T_En             <=          APB_PWDATA[2]       ;
                          GPIB_Ctl_IRQ_R_Clr            <=          APB_PWDATA[3]       ;
                          GPIB_Ctl_IRQ_T_Clr            <=          APB_PWDATA[4]       ;
                          GPIB_Addr                     <=          APB_PWDATA[12:8]    ;
                          end 
            default     :                                                               ;
        endcase 
    end 
    else begin 
        GPIB_Data_M1_w      <=      GPIB_Data_M1_w          ;
        GPIB_Ctl_En         <=      GPIB_Ctl_En             ;
        GPIB_Ctl_IRQ_R_En   <=      GPIB_Ctl_IRQ_R_En       ;
        GPIB_Ctl_IRQ_T_En   <=      GPIB_Ctl_IRQ_T_En       ;
        GPIB_Ctl_IRQ_R_Clr  <=      1'b0                    ;
        GPIB_Ctl_IRQ_T_Clr  <=      1'b0                    ;
        GPIB_Addr           <=      GPIB_Addr               ;
    end 
end 

always @(*) begin
    case (APB_PADDR[15:0])
        16'h0010: read_data =       {24'd0,GPIB_Data_M1_r}  ;
        16'h0014: read_data =       {24'd0,GPIB_Addr,3'd0,GPIB_Ctl_IRQ_T_Clr,GPIB_Ctl_IRQ_R_Clr,GPIB_Ctl_IRQ_T_En,GPIB_Ctl_IRQ_R_En,GPIB_Ctl_En};
        16'h0018: read_data =       {29'd0,~GPIB_infifo_empty,~GPIB_outfifo_empty_apb,GPIB_State_apb};
        16'h001C: read_data =       32'h21101312            ;
        default : read_data =       {32{1'b0}}              ;               // x propogation
    endcase
end

always @(posedge APB_PCLK or negedge APB_PRESET) begin 
    if (~APB_PRESET)
        APB_PRDATA          <=      {32{1'b0}}              ;
    else if(read_enable)
        APB_PRDATA          <=      read_data               ;
    else
        APB_PRDATA          <=      APB_PRDATA              ;
end 

assign APB_PSLVERR          =       1'b0                    ;

//----------------------------------------------------------------------------------------
//跨时钟域同步：sys_clk -> APB_PCLK
//状态信号 GPIB_State / GPIB_outfifo_empty 在 sys_clk 域产生，被 APB 状态寄存器读取。
//采用 2 级同步器（GPIB_infifo_empty 来自 in-FIFO 读侧，本就在 APB_PCLK 域，无需同步）。
//----------------------------------------------------------------------------------------
reg                                 GPIB_State_sync0, GPIB_State_sync1          ;
reg                                 GPIB_outfifo_empty_sync0, GPIB_outfifo_empty_sync1;
always @(posedge APB_PCLK or negedge APB_PRESET) begin
    if(~APB_PRESET) begin
        GPIB_State_sync0           <= 1'b0;            GPIB_State_sync1           <= 1'b0;
        GPIB_outfifo_empty_sync0   <= 1'b1;            GPIB_outfifo_empty_sync1   <= 1'b1;
    end else begin
        GPIB_State_sync0           <= GPIB_State;                    GPIB_State_sync1           <= GPIB_State_sync0;
        GPIB_outfifo_empty_sync0   <= GPIB_outfifo_empty;            GPIB_outfifo_empty_sync1   <= GPIB_outfifo_empty_sync0;
    end
end
assign                              GPIB_State_apb        = GPIB_State_sync1        ;
assign                              GPIB_outfifo_empty_apb= GPIB_outfifo_empty_sync1;

//----------------------------------------------------------------------------------------
//GPIB发送FIFO的写使能
always @(posedge APB_PCLK or negedge APB_PRESET) begin 
    if (~APB_PRESET)
        write_enable_dly    <=      1'b0                    ;
    else
        write_enable_dly    <=      write_enable            ;
end 

always @(posedge APB_PCLK or negedge APB_PRESET) begin 
    if (~APB_PRESET) begin 
        GPIB_outfifo_w      <=      1'b0                    ;
    end 
    else if((write_enable == 1'b0) && write_enable_dly)begin 
        case (APB_PADDR[15:0])
            16'h0010    :   GPIB_outfifo_w          <=          1'b1    ;
            default     :                                               ;
        endcase 
    end 
    else begin 
        GPIB_outfifo_w      <=      1'b0                    ;
    end 
end 

//----------------------------------------------------------------------------------------
//GPIB接收FIFO的读使能
always @(posedge APB_PCLK or negedge APB_PRESET) begin 
    if (~APB_PRESET)
        read_enable_dly     <=      1'b0                    ;
    else
        read_enable_dly     <=      read_enable             ;
end 

always @(posedge APB_PCLK or negedge APB_PRESET) begin 
    if (~APB_PRESET) begin 
        GPIB_infifo_r       <=      1'b0                    ;
    end 
    else if((read_enable == 1'b0) && read_enable_dly)begin 
        case (APB_PADDR[15:0])
            16'h0010    :   GPIB_infifo_r           <=          1'b1    ;
            default     :                                               ;
        endcase 
    end 
    else begin 
        GPIB_infifo_r       <=      1'b0                    ;
    end 
end 


//----------------------------------------------------------------------------------------
//发送数据保持寄存器：
//  源方握手 SH 在 SGNS 态对异步 FWFT 发送 FIFO 发起一次读(GPIB_outfifo_r 脉冲)，
//  FIFO 读指针随之推进，Q 在下一拍变为下一字节；而 data 是组合逻辑直驱
//  (~GPIB_Data_FPGA_w)，导致 STRS(DAV 有效)阶段总线呈现的是"被读后的下一字节"，
//  真正被读出的首字节从未发出 => 接收端观察到稳定的 +1 偏移并在末尾回绕。
//  修复：在 SIDS(空闲)态锁存当前 FIFO 输出字，整个 SDYS/STRS/SWNS 期间保持稳定，
//  保证发出的正是被读取的字。(属于 CDC 验证过程中发现的发送数据通路功能 bug)
always @(posedge sys_clk or negedge GPIB_dvire_rstn) begin
    if(~GPIB_dvire_rstn)
        GPIB_Data_FPGA_w_hold   <=      8'd0                    ;
    else if(GPIB_SH_State == GPIB_SH_SIDS)
        GPIB_Data_FPGA_w_hold   <=      GPIB_Data_FPGA_w        ;
end

//----------------------------------------------------------------------------------------
//IO延时同步时钟域
assign GPIB_Data_FPGA_r     =       ~data_dly               ;
assign eoiIn                =       ~eoi_dly                ;
assign davIn                =       ~dav_dly                ;
assign nrfdIn               =       ~nrfd_dly               ;
assign ndacIn               =       ~ndac_dly               ;
assign data                 =       GPIB_State      ? (~GPIB_Data_FPGA_w_hold) : 8'bz;
assign eoi                  =       GPIB_State      ? (~eoiOut)           : 1'bz;
assign dav                  =       GPIB_State      ? (~davOut)           : 1'bz;
assign nrfd                 =       (~GPIB_State)   ? (~nrfdOut)          : 1'bz;
assign ndac                 =       (~GPIB_State)   ? (~ndacOut)          : 1'bz;
assign srq                  =       1'b1                    ;               //当前设备不需要上传请求


//----------------------------------------------------------------------------------------
//控者发送设备清除时，GPIB设备回到初始状态
assign GPIB_dvire_rstn      =       (sys_rstn && (~DCAS))   ;

//----------------------------------------------------------------------------------------
//GPIB外部电平转换芯片控制
assign te_a                 =       GPIB_State              ;
assign te_b                 =       GPIB_State              ;
assign dc                   =       1'b1                    ;               //当前设备不能成为控者
assign sc                   =       1'b0                    ;

//----------------------------------------------------------------------------------------
//判断此时FPGA能否回复三线握手，条件是M1能提供设备信息，否则士德上位机无法显示设备信息
always @(posedge sys_clk or negedge sys_rstn) begin 
    if(~sys_rstn)
        M1_ready_count      <=      32'd0                   ;
    else if(M1_ready_count <= INFO_RDY_DLY_CNT)
        M1_ready_count      <=      M1_ready_count + 1'b1   ;
end
always @(posedge sys_clk or negedge sys_rstn) begin 
    if(~sys_rstn)
        M1_ready_information    <=  1'b0                    ;
    else if(M1_ready_count > INFO_RDY_DLY_CNT)
        M1_ready_information    <=  1'b1                    ;
end

//----------------------------------------------------------------------------------------
//GPIB接收指令
always @(posedge sys_clk or negedge GPIB_dvire_rstn) begin 
    if(~GPIB_dvire_rstn) begin 
        LAD                 <=      1'b0                    ;
        TAD                 <=      1'b0                    ;
    end
    else if((~atn_dly) & LADS & ACDS) begin 
        case (GPIB_Data_FPGA_r[6:5])
            2'b01 : begin 
                if((GPIB_Addr_sys == GPIB_Data_FPGA_r[4:0]) && M1_ready_information) begin 
                    LAD     <=      1'b1                    ;
                end
                else begin 
                    LAD     <=      1'b0                    ;
                end
            end

            2'b10 : begin 
                if((GPIB_Addr_sys == GPIB_Data_FPGA_r[4:0]) && M1_ready_information) begin 
                    TAD     <=      1'b1                    ;
                end
                else begin 
                    TAD     <=      1'b0                    ;
                end
            end

            default: begin 
                LAD         <=      LAD                     ;
                TAD         <=      TAD                     ;
            end
        endcase
    end
    else begin 
            LAD             <=      LAD                     ;
            TAD             <=      TAD                     ;
    end 
end

//----------------------------------------------------------------------------------------
//GPIB接口EOI的操作，必须在指定为说者之后，读取一次FIFO之后才允许置高，用于解决指定为说着之后，由于FIFO上一次的数据为结束符，导致EOI直接为高
always @(posedge sys_clk or negedge GPIB_dvire_rstn) begin 
    if(~GPIB_dvire_rstn)
        eoiOut_can_set      <=      1'b1                    ;
    else if((~GPIB_State_dly) && GPIB_State)
        eoiOut_can_set      <=      1'b0                    ;
    else if((SGNS & (~SGNS_dly)))
        eoiOut_can_set      <=      1'b1                    ;
    else
        eoiOut_can_set      <=      eoiOut_can_set          ;
end
assign eoiOut               =       (GPIB_State & atn_dly & (GPIB_Data_FPGA_w_hold == 8'h0A) & eoiOut_can_set) ? 1'b1 : 1'b0;
//always @(posedge sys_clk or negedge GPIB_dvire_rstn) begin 
//    if(~GPIB_dvire_rstn)
//        eoiOut              <=      1'b0                    ;
//    else if(GPIB_State & atn_dly & (GPIB_Data_FPGA_w == 8'h0A) & (GPIB_outfifo_num == 11'd0))
//        eoiOut              <=      1'b1                    ;
//    else if(~GPIB_State)
//        eoiOut              <=      1'b0                    ;
//    else
//        eoiOut              <=      eoiOut                  ;
//end

//----------------------------------------------------------------------------------------
//GPIB接收状态寄存器操作
always @(posedge sys_clk or negedge GPIB_dvire_rstn) begin 
    if(~GPIB_dvire_rstn)
        GPIB_infifo_w       <=      1'b0                    ;
    // Bug4 修复：in-FIFO 写必须限定在"数据阶段"(ATN 释放)。
    // atn_dly 为 32 级移位(专为 NRFD 就绪时序保留)，在 ATN 断言后的 32 周期同步窗口内
    // 仍残留为 1，导致 LACS 仍为 stale-1，控者发来的命令字节(UNL/UNT/MLA)被 AH 握手接受(ACDS)
    // 并误写入 in-FIFO —— 表现为循环监听时 in-FIFO 前缀出现 3F/5F、数据整体偏移、尾部 SEND_TIMEOUT。
    // 因此数据捕获改用快速 2 级同步 ATN(atn_ff1)：ATN 释放(atn_ff1==1)即数据阶段，命中的是真实 ATN，
    // 命令阶段(atn_ff1==0)绝不被写入。L/T 状态机仍用 32 级 atn_dly 以满足 NI 的 110ns NRFD 时序，
    // 而 TB 会在 atn_dly 生效(LACS 置位)后才发数据，故用 atn_ff1 门控不会漏掉任何真实数据字节。
    else if(GPIB_Ctl_En_sys & atn_ff1 & LACS & ACDS)
        GPIB_infifo_w       <=      1'b1                    ;
    else
        GPIB_infifo_w       <=      1'b0                    ;
end

//----------------------------------------------------------------------------------------
//GPIB模块是否可以从FIFO取数发到GPIB总线上
always @(posedge sys_clk or negedge GPIB_dvire_rstn) begin 
    if(~GPIB_dvire_rstn)
        SGNS_dly            <=   1'b0                       ;
    else
        SGNS_dly            <=   SGNS                       ;
end
assign GPIB_outfifo_r       =       (SGNS & (~SGNS_dly)) ? 1'b1 : 1'b0  ;

//----------------------------------------------------------------------------------------
//GPIB模块身份切换
always @(posedge sys_clk or negedge GPIB_dvire_rstn) begin 
    if(~GPIB_dvire_rstn)
        GPIB_State          <=      1'b0                    ;
    else if(~atn_dly)
        GPIB_State          <=      1'b0                    ;
    else if(TAD & atn_dly)
        GPIB_State          <=      1'b1                    ;
    else
        GPIB_State          <=      GPIB_State              ;
end
always @(posedge sys_clk or negedge GPIB_dvire_rstn) begin 
    if(~GPIB_dvire_rstn)
        GPIB_State_dly      <=      1'b0                    ;
    else
        GPIB_State_dly      <=      GPIB_State              ;
end

//----------------------------------------------------------------------------------------
//GPIB器件清除接口：DC
always @(posedge sys_clk or negedge sys_rstn) begin 
    if(~sys_rstn)
        ifc_dly_dly         <=      1'b0                    ;
    else
        ifc_dly_dly         <=      ifc_dly                 ;
end

always @(posedge sys_clk or negedge sys_rstn) begin 
  if(~sys_rstn) begin 
    DCIS                    <=      1'b1                    ;
    DCAS                    <=      1'b0                    ;
    GPIB_DC_State           <=      1'b0                    ;
  end
  else
    case (GPIB_DC_State)
        1'b0 : begin 
            if((~ifc_dly) & ifc_dly_dly & (~DCAS)) begin                                  //IFC有效或者发送不听指令时，复位
                DCIS        <=      1'b0                    ;
                DCAS        <=      1'b1                    ;
                GPIB_DC_State <=    1'b1                    ;
            end
            else begin 
                DCIS        <=      DCIS                    ;
                DCAS        <=      DCAS                    ;
                GPIB_DC_State <=    GPIB_DC_State           ;
            end
        end

        1'b1 : begin 
            if(ifc_dly & (~DCIS)) begin 
                DCIS        <=      1'b1                    ;
                DCAS        <=      1'b0                    ;
                GPIB_DC_State <=    1'b0                    ;
            end
            else begin 
                DCIS        <=      DCIS                    ;
                DCAS        <=      DCAS                    ;
                GPIB_DC_State <=    GPIB_DC_State           ;
            end
        end

        default : begin 
            DCIS            <=      DCIS                    ;
            DCAS            <=      DCAS                    ;
            GPIB_DC_State   <=      GPIB_DC_State           ;
        end
    endcase
end

//----------------------------------------------------------------------------------------
//GPIB器件听者接口：L
always @(posedge sys_clk or negedge sys_rstn) begin 
  if(~sys_rstn) begin 
    LIDS                    <=      1'b1                    ;
    LADS                    <=      1'b0                    ;
    LACS                    <=      1'b0                    ;
    GPIB_L_State            <=      2'd0                    ;
end
  else if (TACS) begin
    // 讲者作用态(TACS)与听者作用态(LACS)互斥：被寻址为讲者时立即清除听者角色，
    // 避免设备同时处于讲者/听者双角色，导致自身发送的字节被自身 AH(受者)握手写回 in-FIFO。
    // (CDC 验证中暴露的"talk 数据回灌 in-FIFO"功能 bug；此前 LAD 听地址锁存未被清，
    //  ATN 释放后 L 状态机在 LAD 仍置位时重新断言 LACS。)
    LIDS <= 1'b1; LADS <= 1'b0; LACS <= 1'b0; LAD <= 1'b0; GPIB_L_State <= 2'd0;
  end
  else
    case (GPIB_L_State)
        2'd0 : begin 
            if(((~ren_dly) | (~atn_dly)) & (~LADS)) begin                   //远程使能或者指令使能（keysight的设备轮询时只有指令使能，远程不使能）时，进入寻址状态
                LIDS        <=      1'b0                    ;
                LADS        <=      1'b1                    ;
                LACS        <=      1'b0                    ;
                GPIB_L_State <=     2'd1                    ;
            end
            else begin 
                LIDS        <=      LIDS                    ;
                LADS        <=      LADS                    ;
                LACS        <=      LACS                    ;
                GPIB_L_State <=     GPIB_L_State            ;
            end 
        end

        2'd1 : begin 
            if(atn_dly & LAD & (~LACS)) begin                               //ATN信号无效且听地址对应时，进入作用状态
                LIDS        <=      1'b0                    ;
                LADS        <=      1'b0                    ;
                LACS        <=      1'b1                    ;
                GPIB_L_State <=     2'd2                    ;
            end
            else begin 
                LIDS        <=      LIDS                    ;
                LADS        <=      LADS                    ;
                LACS        <=      LACS                    ;
                GPIB_L_State <=     GPIB_L_State            ;
            end 
        end

        2'd2 : begin 
            if((~atn_dly) & (~LADS)) begin                                  //ATN信号有效时，进入寻址状态
                LIDS        <=      1'b0                    ;
                LADS        <=      1'b1                    ;
                LACS        <=      1'b0                    ;
                GPIB_L_State <=     2'd1                    ;
            end
            else begin 
                LIDS        <=      LIDS                    ;
                LADS        <=      LADS                    ;
                LACS        <=      LACS                    ;
                GPIB_L_State <=     GPIB_L_State            ;
            end 
        end

        default : begin 
            LIDS            <=      LIDS                    ;
            LADS            <=      LADS                    ;
            LACS            <=      LACS                    ;
            GPIB_L_State    <=      GPIB_L_State            ;
        end
    endcase
end

//----------------------------------------------------------------------------------------
//GPIB器件讲者接口：T
always @(posedge sys_clk or negedge GPIB_dvire_rstn) begin 
    if(~GPIB_dvire_rstn) begin 
        TIDS                <=      1'b1                    ;
        TADS                <=      1'b0                    ;
        TACS                <=      1'b0                    ;
        GPIB_T_State        <=      2'd0                    ;
    end
    else begin 
        case (GPIB_T_State)
            2'd0 : begin 
                if((~ren_dly) & (~TADS)) begin                              //远程使能时，进入寻址状态
                    TIDS    <=      1'b0                    ;
                    TADS    <=      1'b1                    ;
                    TACS    <=      1'b0                    ;
                    GPIB_T_State <= 2'd1                    ;
                end
                else begin 
                    TIDS    <=      TIDS                    ;
                    TADS    <=      TADS                    ;
                    TACS    <=      TACS                    ;
                    GPIB_T_State <= GPIB_T_State            ;
                end 
            end

            2'd1 : begin 
                if(atn_dly & TAD & (~TACS)) begin                           //ATN信号无效且讲地址对应时，进入作用状态
                    TIDS    <=      1'b0                    ;
                    TADS    <=      1'b0                    ;
                    TACS    <=      1'b1                    ;
                    GPIB_T_State <= 2'd2                    ;
                end
                else if(ren_dly & (~TIDS)) begin                            //复位或者本地使能时，进入空闲态
                    TIDS    <=      1'b1                    ;
                    TADS    <=      1'b0                    ;
                    TACS    <=      1'b0                    ;
                    GPIB_T_State <= 2'd0                    ;
                end
                else begin 
                    TIDS    <=      TIDS                    ;
                    TADS    <=      TADS                    ;
                    TACS    <=      TACS                    ;
                    GPIB_T_State <= GPIB_T_State            ;
                end 
            end

            2'd2 : begin 
                if((~atn_dly) & (~TADS)) begin                              //ATN信号有效时，进入寻址状态
                    TIDS    <=      1'b0                    ;
                    TADS    <=      1'b1                    ;
                    TACS    <=      1'b0                    ;
                    GPIB_T_State <= 2'd1                    ;
                end
                else if(ren_dly & (~TIDS)) begin                            //复位或者本地使能时，进入空闲态
                    TIDS    <=      1'b1                    ;
                    TADS    <=      1'b0                    ;
                    TACS    <=      1'b0                    ;
                    GPIB_T_State <= 2'd0                    ;
                end
                else begin 
                    TIDS    <=      TIDS                    ;
                    TADS    <=      TADS                    ;
                    TACS    <=      TACS                    ;
                    GPIB_T_State <= GPIB_T_State            ;
                end 
            end

            default : begin 
                TIDS        <=      TIDS                    ;
                TADS        <=      TADS                    ;
                TACS        <=      TACS                    ;
                GPIB_T_State    <=  GPIB_T_State            ;
            end
        endcase
    end 
end

//----------------------------------------------------------------------------------------
//GPIB器件受方挂钩功能接口：AH
always @(posedge sys_clk or negedge GPIB_dvire_rstn) begin 
    if(~GPIB_dvire_rstn) 
        GPIB_AH_State       <=      GPIB_AH_AIDS            ;
    else  begin 
        case (GPIB_AH_State)
            GPIB_AH_AIDS : GPIB_AH_State <= ((LAD | (~atn_dly)) & (~ANRS))                  ? GPIB_AH_ANRS : GPIB_AH_AIDS;      //SIGHT的USB转GPIB，会定时发控者指令(0x3F)，用于扫描设备是否在线，但是REN信号不置低，听者也需要握手以判断是否有设备在线
                                                                                                                                //SIGHT检测设备是否在线的逻辑为：REN信号无效的情况下，轮询将31个地址设为听地址，依次判断听者是否准备就绪（ATN为高时，NDAC是否置低）
            GPIB_AH_ANRS : GPIB_AH_State <= ((LAD | (~atn_dly)) & (~ACRS))                  ? GPIB_AH_ACRS : GPIB_AH_ANRS;
            GPIB_AH_ACRS : GPIB_AH_State <= (davIn & (~ACDS))                               ? GPIB_AH_ACDS : 
                                            ((~LAD) & atn_dly & (~AIDS))                    ? GPIB_AH_AIDS : GPIB_AH_ACRS;      //SIGHT扫描设备是否在线时，会依次将设备设为听者，再将ATN信号置为数据传输，REN远程使能打开，看设备是否就绪。
                                                                                                                                //NI   扫描设备是否在线时，会依次将设备设为听者，再将ATN信号置为数据传输，REN远程使能关闭，看设备是否就绪。
            GPIB_AH_ACDS : GPIB_AH_State <= ((GPIB_infifo_w | LADS) & (~AWNS))              ? GPIB_AH_AWNS : GPIB_AH_ACDS;      //受方挂钩：若是挂钩指令（LADS有效），则直接进入下一个状态；若是挂钩数据，则需要等待数据被取走
            GPIB_AH_AWNS : GPIB_AH_State <= ((~davIn) & (~ANRS))                            ? GPIB_AH_AIDS : GPIB_AH_AWNS;
            default      : GPIB_AH_State <= GPIB_AH_State   ;
        endcase
    end 
end

always @(posedge sys_clk or negedge GPIB_dvire_rstn) begin 
    if(~GPIB_dvire_rstn) begin 
        AIDS                <=      1'b1                    ;
        ANRS                <=      1'b0                    ;
        ACRS                <=      1'b0                    ;
        ACDS                <=      1'b0                    ;
        AWNS                <=      1'b0                    ;

        nrfdOut             <=      1'b1                    ;
        ndacOut             <=      1'b1                    ;
    end
    else begin 
        case (GPIB_AH_State)
            GPIB_AH_AIDS : begin 
                AIDS        <=      1'b1                    ;
                ANRS        <=      1'b0                    ;
                ACRS        <=      1'b0                    ;
                ACDS        <=      1'b0                    ;
                AWNS        <=      1'b0                    ;

                nrfdOut     <=      1'b0                    ;
                ndacOut     <=      1'b0                    ;
            end

            GPIB_AH_ANRS : begin 
                AIDS        <=      1'b0                    ;
                ANRS        <=      1'b1                    ;
                ACRS        <=      1'b0                    ;
                ACDS        <=      1'b0                    ;
                AWNS        <=      1'b0                    ;

                nrfdOut     <=      1'b0                    ;
                ndacOut     <=      1'b1                    ;
            end

            GPIB_AH_ACRS : begin 
                AIDS        <=      1'b0                    ;
                ANRS        <=      1'b0                    ;
                ACRS        <=      1'b1                    ;
                ACDS        <=      1'b0                    ;
                AWNS        <=      1'b0                    ;

                nrfdOut     <=      1'b0                    ;
                ndacOut     <=      1'b1                    ;
            end

            GPIB_AH_ACDS : begin 
                AIDS        <=      1'b0                    ;
                ANRS        <=      1'b0                    ;
                ACRS        <=      1'b0                    ;
                ACDS        <=      1'b1                    ;
                AWNS        <=      1'b0                    ;

                nrfdOut     <=      1'b1                    ;
                ndacOut     <=      1'b1                    ;
            end

            GPIB_AH_AWNS : begin 
                AIDS        <=      1'b0                    ;
                ANRS        <=      1'b0                    ;
                ACRS        <=      1'b0                    ;
                ACDS        <=      1'b0                    ;
                AWNS        <=      1'b1                    ;

                nrfdOut     <=      1'b1                    ;
                ndacOut     <=      1'b0                    ;
            end

            default      : begin 
                AIDS        <=      AIDS                    ;
                ANRS        <=      ANRS                    ;
                ACRS        <=      ACRS                    ;
                ACDS        <=      ACDS                    ;
                AWNS        <=      AWNS                    ;

                nrfdOut     <=      nrfdOut                 ;
                ndacOut     <=      ndacOut                 ;
            end
        endcase
    end 
end

//----------------------------------------------------------------------------------------
//GPIB器件源方挂钩功能接口：SH
always @(posedge sys_clk or negedge GPIB_dvire_rstn) begin 
    if(~GPIB_dvire_rstn) begin 
        GPIB_SH_State       <=      GPIB_SH_SIDS            ;
    end
    else begin 
        case (GPIB_SH_State)
            GPIB_SH_SIDS : GPIB_SH_State <= ((~GPIB_outfifo_empty) & TACS & (~SGNS))    ? GPIB_SH_SGNS : GPIB_SH_SIDS;      //进入讲者作用态后开始发送数据
            GPIB_SH_SGNS : GPIB_SH_State <= (GPIB_outfifo_r & (~SDYS))                  ? GPIB_SH_SDYS : GPIB_SH_SGNS;      //创建状态就绪数据，此时读取一次FIFO
            GPIB_SH_SDYS : GPIB_SH_State <= ((~nrfdIn) & (~STRS))                       ? GPIB_SH_STRS : GPIB_SH_SDYS;      //等待听者就绪
            GPIB_SH_STRS : GPIB_SH_State <= ((~ndacIn) & (~SWNS))                       ? GPIB_SH_SWNS : GPIB_SH_STRS;      //等待听者接收数据
            GPIB_SH_SWNS : GPIB_SH_State <= ((~SIWS))                                   ? GPIB_SH_SIDS : GPIB_SH_SWNS;      //等待下一次握手
            GPIB_SH_SIWS : GPIB_SH_State <= (~SIDS)                                     ? GPIB_SH_SIDS : GPIB_SH_SIWS;      //空闲等待：不会进入此状态

            default      : GPIB_SH_State <= GPIB_SH_State   ;
        endcase
    end 
end

always @(posedge sys_clk or negedge GPIB_dvire_rstn) begin 
    if(~GPIB_dvire_rstn) begin 
        SIDS                <=      1'b1                    ;
        SGNS                <=      1'b0                    ;
        SDYS                <=      1'b0                    ;
        STRS                <=      1'b0                    ;
        SWNS                <=      1'b0                    ;
        SIWS                <=      1'b0                    ;

        davOut              <=      1'b0                    ;
    end
    else
        case (GPIB_SH_State)
            GPIB_SH_SIDS : begin 
                SIDS        <=      1'b1                    ;
                SGNS        <=      1'b0                    ;
                SDYS        <=      1'b0                    ;
                STRS        <=      1'b0                    ;
                SWNS        <=      1'b0                    ;
                SIWS        <=      1'b0                    ;

                davOut      <=      1'b0                    ;
            end

            GPIB_SH_SGNS : begin 
                SIDS        <=      1'b0                    ;
                SGNS        <=      1'b1                    ;
                SDYS        <=      1'b0                    ;
                STRS        <=      1'b0                    ;
                SWNS        <=      1'b0                    ;
                SIWS        <=      1'b0                    ;

                davOut      <=      1'b0                    ;
            end

            GPIB_SH_SDYS : begin 
                SIDS        <=      1'b0                    ;
                SGNS        <=      1'b0                    ;
                SDYS        <=      1'b1                    ;
                STRS        <=      1'b0                    ;
                SWNS        <=      1'b0                    ;
                SIWS        <=      1'b0                    ;

                davOut      <=      1'b0                    ;
            end

            GPIB_SH_STRS : begin 
                SIDS        <=      1'b0                    ;
                SGNS        <=      1'b0                    ;
                SDYS        <=      1'b0                    ;
                STRS        <=      1'b1                    ;
                SWNS        <=      1'b0                    ;
                SIWS        <=      1'b0                    ;

                davOut      <=      1'b1                    ;
            end

            GPIB_SH_SWNS : begin 
                SIDS        <=      1'b0                    ;
                SGNS        <=      1'b0                    ;
                SDYS        <=      1'b0                    ;
                STRS        <=      1'b0                    ;
                SWNS        <=      1'b1                    ;
                SIWS        <=      1'b0                    ;

                davOut      <=      1'b0                    ;
            end

            GPIB_SH_SIWS : begin 
                SIDS        <=      1'b0                    ;
                SGNS        <=      1'b0                    ;
                SDYS        <=      1'b0                    ;
                STRS        <=      1'b0                    ;
                SWNS        <=      1'b0                    ;
                SIWS        <=      1'b1                    ;

                davOut      <=      1'b0                    ;
            end

            default      : begin 
                SIDS        <=      SIDS                    ;
                SGNS        <=      SGNS                    ;
                SDYS        <=      SDYS                    ;
                STRS        <=      STRS                    ;
                SWNS        <=      SWNS                    ;
                SIWS        <=      SIWS                    ;

                davOut      <=      davOut                  ;
            end
        endcase
end

//----------------------------------------------------------------------------------------
//FPGA从GPIB获取的数据
always @(posedge sys_clk or negedge sys_rstn) begin 
    if (~sys_rstn)
        GPIB_infifo_w_dly   <=      1'b0                    ;
    else
        GPIB_infifo_w_dly   <=      GPIB_infifo_w           ;
end 

GPIB_fifo_in u_GPIB_fifo_in_0(
    .WrClk                          (sys_clk                ),              //写侧时钟 : GPIB数据到达 (sys_clk 域)
    .RdClk                          (APB_PCLK               ),              //读侧时钟 : APB读取 (APB_PCLK 域)
    .Data                           (GPIB_Data_FPGA_r       ),              //input [7:0] Data
    .WrEn                           (GPIB_infifo_w && (GPIB_infifo_w_dly == 1'b0)),              //input WrEn
    .RdEn                           (GPIB_infifo_r          ),              //input RdEn
    .Reset                          (~GPIB_dvire_rstn       ),              //input Reset (高有效)
    .Q                              (GPIB_Data_M1_r         ),              //output [7:0] Q (APB_PCLK 域)
    .Empty                          (GPIB_infifo_empty      ),              //output Empty (APB_PCLK 域)
    .Full                           (GPIB_infifo_full       )               //output Full (sys_clk 域)
);

//----------------------------------------------------------------------------------------
//GPIB从FPGA获取的数据
GPIB_fifo_out u_GPIB_fifo_out_0(
    .WrClk                          (APB_PCLK               ),              //写侧时钟 : APB写入 (APB_PCLK 域)
    .RdClk                          (sys_clk                ),              //读侧时钟 : GPIB发送 (sys_clk 域)
    .Data                           (GPIB_Data_M1_w         ),              //input [7:0] Data (APB_PCLK 域)
    .WrEn                           (GPIB_outfifo_w         ),              //input WrEn (APB_PCLK 域)
    .RdEn                           (GPIB_outfifo_r         ),              //input RdEn (sys_clk 域)
    .Reset                          (~GPIB_dvire_rstn       ),              //input Reset (高有效)
    .Wnum                           (GPIB_outfifo_num       ),              //output [10:0] Wnum (APB_PCLK 域)
    .Q                              (GPIB_Data_FPGA_w       ),              //output [7:0] Q (sys_clk 域)
    .Empty                          (GPIB_outfifo_empty     ),              //output Empty (sys_clk 域)
    .Full                           (GPIB_outfifo_full      )               //output Full (APB_PCLK 域)
);

//----------------------------------------------------------------------------------------
//GPIB错误状态获取
always @(posedge sys_clk or negedge GPIB_dvire_rstn) begin 
    if (~GPIB_dvire_rstn)
        GPIB_error          <=      8'd0                    ;
    else if(GPIB_error == 8'd0) begin 
        if(GPIB_infifo_full)
            GPIB_error      <=      8'd1                    ;
        else if(GPIB_outfifo_full_sys)
            GPIB_error      <=      8'd2                    ;
        else 
            GPIB_error      <=      GPIB_error              ;
    end 
    else 
        GPIB_error          <=      GPIB_error              ;
end 

endmodule
