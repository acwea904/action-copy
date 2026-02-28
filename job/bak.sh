#!/usr/bin/env bash

#---------------------------------------------------------------
# 1. 远程 VPS SSH 连接配置
#---------------------------------------------------------------
SSH_IP="SSH_IP"
SSH_PORT="22"
SSH_USER="root"
SSH_PASS="SSH_PASS" # 请务必在此处填入真实的密码

#---------------------------------------------------------------
# 2. WebDAV 账号配置 (请务必修改)
#---------------------------------------------------------------
# 结尾请务必带上 /
WEBDAV_URL="https://rebun.infini-cloud.net/dav/WEBDAV/" 
WEBDAV_USER="WEBDAV_USER"
WEBDAV_PASS="WEBDAV_PASS"
KEEP_DAYS=5  # 保留最近 5 天的备份

#---------------------------------------------------------------
# 3. 读取青龙环境变量 (由脚本自动从环境获取)
#---------------------------------------------------------------
# 变量名需与青龙面板“环境变量”列表中的名称一致
TG_ID="${TG_USER_ID:-}"
TG_TOKEN="${TG_BOT_TOKEN:-}"

#---------------------------------------------------------------
# 4. 哪吒面板目录
#---------------------------------------------------------------
WORK_DIR="/home/dpanel/compose/qinglong"

#---------------------------------------------------------------
# 5. 执行逻辑
#---------------------------------------------------------------
if ! command -v sshpass &> /dev/null; then
    echo "[ERROR] 请在青龙面板依赖管理中安装 sshpass"
    exit 1
fi

echo "=========================================================="
echo "▶ 启动青龙面板远程备份任务: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================================="

# 远程执行开始
sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" "$SSH_USER@$SSH_IP" << EOF
    # 设置日志颜色函数
    info() { echo -e "\033[32m[INFO] \$*\033[0m"; }
    warn() { echo -e "\033[33m[WARN] \$*\033[0m"; }
    error() { echo -e "\033[31m[ERROR] \$*\033[0m"; }

    # 1. 变量初始化
    TIMESTAMP=\$(TZ="Asia/Shanghai" date +"%Y-%m-%d-%H-%M-%S")
    BACKUP_TIME=\$(TZ="Asia/Shanghai" date +"%Y-%m-%d %H:%M:%S")
    BACKUP_FILE="qinglong-backup-\${TIMESTAMP}.tar.gz"
    TEMP_DIR="/tmp/backup-\$\$"

    # 2. 数据准备 (复制模式)
    info "步骤 1: 正在创建临时目录并复制数据..."
    mkdir -p "\$TEMP_DIR/data"
    if [ ! -d "$WORK_DIR/data" ]; then
        error "失败: 源目录 $WORK_DIR/data 不存在"
        exit 1
    fi
    cp -R "$WORK_DIR/data" "\$TEMP_DIR/"
    info "数据复制完成。"

    # 3. 打包压缩
    info "步骤 2: 正在打包压缩数据: \$BACKUP_FILE"
    cd "\$TEMP_DIR"
    tar -czf "\$BACKUP_FILE" data/
    BACKUP_SIZE=\$(du -h "\$BACKUP_FILE" | cut -f1)
    info "压缩完成，文件大小: \$BACKUP_SIZE"

    # 4. WebDAV 上传
    info "步骤 3: 正在上传至 WebDAV 远程存储..."
    UPLOAD_STATUS=\$(curl -u "${WEBDAV_USER}:${WEBDAV_PASS}" \
        -T "\$BACKUP_FILE" \
        -s -w "%{http_code}" -o /dev/null \
        "${WEBDAV_URL}\$BACKUP_FILE")

    if [ "\$UPLOAD_STATUS" -ge 200 ] && [ "\$UPLOAD_STATUS" -lt 300 ]; then
        info "上传成功 ✓ (HTTP \$UPLOAD_STATUS)"
    else
        error "上传失败! HTTP 状态码: \$UPLOAD_STATUS"
        # 失败则发送简易 TG 通知
        if [ -n "$TG_ID" ] && [ -n "$TG_TOKEN" ]; then
            curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
                -d "chat_id=${TG_ID}" \
                -d "text=❌ 青龙面板备份上传失败! HTTP: \$UPLOAD_STATUS" > /dev/null
        fi
        rm -rf "\$TEMP_DIR"
        exit 1
    fi

    # 5. 清理 WebDAV 旧备份 (只保留最近5个)
    info "步骤 4: 正在检查 WebDAV 存档数量..."
    FILE_INFO=\$(curl -s -u "${WEBDAV_USER}:${WEBDAV_PASS}" -X PROPFIND -H "Depth: 1" "${WEBDAV_URL}" 2>/dev/null)
    ALL_FILES=\$(echo "\$FILE_INFO" | grep -oE 'qinglong-backup-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}\.tar\.gz' | sort -r)
    
    TOTAL_COUNT=\$(echo "\$ALL_FILES" | wc -l)
    SUCCESS_COUNT=0
    INDEX=0
    
    while read -r old_file; do
        if [ -z "\$old_file" ]; then continue; fi
        INDEX=\$((INDEX+1))
        if [ \$INDEX -gt 5 ]; then
            warn "正在删除过期备份: \$old_file"
            curl -s -u "${WEBDAV_USER}:${WEBDAV_PASS}" -X DELETE "${WEBDAV_URL}\$old_file" >/dev/null
        else
            SUCCESS_COUNT=\$((SUCCESS_COUNT+1))
        fi
    done <<< "\$ALL_FILES"

    # 6. 生成图表并发送 TG 通知
    info "步骤 5: 正在生成图表统计并发送 Telegram 通知..."
    PERCENT=\$((SUCCESS_COUNT * 20))
    CHART_BAR=""
    for i in \$(seq 1 \$SUCCESS_COUNT); do CHART_BAR+="🔵"; done
    for i in \$(seq 1 \$((5 - SUCCESS_COUNT))); do CHART_BAR+="⚪"; done

    TG_MSG="<b>📊 qinglong 备份统计报告</b>%0A"
    TG_MSG+="━━━━━━━━━━━━━━━%0A"
    TG_MSG+="<b>🔹 最新备份信息</b>%0A"
    TG_MSG+="▫️ 文件名称: <code>\$BACKUP_FILE</code>%0A"
    TG_MSG+="▫️ 备份时间: <code>\$BACKUP_TIME</code>%0A"
    TG_MSG+="▫️ 文件大小: <code>\$BACKUP_SIZE</code>%0A%0A"
    TG_MSG+="<b>🔹 WebDAV 存储状态 (Max: 5)</b>%0A"
    TG_MSG+="\$CHART_BAR  <b>\${PERCENT}%</b>%0A"
    TG_MSG+="▫️ 当前有效份数: \$SUCCESS_COUNT / 5%0A"
    TG_MSG+="━━━━━━━━━━━━━━━%0A"
    TG_MSG+="✨ <i>所有数据已加密并安全同步</i>"

    if [ -n "$TG_ID" ] && [ -n "$TG_TOKEN" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            -d "chat_id=${TG_ID}" \
            -d "parse_mode=HTML" \
            -d "text=\$TG_MSG" > /dev/null
    fi

    # 7. 清理本地临时文件
    info "步骤 6: 正在清理 VPS 临时文件..."
    cd /tmp && rm -rf "\$TEMP_DIR"
    
    info "=========================================="
    info "✅ 备份任务全部完成！"
    info "=========================================="
EOF

if [ $? -eq 0 ]; then
    echo "----------------------------------------------------------"
    echo "✔ 青龙面板：远程 SSH 脚本执行成功。"
else
    echo "----------------------------------------------------------"
    echo "✘ 青龙面板：脚本执行过程中出现异常，请检查上方 SSH 详细日志。"
fi