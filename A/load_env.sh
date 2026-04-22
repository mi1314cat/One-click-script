load_env() {
    local env_file="$1"

    # 必须传入 env 文件
    if [[ -z "$env_file" ]]; then
        echo "错误：必须传入 env 文件路径"
        return 1
    fi

    # 1. 检查文件是否存在
    if [ ! -f "$env_file" ]; then
        echo "错误：env 文件不存在 -> $env_file"
        return 1
    fi

    # 2. 逐行读取
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"

        [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" != *=* ]]; then
            echo "警告：跳过无效行（缺少 '='）：$line"
            continue
        fi

        key="${line%%=*}"
        value="${line#*=}"

        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "错误：非法的变量名 -> $key"
            return 1
        fi

        if [[ ! "$value" =~ ^\".*\"$ ]]; then
            echo "错误：变量 $key 的值必须包含在双引号内 -> $value"
            return 1
        fi

        value="${value:1:-1}"

        value="${value//\\\\/\\}"
        value="${value//\\\"/\"}"
        value="${value//\\\$/\$}"

        printf -v "$key" '%s' "$value"
        export "$key"

    done < "$env_file"

    echo "成功：已安全加载环境配置文件 $env_file"
}
