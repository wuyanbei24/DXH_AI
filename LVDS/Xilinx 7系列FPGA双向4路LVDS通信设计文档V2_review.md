# Xilinx 7系列FPGA双向4路LVDS通信设计文档 V2 — 模块设计评审报告

**评审对象**：`Xilinx 7系列FPGA双向4路LVDS通信设计文档_V2.md`
**评审范围**：6 个 RTL 模块（`lvds_tx_channel`、`lvds_rx_phy`、`lvds_rx_link`、`lvds_rx_channel`、`lvds_link_manager`、`lvds_bidirectional_top`）、链路管理状态机、仿真 Testbench
**评审日期**：2026-07-25

---

## 评审结论

该文档存在 **11 个致命问题** 和 **7 个中等问题**，当前代码**无法综合实现预期功能，也无法通过仿真验证**。最核心的三个系统性缺陷是：

1. **时钟架构缺失**：没有 MMCM/PLL，SerDes 时钟关系完全错误，物理层无法工作
2. **建链协议设计缺陷**：从机停止训练码的时机和主机发 ACK 的时机都违反握手逻辑，会导致死锁
3. **重训练链路断裂**：链路层检测的错误信号没有连到物理层，重训练机制形同虚设

建议优先修复致命问题 1-11，再处理跨时钟域同步和仿真环境问题。

---

## 🔴 致命问题（导致设计无法工作）

### 1. 发送通道时钟关系完全错误 — `lvds_tx_channel.v`

```verilog
assign clk_div = clk_ref;
assign clk_ser = clk_ref; // 实际工程需MMCM倍频为8倍并行时钟
```

OSERDESE2 在 **DDR + DATA_WIDTH=8** 模式下，要求 `CLK(串行) = 4 × CLKDIV(并行)`。代码中两者相等，且没有任何 MMCM/PLL 例化。这会导致：
- 串行化完全错误，输出数据率 = 并行时钟率（而非 8 倍）
- 时钟通道输出的 `10101010` 模式产生的时钟频率与数据不匹配
- 接收端无法完成解串

**修复**：必须例化 MMCM/PLL，由 `clk_ref` 生成 `clk_ser`（8× 并行频率）和 `clk_div`（并行频率），且两者严格 4:1（DDR）或 8:1（SDR）。

---

### 2. BUFR 分频比与 ISERDESE2 模式不匹配 — `lvds_rx_phy.v`

```verilog
BUFR #(.BUFR_DIVIDE("8"), ...) u_bufr_div ( ... );
ISERDESE2 #(.DATA_RATE("DDR"), .DATA_WIDTH(8), ...) ...
```

DDR 8-bit 解串需要 `CLKDIV = CLK/4`，因此 `BUFR_DIVIDE` 应为 **"4"** 而非 "8"。当前配置会导致并行时钟频率错误，ISERDESE2 无法正确对齐 8 位数据。

---

### 3. 缺少 IDELAYCTRL 原语 — `lvds_rx_phy.v`

```verilog
IDELAYE2 #(.REFCLK_FREQUENCY(200.0), ...) u_idelay_data ( ... );
```

7 系列 FPGA 使用 IDELAYE2 **必须**同时例化 `IDELAYCTRL` 并提供 200MHz 参考时钟（REFCLK），否则延迟 tap 值不可靠、不精确。代码中完全没有 `IDELAYCTRL`，整个延迟校准算法的基础就不成立。

---

### 4. 延迟扫描采样计数器溢出，状态机卡死 — `lvds_rx_phy.v`

```verilog
reg [3:0] sample_cnt;          // 4位，最大值15
...
D_WAIT: if(sample_cnt >= SAMPLE_CNT[3:0]) d_next_state = D_SAMPLE;  // SAMPLE_CNT=16
```

- `sample_cnt` 是 4 位，**永远无法达到 16**（最大到 15 后回绕到 0）
- `SAMPLE_CNT[3:0]` = `16[3:0]` = `4'd0`，条件变成 `sample_cnt >= 0` 恒为真
- 结果：`D_WAIT` 状态第一拍就跳走，**根本不执行 16 次采样**，延迟校准完全失效

**修复**：`sample_cnt` 改为至少 5 位；比较改为 `sample_cnt >= SAMPLE_CNT-1`。

---

### 5. retry_cnt 每时钟周期递增，迅速永久故障锁定 — `lvds_rx_phy.v`

```verilog
M_DELAY_SCAN: begin
    scan_start <= 1'b0;
    retry_cnt <= retry_cnt + 1'b1;   // 每个时钟周期都+1！
end
...
M_FAULT: if(retry_cnt < MAX_RETRY) m_next_state = M_IDLE;
```

`retry_cnt` 在 `M_DELAY_SCAN` 状态**每个时钟周期**递增，而非每次重试递增一次。扫描过程持续数千周期，`retry_cnt`（2位，MAX_RETRY=3）瞬间溢出，导致 `M_FAULT` 永远无法回到 `M_IDLE`，链路永久锁死。

**修复**：`retry_cnt` 应在每次进入 `M_DELAY_SCAN`（即每次重试开始）时递增一次，且 `M_IDLE`/`M_NORMAL` 状态需清零。

---

### 6. 链路层重训练请求无法触发物理层 — `lvds_bidirectional_top.v`

```verilog
lvds_rx_channel u_rx (
    .retrain_req(ext_retrain_req),      // 只接外部请求！
    ...
    .retrain_trigger(rx_retrain_req)    // 内部错误信号输出
);
```

接收通道的 `retrain_req` 输入只连接了 `ext_retrain_req`（外部强制），而链路层检测到心跳超时/校验错误产生的 `rx_retrain_req`（从 `retrain_trigger` 输出）**没有回送到物理层的 `retrain_req`**。这意味着：心跳超时和连续校验错误**永远不会触发物理层重训练**，重训练机制的核心功能失效。

**修复**：`.retrain_req(ext_retrain_req | rx_retrain_req)`。

---

### 7. 输出端口连接表达式，语法非法 — `lvds_bidirectional_top.v`

```verilog
output wire user_rx_valid;   // 顶层输出
...
lvds_rx_channel u_rx (
    .rx_data_valid(user_rx_valid & user_rx_en),  // 输出端口连表达式
```

`rx_data_valid` 是 `lvds_rx_channel` 的 **output** 端口，不能连接到 `user_rx_valid & user_rx_en` 这样的表达式（且 `user_rx_valid` 自身是顶层输出，形成自引用）。多数综合工具会报错。

**修复**：定义内部 wire 接收原始 valid，再用 `assign` 做门控：
```verilog
wire rx_valid_raw;
.rx_data_valid(rx_valid_raw),
...
assign user_rx_valid = rx_valid_raw & user_rx_en;
```

---

### 8. 建链协议核心缺陷：从机过早停止发送训练码 — `lvds_link_manager.v`

```verilog
S_WAIT_PEER: begin
    tx_train_en <= 1'b0;   // 停止训练码，改发控制帧
    ...
    ctrl_frame_send <= 1'b1;
```

从机在本地接收就绪（`rx_phy_ready`）后立即进入 `S_WAIT_PEER`，将 `tx_train_en` 拉低，停止发送 `0x55` 训练码，改发控制帧。但此时**主机可能尚未完成接收链路训练**（位对齐/字对齐需要持续接收 `0x55`）。控制帧内容不是训练码，主机物理层无法完成校准，导致建链死锁。

**修复**：从机在 `S_WAIT_PEER` 状态应保持 `tx_train_en=1`，通过带外机制或训练码中嵌入就绪标志通知主机；或定义"训练帧"格式，在训练码中携带就绪状态。

---

### 9. 主机无条件提前发送 MASTER_ACK — `lvds_link_manager.v`

```verilog
S_WAIT_PEER: begin
    ...
    if(ctrl_send_timer >= CTRL_SEND_INTERVAL) begin
        ctrl_frame_send <= 1'b1;
        if(IS_MASTER) begin
            ctrl_frame_type_out <= TYPE_MASTER_ACK;  // 没收到SLAVE_READY就发ACK
```

主机进入 `S_WAIT_PEER` 后**立即周期性发送 MASTER_ACK**，而非在收到 SLAVE_READY 之后才发。这违反文档 2.4 节定义的流程（"主机确认双向链路均建立后才发确认帧"）。后果：
- 从机可能收到过早的 MASTER_ACK 而进入 LINK_UP，但主机还在等 SLAVE_READY
- 主从状态不同步

**修复**：主机应在 `ctrl_frame_valid && type==SLAVE_READY` 后才开始发 MASTER_ACK。

---

### 10. retrain_req 自清零导致脉冲极窄 — `lvds_rx_link.v`

```verilog
F_DONE: begin
    ...
    if(frame_err_cnt >= MAX_ERR_CNT) retrain_req <= 1'b1;
end
...
// 同一always块末尾：
if(retrain_req) retrain_req <= 1'b0;
```

`retrain_req` 在 `F_DONE` 中被置 1，但同一时序块末尾又有 `if(retrain_req) retrain_req <= 1'b0`。由于非阻塞赋值，`retrain_req` 实际只拉高**一个时钟周期**。该脉冲从 `clk_div` 域跨到 `clk_ref` 域（链路管理器），无同步器，极易被漏采。

---

### 11. frame_len==0 时校验和字节被吞 — `lvds_rx_link.v`

```verilog
F_LEN: begin
    if(frame_len != 8'd0) begin
        // 处理payload...
    end
    // frame_len==0时什么都不做，但rx_data_in已经是Checksum字节！
end
F_CHECKSUM: begin
    if(rx_data_in == checksum_calc) ...  // 此时rx_data_in是下一帧的字节
```

状态机每个状态消费一个字节。`F_LEN` 状态的 `rx_data_in` 在 `frame_len==0` 时是 Checksum 字节，但代码跳过不处理；`F_CHECKSUM` 状态消费的是**下一帧的字节**，校验和比对必然错误。虽然当前帧类型 Length 均≥1，但用户数据帧允许 Length=0，设计应正确处理。

---

## 🟡 中等问题（时序/可靠性隐患）

### 12. 跨时钟域完全未同步

链路管理器用 `clk_ref`（本地参考时钟），但以下信号来自接收通道的 `clk_div`（BUFR 恢复时钟，与 `clk_ref` 异步）：
- `rx_phy_ready`、`rx_link_up`、`rx_retrain_req`
- `ctrl_frame_valid`、`ctrl_frame_type`、`ctrl_frame_payload`

全部直接连接，**无两级同步器**，存在亚稳态风险，可能导致链路管理器状态机跑飞。

---

### 13. BITSLIP 脉冲非单周期，可能跳过对齐位置 — `lvds_rx_phy.v`

```verilog
M_WORD_ALIGN: begin
    bitslip_req <= 1'b0;
    if(iserdes_q == 8'hB5) ... 
    else begin
        bitslip_req <= 1'b1;   // 持续拉高直到匹配
```

`bitslip_req` 在数据不匹配时持续拉高，ISERDESE2 会在每个 CLKDIV 上升沿执行 BITSLIP，可能连续移位多拍，跳过正确的字对齐位置。正确做法：每次只拉高**一个周期**，等待 ISERDESE2 稳定（1-2 拍）后再采样判断。

---

### 14. M_LOCK_CHECK 锁定检测不可靠 — `lvds_rx_phy.v`

```verilog
M_LOCK_CHECK: if(lock_timer >= 16'd5000) 
    m_next_state = (iserdes_q == 8'hB5) ? M_NORMAL : M_FAULT;
```

等待 5000 周期后检查 `iserdes_q == 8'hB5`，但此时发送端发什么未定义。字对齐阶段发 `0xB5`，但锁定检查阶段发送端可能已切换到帧/空闲填充 `0x55`。单次采样命中 `0xB5` 概率极低，几乎必然进入 `M_FAULT`。

---

### 15. 心跳超时参数与心跳周期不匹配 — `lvds_rx_link.v`

- `HEARTBEAT_TIMEOUT_CNT = 16'd50000`，100MHz 下 = **0.5ms**
- 心跳周期 `HEARTBEAT_MS = 1`ms

超时阈值(0.5ms) < 心跳周期(1ms)，正常心跳到达前就触发超时，导致频繁误触发重训练。

---

### 16. tx_ready 门控过严，吞吐量严重受限 — `lvds_tx_channel.v`

```verilog
assign tx_ready = ~fifo_full && ~train_en && (tx_curr_state == TX_IDLE);
```

`tx_ready` 仅在 `TX_IDLE` 有效。发送状态机每发一帧经历 7 个状态（约 7+ 周期），期间用户无法写入 FIFO。用户数据有效带宽利用率 < 1/8。

---

### 17. 文档与代码不一致：累计 vs 连续错误

文档 3.2.5 节："累计10帧校验和错误"触发重训练。代码实现：
```verilog
F_CHECKSUM: if(rx_data_in == checksum_calc) frame_err_cnt <= 4'd0;  // 正确即清零
            else frame_err_cnt <= frame_err_cnt + 1'b1;
```
实际是"**连续**10帧错误"，中间一次正确就清零。语义不同。

---

### 18. F_DONE 状态多余且引入帧同步风险 — `lvds_rx_link.v`

`F_DONE` 消费一个字节但不检测帧头，依赖发送端 `TX_CHECKSUM→TX_IDLE(输出0x55)→TX_SOF1` 保证帧间至少一个 `0x55`。若噪声将该 `0x55` 翻转为 `0xAA`，`F_IDLE` 会误判为 SOF1，帧同步丢失。`F_DONE` 完全可以合并到 `F_CHECKSUM`。

---

## 🟠 仿真 Testbench 问题

### 19. 信号未声明
```verilog
assign m2s_data_p_final = ...  // m2s_data_p_final 未声明
```
`m2s_data_p_final`、`m2s_data_n_final`、`s2m_data_p_final`、`s2m_data_n_final` 使用前未用 `wire` 声明。

### 20. 时钟线无延迟、无故障注入
只对数据线建模延迟和断链，时钟线（`m2s_clk_p/n`）直连。断链时数据断但时钟不断，不能真实模拟链路故障，且与实际物理链路（时钟数据均有延迟）不符。

### 21. 缺少 Xilinx 仿真库
OSERDESE2/ISERDESE2/IDELAYE2/BUFIO/BUFR 均需 `UNISIM` 库，Testbench 未 `include` 或指定库，仿真无法编译。

### 22. 比对逻辑跨时钟域采样
```verilog
always @(posedge clk_ref_slave) begin
    if(slv_rx_valid && slv_link_up) ...  // slv_rx_valid来自clk_div域
```
用 `clk_ref_slave` 采样恢复时钟域的 `slv_rx_valid`，仿真可能侥幸通过，但逻辑不严谨。

---

## 📋 问题汇总表

| 编号 | 严重度 | 模块 | 问题摘要 |
|------|--------|------|----------|
| 1 | 🔴致命 | tx_channel | clk_ser=clk_div，缺MMCM倍频 |
| 2 | 🔴致命 | rx_phy | BUFR_DIVIDE="8"应为"4" |
| 3 | 🔴致命 | rx_phy | 缺IDELAYCTRL原语 |
| 4 | 🔴致命 | rx_phy | sample_cnt 4位无法≥16，扫描卡死 |
| 5 | 🔴致命 | rx_phy | retry_cnt每周期递增，永久锁死 |
| 6 | 🔴致命 | top | 链路层错误无法触发物理层重训练 |
| 7 | 🔴致命 | top | 输出端口连表达式，语法非法 |
| 8 | 🔴致命 | link_mgr | 从机过早停训练码，建链死锁 |
| 9 | 🔴致命 | link_mgr | 主机无条件提前发ACK |
| 10 | 🔴致命 | rx_link | retrain_req自清零，脉冲极窄 |
| 11 | 🔴致命 | rx_link | frame_len=0时Checksum字节丢失 |
| 12 | 🟡中等 | top/link_mgr | 跨时钟域无同步器 |
| 13 | 🟡中等 | rx_phy | BITSLIP非单周期脉冲 |
| 14 | 🟡中等 | rx_phy | M_LOCK_CHECK单次采样不可靠 |
| 15 | 🟡中等 | rx_link | 心跳超时0.5ms<心跳周期1ms |
| 16 | 🟡中等 | tx_channel | tx_ready门控过严，带宽<1/8 |
| 17 | 🟡中等 | rx_link | 文档"累计"vs代码"连续"错误 |
| 18 | 🟡中等 | rx_link | F_DONE多余且引入同步风险 |
| 19-22 | 🟠仿真 | tb | 信号未声明/时钟无故障注入/缺库/跨域采样 |

---

## 修复优先级建议

1. **第一优先级（致命，阻塞综合）**：问题 1、2、3、7 — 修复时钟架构和语法错误
2. **第二优先级（致命，阻塞功能）**：问题 4、5、6、8、9、10、11 — 修复状态机和信号连接
3. **第三优先级（中等，影响可靠性）**：问题 12-18 — 跨时钟域同步、参数匹配、协议一致性
4. **第四优先级（仿真环境）**：问题 19-22 — Testbench 修正

如需针对某个具体问题给出修复代码，请告知对应问题编号。
