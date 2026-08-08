# LVDS 训练比特对齐与字对齐设计缺陷分析报告

> **审查日期**: 2026-08-08  
> **审查范围**: lvds_rx_lane_phy.v / lvds_rx_phy.v / lvds_tx_channel.v / lane_deskew.v / lvds_link_manager.v  
> **审查重点**: IDELAY 延迟校准（比特对齐）、BITSLIP 字对齐、通道间 deskew 的正确性与鲁棒性  
> **设计基线**: V4（含 LT-01~LT-18 修复后）

---

## 摘要

| 严重级别 | 数量 | 说明 |
|----------|------|------|
| **Critical** | 2 | ~~链路上线后必然触发误重训练~~ **已修复(V5)** |
| **Major** | 3 | 影响校准精度或鲁棒性 |
| **Minor** | 5 | 死代码 / off-by-one / warning |

---

## Critical 问题

### C-01: W_DONE 信号质量监测使用训练码型 0xB5，数据模式下必然误触发

**位置**: `lvds_rx_lane_phy.v` — W_DONE 状态  
**现象**: 链路训练完成 → link_manager 进入 S_LINK_UP → TX 切换发送用户数据 → RX 收到非 0xB5 数据 → `bad_word_cnt` 在 32 拍后达阈值 → `lane_align_done` 被清零 → `phy_ready` 下降 → 触发重训练 → 无限循环

**根因分析**:

```verilog
// lvds_rx_lane_phy.v W_DONE状态
W_DONE: begin
    if(iserdes_q == 8'hB5)      // ← 只在训练阶段发0xB5
        bad_word_cnt <= 8'd0;
    else
        bad_word_cnt <= bad_word_cnt + 1'b1;  // ← 数据模式下每拍+1
    if(bad_word_cnt >= BAD_WORD_THRESHOLD)     // 32拍后必然触发
        lane_align_done <= 1'b0;
end
```

训练完成后 link_manager 置 `tx_train_en=0`，TX 开始发用户帧/心跳帧（非 0xB5），RX 的 W_DONE 持续比对 0xB5 会 100% 判定为"信号恶化"。

**影响**: 链路永远无法稳定在数据传输模式。

**修复方案**:
- 方案 A: 增加 `training_mode` 输入信号，仅在训练期间启用码型监测
- 方案 B: W_DONE 不做运行时监测，信号恶化检测交由 `lvds_rx_phy` 的 M_NORMAL 状态（已有 `runtime_bad_cnt`）
- 方案 C: W_DONE 在 `lane_align_done` 置位后即冻结，不再跳回 W_IDLE

---

### C-02: lvds_rx_phy M_NORMAL 运行时监测同样使用 0xB5 判定，数据模式下必然误报

**位置**: `lvds_rx_phy.v` — M_NORMAL 状态  
**现象**: 与 C-01 同理，M_NORMAL 状态检测 3 路是否为 0xB5，正常数据必然不等于 0xB5，`runtime_bad_cnt` 递增直至超过阈值触发回到 M_IDLE。

```verilog
// lvds_rx_phy.v M_NORMAL
M_NORMAL: begin
    phy_ready <= 1'b1;
    if(deskew_data_out[7:0] == 8'hB5 &&
       deskew_data_out[15:8] == 8'hB5 &&
       deskew_data_out[23:16] == 8'hB5) begin
        runtime_bad_cnt <= 16'd0;     // ← 只有训练码才能清零
    end else begin
        runtime_bad_cnt <= runtime_bad_cnt + 1'b1;  // ← 正常数据必然+1
    end
end
```

**影响**: 即使 C-01 被修复，此处仍会在 1000 拍后强制回到 M_IDLE。

**修复方案**: M_NORMAL 不应使用训练码型判定信号质量。应改为：
- 使用帧层 CRC 校验错误率
- 或使用心跳超时作为链路健康指标
- 或直接移除运行时 0xB5 监测（训练结束即信任链路）

---

## Major 问题

### M-01: D_WAIT 采样次数 off-by-one — 实际采样 17 次而非设计目标 16 次

**位置**: `lvds_rx_lane_phy.v` — D_WAIT 状态退出条件 + 数据路径

**分析**:
```
退出条件 (组合逻辑): if(sample_cnt >= SAMPLE_CNT) d_next_state = D_SAMPLE;
数据路径 (时序逻辑): sample_cnt <= sample_cnt + 1'b1; // 同周期仍执行
```

执行序列：
- sample_cnt=0..15: 正常采样（16次），条件不满足
- sample_cnt=16: 条件满足（`16>=16`），但**同周期 D_WAIT case 仍执行**：cnt→17, 且可能 `sample_err_cnt++`

**影响**: 每个抽头实际采样 17 次，且第 17 次的错误可能被计入。容错比实际为 2/17 而非 2/16。偏差 6% 不致命但不精确。

**修复**: 退出条件改为 `sample_cnt >= SAMPLE_CNT - 1`，或在 D_WAIT 中当 `sample_cnt == SAMPLE_CNT` 时不再递增 error count。

---

### M-02: 训练阶段持续时间固定，无法自适应 RX 实际校准耗时

**位置**: `lvds_tx_channel.v` — `TRAIN_CALIB_DURATION=4000`, `TRAIN_ALIGN_DURATION=8000`

**分析**:
- TX 的训练码切换由固定计数器控制：发送 0x55 持续 4000 clk_div → 切换到 0xB5 持续 8000 clk_div
- RX 的 IDELAY 扫描理论耗时 ≈ 674 周期（32×21+2），4000 周期裕量足够
- 但字对齐（W FSM）需要 `scan_done` 脉冲触发，而 `scan_done` 产生在 D_DONE 状态（即 Phase 0 的 0x55 阶段末尾）
- **问题**: W FSM 被 `scan_done` 触发后立即开始匹配 0xB5，但此时 TX 可能已经切换到 Phase 1 若干周期。如果 D FSM 因某种原因（如 IDELAYCTRL 未就绪、噪声重扫）延迟完成，可能导致 `scan_done` 产生时 TX 已切换到 0xB5 且即将结束 Phase 1

**影响**: 在边界条件下（慢启动、IDELAYCTRL 晚就绪），RX 的字对齐可能来不及在 Phase 1 结束前完成。

**修复建议**: link_manager 应等待 `phy_ready` 信号再退出训练模式，而非依赖 TX 固定时长计时。当前设计中 link_manager 通过 `rx_phy_ready` 判断确实做了这一点（S_TRAINING → S_WAIT_PEER 以 `rx_phy_ready_sync2` 为条件），但 TX 的 `train_en` 解除由 link_manager 的 `tx_train_en` 控制——如果 link_manager 在 RX ready 后才切换，则 TX 训练码会持续足够长。需确认 `tx_train_en` 的解除时序确实在 `phy_ready` 之后。

---

### M-03: 无重试上限 — D FSM 校准失败后在 D_IDLE→D_SET_DELAY 间无限循环

**位置**: `lvds_rx_lane_phy.v` — D FSM + lane_calib_err 管理

**分析**:
```
D_CALC_WIN: lane_calib_err <= ~delay_win_valid;  // 窗口不足→err=1
D_DONE:     scan_done <= 1'b1;                   // 无条件产生scan_done
D_IDLE:     lane_calib_err <= 1'b0;              // err在D_IDLE被清零!
            → ~lane_align_done & ~retrain_req → 立即重新进入D_SET_DELAY
```

如果信号完全缺失（无有效窗口），模块将以 ~674 周期/次的速度无限循环扫描，消耗功耗且无法向上层有效报告"永久故障"。

**影响**: 系统无法区分"暂时性故障"和"永久性硬件断开"。

**修复建议**: 增加连续失败计数器，超过阈值（如 8 次）后锁定在 D_IDLE 不再重试，等待外部 `retrain_req` 或上层干预。

---

## Minor 问题

### m-01: D_SETTLE 等待周期 off-by-one

**位置**: `lvds_rx_lane_phy.v` — D_SETTLE 退出条件

**分析**: `settle_cnt` 从 0 计数，退出条件为 `settle_cnt >= SETTLE_CYCLES (3)`。实际在 settle_cnt=3 时退出，即等待 4 个周期（0→1→2→3）而非注释所称 3 个。

**影响**: 多等 1 周期，不影响功能但校准时间略增（32×1=32 周期额外开销）。

---

### m-02: ISERDESE2 `.O(O)` 连接到未声明隐式线网

**位置**: `lvds_rx_lane_phy.v` L182

```verilog
.O(O),  // O 未声明，产生 implicit wire warning
```

**修复**: 改为 `.O()` 悬空。

---

### m-03: `sample_valid` 寄存器为死代码

**位置**: `lvds_rx_lane_phy.v`

- 声明: `reg sample_valid;`
- 赋值: 复位时=1, D_SET_DELAY中=1
- 读取: **从未被读取**

**修复**: 删除声明和赋值。

---

### m-04: `delay_inc` / `delay_ce` 永远为 0，是死代码

**位置**: `lvds_rx_lane_phy.v`

设计选择 VAR_LOAD 模式通过 `LD`+`CNTVALUEIN` 直接加载，不使用 CE+INC 递增方式。`delay_ce`/`delay_inc` 虽连接到 IDELAYE2 但功能上无效。

**影响**: 无功能影响（CE=0 时 INC 被忽略），但代码中保留完整的声明/复位/驱动增加阅读负担。

**修复**: 删除寄存器声明，IDELAYE2 端口直接绑零 `.CE(1'b0), .INC(1'b0)`。

---

### m-05: `ref_clk_200m` 端口在 lvds_rx_lane_phy 中未使用

**位置**: `lvds_rx_lane_phy.v` 端口列表

IDELAYCTRL 已移至上层 `lvds_rx_phy` 例化，但端口仍保留。产生综合 warning。

**修复**: 从模块端口移除（需同步修改 lvds_rx_phy 中的例化）；或保留作为预留接口文档说明。

---

## 跨模块交互时序分析

### 训练流程时序关键路径

```
时间轴 (clk_div @ 100MHz):
─────────────────────────────────────────────────────────────────────────────

TX 侧 (lvds_tx_channel):
│── train_en=1 ──────────────────────────────────────────────│─ train_en=0 ─
│   Phase 0: 0x55            │   Phase 1: 0xB5               │
│   (4000 cycles)            │   (8000 cycles)               │
│<───────────────────────────┼───────────────────────────────>│

RX 侧 (lvds_rx_lane_phy):
│   D_IDLE→...→D_DONE       │   W_IDLE→W_BITSLIP→...→W_DONE │
│   (IDELAY scan ~674cyc)    │   (BITSLIP align ~22-64cyc)   │
│   scan_done↑               │   lane_align_done↑            │
│<──────── Phase 0 ─────────>│<── Phase 1 ──────────────────>│

RX 侧 (lvds_rx_phy):
│   M_CALIB                  │ M_LANE_DESKEW → M_LOCK_CHECK → M_NORMAL
│   等待 all_lane_done       │ (deskew ~16cyc)  (5000cyc)

link_manager:
│   S_TRAINING               │ S_WAIT_PEER → S_LINK_UP
│   等待 rx_phy_ready        │ (握手确认)
```

### 关键竞争条件

1. **Phase 切换与 scan_done 的竞争**: TX 在 `train_phase_cnt=4000` 时切换到 0xB5。RX 的 D FSM 必须在此前完成扫描。若 RX 延迟校准未完成而 TX 已切换码型，则 D_WAIT 中的采样目标 `0x55` 将不再匹配，导致窗口全无效 → lane_calib_err。
   - **当前设计裕量**: 674/4000 = 16.8% 利用率，裕量充足。
   - **风险场景**: IDELAYCTRL 未就绪导致 D_IDLE 等待，或首次复位后 MMCM lock 延迟。

2. **W FSM 对 Phase 1 的依赖**: W FSM 在 `scan_done` 后进入 W_BITSLIP，匹配目标为 `0xB5`。`scan_done` 产生于 Phase 0 末尾（D_DONE 状态），此时 TX 应已切换到发送 0xB5（因为 D FSM 耗时 < 4000）。但如果 D FSM 耗时接近 4000，`scan_done` 可能与 Phase 切换几乎同时发生，W_CHECK 首拍可能采到 0x55 的最后一拍。
   - **风险等级**: 低（实际 D FSM 通常 674 周期完成，远早于 4000）

---

## 修复优先级建议

| 优先级 | 问题 | 影响 | 建议动作 |
|--------|------|------|----------|
| ~~**P0**~~ | ~~C-01~~ | ~~链路必然崩溃~~ | ✅ **已修复**: 方案A training_mode 门控 |
| ~~**P0**~~ | ~~C-02~~ | ~~链路必然崩溃~~ | ✅ **已修复**: 心跳超时替代0xB5监测 |
| **P1** | M-01 | 校准精度偏差 | 修复：退出条件改为 `>= SAMPLE_CNT-1` |
| **P1** | M-03 | 无限循环功耗 | 修复：增加连续失败计数与锁定 |
| **P2** | M-02 | 边界条件风险 | 评估：确认 link_manager 时序保护 |
| **P3** | m-01~05 | 代码质量 | 择机清理 |

---

## 附录：训练码型与 FSM 对照表

| 训练阶段 | TX 发送码型 | RX 校准目标 | RX FSM 状态 | 持续时间 |
|----------|-------------|-------------|-------------|----------|
| Phase 0 | 0x55 (01010101) | IDELAY 延迟扫描 | D_IDLE→D_DONE | ~674 cyc |
| Phase 1 | 0xB5 (10110101) | BITSLIP 字对齐 | W_IDLE→W_DONE | ~22-64 cyc |
| Phase 1 | 0xB5 | 通道间 deskew | lane_deskew | ~16 cyc |
| Phase 1 | 0xB5 | 锁定检查 | M_LOCK_CHECK | 5000 cyc |
| 数据模式 | 用户帧/心跳 | — | W_DONE (应冻结) | 持续运行 |

---

> **结论**: V4 修复后的设计在训练阶段本身逻辑正确，但存在**训练模式到数据模式的转换缺陷** — C-01 和 C-02 两个 Critical 问题将导致链路在完成训练后无法维持稳定的数据传输状态，需立即修复。
