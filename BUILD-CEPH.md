# Ceph 编译与 RPM 打包指南

`build-ceph.sh` 是一键构建脚本，支持三种模式：

| 模式 | 参数 | 说明 |
| --- | --- | --- |
| 二进制编译（默认） | 无 | 用 cmake + ninja 编译出 `build/bin` 下的可执行文件 |
| RPM 打包 | `--rpm` | 生成源码 tarball 并用 rpmbuild 打出 RPM 包 |
| 两者都做 | `--both` | 先编译二进制，再打 RPM 包 |
| 安装 RPM | `--install` | 安装已打好的 RPM 及其运行时依赖（不编译） |
| 安装二进制 | `--install-binaries` | 编译后执行 `cmake --install` 安装到 `INSTALL_PREFIX`（默认 `/usr/local`） |

加 `--install-rpms` 可在打 RPM 之后自动安装（如 `--rpm --install-rpms`），
`--install-binaries` 可与 `--rpm`/`--both` 组合，先装二进制再打包。

所有依赖下载（dnf、pip、make-dist 中的源码包）都通过远端主机
`43.163.78.103` 提供的 SSH SOCKS5 代理完成，不需要本机直连外网。
远端登录密码不写在脚本里，首次使用前需配置（见第 2 节）。

---

## 1. 环境要求

- openEuler 24.03 LTS-SP1（或其他 RHEL 9 系发行版）
- GCC 12+、CMake 3.27+、ninja、python3
- 本机预装：`sshpass`、`curl`、`dnf-plugins-core`；RPM 模式还需要 `rpm-build`
- 磁盘空间：二进制编译约 35 GB，RPM 打包另需约 40 GB，建议预留 100 GB 以上
- 能通过 SSH 密码登录 `43.163.78.103`（脚本用 `sshpass` 自动登录）

首次使用 RPM 模式时安装打包工具：

```bash
dnf install -y rpm-build bzip2 git tar
```

> 脚本自身会通过代理安装 Ceph 的全部编译依赖（`dnf builddep`），
> 包括 openEuler 缺失、需从远端回传的 `libnbd-devel`。

---

## 2. 配置远端凭据

远端密码不写进脚本（避免提交到 git）。首次使用前二选一：

```bash
# 方式一：环境变量（优先级最高）
export REMOTE_PASS='你的密码'
./build-ceph.sh --rpm
```

```bash
# 方式二：TOML 配置文件
# 仓库自带模板 build-ceph.toml，按需修改即可
vi build-ceph.toml
chmod 600 build-ceph.toml
```

TOML 模板结构（脚本用 python3 的 `tomllib` 解析，需 Python 3.11+）：

```toml
[remote]
host = "43.163.78.103"
user = "root"
port = 1080
password = "你的密码"      # 也可以不填，改用 REMOTE_PASS 环境变量

[build]
jobs = 12
build_type = "RelWithDebInfo"
tests = false
parquet = false
sync_submodules = true
submodule_jobs = 8

[rpm]
version = "21.3.0"
```

优先级：**命令行参数 > 环境变量 > `build-ceph.toml` > 脚本默认值**。
仓库中的模板不含真实凭据；本地填入密码后，可用下面的命令让 git
忽略该文件的改动：

```bash
git update-index --skip-worktree build-ceph.toml
```

也可以用 `CONFIG_FILE=/path/to/other.toml` 指定其他配置文件。

## 3. 快速开始

在源码树根目录执行：

```bash
cd /root/ceph

# 1) 只编译二进制
./build-ceph.sh

# 2) 只打 RPM 包
./build-ceph.sh --rpm

# 3) 二进制 + RPM
./build-ceph.sh --both

# 4) 打 RPM 并直接安装（含运行时依赖）
./build-ceph.sh --rpm --install-rpms

# 5) 安装之前已打好的 RPM
./build-ceph.sh --install

# 6) 编译并安装二进制到 /usr/local（默认前缀）
./build-ceph.sh --install-binaries

# 7) 指定安装前缀
INSTALL_PREFIX=/opt/ceph ./build-ceph.sh --install-binaries
```

需要 root 权限（安装依赖、写系统目录），非 root 用户请用 `sudo`。

常用组合：

```bash
# 依赖已装好时跳过依赖安装，节省时间
./build-ceph.sh --skip-deps

# 全量重来：清掉 build/ 和 build-rpms/
./build-ceph.sh --both --clean

# 指定并行度和 RPM 版本
./build-ceph.sh --rpm --jobs 16 --rpm-version 21.3.0-1
```

---

## 4. 参数说明

| 参数 | 说明 |
| --- | --- |
| `--rpm` | RPM 打包模式 |
| `--both` | 二进制 + RPM |
| `--install` | 安装 `build-rpms/RPMS` 下已打好的 RPM，并自动补齐运行时依赖 |
| `--install-rpms` | 打包完成后立即安装（可与 `--rpm`/`--both` 组合） |
| `--install-binaries` | 编译（必要时）后执行 `cmake --install`，把二进制安装到 `INSTALL_PREFIX`；别名 `--install-bin` |
| `--rpm-version VERSION` | RPM 版本号，默认 `21.3.0`。可写成 `21.3.0-1`（`-` 后为 release），也支持环境变量 `RPM_VERSION` |
| `--clean` | 启动前删除 `build/`（以及非纯二进制模式下的 `build-rpms/`） |
| `--skip-deps` | 跳过依赖安装 |
| `--skip-submodules` | 跳过 git 子模块自动下载 |
| `--jobs N` | 并行编译任务数，默认 `nproc` |
| `--build-type TYPE` | CMake 构建类型，默认 `RelWithDebInfo` |
| `--with-tests` | 编译单元测试（默认关闭，且不再联网拉取 Catch2） |
| `--with-parquet` | 编译 RGW S3 Select parquet 支持（默认关闭，需内置 Arrow，编译很慢） |
| `-h`, `--help` | 显示帮助 |

环境变量覆盖（优先级高于 TOML 配置）：

```
REMOTE_HOST REMOTE_USER REMOTE_PASS PROXY_PORT
BUILD_DIR LOG_DIR RPM_TOP RPM_VERSION JOBS BUILD_TYPE
WITH_TESTS WITH_PARQUET SYNC_SUBMODULES SUBMODULE_JOBS
INSTALL_PREFIX
```

`SYNC_SUBMODULES=0` 等价于 `--skip-submodules`；`SUBMODULE_JOBS` 是
子模块并行下载数（默认 8）；`INSTALL_PREFIX` 是二进制安装前缀
（默认 `/usr/local`，同时作为 CMake 的 `CMAKE_INSTALL_PREFIX`）。

其中 `REMOTE_PASS` 必填；脚本不会在命令行参数里接受密码。

例如换一台跳板机：

```bash
REMOTE_HOST=10.0.0.5 REMOTE_USER=ops REMOTE_PASS=secret ./build-ceph.sh --rpm
```

---

## 5. 脚本做了什么

1. **启动代理**：若本机 1080 端口没有可用 SOCKS5 代理，就用 `sshpass + ssh -D`
   在远端主机上开一个动态转发端口，退出时自动关闭；已有可用代理则直接复用。
2. **自动下载子模块**：检测 `git submodule status --recursive` 中未初始化的
   子模块（rocksdb、zstd、arrow、isa-l 等），然后执行
   `git submodule sync/update --init --recursive`。git 走上面的 SOCKS5 隧道，
   即由 `43.163.78.103` 访问 GitHub 并把对象经 SSH 隧道回传到运行脚本的
   构建机（如 `192.168.1.3`），本机无需直连外网。已初始化的子模块直接跳过，
   但会检查其工作区是否缺少跟踪文件（例如中断的 checkout 留下的空目录），
   缺失时从本地对象库自动恢复；`--skip-submodules` 可关闭此步骤。
3. **安装依赖**：openEuler 上用 `dnf builddep` 解析 `ceph.spec.in` 安装依赖；
   `libnbd-devel` 在 openEuler 源里没有，脚本会在远端（CentOS Stream 9）
   执行 `dnf download --resolve` 再 `scp` 回来安装。
4. **二进制模式**：
   - 准备 cephadm 的离线 wheelhouse（`.cache/cephadm-wheelhouse/`），
     避免临时 venv 中的 pip 无法走 SOCKS 代理；
   - `cmake -GNinja` 配置（`CMAKE_INSTALL_PREFIX=${INSTALL_PREFIX}`），
     `ninja` 编译；
   - 指定 `--install-binaries` 时执行 `cmake --install build`，把可执行文件、
     库、头文件等安装到 `INSTALL_PREFIX`（默认 `/usr/local`）。
5. **RPM 模式**：
   - 用仓库自带 `make-dist` 生成 `ceph-<版本>.tar.bz2`：
     - 通过一个 `wget -> curl` 的 shim 走代理下载 boost / liburing / pmdk；
     - 通过补丁副本跳过 Dashboard 前端 npm 构建（spec 本身以
       `WITH_MGR_DASHBOARD_FRONTEND=OFF` 编译，预生成的 dashboard JSON 已随源码提供）；
   - 从 `ceph.spec.in` 生成 spec（替换版本占位符），并做这些适配：
     - 放宽 `gcc-c++ >= 13.3` 限制（openEuler 自带 GCC 12.3）；
     - 增加 `-DWITH_CATCH2:BOOL=OFF`，避免联网拉取 Catch2；
     - 增加 `-DWITH_RADOSGW_SELECT_PARQUET:BOOL=OFF`，避免内置 Arrow 编译；
     - openEuler 的 python rpm 宏缺少 `py3_shebang_fix`，改为空操作；
     - 关闭 openEuler 全局的 `brp-python-bytecompile`，避免产生未打包的
       `__pycache__`（spec 自己会对 sitelib 做字节编译）；
     - 将仅由 `ceph-test` 子包收录的 `ceph_ec_consistency_checker`
       从主包中排除（因为我们关闭了 `ceph_test_package`）；
     - openEuler 不提供 `python3-asyncssh`，把 `ceph-mgr-cephadm` 对它的
       硬依赖降为 `Recommends`（运行时由脚本用 pip 安装 asyncssh）；
   - 执行 `rpmbuild -ba`，并关闭：`crimson`、`ceph_test_package`、
     `dwz`、`cephadm_bundling`。
6. **安装 RPM**（`--install` / `--install-rpms`）：
   - 先用 `dnf` 安装 openEuler 源里存在的运行时依赖：`luarocks`、
     `python3-cherrypy`、`python3-natsort`、`python3-pyOpenSSL`、
     `python3-routes`、`python3-numpy`、`python3-scikit-learn`、
     `python3-scipy`、`python3-kubernetes`、`python3-jsonpatch`、
     `resource-agents`；
   - `python3-asyncssh` 不在 openEuler 源中，通过 pip 安装（走 SOCKS 代理，
     失败时改由远端主机下载 wheel 再回传）；
   - 最后 `dnf install build-rpms/RPMS/x86_64/*.rpm` 安装全部 Ceph RPM。

源码 tarball 生成一次后会保留在 `build-rpms/SOURCES/`，后续打包直接复用；
要重新生成请加 `--clean`。

---

## 6. 输出位置

| 内容 | 路径 |
| --- | --- |
| 二进制 | `build/bin/`（`ceph`、`rados`、`rbd`、`radosgw`、`ceph-mon/osd/mgr/mds`、`cephadm` 等） |
| RPM | `build-rpms/RPMS/x86_64/*.rpm` |
| SRPM | `build-rpms/SRPMS/*.src.rpm` |
| rpmbuild 工作目录 | `build-rpms/BUILD`、`BUILDROOT` 等 |
| 运行日志 | `build-logs/build-<时间戳>.log` |
| SSH 代理日志 | `build-logs/ssh-proxy.log` |
| 源码 tarball | `build-rpms/SOURCES/ceph-<版本>.tar.bz2` |

验证二进制：

```bash
build/bin/ceph --version
build/bin/rbd --version
```

安装二进制：

```bash
./build-ceph.sh --install-binaries                 # 默认装到 /usr/local
INSTALL_PREFIX=/opt/ceph ./build-ceph.sh --install-binaries
```

安装 RPM：

```bash
# 推荐：脚本自动补齐运行时依赖（含 pip 安装 asyncssh）
./build-ceph.sh --install

# 等价的手工步骤（先装依赖，再装包）
dnf install -y luarocks python3-cherrypy python3-natsort python3-pyOpenSSL \
    python3-routes python3-numpy python3-scikit-learn python3-scipy \
    python3-kubernetes python3-jsonpatch resource-agents
python3 -m pip install asyncssh
dnf install -y ./build-rpms/RPMS/x86_64/*.rpm
```

---

## 7. 耗时统计

脚本结束时会打印对齐的耗时表，百分比以总耗时为基准：

```
[2026-11-12 23:18:32] 构建完成，耗时统计
  子模块   : 3m05s      (  4.6%)
  依赖安装 : 8m12s      ( 12.5%)
  配置     : 1m40s      (  2.5%)
  编译     : 52m03s     ( 79.0%)
  打包     : 3m55s      (  6.0%)
  ----------------------------------
  总计     : 1h05m50s   (100.0%)
```

“子模块”行只在本次确实下载了子模块（耗时大于 0）时显示；
纯二进制模式不显示“打包”行，纯 RPM / `--install` 模式不显示“配置/编译”行，
“二进制安装”行只在执行 `--install-binaries` 时显示，
“安装”行只在执行 RPM 安装时显示，
“依赖安装”用 `--skip-deps` 跳过时显示 `0s`。

---

## 8. 默认关闭的功能

为了在 openEuler 上稳定、快速地完成构建，以下功能默认关闭：

- 单元测试（`WITH_TESTS=OFF`，同时 `WITH_CATCH2=OFF`，不联网拉取 Catch2）
- Dashboard 前端（`WITH_MGR_DASHBOARD_FRONTEND=OFF`，RPM 使用预生成 dashboard）
- Jaeger（`WITH_JAEGER=OFF`）
- Crimson（`WITH_CRIMSON=OFF`）
- RGW S3 Select parquet（默认关闭，RPM 模式强制关闭）
- RPM 模式下额外关闭：单元测试包、dwz 压缩、cephadm 依赖打包
  （`CEPHADM_BUNDLED_DEPENDENCIES=none`）

---

## 9. 常见问题

**安装 RPM 时报缺少 python3-cherrypy / luarocks / resource-agents 等依赖**

直接运行 `./build-ceph.sh --install`，脚本会用 `dnf` 安装这些运行时依赖，
并用 pip 安装 openEuler 源里没有的 `python3-asyncssh`，然后再安装
`build-rpms/RPMS/x86_64/*.rpm`。注意 `python3-asyncssh` 降级为
`Recommends` 的 spec 修改只对本次构建生成的 RPM 生效；旧 RPM 请重新
执行一次 `--rpm`。

**两个终端同时执行脚本**

脚本会对 `build-logs/build.lock` 加 `flock`，第二个进程会直接报错退出。
请等前一个任务结束（或确认没有 `build-ceph.sh`/`ninja` 进程）后再执行。

**安装时提示 `cannot install both ... from @commandline`**

说明 `build-rpms/RPMS` 下同一版本包存在多份，常见于中断过的 RPM 重建
（新包落在 `RPMS/noarch`，旧包仍留在 `RPMS/x86_64`）。`--install` 会按
`name-version-release.arch` 去重，并优先使用修改时间最新的文件，日志中会
打印忽略了几个重复文件。直接重跑 `./build-ceph.sh --install` 即可，
不需要手工删包。

**编译时报 `file STRINGS ... src/rocksdb/include/rocksdb/version.h cannot be read`**

说明 rocksdb 子模块目录被清空了。脚本启动时会自动检测并恢复缺失的
跟踪文件；若仍未解决，可手动执行
`git submodule update --init --recursive -- src/rocksdb` 后重跑。

**代理起不来 / 端口被占用**

查看 `build-logs/ssh-proxy.log`；换端口：

```bash
PROXY_PORT=1081 ./build-ceph.sh
```

如果端口被别的程序占用且不是可用代理，脚本会直接报错退出。

**子模块下载失败 / 中断**

脚本只处理 `git submodule status --recursive` 中前缀为 `-` 的子模块，
失败会直接退出；重跑同一条命令会从断点继续。若某个子模块残留半成品目录，
确认其中没有本地改动后可先 `git submodule deinit -f <路径>` 再重跑。
临时跳过：`--skip-submodules`（需要子模块已就位，否则编译会失败）。

**依赖下载很慢**

脚本已设置 `max_parallel_downloads=10`。速度仍慢时先确认本机到
`43.163.78.103` 的带宽，SSH 隧道吞吐是瓶颈。

**`rpmbuild: command not found`**

```bash
dnf install -y rpm-build bzip2
```

**`libnbd-devel` 安装失败**

脚本会自动从远端下载回传；若远端源里也找不到，检查远端是否可访问
CentOS Stream 9 仓库，或手动准备 RPM 后重跑。

**二进制编译时 cephadm pip 报网络错误**

脚本用 `.cache/cephadm-wheelhouse/` 离线安装 Jinja2/MarkupSafe/PyYAML。
该目录缺少文件时会自动重新下载；也可直接删除它让脚本重建。

**想改版本号 / 重新生成 tarball**

```bash
./build-ceph.sh --rpm --rpm-version 21.3.0-1 --clean
```

**只想重打包、复用已有 tarball**

不加 `--clean` 直接 `./build-ceph.sh --rpm`，脚本会复用
`build-rpms/SOURCES/ceph-<版本>.tar.bz2`。

**磁盘不足**

`--clean` 会删除 `build/` 和 `build-rpms/`，确认无保留内容后再执行。
