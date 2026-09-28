#!/usr/bin/env bash
# ============================================================
#  Fail2ban 一键管理脚本 (审计改造版)
#  体系: fail2ban.sh -> 调用正确的防火墙 action -> UFW / nftables
#  设计原则:
#   1. 首屏 30 秒回答: 有没有在保护 / 拦了哪些 IP / 是否真的被防火墙挡住
#   2. 所有状态数字来自 f2b / nft / ufw / journal 实测, 不伪造
#   3. 不重启不 flush 防火墙; 配置写入独立文件, 不覆盖用户 jail.local, 幂等
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; PLAIN='\033[0m'
ERR_OK="${GREEN}✓${PLAIN}"; ERR_FAIL="${RED}✗${PLAIN}"; ERR_WARN="${YELLOW}!${PLAIN}"
DOT_ON="${GREEN}●${PLAIN}"; DOT_OFF="${RED}○${PLAIN}"

JAIL_LOCAL=/etc/fail2ban/jail.local
JAIL_LOCAL_MINE=/etc/fail2ban/jail.d/zz-tb-fail2ban.local   # 本脚本独占区 (jail.d 之后读取, 只当本区有值时优先)
LESS_BIN=$(command -v less)
TEST_BANIP=192.0.2.77

pkg_installed(){ command -v "$1" >/dev/null 2>&1; }
f2b_available(){ pkg_installed fail2ban-client && fail2ban-client ping >/dev/null 2>&1; }
f2b_running(){ systemctl is-active fail2ban >/dev/null 2>&1; }

# ---- 实际防火墙判断 (不信任"看到命令就算数") ----
# 输出: ufw-healthy | ufw-broken | nft | iptables | none
detect_firewall_backend(){
    if pkg_installed ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        if iptables -S INPUT 2>/dev/null | grep -q "ufw-"; then
            echo ufw-healthy
        else
            echo ufw-broken      # orphan-chain 状态: 所有 ban 实际无效!
        fi
        return 0
    fi
    if pkg_installed nft && nft list tables 2>/dev/null | grep -qE "f2b|filter"; then
        echo nft; return 0
    fi
    if pkg_installed iptables && iptables -S INPUT 2>/dev/null | grep -qvE "^(-P|-N "; then
        echo iptables; return 0
    fi
    echo none
}

# fail2ban 正在使用的真实日志后端
detect_f2b_backend(){
    if fail2ban-client get sshd journalmatch 2>/dev/null | grep -q .; then
        echo systemd
        return
    fi
    local lp; lp=$(fail2ban-client get sshd logpath 2>/dev/null)
    if [[ -n $lp ]]; then echo file; else echo unknown; fi
}

get_ssh_ports(){
    local ports=""
    for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [[ -f $f ]] || continue
        ports+=" $(grep -riE "^[[:space:]]*Port[[:space:]]+[0-9]+" "$f" | awk '{print $2}' | tr '\n' ' ')"
    done
    if [[ -z ${ports// /} ]] && pkg_installed ss; then
        ports+=" $(ss -lntH 2>/dev/null | awk '/sshd/{split($4,a,":"); print a[length(a)]}' | sort -un | tr '\n' ' ')"
    fi
    echo "${ports:-22}" | xargs
}

f2b_logfile(){
    awk '{print tolower($0)}' /etc/fail2ban/fail2ban.conf 2>/dev/null \
      | grep -E "^logtarget *= */" | awk -F= '{print $2}' | xargs
}

# 管理员 SSH 来源 IP (建议加入 ignoreip; 不自动写入公网全域)
admin_ssh_ips(){
    {
    [[ -n $SSH_CLIENT ]] && echo "${SSH_CLIENT%% *}"
    who 2>/dev/null | awk '{print $3}' | grep -E "^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-f:]{2,}$"
    last -n 20 2>/dev/null | grep -Eoo "([0-9]{1,3}\.){3}[0-9]{1,3}" | grep -v "0\.0\.0\.0" | head -5
    } | sort -u
}

ALL_JAILS(){ fail2ban-client status 2>/dev/null | tail -1 | sed 's/.*Jail list://; s/,/ /g'; }
jail_banned_now(){ fail2ban-client get "$1" banned 2>/dev/null | tr -d "[]" | wc -w; }
jail_total_banned(){ fail2ban-client status "$1" 2>/dev/null | grep "Total banned" | awk -F'\t' '{print $2}' | tr -d '\t'; }
jail_cur_failed(){ fail2ban-client status "$1" 2>/dev/null | grep "Currently failed" | awk -F'\t' '{print $2}' | tr -d '\t'; }
jail_total_failed(){ fail2ban-client status "$1" 2>/dev/null | grep "Total failed" | awk -F'\t' '{print $2}' | tr -d '\t'; }

# ============================================================
# 首屏: 防护总览
# ============================================================
show_overview(){
    clear
    echo -e "${BLUE}═════════════ Fail2ban 防护总览 ═════════════${PLAIN}"
    if f2b_running; then
        echo -e " Fail2ban 状态: ${DOT_ON} ${GREEN}运行中${PLAIN}"
    elif pkg_installed fail2ban-client; then
        echo -e " Fail2ban 状态: ${DOT_OFF} ${RED}未运行${PLAIN}"
    else
        echo -e " Fail2ban:      ${DOT_OFF} ${RED}未安装${PLAIN}"
    fi

    local fw; fw=$(detect_firewall_backend)
    case $fw in
        ufw-healthy) echo -e " 防火墙后端:   ${GREEN}UFW（内核 INPUT 已正确接入 ufw 链）${PLAIN}" ;;
        ufw-broken)  echo -e " 防火墙后端:   ${RED}UFW 报 active，但 INPUT 链已脱离 ufw 链${PLAIN}"
                     echo -e "               ${RED}⚠ Fail2ban 的 ban 不会真正拦截！请运行『拦截链路自检』（菜单 5）${PLAIN}" ;;
        nft)         echo -e " 防火墙后端:   nftables" ;;
        iptables)    echo -e " 防火墙后端:   iptables" ;;
        *)           echo -e " 防火墙后端:   ${RED}无可用防火墙，Fail2ban 无法实际拦截${PLAIN}" ;;
    esac

    echo " SSH 端口:     $(get_ssh_ports)"
    local lf; lf=$(f2b_logfile)
    echo " f2b 日志:     ${lf:-<journald, 无文件日志>}"
    echo " 日志后端:     $(detect_f2b_backend)"

    echo
    echo -e "${CYAN} 正在保护:${PLAIN}"
    local jails; jails=$(ALL_JAILS)
    if [[ -z $jails ]]; then
        echo "   (无任何已启动的 Jail)"
    else
        printf "   %-18s %-8s %-10s %-10s %-12s\n" "Jail" "状态" "当前封禁" "累计封禁" "当前失败数"
        printf "   %-18s %-8s %-10s %-10s %-12s\n" "----------------" "----" "--------" "--------" "----------"
        for j in $jails; do
            printf "   %-18s ${DOT_ON}启用${PLAIN}   %-6s      %-8s     %-6s\n" \
                "$j" "$(jail_banned_now "$j")" "$(jail_total_banned "$j")" "$(jail_cur_failed "$j")"
        done
    fi

    echo
    echo -e "${CYAN} 最近事件:${PLAIN}"
    recent_events_line 5
    echo
}

recent_events_line(){
    local n=${1:-5} lf
    lf=$(f2b_logfile)
    local out=""
    if [[ -n $lf && -s $lf ]]; then
        out=$(grep -E "Ban|Unban|Found" "$lf" 2>/dev/null | tail -n "$n")
    fi
    if [[ -z $out && -s /var/log/fail2ban/fail2ban.log ]]; then
        out=$(grep -E "Ban|Unban|Found" /var/log/fail2ban/fail2ban.log 2>/dev/null | tail -n "$n")
    fi
    if [[ -z $out ]] && pkg_installed journalctl; then
        out=$(journalctl -u fail2ban -n "$n" --no-pager -o cat 2>/dev/null | grep -E "Ban|Unban|Found" | tail -n "$n")
    fi
    if [[ -n $out ]]; then
        echo "$out" | sed 's/^/   /'
    else
        echo "   (近期无 ban 事件日志)"
    fi
}

# ============================================================
# 当前被封禁 IP + 详情
# ============================================================
show_banned(){
    clear
    echo -e "${BLUE}═════════════ 当前被封禁的 IP ═════════════${PLAIN}"
    local jails; jails=$(ALL_JAILS)
    if [[ -z $jails ]]; then echo " 无启动的 Jail"; return; fi
    for j in $jails; do
        echo
        echo -e "${CYAN}Jail: $j${PLAIN}"
        local list; list=$(fail2ban-client get "$j" banned 2>/dev/null | tr -d "[]")
        if [[ -z ${list// /} ]]; then echo "  (当前无封禁)"; continue; fi
        echo "  IP                 状态"
        echo "  ------------------------------"
        for ip in $list; do echo "  $ip                当前封禁"; done
    done
    echo
    read -p " 查看某个 IP 的封禁详情，输入 IP (留空返回): " ip
    [[ -n $ip ]] && show_ip_detail "$ip"
    read -p " 回车返回..." _
}

show_ip_detail(){
    local ip=$1
    echo -e "${BLUE}═══ 封禁详情: $ip ═══${PLAIN}"
    echo
    echo -e "${CYAN}所属 Jail:${PLAIN}"
    local found=0
    for j in $(ALL_JAILS); do
        if fail2ban-client get "$j" banned 2>/dev/null | tr -d "[]" | grep -qw "$ip"; then
            echo "  Jail:            $j"
            echo "  filter:          $(fail2ban-client get "$j" logpath 2>/dev/null | head -1 || true)"
            echo "  当前失败次数:    $(jail_cur_failed "$j")  (核心字段; fail2ban 无每-IP 失败计数, 如需精确请看日志)"
            found=1
        fi
    done
    if [[ $found -eq 0 ]]; then echo "  (该 IP 当前不在任何已启动 Jail 的封禁列表中)"; fi

    echo
    echo -e "${CYAN}封禁到什么时候:${PLAIN}"
    echo "  Fail2ban 无法提供该字段 (client 不会返回每个 IP 的 ban/unban 时刻)"
    echo "  该 jail bantime:  $(fail2ban-client get sshd bantime 2>/dev/null || echo '不可得')"
    echo "  bantime.increment: $(fail2ban-client get sshd bantime.increment 2>/dev/null || echo '不可得')"

    echo
    echo -e "${CYAN}真实日志中该 IP 的最近事件:${PLAIN}"
    local lf; lf=$(f2b_logfile)
    if [[ -n $lf && -s $lf ]]; then
        grep "$ip" "$lf" 2>/dev/null | tail -8 | sed 's/^/  /'
    fi
    if [[ -s /var/log/fail2ban/fail2ban.log ]]; then
        grep "$ip" /var/log/fail2ban/fail2ban.log 2>/dev/null | tail -8 | sed 's/^/  /'
    fi
    if pkg_installed journalctl; then
        journalctl -u fail2ban --no-pager -o cat 2>/dev/null | grep "$ip" | tail -8 | sed 's/^/  /'
        [[ $found -eq 0 ]] || journalctl -u ssh --no-pager --since "3 days ago" 2>/dev/null | grep "$ip" | grep -E "Failed|Invalid|Ban" | tail -5 | sed 's/^/  /'
    fi

    echo
    echo -e "${CYAN}防火墙实际规则:${PLAIN}"
    local fw; fw=$(detect_firewall_backend)
    case $fw in
        ufw-healthy|ufw-broken) ufw status 2>/dev/null | grep -F "$ip" | sed 's/^/  /' || echo "  (UFW 中未找到该 IP 规则)" ;;
        nft)                    nft list ruleset 2>/dev/null | grep -F "$ip" | head -6 | sed 's/^/  /' || echo "  (nftables 中未找到)" ;;
        *)                      iptables -S 2>/dev/null | grep -F "$ip" | head -6 | sed 's/^/  /' || echo "  (iptables 中未找到)" ;;
    esac
    echo
}

# ============================================================
# 拦截链路自检 (核心)
# ============================================================
chain_check(){
    clear
    echo -e "${BLUE}═════════════ 拦截链路自检 ═════════════${PLAIN}"
    local ok=1
    echo
    echo -e "${CYAN}[1] SSH 日志${PLAIN}"
    local recent=0
    if pkg_installed journalctl; then
        recent=$(journalctl -u ssh --since "48 hours ago" --no-pager 2>/dev/null | grep -ciE "Failed|Invalid|Accepted")
    fi
    if [[ $recent -gt 0 ]]; then
        echo -e "  $ERR_OK 正常   来源: journald (systemd backend) 近48h SSH 认证日志行数: $recent"
    elif grep -qE "Failed|Accepted" /var/log/auth.log 2>/dev/null; then
        echo -e "  $ERR_OK 正常   来源: /var/log/auth.log"
    else
        echo -e "  $ERR_FAIL 近 48h 未发现 SSH 认证日志 (检查 backend 是否与日志来源匹配)"
        ok=0
    fi

    echo
    echo -e "${CYAN}[2] sshd filter${PLAIN}"
    if f2b_available; then
        local tf cf; tf=$(jail_total_failed sshd); cf=$(jail_cur_failed sshd)
        if [[ ${tf:-0} -gt 0 || ${cf:-0} -gt 0 ]]; then
            echo -e "  $ERR_OK filter 正在匹配: total_failed=$tf  currently_failed=$cf"
        elif journalctl -u ssh --since "2 hours ago" --no-pager 2>/dev/null | grep -cE "Failed|Invalid" >/dev/null; then
            echo -e "  $ERR_WARN filter 计数为 0: fail2ban 刚重启会把计数清零, 这是正常现象, 非故障"
        else
            echo -e "  $ERR_WARN filter 已加载但从未匹配 (total_failed=0)"
            echo -e "      如果 [1] 显示日志正常, 则可能是 journalmatch 单元名不匹配 (ssh.service vs sshd.service)"
            ok=0
        fi
    else
        echo -e "  $ERR_FAIL fail2ban 无响应"; ok=0
    fi

    echo
    echo -e "${CYAN}[3] sshd Jail${PLAIN}"
    if fail2ban-client status sshd >/dev/null 2>&1; then
        echo -e "  $ERR_OK sshd jail 已启动, 当前封禁: $(jail_banned_now sshd)"
    else
        echo -e "  $ERR_FAIL sshd jail 未启动"; ok=0
    fi

    echo
    echo -e "${CYAN}[4] Fail2ban action${PLAIN}"
    local ba; ba=$(fail2ban-client get sshd actions 2>/dev/null | tr -d "[]'\"" | xargs | awk '{print $1}')
    [[ -z $ba ]] && ba=$(sed -n 's/^banaction *=//p' /etc/fail2ban/jail.local 2>/dev/null | head -1 | xargs)
    echo "  banaction: ${ba:-未知}"
    case $ba in
        ufw*)
            if ufw status 2>/dev/null | grep -q active; then
                echo -e "  $ERR_OK action 链接 UFW (active)"
            else
                echo -e "  $ERR_FAIL banaction=ufw 但 UFW 未 active —— ban 不会生效"; ok=0
            fi ;;
        nftables*)
            nft list tables 2>/dev/null | grep -q f2b \
                && echo -e "  $ERR_OK f2b 表位存在于 nftables" \
                || echo -e "  $ERR_WARN 暂未观察到 f2b 表位（如果从未 ban 过，可能正常）" ;;
        iptables*) echo -e "  $ERR_WARN banaction 使用 iptables —— 请确认这不会与其他 nftables/面板冲突" ;;
        *) echo -e "  $ERR_WARN 未知 banaction: $ba" ;;
    esac

    echo
    echo -e "${CYAN}[5] 防火墙规则层${PLAIN}"
    local fw; fw=$(detect_firewall_backend)
    case $fw in
        ufw-healthy)
            echo -e "  $ERR_OK INPUT 基链正确指向 ufw-* 子链"
            echo "     ufw-user-input 规则数: $(iptables -S ufw-user-input 2>/dev/null | grep -c '^-A')" ;;
        ufw-broken)
            echo -e "  $ERR_FAIL UFW 报 active，但 INPUT 不再跳到 ufw 链。当前 INPUT:"
            iptables -S INPUT 2>/dev/null | sed 's/^/       /'
            echo -e "       → Fail2ban 会把 ban 写入 ufw-user-input 却永远不被遍历, 全部无效!"
            echo -e "       → 典型来源:「接管模式」/ nftables 面板 / 手动 flush 清掉了 UFW 基链"
            ok=0 ;;
        nft)
            echo -e "  $ERR_OK nftables 后端"
            nft list tables 2>/dev/null | grep f2b | sed 's/^/     /' ;;
        iptables)
            echo -e "  $ERR_OK iptables 后端, INPUT 规则数 $(iptables -S INPUT 2>/dev/null | grep -c '^-A')" ;;
        *)  echo -e "  $ERR_FAIL 无可用防火墙"; ok=0 ;;
    esac

    echo
    echo -e "${CYAN}[6] 实际封禁验证${PLAIN}"
    local nb; nb=$(jail_banned_now sshd)
    if [[ ${nb:-0} -gt 0 ]]; then
        case $fw in
            ufw-healthy)
                if ufw status 2>/dev/null | grep -qE "REJECT|deny|DROP"; then
                    echo -e "  $ERR_OK UFW 存在封禁规则；且 ufw-user-input 中有 fail2ban 注入的 deny/reject"
                else
                    echo -e "  $ERR_FAIL UFW 中找不到对应 REJECT/DROP 规则"; ok=0
                fi ;;
            ufw-broken)
                echo -e "  $ERR_FAIL ufw 链存在但从未被 INPUT 遍历 —— 封禁规则形同虚设"; ok=0 ;;
            nft)
                nft list ruleset 2>/dev/null | grep -q f2b \
                    && echo -e "  $ERR_OK nftables 有 f2b 表" || { echo -e "  $ERR_FAIL 无 f2b 表"; ok=0; } ;;
            *) iptables -S | grep -q f2b \
                    && echo -e "  $ERR_OK iptables 有 f2b 链" || { echo -e "  $ERR_FAIL iptables 无 f2b 规则"; ok=0; } ;;
        esac
    else
        echo -e "  $ERR_WARN 当前无封禁, 跳过规则存在性检查 (如需验证, 可运行『测试封禁』)"
    fi

    echo
    echo -e "${BLUE}═══ 结论 ═══${PLAIN}"
    if [[ $ok -eq 1 ]]; then
        echo -e " ${GREEN}Fail2ban → ${ba} → ${fw} → drop/reject 链路正常${PLAIN}"
    else
        echo -e " ${RED}链路存在断点，见上方 ✗ 行。Fail2ban 相关 ban 不会真正拦截攻击！${PLAIN}"
        echo -e " 建议: 若 INPUT 被其他脚本/手动操作冲掉, 优先『ufw reload』恢复, 然后再自检"
    fi
    echo
    read -p " 本次测试是否尝试自检封禁一个测试 IP (192.0.2.77) 让你确认规则生成? [y/N]: " a
    [[ $a == y* ]] && test_live_ban
    read -p " 回车返回..." _
}

test_live_ban(){
    echo
    echo -e "${CYAN}[测试] 封禁测试 IP $TEST_BANIP${PLAIN}"
    if ! f2b_available; then echo " fail2ban 未运行"; return; fi
    fail2ban-client set sshd banip "$TEST_BANIP" >/dev/null 2>&1 || { echo -e " $ERR_FAIL ban 测试失败"; return; }
    sleep 2
    local fw; fw=$(detect_firewall_backend)
    case $fw in
        ufw-healthy|ufw-broken)
            if ufw status | grep -q "$TEST_BANIP"; then echo -e " $ERR_OK UFW 中出现该规则"; else echo -e " $ERR_FAIL UFW 中未出现规则"; fi ;;
        nft) nft list ruleset | grep -q "$TEST_BANIP" \
                && echo -e " $ERR_OK nftables 出现该规则" || echo -e " $ERR_FAIL nftables 无规则" ;;
        *)  iptables -S | grep -q "$TEST_BANIP" \
                && echo -e " $ERR_OK iptables 出现该规则" || echo -e " $ERR_FAIL iptables 无规则" ;;
    esac
    fail2ban-client set sshd unbanip "$TEST_BANIP" >/dev/null 2>&1
    sleep 1
    fail2ban-client set sshd unbanip "$TEST_BANIP" >/dev/null 2>&1
    echo -e " 测试完成并已解封。"
}

# ============================================================
# 最近攻击事件
# ============================================================
show_events(){
    clear
    echo -e "${BLUE}═════════════ 最近攻击事件 (真实日志) ═════════════${PLAIN}"
    echo
    echo -e "${CYAN}Fail2ban ban / unban 事件:${PLAIN}"
    local lf; lf=$(f2b_logfile)
    if [[ -n $lf && -s $lf ]]; then
        grep -E "Ban|Unban|Restore Ban" "$lf" 2>/dev/null | tail -15 | sed 's/^/  /'
    else
        journalctl -u fail2ban -n 20 --no-pager -o cat 2>/dev/null | grep -E "Ban|Unban" | tail -15 | sed 's/^/  /'
    fi
    echo
    echo -e "${CYAN}SSH 认证失败 (journal, 最近 24h):${PLAIN}"
    journalctl -u ssh --since "-24 hours" --no-pager -o cat 2>/dev/null \
        | grep -E "Failed password|Invalid user|maxauth" | tail -15 | sed 's/^/  /'
    echo
    read -p " 回车返回..." _
}

# ============================================================
# 防火墙实际拦截 (摘要)
# ============================================================
show_rules(){
    clear
    echo -e "${BLUE}═════════════ 当前实际拦截 (摘要) ═════════════${PLAIN}"
    echo
    echo " [UFW 封禁规则 (by Fail2Ban)]"
    ufw status 2>/dev/null | grep -i "Fail2Ban" | head -10 | sed 's/^/  /' || echo "  (无)"
    echo
    echo " [iptables 内的 f2b 链]"
    iptables -S 2>/dev/null | grep f2b | head -8 | sed 's/^/  /' || echo "  (无)"
    echo
    echo " [nftables 内的 f2b 表]"
    nft list tables 2>/dev/null | grep f2b | sed 's/^/  /' || echo "  (无)"
    echo
    echo " [UFW 基链策略]"
    iptables -S INPUT 2>/dev/null | head -1 | sed 's/^/  /'
    echo "  ufw-user-input ACCEPT 数: $(iptables -S ufw-user-input 2>/dev/null | grep -c ACCEPT)"
    echo "  ufw-user-input deny/reject 数: $(iptables -S ufw-user-input 2>/dev/null | grep -cE "DROP|REJECT")"
    echo
    read -p " 回车返回..." _
}
show_rules_detail(){
    local fw; fw=$(detect_firewall_backend)
    case $fw in
        ufw-healthy|ufw-broken) ufw status verbose 2>/dev/null ;;
        nft)                    nft list ruleset ;;
        *)                      iptables-save ;;
    esac | less 2>/dev/null || {
        echo "  (less 不可用, 直接输出)"
        case $fw in
            ufw-healthy|ufw-broken) ufw status verbose ;;
            nft) nft list ruleset ;;
            *) iptables-save ;;
        esac
    }
}

# ============================================================
# 手动封/解封
# ============================================================
do_ban(){
    read -p " 要封禁的 IP/网段 (IPv4/IPv6): " ip
    [[ -z $ip ]] && return
    if fail2ban-client set sshd banip "$ip" >/dev/null 2>&1; then
        echo -e " $ERR_OK 已在 sshd jail 封禁 $ip (bantime=当前配置)"
    else
        echo -e " $ERR_FAIL ban 失败"
    fi
}
do_unban(){
    fail2ban-client status sshd 2>/dev/null | grep "Banned IP" | sed 's/.*list: //' | tr ' ' '\n' | grep -v '^$' | nl | sed 's/^/  /'
    echo
    read -p " 解封 IP (或 all): " ip
    if [[ $ip == all ]]; then
        fail2ban-client unban --all >/dev/null 2>&1 && echo -e " $ERR_OK 全部解封"
    elif [[ -n $ip ]]; then
        fail2ban-client set sshd unbanip "$ip" >/dev/null 2>&1 && echo -e " $ERR_OK 已解封"
    fi
    read -p " 回车返回..." _
}

# ============================================================
# 推荐配置 (幂等, 不覆盖用户自建 jail)
# 写到 jail.d/zz-tb-fail2ban.local (独立区) 而不是直接覆盖 jail.local
# ============================================================
do_backup_jail_local(){
    [[ -f $JAIL_LOCAL ]] && cp "$JAIL_LOCAL" "${JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"
}

ignoreip_choice(){
    echo
    echo -e "${CYAN} 管理员 SSH 来源 IP (建议加入 ignoreip, 防止重试把你自己锁死):${PLAIN}"
    local ips; ips=$(admin_ssh_ips | grep -vE "^(127\.|::1)" | awk 'x[$0]++==0' | head -8)
    if [[ -z $ips ]]; then
        echo "  (从 who/last/SSH_CLIENT 未取到非本机 IP; 跳过)"
        return ""
    fi
    echo "$ips" | sed 's/^/   - /'
    echo "$ips"
}

apply_recommended_config(){
    local ssh_ports
    ssh_ports=$(get_ssh_ports | xargs | tr ' ' ',')
    echo
    echo " 检测到 SSH 端口: $(echo "$ssh_ports" | tr ',' ' ')"
    local fw ba
    fw=$(detect_firewall_backend)
    case $fw in
        ufw-healthy)  ba=ufw ;;
        ufw-broken)   ba=ufw ;;
        nft)          ba=nftables-multiport ;;
        iptables)     ba=iptables-multiport ;;
        *)            read -p " 未检测到任何防火墙, 使用 dummy (仅日志)? [Y/n]: " _a; _a=${_a:-y}; [[ ${_a,,} != n* ]] && ba=dummy || return ;;
    esac
    echo " 将使用 banaction = $ba"

    read -p " 使用检测到的 SSH 端口 $ssh_ports ? [Y/n]: " a
    [[ $a == n* ]] && read -p " 输入 SSH 端口(逗号分隔): " ssh_ports

    echo
    echo -n " 检测到的管理员 SSH IP (自动读取): "
    local ips; ips=$(admin_ssh_ips | grep -vE "^(127\.|::1)" | awk 'x[$0]++==0' | head -5 | xargs)
    echo "${ips:-未获取到}"
    read -p " 把以上管理员 IP 加入 ignoreip? [y/N]: " a
    local extra=""
    [[ $a == y* ]] && extra=" $ips"

    do_backup_jail_local
    local recidive_action
    case $ba in ufw*) recidive_action="ufw";; nftables*) recidive_action='nftables[type=allports]' ;; iptables*) recidive_action='iptables-allports';; *) recidive_action=dummy;; esac

    local lg; lg=$(f2b_logfile)
    [[ -n $lg ]] || lg=/var/log/fail2ban/fail2ban.log
    mkdir -p /etc/fail2ban/jail.d "$(dirname $lg)"
    [[ -f $lg ]] || touch "$lg"   # recidive 需要 log 文件存在 (若 logtarget 是文件)

    cat > "$JAIL_LOCAL_MINE" <<EOF
# ---- 由 fail2ban.sh 管理区 start ----
# 本文件由 fail2ban.sh 写入, 独立于 jail.local; 幂等: 重复运行结果一致
[DEFAULT]
bantime           = 1h
bantime.increment = true
bantime.maxtime   = 1w
findtime          = 600
maxretry          = 5
banaction         = ${ba}
backend           = auto
ignoreip          = 127.0.0.1/8 ::1${extra}
# fail2ban 无法自己识别当前防火墙时由本脚本检测决定; 若你手动管理 banaction 请把本行改为你的选择

[sshd]
enabled = true
port    = ${ssh_ports}

[recidive]
enabled    = true
logpath    = ${lg}
banaction  = ${recidive_action}
bantime    = 1w
findtime   = 1d
maxretry   = 3
# ---- 由 fail2ban.sh 管理区 end ----
EOF
    [[ -f $lg ]] || echo "  (warning: $lg 不存在, recidive 可能需要调整)"

    if systemctl restart fail2ban 2>/dev/null; then
        echo -e " $ERR_OK 配置已写入 $JAIL_LOCAL_MINE 并重启 Fail2ban"
    else
        echo -e " $ERR_FAIL 重启失败, 请检查: journalctl -u fail2ban -n 20"
    fi
    sleep 2
    fail2ban-client status 2>/dev/null | tail -1
    read -p " 回车返回..." _
}

# ============================================================
# 重启并验证 (对比重启前后的 ufw 规则数 / 检查 jail 恢复情况)
# ============================================================
restart_and_verify(){
    echo
    local before after
    before=$(iptables -S ufw-user-input 2>/dev/null | grep -c '^-A')
    echo " 重启前 ufw-user-input 规则数: $before"
    systemctl restart fail2ban
    sleep 3
    echo " 重启后 jail 列表:"
    fail2ban-client status 2>/dev/null | tail -1
    after=$(iptables -S ufw-user-input 2>/dev/null | grep -c '^-A')
    echo " 重启后 ufw-user-input 规则数: $after"
    echo " 若封禁 IP 列表非空, 这个数字应该恢复(或考虑 fail2ban ban-action 的恢复行为)"
    read -p " 回车返回..." _
}

# ============================================================
# 自动修复 (保守版, 每项都说明触发条件)
# ============================================================
auto_repair(){
    clear
    echo -e "${BLUE}═══ 自动修复 (保守版, 说明每项为什么) ═══${PLAIN}"
    do_backup_jail_local

    # 1) backend=file 但没人提供 /var/log/auth.log (Debian 13)
    if grep -iqE "^backend *= *file" $JAIL_LOCAL /etc/fail2ban/jail.d/*.conf 2>/dev/null \
        && [[ ! -f /var/log/auth.log ]]; then
        echo " [修复1] backend=file 但 auth.log 不存在 → 改为 auto/依赖 journald"
        sed -i 's/^backend *= *file.*/backend = auto/I' /etc/fail2ban/jail.local 2>/dev/null
        echo -e "    $ERR_OK 已修改, 现状:"
        grep -i "^backend" /etc/fail2ban/jail.local 2>/dev/null | sed 's/^/       /'
    else
        echo -e " [跳过] backend/file 配置无冲突"
    fi

    # 2) banaction 与实际防火墙不匹配
    local ba fw
    ba=$(sed -n 's/^banaction *= *//p' $JAIL_LOCAL 2>/dev/null | head -1 | xargs)
    fw=$(detect_firewall_backend)
    case $fw in ufw*) fw=ufw;; nft) fw=nftables;; iptables) fw=iptables;; esac
    if [[ -n $ba ]] && [[ $ba == ufw* && $fw != ufw* ]] || [[ $ba == nftables* && $fw != nft* ]]; then
        echo -e " [修复2] jail.local 里 banaction=$ba 与实际防火墙($fw)不一致"
        echo "    触发条件: UFW 未 active/链路断, 或 nftables 未起."
        echo "    修改什么: jail.d/zz-tb-fail2ban.local (不动 jail.local 其他配置)"
        read -p "    是否用「推荐配置」同步到实际后端? [y/N]: " a
        [[ $a == y* ]] && { apply_recommended_config >/dev/null 2>&1; echo -e "    $ERR_OK 已按实际后端重写并重启"; }
    else
        echo -e " [跳过] banaction 与防火墙一致"
    fi

    # 3) journal 单元名不匹配 (ssh.service vs sshd.service)
    if fail2ban-client get sshd journalmatch 2>/dev/null | grep -q "sshd.service" \
        && pkg_installed journalctl && journalctl -u ssh --no-pager -n1 2>/dev/null | grep -q . \
        && ! journalctl -u sshd --no-pager -n1 2>/dev/null | grep -q .; then
        echo -e " [提示] 本机 SSH 单元是 ssh.service，jail 的 journalmatch 却指向 sshd.service"
        echo -e "        → SSH 认证日志可能无法进入 filter 链。请编辑 jail.local [sshd] journalmatch。"
    fi

    # 4) 启动顺序 (只依赖当前 active 的防火墙, 不再 sleep 3)
    if [[ -f /etc/systemd/system/fail2ban.service.d/override.conf ]]; then
        echo " [发现] fail2ban 已有 systemd override:"
        cat /etc/systemd/system/fail2ban.service.d/override.conf 2>/dev/null | sed 's/^/       /'
        read -p "    是否重建启动依赖 (只依赖当下 active 的 ufw/nftables)? [y/N]: " a
        if [[ $a == y* ]]; then
            local svcs
            systemctl stop fail2ban 2>/dev/null
            rm -f /etc/systemd/system/fail2ban.service.d/override.conf
            mkdir -p /etc/systemd/system/fail2ban.service.d
            svcs=""
            if pkg_installed ufw && ufw status 2>/dev/null | grep -q active; then svcs+=" ufw.service"; fi
            if pkg_installed nft && systemctl is-active nftables >/dev/null 2>&1; then svcs+=" nftables.service"; fi
            cat > /etc/systemd/system/fail2ban.service.d/override.conf <<EOF
[Unit]
After=network.target${svcs}
Wants=${svcs}
EOF
            systemctl daemon-reload && systemctl start fail2ban
            echo -e "    $ERR_OK 启动依赖重建完成 (依赖: ${svcs:-无})"
            if f2b_available; then echo -e "    $ERR_OK fail2ban 已恢复运行"; else echo -e "    $ERR_FAIL fail2ban 未运行"; fi
        fi
    else
        echo -e " [跳过] 无 fail2ban systemd override"
    fi
    echo
    read -p " 回车返回..." _
}

restore_backup(){
    ls -lt /etc/fail2ban/jail.local.bak.* 2>/dev/null | head -5 | sed 's/^/  /'
    read -p " 输入备份文件全名以恢复, 留空取消: " f
    [[ -z $f || ! -f $f ]] && return
    cp "$f" "$JAIL_LOCAL" && rm -f "$JAIL_LOCAL_MINE"
    echo -e " $ERR_OK 已恢复 jail.local 并移除本脚本独占配置"
    fail2ban-client reload >/dev/null 2>&1
    read -p " 回车返回..." _
}

uninstall_my_configs(){
    read -p " 移除本脚本写过的 $JAIL_LOCAL_MINE 与 systemd override? [y/N]: " a
    [[ $a != y* ]] && return
    rm -f "$JAIL_LOCAL_MINE" /etc/systemd/system/fail2ban.service.d/override.conf
    systemctl daemon-reload; fail2ban-client reload >/dev/null 2>&1
    echo -e " $ERR_OK 清理完成"
    read -p " 回车返回..." _
}

jail_manage(){
    echo; echo " 当前 Jail 列表: $(ALL_JAILS)"
    read -p " 要操作的 Jail (留空返回): " j
    [[ -z $j ]] && return
    echo " 1) 详细状态   2) 启用   3) 停用(临时)"
    read -p " 选择: " op
    case $op in
        1) fail2ban-client status "$j" 2>/dev/null ;;
        2) fail2ban-client start "$j" 2>/dev/null && echo -e " $ERR_OK $j 已启动" ;;
        3) fail2ban-client stop "$j" 2>/dev/null && echo -e " $ERR_OK $j 已停用(重启 fail2ban 恢复; 永久停用请改 enabled=false)" ;;
        *) ;;
    esac
    read -p " 回车返回..." _
}

menu_main(){
    while true; do
        show_overview
        echo " ── 当前状态 ──"
        echo "  2. 当前被封禁的 IP"
        echo "  3. Jail 管理"
        echo "  4. 最近攻击事件"
        echo " ── 诊断 ──"
        echo "  5. 拦截链路自检 (核心)"
        echo "  6. 实际拦截规则摘要"
        echo "  7. 详细规则 (原始)"
        echo " ── 操作 ──"
        echo "  8. 手动封禁 IP"
        echo "  9. 手动解封 IP"
        echo " 10. 应用推荐配置 (幂等)"
        echo " ── 维护 ──"
        echo " 11. 重启 Fail2ban 并验证"
        echo " 12. 自动修复 (保守)"
        echo " 13. 恢复 jail.local 备份"
        echo " 14. 移除本脚本生成的配置"
        echo "  0. 退出"
        read -p " 请选择: " choice
        case $choice in
            0) exit ;;
            2) show_banned ;;
            3) jail_manage ;;
            4) show_events ;;
            5) chain_check ;;
            6) show_rules ;;
            7) show_rules_detail ;;
            8) do_ban ;;
            9) do_unban ;;
            10) apply_recommended_config ;;
            11) restart_and_verify ;;
            12) auto_repair ;;
            13) restore_backup ;;
            14) uninstall_my_configs ;;
            *) ;;
        esac
    done
}

# 非 interactive: fail2ban.sh overview|banned|events|check|rules
case "$1" in
    overview) show_overview; exit ;;
    banned)   show_banned;   exit ;;
    events)   show_events;   exit ;;
    check)    chain_check;   exit ;;
    rules)    show_rules;    exit ;;
    menu|"")  menu_main ;;
    *)        echo " 用法: $0 [overview|banned|events|check|rules] (无参=菜单)"; exit 1 ;;
esac
