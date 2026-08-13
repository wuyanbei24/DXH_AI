@echo off
REM ============================================================================
REM run_sim.bat — AXI4Lite2AXI4ST 桥接设计 ModelSim 仿真启动脚本
REM 用法：在 sim/ 目录下双击运行，或命令行执行 run_sim.bat
REM 依赖：ModelSim SE-64 10.6d (E:\EDA\modeltech64_10.6d)
REM        Vivado 2018.2 XPM 源 (E:\EDA\Xilinx\Vivado\2018.2)
REM ============================================================================
set MODELSIM_BIN=E:\EDA\modeltech64_10.6d\win64
set PATH=%MODELSIM_BIN%;%PATH%

cd /d %~dp0
if not exist work mkdir work

echo [INFO] 启动 ModelSim 并运行 run_sim.do ...
"%MODELSIM_BIN%\vsim.exe" -c -do "do run_sim.do"
echo [INFO] 仿真结束。日志见 ModelSim 控制台 / sim 目录。
pause
