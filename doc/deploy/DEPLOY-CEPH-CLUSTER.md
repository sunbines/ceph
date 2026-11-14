# Ceph 单节点集群部署教程（1 mon + 1 mgr + 1 rgw + 4 osd）

本教程记录在本机用 RPM 安装的 Ceph 21.3.0（umbrella dev）部署一个单节点测试集群的完整过程：
把 `/dev/sda` 划成 4 个分区，每个分区做一个 BlueStore OSD，再部署 mon、mgr、rgw。

> 本机实际环境：openEuler 24.03 LTS-SP1，主机名 `openeuler2403`，
> 业务网卡地址 `192.168.1.10`，系统盘是 `nvme1n1`，`/dev/sda` 为空闲数据盘。

## 0. 部署结果

| 组件 | ID | 地址/说明 |
| --- | --- | --- |
| 集群 FSID | `7c8b0a79-5bcd-42e0-aca2-e7c193ab9a78` | `/etc/ceph/ceph.conf` |
| mon | `a` | `v2:192.168.1.10:3300` |
| mgr | `a` | 无独立端口 |
| osd | `0/1/2/3` | `/dev/sda1` ~ `/dev/sda4`，LVM + BlueStore |
| rgw | `a` | `http://192.168.1.10:7480` |

最终状态：

```
health: HEALTH_OK
mon: 1 daemons, quorum a
mgr: a(active)
osd: 4 osds: 4 up, 4 in
rgw: 1 daemon active (1 hosts, 1 zones)
```

## 1. 前提条件

1. 已通过 RPM 安装 Ceph（本仓库的 `./script/build-ceph.sh --install`），确认二进制存在：

   ```bash
   ls -l /usr/bin/ceph-mon /usr/bin/ceph-mgr /usr/bin/radosgw /usr/sbin/ceph-volume
   ceph --version
   ```

2. 防火墙未开启（本机 `firewalld` inactive、SELinux Disabled）。如果开启防火墙，需要放行：

   ```bash
   firewall-cmd --permanent --add-port=3300/tcp   # mon msgr2
   firewall-cmd --permanent --add-port=6789/tcp   # mon msgr1（可选）
   firewall-cmd --permanent --add-port=7480/tcp   # rgw
   firewall-cmd --reload
   ```

   多机部署时 OSD 还需放行 `6800-7300/tcp`。

3. 全程使用 root。下文命令里的 `IP` 均为 `192.168.1.10`。

## 2. 划分 /dev/sda 为 4 个分区

> 确认 `/dev/sda` 是空闲盘，`lsblk` 里没有任何分区和挂载点。
> 下面的 `mklabel gpt` 会清掉盘上原有分区表。

```bash
lsblk /dev/sda

parted -s /dev/sda mklabel gpt
parted -s /dev/sda mkpart osd1 1MiB 25%
parted -s /dev/sda mkpart osd2 25% 50%
parted -s /dev/sda mkpart osd3 50% 75%
parted -s /dev/sda mkpart osd4 75% 100%
partprobe /dev/sda

# 清理分区里遗留的旧文件系统签名（本机 sda1 上有旧的 VMFS/NTFS 签名）
wipefs -a /dev/sda1 /dev/sda2 /dev/sda3 /dev/sda4

lsblk -o NAME,SIZE,TYPE,FSTYPE /dev/sda
```

预期：

```
sda    931.5G disk
├─sda1 232.9G part
├─sda2 232.9G part
├─sda3 232.9G part
└─sda4 232.9G part
```

## 3. 写 ceph.conf

```bash
IP=192.168.1.10
FSID=$(uuidgen)

cat > /etc/ceph/ceph.conf <<EOF
[global]
fsid = $FSID
mon host = v2:$IP:3300
public network = 192.168.1.0/24
cluster network = 192.168.1.0/24
auth cluster required = cephx
auth service required = cephx
auth client required = cephx
osd pool default size = 2
osd pool default min size = 1
osd pool default pg num = 64
osd crush chooseleaf type = 0

[mon.a]
host = $(hostname -s)
mon addr = v2:$IP:3300

[mgr.a]
host = $(hostname -s)

[client.rgw.a]
host = $(hostname -s)
rgw frontends = beast port=7480
EOF
```

几个关键点：

- `osd crush chooseleaf type = 0`：单机模式下让副本分布到不同 OSD，而不是要求不同主机
  （默认 `1` 表示按 host 做故障域，单机会导致 `size=2` 的池无法创建 PG）。
- `osd pool default size = 2 / min size = 1`：4 个 OSD 的测试集群够用。
- `mon host` 写成 `v2:IP:3300`：本版本执行过 `ceph mon set-addrs` 后 monmap 只广播
  msgr2 地址，客户端用 `IP:6789` 会一直卡住。
- **不要**写 `osd pool default pgp num`：本版本默认开启 PG 自动扩缩容，
  新池先按 `pg_num=1` 创建；若 `pgp_num` 被固定成 64，mon 会报
  `'pgp_num' must be greater than 0 and lower or equal than 'pg_num'`（ERANGE），
  RGW 自动建池也会全部失败。

## 4. 部署 mon

```bash
mkdir -p /var/lib/ceph/mon/ceph-a

ceph-authtool --create-keyring /tmp/ceph.mon.keyring \
    --gen-key -n mon. --cap mon 'allow *'

ceph-authtool --create-keyring /etc/ceph/ceph.client.admin.keyring \
    --gen-key -n client.admin \
    --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow *' --cap mgr 'allow *'

ceph-authtool /tmp/ceph.mon.keyring --import-keyring /etc/ceph/ceph.client.admin.keyring

monmaptool --create --add a "$IP:6789" --fsid "$FSID" /tmp/monmap

ceph-mon -i a --mkfs --monmap /tmp/monmap --keyring /tmp/ceph.mon.keyring

chown -R ceph:ceph /var/lib/ceph/mon/ceph-a /etc/ceph/ceph.client.admin.keyring
chmod 600 /etc/ceph/ceph.client.admin.keyring

systemctl enable --now ceph-mon@a
```

等 mon 起来后开启 msgr2、关掉不安全告警：

```bash
ceph mon set-addrs a "v2:$IP:3300/0,v1:$IP:6789/0"
systemctl restart ceph-mon@a       # set-addrs 后 mon 会正常退出，systemd 不会自动拉起

ceph config set mon auth_allow_insecure_global_id_reclaim false

ceph -s
```

> 注意：`ceph mon set-addrs` 会让 mon 以退出码 0 退出（重新绑定地址），而
> `ceph-mon@.service` 是 `Restart=on-failure`，所以必须手动 `systemctl restart` 一次。
> 之后 `ceph -s` 应显示 `mon: 1 daemons, quorum a`、`HEALTH_OK`。

## 5. 部署 mgr

```bash
mkdir -p /var/lib/ceph/mgr/ceph-a

ceph auth get-or-create mgr.a \
    mon 'allow profile mgr' osd 'allow *' mds 'allow *' \
    > /var/lib/ceph/mgr/ceph-a/keyring

chown -R ceph:ceph /var/lib/ceph/mgr/ceph-a
systemctl enable --now ceph-mgr@a

ceph -s      # mgr: a(active)
```

## 6. 部署 4 个 OSD

先准备 bootstrap-osd 密钥（`ceph-volume` 建 OSD 时使用）：

```bash
mkdir -p /var/lib/ceph/bootstrap-osd

ceph auth get-or-create client.bootstrap-osd \
    mon 'profile bootstrap-osd' > /var/lib/ceph/bootstrap-osd/ceph.keyring

# 如果提示 "key exists but cap mon does not match"，改用：
# ceph auth caps client.bootstrap-osd mon 'profile bootstrap-osd'
# ceph auth get client.bootstrap-osd > /var/lib/ceph/bootstrap-osd/ceph.keyring

chown -R ceph:ceph /var/lib/ceph/bootstrap-osd
```

依次把 4 个分区做成 OSD：

```bash
for d in /dev/sda1 /dev/sda2 /dev/sda3 /dev/sda4; do
    ceph-volume lvm create --bluestore --data "$d"
done

ceph osd tree
ceph -s
```

`lvm create` 会为每个分区创建 VG/LV（`ceph-<uuid>/osd-block-<osd-uuid>`），
并自动启用 `ceph-volume@lvm-<osd_id>-<osd_uuid>.service`，重启后会自动激活 OSD。

> 为什么不用 `ceph-volume raw prepare`：
> 本版本 raw 模式不会生成开机激活单元，重启后 OSD 目录是空 tmpfs，OSD 不会自动上线。
> LVM 模式是 RPM 部署的标准做法，有持久化单元。
>
> 不要对分区执行 `ceph-volume lvm zap --destroy`：`--destroy` 会直接删除分区本身。
> 只清数据请用不带 `--destroy` 的 `ceph-volume lvm zap /dev/sdaN`。

完成后应有：

```
ID  CLASS  WEIGHT   TYPE NAME
-1         0.90955  root default
-3         0.90955      host openeuler2403
 0    hdd  0.22739          osd.0   up
 1    hdd  0.22739          osd.1   up
 2    hdd  0.22739          osd.2   up
 3    hdd  0.22739          osd.3   up
```

## 7. 部署 RGW

### 7.1 预建 `.rgw.root` 池

本版本 mon 禁止客户端直接创建点开头的池名，而 `radosgw-admin realm create`
内部创建 `.rgw.root` 时不会带确认标志，会报 ERANGE。先手工建好：

```bash
ceph osd pool create .rgw.root 16 16 --yes-i-really-mean-it
```

### 7.2 初始化 realm / zonegroup / zone

```bash
radosgw-admin realm create --rgw-realm=default --default
radosgw-admin zonegroup create --rgw-zonegroup=default --master --default
radosgw-admin zone create --rgw-zonegroup=default --rgw-zone=default \
    --master --default --endpoints=http://192.168.1.10:7480
radosgw-admin period update --commit
```

### 7.3 启动 radosgw

```bash
mkdir -p /var/lib/ceph/radosgw/ceph-rgw.a

ceph auth get-or-create client.rgw.a \
    mon 'allow rw' osd 'allow rwx' \
    > /var/lib/ceph/radosgw/ceph-rgw.a/keyring

chown -R ceph:ceph /var/lib/ceph/radosgw
systemctl enable --now ceph-radosgw@rgw.a

ss -ltn | grep 7480
curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://192.168.1.10:7480/
```

## 8. 验证

### 8.1 集群状态

```bash
ceph -s
ceph osd tree
ceph osd pool ls
systemctl is-active ceph-mon@a ceph-mgr@a ceph-radosgw@rgw.a \
    ceph-osd@0 ceph-osd@1 ceph-osd@2 ceph-osd@3
```

预期 `ceph -s`：

```
health: HEALTH_OK
mon: 1 daemons, quorum a
mgr: a(active)
osd: 4 osds: 4 up, 4 in
rgw: 1 daemon active (1 hosts, 1 zones)
```

新建池后短时间可能出现 `pgs unknown`，等几十秒会自动变成 `active+clean`。

### 8.2 创建 S3 用户并做读写测试

```bash
radosgw-admin user create --uid=test --display-name='Test User' \
    --access-key=testkey --secret-key=testsecret

radosgw-admin user info --uid=test
```

用下面的脚本验证 PUT bucket / PUT object / GET object（S3 SigV4，路径风格）：

```python
#!/usr/bin/env python3
import hashlib, hmac, urllib.request, urllib.error
from datetime import datetime, timezone

HOST = "127.0.0.1:7480"
AK, SK = "testkey", "testsecret"
REGION = "us-east-1"

def sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()

def req(method, path, body=b""):
    t = datetime.now(timezone.utc)
    amzdate = t.strftime("%Y%m%dT%H%M%SZ")
    datestamp = t.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(body).hexdigest()
    headers = (f"host:{HOST}\nx-amz-content-sha256:{payload_hash}\n"
               f"x-amz-date:{amzdate}\n")
    signed = "host;x-amz-content-sha256;x-amz-date"
    creq = f"{method}\n{path}\n\n{headers}\n{signed}\n{payload_hash}"
    scope = f"{datestamp}/{REGION}/s3/aws4_request"
    sts = (f"AWS4-HMAC-SHA256\n{amzdate}\n{scope}\n"
           + hashlib.sha256(creq.encode()).hexdigest())
    k = sign(("AWS4" + SK).encode(), datestamp)
    k = sign(k, REGION); k = sign(k, "s3"); k = sign(k, "aws4_request")
    sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
    auth = (f"AWS4-HMAC-SHA256 Credential={AK}/{scope}, "
            f"SignedHeaders={signed}, Signature={sig}")
    r = urllib.request.Request("http://" + HOST + path,
                               data=body if method != "GET" else None,
                               method=method)
    r.add_header("Host", HOST)
    r.add_header("x-amz-content-sha256", payload_hash)
    r.add_header("x-amz-date", amzdate)
    r.add_header("Authorization", auth)
    try:
        with urllib.request.urlopen(r) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()

print("PUT bucket:", req("PUT", "/testbucket")[0])
print("PUT object:", req("PUT", "/testbucket/hello.txt", b"hello ceph rgw\n")[0])
print("GET object:", req("GET", "/testbucket/hello.txt"))
print("LIST buckets:", req("GET", "/")[0])
```

预期输出：

```
PUT bucket: 200
PUT object: 200
GET object: (200, b'hello ceph rgw\n')
LIST buckets: 200
```

## 9. 开机自启与重启验证

已持久化启用的单元：

```bash
systemctl is-enabled ceph-mon@a ceph-mgr@a ceph-radosgw@rgw.a
systemctl is-enabled 'ceph-volume@lvm-*'
```

- `ceph-mon@a`、`ceph-mgr@a`、`ceph-radosgw@rgw.a`：普通 enable，开机自启。
- `ceph-volume@lvm-<id>-<uuid>`：每个 OSD 一个，开机时执行
  `ceph-volume lvm trigger` 激活 OSD；`ceph-osd@N` 只是运行时被拉起，
  不需要单独 enable。

重启后检查：

```bash
systemctl is-active ceph-mon@a ceph-mgr@a ceph-radosgw@rgw.a
ceph -s
```

## 10. 常见问题

**1. `ceph mon set-addrs` 后 mon 不自动重启，客户端连不上**

mon 是正常退出（exit 0），而 `ceph-mon@.service` 只在失败时重启。手动
`systemctl restart ceph-mon@a`，并把 `ceph.conf` 的 `mon host` 改成
`v2:<ip>:3300`。

**2. 建池报 `'pgp_num' must be greater than 0 and lower or equal than 'pg_num'`**

`ceph.conf` 里写了 `osd pool default pgp num`，而 PG 自动扩缩容开启时新池
`pg_num` 先取 1，导致 `pgp_num > pg_num`。删掉该配置项，重启 mon：

```bash
systemctl restart ceph-mon@a
```

**3. RGW 初始化报 `pool names beginning with . are not allowed` / `(34) Numerical result out of range`**

先手工建 `.rgw.root`：

```bash
ceph osd pool create .rgw.root 16 16 --yes-i-really-mean-it
```

再重新执行 `radosgw-admin realm/zonegroup/zone/period` 和启动 RGW。

**4. 重启后 OSD 不上线**

说明 OSD 是 `ceph-volume raw prepare` 建的（没有持久激活单元）。
用 `ceph-volume lvm create` 重建（先 `ceph osd purge <id> --yes-i-really-mean-it`，
再对分区 `ceph-volume lvm zap /dev/sdaN`，不要加 `--destroy`）。

**5. `ceph-volume lvm zap --destroy` 把分区删了**

`--destroy` 会删除分区/LV。只想清 OSD 数据时用：

```bash
ceph-volume lvm zap /dev/sdaN
```

**6. 刚建完池 `ceph -s` 显示 `pgs unknown`**

新建池的 PG 还在创建中，等几十秒会自动变成 `active+clean` 并恢复 `HEALTH_OK`。

## 11. 清理集群（可选）

```bash
# 停服务
systemctl disable --now ceph-radosgw@rgw.a ceph-mgr@a ceph-mon@a
systemctl stop 'ceph-volume@lvm-*' ceph-osd@0 ceph-osd@1 ceph-osd@2 ceph-osd@3

# 删除 OSD（在 mon 还可用时执行）
for id in 0 1 2 3; do
    ceph osd purge "$id" --yes-i-really-mean-it
done

# 清理 OSD 数据和 LVM
for d in /dev/sda1 /dev/sda2 /dev/sda3 /dev/sda4; do
    ceph-volume lvm zap "$d"
done

# 清理 mon/mgr/rgw 数据（确认不再需要后）
rm -rf /var/lib/ceph/mon/ceph-a \
       /var/lib/ceph/mgr/ceph-a \
       /var/lib/ceph/radosgw/ceph-rgw.a \
       /var/lib/ceph/osd/ceph-*
```

## 12. 本次部署的实际映射

| 分区 | VG | OSD |
| --- | --- | --- |
| `/dev/sda1` | `ceph-a7d18539-ee79-4d69-9012-c50b54661764` | osd.0 |
| `/dev/sda2` | `ceph-b9c7af7d-dc70-4b90-bf18-933e8c0aa640` | osd.1 |
| `/dev/sda3` | `ceph-1222416e-8114-46f0-bf05-b8db577f5b84` | osd.2 |
| `/dev/sda4` | `ceph-84509f00-24b6-41c7-ab76-bd94e1381267` | osd.3 |

RGW 测试用户：`test` / access key `testkey` / secret key `testsecret`
（仅测试用，生产环境请重新生成）。
