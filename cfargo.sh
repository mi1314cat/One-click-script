#!/bin/bash

# 设置下载目标目录（默认是当前目录）
TARGET_DIR="./cloudflared"
mkdir -p "$TARGET_DIR"

# 检测系统类型
OS=$(uname | tr '[:upper:]' '[:lower:]')

if [ "$OS" = "linux" ]; then
  if grep -iq "alpine" /etc/os-release 2>/dev/null; then
    DISTRO="alpine"
  elif grep -iq "debian" /etc/os-release 2>/dev/null; then
    DISTRO="debian"
  else
    DISTRO="linux"
  fi
elif [ "$OS" = "freebsd" ]; then
  DISTRO="freebsd"
else
  echo "Unsupported operating system: $OS"
  exit 1
fi

# 检测系统架构
ARCH=$(uname -m)

case "$ARCH" in
  x86_64)
    ARCH="amd64"
    ;;
  aarch64 | arm64)
    ARCH="arm64"
    ;;
  armv7l | armv6l)
    ARCH="arm"
    ;;
  *)
    echo "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

# 拼接下载 URL
BASE_URL="https://github.com/cloudflare/cloudflared/releases/latest/download"
FILENAME="cloudflared-${DISTRO}-${ARCH}"
URL="${BASE_URL}/${FILENAME}"

# 下载文件
echo "Downloading cloudflared for $DISTRO ($ARCH) from $URL ..."
curl -L -o "$TARGET_DIR/cloudflared" "$URL"

# 检查下载是否成功
if [[ $? -ne 0 ]]; then
  echo "Failed to download cloudflared."
  exit 1
fi

# 添加执行权限
chmod +x "$TARGET_DIR/cloudflared"

# 打印成功信息
echo "Cloudflared downloaded and saved to $TARGET_DIR/cloudflared"
echo "Run './cloudflared --version' to check the version."
