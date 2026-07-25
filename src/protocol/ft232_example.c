/**
 * @file ft232_example.c
 * @brief FT232通信协议使用示例
 * @author DXH_AI
 * @date 2026-05-31
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ft232_protocol.h"

/* D2XX驱动头文件 (FTDI官方提供) */
#include "ftd2xx.h"

/*============================================================================
 * FT232驱动封装
 *===========================================================================*/

static FT_HANDLE g_ft_handle = NULL;

/**
 * @brief 初始化FT232设备
 * @return 0成功, 负数失败
 */
int ft232_init(void)
{
    FT_STATUS status;
    
    /* 打开设备 */
    status = FT_Open(0, &g_ft_handle);
    if (status != FT_OK) {
        printf("FT232 Open failed: %d\n", status);
        return -1;
    }
    
    /* 配置为Sync FIFO模式 */
    status = FT_SetBitMode(g_ft_handle, 0xFF, FT_BITMODE_SYNC_FIFO);
    if (status != FT_OK) {
        printf("Set Sync FIFO mode failed: %d\n", status);
        FT_Close(g_ft_handle);
        return -1;
    }
    
    /* 配置USB传输参数 */
    FT_SetUSBParameters(g_ft_handle, 65536, 65536);
    FT_SetTimeouts(g_ft_handle, 500, 500);
    FT_SetLatencyTimer(g_ft_handle, 2);
    
    /* 清空缓冲区 */
    FT_Purge(g_ft_handle, FT_PURGE_RX | FT_PURGE_TX);
    
    printf("FT232 initialized successfully\n");
    return 0;
}

/**
 * @brief 关闭FT232设备
 */
void ft232_deinit(void)
{
    if (g_ft_handle) {
        FT_Close(g_ft_handle);
        g_ft_handle = NULL;
    }
}

/**
 * @brief FT232写入数据 (协议层调用)
 */
int ft232_write(const uint8_t *data, uint16_t length)
{
    DWORD bytes_written;
    FT_STATUS status;
    
    status = FT_Write(g_ft_handle, (LPVOID)data, length, &bytes_written);
    if (status != FT_OK) {
        return -1;
    }
    
    return (int)bytes_written;
}

/**
 * @brief FT232读取数据 (协议层调用)
 */
int ft232_read(uint8_t *data, uint16_t max_length, uint32_t timeout_ms)
{
    DWORD bytes_read;
    FT_STATUS status;
    
    FT_SetTimeouts(g_ft_handle, timeout_ms, 500);
    
    status = FT_Read(g_ft_handle, data, max_length, &bytes_read);
    if (status != FT_OK) {
        return -1;
    }
    
    return (int)bytes_read;
}

/*============================================================================
 * 应用示例
 *===========================================================================*/

/**
 * @brief 示例1: 读取系统状态
 */
void example_read_status(void)
{
    PayloadStatus status;
    int ret;
    
    printf("\n=== 读取系统状态 ===\n");
    
    ret = cmd_status_request(&status);
    if (ret == 0) {
        printf("系统状态: 0x%08X\n", status.sys_status);
        printf("DDR状态:  0x%08X\n", status.ddr_status);
        printf("波形数量: %d\n", status.wave_count);
        printf("ADC状态:  0x%08X\n", status.adc_status);
        printf("错误码:   0x%04X\n", status.error_code);
    } else {
        printf("读取状态失败: %d\n", ret);
    }
}

/**
 * @brief 示例2: 寄存器读写
 */
void example_register_access(void)
{
    int ret;
    uint32_t version;
    
    printf("\n=== 寄存器读写测试 ===\n");
    
    /* 读取系统版本 */
    ret = cmd_reg_read(REG_SYS_VERSION, 1, &version);
    if (ret == 0) {
        printf("系统版本: v%d.%d.%d Build%d\n",
               (version >> 24) & 0xFF,
               (version >> 16) & 0xFF,
               (version >> 8) & 0xFF,
               version & 0xFF);
    }
    
    /* 写入波形周期配置 */
    ret = cmd_reg_write(REG_WAVE_PERIOD, 1000);  /* 1000us周期 */
    if (ret == 0) {
        printf("波形周期配置成功\n");
    }
}

/**
 * @brief 示例3: 单条波形配置
 */
void example_single_wave_config(void)
{
    int ret;
    
    printf("\n=== 单条波形配置 ===\n");
    
    /* 准备波形数据 (5个32位数据) */
    uint32_t wave_data[5] = {
        0x00010002,  /* 参数1 */
        0x00030004,  /* 参数2 */
        0x00050006,  /* 参数3 */
        0x00070008,  /* 参数4 */
        0x00090010   /* 参数5 */
    };
    
    /* 配置波形索引0 */
    ret = cmd_wave_config(0, wave_data, 5);
    if (ret == 0) {
        printf("波形0配置成功\n");
    } else {
        printf("波形0配置失败: %d\n", ret);
    }
}

/**
 * @brief 示例4: 批量波形配置
 */
void example_batch_wave_config(void)
{
    int ret;
    WaveEntry waves[100];
    
    printf("\n=== 批量波形配置 (100条) ===\n");
    
    /* 准备100条波形数据 */
    for (int i = 0; i < 100; i++) {
        waves[i].wave_length = 6;  /* 每条6个32位数据 */
        for (int j = 0; j < 8; j++) {
            waves[i].wave_data[j] = (i << 16) | j;
        }
    }
    
    /* 批量配置从索引100开始 */
    ret = cmd_wave_batch(100, waves, 100);
    if (ret == 0) {
        printf("批量配置成功 (索引100-199)\n");
    } else {
        printf("批量配置失败: %d\n", ret);
    }
}

/**
 * @brief 示例5: 系统控制
 */
void example_system_control(void)
{
    int ret;
    
    printf("\n=== 系统控制 ===\n");
    
    /* 启动发射 */
    printf("启动发射...\n");
    ret = cmd_sys_ctrl(CTRL_TX_START, 0);
    if (ret == 0) {
        printf("发射启动成功\n");
    }
    
    /* 等待一段时间 */
    /* delay_ms(5000); */
    
    /* 停止发射 */
    printf("停止发射...\n");
    ret = cmd_sys_ctrl(CTRL_TX_STOP, 0);
    if (ret == 0) {
        printf("发射停止成功\n");
    }
}

/**
 * @brief 示例6: 全量波形配置 (10000条)
 */
void example_full_wave_config(void)
{
    int ret;
    WaveEntry *waves;
    int total_waves = 10000;
    
    printf("\n=== 全量波形配置 (%d条) ===\n", total_waves);
    
    /* 分配内存 */
    waves = (WaveEntry *)malloc(total_waves * sizeof(WaveEntry));
    if (waves == NULL) {
        printf("内存分配失败\n");
        return;
    }
    
    /* 准备波形数据 */
    for (int i = 0; i < total_waves; i++) {
        waves[i].wave_length = 4 + (i % 5);  /* 长度4-8变化 */
        for (int j = 0; j < 8; j++) {
            waves[i].wave_data[j] = (i << 8) | j;
        }
    }
    
    /* 计时开始 */
    printf("开始传输...\n");
    
    /* 批量配置 */
    ret = cmd_wave_batch(0, waves, total_waves);
    
    if (ret == 0) {
        printf("全量配置成功!\n");
    } else {
        printf("配置失败: %d\n", ret);
    }
    
    free(waves);
}

/*============================================================================
 * 主函数
 *===========================================================================*/

int main(int argc, char *argv[])
{
    printf("===========================================\n");
    printf("  FT232 通信协议测试程序\n");
    printf("  FPGA: Xilinx Zynq7020\n");
    printf("  接口: Sync FIFO Mode\n");
    printf("===========================================\n");
    
    /* 初始化FT232 */
    if (ft232_init() != 0) {
        return -1;
    }
    
    /* 运行示例 */
    example_read_status();
    example_register_access();
    example_single_wave_config();
    example_batch_wave_config();
    example_system_control();
    
    /* 可选: 运行全量配置测试 */
    /* example_full_wave_config(); */
    
    /* 关闭设备 */
    ft232_deinit();
    
    printf("\n测试完成\n");
    return 0;
}
