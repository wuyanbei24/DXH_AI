# 修复方案 vs 当前设计 — 对比说明（LANE_CNT 可参数化目标）

> 本文档对比「LANE_CNT=1 缺陷分析」第 5 节提出的 4 项修复方案与当前 RTL 实现的具体差异。
> **仅做对比说明，未修改任何设计文件。** 所有引用均基于当前源码真实行号。
>
> 关键前提（已确认）：`fifo_dout` / `tx_data_mux` / `rx_data_in` 总线位宽本就是 `LANE_CNT*DATA_WIDTH`（见 `lvds_tx_channel.v:44/50`、`lvds_rx_link.v:21`），PAYLOAD 字宽已随 LANE_CNT 缩放。问题**只集中在「帧头 / SOF 检测 / 校验和累加 / 多字节字段 / 硬编码 lane 索引」这几处把数据按 3 字节（LANE_CNT=3）假设硬编码的地方**。

---

## 0. 总览：当前设计与修复方案的哲学差异

| 维度 | 当前设计 | 修复方案 |
|---|---|---|
| 帧格式视角 | **「字宽对齐」视角**：假设每时钟吞吐 = 24bit（3 字节），帧头/校验/心跳都按 24bit 字布局 | **「字节流」视角**：帧格式定义为字节序列，与每时钟多少字节（LANE_CNT）解耦 |
| LANE_CNT 假设 | 隐式假定 = 3（所有硬编码 24bit / 固定字节位） | 显式按 `LANE_CNT` 参数化（循环 / generate / 序列化） |
| 适配 LANE_CNT=1 | ❌ 编译或功能失败（位宽截断、越界 X） | ✅ 仅改参数即可 |

---

## 1. 帧头序列化 + 移位序列 SOF 检测

### 1.1 当前设计

**TX — 帧头作为「一个 24bit 字」同时发出**（`lvds_tx_channel.v:290`）：

```verilog
TX_SOF_TYPE: begin
    tx_data_mux = {tx_type_sel, FRAME_SOF2, FRAME_SOF1};   // 24bit 字面量
    // 例: TYPE_USR=0x20 → 0x20_55_AA
end
```

`tx_data_mux` 位宽为 `LANE_CNT*8`（:44）。当 `LANE_CNT=1`（8bit）时，Verilog 把 24bit RHS **截断掉高 16bit**，只保留低 8bit = `FRAME_SOF1(0xAA)` → **SOF2(0x55) 与 TYPE 全部丢失**。

**RX — SOF 用「单字并行比较固定字节位」检测**（`lvds_rx_link.v:66` + `:144-149`）：

```verilog
wire sof_detected = (rx_data_in[7:0] == SOF_BYTE1 && rx_data_in[15:8] == SOF_BYTE2);
// ...
F_IDLE: if(sof_detected) begin
    frame_type <= rx_data_in[23:16];        // TYPE 取自最高字节
    checksum_calc <= SOF_BYTE1 + SOF_BYTE2 + rx_data_in[23:16];
end
```

`rx_data_in` 为 `LANE_CNT*8`。`LANE_CNT=1` 时 `[15:8]`、`[23:16]` **不存在（越界 → X/z）**：
- `sof_detected` 因 `rx_data_in[15:8]==0x55` 恒为假 → 状态机**永远卡在 F_IDLE**；
- 即便能进，TYPE 也从越界位读到 0/X → 帧被误判为控制帧分支。

### 1.2 修复方案

**TX — 帧头逐字节「序列化」**，SOF1→SOF2→TYPE 各自占一个窄字周期（每个时钟只放 byte0）：

```verilog
// 新增 TX 子状态: TX_SOF1 → TX_SOF2 → TX_TYPE, 每个状态输出 1 字节
TX_SOF1: tx_data_mux = {{(LANE_CNT-1)*8{1'b0}}, FRAME_SOF1};   // 仅 byte0=0xAA
TX_SOF2: tx_data_mux = {{(LANE_CNT-1)*8{1'b0}}, FRAME_SOF2};   // 仅 byte0=0x55
TX_TYPE: tx_data_mux = {{(LANE_CNT-1)*8{1'b0}}, tx_type_sel};  // 仅 byte0=TYPE
```

无论 `LANE_CNT=1/3/4`，帧头恒为 **3 个字节周期**，每个字节独占 byte0，绝不丢字节。

**RX — 「移位寄存器序列检测」**替代固定位比较：

```verilog
reg [7:0] rx_sr [0:1];   // 2 级字节移位寄存器 (滑动窗口)
always @(posedge clk) if(rx_data_valid) {rx_sr[1], rx_sr[0]} <= {rx_sr[0], rx_data_in[7:0]};
// 仅在 F_IDLE 才"武装"SOF 搜索 → 数据中出现的 0xAA 不会误触发
wire sof_detected = (f_curr_state==F_IDLE) && (rx_sr[1]==SOF_BYTE1 && rx_sr[0]==SOF_BYTE2);
```

只观察每个时钟的 `byte0`，与总线宽度完全无关；SOF 检测变成「连续两个字节 = AA→55」的序列识别。

### 1.3 核心区别

| 对比点 | 当前 | 修复 |
|---|---|---|
| 帧头发送 | 1 个时钟发 3 字节（24bit 字） | 3 个时钟各发 1 字节（序列化） |
| SOF 检测输入 | 固定位片 `[7:0]`+`[15:8]` | 单字节滑动窗口 `rx_sr[1:0]` |
| LANE_CNT=1 行为 | 帧头截断丢 SOF2/TYPE；SOF 检测越界卡死 | 正常工作（仅看 byte0） |
| 数据中 0xAA 误触发 | 若某非 SOF 字的 byte0=0xAA 且 byte1=0x55 且恰好 F_IDLE，会误判 SOF | SOF 仅在 **F_IDLE 状态**被搜索；PAYLOAD 期间 FSM 不在 F_IDLE，0xAA 被忽略 → 消除误触发 |
| 字节对齐依赖 | 强依赖 24bit 字边界 | 位置无关（序列识别） |

---

## 2. 校验和按 LANE_CNT 循环累加

### 2.1 当前设计

校验和累加**硬编码「每字 3 字节」**（`lvds_tx_channel.v:265` 与 `lvds_rx_link.v:161` 对称）：

```verilog
// TX 侧 (lvds_tx_channel.v:265), 仅 USR payload 字
checksum_reg <= checksum_reg + fifo_dout[7:0] + fifo_dout[15:8] + fifo_dout[23:16];
// RX 侧 (lvds_rx_link.v:161)
checksum_calc <= checksum_calc + rx_data_in[7:0] + rx_data_in[15:8] + rx_data_in[23:16];
```

- `fifo_dout` / `rx_data_in` 按 `LANE_CNT*8` 缩放（✓），但累加式**仍写死 3 个字节切片**。
- `LANE_CNT=1` 时 `[15:8]`、`[23:16]` 越界 → 仿真中读 0 → 每字只累加 1 字节（比正确值少 2 字节）。
- 注意一个陷阱：TX 与 RX **对称**少加，校验和「看似能对上」，但 `frame_type` 取自越界的 `[23:16]`（见 §1）→ 帧被误路由为控制帧分支，**数据仍无法正确交付**。故「校验和循环累加」必须与「帧头序列化（修 TYPE 捕获）」配套。

### 2.2 修复方案

按实际每字字节数 `LANE_CNT` 循环累加：

```verilog
// 通用: 每 payload 字累加 LANE_CNT 个字节(TX/RX 对称)
integer b;
reg [7:0] w_byte;
always @(*) begin
    next_checksum = checksum_reg;
    for(b=0; b<LANE_CNT; b=b+1)
        next_checksum = next_checksum + tx_word[b*8 +: 8];   // 取第 b 字节
end
```

帧头初始值 `SOF1+SOF2+TYPE`（:253 / :147）本身就不依赖 LANE_CNT（序列化后帧头恒 3 字节），保持原样即可。

### 2.3 核心区别

| 对比点 | 当前 | 修复 |
|---|---|---|
| 每字累加字节数 | 固定 3（写死 `[7:0]+[15:8]+[23:16]`） | 循环 `LANE_CNT` 次 |
| LANE_CNT=1 | 越界位读 0 → 每字少算 2 字节（且 TYPE 捕获失败） | 累加 1 字节/字，正确 |
| LANE_CNT=4 / 2 | 仍只算 3 字节 → 校验和与帧长错位 | 累加 4 / 2 字节，正确 |
| 与帧头修复耦合 | 独立 | 必须配合 §1 的 TYPE 正确捕获，否则帧被误路由 |

---

## 3. 多字节字段拆分多字

### 3.1 当前设计

心跳是 **16bit**，被「塞进一个 24bit 字」发送（`lvds_tx_channel.v:300`），RX 从固定字节位拆回（`:170-171`）：

```verilog
// TX (lvds_tx_channel.v:300)
TYPE_HB: tx_data_mux = {8'd0, heartbeat_cnt[7:0], heartbeat_cnt[15:8]};  // 24bit: pad+low+high
// RX (lvds_rx_link.v:170-171)
heartbeat_recv_cnt[15:8] <= rx_data_in[7:0];    // 取 byte0 当高字节
heartbeat_recv_cnt[7:0]  <= rx_data_in[15:8];   // 取 byte1 当低字节
```

- `LEN`（8bit，:294）与 `CHECKSUM`（8bit，:304）本身就是单字节，**截断无害**，LANE_CNT=1 下 OK。
- 唯有 `HEARTBEAT`（16bit）依赖 24bit 字里有 2 个数据字节。`LANE_CNT=1` 时 24bit→8bit 截断，**只剩 `heartbeat_cnt[7:0]`，高 8 位丢失** → 心跳计数值错误（但本场景因链路状态机用 `link_up` 标志而非比对具体计数值，未必致命，仍属缺陷）。

### 3.2 修复方案

多字节字段「拆成多个窄字周期」，每周期只放 1 字节：

```verilog
// TX: 心跳拆 2 个周期 (低字节 → 高字节), 各占一个 byte0
TX_HB_LOW : tx_data_mux = {{(LANE_CNT-1)*8{1'b0}}, heartbeat_cnt[7:0]};
TX_HB_HIGH: tx_data_mux = {{(LANE_CNT-1)*8{1'b0}}, heartbeat_cnt[15:8]};
// RX: 连续 2 个字节收齐组装
F_HB_PAY0: hb_recv[7:0]  <= rx_data_in[7:0];
F_HB_PAY1: hb_recv[15:8] <= rx_data_in[7:0];
```

对 `LANE_CNT=1`：2 字节 → 2 个 8bit 周期，完整保留 16bit，无丢失。该模式可推广到任意多字节字段（如未来 32bit 时间戳）。

### 3.3 核心区别

| 对比点 | 当前 | 修复 |
|---|---|---|
| 心跳布局 | 1 个 24bit 字含 2 数据字节 + 1 pad | 2 个窄字周期，各 1 字节 |
| LANE_CNT=1 | 截断丢高 8 位 | 2 周期完整保留 16bit |
| 可扩展性 | 再加多字节字段需再改位拼接 | 字段长度 = 周期数，天然可扩展 |

---

## 4. 修 D-4 / D-5 的硬编码 3 路引用

### 4.1 当前设计（硬编码 lane 索引 1、2）

**D-4 — deskew 对齐验证硬编码 `shift_reg[1]/[2]`**（`lane_deskew.v:135-136`）：

```verilog
if(shift_reg[1][lane_offset[1]] == sync_word &&
   shift_reg[2][lane_offset[2]] == sync_word) begin
    check_cnt <= check_cnt + 1'b1;
end
```

`LANE_CNT=1` 时 `shift_reg[1]` 不存在 → 编译/elaboration 报错（或仿真 X）。前面 `:120` 的 `for(i=1;i<LANE_CNT;i++)` 已参数化，唯独这处验证用了字面量索引。

**D-5 — 物理层把 3 路数据硬编码拼接**（`:197`）：

```verilog
.lane_deskew u_lane_deskew (
    .data_in({lane_data[2], lane_data[1], lane_data[0]}),   // 固定 3 路, 宽度 = 24bit
```

`data_in` 端口宽 `LANE_CNT*DATA_WIDTH`。`LANE_CNT=1` 时端口为 8bit，但 RHS 是 24bit 拼接 → 宽度不匹配（截断或编译错误）。

### 4.2 修复方案（改用循环 / generate 打包）

**D-4**：把验证也纳入 `for` 循环（与 :120 一致），跳过参考通道 lane0：

```verilog
// 所有非参考通道在当前锁定偏移处同时出现 sync_word 才算连续匹配
reg all_sync;
all_sync = 1'b1;
for(i=1; i<LANE_CNT; i=i+1)
    if(!(shift_reg[i][lane_offset[i]] == sync_word)) all_sync = 1'b0;
if(all_sync) check_cnt <= check_cnt + 1'b1; else check_cnt <= 4'd0;
```

**D-5**：用 generate 或参数化拼接构造 `data_in`（lane0 为最低字节）：

```verilog
// generate 逐通道打包, 替代手写 {lane_data[2],[1],[0]}
wire [LANE_CNT*DATA_WIDTH-1:0] deskew_din;
genvar gi;
generate for(gi=0; gi<LANE_CNT; gi=gi+1)
    assign deskew_din[gi*DATA_WIDTH +: DATA_WIDTH] = lane_data[gi];
endgenerate
.lane_deskew u_lane_deskew ( .data_in(deskew_din), ... );
```

### 4.3 核心区别

| 对比点 | 当前 | 修复 |
|---|---|---|
| deskew 验证索引 | 字面量 `[1]`、`[2]` | `for(i=1;i<LANE_CNT)` 循环 |
| 物理层 data_in 拼接 | `{lane_data[2],[1],[0]}` 固定 24bit | generate 按 `LANE_CNT` 打包 |
| LANE_CNT=1 | 越界 / 宽度不匹配 → 编译或功能失败 | 循环 0 次 / 单路打包，正常 |
| LANE_CNT=4 | 漏检 lane3 | 自动覆盖全部通道 |

---

## 5. 综合对比表（5 维度）

| 修复方向 | 当前设计痛点 (file:line) | 修复后机制 | LANE_CNT=1 是否解决 |
|---|---|---|---|
| ① 帧头序列化 + 移位 SOF | 帧头 24bit 字截断丢 SOF2/TYPE（:290）；SOF 固定位比较越界卡死（:66） | 帧头 3 字节序列化 + 单字节滑动窗口序列检测（仅 F_IDLE 武装） | ✅ 彻底解决 |
| ② 校验和循环累加 | 每字硬编码 3 字节（:265 / :161） | `for(b<LANE_CNT)` 累加实际字节 | ✅ 解决（须配合 ① 才能正确捕获 TYPE） |
| ③ 多字节字段拆分 | 心跳 16bit 塞 24bit 字，截断丢高字节（:300 / :170-171） | 多字节拆多周期，每周期 1 字节 | ✅ 解决 |
| ④ D-4/D-5 硬编码引用 | deskew 字面量 `[1]/[2]`（:135-136）；phy 固定 3 路拼接（:197） | 循环 / generate 按 LANE_CNT 构造 | ✅ 解决 |

---

## 6. 修复后的统一「字节流」帧格式视图

修复后，帧格式在任何 LANE_CNT 下都等价于如下**字节序列**（与每时钟几字节无关）：

```
[SOF1][SOF2][TYPE][LEN][PAYLOAD × N 字节][CHECKSUM]
            ↑ 心跳帧: [SOF1][SOF2][TYPE_HB][LEN=2][HB_LOW][HB_HIGH][CHECKSUM]
            ↑ 控制帧: [SOF1][SOF2][TYPE_CTRL][LEN=1][CTRL_PAYLOAD][CHECKSUM]
```

- 每个 `[ ]` 恰好 1 字节，独占一个窄字周期的 byte0；
- RX 用滑动窗口识别 `SOF1→SOF2`，之后按字节数顺序解析 TYPE/LEN/PAYLOAD/CHECKSUM；
- 校验和 = 所有字节（含 SOF1/SOF2/TYPE）按 `LANE_CNT` 循环累加；
- deskew / 物理层用 generate 打包，**不再出现任何字面量 lane 索引或固定 24bit 拼接**。

> 这样 LANE_CNT 从 1 到 4（乃至更多）仅需改动参数，逻辑无需重写 —— 真正实现设计文档中「改 LANE_CNT 即可适配」的承诺。

---

*关联文档：`LANE_CNT_1_DEFECT_ANALYSIS.md`（缺陷清单 D-1~D-7 与严重度）。本文档仅对比修复思路与现状，不含任何代码改动。*
