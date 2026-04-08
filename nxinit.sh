#!/usr/bin/env bash
# bash nxinit.sh
# nxinit.sh — nxpromap 首次配置引导脚本
# 交互式填写信息并生成 nx_info.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NX_INFO_FILE="$SCRIPT_DIR/nx_info.json"

if ! command -v python3 >/dev/null 2>&1; then
    echo -e "\033[0;31m✘ 需要 python3，但未找到，请先安装\033[0m" >&2
    exit 1
fi

if [ -f "$NX_INFO_FILE" ]; then
    echo -e "\033[1;33m▸ 配置文件已存在: $NX_INFO_FILE\033[0m"
    read -rp "  是否重新初始化? [y/N] " _ans
    [[ "$_ans" =~ ^[yY](es|ES)?$ ]] || { echo -e "\033[30m▸ 已取消\033[0m"; exit 0; }
    echo ""
fi

echo -e "\033[1;37;44m  nxpromap 初始化配置  \033[0m"
echo -e "\033[30m（直接回车使用 [ ] 内的默认值）\033[0m\n"

read -rp "SSH 用户名 [$(whoami)]: " _user
_user="${_user:-$(whoami)}"

echo ""
echo -e "\033[1;37m本地PC代理设置（Clash / V2Ray 等）:\033[0m"
read -rp "  代理地址 [127.0.0.1]: " _proxy_host
_proxy_host="${_proxy_host:-127.0.0.1}"
read -rp "  代理端口 [7890]: " _proxy_port
_proxy_port="${_proxy_port:-7890}"

echo ""
read -rp "候选隧道端口（空格分隔）[1080 1081 1082 1083]: " _ports_raw
_ports_raw="${_ports_raw:-1080 1081 1082 1083}"

read -rp "连通性测试 URL [https://www.google.com]: " _test_url
_test_url="${_test_url:-https://www.google.com}"

echo ""
echo -e "\033[1;37m各服务器配置（留空主机名结束输入）:\033[0m"
echo -e "\033[30m  主机名: 服务器上 hostname 命令的输出（如 pr4090、h100-1）\033[0m"
_server_hostnames=()
_server_ips=()
_server_ports=()
while true; do
    read -rp "  主机名（留空结束）: " _hostname
    [ -z "$_hostname" ] && break
    read -rp "  ${_hostname} 的对外 IP: " _ip
    if [[ ! "$_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo -e "  \033[0;31m✘ IP 格式无效，请重新输入\033[0m"
        continue
    fi
    read -rp "  ${_hostname} 的 SSH 端口 [22]: " _port
    _port="${_port:-22}"
    if [[ ! "$_port" =~ ^[0-9]+$ ]] || (( _port < 1 || _port > 65535 )); then
        echo -e "  \033[0;31m✘ 端口无效，请重新输入\033[0m"
        continue
    fi
    _server_hostnames+=("$_hostname")
    _server_ips+=("$_ip")
    _server_ports+=("$_port")
    echo -e "  \033[1;32m✔ 已记录: ${_hostname} → ${_ip}:${_port}\033[0m"
done

echo ""
echo -e "\033[1m正在生成配置文件...\033[0m"

_py_servers=""
for (( _i=0; _i<${#_server_hostnames[@]}; _i++ )); do
    _py_servers="${_py_servers}servers[\"${_server_hostnames[$_i]}\"] = \"${_server_ips[$_i]}:${_server_ports[$_i]}\""$'\n'
done

python3 << PYEOF
import json

servers = {}
${_py_servers}
ports = [int(p) for p in "$_ports_raw".split()]

d = {
    "NX_SSH_USER": "$_user",
    "NX_LOCAL_PROXY_HOST": "$_proxy_host",
    "NX_LOCAL_PROXY_PORT": "$_proxy_port",
    "NX_PROXY_PORTS": ports,
    "NX_TEST_URL": "$_test_url",
    "NX_SERVER_SSH_PORTS": servers
}

with open("$NX_INFO_FILE", "w") as f:
    json.dump(d, f, indent=4, ensure_ascii=False)
    f.write("\n")
PYEOF

if [ $? -ne 0 ]; then
    echo -e "\033[0;31m✘ 配置文件生成失败\033[0m" >&2
    exit 1
fi

chmod 600 "$NX_INFO_FILE"
echo -e "\033[1;32m✔ 配置文件已生成: $NX_INFO_FILE\033[0m"
echo -e "\033[30m  权限: $(ls -la "$NX_INFO_FILE" | awk '{print $1, $3, $4}')\033[0m"
echo ""
echo -e "\033[1;37m下一步:\033[0m"
echo -e "  source ~/.script/nxpromap.sh   # 加载配置"
echo -e "  nxpon                          # 开启代理"
echo -e "  nxhelp                         # 查看帮助"
