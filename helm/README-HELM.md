# TDengine Helm 部署文档

## 一、概述

Helm 是 Kubernetes 的包管理工具，通过 Chart 模板化部署应用。TDengine 官方提供 Helm Chart，支持参数化配置单节点或集群部署。

**部署目标环境：**
- K3s 单节点集群 (`k3s1`, `192.168.31.222`)
- StorageClass: `local-path`
- 命名空间: `ecloud`（与现有 InfluxDB 等服务同命名空间）

## 二、前置要求

1. **K3s/K8s 集群**已正常运行
2. **Helm 3** 已安装

```bash
# 检查 Helm 版本
helm version

# 如未安装
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

## 三、获取 TDengine Chart

由于官方 Helm 仓库已失效，从 GitHub 直接下载 Chart 包：

```bash
# 下载 Chart 包
wget https://github.com/taosdata/TDengine-Operator/raw/3.0/helm/tdengine-3.5.0.tgz

# 查看包内文件列表（不解压）
tar -tzf tdengine-3.5.0.tgz

# 查看 Chart 元数据（不解压，直接输出到屏幕）
tar -xzf tdengine-3.5.0.tgz -O tdengine/Chart.yaml

# 查看默认 values（了解可配置项）
helm show values tdengine-3.5.0.tgz

# 解压到当前目录（会创建 tdengine/ 文件夹）
tar -zxvf tdengine-3.5.0.tgz

# 查看 Chart 信息
cat tdengine/Chart.yaml

# 查看模板文件
ls -la tdengine/templates/
```

### Chart 版本与镜像版本

| 版本 | 来源 | 说明 |
|------|------|------|
| Chart 版本 | `Chart.yaml` 中的 `version` | Helm Chart 模板版本，如 `3.5.0` |
| 默认镜像版本 | `Chart.yaml` 中的 `appVersion` | 如 `3.3.5.1`，values 中不指定 `tag` 时生效 |
| 覆盖镜像版本 | `values.yaml` 中的 `image.tag` | 优先级最高，如 `3.3.6.13` |

```bash
# 查看 Chart 默认镜像版本
helm show chart tdengine-3.5.0.tgz | grep appVersion

# 查看默认 values 中的 image 配置
helm show values tdengine-3.5.0.tgz | grep -A3 "image:"
```

**示例输出：**
```yaml
# Chart.yaml
apiVersion: v2
appVersion: 3.3.5.1      # ← 默认镜像版本
description: TDengine Cluster Chart for Kubernetes
name: tdengine
type: application
version: 3.5.0            # ← Chart 版本
```

**镜像版本覆盖逻辑：**
- `values.yaml` 中指定 `image.tag: "3.4.1.13"` → 使用 `tdengine/tsdb:3.4.1.13`
- `values.yaml` 中不指定 `tag`（或为空）→ 使用 `tdengine/tdengine:3.3.5.1`（即 `appVersion`）

## 四、部署方式

### 4.1 单节点部署（推荐，当前环境）

适用于：数据量中等、单节点 K3s、资源有限（1C2G 请求 / 2C4G 限制）

```bash
# 进入 Chart 所在目录
cd ~/k3s-deploy/relation-service/tdengine

# 安装（使用自定义 values）
helm upgrade --install tdengine ./tdengine-3.5.0.tgz \
  --namespace ecloud \
  --create-namespace \
  -f helm/values-single-node.yaml
```

**单节点配置要点：**
- `replicaCount: 1`
- `storage.dataSize: 120Gi`（适配 14G 历史数据 + 预留）
- `taoscfg.CLUSTER: "0"`（单节点模式）
- `taoscfg.TAOS_REPLICA: "1"`

### 4.2 三节点集群部署（未来扩展）

适用于：高可用生产环境、多节点 K3s/K8s

```bash
helm upgrade --install tdengine ./tdengine-3.5.0.tgz \
  --namespace ecloud \
  --create-namespace \
  -f helm/values-cluster.yaml
```

**集群配置要点：**
- `replicaCount: 3`
- `storage.dataSize: 20Gi`（每节点）
- `taoscfg.CLUSTER: "1"`（集群模式）
- `taoscfg.TAOS_REPLICA: "3"`（3 副本冗余）
- `affinity.podAntiAffinity`（Pod 分布在不同节点）

### 4.3 创建 NodePort Service（暴露外部访问）

官方 Chart 默认使用 `ClusterIP`，需额外创建 NodePort Service。建议将 YAML 文件保存在部署目录，而非临时目录：

```bash
# 进入部署目录
cd ~/k3s-deploy/relation-service/tdengine

# 创建 NodePort Service YAML
cat > tdengine-nodeport.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: tdengine-nodeport
  namespace: ecloud
  labels:
    app: tdengine
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: tdengine
    app.kubernetes.io/instance: tdengine
  ports:
    - name: taosadapter
      port: 6041
      targetPort: 6041
      nodePort: 30441
      protocol: TCP
    - name: taosd
      port: 6030
      targetPort: 6030
      nodePort: 30603
      protocol: TCP
    - name: taosexplorer
      port: 6060
      targetPort: 6060
      nodePort: 30660
      protocol: TCP
EOF

# 应用
kubectl apply -f tdengine-nodeport.yaml

# 验证
kubectl get svc -n ecloud
```

**目录结构建议：**
```
~/k3s-deploy/relation-service/tdengine/
├── tdengine-3.5.0.tgz              # Chart 包
├── tdengine/                       # 解压后的 Chart（可选）
├── helm/
│   ├── values-single-node.yaml     # 单节点配置
│   └── values-cluster.yaml         # 集群配置
├── tdengine-nodeport.yaml          # NodePort Service
└── README-HELM.md                  # 本文档
```

## 五、自定义 values 配置

### 5.1 核心配置参数说明

#### 端口配置

```yaml
# Service 配置（官方 Chart 使用数组格式）
service:
  type: ClusterIP
  ports:
    # TCP 端口说明：
    # 6030 - taosd 服务端口（客户端连接、集群 dnode 通信）
    # 6041 - taosAdapter REST API 端口（InfluxDB Line Protocol 写入、HTTP 查询）
    # 6060 - taosExplorer / taosx 管理界面端口
    tcp: [6030, 6041, 6060]
    # UDP 端口说明：
    # 6044 - taosd 内部数据通信
    # 6045 - taosd 内部管理通信
    udp: [6044, 6045]
```

**端口用途对照表：**

| 端口 | 协议 | 组件 | 用途 | 暴露方式 |
|------|------|------|------|---------|
| 6030 | TCP | taosd | 数据库服务端口（客户端连接、集群 dnode 通信）| ClusterIP / NodePort 30603 |
| 6041 | TCP | taosAdapter | REST API 端口（InfluxDB Line Protocol 写入、HTTP 查询）| ClusterIP / NodePort 30441 |
| 6060 | TCP | taosExplorer | Web 管理界面端口 | ClusterIP / NodePort 30660 |
| 6044 | UDP | taosd | 内部数据通信 | ClusterIP |
| 6045 | UDP | taosd | 内部管理通信 | ClusterIP |

**NodePort 映射（外部访问）：**

| 服务端口 | NodePort | 用途 |
|---------|---------|------|
| 6030 | 30603 | taosd 外部连接 |
| 6041 | 30441 | taosAdapter REST API（数据写入/查询）|
| 6060 | 30660 | taosExplorer Web 管理界面 |

#### 完整配置示例

```yaml
# 副本数
replicaCount: 1

# 镜像配置（注意：官方 Chart 使用 image.prefix，不是 image.repository）
image:
  prefix: tdengine/tsdb
  tag: "3.4.1.13"
  pullPolicy: IfNotPresent

# 时区
timezone: "UTC"

# 资源限制
resources:
  limits:
    cpu: "2"
    memory: "4Gi"
  requests:
    cpu: "1"
    memory: "2Gi"

# 存储配置（官方 Chart 使用 dataSize/logSize，不是 persistence.size）
storage:
  className: "local-path"
  dataSize: "120Gi"    # 数据存储大小
  logSize: "10Gi"      # 日志存储大小

# 节点选择器
nodeSelectors:
  taosd: {}

# 集群域名后缀
clusterDomainSuffix: ""

# TDengine 配置（通过环境变量注入 taos.cfg）
taoscfg:
  CLUSTER: "0"          # 0=单节点, 1=集群
  TAOS_REPLICA: "1"      # 副本数（集群模式）
  TAOS_DEBUG_FLAG: "131"  # 日志级别
  TAOS_SML_TSDEFAULTNAME: "ts"  # schemaless 写入默认时间戳列名
```

### 5.2 存储容量规划

| 部署模式 | dataSize | logSize | 总存储 | 适用场景 |
|---------|---------|---------|--------|---------|
| 单节点 | 120Gi | 10Gi | 130Gi | 14G 历史数据 + 长期增长 |
| 集群（每节点） | 20Gi | 5Gi | 25Gi | 高可用，数据分片 |

## 六、常用 Helm 命令

```bash
# 查看部署列表
helm list -n ecloud

# 查看部署状态
helm status tdengine -n ecloud

# 查看 Pod
kubectl get pods -n ecloud -l app.kubernetes.io/name=tdengine

# 查看 Service
kubectl get svc -n ecloud

# 查看 PVC
kubectl get pvc -n ecloud

# 升级配置
helm upgrade tdengine ./tdengine-3.5.0.tgz -n ecloud -f helm/values-single-node.yaml

# 回滚版本
helm rollback tdengine <revision> -n ecloud

# 查看历史版本
helm history tdengine -n ecloud

# 卸载（保留 PVC）
helm uninstall tdengine -n ecloud

# 完全清理（包括 PVC）
helm uninstall tdengine -n ecloud
kubectl delete pvc -l app.kubernetes.io/name=tdengine -n ecloud
```

## 七、验证部署

```bash
# 查看 Pod 状态
kubectl get pods -n ecloud -l app.kubernetes.io/name=tdengine

# 查看 Service（包括 NodePort）
kubectl get svc -n ecloud

# 进入 taos shell
kubectl exec -it tdengine-0 -n ecloud -- taos

# 查看集群状态
kubectl exec -it tdengine-0 -n ecloud -- taos -s "show dnodes; show mnodes"

# 测试 REST API（通过 NodePort）
curl -u root:taosdata http://192.168.31.222:30441/rest/sql -d "show databases"

# 创建测试数据库
kubectl exec -it tdengine-0 -n ecloud -- taos -s "
  create database if not exists test;
  use test;
  create table t1 (ts timestamp, n int);
  insert into t1 values(now, 1)(now + 1s, 2);
  select * from t1;"
```

## 八、扩容操作

### 单节点 → 三节点集群

```bash
# 1. 修改 values-cluster.yaml 中的资源限制（适配单节点 K3s）
# 建议：limits cpu: "2", memory: "4Gi"（避免资源不足）

# 2. 升级部署
helm upgrade tdengine ./tdengine-3.5.0.tgz \
  -n ecloud \
  -f helm/values-cluster.yaml

# 3. 验证
kubectl exec -it tdengine-0 -n ecloud -- taos -s "show dnodes; show mnodes"
```

**注意**：单节点 K3s 扩容三节点时，由于只有一个物理节点，`podAntiAffinity` 会导致 Pod 无法调度。需要：
1. 移除 `affinity` 配置，或
2. 添加更多 K3s 工作节点

## 九、与 InfluxDB 共存（迁移期间）

迁移期间 TDengine 与 InfluxDB 同时运行在 `ecloud` 命名空间：

```bash
# 查看所有服务
kubectl get svc -n ecloud

# InfluxDB（现有）
#   influxdb:8086

# TDengine（新部署）
#   tdengine-nodeport:30441 (taosAdapter)
#   tdengine-nodeport:30603 (taosd)
#   tdengine-nodeport:30660 (taosExplorer)
```

## 十、镜像升级

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
cd ~/k3s-deploy/relation-service/tdengine

# 1. 确认当前部署
helm list -n ecloud
kubectl get pods -n ecloud -l app.kubernetes.io/name=tdengine

# 2. 确认 values 文件已更新镜像（已改好 tdengine/tsdb:3.4.1.13）
cat helm/values-single-node.yaml | grep -A3 "image:"

# 3. 执行升级（保留 PVC 数据，StatefulSet 滚动更新）
helm upgrade tdengine ./tdengine-3.5.0.tgz \
  -n ecloud \
  -f helm/values-single-node.yaml

# 4. 观察滚动更新（按序号倒序逐个重启 Pod）
kubectl get pods -n ecloud -l app.kubernetes.io/name=tdengine -w

# 5. 验证新版本
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
# 查看历史版本
helm history tdengine -n ecloud

# 回滚到上一个版本
helm rollback tdengine -n ecloud

# 或回滚到指定版本
helm rollback tdengine 1 -n ecloud
```

## 十一、参考文档

- [TDengine-Operator GitHub](https://github.com/taosdata/TDengine-Operator/tree/3.0)
- [Helm 官方文档](https://helm.sh/docs/)
- [TDengine 官方文档 - Helm 部署](https://taosdata.github.io/TDengine-Operator/zh/2.2-tdengine-with-helm.html)
