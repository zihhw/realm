#!/bin/bash

# 定义变量
CONFIG_FILE="$(dirname "$0")/realm.toml"  # 脚本当前目录下的 realm.toml
SERVICE_NAME="realm.service"  # realm 服务名称

# 检查是否以 root 用户运行
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 用户运行此脚本"
  exit 1
fi

# 显示菜单
function show_menu() {
  echo "=============================="
  echo "          Realm 管理脚本      "
  echo "=============================="
  echo "1. 添加转发规则"
  echo "2. 删除转发规则"
  echo "3. 查看已有规则"
  echo "0. 退出并重启服务"
  echo "=============================="
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

# 添加转发规则
function add_rule() {
  while true; do
    read -p "请输入本机端口（例如 2005）: " LOCAL_PORT
    if [[ $LOCAL_PORT =~ ^[0-9]+$ ]]; then
      break
    else
      echo "错误：本机端口必须是数字"
    fi
  done

  while true; do
    read -p "请输入远程地址（例如 1.1.1.1:443）: " REMOTE
    if validate_ip_port "$REMOTE"; then
      break
    else
      echo "错误：远程地址格式无效，请输入 IP:端口"
    fi
  done

  read -p "请输入规则别名（例如 游戏服务器）: " ALIAS

  # 检查端口是否已存在
  if grep -q "listen = \"0.0.0.0:$LOCAL_PORT\"" "$CONFIG_FILE"; then
    echo "错误：本机端口 $LOCAL_PORT 已存在"
    return
  fi

  # 添加规则到配置文件
  echo -e "\n[[endpoints]]" >> "$CONFIG_FILE"
  echo "alias = \"$ALIAS\"" >> "$CONFIG_FILE"
  echo "listen = \"0.0.0.0:$LOCAL_PORT\"" >> "$CONFIG_FILE"
  echo "remote = \"$REMOTE\"" >> "$CONFIG_FILE"
  echo "已添加转发规则：$ALIAS -- 0.0.0.0:$LOCAL_PORT -> $REMOTE"
}

# 删除转发规则
function remove_rule() {
  # 获取所有转发规则
  RULES=($(grep -A 2 "\[\[endpoints\]\]" "$CONFIG_FILE" | grep "alias" | cut -d '"' -f 2))

  if [ ${#RULES[@]} -eq 0 ]; then
    echo "错误：没有找到任何转发规则"
    return
  fi

  # 显示规则列表
  echo "请选择要删除的转发规则："
  for i in "${!RULES[@]}"; do
    echo "$((i+1)). ${RULES[$i]}"
  done

  # 读取用户输入
  read -p "请输入规则编号 (1-${#RULES[@]}): " CHOICE

  # 检查输入是否有效
  if [[ ! $CHOICE =~ ^[0-9]+$ ]] || [ $CHOICE -lt 1 ] || [ $CHOICE -gt ${#RULES[@]} ]; then
    echo "错误：无效的选择"
    return
  fi

  # 获取选择的规则
  SELECTED_RULE="${RULES[$((CHOICE-1))]}"

  # 备份配置文件
  cp "$CONFIG_FILE" "$CONFIG_FILE.bak"

  # 使用awk删除指定的块
  awk -v del_alias="$SELECTED_RULE" '
    /\[\[endpoints\]\]/ {
      if (block != "") {
        print block
      }
      block = ""
      delete_flag = 0
    }
    /alias = "'"$SELECTED_RULE"'"/ {
      delete_flag = 1
    }
    {
      if (!delete_flag) {
        block = block $0 "\n"
      }
    }
    END {
      if (block != "" && !delete_flag) {
        print block
      }
    }
  ' "$CONFIG_FILE" > "$CONFIG_FILE.new" && mv "$CONFIG_FILE.new" "$CONFIG_FILE"

  # 删除多余的空白行
  sed -i '/^$/d' "$CONFIG_FILE"

  echo "已删除转发规则：$SELECTED_RULE"
}

# 查看已有规则
function show_rules() {
  # 检查配置文件是否存在
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "错误：配置文件 $CONFIG_FILE 不存在"
    return
  fi

  # 获取所有转发规则
  RULES=($(awk '
    /\[\[endpoints\]\]/ {
      if (alias != "" || listen != "" || remote != "") {
        print alias, listen, remote
      }
      alias = ""
      listen = ""
      remote = ""
    }
    /alias = / {
      alias = $3
      gsub(/"/, "", alias)
    }
    /listen = / {
      listen = $3
      gsub(/"/, "", listen)
    }
    /remote = / {
      remote = $3
      gsub(/"/, "", remote)
    }
    END {
      if (alias != "" || listen != "" || remote != "") {
        print alias, listen, remote
      }
    }
  ' "$CONFIG_FILE"))

  if [ ${#RULES[@]} -eq 0 ]; then
    echo "没有找到任何转发规则"
    return
  fi

  echo "已添加的转发规则："
  for ((i=0; i<${#RULES[@]}; i+=3)); do
    ALIAS="${RULES[$i]}"
    LISTEN="${RULES[$((i+1))]}"
    REMOTE="${RULES[$((i+2))]}"
    if [[ -z "$ALIAS" ]]; then
      ALIAS="未命名规则"
    fi
    echo "$ALIAS -- $LISTEN ==> $REMOTE"
  done
}

# 重启 realm 服务
function restart_realm() {
  echo "重启 realm 服务..."
  systemctl restart $SERVICE_NAME
  systemctl status $SERVICE_NAME --no-pager
}

# 主循环
while true; do
  show_menu
  read -p "请输入选项 (0-3): " OPTION

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
    0)
      echo "退出脚本并重启服务..."
      restart_realm
      break
      ;;
    *)
      echo "错误：无效的选项"
      ;;
  esac

  # 按任意键继续
  read -p "按任意键继续..." -n 1
  echo
done

