/**
 * @file ft232_protocol.c
 * @brief FPGA-x86 FT232通信协议实现
 * @author DXH_AI
 * @date 2026-05-31
 */

#include "ft232_protocol.h"
#include <string.h>

/*============================================================================
 * 内部变量
 *===========================================================================*/

static uint16_t g_packet_index = 0;     /* 全局报文序号 */

/*============================================================================
 * CRC16实现
 *===========================================================================*/

/**
 * @brief CRC16-CCITT计算
 * 多项式: 0x1021, 初始值: 0xFFFF
 */
uint16_t crc16_ccitt(const uint8_t *data, uint16_t length)
{
    uint16_t crc = 0xFFFF;
    
    for (uint16_t i = 0; i < length; i++) {
        crc ^= (uint16_t)data[i] << 8;
        for (uint8_t j = 0; j < 8; j++) {
            if (crc & 0x8000) {
                crc = (crc << 1) ^ 0x1021;
            } else {
                crc <<= 1;
            }
        }
    }
    
    return crc;
}

/*============================================================================
 * 帧构建函数
 *===========================================================================*/

/**
 * @brief 构建帧头
 */
void build_frame_header(FrameHeader *header, uint8_t type, 
                        uint16_t index, uint16_t payload_len, int is_downlink)
{
    header->sync = is_downlink ? SYNC_DOWNLINK : SYNC_UPLINK;
    header->type = type;
    header->index = index;
    header->length = payload_len;
}

/**
 * @brief 构建完整帧
 * @return 帧总长度, 或负数表示错误
 */
int build_frame(uint8_t *buffer, uint8_t type, uint16_t index,
                const void *payload, uint16_t payload_len, int is_downlink)
{
    if (buffer == NULL) {
        return -ERR_PARAM;
    }
    
    if (payload_len > MAX_PAYLOAD_SIZE) {
        return -ERR_LENGTH;
    }
    
    uint16_t offset = 0;
    
    /* 填充帧头 */
    FrameHeader *header = (FrameHeader *)buffer;
    build_frame_header(header, type, index, payload_len, is_downlink);
    offset += sizeof(FrameHeader);
    
    /* 填充Payload */
    if (payload != NULL && payload_len > 0) {
        memcpy(buffer + offset, payload, payload_len);
        offset += payload_len;
    }
    
    /* 计算CRC (从SYNC到Payload末尾) */
    uint16_t crc = crc16_ccitt(buffer, offset);
    
    /* 填充CRC */
    buffer[offset++] = (crc >> 8) & 0xFF;   /* CRC高字节 */
    buffer[offset++] = crc & 0xFF;          /* CRC低字节 */
    
    /* 填充帧结束标志 */
    buffer[offset++] = FRAME_END_BYTE;
    
    return offset;
}

/*============================================================================
 * 帧解析函数
 *===========================================================================*/

/**
 * @brief 解析帧
 * @return 0成功, 负数错误码
 */
int parse_frame(const uint8_t *buffer, uint16_t length,
                FrameHeader *header, const uint8_t **payload, uint16_t *payload_len)
{
    if (buffer == NULL || header == NULL) {
        return -ERR_PARAM;
    }
    
    /* 检查最小长度 */
    if (length < FRAME_OVERHEAD) {
        return -ERR_LENGTH;
    }
    
    /* 解析帧头 */
    memcpy(header, buffer, sizeof(FrameHeader));
    
    /* 检查同步字 */
    if (header->sync != SYNC_DOWNLINK && header->sync != SYNC_UPLINK) {
        return -ERR_CRC;  /* 同步字错误 */
    }
    
    /* 检查Payload长度 */
    if (header->length > MAX_PAYLOAD_SIZE) {
        return -ERR_LENGTH;
    }
    
    /* 检查总长度 */
    uint16_t expected_len = FRAME_OVERHEAD + header->length;
    if (length < expected_len) {
        return -ERR_LENGTH;
    }
    
    /* 检查帧结束标志 */
    if (buffer[expected_len - 1] != FRAME_END_BYTE) {
        return -ERR_CRC;
    }
    
    /* 计算并校验CRC */
    uint16_t crc_offset = FRAME_HEADER_SIZE + header->length;
    uint16_t crc_calc = crc16_ccitt(buffer, crc_offset);
    uint16_t crc_recv = ((uint16_t)buffer[crc_offset] << 8) | buffer[crc_offset + 1];
    
    if (crc_calc != crc_recv) {
        return -ERR_CRC;
    }
    
    /* 输出Payload信息 */
    if (payload != NULL) {
        *payload = (header->length > 0) ? (buffer + FRAME_HEADER_SIZE) : NULL;
    }
    if (payload_len != NULL) {
        *payload_len = header->length;
    }
    
    return 0;
}

/*============================================================================
 * 底层发送/接收函数 (需外部实现)
 *===========================================================================*/

/* 声明外部函数 */
extern int ft232_write(const uint8_t *data, uint16_t length);
extern int ft232_read(uint8_t *data, uint16_t max_length, uint32_t timeout_ms);

/*============================================================================
 * 高级命令函数
 *===========================================================================*/

/**
 * @brief 获取下一个报文序号
 */
static uint16_t get_next_index(void)
{
    return g_packet_index++;
}

/**
 * @brief 等待ACK响应
 */
static int wait_ack(uint16_t expected_index, uint32_t timeout_ms)
{
    uint8_t rx_buffer[MAX_FRAME_SIZE];
    FrameHeader header;
    const uint8_t *payload;
    uint16_t payload_len;
    
    int len = ft232_read(rx_buffer, MAX_FRAME_SIZE, timeout_ms);
    if (len <= 0) {
        return -ERR_TIMEOUT;
    }
    
    int ret = parse_frame(rx_buffer, len, &header, &payload, &payload_len);
    if (ret < 0) {
        return ret;
    }
    
    if (header.type != RSP_ACK) {
        return -ERR_TYPE;
    }
    
    PayloadAck *ack = (PayloadAck *)payload;
    if (ack->ack_index != expected_index) {
        return -ERR_PARAM;
    }
    
    if (ack->ack_result != ACK_SUCCESS) {
        return -ack->ack_result;
    }
    
    return 0;
}

/**
 * @brief 发送命令并等待ACK
 */
static int send_cmd_with_ack(uint8_t type, const void *payload, 
                             uint16_t payload_len, int retries)
{
    uint8_t tx_buffer[MAX_FRAME_SIZE];
    uint16_t index = get_next_index();
    
    int frame_len = build_frame(tx_buffer, type, index, payload, payload_len, 1);
    if (frame_len < 0) {
        return frame_len;
    }
    
    for (int i = 0; i <= retries; i++) {
        int ret = ft232_write(tx_buffer, frame_len);
        if (ret < 0) {
            continue;
        }
        
        ret = wait_ack(index, ACK_TIMEOUT_MS);
        if (ret == 0) {
            return 0;
        }
        
        /* 重传延迟 */
        if (i < retries) {
            /* delay_ms(RETRY_DELAY_MS); */
        }
    }
    
    return -ERR_TIMEOUT;
}

/**
 * @brief 发送寄存器写入命令
 */
int cmd_reg_write(uint32_t addr, uint32_t value)
{
    PayloadRegWrite payload = {
        .reg_addr = addr,
        .reg_data = value,
        .reserved = 0
    };
    
    return send_cmd_with_ack(CMD_REG_WRITE, &payload, sizeof(payload), MAX_RETRY_COUNT);
}

/**
 * @brief 发送寄存器读取命令
 */
int cmd_reg_read(uint32_t addr, uint16_t count, uint32_t *data)
{
    if (data == NULL || count == 0) {
        return -ERR_PARAM;
    }
    
    uint8_t tx_buffer[MAX_FRAME_SIZE];
    uint8_t rx_buffer[MAX_FRAME_SIZE];
    uint16_t index = get_next_index();
    
    PayloadRegRead req = {
        .reg_addr = addr,
        .count = count
    };
    
    int frame_len = build_frame(tx_buffer, CMD_REG_READ, index, &req, sizeof(req), 1);
    if (frame_len < 0) {
        return frame_len;
    }
    
    for (int i = 0; i <= MAX_RETRY_COUNT; i++) {
        int ret = ft232_write(tx_buffer, frame_len);
        if (ret < 0) {
            continue;
        }
        
        int len = ft232_read(rx_buffer, MAX_FRAME_SIZE, ACK_TIMEOUT_MS);
        if (len <= 0) {
            continue;
        }
        
        FrameHeader header;
        const uint8_t *payload;
        uint16_t payload_len;
        
        ret = parse_frame(rx_buffer, len, &header, &payload, &payload_len);
        if (ret < 0) {
            continue;
        }
        
        if (header.type == RSP_REG_DATA) {
            PayloadRegData *rsp = (PayloadRegData *)payload;
            if (rsp->count <= count) {
                memcpy(data, rsp->data, rsp->count * sizeof(uint32_t));
                return 0;
            }
        }
    }
    
    return -ERR_TIMEOUT;
}

/**
 * @brief 配置单条波形
 */
int cmd_wave_config(uint16_t index, const uint32_t *data, uint8_t length)
{
    if (data == NULL || length < MIN_WAVE_LENGTH || length > MAX_WAVE_LENGTH) {
        return -ERR_PARAM;
    }
    
    if (index >= MAX_WAVE_COUNT) {
        return -ERR_PARAM;
    }
    
    PayloadWaveConfig payload;
    memset(&payload, 0, sizeof(payload));
    payload.wave_index = index;
    payload.wave_length = length;
    memcpy(payload.wave_data, data, length * sizeof(uint32_t));
    
    uint16_t payload_len = 3 + length * sizeof(uint32_t);
    return send_cmd_with_ack(CMD_WAVE_CONFIG, &payload, payload_len, MAX_RETRY_COUNT);
}

/**
 * @brief 批量配置波形
 */
int cmd_wave_batch(uint16_t start_index, const WaveEntry *entries, uint16_t count)
{
    if (entries == NULL || count == 0) {
        return -ERR_PARAM;
    }
    
    if (start_index + count > MAX_WAVE_COUNT) {
        return -ERR_PARAM;
    }
    
    uint8_t payload_buffer[MAX_PAYLOAD_SIZE];
    uint16_t remaining = count;
    uint16_t current_index = start_index;
    const WaveEntry *current_entry = entries;
    
    while (remaining > 0) {
        uint16_t batch_count = (remaining > MAX_WAVES_PER_BATCH) ? 
                                MAX_WAVES_PER_BATCH : remaining;
        
        /* 构建批量Payload */
        PayloadWaveBatch *batch = (PayloadWaveBatch *)payload_buffer;
        batch->start_index = current_index;
        batch->wave_count = batch_count;
        
        memcpy(batch->entries, current_entry, batch_count * sizeof(WaveEntry));
        
        uint16_t payload_len = 4 + batch_count * sizeof(WaveEntry);
        
        int ret = send_cmd_with_ack(CMD_WAVE_BATCH, payload_buffer, 
                                    payload_len, MAX_RETRY_COUNT);
        if (ret < 0) {
            return ret;
        }
        
        remaining -= batch_count;
        current_index += batch_count;
        current_entry += batch_count;
    }
    
    return 0;
}

/**
 * @brief 发送系统控制命令
 */
int cmd_sys_ctrl(uint16_t cmd, uint32_t param)
{
    PayloadSysCtrl payload = {
        .ctrl_cmd = cmd,
        .ctrl_param = param,
        .reserved = 0
    };
    
    return send_cmd_with_ack(CMD_SYS_CTRL, &payload, sizeof(payload), MAX_RETRY_COUNT);
}

/**
 * @brief 请求状态信息
 */
int cmd_status_request(PayloadStatus *status)
{
    if (status == NULL) {
        return -ERR_PARAM;
    }
    
    uint8_t tx_buffer[MAX_FRAME_SIZE];
    uint8_t rx_buffer[MAX_FRAME_SIZE];
    uint16_t index = get_next_index();
    
    /* 状态请求无Payload */
    int frame_len = build_frame(tx_buffer, CMD_STATUS_REQ, index, NULL, 0, 1);
    if (frame_len < 0) {
        return frame_len;
    }
    
    for (int i = 0; i <= MAX_RETRY_COUNT; i++) {
        int ret = ft232_write(tx_buffer, frame_len);
        if (ret < 0) {
            continue;
        }
        
        int len = ft232_read(rx_buffer, MAX_FRAME_SIZE, ACK_TIMEOUT_MS);
        if (len <= 0) {
            continue;
        }
        
        FrameHeader header;
        const uint8_t *payload;
        uint16_t payload_len;
        
        ret = parse_frame(rx_buffer, len, &header, &payload, &payload_len);
        if (ret < 0) {
            continue;
        }
        
        if (header.type == RSP_STATUS && payload_len >= sizeof(PayloadStatus)) {
            memcpy(status, payload, sizeof(PayloadStatus));
            return 0;
        }
    }
    
    return -ERR_TIMEOUT;
}
