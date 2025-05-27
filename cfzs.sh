#!/bin/bash

# 创建目录（如果不存在）
mkdir -p /root/catmi

echo "请输入你的 Cloudflare API Token:"
read -r CF_API_TOKEN

echo "请输入你的 Cloudflare Zone ID:"
read -r ZONE_ID

echo "请输入你要申请证书的域名（例如：example.com）:"
read -r DOMAIN

# 默认文件路径
CERT_FILE="/root/catmi/server.crt"
KEY_FILE="/root/catmi/server.key"
CSR_FILE="/root/catmi/server.csr"

echo "🔐 正在生成私钥：$KEY_FILE"
openssl genrsa -out "$KEY_FILE" 2048

echo "📄 生成证书签名请求 (CSR)..."
openssl req -new -key "$KEY_FILE" -subj "/CN=$DOMAIN" -out "$CSR_FILE"

# 读取CSR内容
CSR_CONTENT=$(cat "$CSR_FILE" | sed '/-----/d' | tr -d '\n')

echo "📡 正在向 Cloudflare 申请 15 年 Origin CA 证书..."

# 请求 Origin CA 证书
RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/origin_tls_client_auth/hostnames" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  --data '{
    "hostnames": ["'"$DOMAIN"'"],
    "requested_validity": 5475,
    "type": "origin-rsa",
    "csr": "'"$CSR_CONTENT"'"
  }')

# 解析结果
SUCCESS=$(echo "$RESPONSE" | jq -r '.success')
if [[ "$SUCCESS" != "true" ]]; then
  echo "❌ 申请失败:"
  echo "$RESPONSE"
  exit 1
fi

# 提取证书内容并保存
CERT=$(echo "$RESPONSE" | jq -r '.result.certificate')
echo "$CERT" > "$CERT_FILE"

# 清理临时CSR文件
rm -f "$CSR_FILE"

echo "✅ 成功申请 Cloudflare Origin CA 证书"
echo "📄 证书路径：$CERT_FILE"
echo "🔑 私钥路径：$KEY_FILE"
