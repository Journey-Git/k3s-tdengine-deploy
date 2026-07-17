# TDengine K3s 原生 YAML 部署文档

## 一、概述

本文档描述使用原生 Kubernetes YAML 资源在 K3s 集群中部署 TDengine 3.x 时序数据库。

部署方案基于 [TDengine-Operator 3.0 分支](https://github.com/taosdata/TDengine-Operator/tree/3.0) 官方手动部署规范，适配 K3s 单节点环境。

## 文件结构

```
k8s-native/
├── README.md                 # 本文档（公共）
├── DEPLOYMENT_SUMMARY.md     # 部署总结（公共）
│
├── local-path/               # 方案一：local-path 自动管理
│   ├── tdengine_configmap.yaml   # taos.cfg 配置
│   ├── tdengine.yaml             # Service + StatefulSet
│   ├── kustomization.yaml        # Kustomize 配置（引用上面文件）
│   ├── deploy.sh                 # 一键部署脚本
│   └── uninstall.sh              # 卸载脚本
│
└── hostpath/                 # 方案二：hostPath 手动指定路径
    ├── tdengine_configmap.yaml   # taos.cfg 配置
    ├── tdengine_hostpath.yaml    # PV + PVC + Service + StatefulSet
    ├── kustomization.yaml        # Kustomize 配置（引用上面文件）
    ├── deploy.sh                 # 一键部署脚本
    └── uninstall.sh              # 卸载脚本
```

> **说明**：每个方案文件夹内包含 4 个 YAML 文件 + 2 个脚本文件，可直接进入对应文件夹独立部署，无需依赖父目录文件。
>
> **文档文件**（`README.md`、`DEPLOYMENT_SUMMARY.md`）仅在父目录保留，子文件夹不重复。

## 持久化方案选择

| 方案 | 目录 | 数据路径 | 日志路径 | 宿主机路径 | 适用场景 |
|------|------|---------|---------|-----------|---------|
| **方案一：local-path 自动** | `local-path/` | `/var/lib/taos` | `/var/log/taos` | local-path 自动分配 | 数据+日志持久化，自动分配路径 |
| **方案二：hostPath 手动** | `hostpath/` | `/var/lib/taos` | `/var/log/taos` | `/mnt/disk1/k3s/tdengine` | 需要指定存储路径，数据持久化 |

> **注意**：方案一数据目录和日志均已挂载 PVC，数据持久化。如需指定固定路径，使用方案二。

## 二、前置要求

1. **K3s 集群**已正常运行
2. **kubectl** 命令行工具已配置
3. **StorageClass** 已配置（用于数据持久化）

## 三、部署架构

```
┌─────────────────────────────────────────┐
│           K3s Single Node               │
│  ┌─────────────────────────────────┐    │
│  │   Namespace: ecloud             │    │
│  │  ┌─────────────────────────┐    │    │
│  │  │  StatefulSet: tdengine  │    │    │
│  │  │  replicas: 1            │    │    │
│  │  │  image: tdengine:3.3.6.13│   │    │
│  │  └─────────────────────────┘    │    │
│  │           │                     │    │
│  │  ┌────────┴────────────────┐    │    │
│  │  │ Service: tdengine-service│   │    │
│  │  │  - ClusterIP (内部访问)  │    │    │
│  │  │  - 端口: 6030, 6041      │    │    │
│  │  └─────────────────────────┘    │    │
│  │           │                     │    │
│  │  ┌────────┴────────────────┐    │    │
│  │  │ Service: tdengine-nodeport│   │    │
│  │  │  - NodePort (外部访问)   │    │    │
│  │  │  - 30441: taosAdapter    │    │    │
│  │  │  - 30603: taosd          │    │    │
│  │  │  - 30660: taosExplorer   │    │    │
│  │  └─────────────────────────┘    │    │
│  │           │                     │    │
│  │  ┌────────┴────────────────┐    │    │
│  │  │ PVC: taosdata (5Gi)      │    │    │
│  │  └─────────────────────────┘    │    │
│  └─────────────────────────────────┘    │
└─────────────────────────────────────────┘
```

## 四、核心配置说明（对齐官方规范）

### 4.1 FQDN 配置（关键！）

官方 3.0 规范要求必须设置以下环境变量，确保集群内 DNS 解析正确：

| 环境变量 | 来源 | 说明 |
|---------|------|------|
| `POD_NAME` | `metadata.name` | Pod 名称，如 `tdengine-0` |
| `SERVICE_NAME` | 硬编码 `tdengine-service` | Service 名称，用于 DNS |
| `STS_NAME` | 硬编码 `tdengine` | StatefulSet 名称 |
| `STS_NAMESPACE` | `metadata.namespace` | 命名空间 |
| `TAOS_FQDN` | 组合值 | `$(POD_NAME).$(SERVICE_NAME).$(STS_NAMESPACE).svc.cluster.local` |
| `TAOS_FIRST_EP` | 组合值 | `$(STS_NAME)-0.$(SERVICE_NAME).$(STS_NAMESPACE).svc.cluster.local:6030` |

> **重要**：`TAOS_FQDN` 必须在 K8s 环境中设置，否则 dnode 注册会使用 IP 地址，导致集群通信失败。

### 4.2 探针配置

> **注意**：TDengine 3.4.x 版本起，`taos-check` 命令需要显式参数。3.3.x 及更早版本使用无参数形式。

**3.4.x 版本配置（当前使用）：**

```yaml
startupProbe:
  exec:
    command: ["taos-check", "startup"]
  failureThreshold: 360
  periodSeconds: 10

readinessProbe:
  exec:
    command: ["taos-check", "service"]
  initialDelaySeconds: 5
  timeoutSeconds: 5000

livenessProbe:
  exec:
    command: ["taos-check", "service"]
  initialDelaySeconds: 15
  periodSeconds: 20
```

**3.3.x 及更早版本配置（已废弃）：**

```yaml
startupProbe:
  exec:
    command: ["taos-check"]  # 3.4.x 起不兼容
```

**版本兼容性说明：**

| TDengine 版本 | `taos-check` 用法 | 说明 |
|-------------|------------------|------|
| 3.3.x 及更早 | `taos-check`（无参数） | 直接检测服务状态 |
| 3.4.x 及以后 | `taos-check [startup\|service]` | 必须指定子命令：`startup` 用于启动检测，`service` 用于就绪/存活检测 |

> 3.4.x 使用无参数 `taos-check` 会报错：`usage: taos-check [startup|service]`，导致 Pod 无法就绪。

### 4.3 端口列表

TDengine 3.x 暴露端口：

| 端口 | 用途 |
|------|------|
| 6030 | taosd 服务端口（客户端连接、集群通信） |
| 6041 | taosAdapter REST API（InfluxDB Line Protocol 写入、HTTP 查询） |
| 6060 | taosExplorer / taosx 管理界面 |

### 4.4 存储配置

使用单 PVC 方式（官方推荐）：

```yaml
volumeClaimTemplates:
  - metadata:
      name: taosdata
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: local-path
      resources:
        requests:
          storage: 5Gi
```

## 五、部署步骤

### 5.1 检查 K3s 集群状态

```bash
# 查看节点状态
kubectl get nodes

# 查看 StorageClass
kubectl get sc

# 确认 local-path 存在（K3s 默认自带）
kubectl get sc local-path
```

### 5.2 方案一：local-path 自动部署（默认）

```bash
./deploy.sh
```

或手动执行：

```bash
kubectl apply -k .
```

> **注意**：此方案数据目录和日志均已挂载 PVC，数据持久化。生产环境可直接使用。

### 5.3 方案二：hostPath 手动部署（指定宿主机路径）

**前置准备：**

```bash
# 1. 创建宿主机目录
sudo mkdir -p /mnt/disk1/k3s/tdengine

# 2. 设置权限（与容器内用户一致）
sudo chmod 755 /mnt/disk1/k3s/tdengine
```

**部署：**

```bash
# 使用方案二配置
cp hostpath/tdengine_hostpath.yaml local-path/tdengine.yaml
kubectl apply -k .
```

或单独应用：

```bash
# 1. 部署 ConfigMap
kubectl apply -f tdengine_configmap.yaml

# 2. 部署应用（含 PV + PVC + Service + StatefulSet）
kubectl apply -f hostpath/tdengine_hostpath.yaml
```

### 5.4 验证部署

```bash
# 查看 Pod 状态
kubectl get pods -n ecloud -l app=tdengine

# 查看服务
kubectl get svc -n ecloud

# 查看 PVC
kubectl get pvc -n ecloud

# 验证 TDengine 服务
kubectl exec -it tdengine-0 -n ecloud -- taos -s "show dnodes; show mnodes"

# 测试 taosAdapter REST 接口
curl -u root:taosdata http://<node-ip>:30441/rest/sql -d "show databases"
```

## 六、服务端口说明

| 端口 | 协议 | 用途 | 访问方式 |
|------|------|------|---------|
| 6030 | TCP | taosd 服务端口（客户端连接、集群 dnode 通信） | NodePort 30603 |
| 6041 | TCP | taosAdapter REST API（InfluxDB Line Protocol 写入、HTTP 查询） | NodePort 30441 |
| 6060 | TCP | taosExplorer / taosx 管理界面 | NodePort 30660 |

## 七、扩展为集群（后续操作）

当单节点无法满足需求时，可按官方规范扩展：

```bash
# 1. 修改 statefulset.yaml 中 replicas: 3
# 2. 修改 TAOS_CLUSTER: "1"
# 3. 添加 Pod 反亲和性配置
# 4. 应用更新
kubectl apply -k .

# 5. 验证集群
kubectl exec -it tdengine-0 -n ecloud -- taos -s "show dnodes"
```

**缩容注意事项**（官方强调）：

1. 必须先 `drop dnode` 再缩容：
   ```bash
   kubectl exec -it tdengine-0 -n ecloud -- taos -s "drop dnode <id>"
   kubectl scale statefulset tdengine --replicas=2
   ```
2. 缩容后必须删除对应 PVC：
   ```bash
   kubectl delete pvc taosdata-tdengine-3 -n ecloud
   ```
3. 检查数据库 replica 数，确保剩余节点 >= 最大 replica

## 八、数据迁移步骤

### 8.1 创建目标数据库

```bash
kubectl exec -it tdengine-0 -n ecloud -- taos

# 在 taos shell 中执行
CREATE DATABASE IF NOT EXISTS product_basic KEEP 365 VGROUPS 4 PRECISION 'ns';
USE product_basic;

# 创建超级表
CREATE STABLE IF NOT EXISTS fitness_result (
    ts TIMESTAMP,
    attempts DOUBLE,
    score_text BINARY(64),
    score_value DOUBLE
) TAGS (
    item_code BINARY(64),
    student_id BINARY(64)
);
```

### 8.2 数据导入

```bash
python tdengine_import_parallel.py \
  --db product_basic \
  --input ./dump \
  --host <k3s-node-ip> \
  --port 30441 \
  --processes 8
```

## 九、运维命令

```bash
# 查看日志
kubectl logs -f tdengine-0 -n ecloud

# 查看 Pod 详情
kubectl describe pod tdengine-0 -n ecloud

# 进入容器
kubectl exec -it tdengine-0 -n ecloud -- /bin/bash

# 进入 taos shell
kubectl exec -it tdengine-0 -n ecloud -- taos

# 备份数据
kubectl exec -it tdengine-0 -n ecloud -- taosdump -o /tmp/backup -D product_basic

# 卸载（完全卸载，含数据删除）
./uninstall.sh

# 卸载（保留数据，只删除 StatefulSet/Service/ConfigMap）
./uninstall.sh --keep-data

# 完全手动清理（只删除 TDengine 相关资源，保留 Namespace）
kubectl delete statefulset tdengine -n ecloud
kubectl delete svc -l app=tdengine -n ecloud
kubectl delete pvc -l app=tdengine -n ecloud

# ⚠️  危险操作：删除整个 Namespace 会清空该空间下所有服务
# 如需执行，请确认 Namespace 下只有 TDengine 且无其他重要资源
# kubectl delete namespace ecloud
```

## 十、注意事项

1. **FQDN 必须正确**：`TAOS_FQDN` 和 `TAOS_FIRST_EP` 使用官方推荐的组合方式，确保 DNS 解析正确
2. **数据库命名**：InfluxDB 中的 `product-basic` 在 TDengine 中需改为 `product_basic`（使用下划线）
3. **时区配置**：默认使用 `UTC`
4. **密码安全**：默认 root 密码为 `taosdata`，生产环境请务必修改
5. **资源限制**：单节点建议至少 2C4G
6. **存储容量**：根据数据量预估设置 PVC 大小，建议预留 50% 余量

## 十一、故障排查

| 现象 | 可能原因 | 解决方法 |
|------|---------|---------|
| Pod 无法启动 | 存储类不存在 | 检查 `kubectl get sc`，确认 StorageClass 配置正确 |
| 连接被拒绝 | 端口未暴露 | 检查 Service 类型和 NodePort 配置 |
| 写入失败 | 数据库/表未创建 | 先执行建库建表 SQL |
| dnode 显示 offline | FQDN 配置错误 | 检查 `TAOS_FQDN` 环境变量和 DNS 解析 |
| 性能低下 | 资源不足 | 增加 CPU/内存限制，或扩展为集群模式 |

## 附录：镜像地址

### 默认镜像地址

```
tdengine/tsdb:3.4.1.13
```

### 镜像拉取策略

`statefulset.yaml` 中配置：

```yaml
image: tdengine/tsdb:3.4.1.13
imagePullPolicy: IfNotPresent
```

| 策略 | 说明 |
|------|------|
| `IfNotPresent` | 本地没有时才拉取（默认） |
| `Always` | 每次启动都强制拉取 |
| `Never` | 只使用本地镜像 |

### 离线导入镜像

如果节点无法访问 Docker Hub，可手动导入：

```bash
# 1. 在有网络的机器上下载
sudo docker pull tdengine/tsdb:3.4.1.13
sudo docker save tdengine/tsdb:3.4.1.13 -o tdengine.tar

# 2. 复制到 K3s 节点
scp tdengine.tar root@k3s-node:/opt/

# 3. 在 K3s 节点导入
sudo k3s ctr images import /opt/tdengine.tar

# 4. 改为使用本地镜像
# 修改 statefulset.yaml: imagePullPolicy: Never
```

### 国内镜像加速

K3s 镜像源配置 `/etc/rancher/k3s/registries.yaml`：

```yaml
mirrors:
  "docker.io":
    endpoint:
      - "https://docker.m.daocloud.io"
      - "https://docker.1panel.live"
      - "https://hub.rat.dev"
```

## 十二、镜像升级

### 镜像变更说明

本次部署已更新镜像：

| 旧镜像 | 新镜像 |
|--------|--------|
| `tdengine/tdengine:3.3.6.13` | `tdengine/tsdb:3.4.1.13` |

> **说明**：`tdengine/tsdb` 是 TDengine 3.4.x 社区版官方镜像命名，与旧版 `tdengine/tdengine` 为同一产品，仅镜像仓库路径调整。
>
> - 旧镜像标签页：[https://hub.docker.com/r/tdengine/tdengine/tags](https://hub.docker.com/r/tdengine/tdengine/tags)
> - 新镜像标签页：[https://hub.docker.com/r/tdengine/tsdb/tags](https://hub.docker.com/r/tdengine/tsdb/tags)

### 已部署实例升级步骤

```bash
cd ~/k3s-deploy/relation-service/tdengine/k8s-native

# 1. 确认当前 Pod
kubectl get pods -n ecloud -l app=tdengine

# 2. 直接应用更新后的 YAML（已改好 tdengine/tsdb:3.4.1.13）
kubectl apply -k .

# 或只更新 StatefulSet 镜像
kubectl set image statefulset/tdengine tdengine=tdengine/tsdb:3.4.1.13 -n ecloud

# 3. 观察滚动更新（StatefulSet 按序号倒序逐个重启）
kubectl get pods -n ecloud -l app=tdengine -w

# 4. 验证新版本
kubectl exec -it tdengine-0 -n ecloud -- taosd -V
kubectl exec -it tdengine-0 -n ecloud -- taos -s "show dnodes; show mnodes"
```

### 升级前检查清单

```bash
# 检查当前版本
kubectl exec -it tdengine-0 -n ecloud -- taosd -V

# 备份数据（可选但推荐）
kubectl exec -it tdengine-0 -n ecloud -- taosdump -o /tmp/backup -D product_basic
kubectl cp ecloud/tdengine-0:/tmp/backup ./backup-$(date +%Y%m%d)

# 确认新镜像可拉取
sudo k3s ctr images pull docker.io/tdengine/tsdb:3.4.1.13
# 或手动导入
sudo k3s ctr images import tdengine-3.4.1.13.tar
```

### 回滚（升级失败时）

```bash
# 手动改回旧镜像
kubectl set image statefulset/tdengine tdengine=tdengine/tdengine:3.3.6.13 -n ecloud

# 或重新应用旧版本 YAML
git checkout HEAD~1 -- statefulset.yaml
kubectl apply -k .
```

## 参考文档

- [TDengine-Operator GitHub](https://github.com/taosdata/TDengine-Operator/tree/3.0)
- [TDengine K8s 手动部署指南](https://github.com/taosdata/TDengine-Operator/blob/3.0/src/en/2.1-tdengine-step-by-step.md)
- [TDengine 官方文档](https://docs.tdengine.com/)
