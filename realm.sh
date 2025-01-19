#!/bin/bash

# 定义变量
REALM_VERSION="v2.4.5"  # 替换为最新的 realm 版本
REALM_URL="https://github.com/zhboner/realm/releases/download/${REALM_VERSION}/realm-x86_64-unknown-linux-gnu.tar.gz"
REALM_BIN="/usr/local/bin/realm"
CONFIG_FILE="/etc/realm/realm.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"
SERVICE_NAME="realm.service"

# 颜色定义
GREEN='\033[0;32m'
NC='\033[0m'  # 重置颜色

# 分隔线定义
SEPARATOR="=============================="

# 检查是否以 root 用户运行
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 用户运行此脚本"
  exit 1
fi

# 安装依赖
function install_dependencies() {
  echo "安装依赖：wget 和 tar..."
  apt-get update && apt-get install -y wget tar
}

# 下载并安装 realm
function install_realm() {
  echo "下载 realm..."
  wget -O /tmp/realm.tar.gz "$REALM_URL"
  if [ $? -ne 0 ]; then
    echo "错误：下载 realm 失败"
    exit 1
  fi

  echo "解压 realm..."
  tar -xzf /tmp/realm.tar.gz -C /tmp
  if [ $? -ne 0 ]; then
    echo "错误：解压 realm 失败"
    exit 1
  fi

  echo "安装 realm 到 /usr/local/bin..."
  mv /tmp/realm "$REALM_BIN"
  chmod +x "$REALM_BIN"
}

# 创建配置文件目录和默认配置
function create_config() {
  echo "创建配置文件目录 /etc/realm..."
  mkdir -p /etc/realm

  echo "创建默认的 realm.toml 配置文件..."
  cat <<EOF > "$CONFIG_FILE"
[network]
no_tcp = false
use_udp = true
EOF
}

# 创建 systemd 服务文件
function create_service() {
  echo "创建 systemd 服务文件..."
  cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Realm - A simple and fast relay tool
After=network.target

[Service]
ExecStart=$REALM_BIN -c $CONFIG_FILE
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

  echo "重新加载 systemd 配置..."
  systemctl daemon-reload

  echo "启动并启用 realm 服务..."
  systemctl start realm
  systemctl enable realm

  echo "检查 realm 服务状态..."
  systemctl status realm --no-pager
}

# 显示管理菜单
function show_menu() {
  echo "$SEPARATOR"
  echo "          Realm 管理脚本      "
  echo "$SEPARATOR"
  echo "1. 添加转发规则"
  echo "2. 删除转发规则"
  echo "3. 查看已有规则"
  echo "4. 卸载 realm"
  echo "0. 退出并重启服务"
  echo "$SEPARATOR"
}

# 检查 IP:端口 格式是否有效
function validate_ip_port() {
  local input=$1
  if [[ $input =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
    return 0
  else
    return 1
  fi
}

# 检查端口是否被占用
function is_port_used() {
  local port=$1
  if ss -tuln | grep -q ":$port "; then
    return 0  # 端口已被占用
  else
    return 1  # 端口未被占用
  fi
}

# 添加转发规则
function add_rule() {
  while true; do
    echo "$SEPARATOR"
    echo "          添加转发规则        "
    echo "$SEPARATOR"

    while true; do
      read -p "请输入转发端口（1-65535）: " FORWARD_PORT
      if [[ $FORWARD_PORT =~ ^[0-9]+$ ]] && [ $FORWARD_PORT -ge 1 ] && [ $FORWARD_PORT -le 65535 ]; then
        if is_port_used "$FORWARD_PORT"; then
          echo "错误：转发端口 $FORWARD_PORT 已被占用"
        else
          break
        fi
      else
        echo "错误：转发端口必须是 1-65535 之间的数字"
      fi
    done

    while true; do
      read -p "请输入欲转发地址（例如 1.1.1.1:443）: " TARGET_ADDRESS
      if validate_ip_port "$TARGET_ADDRESS"; then
        break
      else
        echo "错误：欲转发地址格式无效，请输入 IP:端口"
      fi
    done

    read -p "请输入规则别名（例如 游戏服务器）: " ALIAS

    # 检查端口是否已存在
    if grep -q "listen = \"0.0.0.0:$FORWARD_PORT\"" "$CONFIG_FILE"; then
      echo "错误：转发端口 $FORWARD_PORT 已存在"
      return
    fi

    # 添加规则到配置文件
    echo -e "\n[[endpoints]]" >> "$CONFIG_FILE"
    echo "alias = \"$ALIAS\"" >> "$CONFIG_FILE"
    echo "listen = \"0.0.0.0:$FORWARD_PORT\"" >> "$CONFIG_FILE"
    echo "remote = \"$TARGET_ADDRESS\"" >> "$CONFIG_FILE"
    echo "已添加转发规则：$ALIAS -- 0.0.0.0:$FORWARD_PORT -> $TARGET_ADDRESS"

    # 询问是否继续添加
    read -p "是否继续添加规则？(y/n): " CONTINUE
    if [[ $CONTINUE != "y" && $CONTINUE != "Y" ]]; then
      break
    fi
  done
}

# 删除转发规则
function remove_rule() {
  while true; do
    # 获取所有转发规则
    RULES=($(grep -n '\[\[endpoints\]\]' "$CONFIG_FILE" | cut -d ':' -f 1))

    if [ ${#RULES[@]} -eq 0 ]; then
      echo "错误：没有找到任何转发规则"
      return
    fi

    # 显示规则列表
    echo "$SEPARATOR"
    echo "          删除转发规则        "
    echo "$SEPARATOR"
    echo "请选择要删除的转发规则："
    for i in "${!RULES[@]}"; do
      ALIAS=$(sed -n "$((RULES[i]+1))p" "$CONFIG_FILE" | grep "alias" | cut -d '"' -f 2)
      LISTEN=$(sed -n "$((RULES[i]+2))p" "$CONFIG_FILE" | grep "listen" | cut -d '"' -f 2)
      REMOTE=$(sed -n "$((RULES[i]+3))p" "$CONFIG_FILE" | grep "remote" | cut -d '"' -f 2)
      echo "$((i+1)). $ALIAS -- $LISTEN -> $REMOTE"
    done
    echo "$SEPARATOR"
    read -p "请输入选项 (回车返回): " CHOICE

    # 如果用户直接按回车，则返回
    if [[ -z $CHOICE ]]; then
      return
    fi

    # 检查输入是否有效
    if [[ ! $CHOICE =~ ^[0-9]+$ ]] || [ $CHOICE -lt 1 ] || [ $CHOICE -gt ${#RULES[@]} ]; then
      echo "错误：无效的选择"
      continue
    fi

    # 获取选择的规则
    SELECTED_RULE_LINE=${RULES[$((CHOICE-1))]}

    # 备份配置文件
    cp "$CONFIG_FILE" "$CONFIG_FILE.bak"

    # 使用sed删除指定的块
    sed -i "$((SELECTED_RULE_LINE)),$((SELECTED_RULE_LINE+3))d" "$CONFIG_FILE"

    # 删除多余的空白行
    sed -i '/^$/d' "$CONFIG_FILE"

    if [ $? -eq 0 ]; then
      echo "删除成功。"
    else
      echo "删除失败。以下是 systemctl 的状态信息："
      systemctl status $SERVICE_NAME --no-pager
    fi
  done
}

# 查看已有规则
function show_rules() {
  while true; do
    # 检查配置文件是否存在
    if [ ! -f "$CONFIG_FILE" ]; then
      echo "错误：配置文件 $CONFIG_FILE 不存在"
      return
    fi

    # 获取所有转发规则
    RULES=($(grep -n '\[\[endpoints\]\]' "$CONFIG_FILE" | cut -d ':' -f 1))

    if [ ${#RULES[@]} -eq 0 ]; then
      echo "没有找到任何转发规则"
      return
    fi

    # 显示规则列表
    echo "$SEPARATOR"
    echo "          查看已有规则        "
    echo "$SEPARATOR"
    echo "已添加的转发规则："
    for i in "${!RULES[@]}"; do
      ALIAS=$(sed -n "$((RULES[i]+1))p" "$CONFIG_FILE" | grep "alias" | cut -d '"' -f 2)
      LISTEN=$(sed -n "$((RULES[i]+2))p" "$CONFIG_FILE" | grep "listen" | cut -d '"' -f 2)
      REMOTE=$(sed -n "$((RULES[i]+3))p" "$CONFIG_FILE" | grep "remote" | cut -d '"' -f 2)
      echo "$((i+1)). $ALIAS -- $LISTEN ==> $REMOTE"
    done
    echo "$SEPARATOR"
    read -p "请输入选项 (回车返回): " CHOICE

    # 如果用户直接按回车，则返回
    if [[ -z $CHOICE ]]; then
      return
    fi

    # 检查输入是否有效
    if [[ $CHOICE != "0" ]]; then
      echo "错误：无效的选择"
      continue
    fi

    # 返回主菜单
    return
  done
}

# 重启 realm 服务
function restart_realm() {
  systemctl restart $SERVICE_NAME
  if [ $? -eq 0 ]; then
    echo "重启 realm 服务成功。"
  else
    echo "重启失败。以下是 systemctl 的状态信息："
    systemctl status $SERVICE_NAME --no-pager
  fi
}

# 卸载 realm
function uninstall_realm() {
  read -p "确定要卸载 realm 吗？(y/n): " CONFIRM
  if [[ $CONFIRM != "y" && $CONFIRM != "Y" ]]; then
    echo "卸载已取消。"
    return
  fi

  echo "停止 realm 服务..."
  systemctl stop $SERVICE_NAME
  if [ $? -ne 0 ]; then
    echo "停止服务失败。以下是 systemctl 的状态信息："
    systemctl status $SERVICE_NAME --no-pager
    return 1
  fi

  echo "禁用 realm 服务..."
  systemctl disable $SERVICE_NAME
  if [ $? -ne 0 ]; then
    echo "禁用服务失败。以下是 systemctl 的状态信息："
    systemctl status $SERVICE_NAME --no-pager
    return 1
  fi

  echo "删除 realm 二进制文件..."
  rm -f "$REALM_BIN"
  if [ $? -ne 0 ]; then
    echo "删除二进制文件失败。"
    return 1
  fi

  echo "删除配置文件..."
  rm -rf "/etc/realm"
  if [ $? -ne 0 ]; then
    echo "删除配置文件失败。"
    return 1
  fi

  echo "删除 systemd 服务文件..."
  rm -f "$SERVICE_FILE"
  if [ $? -ne 0 ]; then
    echo "删除 systemd 服务文件失败。"
    return 1
  fi

  echo "重新加载 systemd 配置..."
  systemctl daemon-reload
  if [ $? -ne 0 ]; then
    echo "重新加载 systemd 配置失败。"
    return 1
  fi

  echo "realm 已卸载完成！"
}

# 主安装函数
function install_and_setup() {
  install_dependencies
  install_realm
  create_config
  create_service
  echo "realm 安装和配置完成！"
}

# 主管理循环
function manage_realm() {
  while true; do
    show_menu
    read -p "请输入选项 (0-4): " OPTION

    case $OPTION in
      1)
        add_rule
        ;;
      2)
        remove_rule
        ;;
      3)
        show_rules
        ;;
      4)
        uninstall_realm
        break
        ;;
      0)
        echo "退出脚本并重启服务..."
        restart_realm
        break
        ;;
      *)
        echo "错误：无效的选项"
        ;;
    esac

    # 按任意键继续（仅在主菜单显示）
    if [[ $OPTION -ne 1 && $OPTION -ne 2 && $OPTION -ne 3 ]]; then
      read -p "按任意键继续..." -n 1
      echo
    fi
  done
}

# 主逻辑
if [ ! -f "$REALM_BIN" ]; then
  echo "realm 未安装，开始安装..."
  install_and_setup
else
  echo "realm 已安装，进入管理菜单..."
fi

manage_realm
