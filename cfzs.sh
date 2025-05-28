#!/bin/bash

CERT_DIR="/root/catmi"
CERT_FILE="${CERT_DIR}/server.crt"
KEY_FILE="${CERT_DIR}/server.key"

# 创建目录
mkdir -p "$CERT_DIR"

# 提示输入证书
echo "📄 请粘贴你的证书内容（以 -----BEGIN CERTIFICATE----- 开头），输入完后按 Ctrl+D："
CERT_CONTENT=$(</dev/stdin)

# 检查输入为空
if [[ -z "$CERT_CONTENT" ]]; then
  echo "❌ 证书内容不能为空！"
  exit 1
fi

# 保存证书
echo "$CERT_CONTENT" > "$CERT_FILE"
echo "✅ 证书已保存到 $CERT_FILE"

# 提示输入私钥
echo "🔑 请粘贴你的私钥内容（以 -----BEGIN PRIVATE KEY----- 或 RSA 开头），输入完后按 Ctrl+D："
KEY_CONTENT=$(</dev/stdin)

# 检查输入为空
if [[ -z "$KEY_CONTENT" ]]; then
  echo "❌ 私钥内容不能为空！"
  exit 1
fi

# 保存私钥
echo "$KEY_CONTENT" > "$KEY_FILE"
echo "✅ 私钥已保存到 $KEY_FILE"

# 设置权限
chmod 600 "$CERT_FILE" "$KEY_FILE"
echo "🔐 权限已设置为 600"

echo "✅ 所有操作完成！"
