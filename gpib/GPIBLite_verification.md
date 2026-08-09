# GPIBLite（PssGPIB）模块验证报告

| 项目 | 内容 |
|---|---|
| 待测设计 | `GPIBLite`（GPIB Talker/Listener 控制器，APB 从接口；产品名 PssGPIB） |
| 验证目标 | 跨时钟域（CDC）修复后的功能与协议正确性验证 |
| 仿真工具 | ModelSim SE-64 **10.6d**（`vlog` + `vsim -c`） |
| 仿真模型 | 未安装 Vivado，采用 **`xpm_fifo_async_beh.v`** 行为级 FWFT 异步 FIFO 替代 XPM 原语 |
| 测试平台 | `tb_GPIBLite.v` |
| 源码文件 | `GPIBLite.v`、`GPIB_fifo_in.v`、`GPIB_fifo_out.v`、`xpm_fifo_async_beh.v`、`tb_GPIBLite.v` |
| 版本 | v1.2（CDC 修复 + 4 项 DUT 功能 bug 修复） |
| 日期 | 2026-08-09 |
| 结论 | **RESULT: ALL TESTS PASSED（PASS=13 / FAIL=0）**，编译 0 错误 0 警告 |

---

## 1. 验证环境

### 1.1 时钟与跨时钟域
- `sys_clk` = 40 MHz（周期 25 ns）：GPIB 握手、状态机、FIFO 读/写侧之一。
- `apb_clk` ≈ 27.8 MHz（周期 36 ns）：APB 寄存器、FIFO 另一侧。
- 两时钟**非整数倍 + 人为相位差**，构成真实的异步 CDC 场景，足以暴露跨域时序问题。

### 1.2 FIFO 模型替换
设计使用 Xilinx `xpm_fifo_async`（FWFT）。本机未安装 Vivado，无法编译 XPM 原语，故以行为级模型 **`xpm_fifo_async_beh.v`** 替代：
- 实现 FWFT 首字直通：`dout = mem[rbin]` 组合输出；`empty = (rptr_g == wptr_g_rs2)`；`rd_en` 仅在 `!empty` 时推进 `rbin`。
- 经验证，FWFT 读在 `rd_en` 有效后**下一拍**才推进读指针——这正是 Bug 1 的根因来源，模型行为与原语一致。

### 1.3 总线与 APB 建模要点
- **开漏总线**：`data/dav/nrfd/ndac/eoi` 经 `pullup` 原语上拉，空闲（高阻）解析为 1，避免 `Z→X` 经同步器污染 DUT 状态机。
- **APB 读 NBA 竞争**：`PRDATA` 经非阻塞赋值晚一拍生效，读任务在访问边沿后多等一拍再采样 `APB_PRDATA`。
- **上电就绪门控**：TB 将 `INFO_RDY_DLY` 参数实例化为 0，跳过约 35 s 的上电等待（仅测试用）。

---

## 2. 测试用例

主测试序列共 **13 项检查**：

| # | 用例 | 验证点 | 结果 |
|---|---|---|---|
| 1 | ID 寄存器 | 读 `0x001C == 0x21101312` | PASS |
| 2 | 控制寄存器默认 | `En==1`、`Addr==1` | PASS |
| 3 | 监听（首测 N=16） | 控者 UNL/UNT/MLA → 发 16 字节 → APB 读回逐一比对 | PASS |
| 4 | 讲者（首测 N=16） | APB 写 out-FIFO → 设备发送 → 控者（监听）接收逐一比对 | PASS |
| 5–8 | CDC 压力：循环监听 N=8 ×4 | 异步时钟下反复 `listen→talk`，验证数据完整、无 stray 字节 | PASS ×4 |
| 9–12 | CDC 压力：循环讲者 N=8 ×4 | 同上，反复 `talk→listen` | PASS ×4 |
| 13 | 器件清除（IFC） | `IFC` 下降沿复位 in-FIFO（空标志翻转） | PASS |

> 监听/讲者各 5 项（首测 + 4 轮循环），合计 10；加 ID、控制默认、器件清除共 **13**。

### 2.1 协议流程（关键时序）
- **监听**：`ATN↓`（命令）→ 发 `UNL(3F)/UNT(5F)/MLA(21)` → `ATN↑`（数据）→ 发 N 字节（三线握手）→ APB 轮询 `0x0018[2]` 非空后读 `0x0010`。
- **讲者**：`ATN↓` → 发 `UNL/UNT/MTA(41)` → `ATN↑` → 设备成讲者 → 软件写 out-FIFO → 设备经 SH 发送 → 控者接收。
- **器件清除**：监听收数后断言 `IFC` 再释放，确认 in-FIFO 被清空。

---

## 3. CDC 修复与 Bug 修复记录

本次验证在 CDC 场景下暴露并修复了 **4 项 DUT 功能 bug**（含 1 项 CDC 直接相关的数据捕获缺陷）以及 **2 项测试平台建模缺陷**。

### 3.1 Bug 1 — 讲者首字节丢失 / +1 偏移 / 末尾回绕（DUT 功能 bug）
- **现象**：`talk` 接收到的数据流整体 `+1` 偏移，首位丢失，末位回绕（如期望 `64..73` 收到 `65..73,64`）。
- **根因**：SH 在 `SGNS` 对 **FWFT** out-FIFO 发起读，`data = ~Q` 组合直驱总线；FIFO 读指针在 `rd_en` 后下一拍推进，`Q` 变为下一字节，导致 `STRS`（DAV 有效）阶段总线已呈现“被读后的下一字节”，**首字节从未发出**。
- **修复**（`GPIBLite.v`）：新增发送保持寄存器
  ```verilog
  reg [7:0] GPIB_Data_FPGA_w_hold;   // 发送数据保持寄存器
  always @(posedge sys_clk or negedge GPIB_dvire_rstn) begin
      if(~GPIB_dvire_rstn)            GPIB_Data_FPGA_w_hold <= 8'd0;
      else if(GPIB_SH_State==GPIB_SH_SIDS) GPIB_Data_FPGA_w_hold <= GPIB_Data_FPGA_w;
  end
  assign data = GPIB_State ? (~GPIB_Data_FPGA_w_hold) : 8'bz;
  assign eoiOut = (GPIB_State & atn_dly & (GPIB_Data_FPGA_w_hold==8'h0A) & eoiOut_can_set) ? 1'b1 : 1'b0;
  ```
  在 `SIDS` 锁存本字节，`STRS` 期间总线保持稳定。**验证：全部 talk 用例 PASS。**

### 3.2 Bug 2 — 角色切换 X 污染（TB 建模 + DUT 交互）
- **现象**：角色切换瞬间 `SEND_TIMEOUT`，`AH` 出现 `X`，握手死锁。
- **根因**：TB 在 DUT 仍为讲者（约 32 周期 `atn_dly` 窗口）时即驱动 `dav`，双端驱动开漏总线产生 `X`，灌入 DUT 的 AH 状态机。
- **修复**（TB）：在驱动 `dav` 前先 `while(!(u_dut.GPIB_State===1'b0))` 等 DUT 切回听者；在驱动 `nrfd/ndac` 前先 `while(!(u_dut.TACS===1'b1))` 等 DUT 成讲者。配合 `pullup` 原语避免 `Z→X`。
- **验证：listen 首测与所有 talk 通过，X 污染消失。**

### 3.3 Bug 3 — 讲者/听者双角色导致自身数据回灌 in-FIFO（DUT 功能 bug）
- **现象**：`talk` 期间 DUT 把地址字节 `3F,5F` 及讲者数据 `64..73` 写入 in-FIFO（`St=1,LACS=1`）。
- **根因**：讲者作用态（`TACS`）与听者作用态（`LACS`）未互斥。L 状态机在 `ATN` 释放（`atn_dly=1`）且 `LAD` 仍置位时重新断言 `LACS`，设备同时处于讲者/听者双角色，自身发出的字节被自身 AH 握手写回 in-FIFO。
- **修复**（`GPIBLite.v` L 状态机新增 `TACS` 互斥分支）：
  ```verilog
  else if (TACS) begin
      // 讲者作用态与听者作用态互斥：被寻址为讲者时立即清除听者角色，
      // 避免设备同时讲/听双角色导致自身发送字节被自身 AH 写回 in-FIFO。
      LIDS<=1'b1; LADS<=1'b0; LACS<=1'b0; LAD<=1'b0; GPIB_L_State<=2'd0;
  end
  ```
- **验证：talk 数据不再回灌（原 `72,73` 前缀消失）。**

### 3.4 Bug 4 — 循环监听把命令字节误写入 in-FIFO（DUT 功能 bug，CDC 相关数据捕获缺陷）
- **现象**：循环 `listen` 的 in-FIFO 前缀出现 `3F,5F`（UNL/UNT 命令），数据整体偏移，并在尾部 `SEND_TIMEOUT`。
- **根因**：`atn_dly` 为 **32 级移位**（专为 NI 的 110 ns NRFD 就绪时序保留）。在 `ATN` 断言后的 32 周期同步窗口内，`atn_dly` 仍为 `1`，`LACS` 仍残留为 `1`（上个数据阶段状态），导致控者发来的命令字节被 AH 握手接受（`ACDS`）并误写入 in-FIFO。原写条件 `GPIB_Ctl_En_sys & LACS & ACDS` 无法区分命令与数据。
- **修复**：数据捕获改用**快速 2 级同步 ATN**（`atn_ff1`），命令阶段（`atn_ff1==0`）绝不被写入；L/T 状态机仍保留 32 级 `atn_dly` 以满足 NRFD 时序。新增：
  ```verilog
  reg atn_ff0, atn_ff1;   // ATN 2 级同步(快速)，仅用于 in-FIFO 数据捕获门控
  // 复位: atn_ff0<=1; atn_ff1<=1;   采样: atn_ff0<=atn; atn_ff1<=atn_ff0;
  // 写条件: GPIB_Ctl_En_sys & atn_ff1 & LACS & ACDS
  ```
  TB 在 `atn_dly` 生效（`LACS` 置位）后才发数据，故用 `atn_ff1` 门控**不会漏掉任何真实数据字节**，且 DBG 确认 in-FIFO 仅含 `00..07` 等真实数据。
- **验证：全部循环 listen PASS，尾部 `SEND_TIMEOUT` 消除。**

### 3.5 TB 修复 — `test_clear` 缺 UNT 导致设备重回讲者
- **现象**：`test_clear` 尾部 `SEND_TIMEOUT`（`AH=000` AIDS 停滞）。
- **根因**：前一轮为讲者，`TAD`（讲地址锁存）仍为 `1`；`test_clear` 仅发 `UNL/MLA` 未发 `UNT`，`ATN` 释放后 `TAD & atn_dly` 使设备重回讲者（`TACS`），驱动 `dav` 而非进行听者握手。
- **修复**（TB）：`test_clear` 命令序列改为 `UNL(3F)/UNT(5F)/MLA(21)`，与 `test_listen` 一致，先清除讲/听地址再重新寻址为听者。
- **验证：`device clear` 用例 PASS。**

---

## 4. 仿真结果

```
# [PASS] ID register == 0x21101312
# [PASS] Ctrl default En==1, Addr==1
# [PASS] listen: N bytes received correctly        (首测 N=16)
# [PASS] talk: N bytes sent correctly              (首测 N=16)
# [PASS] listen: N bytes received correctly        (循环 ×4, N=8)
# [PASS] talk: N bytes sent correctly              (循环 ×4, N=8)
# [PASS] device clear: in-FIFO cleared by IFC
# ==== SUMMARY: PASS=13  FAIL=0 ====
# RESULT: ALL TESTS PASSED
```
- 编译：`Errors: 0, Warnings: 0`。
- 仿真无 `X` 污染、无握手死锁、无数据偏移、无 stray 命令字节。

---

## 5. 覆盖率与局限性

**已覆盖**：
- APB 寄存器默认/标识读取；
- 监听数据完整（单帧 16 字节 + 循环 8 字节，含多帧切换）；
- 讲者数据完整（含 FWFT 首字直通修复后的首位/末位正确性）；
- 异步时钟（非整数倍 + 相位差）下的反复收发 CDC 压力；
- 器件清除（IFC 软复位 in-FIFO）；
- 角色切换、命令/数据阶段边界。

**未覆盖（建议后续）**：
- GPIB 命令集 `DCL/GET/GTL/SDC/TCT/LLO/SPE/SPD/并行查询/副地址` 译码（设计声明未实现）；
- 中断路径（设计无 IRQ 输出端口，仅轮询）；
- `GPIB_error` 内部粘滞错误 FSM；
- 多设备共享总线“抢答”场景（听者 AH 未被 `LACS` 严格门控）；
- 真实 XPM 原语（综合后）与时序（本验证用行为级模型，仅验证逻辑）。

---

## 6. 重跑方法

```bash
cd /f/wc.prj/pulse_mfpga/src/DXH_AI/gpib
export PATH="/e/EDA/modeltech64_10.6d/win64:$PATH"
vlog -work ./work xpm_fifo_async_beh.v GPIB_fifo_in.v GPIB_fifo_out.v GPIBLite.v tb_GPIBLite.v
vsim -c -work ./work tb_GPIBLite -do "run -all"
# 关注输出中的 [PASS]/[FAIL] 与 RESULT 行
```

> 注：综合/上板前须将 `xpm_fifo_async_beh.v` 替换为 Vivado 的 `xpm_fifo_async` 原语（工程已含 `xilinx2018.2_XPM_Lib/`）。行为级模型仅用于功能仿真，不等价于时序原语的建立/保持与跨域同步行为。
