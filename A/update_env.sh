update_env() {
    local env_file="$1"
    local key="$2"
    local value="$3"

    # 参数检查
    [[ -n "$env_file" ]] || { echo "错误：未指定 env 文件"; return 1; }
    [[ -n "$key" ]]      || { echo "错误：未指定 key"; return 1; }

    # 校验 key
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        echo "Invalid key: $key"
        return 1
    }

    # 确保目录 & 文件
    mkdir -p "$(dirname "$env_file")"
    [ -f "$env_file" ] || touch "$env_file"

    # 获取权限 & 属主（兼容 Linux / BSD）
    local mode owner group
    if mode=$(stat -c "%a" "$env_file" 2>/dev/null); then
        owner=$(stat -c "%u" "$env_file")
        group=$(stat -c "%g" "$env_file")
    else
        mode=$(stat -f "%Lp" "$env_file")
        owner=$(stat -f "%u" "$env_file")
        group=$(stat -f "%g" "$env_file")
    fi

    # 转义 value
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\$}"

    # 加锁 + 自动释放
    (
        flock 200

        local tmp_file
        tmp_file=$(mktemp "$(dirname "$env_file")/.env.tmp.XXXXXX")

        # 设置权限
        chmod "$mode" "$tmp_file"
        chown "$owner":"$group" "$tmp_file" 2>/dev/null || true

        # 精确删除旧 key
        awk -v k="$key" 'index($0, k"=") != 1' "$env_file" > "$tmp_file"

        # 写入新值
        printf '%s="%s"\n' "$key" "$value" >> "$tmp_file"

        # 原子替换
        mv "$tmp_file" "$env_file"

    ) 200>"$env_file.lock"
}
