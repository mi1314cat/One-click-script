CERT_DIR="/root/catmi"
CERT_PATH="${CERT_DIR}/server.crt"
KEY_PATH="${CERT_DIR}/server.key"

# 创建目录
mkdir -p "$CERT_DIR"



# 输入证书内容
echo "📄 请粘贴你的证书内容（以 -----BEGIN CERTIFICATE----- 开头），输入完后按 Ctrl+D："
CERT_CONTENT=$(</dev/stdin)

# 检查输入为空
if [[ -z "$CERT_CONTENT" ]]; then
  echo "❌ 证书内容不能为空！"
  exit 1
fi

# 保存证书
echo "$CERT_CONTENT" > "$CERT_PATH"
echo "✅ 证书已保存到 $CERT_PATH"

# 输入私钥内容
echo "🔑 请粘贴你的私钥内容（以 -----BEGIN PRIVATE KEY----- 或 RSA 开头），输入完后按 Ctrl+D："
KEY_CONTENT=$(</dev/stdin)

# 检查输入为空
if [[ -z "$KEY_CONTENT" ]]; then
  echo "❌ 私钥内容不能为空！"
  exit 1
fi

# 保存私钥
echo "$KEY_CONTENT" > "$KEY_PATH"
echo "✅ 私钥已保存到 $KEY_PATH"

# 设置权限
chmod 644 "$CERT_PATH" "$KEY_PATH"
echo "🔐 权限已设置为 644"

echo "🎉 所有操作完成！"
