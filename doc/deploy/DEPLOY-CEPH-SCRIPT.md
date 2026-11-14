# deploy-ceph.py 使用教程

用 Python 脚本部署 Ceph 集群，支持 **单节点** 和 **多节点**，自动创建：

- mon（1 个或多个）
- mgr（1 个或多个）
- rgw（可选，1 个或多个）
- osd（ceph-volume + LVM + BlueStore）
- 可选：把整块磁盘自动分成 N 个分区再做 OSD
- 销毁集群：停止服务、移除 OSD、清理数据和配置

脚本只依赖 Python 标准库（需要 Python 3.11+ 的 `tomllib`），Ceph 使用 RPM 安装。
手工部署的完整原理见 [DEPLOY-CEPH-CLUSTER.md](DEPLOY-CEPH-CLUSTER.md)。

---

## 1. 文件说明

| 文件 | 用途 |
| --- | --- |
| `script/deploy-ceph.py` | 部署/销毁脚本 |
| `conf/deploy-ceph.toml` | 单节点示例配置（4 个 OSD 分区） |
| `conf/deploy-ceph-multi.toml` | 3 节点示例配置 |
| `conf/deploy-ceph.state.json` | 首次 `--apply` 后自动生成，保存集群 fsid |

> `*.state.json` 与配置文件同目录，按配置文件名生成，例如
> `conf/deploy-ceph-multi.toml` 对应 `conf/deploy-ceph-multi.state.json`。
> **部署后请保留该文件**，重复执行时靠它复用同一个 fsid。
> 该文件已被 `.gitignore` 忽略，不会被提交。

---

## 2. 前置条件

### 2.1 所有节点

1. 已安装同版本的 Ceph RPM（至少包含 `ceph`、`ceph-mon`、`ceph-mgr`、
   `ceph-radosgw`、`ceph-volume`）。

   本仓库可以用 [build-ceph.sh](../build/BUILD-CEPH.md) 构建并安装：

   ```bash
   ./script/build-ceph.sh --rpm        # 构建 RPM
   ./script/build-ceph.sh --install    # 在当前节点安装
   ```

   多节点时，在每台节点上分别安装同版本的 RPM。不要把不同版本混用。

2. 主机名唯一，节点之间能用 IP 互通；建议配置 `/etc/hosts` 或 DNS。
3. 时间同步（`chronyd`）正常，避免 cephx 认证因时间偏差失败。
4. OSD 使用**专用磁盘/分区**，上面的数据会被清空。
5. 部署机需要 Python 3.11+：

   ```bash
   python3 --version
   ```

6. 如果机器上同时装了源码版和 RPM 版 Ceph，部署时建议优先使用 RPM 命令：

   ```bash
   export PATH=/usr/bin:$PATH
   command -v ceph        # 应输出 /usr/bin/ceph
   ```

### 2.2 多节点额外要求

1. 在部署机（admin 节点）上配置到所有节点的 root 免密 SSH：

   ```bash
   ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519   # 已有可跳过
   ssh-copy-id root@10.0.0.11
   ssh-copy-id root@10.0.0.12
   ssh-copy-id root@10.0.0.13
   ssh root@10.0.0.11 hostname -s                     # 验证
   ```

2. 如果使用非 root 用户，需要该用户能 `sudo -n`（免密码 sudo），
   并在配置里写 `ssh_user = "youruser"`。

### 2.3 防火墙

按需放行：

```bash
firewall-cmd --permanent --add-port=3300/tcp     # mon msgr2
firewall-cmd --permanent --add-port=6789/tcp     # mon msgr1（兼容）
firewall-cmd --permanent --add-port=6800-7300/tcp # OSD
firewall-cmd --permanent --add-port=7480/tcp     # RGW（按实际端口）
firewall-cmd --reload
```

如果实验环境直接关闭了 firewalld，可忽略本节。

---

## 3. 单节点快速开始

以本机 `openeuler2403`（192.168.1.10）、`/dev/sda` 已分好 4 个区为例，
配置见 `conf/deploy-ceph.toml`。

### 3.1 编辑配置

```toml
[cluster]
public_network = "192.168.1.0/24"
cluster_network = "192.168.1.0/24"
pool_size = 2
pool_min_size = 1
pg_num = 64
wipe_devices = false          # 需要清空磁盘签名时改成 true

[[node]]
name = "openeuler2403"
address = "192.168.1.10"
mon = true
mgr = true
rgw = true
rgw_port = 7480
osd_devices = ["/dev/sda1", "/dev/sda2", "/dev/sda3", "/dev/sda4"]
```

如果磁盘还没分区，可以改成自动分区（**会清空整块盘**）：

```toml
[[node]]
name = "openeuler2403"
address = "192.168.1.10"
mon = true
mgr = true
rgw = true
rgw_port = 7480

[node.partition]
disk = "/dev/sda"
count = 4
```

> `[node.partition]` 必须紧跟在对应的 `[[node]]` 后面，并且不能同时配置
> `osd_devices`，二者只能选一个。

### 3.2 预演（默认）

```bash
cd /root/ceph
./script/deploy-ceph.py -c conf/deploy-ceph.toml
```

只打印节点、角色、ID、OSD 设备和 fsid 计划，**不做任何变更**。
此时 fsid 显示为 `(将自动生成)`。

### 3.3 预检查

```bash
./script/deploy-ceph.py -c conf/deploy-ceph.toml --check
```

检查内容：

- 本机 Ceph 命令是否齐全
- SSH 是否可达（多节点）
- 目标节点上的 Ceph 命令是否齐全
- 分区模式下的磁盘是否为块设备、是否被挂载、分区表是否符合预期
- OSD 设备是否存在、是否已被 OSD 使用

看到 `预检查通过` 后再执行下一步。

### 3.4 正式部署

```bash
sudo ./script/deploy-ceph.py -c conf/deploy-ceph.toml --apply
```

`--apply` 需要 root。脚本会依次完成：

1. 生成（或从 state 文件读取）fsid
2. 生成 admin/mon 密钥和 monmap，写入 `/etc/ceph/ceph.conf`
3. 初始化并启动 mon，等待 quorum
4. 创建 mgr 密钥并启动 mgr
5. 创建 `client.bootstrap-osd` 密钥
6. 对每个 OSD 设备执行 `ceph-volume lvm create --bluestore`
7. 创建 `.rgw.root` 池、realm/zonegroup/zone，提交 period，启动 rgw，
   并为 RGW 相关池启用 `rgw` 应用标签
8. 输出 `ceph -s` 和各节点 systemd 服务状态

部署完成后会提示 `部署完成`。

### 3.5 验证

```bash
ceph -s
ceph osd tree
systemctl is-active ceph-mon@a ceph-mgr@a ceph-radosgw@rgw.openeuler2403
ss -ltn | grep 7480
```

预期：`HEALTH_OK`，4 个 OSD `up/in`，三个服务都是 `active`，7480 端口在监听。

---

## 4. 多节点快速开始

以 3 台机器为例（`conf/deploy-ceph-multi.toml`）：

- `ceph1` 10.0.0.11：mon + mgr + 2 OSD
- `ceph2` 10.0.0.12：mon + mgr + 2 OSD
- `ceph3` 10.0.0.13：mon + rgw + 2 OSD

### 4.1 配置

```toml
[cluster]
public_network = "10.0.0.0/24"
cluster_network = "10.0.0.0/24"
pool_size = 2
pool_min_size = 1
pg_num = 64
wipe_devices = true           # 专用盘，允许清空签名
rgw_realm = "default"

[[node]]
name = "ceph1"
address = "10.0.0.11"
mon = true
mgr = true
osd_devices = ["/dev/sdb", "/dev/sdc"]

[[node]]
name = "ceph2"
address = "10.0.0.12"
mon = true
mgr = true
osd_devices = ["/dev/sdb", "/dev/sdc"]

[[node]]
name = "ceph3"
address = "10.0.0.13"
mon = true
rgw = true
rgw_port = 7480
osd_devices = ["/dev/sdb", "/dev/sdc"]
```

也可以给某个节点换成自动分区：

```toml
[[node]]
name = "ceph3"
address = "10.0.0.13"
mon = true
rgw = true
rgw_port = 7480

[node.partition]
disk = "/dev/sdb"
count = 4
```

### 4.2 检查并部署

在 admin 节点执行：

```bash
./script/deploy-ceph.py -c conf/deploy-ceph-multi.toml --check
sudo ./script/deploy-ceph.py -c conf/deploy-ceph-multi.toml --apply
```

脚本会自动：

- 按配置顺序分配 mon id：`a`、`b`、`c`
- 分配 mgr id：`a`、`b`
- 生成 rgw id：`rgw.ceph3`
- 在各自节点上启动对应服务

### 4.3 验证

```bash
ceph -s
ceph osd tree
ceph quorum_status -f json_pretty | head -20
```

在各节点分别检查：

```bash
systemctl is-active ceph-mon@a ceph-mgr@a        # ceph1
systemctl is-active ceph-mon@b ceph-mgr@b        # ceph2
systemctl is-active ceph-mon@c ceph-radosgw@rgw.ceph3  # ceph3
```

RGW 入口：`http://10.0.0.13:7480`。

---

## 5. 配置项说明

### 5.1 `[cluster]`

| 字段 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- |
| `fsid` | 否 | 自动生成 | 集群 UUID。固定后可脱离 state 文件复现 |
| `public_network` | 否 | 由第一个节点地址推导 `/24` | 公网段 |
| `cluster_network` | 否 | 同 `public_network` | 集群网段 |
| `pool_size` | 否 | `2` | 默认副本数 |
| `pool_min_size` | 否 | `1` | 最小可用副本数 |
| `pg_num` | 否 | `64` | 新池默认 PG 数 |
| `wipe_devices` | 否 | `false` | 是否对 OSD 设备执行 `wipefs -a` |
| `rgw_realm` | 否 | `default` | RGW realm/zonegroup/zone 名称 |

> 单机部署时脚本会自动加 `osd crush chooseleaf type = 0`，按 OSD 而不是按
> host 做故障域；多机部署不会加。`pool_size=2` 在单机上只防 OSD 故障，
> 不防整机故障。

### 5.2 `[[node]]`

| 字段 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- |
| `name` | 否 | `node1`... | 节点名，也用于生成 rgw id |
| `address` | 是 | - | 节点 IP |
| `ssh_user` | 否 | `root` | SSH 用户 |
| `ssh_port` | 否 | `22` | SSH 端口 |
| `mon` | 否 | `false` | 是否部署 mon |
| `mgr` | 否 | `false` | 是否部署 mgr |
| `rgw` | 否 | `false` | 是否部署 rgw |
| `rgw_port` | 否 | `7480` | rgw 监听端口 |
| `osd_devices` | 否 | `[]` | OSD 设备/分区列表 |
| `[node.partition]` | 否 | - | 自动分区，见下 |

### 5.3 `[node.partition]`

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `disk` | 是 | 整块磁盘，如 `/dev/sda`、`/dev/nvme0n1` |
| `count` | 是 | 分成几个分区，即几个 OSD |

限制与保护：

- 与 `osd_devices` 互斥
- 磁盘必须是块设备
- 磁盘上已有分区被挂载时直接拒绝
- 已有分区数量和名称与配置不一致时拒绝（避免误清数据）
- 分区名为 `osd1`...`osdN`；整盘会先 `mklabel gpt`

### 5.4 角色规则

- 至少一个 `mon = true`
- mon 数量建议为奇数（1/3/5）；偶数会打印警告
- mgr 至少一个；多个 mgr 会自动主备
- rgw 可选；id 固定为 `rgw.<name>`
- OSD 设备必须存在且未被其他集群占用

---

## 6. 幂等与安全机制

### 6.1 默认不改系统

| 命令 | 行为 |
| --- | --- |
| 不带参数 | dry-run，只打印部署计划 |
| `--check` | 部署前只读检查，不做变更 |
| `--apply` | 真正部署，需要 root |
| `--destroy` | dry-run，只打印销毁计划 |
| `--destroy --check` | 销毁前只读检查 |
| `--destroy --apply` | 真正销毁，需要 root |

### 6.2 重复执行

脚本可以重复执行：

- state 文件中已有 fsid 时继续使用
- mon 数据目录已存在时跳过 `--mkfs`
- 已存在的 mon/mgr/rgw 密钥直接复用，不会覆盖成新密钥
- `ceph-volume lvm list` 中已有的设备会跳过
- 已有 OSD 不会重复创建

因此调整配置（例如增加 OSD、增加 rgw）后可以再次 `--apply`。

### 6.3 fsid 与 state 文件

首次 `--apply` 会在配置文件同目录生成 `conf/deploy-ceph.state.json`：

```json
{
  "fsid": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

如果 state 文件丢失，可把 `ceph fsid` 的输出写回 TOML 的 `[cluster] fsid`，
或直接恢复该文件。否则再次 `--apply` 会生成新 fsid，并被安全保护拦下。

### 6.4 已有集群保护

如果节点上已经有一个运行中的集群，且 fsid 与目标不同，脚本会拒绝执行：

```text
节点 xxx 上已有一个运行中的集群（fsid=...），与目标 fsid=... 不同。
确认要覆盖请加 --force
```

`--force` 会覆盖目标节点的 `/etc/ceph/ceph.conf` 和 admin keyring，
**仅用于确认要重建的实验环境**。它不会自动删除旧 mon/OSD 数据，混用可能导致集群损坏。

销毁同样有 fsid 保护：

- 目标 fsid 来自 TOML 的 `fsid` 或 state 文件
- 两者都没有时，`--destroy --apply` 会拒绝执行，除非显式加 `--force`
- 节点上的 fsid 与目标不同时，会拒绝执行，除非加 `--force`
- `--force` 不会绕过“设备被挂载”的保护，挂载中的磁盘始终拒绝销毁

### 6.5 破坏性操作提醒

- `wipe_devices = true`：会清空 OSD 设备上的文件系统签名
- `[node.partition]`：会对整盘执行 `mklabel gpt`，**清空原分区表**
- 已挂载的磁盘、分区数不符的磁盘会被拒绝操作

生产环境执行前请确认设备名（`lsblk`、`ceph-volume lvm list`）。

> 部署机会把目标集群的 `/etc/ceph/ceph.conf` 和 admin keyring 写到本机，
> 用于执行 `ceph` 命令。如果本机正在管理另一个集群，请换一台专用部署机，
> 避免覆盖本机原有的集群配置。

---

## 7. 部署后使用

### 7.1 查看集群

```bash
ceph -s
ceph osd tree
ceph df
ceph health detail
```

### 7.2 RGW 是否在线

```bash
curl -s -D - http://192.168.1.10:7480/ -o /dev/null | grep -Ei '^HTTP/|^Server:'
```

只要返回 HTTP 响应（`200` 或 `403`）并带有
`Server: Ceph Object Gateway`，就说明 RGW 正常；连接被拒绝才是服务没起来。
本版本对匿名根请求可能返回 `200` 和空桶列表，不代表可以直接读写数据，
真正的 S3 读写需要下面的用户密钥。

### 7.3 创建 S3 用户并测试

```bash
radosgw-admin user create \
  --uid=demo --display-name="demo user" \
  --access-key=demo --secret-key=demo123
```

如果安装了 AWS CLI：

```bash
export AWS_ACCESS_KEY_ID=demo
export AWS_SECRET_ACCESS_KEY=demo123
aws --endpoint-url http://192.168.1.10:7480 s3 mb s3://demo
aws --endpoint-url http://192.168.1.10:7480 s3 cp /etc/hostname s3://demo/hostname
aws --endpoint-url http://192.168.1.10:7480 s3 ls s3://demo/
```

> RGW 默认是 HTTP。生产环境请在前面加 TLS 反向代理，或配置 beast 的
> SSL 证书。

### 7.4 重启后自启

脚本创建的服务都已 `systemctl enable`：

```bash
systemctl is-enabled ceph-mon@a ceph-mgr@a ceph-radosgw@rgw.openeuler2403
```

OSD 由 `ceph-volume@lvm-<id>-<uuid>` 单元负责激活：

```bash
systemctl list-units 'ceph-volume@*' --all
ceph-volume lvm list
```

重启后检查 `ceph -s` 是否为 `HEALTH_OK`。

---

## 8. 常见问题

### 8.1 `无法连接节点` / SSH 失败

```bash
ssh -o BatchMode=yes root@10.0.0.11 hostname -s
```

确认免密登录、端口、防火墙。非 root 用户需要免密码 sudo：

```bash
ssh user@10.0.0.11 'sudo -n true'
```

### 8.2 `节点 xxx 缺少命令`

该节点没有安装对应 RPM，或 PATH 不对。安装 Ceph RPM 后重试：

```bash
ssh root@10.0.0.11 'command -v ceph ceph-mon ceph-mgr radosgw ceph-volume'
```

### 8.3 `设备不存在` / `不是块设备`

分区名可能与磁盘类型不匹配：

- `/dev/sda` → `/dev/sda1`
- `/dev/nvme0n1` → `/dev/nvme0n1p1`

脚本自动分区时会处理 `p` 前缀；手工填写 `osd_devices` 时要注意。

### 8.4 OSD 创建失败

先看设备是否已有 LVM/文件系统：

```bash
lsblk -f /dev/sdb
ceph-volume lvm list
```

必要时清空设备（**确认是专用盘**）：

```bash
wipefs -a /dev/sdb
ceph-volume lvm zap /dev/sdb      # 不要加 --destroy，除非确实要删分区/LV
```

如果 zap 报 `Device or resource busy`，说明分区上的 LV 仍处于活动状态。
先确认 VG 名称，删除后再 zap（分区会保留）：

```bash
vgs | grep ceph
lvremove -f <vg-name>
ceph-volume lvm zap /dev/sdb1
```

### 8.5 等待 mon quorum 超时

```bash
systemctl status ceph-mon@a
journalctl -u ceph-mon@a -n 100 --no-pager
```

常见原因：防火墙未放行 3300、`mon host` 地址不通、时间不同步、
旧 mon 数据与新 fsid 混用。

### 8.6 mgr 未 active

```bash
ceph -s
systemctl status ceph-mgr@a
journalctl -u ceph-mgr@a -n 100 --no-pager
```

### 8.7 RGW 端口未监听

```bash
systemctl status ceph-radosgw@rgw.ceph3
journalctl -u ceph-radosgw@rgw.ceph3 -n 100 --no-pager
ss -ltn | grep 7480
```

如果脚本提示 `.rgw.root` 池创建失败，可手动创建：

```bash
ceph osd pool create .rgw.root 16 16 --yes-i-really-mean-it
```

如果 `ceph -s` 出现 `POOL_APP_NOT_ENABLED` 警告：

```bash
ceph osd pool application enable <pool> rgw
```

脚本部署时会自动给 `.rgw.root` 和 `*.rgw.*` 池打上 `rgw` 标签。

### 8.8 `--apply 需要 root 权限`

使用 `sudo` 执行，或直接以 root 登录。

### 8.9 提示 fsid 不同

说明目标节点已有其他集群。确认是实验环境、要重建时再加 `--force`；
否则先清理旧集群或换一台机器。

### 8.10 `需要 Python 3.11+`

```bash
python3 --version
```

openEuler 24.03 自带 Python 3.11，可直接使用。

### 8.11 销毁时提示 fsid 未知或不同

- 如果是用脚本部署的，保留 `conf/deploy-ceph-*.state.json` 即可
- 如果 state 文件丢失，把 `ceph fsid` 的输出写到 TOML 的 `[cluster] fsid`
- 确认就是要销毁任意现存集群时，才使用 `--destroy --apply --force`

### 8.12 重新部署后没有 OSD

最常见原因是销毁时用了 `--keep-devices`。旧 LVM 仍占用设备，脚本会跳过。
先手动清理再部署：

```bash
ceph-volume lvm list
vgs | grep ceph                    # 找到设备对应的 ceph VG
lvremove -f ceph-xxxxxxxx-...      # 先删 LV，否则 zap 可能报 Device or resource busy
ceph-volume lvm zap /dev/sdXN      # 确认设备无误后执行
```

---

## 9. 销毁集群

`--destroy` 只操作配置文件里列出的节点。**销毁前必须确认使用的是部署时的同一份配置**
（节点、角色、OSD 设备一致），否则可能漏删服务或误删设备。

### 9.1 三步操作

```bash
# 1. 预演：只打印计划，不连接节点、不做变更
./script/deploy-ceph.py -c conf/deploy-ceph.toml --destroy

# 2. 预检查：SSH、命令、fsid、OSD 设备、挂载状态
./script/deploy-ceph.py -c conf/deploy-ceph.toml --destroy --check

# 3. 执行销毁（需要 root）
sudo ./script/deploy-ceph.py -c conf/deploy-ceph.toml --destroy --apply
```

多节点使用同一份多节点配置执行同样的命令即可。

### 9.2 销毁顺序

脚本按以下顺序执行：

1. 在每个节点用 `ceph-volume lvm list` 收集 OSD ID 和设备
2. 停止节点上所有 `ceph-radosgw@*`、`ceph-mgr@*`、`ceph-osd@*`、
   `ceph-volume@lvm-*` 单元，并等待 `ceph-osd` 进程退出
3. 在 mon 仍运行时删除 OSD：依次执行 `ceph osd out`、
   `ceph osd crush remove`、`ceph auth del`、`ceph osd rm`
   （这版 `ceph osd purge` 在 OSD 全部 down 时可能阻塞，脚本改用等价的分步命令）
4. 停止 `ceph-mon@*`
5. 对每个 OSD 设备先删除上面的 ceph LVM（`lvremove`/`vgremove`/`pvremove`），
   再执行 `ceph-volume lvm zap <dev>`。zap 不加 `--destroy`，**分区本身会保留**，
   最终恢复成空分区，可直接再次部署
6. 删除节点上 `/var/lib/ceph/{mon,mgr,radosgw,osd,bootstrap-*}` 下的数据
7. 删除 `/etc/ceph/ceph.conf`、admin keyring、mon/bootstrap keyring
8. 全部成功后才删除对应的 `*.state.json`

执行结束后会检查是否还有活动的 Ceph 单元，并提示销毁完成。

### 9.3 保留 OSD 数据

```bash
sudo ./script/deploy-ceph.py -c conf/deploy-ceph.toml --destroy --apply --keep-devices
```

只停止服务、清理 mon/mgr/rgw 数据和配置，不对 OSD 设备执行 `lvm zap`。
适用于想保留数据盘、之后再人工处理的场景。

> 注意：`--keep-devices` 后磁盘上仍然保留旧 OSD 的 LVM 信息。
> 直接重新 `--apply` 时，脚本会把这些设备识别为“已被 OSD 使用”而跳过，
> 导致新集群没有 OSD。重新部署前请先手动清理：
>
> ```bash
> ceph-volume lvm zap /dev/sdXN
> ```

无论是否加 `--keep-devices`，销毁成功后 state 文件都会删除，下次部署会生成新 fsid。

### 9.4 安全限制

- `--destroy --apply` 需要 root
- 目标 fsid 未知时拒绝执行，除非加 `--force`
- 节点 fsid 与目标 fsid 不同时拒绝执行，除非加 `--force`
- OSD 设备或其分区仍被挂载时**始终拒绝销毁**，`--force` 也不会绕过
- 销毁会停止节点上所有 Ceph 单元，并清理 `/var/lib/ceph` 下的 Ceph 数据；
  不要在同时运行其他 Ceph 集群的节点上使用本功能
- 销毁不可恢复；重要数据请先备份，实验环境建议先打快照

`--force` 只用于确认“就是要销毁这个 fsid 不匹配的环境”，不会帮你清理旧数据，
也不会跳过挂载保护。

### 9.5 手工清理

如果脚本无法完成清理（例如 Ceph RPM 已被卸载），可参考
[DEPLOY-CEPH-CLUSTER.md 的清理章节](DEPLOY-CEPH-CLUSTER.md#11-清理集群可选)
手工停止服务、purge OSD、`ceph-volume lvm zap` 并删除 `/var/lib/ceph` 下的残留目录。

不要在仍在使用的机器上执行清理命令；执行前务必用 `lsblk` 核对设备。

---

## 10. 与手工部署的关系

- [DEPLOY-CEPH-CLUSTER.md](DEPLOY-CEPH-CLUSTER.md)：手工逐步部署、原理和排错，
  适合第一次理解 Ceph。
- 本文 + `script/deploy-ceph.py`：把同样的步骤自动化，适合重复部署和批量部署。

脚本的关键约定与手工部署一致：

- msgr2：`mon host = v2:<ip>:3300`
- 单机使用 `osd crush chooseleaf type = 0`
- 不设置固定的 `osd_pool_default_pgp_num`，避免 PG 自动扩缩容时 ERANGE
- OSD 使用 `ceph-volume lvm create --bluestore`，重启由
  `ceph-volume@lvm-*` 单元激活
