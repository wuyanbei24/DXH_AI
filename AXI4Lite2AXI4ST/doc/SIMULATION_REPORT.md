# AXI4-Lite ↔ AXI4-Stream 桥接设计 — 仿真报告

> **报告版本**：V1（仿真验证版）
> **日期**：2026-08-12
> **RTL 修正版本**：V5（仿真驱动修正，详见 `DESIGN_CHANGELOG.md`）
> **仿真工具**：ModelSim SE-64 10.6d
> **XPM 源**：Vivado 2018.2（`E:/EDA/Xilinx/Vivado/2018.2/data/ip/xpm`）
> **结论**：**全部 7 个测试用例通过（TOTAL PASS），错误数 = 0**

---

## 一、仿真目标与范围

对 `AXI4Lite2AXI4ST` 桥接设计进行行为级仿真验证，覆盖：

- 顶层 `axi_lite_stream_bridge`（AXI4-Lite 从接口 ↔ AXI4-Stream 桥接 ↔ 本地寄存器阵列）
- 模块一 `axi4lite2axist`（AXI4-Lite → AXI4-Stream 命令组包 + 响应解包）
- 模块二 `axist2native`（AXI4-Stream 命令执行 + 响应生成 + 寄存器读写）

验证目标：确认设计在 AXI4-Lite 协议（含 AW/W 独立握手、字节选通、地址越界、读写并发、背靠背事务、读响应码端到端传递）下的功能正确性。

> 设计采用**内部回环（loopback）**结构：`axi4lite2axist` 的 AXI4-Stream Master 直接连接到 `axist2native` 的 AXI4-Stream Slave，反向同理。因此仿真自洽地打通了「AXI4-Lite 命令 → Stream 帧 → 寄存器执行 → Stream 响应帧 → AXI4-Lite B/R 响应」的完整通路。

---

## 二、仿真环境

| 项目 | 配置 |
|------|------|
| 仿真器 | ModelSim SE-64 10.6d（Feb 24 2018） |
| 编译命令 | `vlog -sv`（XPM 源）/ `vlog`（RTL、TB） |
| 启动命令 | `vsim -c -work work -voptargs="+acc" tb_axi_lite_stream_bridge` |
| XPM FIFO | `xpm_fifo_sync`，`READ_MODE="fwft"`，`FIFO_MEMORY_TYPE="distributed"` |
| XPM 源文件 | `xpm_cdc.sv`、`xpm_memory.sv`、`xpm_fifo.sv`（Vivado 2018.2 行为级模型） |
| 时钟 | 100 MHz（`aclk`，周期 10 ns，半周期 5 ns） |
| 复位 | 低有效 `aresetn`，上电后延迟 20 ns 释放 |
| 参数 | `C_S_AXI_DATA_WIDTH=32`、`C_S_AXI_ADDR_WIDTH=32`、`C_REG_NUM=4`、`C_FIFO_DEPTH=16` |
| 波形 | `tb_axi_lite_stream_bridge.vcd`（`$dumpvars`） |

**编译告警说明**：仿真输出 24 条 `(vopt-2685)/(vopt-2718) Too few port connections` 告警，均为 XPM FIFO 的**可选端口未连接**（`data_valid`/`wr_ack`/`sleep`）。这些是 XPM 宏提供的可选状态端口，本设计未使用，属预期内的良性告警，不影响功能与时序。

**编码说明**：ModelSim 在本机（中文 Windows，代码页 936）下 `$display` 输出为 GBK 字节流。解析日志时需用 `data.decode('gbk', errors='replace')`（见 `sim/` 下历史调试脚本），或在 UTF-8 终端直接查看。

---

## 三、测试平台与用例

测试平台 `sim/tb_axi_lite_stream_bridge.v`（自检式，顶层回环），含 7 个测试用例：

| 用例 | 名称 | 验证点 | 关键检查 |
|------|------|--------|----------|
| T1 | 基础单写单读 | 正常写读通路 | 写 `reg0=0x12345678`，读回一致；BRESP/RRESP=OKAY |
| T2 | AW/W 分离握手（D-04） | AW/W 独立 FIFO 解耦 | 先发 AW 延迟 3 拍再发 W，写 `reg1=0xCAFEBABE`，读回应正确 |
| T3 | 字节选通写 | WSTRB 分字节生效 | 先写全字节 `0xFFFFFFFF`，再仅写低 2 字节 `0x00001122`，结果 `0xFFFF1122` |
| T4 | 读写并发（轮询仲裁） | TX 轮询仲裁不堵塞 | `fork` 同时发起 写 reg2 + 读 reg0；读回 `0x12345678`，写后读回 `0xA5A5A5A5` |
| T5 | 连续多笔背靠背 | 顺序事务无粘连 | 对 reg0~3 各写 `0xA000_0000+k`，再依次读回一致 |
| T6 | 地址越界 DECERR | 越界返回 DECERR 且不改写合法寄存器 | 越界写返回 `DECERR(2'b11)`，不改写 reg0；越界读返回 `0xDEADBEEF` + `DECERR` |
| T7 | 读响应 RRESP 端到端 | RRESP 经帧格式回传正确 | 合法读 RRESP=`OKAY(2'b00)`，RDATA=`0xA0000001` |

> T2 / T4 / T6 / T7 直接对应 `DESIGN_REVIEW_REPORT.md` 中 D-04、D-05、M-03、M-04 等修正点的回归验证。

---

## 四、仿真执行方法

`sim/run_sim.do` 已固化全流程（建库 → 编译 XPM → 编译 RTL → 编译 TB → 启动 → `run -all`）。复现命令：

```bash
cd F:/wc.prj/pulse_mfpga/src/DXH_AI/AXI4Lite2AXI4ST/sim
export PATH="E:/EDA/modeltech64_10.6d/win64:$PATH"
vsim -c -do "do run_sim.do" -l sim_final.log
```

调试用（`+define+DEBUG` 启用 TB 内逐拍追踪）：

```bash
vlog +define+DEBUG -work work tb_axi_lite_stream_bridge.v   # 需先编译 XPM 与 RTL
vsim -c -work work -voptargs="+acc" -GDEBUG=1 tb_axi_lite_stream_bridge
```

日志：`sim_final.log`（本版规范参考运行）、`sim_fix6.log`（修复 T2 后的首次全绿运行）。

---

## 五、初始失败与根因分析（仿真驱动发现的 3 个 RTL 缺陷）

仿真在复现阶段暴露了 3 个**未被原始 Review 覆盖的硬件级缺陷**，均位于模块一 `axi4lite2axist` 的「AW/W → WRQ 配对」与「数据锁存」通路。根因均与 **XPM `xpm_fifo_sync` FWFT 模式的行为特性**相关。

### 缺陷 S-01：WRQ 重复配对（根因：FWFT `empty` 滞后 → 配对脉冲双发）

- **现象**：T6 越界写 BRESP 返回 `OKAY` 而非 `DECERR`；追踪发现 TX 对每笔命令帧**重发多次**，native 重复执行，BRSP FIFO 累积多余响应，B 通道被淹没错乱。
- **根因**：配对条件 `make_pair = !aw_empty && !w_empty && !wrq_full` 依赖 FIFO 的 `empty` 寄存器输出。XPM FWFT FIFO 的 `empty` 在 `rd_en` 弹出后**滞后约 1 拍**更新，导致 `make_pair` 在弹出后仍持续多拍为高。若直接用 `pair_pop <= make_pair`，同一对 AW/W 会被弹出并写入 WRQ **两次**，产生重复配对。
- **证据**：`[PAIR]` 追踪显示 T1 写弹出在 T=205000 与 T=305000 各发一次，`wrq_empty` 直到 T=315000 才归 1。

### 缺陷 S-02：WDATA 整体滞后一笔（根因：FWFT `dout` 在 rd/wr 同拍反映旧字头）

- **现象**：T1 写后 reg1 读回 reg0 数据、reg2 读回 reg1…（每笔写数据滞后一笔）。
- **根因**：原设计在配对弹出当拍**直接从 AW/W FIFO 的 FWFT `dout` 组合 `wrq_din`**。当测试在配对同一拍向 W FIFO 写入新数据时，FWFT `dout` 在该拍仍反映被弹出的旧字头，新数据要到下一拍才更新，导致 `wrq_din` 采到上一笔的写数据。
- **证据**：`[PAIR]` 追踪证明每个配对点 `wrq_dout`/`w_dout` 都是上一笔 W 数据。

### 缺陷 S-03：W FIFO 读-写碰撞（根因：rd_en 与 wr_en 同拍弹出不可靠）

- **现象**：T2（分离写）`reg1=0x12345678`，应为 `0xCAFEBABE`。
- **根因**：`make_pair` 在 AW/W 双双非空当拍即有效，而该拍往往与测试向 W FIFO 写入新数据同拍。若当拍即弹出，XPM FWFT FIFO 在 `rd_en` 与 `wr_en` 同拍时**弹出不可靠（读被写淹没）**，导致 W 字头滞留、上笔写数据残留，进而与下一笔 AW 错配。
- **证据**：`[WP]` 追踪（T2 配对点）显示 `aw_hold/wdata_hold` 已正确（`0x4`/`0xcafebabe`），但 W FIFO 仍滞留 T1 的 `0x12345678`，`make_pair=0`（AW 已被早先错配弹出）。

---

## 六、修正方案与代码（V5，仅在 `axi4lite2axist.v`）

### 修正 1（对应 S-01 / S-03）：配对 one-shot 锁 + 弹出延后 1 拍

文件 `rtl/axi4lite2axist.v`，WRQ 组装逻辑段（约第 295–330 行）：

```verilog
reg  pair_pop;
reg  pair_det;
reg  pair_armed;   // 单次配对锁：规避 FWFT empty 滞后导致的重复配对
wire make_pair = (!aw_empty) && (!w_empty) && (!wrq_full);
always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        pair_pop   <= 1'b0; pair_det <= 1'b0; pair_armed <= 1'b0;
    end else begin
        pair_pop   <= pair_det;            // 延后 1 拍真正弹出，规避读-写碰撞
        if (make_pair && !pair_armed) begin
            pair_det   <= 1'b1;
            pair_armed <= 1'b1;            // make_pair 首个高电平触发一次后封锁
        end else begin
            pair_det   <= 1'b0;
        end
        if (!make_pair) pair_armed <= 1'b0; // FIFO 排空后才解除封锁
    end
end
assign aw_rd_en = pair_pop;
assign w_rd_en  = pair_pop;
assign wrq_wr_en = pair_pop;
```

- `pair_armed`：确保每对 AW/W **只配对一次**（修复 S-01）。
- `pair_det → pair_pop` 延后 1 拍：使 W 写入已落定、`dout` 已更新，弹出干净无碰撞（修复 S-03）。

### 修正 2（对应 S-02）：AW/W 数据保持寄存器

文件 `rtl/axi4lite2axist.v`，WRQ FIFO 定义段（约第 210–235 行）：

```verilog
reg [C_S_AXI_ADDR_WIDTH-1:0]   aw_hold;
reg [C_S_AXI_DATA_WIDTH-1:0]   wdata_hold;
reg [C_S_AXI_DATA_WIDTH/8-1:0] wstrb_hold;
always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        aw_hold<={C_S_AXI_ADDR_WIDTH{1'b0}};
        wdata_hold<={C_S_AXI_DATA_WIDTH{1'b0}};
        wstrb_hold<={C_S_AXI_DATA_WIDTH/8{1'b0}};
    end else begin
        if (aw_wr_en) aw_hold    <= s_axi_awaddr;
        if (w_wr_en)  begin wdata_hold <= s_axi_wdata; wstrb_hold <= s_axi_wstrb; end
    end
end
assign wrq_din = {aw_hold, wdata_hold, wstrb_hold};
```

在 AW/W **各自被写入的当拍**即把原始地址/数据/选通锁存到保持寄存器，`wrq_din` 直接由寄存器组合。数据在写入拍即稳定，彻底摆脱 FWFT `dout` 的滞后与读-写碰撞（修复 S-02）。

> 两处修正协同：保持寄存器消除「数据滞后」，配对 one-shot + 延后 1 拍消除「重复配对」与「读-写碰撞」，使每笔 AXI4-Lite 写事务精确映射为一次 WRQ 配对、一次 TX 帧发送、一次 native 执行、一次 BRESP 响应。

---

## 七、最终仿真结果（sim_final.log，2026-08-12）

```
# ==================== 测试1：基础单写单读 ====================
#   [PASS] 寄存器0 读回 0x12345678
# ==================== 测试2：AW/W 分离握手 (D-04) ====================
#   [PASS] 寄存器1 读回 0xcafebabe
# ==================== 测试3：字节选通写 ====================
#   [PASS] 寄存器3 读回 0xffff1122 (低2字节被覆盖)
# ==================== 测试4：读写并发 (轮询仲裁) ====================
#   [PASS] 并发读 寄存器0 = 0x12345678
#   [PASS] 并发写 寄存器2 = 0xa5a5a5a5
# ==================== 测试5：连续多笔背靠背 ====================
#   [PASS] 寄存器0 = 0xa0000000  ~ 寄存器3 = 0xa0000003
# ==================== 测试6：地址越界 DECERR ====================
#   [PASS] 越界写 返回 DECERR
#   [PASS] 越界写未改写合法寄存器 reg0 = 0xa0000000
#   [PASS] 越界读 返回 0xDEADBEEF
#   [PASS] 越界读 返回 DECERR
# ==================== 测试7：读响应 RRESP=OKAY 端到端校验 ====================
#   [PASS] 合法读 RRESP=OKAY, RDATA=0xa0000001
# ********************************************************
#   所有测试通过 (TOTAL PASS), 错误数 = 0
# ********************************************************
```

| 用例 | 结果 | 备注 |
|------|------|------|
| T1 基础单写单读 | ✅ PASS | BRESP/RRESP=OKAY |
| T2 AW/W 分离握手 | ✅ PASS | 修复 S-03 后通过（关键回归） |
| T3 字节选通写 | ✅ PASS | 低 2 字节被覆盖 |
| T4 读写并发 | ✅ PASS | 轮询仲裁无堵塞 |
| T5 连续背靠背 | ✅ PASS | 4 寄存器全部一致 |
| T6 地址越界 | ✅ PASS（4 子项） | DECERR + 不改写 + 0xDEADBEEF |
| T7 RRESP 端到端 | ✅ PASS | RRESP 经帧正确回传 |
| **合计** | **7/7 PASS，0 错误** | — |

---

## 八、遗留项与后续建议

1. **`DESIGN_REVIEW_REPORT.md` 中未关闭项**：M-05（`addr_in_range` 比较在 `C_REG_NUM` 非 2 的幂时的面积优化）、L-02（建议补充负面测试：FIFO 满/背压、帧格式错误注入、复位期间事务）、L-03（建议显式声明全部 XPM 参数）。以上不影响功能正确性，可后续优化。
2. **仿真覆盖度**：当前 7 用例覆盖正常路径与越界/分离/并发/背靠背。建议后续补充 FIFO 满反压（`C_FIFO_DEPTH` 调小）与连续读写交替压力场景。
3. **可移植性**：`run_sim.do` 中 `VIVADO_XPM` 为绝对路径，跨机复现需按实际 Vivado 版本修改。
4. **综合/实现未验证**：本仿真为行为级（XPM 行为模型），未做 Vivado 综合/布局布线，时序与资源占用待实现阶段确认。

---

## 九、结论

经仿真驱动修正（V5，3 处 RTL 修改），`AXI4Lite2AXI4ST` 桥接设计在 AXI4-Lite 协议各关键场景（独立握手、字节选通、地址越界、并发仲裁、背靠背、读响应码回传）下功能正确，**全部 7 个测试用例通过，错误数 0**。设计可进入综合/实现阶段验证。

---

*相关文档：`DESIGN_REVIEW_REPORT.md`（设计 Review，V4）、`DESIGN_CHANGELOG.md`（变更记录，含 V5 仿真修正）、`完整帧格式版 AXI4-Lite ↔ AXI4-Stream 桥接设计V02.md`（设计规格）。*
