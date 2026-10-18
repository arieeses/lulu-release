# lulu

多协议代理节点后端（闭源，二进制发布）。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/arieeses/lulu-release/main/lulu.sh) install
```

安装后默认开机自启。编辑 `/etc/lulu/config.yml` 填好面板 ApiHost / ApiKey / NodeID，然后：

```bash
lulu.sh restart
```

## 常用命令

```
lulu.sh start|stop|restart|status|log
lulu.sh enable|disable        # 开机自启开关
lulu.sh version               # 查看版本
lulu.sh update                # 更新到最新发布版
lulu.sh uninstall             # 卸载（保留 /etc/lulu 配置）
lulu.sh bbr                   # 开启 BBR
lulu.sh swap [SIZE]           # 开启 zswap + SWAP（默认 1G）
lulu.sh haproxy install|start|stop|restart|uninstall [URL]
```

直接运行 `sudo lulu.sh` 进入交互菜单。
