#!/bin/bash

# 检查 jq 是否安装
if ! command -v jq &> /dev/null; then
  echo "❌ 请先安装 jq 工具（用于解析 JSON）"
  echo "例如：apt install jq 或 pkg install jq"
  exit 1
fi

# 创建目录
mkdir -p /root/catmi

# 用户输入 API Token
echo "请输入你的 Cloudflare API Token:"
read -r CF_API_TOKEN

# 用户输入完整域名
echo "请输入你要申请证书的域名（例如：example.com 或 sub.example.com）:"
read -r FULL_DOMAIN

# 提取主域名部分（从 cdascoi.casmi.dpdns.org 提取 casmi.dpdns.org）
ROOT_DOMAIN=$(echo "$FULL_DOMAIN" | awk -F. '{print $(NF-2)"."$(NF-1)"."$NF}')

# 获取 Zone ID
echo "🌐 正在获取 Zone ID for $ROOT_DOMAIN..."
ZONE_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${ROOT_DOMAIN}" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json")

ZONE_ID=$(echo "$ZONE_RESPONSE" | jq -r '.result[0].id')

if [[ "$ZONE_ID" == "null" || -z "$ZONE_ID" ]]; then
  echo "❌ 无法获取 Zone ID，请确认 Token 权限和域名是否正确。"
  echo "$ZONE_RESPONSE"
  exit 1
fi

echo "✅ 已获取 Zone ID: $ZONE_ID"

# 定义证书、密钥、CSR 文件路径
CERT_FILE="/root/catmi/server.crt"
KEY_FILE="/root/catmi/server.key"
CSR_FILE="/root/catmi/server.csr"

# 生成私钥
echo "🔐 正在生成私钥：$KEY_FILE"
openssl genrsa -out "$KEY_FILE" 2048

# 生成 CSR
echo "📄 正在生成证书签名请求 (CSR)..."
openssl req -new -key "$KEY_FILE" -subj "/CN=$FULL_DOMAIN" -out "$CSR_FILE"

# 提取 CSR 内容
CSR_CONTENT=$(cat "$CSR_FILE" | sed '/-----/d' | tr -d '\n')

# 请求 Origin CA 证书
echo "📡 正在向 Cloudflare 申请 15 年 Origin CA 证书..."
RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/origin_tls_client_auth/hostnames" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  --data '{
    "hostnames": ["'"$FULL_DOMAIN"'"],
    "requested_validity": 5475,
    "type": "origin-rsa",
    "csr": "'"$CSR_CONTENT"'"
  }')

SUCCESS=$(echo "$RESPONSE" | jq -r '.success')
if [[ "$SUCCESS" != "true" ]]; then
  echo "❌ 证书申请失败，Cloudflare 返回如下信息："
  echo "$RESPONSE" | jq
  echo ""
  echo "📛 错误摘要："
  echo "$RESPONSE" | jq -r '.errors[] | "Code: \(.code), Message: \(.message)"'
  exit 1
fi

# 提取证书内容并保存
CERT=$(echo "$RESPONSE" | jq -r '.result.certificate')
echo "$CERT" > "$CERT_FILE"

# 清理 CSR 文件
rm -f "$CSR_FILE"

# 输出成功信息
echo "✅ 成功申请 Cloudflare Origin CA 证书"
echo "📄 证书保存路径：$CERT_FILE"
echo "🔑 私钥保存路径：$KEY_FILE"
