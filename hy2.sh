#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 极速抢占带宽版部署脚本（支持命令行端口参数 + 默认跳过证书验证）
# 针对高延迟、高丢包链路激进优化，同时兼顾低内存（32-64MB）环境

set -e

# ---------- 默认配置 ----------
HYSTERIA_VERSION="v2.6.5"
DEFAULT_PORT=22222         # 自适应端口
AUTH_PASSWORD="wdx526"   # 建议修改为复杂密码
CERT_FILE="cert.pem"
KEY_FILE="key.pem"
SNI="www.bing.com"
ALPN="h3"
# ------------------------------

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "Hysteria2 激进网速抢占部署脚本（Shell 版）"
echo "支持命令行端口参数，如：bash hysteria2.sh 443"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

# ---------- 获取端口 ----------
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    SERVER_PORT="$1"
    echo "✅ 使用命令行指定端口: $SERVER_PORT"
else
    SERVER_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
    echo "⚙️ 未提供端口参数，使用默认端口: $SERVER_PORT"
fi

# ---------- 检测架构 ----------
arch_name() {
    local machine
    machine=$(uname -m | tr '[:upper:]' '[:lower:]')
    if [[ "$machine" == *"arm64"* ]] || [[ "$machine" == *"aarch64"* ]]; then
        echo "arm64"
    elif [[ "$machine" == *"x86_64"* ]] || [[ "$machine" == *"amd64"* ]]; then
        echo "amd64"
    else
        echo ""
    fi
}

ARCH=$(arch_name)
if [ -z "$ARCH" ]; then
  echo "❌ 无法识别 CPU 架构: $(uname -m)"
  exit 1
fi

BIN_NAME="hysteria-linux-${ARCH}"
BIN_PATH="./${BIN_NAME}"

# ---------- 下载二进制 ----------
download_binary() {
    if [ -f "$BIN_PATH" ]; then
        echo "✅ 二进制已存在，跳过下载。"
        return
    fi
    URL="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN_NAME}"
    echo "⏳ 下载: $URL"
    curl -L --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$URL"
    chmod +x "$BIN_PATH"
    echo "✅ 下载完成并设置可执行: $BIN_PATH"
}

# ---------- 生成证书 ----------
ensure_cert() {
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        echo "✅ 发现证书，使用现有 cert/key。"
        return
    fi
    echo "🔑 未发现证书，使用 openssl 生成自签证书（prime256v1）..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}"
    echo "✅ 证书生成成功。"
}

# ---------- 写配置文件（狂暴抢占网速优化） ----------
write_config() {
cat > server.yaml <<EOF
listen: ":${SERVER_PORT}"
tls:
  cert: "$(pwd)/${CERT_FILE}"
  key: "$(pwd)/${KEY_FILE}"
  alpn:
    - "${ALPN}"
auth:
  type: "password"
  password: "${AUTH_PASSWORD}"

# 解锁带宽上限
bandwidth:
  up: "1gbps"
  down: "1gbps"

# 核心抢占与速度优化参数
quic:
  # 减少空闲超时，快速释放无效连接，防死锁
  max_idle_timeout: "30s"
  # 允许的最大并发流，16个足够榨干单用户带宽
  max_concurrent_streams: 16
  
  # 激进接收窗口优化：扩大到 4MB-8MB，确保高延迟长肥管道（LFN）跑满
  initial_stream_receive_window: 4194304
  max_stream_receive_window: 8388608
  initial_conn_receive_window: 8388608
  max_conn_receive_window: 16777216
  
  # 【终极抢占】开启忽略丢包模式，防止网络抖动时暴力降速
  ignore_packet_loss: true
EOF
    echo "✅ 写入配置 server.yaml（已注入网速抢占优化）。"
}

# ---------- 获取服务器 IP ----------
get_server_ip() {
    IP=$(curl -s --max-time 10 https://api.ipify.org || echo "YOUR_SERVER_IP")
    echo "$IP"
}

# ---------- 打印连接信息 ----------
print_connection_info() {
    local IP="$1"
    echo "🎉 Hysteria2 部署成功！（狂暴抢占优化版）"
    echo "=========================================================================="
    echo "📋 服务器信息:"
    echo "    🌐 IP地址: $IP"
    echo "    🔌 端口: $SERVER_PORT"
    echo "    🔑 密码: $AUTH_PASSWORD"
    echo ""
    echo "📱 节点链接（客户端也需要配置对应的速度或不限速）："
    echo "hysteria2://${AUTH_PASSWORD}@${IP}:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-Turbo"
    echo ""
    echo "📄 建议客户端（Client）配置中加上："
    echo "bandwidth:"
    echo "  up: 100mbps   # 根据你本地实际宽带上传填写"
    echo "  down: 500mbps # 根据你本地实际宽带下载填写"
    echo "=========================================================================="
}

# ---------- 主逻辑 ----------
main() {
    download_binary
    ensure_cert
    write_config
    SERVER_IP=$(get_server_ip)
    print_connection_info "$SERVER_IP"
    echo "🚀 以狂暴速度模式启动 Hysteria2 服务器..."
    exec "$BIN_PATH" server -c server.yaml
}

main "$@"
