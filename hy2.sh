#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 翼龙面板单端口晚高峰抗封锁优化版
# 针对 Docker 容器网络栈与晚高峰运营商 UDP QoS 限速进行深度调优

set -e

# ---------- 翼龙面板环境适配 ----------
# 翼龙面板通常将工作目录限制在 /home/container
WORKSPACE="/home/container"
cd "$WORKSPACE"

HYSTERIA_VERSION="v2.6.5"
AUTH_PASSWORD="wdx526"   # 建议修改为你的复杂密码
CERT_FILE="cert.pem"
KEY_FILE="key.pem"
SNI="www.bing.com"
ALPN="h3"

echo "=========================================================================="
echo " Hysteria2 翼龙面板专用部署脚本 (单端口抗晚高峰断流优化版)"
echo "=========================================================================="

# ---------- 获取翼龙分配的端口 ----------
# 翼龙面板通常会传递当前的 PORT 变量，如果没有则使用面板配置的参数 $1
if [ -n "${SERVER_PORT:-}" ]; then
    PORT="$SERVER_PORT"
elif [[ $# -ge 1 && -n "${1:-}" ]]; then
    PORT="$1"
else
    # 如果实在找不到，默认使用 22222（请确保这与面板分配的端口一致）
    PORT=22222
fi
echo "📢 当前容器绑定端口: $PORT"

# ---------- 检测 CPU 架构 ----------
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
BIN_PATH="${WORKSPACE}/${BIN_NAME}"

# ---------- 下载二进制 ----------
download_binary() {
    if [ -f "$BIN_PATH" ]; then
        echo "✅ Hysteria2 二进制文件已存在，跳过下载。"
        return
    fi
    URL="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN_NAME}"
    echo "⏳ 正在从 GitHub 下载二进制文件..."
    curl -L --retry 3 --connect-timeout 20 -o "$BIN_PATH" "$URL"
    chmod +x "$BIN_PATH"
    echo "✅ 下载完成并成功赋予执行权限。"
}

# ---------- 生成自签证书 ----------
ensure_cert() {
    if [ -f "$WORKSPACE/$CERT_FILE" ] && [ -f "$WORKSPACE/$KEY_FILE" ]; then
        echo "✅ 发现现有证书，跳过生成。"
        return
    fi
    echo "🔑 未发现证书，正在生成 10 年期自签证书 (prime256v1)..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$WORKSPACE/$KEY_FILE" -out "$WORKSPACE/$CERT_FILE" -subj "/CN=${SNI}"
    echo "✅ 证书生成成功。"
}

# ---------- 写配置文件（针对单端口 Docker 与晚高峰抗 QoS 调优） ----------
write_config() {
cat > "$WORKSPACE/server.yaml" <<EOF
# 绑定翼龙分配的唯一端口
listen: ":${PORT}"

tls:
  cert: "$WORKSPACE/${CERT_FILE}"
  key: "$WORKSPACE/${KEY_FILE}"
  alpn:
    - "${ALPN}"

auth:
  type: "password"
  password: "${AUTH_PASSWORD}"

# 【抗 QoS 核心优化 1】降低单端口宣称带宽
# 在晚高峰，将单端口限速在 150M 左右是最稳妥的。
# 填 1Gbps 会导致 Docker 虚拟网卡疯狂重传丢包，直接触发运营商断流，网页疯狂转圈。
bandwidth:
  up: "150mbps"
  down: "150mbps"

quic:
  # 【抗 QoS 核心优化 2】缩短断流超时时间
  # 晚高峰一旦遇到运营商短暂的 UDP 阻断，让连接在 10 秒内快速断开并重连，而不是让网页死等转圈
  max_idle_timeout: "10s"
  
  # 限制最大并发流，降低单端口 Docker 容器的 Conntrack（连接跟踪）表压力
  max_concurrent_streams: 32
  
  # 【抗 QoS 核心优化 3】收紧接收窗口大小
  # 放弃之前 8MB/16MB 的狂暴参数。晚高峰单端口根本吃不下那么大的缓冲区，会导致严重的丢包。
  # 适当收紧窗口，流量更平滑，防火墙更不容易识别。
  initial_stream_receive_window: 1048576    # 1MB
  max_stream_receive_window: 2097152        # 2MB
  initial_conn_receive_window: 2097152      # 2MB
  max_conn_receive_window: 4194304          # 4MB
  
  # 【抗 QoS 核心优化 4】严禁开启忽略丢包
  # 晚高峰开启 ignore_packet_loss 会导致单端口产生海量的无效重传特征，瞬间被防火墙拉黑。
  ignore_packet_loss: false
EOF
    echo "✅ 针对翼龙单端口优化的 server.yaml 配置文件写入成功。"
}

# ---------- 获取服务器 IP ----------
get_server_ip() {
    IP=$(curl -s --max-time 5 https://api.ipify.org || echo "YOUR_SERVER_IP")
    echo "$IP"
}

# ---------- 打印节点信息 ----------
print_connection_info() {
    local IP="$1"
    echo "=========================================================================="
    echo "🎉 Hysteria2 晚高峰稳定版配置成功！"
    echo "📋 节点连接信息:"
    echo "    🌐 服务器 IP : $IP"
    echo "    🔌 容器端口  : $PORT"
    echo "    🔑 认证密码  : $AUTH_PASSWORD"
    echo "=========================================================================="
    echo "📱 通用客户端节点链接 (已开启跳过证书验证):"
    echo "hysteria2://${AUTH_PASSWORD}@${IP}:${PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-Pterodactyl"
    echo "=========================================================================="
    echo "⚠️【极为重要】为了防止晚高峰网页转圈，请必须在你的客户端（电脑/手机）中限速："
    echo "  bandwidth:"
    echo "    up: 20mbps    # 根据你本地宽带上传的 30% 填写"
    echo "    down: 45mbps  # 严格限制在 50M 以下！主动限速能让流量平滑，躲过晚高峰 QoS 惩罚"
    echo "=========================================================================="
}

# ---------- 主逻辑 ----------
main() {
    download_binary
    ensure_cert
    write_config
    SERVER_IP=$(get_server_ip)
    print_connection_info "$SERVER_IP"
    
    echo "🚀 正在启动 Hysteria2 服务..."
    exec "$BIN_PATH" server -c "$WORKSPACE/server.yaml"
}

main "$@"
