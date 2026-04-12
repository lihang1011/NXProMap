#!/usr/bin/env bash

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
    || echo -e "\033[0;31m✘ Config parse failed: ${_NX_INFO_FILE}\033[0m" >&2
else
    echo -e "\033[0;31m✘ Config file not found: ${_NX_INFO_FILE}. Run nxinit.sh first.\033[0m" >&2
fi

export NX_ACTIVE_PROXY_PORT=""
export NX_CUR_MAP_PORT=""
export NX_CUR_MAP_TARGET=""
_NX_PREV_RX=0
_NX_PREV_TX=0
_NX_PREV_TS=0

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
        && echo -e "  \033[30m(Copied to clipboard)\033[0m\n"
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

    echo -e "\n\033[1;37;41m Warning: Other SSH tunnels detected! \033[0m"
    echo "$_other" | while read -r line; do echo -e "  \033[30m${line}\033[0m"; done
    echo ""
    read -p "Disconnect these tunnels? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        _pids=$(echo "$_other" | awk '{print $2}')
        for _pid in $_pids; do
            kill "$_pid" 2>/dev/null && echo -e "\033[1;32m✔ Disconnected PID: ${_pid}\033[0m"
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

    echo -e "\033[1;33m▸ Found SSH tunnel on :${port}, PID: ${pids}\033[0m"

    for pid in $pids; do
        if kill "$pid" 2>/dev/null; then
            echo -e "\033[1;32m✔ SSH tunnel disconnected (PID: ${pid})\033[0m"
        else
            echo -e "\033[0;31m✘ Failed to kill process ${pid} (may need permission)\033[0m"
        fi
    done
}

nxpon() {
    local WAIT_MODE=1
    local MODE="http"

    for _arg in "$@"; do
        case "$_arg" in
            socks5h|socks5|http) MODE="$_arg" ;;
            *) echo -e "\033[1;33m▸ Unknown argument: $_arg (valid: socks5h socks5 http)\033[0m"; return 1 ;;
        esac
    done

    if [ -n "$http_proxy" ]; then
        echo -e "\033[1;33m▸ Proxy already active: $http_proxy\033[0m"
        return 0
    fi

    local _self_ip _self_ssh_port
    read -r _self_ip _self_ssh_port < <(_nx_self_addr)

    echo -e "\033[1mScanning proxy ports...\033[0m"
    local found_port="" suggest_port=""
    for port in "${NX_PROXY_PORTS[@]}"; do
        if _check_port "$port"; then
            if curl -Is --connect-timeout 2 --max-time 3 \
                    --proxy "socks5h://127.0.0.1:$port" \
                    "$NX_TEST_URL" >/dev/null 2>&1; then
                found_port="$port"
                printf "  :%-5s \033[1;32m✔ Available\033[0m\n" "$port"
                break
            else
                printf "  :%-5s \033[1;33m▸ In use (proxy unreachable)\033[0m\n" "$port"
            fi
        else
            printf "  :%-5s \033[30m○ Free\033[0m\n" "$port"
            [ -z "$suggest_port" ] && suggest_port="$port"
        fi
    done

    if [ -z "$found_port" ]; then
        echo ""
        if [ -n "$suggest_port" ]; then
            echo -e "\033[1;37;41m Warning: No active tunnel found! \033[0m"
            echo -e "Suggest using free port \033[1;33m:${suggest_port}\033[0m on your local PC:"
            _nx_hint_cmd "ssh -N -R ${suggest_port}:${NX_LOCAL_PROXY_HOST}:${NX_LOCAL_PROXY_PORT} ${NX_SSH_USER}@${_self_ip} -p ${_self_ssh_port}"
        else
            echo -e "\033[1;37;41m Warning: All proxy ports are occupied! \033[0m"
            echo -e "Add more ports to NX_PROXY_PORTS"
        fi

        if [ $WAIT_MODE -eq 1 ] && [ -n "$suggest_port" ]; then
            local _timeout=60 _elapsed=0 _ss_out
            echo -e "\033[1;36m▸ Waiting for tunnel (up to ${_timeout}s)...\033[0m"
            while [ $_elapsed -lt $_timeout ]; do
                sleep 1
                _elapsed=$(( _elapsed + 1 ))
                printf "\r  \033[30mWaiting... %ds/%ds\033[0m" "$_elapsed" "$_timeout"
                _ss_out=$(ss -lnt)
                for port in "${NX_PROXY_PORTS[@]}"; do
                    if echo "$_ss_out" | grep -q ":$port "; then
                        if curl -Is --connect-timeout 2 --max-time 3 \
                                --proxy "socks5h://127.0.0.1:$port" \
                                "$NX_TEST_URL" >/dev/null 2>&1; then
                            found_port="$port"
                            printf "\r  :%-5s \033[1;32m✔ Tunnel ready\033[0m\n" "$port"
                            break 2
                        fi
                    fi
                done
            done
            if [ -z "$found_port" ]; then
                echo -e "\n\033[0;31m✘ Timeout: tunnel not ready\033[0m"
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
        echo -e "\033[1;33m▸ Port ${NX_PROXY_PORTS[0]} occupied, switched to :${found_port}\033[0m"
    echo -e "\033[1;32m✔ Proxy active\033[0m  \033[30m$P_URL  Connection OK\033[0m"
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
        echo -e "\033[1;35m✔ Proxy cleared\033[0m"
    else
        echo -e "\033[30m▸ No active proxy\033[0m"
    fi
}

nxmon() {
    if [ -z "$1" ]; then
        echo -e "\033[1;37mUsage: nxmon <remote-port> [local-port]\033[0m"
        return 1
    fi

    if [[ ! "$1" =~ ^[0-9]+$ ]] || (( $1 < 1 || $1 > 65535 )); then
        echo -e "\033[1;33m▸ Invalid port '$1' (must be 1-65535)\033[0m"
        return 1
    fi

    export NX_CUR_MAP_PORT="$1"
    export NX_CUR_MAP_TARGET="${2:-$1}"

    local app_stat
    _check_port "$NX_CUR_MAP_PORT" \
        && app_stat="\033[1;32mListening\033[0m" \
        || app_stat="\033[30mNot detected\033[0m"

    echo -e "\n\033[1;37;45m Info: Port mapping set \033[0m"
    echo -e "Map: Remote:\033[1;32m${NX_CUR_MAP_PORT}\033[0m -> Local:\033[1;32m${NX_CUR_MAP_TARGET}\033[0m  Service: ${app_stat}"
    echo -e "Run this command on your local terminal:"
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
        echo -e "\033[1;35m✔ Port mapping cleared\033[0m"
    else
        echo -e "\033[30m▸ No active port mapping\033[0m"
    fi
}

nxrun() {
    if [ -z "$1" ]; then
        echo -e "\033[1;37mUsage: nxrun [socks5h|socks5|http] <command>\033[0m"
        return 1
    fi

    local mode="http"
    case "$1" in socks5h|socks5|http) mode="$1"; shift ;; esac

    nxpon "$mode" >/dev/null || { echo -e "\033[1;33m▸ Proxy not ready, command not executed\033[0m"; return 1; }

    echo -e "\033[1;36m▸ Running:\033[0m $*"

    trap 'nxpoff >/dev/null 2>&1; trap - INT TERM' INT TERM
    "$@"
    local ret=$?
    trap - INT TERM

    nxpoff >/dev/null
    [ $ret -ne 0 ] && echo -e "\033[1;33m▸ Exit code: $ret\033[0m"
    return $ret
}

_nx_fmt_speed() {
    awk -v b="$1" 'BEGIN{
        if(b>=1048576) printf "%.1f MB/s", b/1048576
        else if(b>=1024) printf "%.1f KB/s", b/1024
        else printf "%d B/s", b
    }'
}

_nx_mk_bar() {
    local val="$1" scale="$2" width="$3"
    local filled=$(( scale > 0 ? val * width / scale : 0 ))
    (( filled > width )) && filled=$width
    local empty=$(( width - filled ))
    local bar="" i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty; i++ )); do bar+="-"; done
    printf '%s' "$bar"
}

_nx_traffic_section() {
    local C_R="\033[0m" C_CYN="\033[36m" C_GRY="\033[90m" C_YLW="\033[33m"
    local C_B="\033[1m"
    local DIV="${C_GRY}---------------------------------------------------------${C_R}"
    local _eol="\033[K"

    local _iface
    _iface=$(ip route show default 2>/dev/null | awk 'NR==1{print $5}')
    [ -z "$_iface" ] && _iface=$(awk 'NR>2 && !/lo:/{gsub(/:$/,"",$1); print $1; exit}' /proc/net/dev)

    local _cur_rx=0 _cur_tx=0 _cur_ts
    _cur_ts=$(date +%s)
    [ -n "$_iface" ] && read -r _cur_rx _cur_tx < <(
        awk -v dev="${_iface}:" '$1==dev{print $2,$10}' /proc/net/dev
    )
    _cur_rx=${_cur_rx:-0}; _cur_tx=${_cur_tx:-0}

    if [ "$_NX_PREV_TS" -eq 0 ]; then
        _NX_PREV_RX="$_cur_rx"
        _NX_PREV_TX="$_cur_tx"
        _NX_PREV_TS="$_cur_ts"
        sleep 1
        _cur_ts=$(date +%s)
        [ -n "$_iface" ] && read -r _cur_rx _cur_tx < <(
            awk -v dev="${_iface}:" '$1==dev{print $2,$10}' /proc/net/dev
        )
        _cur_rx=${_cur_rx:-0}; _cur_tx=${_cur_tx:-0}
    fi

    local _up=0 _down=0
    local _dt=$(( _cur_ts - _NX_PREV_TS ))
    if [ "$_dt" -gt 0 ]; then
        _down=$(( (_cur_rx - _NX_PREV_RX) / _dt ))
        _up=$(( (_cur_tx - _NX_PREV_TX) / _dt ))
        (( _down < 0 )) && _down=0
        (( _up   < 0 )) && _up=0
    fi

    _NX_PREV_RX="$_cur_rx"
    _NX_PREV_TX="$_cur_tx"
    _NX_PREV_TS="$_cur_ts"

    local _max=$(( _up > _down ? _up : _down ))
    local _scale
    if   (( _max >= 10485760 )); then _scale=104857600
    elif (( _max >=  1048576 )); then _scale=10485760
    elif (( _max >=   102400 )); then _scale=1048576
    else                              _scale=102400
    fi

    local _bar_w=40
    local _up_bar _down_bar _up_str _down_str
    _up_bar=$(_nx_mk_bar "$_up"   "$_scale" "$_bar_w")
    _down_bar=$(_nx_mk_bar "$_down" "$_scale" "$_bar_w")
    _up_str=$(_nx_fmt_speed "$_up")
    _down_str=$(_nx_fmt_speed "$_down")

    printf "\n"
    printf "  ${C_B}Network Traffic${C_R}  ${C_GRY}(${_iface:-?})${C_R}${_eol}\n"
    printf "%b${_eol}\n" "$DIV"
    printf "  ${C_YLW}↑${C_R} %-10s [%s]  %s${_eol}\n" "Upload:"   "$_up_bar"   "$_up_str"
    printf "  ${C_CYN}↓${C_R} %-10s [%s]  %s${_eol}\n" "Download:" "$_down_bar" "$_down_str"
}

_nxinfo_body() {
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

            printf "  ${C_CYN}❯${C_R} [%s] %s\033[K\n" "$g_idx" "$g_name"
            printf "    Mem: %-18s | Util: %-5s | Temp: ${t_color}%s°C${C_R}\033[K\n" "$mem_str" "${g_util}%" "$g_temp"
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
            printf "  ${C_GRN}✔${C_R} %-10s ${C_GRN}ACTIVE${C_R} (%s)\033[K\n" "Proxy:" "$http_proxy"
        else
            printf "  ${C_RED}✗${C_R} %-10s ${C_RED}FAILED${C_R} (Timeout, tunnel broken)\033[K\n" "Proxy:"
        fi
    else
        local _has_tunnel=0 _ports_info=""
        for p in "${NX_PROXY_PORTS[@]}"; do
            _check_port "$p" && { _ports_info="${_ports_info} :${p}"; _has_tunnel=1; }
        done
        if [ $_has_tunnel -eq 1 ]; then
             printf "  ${C_YLW}●${C_R} %-10s ${C_YLW}IDLE${C_R}   (Available%s)\033[K\n" "Proxy:" "$_ports_info"
        else
             printf "  ${C_GRY}- %-10s OFF    (No tunnels)${C_R}\033[K\n" "Proxy:"
        fi
    fi

    if [ -n "$NX_CUR_MAP_PORT" ]; then
        if _check_port "$NX_CUR_MAP_PORT"; then
             printf "  ${C_GRN}✔${C_R} %-10s ${C_GRN}ACTIVE${C_R} (Remote: %s -> Local: %s)\033[K\n" "Port Map:" "$NX_CUR_MAP_PORT" "$NX_CUR_MAP_TARGET"
        else
             printf "  ${C_RED}✗${C_R} %-10s ${C_RED}FAILED${C_R} (Port %s not listening)\033[K\n" "Port Map:" "$NX_CUR_MAP_PORT"
        fi
    else
         printf "  ${C_GRY}- %-10s OFF    (Not set)${C_R}\033[K\n" "Port Map:"
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
    echo -e "${tools_line}\033[K"
}

nxinfo() {
    _NX_PREV_RX=0; _NX_PREV_TX=0; _NX_PREV_TS=0
    local _watch=0
    for _arg in "$@"; do
        case "$_arg" in
            -w|--watch) _watch=1 ;;
        esac
    done

    if [ "$_watch" -eq 1 ]; then
        trap 'tput cnorm 2>/dev/null; tput rmcup 2>/dev/null; return 0' INT TERM
        tput smcup 2>/dev/null
        tput civis 2>/dev/null
        printf '\033[2J'
        while true; do
            printf '\033[H'
            _nxinfo_body
            _nx_traffic_section
            printf "  \033[90mAuto-refresh every 2s — Ctrl+C to exit\033[0m\033[K\n"
            printf '\033[J'
            sleep 2
        done
        tput cnorm 2>/dev/null
        tput rmcup 2>/dev/null
        trap - INT TERM
    else
        _nxinfo_body
        echo ""
    fi
}

_nxedit_write_json() {
    local _ip="$1" _port="$2"
    [ ! -w "$_NX_INFO_FILE" ] && { echo -e "\033[1;33m▸ nx_info.json not writable, session-only update\033[0m"; return 1; }
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
            read -rp "  Server hostname: " _hostname
            [ -z "$_hostname" ] && { echo -e "\033[0;31m✘ Hostname cannot be empty\033[0m"; return 1; }
            read -rp "  Public IP address: " _ip
            if [[ ! "$_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                echo -e "\033[0;31m✘ Invalid IP format\033[0m"; return 1
            fi
            read -rp "  SSH port (1-65535): " _port
            if [[ ! "$_port" =~ ^[0-9]+$ ]] || (( _port < 1 || _port > 65535 )); then
                echo -e "\033[0;31m✘ Invalid port\033[0m"; return 1
            fi
            local _val="${_ip}:${_port}"
            if [ -n "${NX_SERVER_SSH_PORTS[$_hostname]}" ]; then
                echo -e "\033[1;33m▸ ${_hostname} already exists: ${NX_SERVER_SSH_PORTS[$_hostname]}\033[0m"
                read -rp "  Overwrite? [y/N] " _ans
                [[ "$_ans" =~ ^[yY](es|ES)?$ ]] || { echo -e "\033[30m▸ Cancelled\033[0m"; return 0; }
            fi
            NX_SERVER_SSH_PORTS["$_hostname"]="$_val"
            _nxedit_write_json "$_hostname" "$_val" \
                && echo -e "\033[1;32m✔ Written to nx_info.json: ${_hostname} → ${_val}\033[0m" \
                || echo -e "\033[1;32m✔ Session updated: ${_hostname} → ${_val}\033[0m"
            ;;
        -d|--del)
            if [ ${#NX_SERVER_SSH_PORTS[@]} -eq 0 ]; then
                echo -e "\033[30m▸ Config table is empty\033[0m"; return 0
            fi
            local _keys=() _i=1
            echo -e "\033[1;37mCurrent entries:\033[0m"
            for _k in "${!NX_SERVER_SSH_PORTS[@]}"; do
                printf "  \033[1;33m%d)\033[0m  %-20s  %s\n" "$_i" "$_k" "${NX_SERVER_SSH_PORTS[$_k]}"
                _keys+=("$_k")
                _i=$(( _i + 1 ))
            done
            read -rp "  Enter number to delete: " _sel
            if [[ ! "$_sel" =~ ^[0-9]+$ ]] || (( _sel < 1 || _sel > ${#_keys[@]} )); then
                echo -e "\033[0;31m✘ Invalid selection\033[0m"; return 1
            fi
            local _del_key="${_keys[$(( _sel - 1 ))]}"
            unset "NX_SERVER_SSH_PORTS[$_del_key]"
            _nxedit_del_json "$_del_key" \
                && echo -e "\033[1;32m✔ Deleted from nx_info.json: ${_del_key}\033[0m" \
                || echo -e "\033[1;32m✔ Session deleted: ${_del_key} (file not writable, not persisted)\033[0m"
            ;;
        *)
            echo -e "\033[1;33m▸ Unknown option: $_mode (valid: -a add  -d delete)\033[0m"; return 1 ;;
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
    printf "  ${C_CYN}❯${C_R} %-10s %-18s %s\n" "nxpon"   "[mode]"           "Start proxy (wait for tunnel, then activate)"
    printf "  ${C_CYN}❯${C_R} %-10s %-18s %s\n" "nxpoff"  "-"                "Stop proxy and clean history"
    printf "  ${C_CYN}❯${C_R} %-10s %-18s %s\n" "nxmon"   "<remote> [local]" "Set port mapping and print local SSH command"
    printf "  ${C_CYN}❯${C_R} %-10s %-18s %s\n" "nxmoff"  "-"                "Clear port mapping"
    printf "  ${C_CYN}❯${C_R} %-10s %-18s %s\n" "nxrun"   "[mode] <cmd>"     "Run command under proxy, auto-off after"
    printf "  ${C_CYN}❯${C_R} %-10s %-18s %s\n" "nxedit"  "[-a|-d]"          "Manage server SSH port config table"
    printf "  ${C_CYN}❯${C_R} %-10s %-18s %s\n" "nxinfo"  "[-w]"             "Full status overview; -w for live refresh"
    printf "  ${C_CYN}❯${C_R} %-10s %-18s %s\n" "nxhelp"  "-"                "Show this help table"
    echo ""
}