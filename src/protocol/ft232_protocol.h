/**
 * @file ft232_protocol.h
 * @brief FPGA-x86 FT232通信协议头文件
 * @author DXH_AI
 * @date 2026-05-31
 */

#ifndef __FT232_PROTOCOL_H__
#define __FT232_PROTOCOL_H__

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*============================================================================
 * 常量定义
 *===========================================================================*/

/* 同步字 */
#define SYNC_DOWNLINK           0x55AA      /* 下行同步字 (x86→FPGA) */
#define SYNC_UPLINK             0xAA55      /* 上行同步字 (FPGA→x86) */

/* 帧结构参数 */
#define FRAME_HEADER_SIZE       7           /* 帧头长度: SYNC(2)+Type(1)+Index(2)+Length(2) */
#define FRAME_TAIL_SIZE         3           /* 帧尾长度: CRC(2)+END(1) */
#define FRAME_OVERHEAD          10          /* 帧开销: 头+尾 */
#define MAX_PAYLOAD_SIZE        1012        /* 最大Payload长度 (1024-12预留) */
#define MAX_FRAME_SIZE          1022        /* 最大帧长度 */
#define FRAME_END_BYTE          0x0D        /* 帧结束标志 */

/* FT232缓存限制 */
#define FT232_BUFFER_SIZE       1024        /* FT232缓存大小 */

/* 波形参数 */
#define MAX_WAVE_COUNT          10000       /* 最大波形条数 */
#define MIN_WAVE_LENGTH         4           /* 最小波形长度(32位字) */
#define MAX_WAVE_LENGTH         8           /* 最大波形长度(32位字) */
#define WAVE_ENTRY_SIZE         33          /* 单条波形条目大小(字节) */
#define MAX_WAVES_PER_BATCH     30          /* 每帧最大批量波形数 */

/* ADC数据参数 */
#define ADC_PAYLOAD_SIZE        512         /* ADC数据定长Payload(字节) */
#define ADC_HEADER_SIZE         12          /* ADC数据头部大小(字节) */
#define ADC_MAX_SAMPLES         124         /* 每帧最大采样点数 */
#define ADC_SAMPLE_DATA_SIZE    496         /* 采样数据区大小(124×4) */
#define ADC_PADDING_SIZE        4           /* 填充区大小(字节) */

/* 超时与重传 */
#define ACK_TIMEOUT_MS          500         /* ACK超时时间(ms) */
#define MAX_RETRY_COUNT         3           /* 最大重传次数 */
#define RETRY_DELAY_MS          100         /* 重传延迟(ms) */

/*============================================================================
 * 报文类型定义
 *===========================================================================*/

/* 下行报文类型 (x86 → FPGA) */
typedef enum {
    CMD_REG_WRITE       = 0x01,     /* 寄存器写入命令 */
    CMD_REG_READ        = 0x02,     /* 寄存器读取请求 */
    CMD_WAVE_CONFIG     = 0x03,     /* 单条波形配置 */
    CMD_WAVE_BATCH      = 0x04,     /* 批量波形数据 */
    CMD_SYS_CTRL        = 0x05,     /* 系统控制命令 */
    CMD_STATUS_REQ      = 0x06,     /* 状态查询请求 */
    CMD_ACK             = 0x0F,     /* 应答确认 */
} DownlinkPacketType;

/* 上行报文类型 (FPGA → x86) */
typedef enum {
    RSP_REG_DATA        = 0x81,     /* 寄存器读取响应 */
    RSP_STATUS          = 0x82,     /* 状态信息上报 */
    RSP_ADC_DATA        = 0x83,     /* ADC采样数据 */
    RSP_ADC_BATCH       = 0x84,     /* 批量ADC数据 */
    RSP_ERROR           = 0x85,     /* 错误信息上报 */
    RSP_ACK             = 0x8F,     /* 应答确认 */
} UplinkPacketType;

/*============================================================================
 * 系统控制命令
 *===========================================================================*/

typedef enum {
    CTRL_SYS_RESET      = 0x0001,   /* 系统复位 */
    CTRL_TX_START       = 0x0002,   /* 启动发射 */
    CTRL_TX_STOP        = 0x0003,   /* 停止发射 */
    CTRL_DDR_CLEAR      = 0x0004,   /* DDR清空 */
    CTRL_ADC_START      = 0x0005,   /* ADC启动采集 */
    CTRL_ADC_STOP       = 0x0006,   /* ADC停止采集 */
} SystemControlCmd;

/*============================================================================
 * 错误码定义
 *===========================================================================*/

typedef enum {
    ERR_NONE            = 0x0000,   /* 无错误 */
    ERR_CRC             = 0x0001,   /* CRC校验失败 */
    ERR_LENGTH          = 0x0002,   /* 长度不合法 */
    ERR_TYPE            = 0x0003,   /* 类型不支持 */
    ERR_PARAM           = 0x0004,   /* 参数错误 */
    ERR_TIMEOUT         = 0x0005,   /* 超时 */
    ERR_BUSY            = 0x0006,   /* 设备忙 */
    ERR_DDR_FULL        = 0x0007,   /* DDR缓存满 */
    ERR_DDR_ACCESS      = 0x0008,   /* DDR访问错误 */
    ERR_ADC             = 0x0009,   /* ADC错误 */
} ErrorCode;

/* ACK结果码 */
typedef enum {
    ACK_SUCCESS         = 0x00,     /* 成功 */
    ACK_CRC_ERROR       = 0x01,     /* CRC错误 */
    ACK_LENGTH_ERROR    = 0x02,     /* 长度错误 */
    ACK_TYPE_UNSUPPORT  = 0x03,     /* 类型不支持 */
    ACK_PARAM_ERROR     = 0x04,     /* 参数错误 */
    ACK_EXEC_FAIL       = 0x05,     /* 执行失败 */
    ACK_BUSY            = 0x06,     /* 忙 */
} AckResult;

/*============================================================================
 * 寄存器地址定义
 *===========================================================================*/

/* 系统寄存器 */
#define REG_SYS_VERSION         0x0000      /* 系统版本号 (R) */
#define REG_SYS_STATUS          0x0004      /* 系统状态 (R) */
#define REG_SYS_CTRL            0x0008      /* 系统控制 (RW) */
#define REG_SYS_IRQ             0x000C      /* 中断状态 (RC) */
#define REG_SYS_IRQ_EN          0x0010      /* 中断使能 (RW) */

/* 波形控制寄存器 */
#define REG_WAVE_CTRL           0x0100      /* 波形控制 (RW) */
#define REG_WAVE_COUNT          0x0104      /* 已配置波形数 (R) */
#define REG_WAVE_INDEX          0x0108      /* 当前发射索引 (RW) */
#define REG_WAVE_PERIOD         0x010C      /* 发射周期 (RW) */

/* ADC寄存器 */
#define REG_ADC_CTRL            0x0200      /* ADC控制 (RW) */
#define REG_ADC_STATUS          0x0204      /* ADC状态 (R) */
#define REG_ADC_SAMPLE_CNT      0x0208      /* 采样点数 (RW) */
#define REG_ADC_TRIGGER         0x020C      /* 触发配置 (RW) */

/*============================================================================
 * 数据结构定义
 *===========================================================================*/

#pragma pack(push, 1)

/* 通用帧头 */
typedef struct {
    uint16_t sync;          /* 同步字 */
    uint8_t  type;          /* 报文类型 */
    uint16_t index;         /* 报文序号 */
    uint16_t length;        /* Payload长度 */
} FrameHeader;

/* 通用帧尾 */
typedef struct {
    uint16_t crc;           /* CRC16校验 */
    uint8_t  end;           /* 帧结束标志 */
} FrameTail;

/* 寄存器写入Payload */
typedef struct {
    uint32_t reg_addr;      /* 寄存器地址 */
    uint32_t reg_data;      /* 寄存器数据 */
    uint32_t reserved;      /* 保留 */
} PayloadRegWrite;

/* 寄存器读取请求Payload */
typedef struct {
    uint32_t reg_addr;      /* 起始地址 */
    uint16_t count;         /* 读取数量 */
} PayloadRegRead;

/* 寄存器读取响应Payload */
typedef struct {
    uint32_t reg_addr;      /* 起始地址 */
    uint16_t count;         /* 数据数量 */
    uint32_t data[1];       /* 数据数组(可变长) */
} PayloadRegData;

/* 单条波形配置Payload */
typedef struct {
    uint16_t wave_index;    /* 波形索引 */
    uint8_t  wave_length;   /* 波形长度(4-8) */
    uint32_t wave_data[8];  /* 波形数据 */
} PayloadWaveConfig;

/* 波形条目(批量用) */
typedef struct {
    uint8_t  wave_length;   /* 波形长度 */
    uint32_t wave_data[8];  /* 波形数据(32字节) */
} WaveEntry;

/* 批量波形Payload */
typedef struct {
    uint16_t start_index;   /* 起始索引 */
    uint16_t wave_count;    /* 波形数量 */
    WaveEntry entries[1];   /* 波形条目数组(可变长) */
} PayloadWaveBatch;

/* 系统控制Payload */
typedef struct {
    uint16_t ctrl_cmd;      /* 控制命令 */
    uint32_t ctrl_param;    /* 命令参数 */
    uint32_t reserved;      /* 保留 */
} PayloadSysCtrl;

/* 状态信息Payload */
typedef struct {
    uint32_t sys_status;    /* 系统状态 */
    uint32_t ddr_status;    /* DDR状态 */
    uint16_t wave_count;    /* 已配置波形数 */
    uint32_t adc_status;    /* ADC状态 */
    uint16_t error_code;    /* 错误码 */
    uint32_t reserved;      /* 保留 */
} PayloadStatus;

/* ADC数据Payload (定长512字节) */
typedef struct {
    uint32_t timestamp;         /* 时间戳 */
    uint16_t channel_mask;      /* 通道掩码 */
    uint16_t sample_count;      /* 有效采样点数(≤124) */
    uint32_t reserved;          /* 保留字段 */
    uint32_t data[124];         /* 采样数据(固定124点) */
    uint32_t padding;           /* 填充至512字节 */
} PayloadAdcData;               /* sizeof = 512 */

/* 批量ADC数据Payload (定长512字节) */
typedef struct {
    uint16_t total_frames;      /* 总帧数 */
    uint16_t frame_seq;         /* 当前帧序号 */
    uint32_t timestamp;         /* 时间戳 */
    uint16_t sample_count;      /* 本帧有效采样点数(≤124) */
    uint16_t reserved;          /* 保留 */
    uint32_t data[124];         /* 采样数据(固定124点) */
    uint8_t  padding[4];        /* 填充至512字节 */
} PayloadAdcBatch;              /* sizeof = 512 */

/* ACK响应Payload */
typedef struct {
    uint8_t  ack_type;      /* 被应答的报文类型 */
    uint16_t ack_index;     /* 被应答的报文序号 */
    uint8_t  ack_result;    /* 应答结果 */
} PayloadAck;

/* 错误信息Payload */
typedef struct {
    uint16_t error_code;    /* 错误码 */
    uint32_t error_param;   /* 错误参数 */
    uint32_t error_addr;    /* 错误地址(如适用) */
} PayloadError;

#pragma pack(pop)

/*============================================================================
 * 函数声明
 *===========================================================================*/

/**
 * @brief CRC16-CCITT计算
 * @param data 数据指针
 * @param length 数据长度
 * @return CRC16校验值
 */
uint16_t crc16_ccitt(const uint8_t *data, uint16_t length);

/**
 * @brief 构建帧头
 * @param header 帧头指针
 * @param type 报文类型
 * @param index 报文序号
 * @param payload_len Payload长度
 * @param is_downlink 是否为下行报文
 */
void build_frame_header(FrameHeader *header, uint8_t type, 
                        uint16_t index, uint16_t payload_len, int is_downlink);

/**
 * @brief 构建完整帧
 * @param buffer 输出缓冲区
 * @param type 报文类型
 * @param index 报文序号
 * @param payload Payload数据
 * @param payload_len Payload长度
 * @param is_downlink 是否为下行报文
 * @return 帧总长度
 */
int build_frame(uint8_t *buffer, uint8_t type, uint16_t index,
                const void *payload, uint16_t payload_len, int is_downlink);

/**
 * @brief 解析帧
 * @param buffer 输入缓冲区
 * @param length 缓冲区长度
 * @param header 输出帧头
 * @param payload 输出Payload指针
 * @param payload_len 输出Payload长度
 * @return 0成功, 负数错误码
 */
int parse_frame(const uint8_t *buffer, uint16_t length,
                FrameHeader *header, const uint8_t **payload, uint16_t *payload_len);

/**
 * @brief 发送寄存器写入命令
 * @param addr 寄存器地址
 * @param value 写入值
 * @return 0成功, 负数错误码
 */
int cmd_reg_write(uint32_t addr, uint32_t value);

/**
 * @brief 发送寄存器读取命令
 * @param addr 起始地址
 * @param count 读取数量
 * @param data 输出数据缓冲区
 * @return 0成功, 负数错误码
 */
int cmd_reg_read(uint32_t addr, uint16_t count, uint32_t *data);

/**
 * @brief 配置单条波形
 * @param index 波形索引
 * @param data 波形数据
 * @param length 数据长度(4-8)
 * @return 0成功, 负数错误码
 */
int cmd_wave_config(uint16_t index, const uint32_t *data, uint8_t length);

/**
 * @brief 批量配置波形
 * @param start_index 起始索引
 * @param entries 波形条目数组
 * @param count 波形数量
 * @return 0成功, 负数错误码
 */
int cmd_wave_batch(uint16_t start_index, const WaveEntry *entries, uint16_t count);

/**
 * @brief 发送系统控制命令
 * @param cmd 控制命令
 * @param param 命令参数
 * @return 0成功, 负数错误码
 */
int cmd_sys_ctrl(uint16_t cmd, uint32_t param);

/**
 * @brief 请求状态信息
 * @param status 输出状态结构
 * @return 0成功, 负数错误码
 */
int cmd_status_request(PayloadStatus *status);

#ifdef __cplusplus
}
#endif

#endif /* __FT232_PROTOCOL_H__ */
