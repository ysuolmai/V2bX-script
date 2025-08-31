#!/bin/bash
red='\033[0;31m' ; green='\033[0;32m' ; yellow='\033[0;33m' ; plain='\033[0m'
cur_dir=$(pwd)

# ---------------- 新增：参数解析（兼容原版将第一个位置参数作为版本号） ----------------
INSTANCE="${INSTANCE:-}"
LEGACY_VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance)
      INSTANCE="$2"; shift 2;;
    *)
      if [[ -z "$LEGACY_VERSION" ]]; then LEGACY_VERSION="$1"; shift; else shift; fi;;
  esac
done
if [[ -n "$INSTANCE" && ! "$INSTANCE" =~ ^[0-9]+$ ]]; then
  echo -e "${red}--instance 只能是数字（例如 2、3、4）${plain}"; exit 1
fi

# ---------------- 根据实例选择目录/服务名/命令名（默认实例完全不变） ----------------
if [[ -z "$INSTANCE" ]]; then
  BIN_DIR="/usr/local/V2bX"
  ETC_DIR="/etc/V2bX"
  SERVICE_BASE="V2bX"
  SERVICE_INITD="/etc/init.d/V2bX"
  SERVICE_SYSTEMD="/etc/systemd/system/V2bX.service"
  CLI_DEFAULT=true
  CLI_NAME="v2bx"
else
  BIN_DIR="/usr/local/V2bX${INSTANCE}"
  ETC_DIR="/etc/V2bX${INSTANCE}"
  SERVICE_BASE="V2bX${INSTANCE}"
  SERVICE_INITD="/etc/init.d/${SERVICE_BASE}"
  SERVICE_SYSTEMD="/etc/systemd/system/${SERVICE_BASE}.service"
  CLI_DEFAULT=false
  CLI_NAME="v2bx${INSTANCE}"
fi

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
if [[ -f /etc/redhat-release ]]; then
  release="centos"
elif cat /etc/issue | grep -Eqi "alpine"; then
  release="alpine"
elif cat /etc/issue | grep -Eqi "debian"; then
  release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
  release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
  release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
  release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
  release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
  release="centos"
elif cat /proc/version | grep -Eqi "arch"; then
  release="arch"
else
  echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

arch=$(uname -m)
if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
  arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
  arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
  arch="s390x"
else
  arch="64"
  echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi
echo "架构: ${arch}"

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
  echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系作者"
  exit 2
fi

# os version
if [[ -f /etc/os-release ]]; then
  os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
  os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi
if [[ x"${release}" == x"centos" ]]; then
  if [[ ${os_version} -le 6 ]]; then
    echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
  fi
  if [[ ${os_version} -eq 7 ]]; then
    echo -e "${red}注意： CentOS 7 无法使用hysteria1/2协议！${plain}\n"
  fi
elif [[ x"${release}" == x"ubuntu" ]]; then
  if [[ ${os_version} -lt 16 ]]; then
    echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
  fi
elif [[ x"${release}" == x"debian" ]]; then
  if [[ ${os_version} -lt 8 ]]; then
    echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
  fi
fi

install_base() {
  if [[ x"${release}" == x"centos" ]]; then
    yum install epel-release wget curl unzip tar crontabs socat ca-certificates -y >/dev/null 2>&1
    update-ca-trust force-enable >/dev/null 2>&1
  elif [[ x"${release}" == x"alpine" ]]; then
    apk add wget curl unzip tar socat ca-certificates >/dev/null 2>&1
    update-ca-certificates >/dev/null 2>&1
  elif [[ x"${release}" == x"debian" ]]; then
    apt-get update -y >/dev/null 2>&1
    apt install wget curl unzip tar cron socat ca-certificates -y >/dev/null 2>&1
    update-ca-certificates >/dev/null 2>&1
  elif [[ x"${release}" == x"ubuntu" ]]; then
    apt-get update -y >/dev/null 2>&1
    apt install wget curl unzip tar cron socat -y >/dev/null 2>&1
    apt-get install ca-certificates wget -y >/dev/null 2>&1
    update-ca-certificates >/dev/null 2>&1
  elif [[ x"${release}" == x"arch" ]]; then
    pacman -Sy --noconfirm >/dev/null 2>&1
    pacman -S --noconfirm --needed wget curl unzip tar cron socat >/dev/null 2>&1
    pacman -S --noconfirm --needed ca-certificates wget >/dev/null 2>&1
  fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
  if [[ ! -f ${BIN_DIR}/V2bX ]]; then
    return 2
  fi
  if [[ x"${release}" == x"alpine" ]]; then
    temp=$(service ${SERVICE_BASE} status | awk '{print $3}')
    if [[ x"${temp}" == x"started" ]]; then return 0; else return 1; fi
  else
    temp=$(systemctl status ${SERVICE_BASE} 2>/dev/null | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
    if [[ x"${temp}" == x"running" ]]; then return 0; else return 1; fi
  fi
}

install_V2bX() {
  # 二进制目录（按实例隔离）
  if [[ -e ${BIN_DIR}/ ]]; then
    rm -rf ${BIN_DIR}/
  fi
  mkdir -p ${BIN_DIR}/
  cd ${BIN_DIR}/

  # 版本选择：兼容原版逻辑（无实例时也可接受 1 个参数当作版本号）
  if [[ -z "$LEGACY_VERSION" ]]; then
    last_version=$(curl -Ls "https://api.github.com/repos/wyx2685/V2bX/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ ! -n "$last_version" ]]; then
      echo -e "${red}检测 V2bX 版本失败，可能是超出 Github API 限制，请稍后再试，或手动指定 V2bX 版本安装${plain}"
      exit 1
    fi
    echo -e "检测到 V2bX 最新版本：${last_version}，开始安装"
    wget --no-check-certificate -N --progress=bar -O ${BIN_DIR}/V2bX-linux.zip https://github.com/wyx2685/V2bX/releases/download/${last_version}/V2bX-linux-${arch}.zip
    if [[ $? -ne 0 ]]; then
      echo -e "${red}下载 V2bX 失败，请确保你的服务器能够下载 Github 的文件${plain}"
      exit 1
    fi
  else
    last_version=$LEGACY_VERSION
    url="https://github.com/wyx2685/V2bX/releases/download/${last_version}/V2bX-linux-${arch}.zip"
    echo -e "开始安装 V2bX $LEGACY_VERSION"
    wget --no-check-certificate -N --progress=bar -O ${BIN_DIR}/V2bX-linux.zip ${url}
    if [[ $? -ne 0 ]]; then
      echo -e "${red}下载 V2bX $LEGACY_VERSION 失败，请确保此版本存在${plain}"
      exit 1
    fi
  fi

  unzip V2bX-linux.zip
  rm -f V2bX-linux.zip
  chmod +x V2bX

  # 配置目录（按实例隔离）
  mkdir -p ${ETC_DIR}/
  cp geoip.dat ${ETC_DIR}/ 2>/dev/null
  cp geosite.dat ${ETC_DIR}/ 2>/dev/null

  if [[ x"${release}" == x"alpine" ]]; then
    # OpenRC：按实例命名，并显式指定配置文件
    rm -f ${SERVICE_INITD}
    cat > ${SERVICE_INITD} <<EOF
#!/sbin/openrc-run
name="${SERVICE_BASE}"
description="${SERVICE_BASE}"
command="${BIN_DIR}/V2bX"
command_args="server -c ${ETC_DIR}/config.json"
command_user="root"
pidfile="/run/${SERVICE_BASE}.pid"
command_background="yes"
depend() { need net }
EOF
    chmod +x ${SERVICE_INITD}
    rc-update add ${SERVICE_BASE} default
    echo -e "${green}V2bX ${last_version}${plain} 安装完成，已设置开机自启"
  else
    # systemd：按实例命名，并显式指定配置文件
    rm -f ${SERVICE_SYSTEMD}
    cat > ${SERVICE_SYSTEMD} <<EOF
[Unit]
Description=${SERVICE_BASE} Service
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
WorkingDirectory=${BIN_DIR}/
ExecStart=${BIN_DIR}/V2bX server -c ${ETC_DIR}/config.json
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl stop ${SERVICE_BASE} >/dev/null 2>&1 || true
    systemctl enable ${SERVICE_BASE}
    echo -e "${green}V2bX ${last_version}${plain} 安装完成，已设置开机自启"
  fi

  # 仅当首次无配置时复制模板（避免覆盖你已有配置）
  if [[ ! -f ${ETC_DIR}/config.json ]]; then
    cp config.json ${ETC_DIR}/ 2>/dev/null
    echo -e ""
    echo -e "全新安装${INSTANCE:+（实例 ${INSTANCE}）}，请先参看教程：https://v2bx.v-50.me/，配置必要的内容"
    first_install=true
  else
    if [[ x"${release}" == x"alpine" ]]; then
      service ${SERVICE_BASE} start
    else
      systemctl start ${SERVICE_BASE}
    fi
    sleep 2
    check_status
    echo -e ""
    if [[ $? == 0 ]]; then
      echo -e "${green}${SERVICE_BASE} 重启成功${plain}"
    else
      echo -e "${red}${SERVICE_BASE} 可能启动失败，请使用日志命令查看并对照 wiki。${plain}"
    fi
    first_install=false
  fi

  # 其他可选配置（不存在才拷贝）
  [[ ! -f ${ETC_DIR}/dns.json ]] && cp dns.json ${ETC_DIR}/ 2>/dev/null
  [[ ! -f ${ETC_DIR}/route.json ]] && cp route.json ${ETC_DIR}/ 2>/dev/null
  [[ ! -f ${ETC_DIR}/custom_outbound.json ]] && cp custom_outbound.json ${ETC_DIR}/ 2>/dev/null
  [[ ! -f ${ETC_DIR}/custom_inbound.json ]] && cp custom_inbound.json ${ETC_DIR}/ 2>/dev/null

  # ---------------- 管理脚本安装（关键改动点） ----------------
  if $CLI_DEFAULT ; then
    # 默认实例：保持原样（上游脚本 + v2bx）
    curl -o /usr/bin/V2bX -Ls https://raw.githubusercontent.com/wyx2685/V2bX-script/master/V2bX.sh
    chmod +x /usr/bin/V2bX
    if [ ! -L /usr/bin/v2bx ]; then
      ln -s /usr/bin/V2bX /usr/bin/v2bx
      chmod +x /usr/bin/v2bx
    fi
  else
    # 非默认实例：生成“完整版” v2bxN（上游脚本替换路径/服务名）
    # 先清理旧的 v2bxN / V2bXN（满足“删除原来安装的 v2bx2”的需求）
    rm -f /usr/bin/${CLI_NAME} /usr/bin/${SERVICE_BASE}

    # 1) 拉取上游管理脚本
    curl -o /usr/bin/${SERVICE_BASE} -Ls https://raw.githubusercontent.com/wyx2685/V2bX-script/master/V2bX.sh
    chmod +x /usr/bin/${SERVICE_BASE}

    # 2) 路径与服务名替换（尽量精确）
    sed -i "s#/usr/local/V2bX#${BIN_DIR}#g"                 /usr/bin/${SERVICE_BASE}
    sed -i "s#/etc/V2bX#${ETC_DIR}#g"                       /usr/bin/${SERVICE_BASE}
    sed -i "s#V2bX\.service#${SERVICE_BASE}\.service#g"     /usr/bin/${SERVICE_BASE}
    sed -i "s#SVC=\"V2bX\"#SVC=\"${SERVICE_BASE}\"#g"       /usr/bin/${SERVICE_BASE}
    sed -i "s#SVC='V2bX'#SVC='${SERVICE_BASE}'#g"           /usr/bin/${SERVICE_BASE}
    sed -i "s#\(systemctl \+\w\+ \+\)V2bX\( \|$\)#\1${SERVICE_BASE}\2#g" /usr/bin/${SERVICE_BASE}

    # 3) 软链成 v2bxN
    ln -sf /usr/bin/${SERVICE_BASE} /usr/bin/${CLI_NAME}
    chmod +x /usr/bin/${CLI_NAME}
  fi

  cd $cur_dir
  rm -f install.sh

  echo -e ""
  echo "V2bX 管理脚本使用方法:"
  echo "------------------------------------------"
  if $CLI_DEFAULT ; then
    echo "V2bX - 显示管理菜单 (功能更多)"
    echo "V2bX start|stop|restart|status|enable|disable|log|x25519|generate|update|install|uninstall|version"
  else
    echo "${CLI_NAME} - 显示管理菜单 (与 v2bx 同款，只是作用于实例 ${INSTANCE})"
    echo "${CLI_NAME} start|stop|restart|status|enable|disable|log|x25519|generate|update|install|uninstall|version"
  fi
  echo "------------------------------------------"

  # 首次安装询问是否生成配置文件（仅默认实例保持原行为）
  if [[ $first_install == true && $CLI_DEFAULT == true ]]; then
    read -rp "检测到你为第一次安装V2bX,是否自动直接生成配置文件？(y/n): " if_generate
    if [[ $if_generate == [Yy] ]]; then
      curl -o ./initconfig.sh -Ls https://raw.githubusercontent.com/wyx2685/V2bX-script/master/initconfig.sh
      source initconfig.sh
      rm -f initconfig.sh
      generate_config_file
    fi
  fi
}

echo -e "${green}开始安装${plain}"
install_base
install_V2bX
