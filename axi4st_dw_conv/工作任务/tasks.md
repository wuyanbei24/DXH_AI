# Tasks

- [x] Task 1: 重命名文件并搭建模块骨架
  - [x] SubTask 1.1: 将 `src/DXH_AI/axi4st_dw_conv/axaaxi4st_dw_conv.v` 重命名为 `axi4st_dw_conv.v`
  - [x] SubTask 1.2: 编写模块声明（端口、参数、`timescale 1ns/1ps`），添加比率合法性检查（generate/initial $error）
  - [x] SubTask 1.3: 定义内部常量：`IS_DOWNSIZE`、`RATIO`、`IN_BYTES`/`OUT_BYTES`、复合字宽度 `COMPOSITE_W`

- [x] Task 2: 实现降位宽（4:1 / 2:1）转换核心
  - [x] SubTask 2.1: 三段式 FSM 状态定义（DS_IDLE / DS_SHIFT），状态寄存器段
  - [x] SubTask 2.2: 次态组合逻辑段（输入握手加载 → 移位输出）
  - [x] SubTask 2.3: 输出逻辑段：移位寄存器（tdata/tkeep/tlast/tuser），移位计数器，tlast 定位到最后子节拍，tuser 传播到第一子节拍
  - [x] SubTask 2.4: 生成输出复合字写入信号与输入 tready 逻辑

- [x] Task 3: 实现升位宽（1:2 / 1:4）转换核心
  - [x] SubTask 3.1: 三段式 FSM 状态定义（US_IDLE / US_ACCUM），状态寄存器段
  - [x] SubTask 3.2: 次态组合逻辑段（累加未满且无 tlast → 继续累加；满或 tlast → 产出）
  - [x] SubTask 3.3: 输出逻辑段：按字节位置拼接累加器，字节计数器，tlast 触发部分字冲刷，tkeep 标记有效字节，tuser 取触发节拍值
  - [x] SubTask 3.4: 生成输出复合字写入信号与输入 tready 逻辑（产出且 FIFO 未满时才接受新输入）

- [x] Task 4: 例化 XPM FIFO 弹性缓冲
  - [x] SubTask 4.1: 定义复合字打包/解包：`{tuser, tlast, tkeep, tdata}`（tdata 在低位）
  - [x] SubTask 4.2: 例化 `xpm_fifo_sync`（FIFO_MEMORY_TYPE="distributed", READ_MODE="fwft"，WRITE/READ_DATA_WIDTH=COMPOSITE_W，DEPTH=FIFO_DEPTH）
  - [x] SubTask 4.3: 连接 FIFO 写侧（FSM 产出）与读侧（输出端口），`.rst(fifo_rst)`、`.wr_clk(aclk)`
  - [x] SubTask 4.4: 输出 tvalid = !empty，tready 反馈控制 rd_en；FIFO 满反压 FSM 产出

- [x] Task 5: 顶层验证与风格一致性
  - [x] SubTask 5.1: 检查 AXI4-Stream 握手时序（tvalid/tready 无组合环路）
  - [x] SubTask 5.2: 检查复位路径（aresetn → fifo_rst，所有寄存器异步复位）
  - [x] SubTask 5.3: 确认与项目 `axi4lite2axist.v` 的 XPM FIFO 例化风格一致
  - [x] SubTask 5.4: 确认无未使用信号告警（overflow/underflow 等空端口留空）

# Task Dependencies
- Task 2, Task 3 依赖 Task 1（共用骨架与常量）
- Task 4 依赖 Task 2 或 Task 3（需要 FSM 产出复合字）
- Task 5 依赖 Task 2, 3, 4 全部完成
- Task 2 与 Task 3 通过 generate 根据 IS_DOWNSIZE 选择
