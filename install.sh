cat > /www/wwwroot/deploy_napcat.sh <<'EOF'
#!/bin/bash
set -e
cd /www/wwwroot

IMAGE="810331109:latest"
IMG_URL=$(echo "aHR0cDovLzE3NS4xNzguODguMjA1OjE1MjQ0L2QvJUU4JTgxJTk0JUU5JTgwJTlBJUU0JUJBJTkxJUU3JTlCJTk4L0xpbnV4JUU1JUI3JUE1JUU1JTg1JUI3L0xpbnV4UVElRTYlOUMlQkElRTUlOTklQTglRTQlQkElQkEvTmFwQ2F0JUU3JTg5JTg4JUU2JTlDJUFDNC4xOC40JUU5JTk1JTlDJUU1JTgzJThGLnRhcg==" | base64 -d)
PLUGIN_URL=$(echo "aHR0cDovLzE3NS4xNzguODguMjA1OjE1MjQ0L2QvJUU4JTgxJTk0JUU5JTgwJTlBJUU0JUJBJTkxJUU3JTlCJTk4L0xpbnV4JUU1JUI3JUE1JUU1JTg1JUI3L0xpbnV4UVElRTYlOUMlQkElRTUlOTklQTglRTQlQkElQkEvJUU2JThGJTkyJUU0JUJCJUI2Mi56aXA=" | base64 -d)
BASE="/www/napcat"
SELF="/www/wwwroot/deploy_napcat.sh"

# === 自动选择下载器 ===
WGET_VER=$(wget --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
WGET_MAJOR=$(echo "$WGET_VER" | cut -d. -f1)
WGET_MINOR=$(echo "$WGET_VER" | cut -d. -f2)
USE_WGET_PROGRESS=0
if [ -n "$WGET_MAJOR" ] && [ -n "$WGET_MINOR" ]; then
  if [ "$WGET_MAJOR" -gt 1 ] || { [ "$WGET_MAJOR" -eq 1 ] && [ "$WGET_MINOR" -ge 16 ]; }; then
    USE_WGET_PROGRESS=1
  fi
fi

if [ "$USE_WGET_PROGRESS" -eq 1 ]; then
  echo "（下载器：wget $WGET_VER）"
  DL() { wget -q --show-progress -c -O "$1" "$2"; }
else
  command -v aria2c >/dev/null 2>&1 || yum install -y aria2 >/dev/null 2>&1 || true
  if command -v aria2c >/dev/null 2>&1; then
    echo "（下载器：aria2c，wget 版本过老不支持进度，自动切换）"
    # 【修改说明】用管道过滤 aria2c 的输出，只保留带有百分比的一行，并原地刷新
    DL() { 
      aria2c -x 4 -s 4 -c --summary-interval=1 --file-allocation=none -d "$(dirname "$1")" -o "$(basename "$1")" "$2" 2>&1 | \
      grep --line-buffered -oE '\[#[a-zA-Z0-9]+\s+[0-9.]+[KMG]iB/[0-9.]+[KMG]iB\([0-9]+%\).*ETA:[0-9smh]+\]' | \
      while read -r line; do
        printf "\r\033[K%s" "$line"
      done
      echo ""
    }
  else
    echo "（下载器：wget 静默模式，无进度条）"
    DL() { wget -q -c -O "$1" "$2"; }
  fi
fi

echo "==== [1/6] 创建挂载目录 ===="
mkdir -p "$BASE/QQ" "$BASE/config" "$BASE/plugins" "$BASE/cache"

echo "==== [2/6] 检查/导入镜像 ===="
if ! docker images | grep -q "810331109"; then
  echo "本地无镜像，开始下载..."
  DL /www/wwwroot/NapCat.tar "$IMG_URL"
  echo "下载完成，开始导入..."
  docker load -i /www/wwwroot/NapCat.tar
  echo "导入完成，删除镜像 tar 包..."
  rm -f /www/wwwroot/NapCat.tar
else
  echo "本地已存在镜像，跳过下载导入。"
fi

echo "==== [3/6] 下载并解压插件 ===="
if DL "$BASE/plugin.zip" "$PLUGIN_URL"; then
  rm -rf "$BASE/plugins"/*
  unzip -o "$BASE/plugin.zip" -d "$BASE/plugins/" >/dev/null
  echo "插件目录内容："
  ls -la "$BASE/plugins/"
  rm -f "$BASE/plugin.zip"
else
  echo "? 插件下载失败（链接可能失效），跳过插件步骤，继续启动容器..."
fi

echo "==== [4/6] 启动容器 ===="
docker rm -f napcat 2>/dev/null || true

docker run -d \
  --name napcat \
  --restart=always \
  -e NAPCAT_GID=$(id -g) \
  -e NAPCAT_UID=$(id -u) \
  -p 3000:3000 \
  -p 3001:3001 \
  -p 6099:6099 \
  -v "$BASE/QQ:/app/.config/QQ" \
  -v "$BASE/config:/app/napcat/config" \
  -v "$BASE/plugins:/app/napcat/plugins" \
  -v "$BASE/cache:/app/napcat/cache" \
  "$IMAGE"

echo "==== [5/6] 等待 NapCat 生成 WebUI Token ===="
TOKEN=""
for i in $(seq 1 60); do
  TOKEN=$(docker logs napcat 2>&1 | grep -oE "WebUi Token: [a-zA-Z0-9]+" | head -n1 | awk '{print $3}')
  if [ -n "$TOKEN" ]; then
    break
  fi
  sleep 1
done

if [ -n "$TOKEN" ]; then
  echo "$TOKEN" > "$BASE/webui_token.txt"
fi

echo "==== [6/6] 获取公网 IP 并输出访问地址 ===="
SERVER_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 ip.sb || curl -s --max-time 5 cip.cc | awk '/IP/{print $3}')
[ -z "$SERVER_IP" ] && SERVER_IP="<你的服务器公网IP>"

echo ""
echo "==============================================="
echo "  NapCat 部署完成"
echo "==============================================="
if [ -n "$TOKEN" ]; then
  echo "  WebUI 地址:  （访问地址）: http://$SERVER_IP:6099/"
  echo "  WebUI Token（登录密码）: $TOKEN"
  echo "  如需定时重启. （脚本内容）: docker restart napcat"
else
  echo "  ? 未在日志中抓到 Token，请稍后手动执行："
  echo "     docker logs napcat | grep 'WebUi Token'"
fi
echo "==============================================="

echo "===完成==="
rm -f "$SELF"
EOF

chmod +x /www/wwwroot/deploy_napcat.sh
/www/wwwroot/deploy_napcat.sh
