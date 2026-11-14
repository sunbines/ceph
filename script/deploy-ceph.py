#!/usr/bin/env python3
"""deploy-ceph.py — 用 RPM 安装的 Ceph 部署/销毁单节点或多节点集群。

默认只打印部署计划（dry-run），加 --apply 才真正执行。
支持：mon / mgr / rgw / osd（ceph-volume lvm），可选把整盘自动分区。
销毁使用 --destroy，默认同样只打印计划。

示例：
    ./script/deploy-ceph.py -c conf/deploy-ceph.toml            # 打印部署计划
    ./script/deploy-ceph.py -c conf/deploy-ceph.toml --check    # 预检查 SSH/依赖/磁盘
    ./script/deploy-ceph.py -c conf/deploy-ceph.toml --apply    # 执行部署
    ./script/deploy-ceph.py -c conf/deploy-ceph.toml --destroy  # 打印销毁计划
    ./script/deploy-ceph.py -c conf/deploy-ceph.toml --destroy --apply  # 执行销毁
"""

from __future__ import annotations

import argparse
import base64
import ipaddress
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    sys.stderr.write("需要 Python 3.11+（使用标准库 tomllib 解析配置）\n")
    sys.exit(1)

VERSION = "1.1"
SSH_OPTS = [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10",
    "-o", "StrictHostKeyChecking=accept-new",
]
REQUIRED_BINS = ["ceph", "ceph-mon", "ceph-mgr", "ceph-authtool",
                 "monmaptool", "ceph-volume"]
STATE_SUFFIX = ".state.json"
REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG = str(REPO_ROOT / "conf" / "deploy-ceph.toml")


class DeployError(RuntimeError):
    pass


def log(msg: str) -> None:
    print(f"[deploy-ceph] {msg}", flush=True)


def die(msg: str) -> None:
    raise DeployError(msg)


def run(cmd: str, check: bool = True, input: str | None = None,
        timeout: int | None = None) -> subprocess.CompletedProcess:
    try:
        res = subprocess.run(["bash", "-c", cmd], input=input, text=True,
                             capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise DeployError(f"命令超时（{timeout}s）：{cmd}")
    if check and res.returncode != 0:
        raise DeployError(
            f"命令失败（exit {res.returncode}）：{cmd}\n"
            f"--- stdout ---\n{res.stdout[-4000:]}\n"
            f"--- stderr ---\n{res.stderr[-4000:]}"
        )
    return res


def local_ips() -> set[str]:
    ips: set[str] = {"127.0.0.1", "::1"}
    res = run("hostname -I 2>/dev/null", check=False)
    ips.update(res.stdout.split())
    try:
        ips.add(socket.gethostbyname(socket.gethostname()))
    except OSError:
        pass
    return ips


def local_hostnames() -> set[str]:
    names = set()
    for cmd in ("hostname", "hostname -s", "hostname -f"):
        res = run(cmd, check=False)
        if res.returncode == 0 and res.stdout.strip():
            names.add(res.stdout.strip())
    return names


def sanitize_id(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]", "-", value)


def letter_id(index: int) -> str:
    return chr(ord("a") + index)


def partition_device(disk: str, number: int) -> str:
    return f"{disk}p{number}" if disk and disk[-1].isdigit() else f"{disk}{number}"


def read_conf_fsid(path: str) -> str | None:
    try:
        text = Path(path).read_text(errors="ignore")
    except OSError:
        return None
    for line in text.splitlines():
        m = re.match(r"\s*fsid\s*=\s*(\S+)", line)
        if m:
            return m.group(1)
    return None


def put_local(path: str, content: str, mode: int = 0o600,
              owner: str = "root:root") -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = f"{path}.tmp{os.getpid()}"
    with open(tmp, "w") as fh:
        fh.write(content)
    os.chmod(tmp, mode)
    shutil.chown(tmp, *owner.split(":"))
    os.replace(tmp, path)


@dataclass
class Node:
    name: str
    address: str
    ssh_user: str = "root"
    ssh_port: int = 22
    mon: bool = False
    mgr: bool = False
    rgw: bool = False
    rgw_port: int = 7480
    osd_devices: list[str] = field(default_factory=list)
    partition_disk: str | None = None
    partition_count: int = 0
    hostname: str = ""
    is_local: bool = False
    mon_id: str = ""
    mgr_id: str = ""
    rgw_id: str = ""

    @property
    def roles(self) -> str:
        roles = [r for r, on in (("mon", self.mon), ("mgr", self.mgr),
                                 ("rgw", self.rgw)) if on]
        if self.osd_devices or self.partition_disk:
            roles.append("osd")
        return ",".join(roles) or "-"

    def run(self, cmd: str, check: bool = True, input: str | None = None,
            timeout: int = 300) -> subprocess.CompletedProcess:
        if self.is_local:
            return run(cmd, check=check, input=input, timeout=timeout)
        remote = cmd
        if self.ssh_user != "root":
            remote = f"sudo -n sh -c {shlex.quote(cmd)}"
        try:
            res = subprocess.run(
                ["ssh", *SSH_OPTS, "-p", str(self.ssh_port),
                 f"{self.ssh_user}@{self.address}", remote],
                input=input, text=True, capture_output=True, timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            raise DeployError(f"[{self.name}] SSH 命令超时：{cmd}")
        if check and res.returncode != 0:
            raise DeployError(
                f"[{self.name}] 命令失败（exit {res.returncode}）：{cmd}\n"
                f"--- stdout ---\n{res.stdout[-4000:]}\n"
                f"--- stderr ---\n{res.stderr[-4000:]}"
            )
        return res

    def put(self, path: str, content: str, mode: int = 0o600,
            owner: str = "root:root") -> None:
        if self.is_local:
            put_local(path, content, mode, owner)
            return
        script = (
            f"umask 077; mkdir -p {shlex.quote(os.path.dirname(path))}; "
            f"cat > {shlex.quote(path)}; "
            f"chmod {mode:o} {shlex.quote(path)}; "
            f"chown {owner} {shlex.quote(path)}"
        )
        self.run(script, input=content)

    def exists(self, path: str) -> bool:
        return self.run(f"test -e {shlex.quote(path)}", check=False).returncode == 0


@dataclass
class Cluster:
    fsid: str
    public_network: str
    cluster_network: str
    pool_size: int = 2
    pool_min_size: int = 1
    pg_num: int = 64
    wipe_devices: bool = False
    realm: str = "default"


def load_config(path: str) -> tuple[Cluster, list[Node]]:
    try:
        data = tomllib.loads(Path(path).read_text())
    except FileNotFoundError:
        raise DeployError(f"配置文件不存在：{path}")
    except tomllib.TOMLDecodeError as exc:
        raise DeployError(f"TOML 解析失败：{exc}")

    raw = data.get("cluster", {})
    raw_nodes = data.get("node", [])
    if not isinstance(raw_nodes, list) or not raw_nodes:
        raise DeployError("配置里至少需要一个 [[node]]")

    nodes: list[Node] = []
    for idx, rn in enumerate(raw_nodes):
        name = str(rn.get("name") or rn.get("host") or f"node{idx + 1}")
        address = str(rn.get("address") or rn.get("addr") or "").strip()
        if not address:
            raise DeployError(f"节点 {name} 缺少 address")
        part = rn.get("partition") or {}
        devices = [str(d) for d in rn.get("osd_devices", [])]
        p_disk = part.get("disk")
        p_count = int(part.get("count", 0) or 0)
        if p_disk and devices:
            raise DeployError(f"节点 {name} 同时配置了 osd_devices 和 partition，只能二选一")
        if p_disk and p_count < 1:
            raise DeployError(f"节点 {name} 的 [node.partition] 需要 count >= 1")
        nodes.append(Node(
            name=name,
            address=address,
            ssh_user=str(rn.get("ssh_user", "root")),
            ssh_port=int(rn.get("ssh_port", 22)),
            mon=bool(rn.get("mon", False)),
            mgr=bool(rn.get("mgr", False)),
            rgw=bool(rn.get("rgw", False)),
            rgw_port=int(rn.get("rgw_port", 7480)),
            osd_devices=devices,
            partition_disk=str(p_disk) if p_disk else None,
            partition_count=p_count,
        ))

    if not any(n.mon for n in nodes):
        raise DeployError("至少需要一个 mon 节点（mon = true）")

    fsid = str(raw.get("fsid", "")).strip()
    if fsid:
        try:
            uuid.UUID(fsid)
        except ValueError:
            raise DeployError(f"fsid 不是合法 UUID：{fsid}")

    try:
        default_net = str(ipaddress.ip_network(nodes[0].address + "/24",
                                               strict=False))
    except ValueError:
        raise DeployError(f"无法从 {nodes[0].address} 推导网段，请显式配置 public_network")
    public_network = str(raw.get("public_network", default_net))
    cluster_network = str(raw.get("cluster_network", public_network))

    cluster = Cluster(
        fsid=fsid,
        public_network=public_network,
        cluster_network=cluster_network,
        pool_size=int(raw.get("pool_size", 2)),
        pool_min_size=int(raw.get("pool_min_size", 1)),
        pg_num=int(raw.get("pg_num", 64)),
        wipe_devices=bool(raw.get("wipe_devices", False)),
        realm=str(raw.get("rgw_realm", "default")),
    )

    ips = local_ips()
    names = local_hostnames()
    for node in nodes:
        node.is_local = node.address in ips or node.name in names
        if not node.is_local:
            try:
                node.is_local = socket.gethostbyname(node.address) in ips
            except OSError:
                pass

    mon_nodes = [n for n in nodes if n.mon]
    mgr_nodes = [n for n in nodes if n.mgr]
    for i, node in enumerate(mon_nodes):
        node.mon_id = letter_id(i)
    for i, node in enumerate(mgr_nodes):
        node.mgr_id = letter_id(i)
    for node in nodes:
        if node.rgw:
            node.rgw_id = "rgw." + sanitize_id(node.name)

    if len(mon_nodes) % 2 == 0:
        log(f"警告：mon 数量为 {len(mon_nodes)}，建议使用奇数个（1/3/5）")
    return cluster, nodes


def node_devices(node: Node) -> list[str]:
    if node.partition_disk:
        return [partition_device(node.partition_disk, i)
                for i in range(1, node.partition_count + 1)]
    return list(node.osd_devices)


def render_conf(cluster: Cluster, nodes: list[Node]) -> str:
    mons = [n for n in nodes if n.mon]
    mgrs = [n for n in nodes if n.mgr]
    rgws = [n for n in nodes if n.rgw]
    mon_host = ",".join(f"v2:{n.address}:3300" for n in mons)

    osd_hosts = {n.name for n in nodes if node_devices(n)}
    lines = [
        "[global]",
        f"fsid = {cluster.fsid}",
        f"mon host = {mon_host}",
        f"public network = {cluster.public_network}",
        f"cluster network = {cluster.cluster_network}",
        "auth cluster required = cephx",
        "auth service required = cephx",
        "auth client required = cephx",
        f"osd pool default size = {cluster.pool_size}",
        f"osd pool default min size = {cluster.pool_min_size}",
    ]
    if cluster.pg_num > 0:
        # 不要设置 osd_pool_default_pgp_num：PG 自动扩缩容会先按 pg_num=1
        # 建池，固定的 pgp_num 会触发 ERANGE。
        lines.append(f"osd pool default pg num = {cluster.pg_num}")
    if len(osd_hosts) <= 1:
        # 单机部署时按 OSD 而不是按 host 做故障域，否则副本池没有 PG 可用。
        lines.append("osd crush chooseleaf type = 0")
    for node in mons:
        lines += ["", f"[mon.{node.mon_id}]",
                  f"host = {node.hostname or node.name}",
                  f"mon addr = v2:{node.address}:3300"]
    for node in mgrs:
        lines += ["", f"[mgr.{node.mgr_id}]",
                  f"host = {node.hostname or node.name}"]
    for node in rgws:
        lines += ["", f"[client.{node.rgw_id}]",
                  f"host = {node.hostname or node.name}",
                  f"rgw frontends = beast endpoint={node.address}:{node.rgw_port}"]
    return "\n".join(lines) + "\n"


def print_plan(cluster: Cluster, nodes: list[Node], state_path: str) -> None:
    log("部署计划")
    print(f"  集群 FSID      : {cluster.fsid or '(将自动生成)'}")
    print(f"  公网/集群网段  : {cluster.public_network} / {cluster.cluster_network}")
    print(f"  副本数         : size={cluster.pool_size}, min_size={cluster.pool_min_size}")
    if cluster.wipe_devices:
        print("  磁盘清理       : 启用（会对 osd 设备执行 wipefs -a）")
    print()
    header = f"  {'节点':<18} {'地址':<16} {'角色':<16} {'mon/mgr/rgw id':<22} OSD 设备"
    print(header)
    print("  " + "-" * (len(header) - 2))
    for node in nodes:
        ids = "/".join(x for x in (node.mon_id, node.mgr_id, node.rgw_id) if x) or "-"
        devs = node_devices(node)
        if node.partition_disk:
            devs = [f"{node.partition_disk} -> {node.partition_count} 个分区"]
        print(f"  {node.name:<18} {node.address:<16} {node.roles:<16} "
              f"{ids:<22} {', '.join(devs) or '-'}")
        if node.partition_disk:
            print(f"  {'':<18} 将对 {node.partition_disk} 执行 mklabel gpt + "
                  f"{node.partition_count} 个分区（会清空该盘！）")
        if not node.is_local:
            print(f"  {'':<18} SSH: {node.ssh_user}@{node.address}:{node.ssh_port}")
    print()
    print(f"  状态文件       : {state_path}")
    print()


def check_local_tools(need_rgw: bool) -> None:
    bins = list(REQUIRED_BINS)
    if need_rgw:
        bins.append("radosgw")
    missing = [b for b in bins if not shutil.which(b)]
    if missing:
        die("本机缺少命令：" + ", ".join(missing) +
            "\n请先安装 Ceph RPM（例如 ./build-ceph.sh --install）")


def check_ssh_tools(nodes: list[Node]) -> None:
    if any(not n.is_local for n in nodes) and not shutil.which("ssh"):
        die("本机缺少 ssh 命令（部署远程节点需要）")


def check_node(node: Node) -> None:
    res = node.run("hostname -s", check=False)
    if res.returncode != 0:
        detail = (res.stderr or res.stdout).strip()
        die(f"无法连接节点 {node.name}（{node.ssh_user}@{node.address}:"
            f"{node.ssh_port}）：{detail}\n"
            "请先配置免密登录：ssh-copy-id root@<地址>")
    node.hostname = res.stdout.strip()
    bins = list(REQUIRED_BINS)
    if node.rgw:
        bins.append("radosgw")
    missing = []
    for b in bins:
        if node.run(f"command -v {b} >/dev/null 2>&1", check=False).returncode != 0:
            missing.append(b)
    if missing:
        die(f"节点 {node.name} 缺少命令：{', '.join(missing)}；请先安装 Ceph RPM")


def used_osd_devices(node: Node) -> set[str]:
    res = node.run("ceph-volume lvm list --format json", check=False)
    if res.returncode != 0:
        return set()
    try:
        data = json.loads(res.stdout)
    except json.JSONDecodeError:
        return set()
    used: set[str] = set()
    for entries in data.values():
        for entry in entries or []:
            for dev in entry.get("devices", []) or []:
                used.add(dev)
    return used


def partition_table(node: Node, disk: str) -> list[str] | None:
    res = node.run(f"parted -m -s {shlex.quote(disk)} print", check=False)
    if res.returncode != 0:
        return None
    names = []
    for line in res.stdout.splitlines():
        if re.match(r"^\d+:", line):
            fields = line.split(":")
            names.append(fields[5] if len(fields) > 5 else "")
    return names


def mounted_partitions(node: Node, disk: str) -> list[str]:
    res = node.run(f"lsblk -ln -o MOUNTPOINTS {shlex.quote(disk)}", check=False)
    if res.returncode != 0:
        die(f"[{node.name}] 无法读取 {disk} 的挂载信息")
    return [line.strip() for line in res.stdout.splitlines() if line.strip()]


def inspect_partition_disk(node: Node, warn_only: bool = False) -> None:
    disk = node.partition_disk
    if not disk:
        return
    if node.run(f"test -b {shlex.quote(disk)}", check=False).returncode != 0:
        die(f"[{node.name}] {disk} 不存在或不是块设备")
    mounted = mounted_partitions(node, disk)
    if mounted:
        die(f"[{node.name}] {disk} 上的分区仍被挂载（{', '.join(mounted)}），"
            "拒绝重新分区")
    parts = partition_table(node, disk)
    if not parts:
        return
    expected = [f"osd{i}" for i in range(1, node.partition_count + 1)]
    if len(parts) == node.partition_count and all(
            name in expected for name in parts):
        return
    if warn_only:
        log(f"警告：{node.name} 的 {disk} 已有 {len(parts)} 个分区，"
            "与配置不一致，执行时会拒绝分区")
        return
    die(f"[{node.name}] {disk} 已有 {len(parts)} 个分区（{parts}），"
        f"与配置的 {node.partition_count} 个不一致；请先人工确认")


def ensure_partitions(node: Node) -> list[str]:
    disk = node.partition_disk
    if not disk:
        return []
    inspect_partition_disk(node)
    parts = partition_table(node, disk)
    devices = node_devices(node)
    if parts:
        log(f"[{node.name}] {disk} 已有符合配置的 {len(parts)} 个分区，跳过分区")
        return devices

    log(f"[{node.name}] 分区 {disk}：mklabel gpt + {node.partition_count} 个分区")
    node.run(f"parted -s {shlex.quote(disk)} mklabel gpt")
    count = node.partition_count
    for i in range(count):
        start = "1MiB" if i == 0 else f"{i * 100 / count:.4f}%"
        end = f"{(i + 1) * 100 / count:.4f}%"
        node.run(f"parted -s {shlex.quote(disk)} mkpart osd{i + 1} {start} {end}")
    node.run(f"partprobe {shlex.quote(disk)} 2>/dev/null || true; sleep 1")
    for dev in devices:
        if node.run(f"test -b {shlex.quote(dev)}", check=False).returncode != 0:
            die(f"[{node.name}] 分区 {dev} 创建后不存在")
        node.run(f"wipefs -a {shlex.quote(dev)}")
    return devices


def ensure_auth(entity: str, caps: str) -> str:
    res = run(f"ceph auth get-or-create {entity} {caps}", check=False)
    if res.returncode != 0:
        run(f"ceph auth caps {entity} {caps}")
    return run(f"ceph auth get {entity}").stdout


def cluster_status() -> dict | None:
    res = run("ceph -s -f json", check=False)
    if res.returncode != 0:
        return None
    try:
        return json.loads(res.stdout)
    except json.JSONDecodeError:
        return None


def wait_for_quorum(mon_names: list[str], timeout: int = 180) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        status = cluster_status()
        if status:
            quorum = status.get("quorum_names") or status.get("quorum") or []
            if set(quorum) >= set(mon_names):
                log(f"mon quorum 就绪：{', '.join(mon_names)}")
                return
        time.sleep(3)
    die(f"等待 mon quorum 超时（{timeout}s）：{', '.join(mon_names)}")


def wait_for_mgr(timeout: int = 120) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        status = cluster_status()
        if status:
            mgr = status.get("mgrmap") or {}
            if mgr.get("active_name") or mgr.get("available"):
                return
        time.sleep(3)
    die(f"等待 mgr active 超时（{timeout}s）")


def wait_for_osds(expected: int, timeout: int = 240) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        res = run("ceph osd stat -f json", check=False)
        if res.returncode == 0:
            try:
                stat = json.loads(res.stdout)
            except json.JSONDecodeError:
                stat = {}
            up = stat.get("num_up_osds", 0)
            in_ = stat.get("num_in_osds", 0)
            if in_ >= expected and up == in_ and up > 0:
                log(f"OSD 就绪：{up} up / {in_} in")
                return
        time.sleep(3)
    log("警告：等待 OSD 全部 up 超时，请稍后用 ceph -s / ceph osd tree 检查")


def node_conf_fsid(node: Node) -> str | None:
    res = node.run(
        "sed -n 's/^[[:space:]]*fsid[[:space:]]*=[[:space:]]*//p' "
        "/etc/ceph/ceph.conf 2>/dev/null | head -1", check=False)
    return res.stdout.strip() or None


def other_cluster_on(node: Node, fsid: str, force: bool) -> bool:
    old = node_conf_fsid(node)
    if not old or old == fsid:
        return False
    reachable = node.run("ceph -s >/dev/null 2>&1", check=False).returncode == 0
    if reachable and not force:
        die(f"节点 {node.name} 上已有一个运行中的集群（fsid={old}），"
            f"与目标 fsid={fsid} 不同。确认要覆盖请加 --force")
    if reachable and force:
        log(f"警告：节点 {node.name} 上已有集群 {old}，--force 将覆盖其 /etc/ceph/ceph.conf")
    else:
        log(f"提示：节点 {node.name} 的旧 /etc/ceph/ceph.conf（fsid={old}）将被覆盖")
    return True


def mon_initialized(node: Node) -> bool:
    return node.run(
        f"test -e /var/lib/ceph/mon/ceph-{node.mon_id}/kv_backend || "
        f"test -e /var/lib/ceph/mon/ceph-{node.mon_id}/store.db",
        check=False).returncode == 0


def read_keyring(nodes: list[Node], path: str) -> str | None:
    local = Path(path)
    if local.exists():
        return local.read_text()
    for node in nodes:
        if node.run(f"test -e {shlex.quote(path)}", check=False).returncode == 0:
            return node.run(f"cat {shlex.quote(path)}").stdout
    return None


def deploy_mons(cluster: Cluster, nodes: list[Node], conf: str,
                workdir: str) -> None:
    mons = [n for n in nodes if n.mon]
    adminkey = Path(workdir, "admin.keyring")
    monkey = Path(workdir, "mon.keyring")
    monmap = Path(workdir, "monmap")

    existing = [n for n in mons if mon_initialized(n)]
    if existing:
        # 重复执行时复用集群已有密钥，避免覆盖 keyring 后无法认证。
        log("检测到已初始化的 mon，复用现有密钥")
        admin_text = read_keyring(nodes, "/etc/ceph/ceph.client.admin.keyring")
        if not admin_text:
            admin_text = read_keyring(
                existing,
                f"/var/lib/ceph/mon/ceph-{existing[0].mon_id}/keyring")
        if not admin_text:
            die("集群已存在，但找不到 client.admin keyring；"
                "请从其他节点复制 /etc/ceph/ceph.client.admin.keyring 后重试")
        mon_text = read_keyring(
            existing, f"/var/lib/ceph/mon/ceph-{existing[0].mon_id}/keyring")
        if not mon_text:
            res = run("ceph auth get mon.", check=False)
            if res.returncode != 0:
                die("集群已存在，但无法读取 mon. 密钥（ceph auth get mon. 失败）")
            mon_text = res.stdout
    else:
        run(f"ceph-authtool --create-keyring {adminkey} --gen-key "
            "-n client.admin --cap mon 'allow *' --cap osd 'allow *' "
            "--cap mds 'allow *' --cap mgr 'allow *'")
        run(f"ceph-authtool --create-keyring {monkey} --gen-key -n mon. "
            "--cap mon 'allow *'")
        run(f"ceph-authtool {monkey} --import-keyring {adminkey}")
        admin_text = adminkey.read_text()
        mon_text = monkey.read_text()

    add_args = " ".join(f"--add {n.mon_id} v2:{n.address}:3300/0" for n in mons)
    run(f"monmaptool --create {add_args} --fsid {cluster.fsid} {monmap}")
    # monmap 是二进制格式，跨节点传输用 base64，不能按文本读写。
    monmap_b64 = base64.b64encode(monmap.read_bytes()).decode()

    # 部署机本身也要有配置和 admin keyring（用于本地 ceph/ceph-volume 命令）
    put_local("/etc/ceph/ceph.conf", conf, 0o644, "root:root")
    put_local("/etc/ceph/ceph.client.admin.keyring", admin_text, 0o600,
              "ceph:ceph")
    for node in nodes:
        node.put("/etc/ceph/ceph.conf", conf, 0o644, "root:root")
        node.put("/etc/ceph/ceph.client.admin.keyring", admin_text, 0o600,
                 "ceph:ceph")

    for node in mons:
        log(f"[{node.name}] 部署 mon.{node.mon_id}")
        exists = node.run(
            f"test -e /var/lib/ceph/mon/ceph-{node.mon_id}/kv_backend || "
            f"test -e /var/lib/ceph/mon/ceph-{node.mon_id}/store.db",
            check=False).returncode == 0
        if exists:
            log(f"[{node.name}] mon.{node.mon_id} 数据目录已存在，跳过 mkfs")
        else:
            node.run("base64 -d > /tmp/deploy-ceph-monmap && "
                     "chmod 600 /tmp/deploy-ceph-monmap",
                     input=monmap_b64)
            node.put("/tmp/deploy-ceph-mon.keyring", mon_text, 0o600)
            node.run(
                f"install -d -o ceph -g ceph /var/lib/ceph/mon/ceph-{node.mon_id} && "
                f"ceph-mon -i {node.mon_id} --mkfs "
                "--monmap /tmp/deploy-ceph-monmap "
                "--keyring /tmp/deploy-ceph-mon.keyring && "
                f"chown -R ceph:ceph /var/lib/ceph/mon/ceph-{node.mon_id}",
                timeout=600)
            node.run("rm -f /tmp/deploy-ceph-monmap /tmp/deploy-ceph-mon.keyring",
                     check=False)
        node.run(f"systemctl enable --now ceph-mon@{node.mon_id}")

    wait_for_quorum([n.mon_id for n in mons])
    run("ceph config set mon auth_allow_insecure_global_id_reclaim false",
        check=False)


def deploy_mgrs(nodes: list[Node]) -> None:
    mgrs = [n for n in nodes if n.mgr]
    if not mgrs:
        return
    for node in mgrs:
        log(f"[{node.name}] 部署 mgr.{node.mgr_id}")
        key = ensure_auth(
            f"mgr.{node.mgr_id}",
            "mon 'allow profile mgr' osd 'allow *' mds 'allow *'")
        node.put(f"/var/lib/ceph/mgr/ceph-{node.mgr_id}/keyring", key,
                 0o600, "ceph:ceph")
        node.run(f"systemctl enable --now ceph-mgr@{node.mgr_id}")
    wait_for_mgr()


def deploy_osds(cluster: Cluster, nodes: list[Node]) -> None:
    osd_nodes = [n for n in nodes if node_devices(n)]
    if not osd_nodes:
        return
    log("创建 bootstrap-osd 密钥")
    bootstrap = ensure_auth("client.bootstrap-osd", "mon 'profile bootstrap-osd'")
    for node in osd_nodes:
        node.put("/var/lib/ceph/bootstrap-osd/ceph.keyring", bootstrap,
                 0o600, "ceph:ceph")

    total = 0
    for node in osd_nodes:
        devices = ensure_partitions(node) if node.partition_disk else node_devices(node)
        total += len(devices)
        used = used_osd_devices(node)
        for dev in devices:
            real = os.path.realpath(dev) if node.is_local else dev
            if dev in used or real in used:
                log(f"[{node.name}] {dev} 已经是 OSD 设备，跳过")
                continue
            if cluster.wipe_devices:
                log(f"[{node.name}] wipefs -a {dev}")
                node.run(f"wipefs -a {shlex.quote(dev)}", check=False)
            log(f"[{node.name}] ceph-volume lvm create --data {dev}")
            res = node.run(
                f"ceph-volume lvm create --bluestore --data {shlex.quote(dev)}",
                check=False, timeout=1800)
            if res.returncode != 0:
                raise DeployError(
                    f"[{node.name}] 在 {dev} 上创建 OSD 失败：\n"
                    f"{res.stdout[-4000:]}\n{res.stderr[-4000:]}")
    wait_for_osds(total)


def deploy_rgws(cluster: Cluster, nodes: list[Node]) -> None:
    rgws = [n for n in nodes if n.rgw]
    if not rgws:
        return

    pools = run("ceph osd pool ls", check=False).stdout.split()
    if ".rgw.root" not in pools:
        log("创建 .rgw.root 池")
        res = run("ceph osd pool create .rgw.root 16 16 "
                  "--yes-i-really-mean-it", check=False)
        if res.returncode != 0:
            run("ceph osd pool create .rgw.root 16 16")

    realm = cluster.realm
    if run(f"radosgw-admin realm get --rgw-realm={realm}",
           check=False).returncode != 0:
        log(f"创建 realm {realm}")
        run(f"radosgw-admin realm create --rgw-realm={realm} --default")
    if run(f"radosgw-admin zonegroup get --rgw-zonegroup={realm}",
           check=False).returncode != 0:
        log(f"创建 zonegroup {realm}")
        run(f"radosgw-admin zonegroup create --rgw-zonegroup={realm} "
            "--master --default")
    if run(f"radosgw-admin zone get --rgw-zone={realm}",
           check=False).returncode != 0:
        endpoints = ",".join(f"http://{n.address}:{n.rgw_port}" for n in rgws)
        log(f"创建 zone {realm}（endpoints={endpoints}）")
        run(f"radosgw-admin zone create --rgw-zonegroup={realm} "
            f"--rgw-zone={realm} --master --default --endpoints={endpoints}")
    run("radosgw-admin period update --commit", timeout=180)

    for node in rgws:
        log(f"[{node.name}] 部署 {node.rgw_id}")
        key = ensure_auth(f"client.{node.rgw_id}",
                          "mon 'allow rw' osd 'allow rwx'")
        node.put(f"/var/lib/ceph/radosgw/ceph-{node.rgw_id}/keyring", key,
                 0o600, "ceph:ceph")
        node.run(f"systemctl enable --now ceph-radosgw@{node.rgw_id}")
        listening = False
        for _ in range(20):
            if node.run(f"ss -ltn | grep -q ':{node.rgw_port} '",
                        check=False).returncode == 0:
                listening = True
                break
            time.sleep(1)
        if not listening:
            log(f"警告：[{node.name}] 端口 {node.rgw_port} 尚未监听，请查看 "
                f"journalctl -u ceph-radosgw@{node.rgw_id}")
        else:
            log(f"[{node.name}] RGW 已监听 {node.address}:{node.rgw_port}")

    # RGW 的池如果没有 application 标签，集群会一直报 POOL_APP_NOT_ENABLED。
    for pool in run("ceph osd pool ls", check=False).stdout.split():
        if (pool == ".rgw.root" or pool.startswith("default.rgw.")
                or pool.startswith(f"{realm}.rgw.")):
            run(f"ceph osd pool application enable {shlex.quote(pool)} rgw",
                check=False)


def node_osd_info(node: Node) -> tuple[list[str], list[str]]:
    res = node.run("ceph-volume lvm list --format json", check=False)
    if res.returncode != 0:
        return [], []
    try:
        data = json.loads(res.stdout)
    except json.JSONDecodeError:
        return [], []
    if not isinstance(data, dict):
        return [], []
    ids: set[str] = set()
    devices: set[str] = set()
    for osd_id, entries in data.items():
        osd_id = str(osd_id)
        if osd_id.isdigit():
            ids.add(osd_id)
        for entry in entries or []:
            for dev in entry.get("devices", []) or []:
                if dev:
                    devices.add(dev)
    return sorted(ids, key=int), sorted(devices)


def destroy_plan(cluster: Cluster, nodes: list[Node], state_path: str,
                 keep_devices: bool) -> None:
    log("销毁计划")
    print(f"  目标 FSID      : {cluster.fsid or '(未知；执行时需要 --force)'}")
    print(f"  磁盘处理       : "
          f"{'保留 OSD 数据（--keep-devices）' if keep_devices else 'ceph-volume lvm zap（删除 OSD 数据）'}")
    print()
    header = f"  {'节点':<18} {'地址':<16} 将停止的服务"
    print(header)
    print("  " + "-" * (len(header) - 2))
    for node in nodes:
        units = []
        if node.rgw:
            units.append("ceph-radosgw@*")
        if node.mgr:
            units.append("ceph-mgr@*")
        if node.mon:
            units.append("ceph-mon@*")
        if node_devices(node):
            units.append("ceph-osd@* + ceph-volume@lvm-*")
        print(f"  {node.name:<18} {node.address:<16} {', '.join(units) or '-'}")
        if node_devices(node):
            print(f"  {'':<18} {'':<16} OSD: {', '.join(node_devices(node))}")
    print()
    print(f"  状态文件       : {state_path}（销毁成功后删除）")
    print()
    log("警告：销毁不可恢复；请确认节点、fsid 和设备名无误")


def destroy_preflight(cluster: Cluster, nodes: list[Node], force: bool,
                      keep_devices: bool) -> dict[str, tuple[list[str], list[str]]]:
    check_ssh_tools(nodes)
    for node in nodes:
        check_node(node)

    info: dict[str, tuple[list[str], list[str]]] = {}
    for node in nodes:
        old = node_conf_fsid(node)
        if old and cluster.fsid and old != cluster.fsid:
            if not force:
                die(f"节点 {node.name} 上的集群 fsid={old}，与目标 "
                    f"fsid={cluster.fsid} 不同；确认要销毁请加 --force")
            log(f"警告：节点 {node.name} 的 fsid={old} 与目标不同，--force 继续")
        elif old and not cluster.fsid:
            log(f"警告：未指定目标 fsid，节点 {node.name} 上的 fsid={old} 将被销毁")
        elif not old:
            log(f"提示：节点 {node.name} 未发现 /etc/ceph/ceph.conf 的 fsid")

        ids, devs = node_osd_info(node)
        info[node.name] = (ids, devs)
        if keep_devices:
            continue
        for dev in sorted(set(node_devices(node)) | set(devs)):
            if node.run(f"test -b {shlex.quote(dev)}",
                        check=False).returncode != 0:
                log(f"提示：[{node.name}] {dev} 不存在或不是块设备，跳过")
                continue
            mounted = node.run(
                f"lsblk -ln -o MOUNTPOINTS {shlex.quote(dev)}",
                check=False).stdout.strip()
            if mounted:
                die(f"[{node.name}] {dev} 或其分区仍被挂载（{mounted}），拒绝销毁")
    return info


def destroy_check_report(cluster: Cluster, nodes: list[Node],
                         info: dict[str, tuple[list[str], list[str]]],
                         keep_devices: bool) -> None:
    log("销毁预检查通过")
    print(f"  目标 FSID: {cluster.fsid or '(未知，执行时需要 --force)'}")
    for node in nodes:
        ids, devs = info.get(node.name, ([], []))
        old = node_conf_fsid(node)
        print(f"  {node.name:<18} fsid={old or '-':<38} "
              f"OSD={','.join(ids) or '-'}")
        for dev in sorted(set(node_devices(node)) | set(devs)):
            if not node.run(f"test -b {shlex.quote(dev)}",
                            check=False).returncode == 0:
                state = "设备不存在"
            elif keep_devices:
                state = "保留"
            else:
                mounted = node.run(
                    f"lsblk -ln -o MOUNTPOINTS {shlex.quote(dev)}",
                    check=False).stdout.strip()
                state = "已挂载（将拒绝）" if mounted else "将 zap"
            print(f"  {'':<18} {dev:<20} {state}")


def matching_units(node: Node, pattern: str) -> set[str]:
    res = node.run(
        "systemctl list-units --all --plain --no-legend "
        f"'{pattern}' 2>/dev/null | awk '{{print $1}}'", check=False)
    units = set()
    for unit in res.stdout.split():
        if "@." in unit:
            continue
        units.add(unit[:-8] if unit.endswith(".service") else unit)
    return units


def stop_node_services(node: Node, osd_ids: list[str]) -> None:
    rgw_units = matching_units(node, "ceph-radosgw@*")
    mgr_units = matching_units(node, "ceph-mgr@*")
    if node.rgw:
        rgw_units.add(f"ceph-radosgw@{node.rgw_id}")
    if node.mgr:
        mgr_units.add(f"ceph-mgr@{node.mgr_id}")

    osd_units = {f"ceph-osd@{i}" for i in osd_ids}
    osd_units |= matching_units(node, "ceph-volume@lvm-*")

    for units in (sorted(rgw_units), sorted(mgr_units), sorted(osd_units)):
        if not units:
            continue
        quoted = " ".join(shlex.quote(u) for u in units)
        node.run(f"systemctl disable --now {quoted}", check=False)
        node.run(f"systemctl reset-failed {quoted}", check=False)


def stop_mon_services(node: Node) -> None:
    units = matching_units(node, "ceph-mon@*")
    if node.mon:
        units.add(f"ceph-mon@{node.mon_id}")
    if units:
        node.run("systemctl disable --now "
                 + " ".join(shlex.quote(u) for u in sorted(units)),
                 check=False)
        node.run("systemctl reset-failed "
                 + " ".join(shlex.quote(u) for u in sorted(units)),
                 check=False)


def wait_osd_processes(node: Node, timeout: int = 60) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if node.run("pgrep -x ceph-osd >/dev/null 2>&1",
                    check=False).returncode != 0:
            return True
        time.sleep(2)
    log(f"警告：[{node.name}] ceph-osd 进程仍在运行")
    return False


def remove_device_lvm(node: Node, dev: str) -> None:
    # 这版 ceph-volume lvm zap 不会先删分区上的 LV，dm 设备仍占用时
    # wipefs 会 EBUSY，所以先按设备找到 ceph VG 并删掉。
    res = node.run(
        f"pvs --noheadings -o vg_name {shlex.quote(dev)} 2>/dev/null",
        check=False)
    vgs = {line.strip() for line in res.stdout.splitlines() if line.strip()}
    for vg in sorted(vgs):
        if not vg.startswith("ceph-"):
            log(f"警告：[{node.name}] {dev} 属于非 ceph VG {vg}，跳过")
            continue
        node.run(f"lvremove -f {shlex.quote(vg)}", check=False)
        node.run(f"vgremove -f {shlex.quote(vg)}", check=False)
        node.run(f"pvremove -f {shlex.quote(dev)}", check=False)


def wait_osds_down(probe: Node, osd_ids: list[str],
                   timeout: int = 60) -> None:
    pending = set(osd_ids)
    deadline = time.time() + timeout
    while pending and time.time() < deadline:
        res = probe.run("ceph osd tree --format json", check=False)
        if res.returncode == 0:
            try:
                tree = json.loads(res.stdout)
            except json.JSONDecodeError:
                tree = {}

            down = {
                str(entry.get("id"))
                for entry in tree.get("nodes") or []
                if isinstance(entry, dict)
                and entry.get("type") == "osd"
                and entry.get("status") == "down"
            }
            present = {
                str(entry.get("id"))
                for entry in tree.get("nodes") or []
                if isinstance(entry, dict) and entry.get("type") == "osd"
            }
            pending -= down
            # 已从 osdmap 删除的 OSD 不会再出现在 tree 里，视为已 down。
            if present:
                pending &= present
            if not pending:
                return
        for osd in pending:
            probe.run(f"ceph osd down {shlex.quote(osd)}", check=False)
        time.sleep(2)
    if pending:
        log(f"警告：等待 OSD down 超时：{', '.join(sorted(pending))}")


def purge_osds(probe: Node, osd_ids: list[str]) -> list[str]:
    if not osd_ids:
        return []
    if probe.run("ceph -s >/dev/null 2>&1", check=False).returncode != 0:
        log("警告：无法连接 mon，跳过 osd purge，直接清理本地数据")
        return []

    wait_osds_down(probe, osd_ids)
    failed: list[str] = []
    for osd in osd_ids:
        # 这版 ceph osd purge 在全部 OSD down、PG 卡在 peering 时会阻塞，
        # 拆成它内部执行的四个步骤，逐步带超时执行。
        probe.run(f"ceph osd out {shlex.quote(osd)}",
                  check=False, timeout=60)
        probe.run(f"ceph osd crush remove osd.{shlex.quote(osd)}",
                  check=False, timeout=60)
        probe.run(f"ceph auth del osd.{shlex.quote(osd)}",
                  check=False, timeout=60)
        res = probe.run(f"ceph osd rm {shlex.quote(osd)}",
                        check=False, timeout=60)
        if res.returncode != 0:
            detail = (res.stderr or res.stdout).strip()
            if "does not exist" in detail or "not found" in detail:
                continue
            log(f"警告：删除 osd.{osd} 失败：{detail[-300:]}")
            failed.append(osd)
    return failed


def zap_node_devices(node: Node, devices: list[str],
                     keep_devices: bool) -> list[str]:
    if not devices:
        return []
    if keep_devices:
        log(f"[{node.name}] 保留 OSD 数据：{', '.join(devices)}")
        return []

    failed: list[str] = []
    for dev in devices:
        if node.run(f"test -b {shlex.quote(dev)}",
                    check=False).returncode != 0:
            log(f"[{node.name}] {dev} 不存在，跳过")
            continue
        mounted = node.run(
            f"lsblk -ln -o MOUNTPOINTS {shlex.quote(dev)}",
            check=False).stdout.strip()
        if mounted:
            log(f"警告：[{node.name}] {dev} 仍被挂载，跳过 zap")
            failed.append(dev)
            continue
        remove_device_lvm(node, dev)
        log(f"[{node.name}] ceph-volume lvm zap {dev}")
        res = node.run(f"ceph-volume lvm zap {shlex.quote(dev)}",
                       check=False, timeout=600)
        if res.returncode != 0:
            # 给内核/OSD 残留引用一点释放时间后重试一次。
            time.sleep(3)
            res = node.run(f"ceph-volume lvm zap {shlex.quote(dev)}",
                           check=False, timeout=600)
        if res.returncode != 0:
            detail = (res.stderr or res.stdout).strip()[-500:]
            log(f"警告：[{node.name}] zap {dev} 失败：{detail}")
            failed.append(dev)
    return failed


def destroy_cluster(cluster: Cluster, nodes: list[Node], state_path: str,
                    keep_devices: bool,
                    info: dict[str, tuple[list[str], list[str]]]) -> bool:
    all_ids = sorted({i for ids, _ in info.values() for i in ids}, key=int)
    mons = [n for n in nodes if n.mon]
    probe = mons[0] if mons else nodes[0]

    # 必须先停 OSD，等进程退出；mon 保持运行以便 purge。
    workers_stopped = True
    for node in nodes:
        ids = info.get(node.name, ([], []))[0]
        log(f"[{node.name}] 停止 rgw/mgr/osd 服务")
        stop_node_services(node, ids)
        if ids and not wait_osd_processes(node):
            workers_stopped = False

    purge_failed = purge_osds(probe, all_ids)

    for node in nodes:
        log(f"[{node.name}] 停止 mon 服务")
        stop_mon_services(node)

    zap_failed: list[str] = []
    for node in nodes:
        discovered = info.get(node.name, ([], []))[1]
        devices = sorted(set(node_devices(node)) | set(discovered))
        zap_failed += zap_node_devices(node, devices, keep_devices)

    for node in nodes:
        log(f"[{node.name}] 清理数据目录和 /etc/ceph 配置")
        # 按目录清理而不是按配置里的 id，兼容手工部署或 id 不一致的情况。
        node.run("rm -rf /var/lib/ceph/mon/* /var/lib/ceph/mgr/* "
                 "/var/lib/ceph/radosgw/* /var/lib/ceph/osd/* "
                 "/var/lib/ceph/bootstrap-*", check=False)
        node.run("rm -f /etc/ceph/ceph.conf "
                 "/etc/ceph/ceph.client.admin.keyring "
                 "/etc/ceph/ceph.mon.keyring "
                 "/etc/ceph/ceph.bootstrap-osd.keyring", check=False)

    if not any(n.is_local for n in nodes):
        local_fsid = read_conf_fsid("/etc/ceph/ceph.conf")
        if cluster.fsid and local_fsid and local_fsid != cluster.fsid:
            log("警告：本机 /etc/ceph 属于其他集群，未删除本机配置")
        else:
            log("清理本机 /etc/ceph 配置")
            run("rm -f /etc/ceph/ceph.conf "
                "/etc/ceph/ceph.client.admin.keyring "
                "/etc/ceph/ceph.mon.keyring", check=False)

    failed = bool(purge_failed or zap_failed or not workers_stopped)
    if failed:
        log("警告：销毁未完全成功")
        if purge_failed:
            log(f"  未 purge 的 OSD：{', '.join(purge_failed)}")
        if zap_failed:
            log(f"  未清理的设备：{', '.join(zap_failed)}")
        if not workers_stopped:
            log("  部分 ceph-osd 进程未退出")
        if os.path.exists(state_path):
            log(f"  状态文件保留：{state_path}")
    else:
        try:
            os.remove(state_path)
            log(f"已删除状态文件 {state_path}")
        except FileNotFoundError:
            pass

    print()
    log("销毁结果")
    for node in nodes:
        res = node.run(
            "systemctl list-units --state=active --plain --no-legend "
            "'ceph-mon@*' 'ceph-mgr@*' 'ceph-radosgw@*' "
            "'ceph-osd@*' 'ceph-volume@lvm-*' "
            "2>/dev/null | awk '{print $1}'", check=False)
        left = res.stdout.split()
        state = "仍活动: " + ", ".join(left) if left else "无活动单元"
        print(f"  {node.name:<18} {state}")

    if failed:
        log("销毁未完成，请按上面的警告处理后重试。")
        return False
    log("销毁完成。确认磁盘可复用后可重新执行 --apply 部署新集群。")
    return True


def summary(nodes: list[Node]) -> None:
    print()
    log("集群状态")
    res = run("ceph -s", check=False)
    print(res.stdout or res.stderr)
    log("服务状态")
    for node in nodes:
        units = []
        if node.mon:
            units.append(f"ceph-mon@{node.mon_id}")
        if node.mgr:
            units.append(f"ceph-mgr@{node.mgr_id}")
        if node.rgw:
            units.append(f"ceph-radosgw@{node.rgw_id}")
        if not units:
            continue
        args = " ".join(units)
        res = node.run(f"systemctl is-active {args} 2>/dev/null | tr '\\n' ' '",
                       check=False)
        print(f"  {node.name:<18} {res.stdout.strip()}")
    for node in nodes:
        if node.rgw:
            print(f"  RGW 入口：http://{node.address}:{node.rgw_port}")


def preflight(cluster: Cluster, nodes: list[Node], for_apply: bool,
              force: bool = False) -> None:
    check_local_tools(any(n.rgw for n in nodes))
    check_ssh_tools(nodes)
    for node in nodes:
        check_node(node)
        if node.partition_disk:
            inspect_partition_disk(node, warn_only=not for_apply)
    if for_apply:
        for node in nodes:
            other_cluster_on(node, cluster.fsid, force=force)


def check_report(cluster: Cluster, nodes: list[Node]) -> None:
    log("预检查通过")
    for node in nodes:
        used = used_osd_devices(node) if not node.partition_disk else set()
        for dev in node_devices(node):
            if node.partition_disk:
                break
            state = "已被 OSD 使用" if dev in used else "空闲"
            if node.run(f"test -b {shlex.quote(dev)}",
                        check=False).returncode != 0:
                state = "设备不存在"
            print(f"  {node.name:<18} {dev:<20} {state}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="部署或销毁单/多节点 Ceph 集群（RPM 版，默认 dry-run）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "示例:\n"
            "  ./script/deploy-ceph.py -c conf/deploy-ceph.toml\n"
            "  ./script/deploy-ceph.py -c conf/deploy-ceph.toml --check\n"
            "  ./script/deploy-ceph.py -c conf/deploy-ceph.toml --apply\n"
            "  ./script/deploy-ceph.py -c conf/deploy-ceph.toml --destroy\n"
            "  ./script/deploy-ceph.py -c conf/deploy-ceph.toml --destroy --apply\n"
        ))
    parser.add_argument("-c", "--config", default=DEFAULT_CONFIG,
                        help="TOML 配置文件（默认 conf/deploy-ceph.toml）")
    parser.add_argument("--check", action="store_true",
                        help="只做预检查（SSH/命令/磁盘），不做任何变更")
    parser.add_argument("--apply", action="store_true",
                        help="真正执行部署或销毁（默认只打印计划）")
    parser.add_argument("--destroy", action="store_true",
                        help="销毁配置中定义的集群（默认只打印计划）")
    parser.add_argument("--keep-devices", action="store_true",
                        help="销毁时保留 OSD 设备上的数据（不执行 lvm zap）")
    parser.add_argument("--force", action="store_true",
                        help="允许覆盖/销毁 fsid 与目标不同的集群")
    parser.add_argument("--version", action="version",
                        version=f"deploy-ceph {VERSION}")
    args = parser.parse_args(argv)

    try:
        cluster, nodes = load_config(args.config)
        state_path = str(Path(args.config).with_suffix(STATE_SUFFIX))
        state = {}
        if os.path.exists(state_path):
            try:
                state = json.loads(Path(state_path).read_text())
            except (OSError, json.JSONDecodeError):
                state = {}

        if args.keep_devices and not args.destroy:
            die("--keep-devices 只能和 --destroy 一起使用")

        if args.destroy:
            if args.apply and os.geteuid() != 0:
                die("--destroy --apply 需要 root 权限")
            cluster.fsid = cluster.fsid or str(state.get("fsid", ""))
            if args.apply and not cluster.fsid and not args.force:
                die("销毁需要已知 fsid：请在配置中设置 fsid、保留 state 文件，"
                    "或加 --force 确认销毁任意集群")
            destroy_plan(cluster, nodes, state_path, args.keep_devices)
            if args.check:
                info = destroy_preflight(cluster, nodes, args.force,
                                         args.keep_devices)
                destroy_check_report(cluster, nodes, info, args.keep_devices)
                return 0
            if not args.apply:
                log("这是销毁预演，未做任何变更。执行销毁请加 --destroy --apply")
                return 0
            info = destroy_preflight(cluster, nodes, args.force,
                                     args.keep_devices)
            ok = destroy_cluster(cluster, nodes, state_path,
                                 args.keep_devices, info)
            return 0 if ok else 1

        if args.apply:
            if os.geteuid() != 0:
                die("--apply 需要 root 权限")
            if not cluster.fsid:
                cluster.fsid = str(state.get("fsid") or uuid.uuid4())
            Path(state_path).write_text(
                json.dumps({"fsid": cluster.fsid}, indent=2) + "\n")
        else:
            cluster.fsid = cluster.fsid or state.get("fsid", "")

        print_plan(cluster, nodes, state_path)

        if args.check:
            preflight(cluster, nodes, for_apply=False)
            check_report(cluster, nodes)
            return 0
        if not args.apply:
            log("这是预演，未做任何变更。执行部署请加 --apply")
            return 0

        preflight(cluster, nodes, for_apply=True, force=args.force)
        with __import__("tempfile").TemporaryDirectory(prefix="deploy-ceph-") as wd:
            conf = render_conf(cluster, nodes)
            log("部署 mon / 写入 ceph.conf")
            deploy_mons(cluster, nodes, conf, wd)
            log("部署 mgr")
            deploy_mgrs(nodes)
            log("部署 OSD")
            deploy_osds(cluster, nodes)
            log("部署 RGW")
            deploy_rgws(cluster, nodes)
        summary(nodes)
        log("部署完成")
        return 0
    except DeployError as exc:
        print(f"[deploy-ceph] 错误：{exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\n[deploy-ceph] 已中断", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
