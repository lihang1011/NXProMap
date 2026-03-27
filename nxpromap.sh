#!/usr/bin/env bash
# -------------------- Functions (EN) -----------------------------
# nxpon                  : Start proxy (scans NX_PROXY_PORTS, set env)
# nxpoff                 : Stop proxy (restore env, kill tunnel, clean hist)
# nxmon                  : Set port mapping & print SSH local-forward cmd
# nxmoff                 : Clear mapping (kill tunnel, clean hist)
# nxrun                  : Run command under temp proxy, auto-off after
# nxinfo                 : Full-table status: System / GPU / Proxy / Tools
# nxhelp                 : Display command reference table
# -------------------- 功能（中文）-------------------------------
# nxpon                  : 开启代理（扫描 NX_PROXY_PORTS，设置环境变量）
# nxpoff                 : 关闭代理（恢复环境变量，终止隧道，清理历史）
# nxmon                  : 设置端口映射并输出 SSH 本地转发命令
# nxmoff                 : 清除映射（终止隧道，清理历史记录）
# nxrun                  : 在代理下执行单条命令，完成后自动关闭
# nxinfo                 : 全表格状态展示：系统 / GPU / 代理 / 工具
# nxhelp                 : 显示命令参考表
# ---------------- Configuration (EN) ----------------------------
# NX_SSH_USER          : Remote SSH username
# NX_SSH_HOST          : Remote SSH IP/Domain
# NX_SSH_PORT          : Remote SSH Port
# NX_LOCAL_PROXY_HOST  : Local proxy address (e.g., 127.0.0.1)
# NX_LOCAL_PROXY_PORT  : Local proxy port (e.g., Clash / V2Ray, 7890)
# NX_PROXY_PORTS       : Ordered list of candidate remote SOCKS5 ports
# NX_TEST_URL          : Connectivity test URL (HTTPS)
# NX_ACTIVE_PROXY_PORT : Currently active proxy port (set at runtime)
# NX_CUR_MAP_PORT      : Current monitored server-side port
# NX_CUR_MAP_TARGET    : Current mapped local port
#
# ---------------- 配置信息（中文）-------------------------------
# NX_SSH_USER          : 远程 SSH 用户名
# NX_SSH_HOST          : 远程主机 IP 或域名
# NX_SSH_PORT          : 远程 SSH 端口
# NX_LOCAL_PROXY_HOST  : 本地代理监听地址（通常为 127.0.0.1）
# NX_LOCAL_PROXY_PORT  : 本地代理监听端口（如 Clash / V2Ray，通常 7890）
# NX_PROXY_PORTS       : 候选远程 SOCKS5 端口列表（按序扫描）
# NX_TEST_URL          : 连通性测试 HTTPS 地址
# NX_ACTIVE_PROXY_PORT : 当前激活的代理端口（运行时动态设置）
# NX_CUR_MAP_PORT      : 当前监控的服务端端口
# NX_CUR_MAP_TARGET    : 当前映射的本地端口
#
# ================================================================

NX_SSH_USER="<SSH_USER>"
NX_SSH_HOST="<SSH_HOST>"
NX_SSH_PORT="<SSH_PORT>"

NX_LOCAL_PROXY_HOST="127.0.0.1"
NX_LOCAL_PROXY_PORT="7890"
NX_PROXY_PORTS=(1080 1081 1082 1083) 
NX_TEST_URL="https://www.google.com"

export NX_ACTIVE_PROXY_PORT=""
export NX_CUR_MAP_PORT=""
export NX_CUR_MAP_TARGET=""

_check_port() { ss -lnt | grep -q ":$1 "; }
_check_net()  { curl -Is --connect-timeout 2 --max-time 3 "$NX_TEST_URL" >/dev/null 2>&1; }

_nx_clean_hist() {
    local f="$HOME/.bash_history"
    [ -f "$f" ] && sed -i '/^nx/d' "$f"
}

_nx_hint_cmd() {
    local cmd="$1"
    echo -e "  \033[1;33m${cmd}\033[0m"
    local b64
    b64=$(printf '%s' "$cmd" | base64 2>/dev/null) \
        && printf '\033]52;c;%s\a' "$b64" 2>/dev/null \
        && echo -e "  \033[30m(已尝试复制到剪贴板)\033[0m\n"
}

_find_ssh_tunnels() {
    local port="$1"
    local user="${2:-$NX_SSH_USER}"
    local host="${3:-$NX_SSH_HOST}"
    ps aux | grep -E "ssh.*-[NRL].*:${port}.*${user}@${host}" | grep -v grep
}

_find_all_user_tunnels() {
    local user="${1:-$NX_SSH_USER}"
    local host="${2:-$NX_SSH_HOST}"
    ps aux | grep -E "ssh.*-[NRL].*${user}@${host}" | grep -v grep
}

_kill_ssh_tunnel() {
    local port="$1"
    local pids

    pids=$(_find_ssh_tunnels "$port" | awk '{print $2}')

    if [ -z "$pids" ]; then
        return 1
    fi

    echo -e "\033[1;33m▸ 发现端口 :${port} 的 SSH 隧道进程: ${pids}\033[0m"

    for pid in $pids; do
        if kill "$pid" 2>/dev/null; then
            echo -e "\033[1;32m✔ 已断开 SSH 隧道 (PID: ${pid})\033[0m"
        else
            echo -e "\033[0;31m✘ 无法断开进程 ${pid}（可能需要权限）\033[0m"
        fi
    done
}

nxpon() {
    local MODE="${1:-socks5h}"

    if [ -n "$http_proxy" ]; then
        echo -e "\033[1;33m▸ 代理已开启: $http_proxy\033[0m"
        return 0
    fi

    echo -e "\033[1m正在扫描代理端口...\033[0m"
    local found_port="" suggest_port=""
    for port in "${NX_PROXY_PORTS[@]}"; do
        if _check_port "$port"; then
            if curl -Is --connect-timeout 2 --max-time 3 \
                    --proxy "socks5h://127.0.0.1:$port" \
                    "$NX_TEST_URL" >/dev/null 2>&1; then
                found_port="$port"
                printf "  :%-5s \033[1;32m✔ 可用\033[0m\n" "$port"
                break
            else
                printf "  :%-5s \033[1;33m▸ 占用中（代理不通）\033[0m\n" "$port"
            fi
        else
            printf "  :%-5s \033[30m○ 空闲\033[0m\n" "$port"
            [ -z "$suggest_port" ] && suggest_port="$port"
        fi
    done

    if [ -z "$found_port" ]; then
        echo ""
        if [ -n "$suggest_port" ]; then
            echo -e "\033[1;37;41m Warning: 暂无可用隧道！ \033[0m"
            echo -e "建议在本地用空闲端口 \033[1;33m:${suggest_port}\033[0m 建立:"
            _nx_hint_cmd "ssh -N -R ${suggest_port}:${NX_LOCAL_PROXY_HOST}:${NX_LOCAL_PROXY_PORT} ${NX_SSH_USER}@${NX_SSH_HOST} -p ${NX_SSH_PORT}"
        else
            echo -e "\033[1;37;41m Warning: 所有备用端口均被占用！ \033[0m"
            echo -e "可在 NX_PROXY_PORTS 中追加新端口"
        fi
        return 1
    fi

    local P_URL
    case "$MODE" in
        socks5h) P_URL="socks5h://127.0.0.1:$found_port" ;;
        socks5)  P_URL="socks5://127.0.0.1:$found_port"  ;;
        http)    P_URL="http://127.0.0.1:$found_port"    ;;
        *)  echo -e "\033[1;33m▸ 未知模式: $MODE（可选: socks5h socks5 http）\033[0m"; return 1 ;;
    esac

    export _OLD_HTTP_PROXY="$http_proxy"
    export _OLD_HTTPS_PROXY="$https_proxy"
    export _OLD_ALL_PROXY="$ALL_PROXY"
    export NX_ACTIVE_PROXY_PORT="$found_port"
    export http_proxy="$P_URL"
    export https_proxy="$P_URL"
    export ALL_PROXY="$P_URL"

    trap 'nxpoff >/dev/null 2>&1' EXIT

    echo ""
    [ "$found_port" != "${NX_PROXY_PORTS[0]}" ] && \
        echo -e "\033[1;33m▸ 端口 ${NX_PROXY_PORTS[0]} 被占用，已切换至 :${found_port}\033[0m"
    echo -e "\033[1;32m✔ 代理已开启\033[0m  \033[30m$P_URL  连通正常\033[0m"
}

nxpoff() {
    local was_active="no"
    local active_port="$NX_ACTIVE_PROXY_PORT"

    if [ -n "$http_proxy" ]; then
        was_active="yes"
        [ -n "$_OLD_HTTP_PROXY" ]  && export http_proxy="$_OLD_HTTP_PROXY"   || unset http_proxy
        [ -n "$_OLD_HTTPS_PROXY" ] && export https_proxy="$_OLD_HTTPS_PROXY" || unset https_proxy
        [ -n "$_OLD_ALL_PROXY" ]   && export ALL_PROXY="$_OLD_ALL_PROXY"     || unset ALL_PROXY
        unset _OLD_HTTP_PROXY _OLD_HTTPS_PROXY _OLD_ALL_PROXY NX_ACTIVE_PROXY_PORT
        trap - EXIT
    fi

    _nx_clean_hist

    if [ -n "$active_port" ]; then
        echo ""
        if _find_ssh_tunnels "$active_port" >/dev/null; then
            _kill_ssh_tunnel "$active_port"
        fi

        local other_tunnels
        other_tunnels=$(_find_all_user_tunnels | grep -v ":${active_port}" | grep -v grep)

        if [ -n "$other_tunnels" ]; then
            echo -e "\n\033[1;37;41m Warning: 检测到其他 SSH 隧道! \033[0m"
            echo "$other_tunnels" | while read -r line; do
                echo -e "  \033[30m${line}\033[0m"
            done
            echo ""
            read -p "是否一并断开这些隧道? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                local all_pids
                all_pids=$(echo "$other_tunnels" | awk '{print $2}')
                for pid in $all_pids; do
                    kill "$pid" 2>/dev/null && \
                        echo -e "\033[1;32m✔ 已断开 PID: ${pid}\033[0m"
                done
            fi
        fi
    fi

    if [ "$was_active" = "yes" ]; then
        echo -e "\033[1;35m✔ 代理已清除\033[0m"
    else
        echo -e "\033[30m▸ 当前未开启代理\033[0m"
    fi
}

nxmon() {
    if [ -z "$1" ]; then
        echo -e "\033[1;37m用法: nxmon <服务端端口> [本地端口]\033[0m"
        return 1
    fi

    if [[ ! "$1" =~ ^[0-9]+$ ]] || (( $1 < 1 || $1 > 65535 )); then
        echo -e "\033[1;33m▸ 端口号无效 '$1'（需 1-65535）\033[0m"
        return 1
    fi

    export NX_CUR_MAP_PORT="$1"
    export NX_CUR_MAP_TARGET="${2:-$1}"

    local app_stat
    _check_port "$NX_CUR_MAP_PORT" \
        && app_stat="\033[1;32m运行中\033[0m" \
        || app_stat="\033[30m未检测到监听\033[0m"

    echo -e "\n\033[1;37;45m Info: 建立端口映射 \033[0m"
    echo -e "映射: 远端:\033[1;32m${NX_CUR_MAP_PORT}\033[0m -> 本地:\033[1;32m${NX_CUR_MAP_TARGET}\033[0m  服务: ${app_stat}"
    echo -e "请复制并在本地终端执行以下命令:"
    _nx_hint_cmd "ssh -N -L ${NX_CUR_MAP_TARGET}:127.0.0.1:${NX_CUR_MAP_PORT} ${NX_SSH_USER}@${NX_SSH_HOST} -p ${NX_SSH_PORT}"
}

nxmoff() {
    local was_active="no"
    local map_port="$NX_CUR_MAP_PORT"

    if [ -n "$NX_CUR_MAP_PORT" ]; then
        was_active="yes"
        unset NX_CUR_MAP_PORT NX_CUR_MAP_TARGET
    fi

    _nx_clean_hist

    if [ -n "$map_port" ]; then
        echo ""
        if _find_ssh_tunnels "$map_port" >/dev/null; then
            _kill_ssh_tunnel "$map_port"
        fi

        local other_tunnels
        other_tunnels=$(_find_all_user_tunnels | grep -v ":${map_port}" | grep -v grep)

        if [ -n "$other_tunnels" ]; then
            echo -e "\n\033[1;37;41m Warning: 检测到其他 SSH 隧道! \033[0m"
            echo "$other_tunnels" | while read -r line; do
                echo -e "  \033[30m${line}\033[0m"
            done
            echo ""
            read -p "是否一并断开这些隧道? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                local all_pids
                all_pids=$(echo "$other_tunnels" | awk '{print $2}')
                for pid in $all_pids; do
                    kill "$pid" 2>/dev/null && \
                        echo -e "\033[1;32m✔ 已断开 PID: ${pid}\033[0m"
                done
            fi
        fi
    fi

    if [ "$was_active" = "yes" ]; then
        echo -e "\033[1;35m✔ 映射记录已清除\033[0m"
    else
        echo -e "\033[30m▸ 当前无映射记录\033[0m"
    fi
}

nxrun() {
    if [ -z "$1" ]; then
        echo -e "\033[1;37m用法: nxrun [socks5h|socks5|http] <命令>\033[0m"
        return 1
    fi

    local mode="socks5h"
    case "$1" in socks5h|socks5|http) mode="$1"; shift ;; esac

    nxpon "$mode" >/dev/null || { echo -e "\033[1;33m▸ 代理未就绪，命令未执行\033[0m"; return 1; }

    echo -e "\033[1;36m▸ 执行:\033[0m $*"

    trap 'nxpoff >/dev/null 2>&1; trap - INT TERM' INT TERM
    "$@"
    local ret=$?
    trap - INT TERM

    nxpoff >/dev/null
    [ $ret -ne 0 ] && echo -e "\033[1;33m▸ 命令退出码: $ret\033[0m"
    return $ret
}

nxinfo() {
    local _os_name _kernel _ip
    _os_name=$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2 | cut -c 1-22)
    _kernel=$(uname -r)
    _ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    local _mem_used _mem_total
    _mem_total=$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)
    _mem_used=$(awk '/MemAvailable/{avail=$2} /MemTotal/{total=$2} END{printf "%.0f", (total-avail)/1024}' /proc/meminfo 2>/dev/null)

    local _disk_info
    _disk_info=$(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $3 "/" $2}')

    local _py_ver="Uninstalled"
    if command -v python3 >/dev/null 2>&1; then
        _py_ver=$(python3 -V 2>&1 | awk '{print $2}')
    fi
    local _conda_env="${CONDA_DEFAULT_ENV:-None}"
    local FMT_HDR_SYS="%-20s %-22s %-16s %-20s %-18s\033[1;37;44m  系统环境  \033[0m\n"
    local FMT_ROW_SYS="\033[1;33m%-20s\033[0m %-22s \033[1;36m%-16s\033[0m %-20s %-18s\n"

    echo -ne "\n\033[30;47m"
    printf "$FMT_HDR_SYS" "USER@HOST" "OS (KERNEL)" "IP" "MEM (USED/TOT)" "DISK (HOME)"
    printf "$FMT_ROW_SYS" "$(whoami)@$(hostname)" "${_os_name:-Unknown}" "${_ip:-Unknown}" "${_mem_used:-?}/${_mem_total:-?}MB" "$_disk_info"

    local FMT_HDR_ENV="%-20s %-22s %-16s %-20s %-18s\033[1;37;44m  计算环境  \033[0m\n"
    local FMT_ROW_ENV="\033[1;33m%-20s\033[0m \033[1;32m%-22s\033[0m %-16s %-20s %-18s\n"
    echo -ne "\n\033[30;47m"
    printf "$FMT_HDR_ENV" "CONDA_ENV" "PYTHON_VER" "-" "-" "-"
    printf "$FMT_ROW_ENV" "$_conda_env" "$_py_ver" "-" "-" "-"

    local FMT_HDR_GPU="%-6s %-24s %-18s %-10s %-10s %-27s\033[1;37;42m  GPU 状态  \033[0m\n"
    local FMT_ROW_GPU="\033[1;33m%-6s\033[0m %-24s \033[1;36m%-18s\033[0m %-10s %-10s %-27s\n"
    local FMT_ERR_GPU="\033[0;31m%-6s %-24s %-18s %-10s %-10s %-27s\033[0m\n"

    echo -ne "\n\033[30;47m"
    printf "$FMT_HDR_GPU" "IDX" "NAME" "MEM (USED/TOT)" "UTIL" "TEMP" "CUDA_VER"

    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        local _cuda_ver=$(nvidia-smi 2>/dev/null | awk '/CUDA Version/{print $9}')
        local gpu_count=0

        while IFS=',' read -r g_idx g_name g_mem_used g_mem_tot g_util g_temp; do
            g_name=$(echo "$g_name" | xargs | cut -c 1-24)
            local mem_str="${g_mem_used}/${g_mem_tot} MB"
            local util_str="${g_util}%"
            local temp_str="${g_temp}C"

            if [ -n "$g_temp" ] && [ "$g_temp" -ge 80 ] 2>/dev/null; then
                printf "$FMT_ERR_GPU" "$g_idx" "$g_name" "$mem_str" "$util_str" "$temp_str" "${_cuda_ver:-N/A}"
            else
                printf "$FMT_ROW_GPU" "$g_idx" "$g_name" "$mem_str" "$util_str" "$temp_str" "${_cuda_ver:-N/A}"
            fi
            gpu_count=$((gpu_count + 1))
        done < <(nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv,noheader,nounits 2>/dev/null)

        [ "$gpu_count" -eq 0 ] && printf "$FMT_ERR_GPU" "-" "No GPU Detected" "-" "-" "-" "-"
    else
        printf "$FMT_ERR_GPU" "-" "NVML Error / Crash" "-" "-" "-" "N/A"
    fi

    local FMT_HDR_PRX="%-12s %-10s %-26s %-49s\033[1;37;45m  代理映射  \033[0m\n"
    local FMT_ROW_PRX="\033[1;33m%-12s\033[0m \033[1;32m%-10s\033[0m %-26s %-49s\n"
    local FMT_ERR_PRX="\033[1;33m%-12s\033[0m \033[0;31m%-10s\033[0m %-26s %-49s\n"
    local FMT_IDL_PRX="\033[30m%-12s %-10s %-26s %-49s\033[0m\n"

    echo -ne "\n\033[30;47m"
    printf "$FMT_HDR_PRX" "SERVICE" "STATUS" "ADDRESS / PORT" "DETAILS"

    if [ -n "$http_proxy" ]; then
        if _check_net; then
            printf "$FMT_ROW_PRX" "Proxy" "ACTIVE" "$http_proxy" "Connection OK"
        else
            printf "$FMT_ERR_PRX" "Proxy" "FAILED" "$http_proxy" "Timeout / Tunnel Broken"
        fi
    else
        local _has_tunnel=0
        local _ports_info=""
        for p in "${NX_PROXY_PORTS[@]}"; do
            _check_port "$p" && { _ports_info="${_ports_info}:${p} "; _has_tunnel=1; }
        done
        if [ $_has_tunnel -eq 1 ]; then
            printf "$FMT_IDL_PRX" "Proxy" "IDLE" "Available: ${_ports_info}" "Run 'nxpon' to activate"
        else
            printf "$FMT_IDL_PRX" "Proxy" "OFF" "-" "[IDLE] Establish tunnel first"
        fi
    fi

    if [ -n "$NX_CUR_MAP_PORT" ]; then
        local map_stat="ACTIVE"
        local map_fmt="$FMT_ROW_PRX"
        _check_port "$NX_CUR_MAP_PORT" || { map_stat="FAILED"; map_fmt="$FMT_ERR_PRX"; }
        printf "$map_fmt" "Port Map" "$map_stat" "R:${NX_CUR_MAP_PORT} -> L:${NX_CUR_MAP_TARGET}" "Local mapping rule"
    else
        printf "$FMT_IDL_PRX" "Port Map" "OFF" "-" "[IDLE] Not set"
    fi

    local FMT_HDR_TLS="%-100s\033[1;37;46m  常用工具  \033[0m\n"
    echo -ne "\n\033[30;47m"
    printf "$FMT_HDR_TLS" "AVAILABLE TOOLS"

    local tools_line=""
    for tool in ss curl ssh git docker htop vim tmux; do
        local pad_tool=$(printf "%-10s" "$tool")
        if command -v "$tool" >/dev/null 2>&1; then
            tools_line="${tools_line}\033[1;32m✓\033[0m ${pad_tool}"
        else
            tools_line="${tools_line}\033[0;31m✗\033[0m ${pad_tool}"
        fi
    done
    echo -e "${tools_line}\n"
}

nxhelp() {
    local FMT_HDR_HLP="%-12s %-25s %-61s\033[1;37;46m Nx命令帮助 \033[0m\n"
    local FMT_ROW_HLP="\033[1;32m%-12s\033[0m %s %s\n"

    echo -ne "\n\033[30;47m"
    printf "$FMT_HDR_HLP" "COMMAND" "ARGS" "DESCRIPTION"

    printf "$FMT_ROW_HLP" "nxpon"  "[mode]                   " "开启代理 mode: socks5h(默认)/socks5/http"
    printf "$FMT_ROW_HLP" "nxpoff" "-                        " "关闭代理并清理历史"
    printf "$FMT_ROW_HLP" "nxmon"  "<远端端口> [本地]        " "设置端口映射并输出本地执行命令"
    printf "$FMT_ROW_HLP" "nxmoff" "-                        " "清除映射记录"
    printf "$FMT_ROW_HLP" "nxrun"  "[mode] <命令>            " "临时代理执行，完成后自动关闭"
    printf "$FMT_ROW_HLP" "nxinfo" "-                        " "环境监控 & 代理状态总览"
    echo ""
}
