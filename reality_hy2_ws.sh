#!/bin/bash 
 
# 打印函数 
print_with_delay() {
    local text="$1"
    local delay="$2"
    for ((i=0; i<${#text}; i++)); do 
        echo -n "${text:$i:1}"
        sleep $delay 
    done 
    echo 
}
 
# 通知横幅 
show_notice() {
    local message="$1"
    echo "#####################################################################################################"
    printf "%-100s\n" " "
    printf "%-10s %-80s %-10s\n" " " "$message" " "
    printf "%-100s\n" " "
    echo "#####################################################################################################"
}
 
# 初始化动画 
print_with_delay "sing-box-reality-hy2-installer" 0.02 
echo -e "\n\n"
 
# 基础依赖安装 
install_base() {
    if ! command -v jq &>/dev/null; then 
        echo "安装jq..."
        export DEBIAN_FRONTEND=noninteractive 
        apt-get update > /dev/null 2>&1
        apt-get install -y jq openssl uuid-runtime > /dev/null 2>&1 || {
            yum install -y epel-release > /dev/null 2>&1
            yum install -y jq openssl util-linux > /dev/null 2>&1 || dnf install -y jq openssl util-linux > /dev/null 2>&1
        }
    fi 
}
 
# Argo隧道管理 
regenarte_cloudflared_argo() {
    pgrep -f cloudflared | xargs kill -9 > /dev/null 2>&1
    vmess_port=$(jq -r '.inbounds[[2]()].listen_port' /root/sbox/sbconfig_server.json) 
    
    nohup /root/sbox/cloudflared-linux tunnel --url http://localhost:$vmess_port \
        --no-autoupdate \
        --edge-ip-version auto \
        --protocol h2mux > argo.log  2>&1 &
        
    sleep 8 
    argo=$(awk -F// '/trycloudflare.com/{print  $2}' argo.log  | awk 'NR==2{print $1}' | sed 's/ //g')
     && argo=$(curl -s localhost:45678/metrics | awk '/argo_tunnel/{print $NF}' | head -1)
    
    echo "$argo" | base64 > /root/sbox/argo.txt.b64  
    rm -f argo.log  
}
 
# 组件下载 
download_singbox() {
    arch=$(uname -m)
    case $arch in 
        x86_64) arch="amd64";;
        aarch64) arch="arm64";;
        armv7l) arch="armv7";;
        *) echo "不支持的架构"; exit 1;;
    esac 
 
    latest_tag=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases  | jq -r '.[[0]()].tag_name')
    latest_ver=${latest_tag#v}
    
    pkg_name="sing-box-${latest_ver}-linux-${arch}"
    download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_tag}/${pkg_name}.tar.gz" 
    
    echo "下载sing-box v${latest_ver}..."
    curl -sLo "/root/${pkg_name}.tar.gz"  "$download_url"
    
    tar -xzf "/root/${pkg_name}.tar.gz"  -C /root 
    mv "/root/${pkg_name}/sing-box" /root/sbox/
    chmod +x /root/sbox/sing-box 
    
    rm -rf "/root/${pkg_name}"*
}
 
download_cloudflared() {
    arch=$(uname -m)
    case $arch in 
        x86_64) cf_arch="amd64";;
        aarch64) cf_arch="arm64";;
        armv7l) cf_arch="arm";;
    esac 
    
    cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}" 
    curl -sLo "/root/sbox/cloudflared-linux" "$cf_url"
    chmod +x /root/sbox/cloudflared-linux 
}
 
# 客户端配置展示 
show_client_configuration() {
    # 获取配置参数 
    reality_port=$(jq -r '.inbounds[[0]()].listen_port' /root/sbox/sbconfig_server.json) 
    sni=$(jq -r '.inbounds[[0]()].tls.server_name'  /root/sbox/sbconfig_server.json) 
    uuid=$(jq -r '.inbounds[[0]()].users[[0]()].uuid' /root/sbox/sbconfig_server.json) 
    public_key=$(base64 -d /root/sbox/public.key.b64) 
    short_id=$(jq -r '.inbounds[[0]()].tls.reality.short_id[[0]()]  ' /root/sbox/sbconfig_server.json) 
    
    hy_port=$(jq -r '.inbounds[[1]()].listen_port' /root/sbox/sbconfig_server.json) 
    hy_pass=$(jq -r '.inbounds[[1]()].users[[0]()].password' /root/sbox/sbconfig_server.json) 
    hy_sni=$(openssl x509 -in /root/self-cert/cert.pem  -noout -subject | awk -F'CN=' '{print $2}')
    
    argo=$(base64 -d /root/sbox/argo.txt.b64) 
    vmess_uuid=$(jq -r '.inbounds[[2]()].users[[0]()].uuid' /root/sbox/sbconfig_server.json) 
    ws_path=$(jq -r '.inbounds[[2]()].transport.path'  /root/sbox/sbconfig_server.json) 
    
    server_ip=$(curl -s4m8 ip.sb  || curl -s6m8 ip.sb) 
 
    # Reality配置 
    show_notice "Reality 客户端配置"
    cat <<EOF 
协议类型：vless 
地址：${server_ip}
端口：${reality_port}
UUID：${uuid}
传输协议：tcp 
流量控制：xtls-rprx-vision 
SNI：${sni}
PublicKey：${public_key}
ShortID：${short_id}
 
通用链接：
vless://${uuid}@${server_ip}:${reality_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#SING-BOX-Reality 
EOF 
 
    # Hysteria2配置 
    show_notice "Hysteria2 客户端配置"
    cat <<EOF 
服务器地址：${server_ip}
端口：${hy_port}
密码：${hy_pass}
SNI：${hy_sni}
跳过证书验证：true 
ALPN：h3
 
快速链接：
hysteria2://${hy_pass}@${server_ip}:${hy_port}?insecure=1&sni=${hy_sni}
EOF 
 
    # VMess配置 
    show_notice "VMess over WS 配置"
    cat <<EOF 
协议类型：vmess 
地址：speed.cloudflare.com  
端口：443/80 
UUID：${vmess_uuid}
传输协议：ws 
TLS：开启(443)/关闭(80)
路径：${ws_path}
SNI伪装：${argo}
 
WS链接：
443端口：wss://${argo}${ws_path}
80端口：ws://${argo}${ws_path}
 
通用链接：
vmess://$(echo '{"v":"2","ps":"sing-box-vmess","add":"speed.cloudflare.com","port":"443","id":"'${vmess_uuid}'","aid":"0","scy":"none","net":"ws","type":"none","host":"'${argo}'","path":"'${ws_path}'","tls":"tls","sni":"'${argo}'","fp":"chrome"}'  | base64 -w0)
EOF 
}
 
# 主安装流程 
main_installation() {
    mkdir -p /root/sbox /root/self-cert 
    install_base 
    download_singbox 
    download_cloudflared 
    
    # 生成密钥 
    key_pair=$(/root/sbox/sing-box generate reality-keypair)
    private_key=$(awk '/PrivateKey/{print $2}' <<< "$key_pair" | tr -d '"')
    public_key=$(awk '/PublicKey/{print $2}' <<< "$key_pair" | tr -d '"')
    echo "$public_key" | base64 > /root/sbox/public.key.b64  
    
    # 生成参数 
    uuid=$(/root/sbox/sing-box generate uuid)
    short_id=$(/root/sbox/sing-box generate rand -hex 8)
    hy_pass=$(/root/sbox/sing-box generate rand -hex 6)
    vmess_uuid=$(/root/sbox/sing-box generate uuid)
    ws_path="/$(/root/sbox/sing-box generate rand -hex 4)"
    
    # 交互设置 
    read -p "Reality端口 [[443]()]: " reality_port ; reality_port=${reality_port:-443}
    read -p "SNI域名 [apple.com]: " sni ; sni=${sni:-apple.com} 
    read -p "Hysteria2端口 [8443]: " hy_port ; hy_port=${hy_port:-8443}
    read -p "自签证书域名 [microsoft.com]: " hy_sni ; hy_sni=${hy_sni:-microsoft.com} 
    
    # 生成证书 
    openssl ecparam -genkey -name prime256v1 -out /root/self-cert/private.key  
    openssl req -new -x509 -days 36500 -key /root/self-cert/private.key  -out /root/self-cert/cert.pem  -subj "/CN=${hy_sni}"
    
    # 生成配置文件 
    jq -n --argjson ports "{ \"reality\": $reality_port, \"hysteria2\": $hy_port, \"vmess\": 15555 }" \
        --arg uuid "$uuid" --arg short_id "$short_id" --arg private_key "$private_key" \
        --arg hy_pass "$hy_pass" --arg vmess_uuid "$vmess_uuid" --arg ws_path "$ws_path" \
        --arg sni "$sni" --arg hy_sni "$hy_sni" '
{
    "log": { "level": "info", "timestamp": true },
    "inbounds": [
        {
            "type": "vless",
            "listen": "::",
            "listen_port": $ports.reality, 
            "users": [{ "uuid": $uuid, "flow": "xtls-rprx-vision" }],
            "tls": {
                "enabled": true,
                "server_name": $sni,
                "reality": {
                    "enabled": true,
                    "handshake": { "server": $sni, "server_port": 443 },
                    "private_key": $private_key,
                    "short_id": [$short_id]
                }
            }
        },
        {
            "type": "hysteria2",
            "listen": "::",
            "listen_port": $ports.hysteria2, 
            "users": [{ "password": $hy_pass }],
            "tls": {
                "enabled": true,
                "alpn": ["h3"],
                "certificate_path": "/root/self-cert/cert.pem", 
                "key_path": "/root/self-cert/private.key" 
            }
        },
        {
            "type": "vmess",
            "listen": "::",
            "listen_port": $ports.vmess, 
            "users": [{ "uuid": $vmess_uuid, "alterId": 0 }],
            "transport": {
                "type": "ws",
                "path": $ws_path,
                "headers": { "Host": $sni }
            }
        }
    ],
    "outbounds": [
        { "type": "direct", "tag": "direct" },
        { "type": "block", "tag": "block" }
    ]
}' > /root/sbox/sbconfig_server.json  
 
    # 服务配置 
    cat > /etc/systemd/system/sing-box.service  <<EOF 
[Unit]
Description=sing-box service 
After=network.target  
 
[Service]
User=root 
ExecStart=/root/sbox/sing-box run -C /root/sbox/
Restart=on-failure 
RestartSec=30s
LimitNOFILE=infinity 
 
[Install]
WantedBy=multi-user.target  
EOF 
 
    systemctl daemon-reload 
    systemctl enable --now sing-box 
    regenarte_cloudflared_argo 
    show_client_configuration 
}
 
# 执行主函数 
main_installation 
