#!/usr/bin/env bash
# -------------------- Functions (EN) -----------------------------
# nxpon                  : Start proxy (scans NX_PROXY_PORTS, set env); waits for tunnel if none found
# nxpoff                 : Stop proxy (restore env, kill tunnel, clean hist)
# nxmon                  : Set port mapping & print SSH local-forward cmd
# nxmoff                 : Clear mapping (kill tunnel, clean hist)
# nxrun                  : Run command under temp proxy, auto-off after
# nxedit                 : Manage NX_SERVER_SSH_PORTS in nx_info.json (-a add, -d delete)
# nxinfo                 : Full-table status: System / GPU / Proxy / Tools
# nxhelp                 : Display command reference table
# -------------------- 功能（中文）-------------------------------
# nxpon                  : 开启代理（扫描 NX_PROXY_PORTS，设置环境变量）；无隧道时自动等待
# nxpoff                 : 关闭代理（恢复环境变量，终止隧道，清理历史）
# nxmon                  : 设置端口映射并输出 SSH 本地转发命令
# nxmoff                 : 清除映射（终止隧道，清理历史记录）
# nxrun                  : 在代理下执行单条命令，完成后自动关闭
# nxedit                 : 管理 nx_info.json 中的 NX_SERVER_SSH_PORTS 配置表（-a 添加，-d 删除）
# nxinfo                 : 全表格状态展示：系统 / GPU / 代理 / 工具
# nxhelp                 : 显示命令参考表
# ---------------- Configuration (EN) ----------------------------
# All sensitive config (IPs, ports, username) lives in nx_info.json (same dir, chmod 600)
# Run nxinit.sh to generate nx_info.json on first use.
# NX_ACTIVE_PROXY_PORT : Currently active proxy port (set at runtime)
# NX_CUR_MAP_PORT      : Current monitored server-side port
# NX_CUR_MAP_TARGET    : Current mapped local port
#
# ---------------- 配置信息（中文）-------------------------------
# 所有敏感配置（IP、端口、用户名等）均在同目录 nx_info.json 中（建议 chmod 600）
# 首次使用请运行 nxinit.sh 生成配置文件
# NX_ACTIVE_PROXY_PORT : 当前激活的代理端口（运行时动态设置）
# NX_CUR_MAP_PORT      : 当前监控的服务端端口
# NX_CUR_MAP_TARGET    : 当前映射的本地端口
#
# ================================================================

_NX_INFO_FILE="$(dirname "${BASH_SOURCE[0]}")/nx_info.json"
declare -A NX_SERVER_SSH_PORTS

if [ -f "$_NX_INFO_FILE" ]; then
    eval "$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
u   = d.get("NX_SSH_USER", "")
h   = d.get("NX_LOCAL_PROXY_HOST", "127.0.0.1")
p   = str(d.get("NX_LOCAL_PROXY_PORT", "7890"))
pts = " ".join(str(x) for x in d.get("NX_PROXY_PORTS", [1080,1081,1082,1083]))
url = d.get("NX_TEST_URL", "https://www.google.com")
ssh = d.get("NX_SERVER_SSH_PORTS", {})
for k, v in ssh.items():
    print("NX_SERVER_SSH_PORTS[\""+k+"\"]=\""+str(v)+"\"")
print("NX_SSH_USER=\""         + u    + "\"")
print("NX_LOCAL_PROXY_HOST=\"" + h    + "\"")
print("NX_LOCAL_PROXY_PORT=\"" + p    + "\"")
print("NX_PROXY_PORTS=("       + pts  + ")")
print("NX_TEST_URL=\""         + url  + "\"")
' "$_NX_INFO_FILE")" \
    || echo -e "\033[0;31m✘ 配置解析失败: ${_NX_INFO_FILE}\033[0m" >&2
else
    echo -e "\033[0;31m✘ 配置文件未找到: ${_NX_INFO_FILE}，请先运行 nxinit.sh\033[0m" >&2
fi

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

_nx_self_addr() {
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
entry = d.get("NX_SERVER_SSH_PORTS", {}).get(sys.argv[2], "")
if ":" in entry:
    ip, port = entry.rsplit(":", 1)
    print(ip + " " + port)
else:
    import subprocess
    ips = subprocess.check_output(["hostname", "-I"]).decode().split()
    print((ips[0] if ips else "127.0.0.1") + " 22")
' "$_NX_INFO_FILE" "$(hostname)"
}

_find_ssh_tunnels() {
    local port="$1"
    local user="${2:-$NX_SSH_USER}"
    ps aux | grep -E "ssh.*-[NRL].*:${port}.*${user}@" | grep -v grep
}

_find_all_user_tunnels() {
    local user="${1:-$NX_SSH_USER}"
    ps aux | grep -E "ssh.*-[NRL].*${user}@" | grep -v grep
}

_nx_kill_other_tunnels() {
    local _skip_port="$1" _other _pids _pid
    _other=$(_find_all_user_tunnels | grep -v ":${_skip_port}")
    [ -z "$_other" ] && return 0

    echo -e "\n\033[1;37;41m Warning: 检测到其他 SSH 隧道! \033[0m"
    echo "$_other" | while read -r line; do echo -e "  \033[30m${line}\033[0m"; done
    echo ""
    read -p "是否一并断开这些隧道? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        _pids=$(echo "$_other" | awk '{print $2}')
        for _pid in $_pids; do
            kill "$_pid" 2>/dev/null && echo -e "\033[1;32m✔ 已断开 PID: ${_pid}\033[0m"
        done
    fi
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
    local WAIT_MODE=1
    local MODE="http"

    for _arg in "$@"; do
        case "$_arg" in
            socks5h|socks5|http) MODE="$_arg" ;;
            *) echo -e "\033[1;33m▸ 未知参数: $_arg（可选: socks5h socks5 http）\033[0m"; return 1 ;;
        esac
    done

    if [ -n "$http_proxy" ]; then
        echo -e "\033[1;33m▸ 代理已开启: $http_proxy\033[0m"
        return 0
    fi

    local _self_ip _self_ssh_port
    read -r _self_ip _self_ssh_port < <(_nx_self_addr)

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
            echo -e "建议在本地PC用空闲端口 \033[1;33m:${suggest_port}\033[0m 建立:"
            _nx_hint_cmd "ssh -N -R ${suggest_port}:${NX_LOCAL_PROXY_HOST}:${NX_LOCAL_PROXY_PORT} ${NX_SSH_USER}@${_self_ip} -p ${_self_ssh_port}"
        else
            echo -e "\033[1;37;41m Warning: 所有备用端口均被占用！ \033[0m"
            echo -e "可在 NX_PROXY_PORTS 中追加新端口"
        fi

        if [ $WAIT_MODE -eq 1 ] && [ -n "$suggest_port" ]; then
            local _timeout=60 _elapsed=0 _ss_out
            echo -e "\033[1;36m▸ 等待隧道就绪（最多 ${_timeout}s）…\033[0m"
            while [ $_elapsed -lt $_timeout ]; do
                sleep 1
                _elapsed=$(( _elapsed + 1 ))
                printf "\r  \033[30m等待中... %ds/%ds\033[0m" "$_elapsed" "$_timeout"
                _ss_out=$(ss -lnt)
                for port in "${NX_PROXY_PORTS[@]}"; do
                    if echo "$_ss_out" | grep -q ":$port "; then
                        if curl -Is --connect-timeout 2 --max-time 3 \
                                --proxy "socks5h://127.0.0.1:$port" \
                                "$NX_TEST_URL" >/dev/null 2>&1; then
                            found_port="$port"
                            printf "\r  :%-5s \033[1;32m✔ 隧道就绪\033[0m\n" "$port"
                            break 2
                        fi
                    fi
                done
            done
            if [ -z "$found_port" ]; then
                echo -e "\n\033[0;31m✘ 等待超时，隧道未就绪\033[0m"
                return 1
            fi
        else
            return 1
        fi
    fi

    local P_URL="${MODE}://127.0.0.1:$found_port"

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

        _nx_kill_other_tunnels "$active_port"
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
    local _self_ip _self_ssh_port
    read -r _self_ip _self_ssh_port < <(_nx_self_addr)
    _nx_hint_cmd "ssh -N -L ${NX_CUR_MAP_TARGET}:127.0.0.1:${NX_CUR_MAP_PORT} ${NX_SSH_USER}@${_self_ip} -p ${_self_ssh_port}"
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

        _nx_kill_other_tunnels "$map_port"
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

    local mode="http"
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

    local _py_ver="None"
    if command -v python3 >/dev/null 2>&1; then
        _py_ver=$(python3 -V 2>&1 | awk '{print $2}')
    fi
    local _conda_env="${CONDA_DEFAULT_ENV:-None}"

    local _cuda_ver="N/A"
    if command -v nvidia-smi >/dev/null 2>&1; then
        _cuda_ver=$(nvidia-smi 2>/dev/null | awk '/CUDA Version/{print $9}')
    fi

    local C_R="\033[0m"
    local C_B="\033[1m"
    local C_GRY="\033[90m"
    local C_CYN="\033[36m"
    local C_MAG="\033[35m"
    local C_GRN="\033[32m"
    local C_RED="\033[31m"
    local C_YLW="\033[33m"
    local DIV="${C_GRY}---------------------------------------------------------${C_R}"

    echo ""
    printf "  ${C_B}%-31s %s${C_R}\n" "System Information" "Compute Environment"
    echo -e "$DIV"
    printf "  ${C_CYN}❯${C_R} %-28s ${C_MAG}◆${C_R} %-7s %s\n" "$(whoami)@$(hostname)" "Python:" "$_py_ver"
    printf "    %-6s %-21s ${C_MAG}◆${C_R} %-7s %s\n" "OS:" "${_os_name:-Unknown}" "Conda:" "$_conda_env"
    printf "    %-6s %-21s ${C_MAG}◆${C_R} %-7s %s\n" "IP:" "${_ip:-Unknown}" "CUDA:" "$_cuda_ver"
    printf "    %-6s %-21s\n" "RAM:" "${_mem_used:-?}/${_mem_total:-?} MB"
    printf "    %-6s %-21s\n" "Disk:" "$_disk_info (Home)"

    echo ""
    printf "  ${C_B}GPU Status${C_R}\n"
    echo -e "$DIV"

    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        local gpu_count=0
        while IFS=',' read -r g_idx g_name g_mem_used g_mem_tot g_util g_temp; do
            g_name=$(echo "$g_name" | xargs | cut -c 1-28)
            local mem_str="${g_mem_used}/${g_mem_tot} MB"

            local t_color="$C_R"
            if [ -n "$g_temp" ] && [ "$g_temp" -ge 80 ] 2>/dev/null; then
                t_color="$C_RED"
            fi

            printf "  ${C_CYN}❯${C_R} [%s] %s\n" "$g_idx" "$g_name"
            printf "    Mem: %-18s | Util: %-5s | Temp: ${t_color}%s°C${C_R}\n" "$mem_str" "${g_util}%" "$g_temp"
            gpu_count=$((gpu_count + 1))
        done < <(nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv,noheader,nounits 2>/dev/null)

        [ "$gpu_count" -eq 0 ] && printf "  ${C_GRY}- No GPU Detected -${C_R}\n"
    else
        printf "  ${C_RED}✗ NVML Error / Crash${C_R}\n"
    fi

    echo ""
    printf "  ${C_B}Network & Proxy${C_R}\n"
    echo -e "$DIV"

    if [ -n "$http_proxy" ]; then
        if _check_net; then
            printf "  ${C_GRN}✔${C_R} %-10s ${C_GRN}ACTIVE${C_R} (%s)\n" "Proxy:" "$http_proxy"
        else
            printf "  ${C_RED}✗${C_R} %-10s ${C_RED}FAILED${C_R} (Timeout, Tunnel broken)\n" "Proxy:"
        fi
    else
        local _has_tunnel=0 _ports_info=""
        for p in "${NX_PROXY_PORTS[@]}"; do
            _check_port "$p" && { _ports_info="${_ports_info} :${p}"; _has_tunnel=1; }
        done
        if [ $_has_tunnel -eq 1 ]; then
             printf "  ${C_YLW}●${C_R} %-10s ${C_YLW}IDLE${C_R}   (Available%s)\n" "Proxy:" "$_ports_info"
        else
             printf "  ${C_GRY}- %-10s OFF    (No tunnels)${C_R}\n" "Proxy:"
        fi
    fi

    if [ -n "$NX_CUR_MAP_PORT" ]; then
        if _check_port "$NX_CUR_MAP_PORT"; then
             printf "  ${C_GRN}✔${C_R} %-10s ${C_GRN}ACTIVE${C_R} (Remote: %s -> Local: %s)\n" "Port Map:" "$NX_CUR_MAP_PORT" "$NX_CUR_MAP_TARGET"
        else
             printf "  ${C_RED}✗${C_R} %-10s ${C_RED}FAILED${C_R} (Port %s not listening)\n" "Port Map:" "$NX_CUR_MAP_PORT"
        fi
    else
         printf "  ${C_GRY}- %-10s OFF    (Not set)${C_R}\n" "Port Map:"
    fi

    echo ""
    printf "  ${C_B}Available Tools${C_R}\n"
    echo -e "$DIV"
    local tools_line="  "
    for tool in ss curl ssh git docker htop vim tmux; do
        if command -v "$tool" >/dev/null 2>&1; then
            tools_line+="${C_GRN}✔${C_R} $(printf "%-8s" "$tool")"
        else
            tools_line+="${C_RED}✗${C_R} $(printf "%-8s" "$tool")"
        fi
    done
    echo -e "${tools_line}\n"
}

_nxedit_write_json() {
    local _ip="$1" _port="$2"
    [ ! -w "$_NX_INFO_FILE" ] && { echo -e "\033[1;33m▸ nx_info.json 不可写，仅更新当前 session\033[0m"; return 1; }
    python3 -c '
import json, sys
f, ip, port = sys.argv[1], sys.argv[2], sys.argv[3]
with open(f) as fh:
    d = json.load(fh)
d.setdefault("NX_SERVER_SSH_PORTS", {})[ip] = port
with open(f, "w") as fh:
    json.dump(d, fh, indent=4, ensure_ascii=False)
    fh.write("\n")
' "$_NX_INFO_FILE" "$_ip" "$_port"
}

_nxedit_del_json() {
    local _key="$1"
    [ ! -w "$_NX_INFO_FILE" ] && return 1
    python3 -c '
import json, sys
f, key = sys.argv[1], sys.argv[2]
with open(f) as fh:
    d = json.load(fh)
d.get("NX_SERVER_SSH_PORTS", {}).pop(key, None)
with open(f, "w") as fh:
    json.dump(d, fh, indent=4, ensure_ascii=False)
    fh.write("\n")
' "$_NX_INFO_FILE" "$_key"
}

nxedit() {
    local _mode="${1:--a}"

    case "$_mode" in
        -a|--add)
            local _hostname _ip _port
            read -rp "  服务器主机名 (hostname): " _hostname
            [ -z "$_hostname" ] && { echo -e "\033[0;31m✘ 主机名不能为空\033[0m"; return 1; }
            read -rp "  对外 IP 地址: " _ip
            if [[ ! "$_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                echo -e "\033[0;31m✘ IP 格式无效\033[0m"; return 1
            fi
            read -rp "  SSH 端口 (1-65535): " _port
            if [[ ! "$_port" =~ ^[0-9]+$ ]] || (( _port < 1 || _port > 65535 )); then
                echo -e "\033[0;31m✘ 端口无效\033[0m"; return 1
            fi
            local _val="${_ip}:${_port}"
            if [ -n "${NX_SERVER_SSH_PORTS[$_hostname]}" ]; then
                echo -e "\033[1;33m▸ ${_hostname} 已存在: ${NX_SERVER_SSH_PORTS[$_hostname]}\033[0m"
                read -rp "  是否覆盖? [y/N] " _ans
                [[ "$_ans" =~ ^[yY](es|ES)?$ ]] || { echo -e "\033[30m▸ 已取消\033[0m"; return 0; }
            fi
            NX_SERVER_SSH_PORTS["$_hostname"]="$_val"
            _nxedit_write_json "$_hostname" "$_val" \
                && echo -e "\033[1;32m✔ 已写入 nx_info.json: ${_hostname} → ${_val}\033[0m" \
                || echo -e "\033[1;32m✔ session 已更新: ${_hostname} → ${_val}\033[0m"
            ;;
        -d|--del)
            if [ ${#NX_SERVER_SSH_PORTS[@]} -eq 0 ]; then
                echo -e "\033[30m▸ 配置表为空\033[0m"; return 0
            fi
            local _keys=() _i=1
            echo -e "\033[1;37m当前配置:\033[0m"
            for _k in "${!NX_SERVER_SSH_PORTS[@]}"; do
                printf "  \033[1;33m%d)\033[0m  %-20s  %s\n" "$_i" "$_k" "${NX_SERVER_SSH_PORTS[$_k]}"
                _keys+=("$_k")
                _i=$(( _i + 1 ))
            done
            read -rp "  输入要删除的序号: " _sel
            if [[ ! "$_sel" =~ ^[0-9]+$ ]] || (( _sel < 1 || _sel > ${#_keys[@]} )); then
                echo -e "\033[0;31m✘ 序号无效\033[0m"; return 1
            fi
            local _del_key="${_keys[$(( _sel - 1 ))]}"
            unset "NX_SERVER_SSH_PORTS[$_del_key]"
            _nxedit_del_json "$_del_key" \
                && echo -e "\033[1;32m✔ 已从 nx_info.json 删除: ${_del_key}\033[0m" \
                || echo -e "\033[1;32m✔ session 已删除: ${_del_key}（文件不可写，未持久化）\033[0m"
            ;;
        *)
            echo -e "\033[1;33m▸ 未知选项: $_mode（可选: -a 添加  -d 删除）\033[0m"; return 1 ;;
    esac
}

nxhelp() {
    local C_R="\033[0m"
    local C_B="\033[1m"
    local C_GRY="\033[90m"
    local C_CYN="\033[36m"
    local DIV="${C_GRY}---------------------------------------------------------${C_R}"

    echo ""
    printf "  ${C_B}%-11s %-18s %s${C_R}\n" "Command" "Arguments" "Description"
    echo -e "$DIV"
    printf "  ${C_CYN}❯${C_R} %-10s %-18s %s\n" "nxpon" "[mode]" "开启代理 (等待隧道就绪后激活)"
    printf "  ${C_CYN}❯${C_R} %-10s %-18s %s\n" "nxpoff" "-" "关闭代理并清理历史"
    printf "  ${C_CYN}❯${C_R} %-10s %-18s %s\n" "nxmon" "<remote> [local]" "设置端口映射并输出本地命令"
    printf "  ${C_CYN}❯${C_R} %-10s %-18s %s\n" "nxmoff" "-" "清除映射记录"
    printf "  ${C_CYN}❯${C_R} %-10s %-18s %s\n" "nxrun" "[mode] <cmd>" "临时代理执行，完成后自动关闭"
    printf "  ${C_CYN}❯${C_R} %-10s %-18s %s\n" "nxedit" "[-a|-d]" "管理服务器 SSH 端口配置表"
    printf "  ${C_CYN}❯${C_R} %-10s %-18s %s\n" "nxinfo" "-" "环境监控 & 代理状态总览"
    printf "  ${C_CYN}❯${C_R} %-10s %-18s %s\n" "nxhelp" "-" "显示本帮助列表"
    echo ""
}
