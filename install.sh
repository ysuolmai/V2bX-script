#!/bin/bash
red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; plain='\033[0m'
cur_dir=$(pwd)

# ------- 新增：解析 --instance 参数 / 环境变量 -------
INSTANCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance)
      INSTANCE="$2"; shift 2;;
    *)
      # 兼容旧用法：保留第一个非 --instance 作为版本号
      if [[ -z "$LEGACY_VERSION" ]]; then LEGACY_VERSION="$1"; shift; else shift; fi;;
  esac
done
if [[ -n "$INSTANCE" ]]; then SFX="-$INSTANCE"; else SFX=""; fi

BIN_DIR="/usr/local/V2bX${SFX}"
ETC_DIR="/etc/V2bX${SFX}"
SERVICE_NAME="V2bX${SFX}"

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！" && exit 1

# check os
if [[ -f /etc/redhat-release ]]; then
  release="centos"
elif grep -Eqi "alpine" /etc/issue; then
  release="alpine"
elif grep -Eqi "debian" /etc/issue; then
  release="debian"
elif grep -Eqi "ubuntu" /etc/issue; then
  release="ubuntu"
elif grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux" /etc/issue; then
  release="centos"
elif grep -Eqi "debian" /proc/version; then
  release="debian"
elif grep -Eqi "ubuntu" /proc/version; then
  release="ubuntu"
elif grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux" /proc/version; then
  release="centos"
elif grep -Eqi "arch" /proc/version; then
  release="arch"
else
  echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}"; exit 1
fi

arch=$(uname -m)
if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
  arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
  arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
  arch="s390x"
else
  arch="64"; echo -e "${yellow}检测架构失败，使用默认架构: ${arch}${plain}"
fi
echo "架构: ${arch}"

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ]; then
  echo "本软件不支持 32 位系统"; exit 2
fi

# os version
if [[ -f /etc/os-release ]]; then
  os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
  os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi
if [[ x"${release}" == x"centos" ]]; then
  if [[ ${os_version} -le 6 ]]; then echo -e "${red}请使用 CentOS 7+！${plain}"; exit 1; fi
  if [[ ${os_version} -eq 7 ]]; then echo -e "${yellow}注意： CentOS 7 无法使用hysteria1/2协议！${plain}"; fi
elif [[ x"${release}" == x"ubuntu" ]]; then
  if [[ ${os_version} -lt 16 ]]; then echo -e "${red}请使用 Ubuntu 16+！${plain}"; exit 1; fi
elif [[ x"${release}" == x"debian" ]]; then
  if [[ ${os_version} -lt 8 ]]; then echo -e "${red}请使用 Debian 8+！${plain}"; exit 1; fi
fi

install_base() {
  if [[ x"${release}" == x"centos" ]]; then
    yum install -y epel-release wget curl unzip tar crontabs socat ca-certificates >/dev/null 2>&1
    update-ca-trust force-enable >/dev/null 2>&1
  elif [[ x"${release}" == x"alpine" ]]; then
    apk add wget curl unzip tar socat ca-certificates >/dev/null 2>&1
    update-ca-certificates >/dev/null 2>&1
  elif [[ x"${release}" == x"debian" ]]; then
    apt-get update -y >/dev/null 2>&1
    apt install -y wget curl unzip tar cron socat ca-certificates >/dev/null 2>&1
    update-ca-certificates >/dev/null 2>&1
  elif [[ x"${release}" == x"ubuntu" ]]; then
    apt-get update -y >/dev/null 2>&1
    apt install -y wget curl unzip tar cron socat ca-certificates >/dev/null 2>&1
    update-ca-certificates >/dev/null 2>&1
  elif [[ x"${release}" == x"arch" ]]; then
    pacman -Sy --noconfirm >/dev/null 2>&1
    pacman -S --noconfirm --needed wget curl unzip tar cron socat ca-certificates >/dev/null 2>&1
  fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
  if [[ ! -f ${BIN_DIR}/V2bX ]]; then return 2; fi
  if [[ x"${release}" == x"alpine" ]]; then
    temp=$(service ${SERVICE_NAME} status | awk '{print $3}')
    [[ x"${temp}" == x"started" ]] && return 0 || return 1
  else
    temp=$(systemctl status ${SERVICE_NAME} 2>/dev/null | grep Active | awk '{print $3}' | tr -d '()')
    [[ x"${temp}" == x"running" ]] && return 0 || return 1
  fi
}

install_V2bX() {
  rm -rf "${BIN_DIR}"
  mkdir -p "${BIN_DIR}"
  cd "${BIN_DIR}"

  # 版本选择：兼容旧用法（第一个非 --instance 参数为版本号）
  if [[ -z "$LEGACY_VERSION" ]]; then
    last_version=$(curl -Ls "https://api.github.com/repos/wyx2685/V2bX/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [[ -z "$last_version" ]] && echo -e "${red}检测 V2bX 版本失败${plain}" && exit 1
    echo -e "检测到 V2bX 最新版本：${last_version}，开始安装"
    wget --no-check-certificate -N --progress=bar -O "${BIN_DIR}/V2bX-linux.zip" \
      "https://github.com/wyx2685/V2bX/releases/download/${last_version}/V2bX-linux-${arch}.zip" || { echo -e "${red}下载失败${plain}"; exit 1; }
  else
    last_version="$LEGACY_VERSION"
    url="https://github.com/wyx2685/V2bX/releases/download/${last_version}/V2bX-linux-${arch}.zip"
    echo -e "开始安装 V2bX ${last_version}"
    wget --no-check-certificate -N --progress=bar -O "${BIN_DIR}/V2bX-linux.zip" "${url}" || { echo -e "${red}下载失败${plain}"; exit 1; }
  fi

  unzip V2bX-linux.zip && rm -f V2bX-linux.zip
  chmod +x V2bX

  mkdir -p "${ETC_DIR}"
  cp geoip.dat "${ETC_DIR}/" 2>/dev/null
  cp geosite.dat "${ETC_DIR}/" 2>/dev/null

  if [[ x"${release}" == x"alpine" ]]; then
    # OpenRC
    rm -f "/etc/init.d/${SERVICE_NAME}"
    cat > "/etc/init.d/${SERVICE_NAME}" <<EOF
#!/sbin/openrc-run
name="${SERVICE_NAME}"
description="V2bX (${INSTANCE:-default})"
command="${BIN_DIR}/V2bX"
command_args="server"
command_user="root"
pidfile="/run/${SERVICE_NAME}.pid"
command_background="yes"
depend() { need net }
EOF
    chmod +x "/etc/init.d/${SERVICE_NAME}"
    rc-update add "${SERVICE_NAME}" default
    echo -e "${green}V2bX ${last_version}${plain} 安装完成（实例：${INSTANCE:-default}），已设置开机自启"
  else
    # systemd
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=V2bX Service (${INSTANCE:-default})
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=${BIN_DIR}
ExecStart=${BIN_DIR}/V2bX server -c ${ETC_DIR}/config.json
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl stop "${SERVICE_NAME}" 2>/dev/null
    systemctl enable "${SERVICE_NAME}"
    echo -e "${green}V2bX ${last_version}${plain} 安装完成（实例：${INSTANCE:-default}），已设置开机自启"
  fi

  # 仅首次创建配置文件时复制模板（避免覆盖你已有配置）
  if [[ ! -f "${ETC_DIR}/config.json" ]]; then
    cp config.json "${ETC_DIR}/"
    echo
    echo -e "${yellow}全新安装（实例：${INSTANCE:-default}}）。请先到 ${ETC_DIR}/config.json 修改必要内容（端口不要与其他实例冲突）。${plain}"
    first_install=true
  else
    if [[ x"${release}" == x"alpine" ]]; then
      service "${SERVICE_NAME}" start
    else
      systemctl start "${SERVICE_NAME}"
    fi
    sleep 2
    check_status
    echo
    if [[ $? == 0 ]]; then
      echo -e "${green}${SERVICE_NAME} 重启成功${plain}"
    else
      echo -e "${red}${SERVICE_NAME} 可能启动失败，请使用日志命令查看并对照 wiki。${plain}"
    fi
    first_install=false
  fi

  # 其他可选配置文件（若不存在才拷贝）
  [[ ! -f "${ETC_DIR}/dns.json" ]] && cp dns.json "${ETC_DIR}/" 2>/dev/null
  [[ ! -f "${ETC_DIR}/route.json" ]] && cp route.json "${ETC_DIR}/" 2>/dev/null
  [[ ! -f "${ETC_DIR}/custom_outbound.json" ]] && cp custom_outbound.json "${ETC_DIR}/" 2>/dev/null
  [[ ! -f "${ETC_DIR}/custom_inbound.json" ]] && cp custom_inbound.json "${ETC_DIR}/" 2>/dev/null

  # 仅在默认实例安装管理脚本，以免混淆
  if [[ -z "$INSTANCE" ]]; then
    curl -o /usr/bin/V2bX -Ls https://raw.githubusercontent.com/wyx2685/V2bX-script/master/V2bX.sh
    chmod +x /usr/bin/V2bX
    if [ ! -L /usr/bin/v2bx ]; then
      ln -s /usr/bin/V2bX /usr/bin/v2bx
      chmod +x /usr/bin/v2bx
    fi
  fi

  cd "$cur_dir"
  rm -f install.sh

  echo
  echo "V2bX 管理方式："
  if [[ -z "$INSTANCE" ]]; then
    echo "  systemctl {start|stop|restart|status} V2bX"
  else
    echo "  systemctl {start|stop|restart|status} ${SERVICE_NAME}"
  fi

  # 首次安装时可选生成配置
  if [[ $first_install == true && -z "$INSTANCE" ]]; then
    read -rp "检测到你为第一次安装V2bX(默认实例), 是否自动生成配置文件？(y/n): " if_generate
    if [[ $if_generate == [Yy] ]]; then
      curl -o ./initconfig.sh -Ls https://raw.githubusercontent.com/wyx2685/V2bX-script/master/initconfig.sh
      source initconfig.sh
      rm -f initconfig.sh
      generate_config_file
      echo -e "${yellow}如需第二实例，请用 --instance NAME 重跑安装，再修改 ${ETC_DIR}/config.json 的端口。${plain}"
    fi
  fi
}

echo -e "${green}开始安装${plain}"
install_base
install_V2bX
