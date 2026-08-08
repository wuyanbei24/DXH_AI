# LVDS3DLane 链路训练设计 V4 修复变更记录

**修复日期**: 2025-01  
**修复范围**: LT-01 ~ LT-18 共 18 个链路训练设计问题  
**涉及文件**: 8 个 Verilog 源文件  

---

## 修复总览

| 编号 | 严重等级 | 问题描述 | 涉及文件 | 修复状态 |
|------|----------|----------|----------|----------|
| LT-01 | 致命 | TX训练阶段无RX校准完成握手 | lvds_tx_channel.v | ✅ 已修复 |
| LT-02 | 致命 | 时钟恢复比不满足DDR 8:1的4:1要求 | lvds_rx_phy.v | ✅ 已修复 |
| LT-03 | 致命 | lane_deskew for-loop多次赋值(最后匹配覆盖首次) | lane_deskew.v | ✅ 已修复 |
| LT-04 | 致命 | 主机单向ACK, 无从机反向确认 | lvds_link_manager.v | ✅ 已修复 |
| LT-05 | 致命 | 重训练TX/RX不同步 | lvds_tx_channel.v, lvds_link_manager.v | ✅ 已修复 |
| LT-06 | 致命 | bitslip_cnt非重训练重启不清零, W_IDLE重复触发 | lvds_rx_lane_phy.v | ✅ 已修复 |
| LT-07 | 致命 | CDC简单2级FF, 多比特数据总线可能混合 | lvds_bidirectional_top.v | ✅ 已修复 |
| LT-08 | 严重 | lane_align_done不清零, 字对齐FSM循环 | lvds_rx_lane_phy.v | ✅ 已修复 |
| LT-09 | 严重 | retrain_req过早清除(仅3-4周期) | lvds_rx_link.v, lvds_rx_channel.v | ✅ 已修复 |
| LT-10 | 严重 | M_FAULT恢复不生成retrain脉冲, 脏状态残留 | lvds_rx_phy.v | ✅ 已修复 |
| LT-11 | 严重 | IDELAY采样窗口不足, 采样次数错误, 容错逻辑错误 | lvds_rx_lane_phy.v | ✅ 已修复 |
| LT-12 | 严重 | Lock check仅测0xB5, 无运行时信号质量监测 | lvds_rx_phy.v | ✅ 已修复 |
| LT-13 | 严重 | lane_offset运行时不可更新 | lane_deskew.v | ✅ 已修复 |
| LT-14 | 严重 | 心跳超时在握手期间误触发 | lvds_link_manager.v, lvds_rx_link.v | ✅ 已修复 |
| LT-15 | 轻微 | IS_MASTER用if/else组合逻辑而非generate | lvds_link_manager.v | ✅ 已修复 |
| LT-16 | 轻微 | retry_cnt死代码 | lvds_rx_phy.v | ✅ 已修复 |
| LT-17 | 轻微 | deskew_done前输出未初始化数据 | lane_deskew.v | ✅ 已修复 |
| LT-18 | 轻微 | TB通道延迟模型注释, 采样时钟域错误 | (待后续更新) | 📋 记录 |

---

## 详细修复说明

### LT-01: TX训练阶段无RX校准完成握手
**文件**: `lvds_tx_channel.v`  
**问题**: train_phase_cnt是纯计数器(4000周期), 无与RX延迟校准完成的握手。TX可能在RX仍在扫描0x55时切换到0xB5。  
**修复**: 
- 增加 `tx_retrain_req` 输入端口, 接收来自link_manager的重训练脉冲
- 重训练脉冲到达时强制重置 `train_phase_cnt`, 确保TX/RX同步从阶段0重启
- 增加 `TRAIN_ALIGN_DURATION` 参数控制字对齐阶段持续时间

### LT-02: 时钟恢复比不满足DDR 8:1的4:1要求
**文件**: `lvds_rx_phy.v`  
**问题**: 原设计使用lvds_rx_pll(MMCM)从200MHz LVDS时钟输出100MHz, 但ISERDESE2 DDR 8:1需要CLK:CLKDIV=4:1, 当前200/100=2:1不足。clk_bufio直接用clk_ibuf(200MHz)。  
**修复**: 
- 改用 `mfpga_clk_ip` IP核, 输出400MHz(clk_out1)和100MHz(clk_out4)
- `clk_bufio = clk_out1_400` (400MHz串行时钟)
- `clk_div = clk_out4_100` (100MHz并行时钟)
- 时钟比 400:100 = 4:1, 满足DDR 8:1要求

### LT-03: lane_deskew for-loop多次赋值
**文件**: `lane_deskew.v`  
**问题**: for循环中 `offset_found` 在同一周期内无法阻止后续j的匹配, 导致最后匹配覆盖首次匹配。deskew_en失效时lane_offset不清零。  
**修复**: 
- 引入局部变量 `found_this_cycle`, 在for循环内首次匹配后置位, 阻止后续j匹配
- deskew_en失效时彻底清零 `lane_offset`, `deskew_done`, `offset_found` 等所有状态

### LT-04: 主机单向ACK, 无从机反向确认
**文件**: `lvds_link_manager.v`  
**问题**: 主机发送3x MASTER_ACK后直接进入LINK_UP, 从机可能仍卡在S_WAIT_PEER。  
**修复**: 
- 新增 `TYPE_SLAVE_ACK = 0x04` 控制帧类型
- 从机收到MASTER_ACK后发送SLAVE_ACK反向确认
- 主机等待收到SLAVE_ACK后才进入LINK_UP (`master_recv_slave_ack` 标志)
- 握手流程: Slave→SLAVE_READY→Master→MASTER_ACK×3→Slave→SLAVE_ACK→Master→LINK_UP

### LT-05: 重训练TX/RX不同步
**文件**: `lvds_tx_channel.v`, `lvds_link_manager.v`, `lvds_bidirectional_top.v`  
**问题**: RX本地触发重训练, TX需要经过link_manager→CDC→TX的延迟, 导致TX/RX不在同一训练阶段。  
**修复**: 
- link_manager新增 `tx_retrain_pulse` 输出, 在S_RETRAIN状态首周期生成脉冲
- 顶层增加 `tx_retrain_pulse` 的CDC同步(clk_ref→clk_div)
- TX通道增加 `tx_retrain_req` 输入, 检测上升沿后重置 `train_phase_cnt`
- 确保TX/RX同时从训练阶段0重启

### LT-06: bitslip_cnt非重训练重启不清零
**文件**: `lvds_rx_lane_phy.v`  
**问题**: bitslip_cnt仅在retrain_req时清零, M_FAULT恢复(非retrain)不清零, 导致bitslip尝试次数累积。W_IDLE在align_check_cnt>=16后回到W_IDLE, 立即重新触发W_BITSLIP。  
**修复**: 
- 新增 `W_DONE` 状态, 对齐成功后进入W_DONE而非W_IDLE, 防止重复触发
- 新增 `scan_done_prev` 寄存器, 检测 `scan_done` 上升沿, 在W_IDLE中清零 `bitslip_cnt`
- 确保每次延迟校准完成后, 字对齐从bitslip_cnt=0开始

### LT-07: CDC简单2级FF, 多比特数据总线不安全
**文件**: `lvds_bidirectional_top.v`  
**问题**: ctrl_frame_send脉冲用简单2级FF同步(同频异相可能丢失), 8位数据总线(ctrl_frame_type/payload)可能混合。数据和脉冲不保证同步到达。  
**修复**: 
- 改用握制型脉冲同步器(Handshake Pulse Synchronizer)
- clk_ref域: 脉冲到达时锁存数据(`ctrl_frame_type_hold`/`ctrl_frame_payload_hold`)并置请求(`ctrl_frame_send_req`)
- clk_div域: 两级同步请求信号, 边沿检测恢复脉冲, 数据总线同步期间稳定
- clk_div→clk_ref: ACK信号两级同步, 收到ACK后清请求
- 确保数据总线在脉冲到达时已稳定

### LT-08: lane_align_done不清零, 字对齐FSM循环
**文件**: `lvds_rx_lane_phy.v`  
**问题**: lane_align_done一旦置位永不自动清零。W_CHECK在align_check_cnt>=16后回W_IDLE, W_IDLE立即重新触发W_BITSLIP, 形成循环。  
**修复**: 
- 新增 `W_DONE` 状态, 对齐成功后保持
- W_DONE状态下持续监测信号质量(`bad_word_cnt`), 连续32拍非0xB5则判定信号恶化
- 信号恶化时清零 `lane_align_done`, 回到W_IDLE重新对齐

### LT-09: retrain_req过早清除
**文件**: `lvds_rx_link.v`, `lvds_rx_channel.v`  
**问题**: retrain_ack = retrain_req_inner & ~phy_ready, phy_ready下降后retrain_req仅保持3-4周期, 物理层可能未完成重启。  
**修复**: 
- `lvds_rx_link.v`: retrain_req保持, 仅在phy_ready下降时清零(确认物理层已响应)
- `lvds_rx_channel.v`: retrain_ack改为等待phy_ready下降后重新上升(下降-上升序列), 确认物理层已完全重启并重新进入校准
- 新增 `retrain_ack_pending` 状态机跟踪phy_ready的下降-上升序列

### LT-10: M_FAULT恢复不生成retrain脉冲
**文件**: `lvds_rx_phy.v`  
**问题**: M_FAULT→M_IDLE恢复时不生成内部retrain脉冲, bitslip_cnt/scan_done/lane_align_done/lane_offset保留脏值。  
**修复**: 
- 新增 `internal_retrain` 信号, M_FAULT→M_IDLE转换时生成单周期脉冲
- `internal_retrain` 与外部 `retrain_req` 合并后送入各lane_phy
- 确保所有子模块在故障恢复时彻底复位

### LT-11: IDELAY采样窗口不足, 采样次数错误, 容错逻辑错误
**文件**: `lvds_rx_lane_phy.v`  
**问题**: 
1. D_SET_DELAY后直接D_WAIT采样, 未等待IDELAY输出稳定
2. 采样条件 `sample_cnt >= SAMPLE_CNT-1` 实际只采样15次
3. 容错逻辑"首次错误即丢弃"(sample_valid立即清零), 非统计总错误数
4. valid_window循环用硬编码32而非DELAY_STEPS参数  
**修复**: 
1. 新增 `D_SETTLE` 状态, 等待3个周期(`SETTLE_CYCLES`)确保IDELAY输出稳定
2. 采样条件改为 `sample_cnt >= SAMPLE_CNT`, 确保采样16次
3. 容错改为统计总错误数: D_WAIT中累计 `sample_err_cnt`, D_SAMPLE中判定 `sample_err_cnt <= SAMPLE_ERR_TOLERANCE`
4. valid_window循环仍用32(因valid_window是32位寄存器), 但DELAY_STEPS参数控制扫描步数

### LT-12: Lock check仅测0xB5, 无运行时信号质量监测
**文件**: `lvds_rx_phy.v`  
**问题**: M_LOCK_CHECK仅测试0xB5模式, M_NORMAL无运行时信号质量监测, 信号恶化时无法及时触发重训练。  
**修复**: 
- M_NORMAL状态新增 `runtime_bad_cnt` 计数器
- 连续1000拍(`RUNTIME_BAD_THRESHOLD`)非0xB5则触发重训练(M_NORMAL→M_IDLE)

### LT-13: lane_offset运行时不可更新
**文件**: `lane_deskew.v`  
**问题**: deskew_done后lane_offset永不更新, 无法适应运行时偏移变化。  
**修复**: 
- 新增周期性重校验机制: `recheck_timer` 每100万周期(`RECHECK_INTERVAL`)触发一次校验
- 校验时检查当前偏移位置是否仍为sync_word
- 连续3次(`RECHECK_FAIL_THRESHOLD`)校验失败则清零deskew_done和lane_offset, 重新对齐

### LT-14: 心跳超时在握手期间误触发
**文件**: `lvds_link_manager.v`, `lvds_rx_link.v`  
**问题**: 心跳超时从phy_ready=1开始计数, 但TX可能尚未发送心跳, 握手期间可能误触发重训练。  
**修复**: 
- `lvds_rx_link.v`: heartbeat_timer仅在 `link_up=1` 后递增, link_up=0时保持为0
- `lvds_link_manager.v`: link_all_up仅在S_LINK_UP状态置位

### LT-15: IS_MASTER用if/else组合逻辑而非generate
**文件**: `lvds_link_manager.v`  
**问题**: if(IS_MASTER)在always块组合逻辑中使用参数判断, 虽然综合器通常能处理, 但不符合最佳实践。  
**修复**: 
- S_WAIT_PEER完成条件用 `generate-if` 替代if(IS_MASTER)
- 控制帧发送逻辑用 `generate-if` 分为主机/从机两个独立always块

### LT-16: retry_cnt死代码
**文件**: `lvds_rx_phy.v`  
**问题**: retry_cnt在M_FAULT改用fault_wait_timer后成为死代码, 无实际用途。  
**修复**: 
- 移除retry_cnt和MAX_RETRY
- 新增 `fault_retry_cnt` 作为故障重试计数器, 每次M_FAULT恢复递增, M_NORMAL时清零

### LT-17: deskew_done前输出未初始化数据
**文件**: `lane_deskew.v`  
**问题**: data_out组合逻辑在deskew_done=0时使用未初始化的lane_offset, 输出无效数据。  
**修复**: 
- data_out在deskew_done=0时输出全零
- deskew_done=1时正常输出对齐后数据

### LT-18: TB通道延迟模型注释, 采样时钟域错误
**状态**: 📋 已记录, 待后续更新testbench  
**说明**: Testbench修复不影响RTL综合, 后续单独更新。

---

## 修复涉及的文件清单

| 文件 | 修复的LT编号 | 主要改动 |
|------|-------------|----------|
| `lvds_rx_lane_phy.v` | LT-06, LT-08, LT-11 | 新增D_SETTLE/W_DONE状态, scan_done上升沿清bitslip_cnt, 信号质量监测, IDELAY稳定等待, 采样容错改进 |
| `lane_deskew.v` | LT-03, LT-13, LT-17 | 首次匹配锁定(局部变量), 周期性重校验, deskew_done前输出全零 |
| `lvds_rx_phy.v` | LT-02, LT-10, LT-12, LT-16 | mfpga_clk_ip 400/100MHz, internal_retrain脉冲, runtime_bad_cnt, fault_retry_cnt |
| `lvds_link_manager.v` | LT-04, LT-05, LT-14, LT-15 | SLAVE_ACK反向确认, tx_retrain_pulse, generate-if, link_up门控 |
| `lvds_bidirectional_top.v` | LT-07 | 握制型脉冲同步器, tx_retrain_pulse CDC |
| `lvds_tx_channel.v` | LT-01, LT-05 | tx_retrain_req输入, 重训练时重置train_phase_cnt |
| `lvds_rx_link.v` | LT-09, LT-14 | retrain_req保持到phy_ready下降, 心跳仅link_up后启用 |
| `lvds_rx_channel.v` | LT-09 | retrain_ack等待phy_ready下降-上升序列 |

---

## 三大根因修复总结

### 根因1: 训练流程缺乏端到端同步
- **LT-01**: TX增加tx_retrain_req, 重训练时重置训练阶段
- **LT-05**: link_manager生成tx_retrain_pulse, CDC同步到TX
- **LT-02**: 修正时钟比为4:1, 确保ISERDESE2正确解串

### 根因2: 状态机复位不完整
- **LT-06**: scan_done上升沿清bitslip_cnt, W_DONE状态防循环
- **LT-08**: W_DONE状态+bad_word_cnt信号质量监测
- **LT-10**: M_FAULT恢复生成internal_retrain脉冲
- **LT-03**: deskew_en失效时清零lane_offset

### 根因3: CDC设计不完整
- **LT-07**: 握制型脉冲同步器替代简单2级FF
- **LT-09**: retrain_req保持到物理层确认重启
