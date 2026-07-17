# TDengine K3s 部署总结（纯 kubectl 版本）

## 一、部署概述

- **目标**：在 K3s 单节点集群上部署 TDengine 3.x 时序数据库
- **部署方式**：原生 K8s YAML，使用 `kubectl apply -f` 直接部署，无需 Kustomize
- **命名空间**：`ecloud`
- **镜像版本**：`tdengine/tsdb:3.4.1.13`

## 二、部署步骤

### 2.1 前置准备

```bash
# 确认 K3s 集群状态
kubectl get nodes

# 确认 StorageClass
kubectl get sc

# 确认 local-path 存在
kubectl get sc local-path
```

### 2.2 部署文件结构

```
k8s-native-kubectl/
├── README.md                 # 部署文档（公共）
├── DEPLOYMENT_SUMMARY.md     # 部署总结（公共）
│
├── local-path/               # 方案一：local-path 自动管理
│   ├── tdengine_configmap.yaml   # taos.cfg 配置
│   ├── tdengine.yaml             # Namespace + Service + StatefulSet
│   ├── deploy.sh                 # 一键部署脚本
│   └── uninstall.sh              # 卸载脚本
│
└── hostpath/                 # 方案二：hostPath 手动指定路径
    ├── tdengine_configmap.yaml   # taos.cfg 配置
    ├── tdengine_hostpath.yaml    # PV + PVC + Namespace + Service + StatefulSet
    ├── deploy.sh                 # 一键部署脚本
    └── uninstall.sh              # 卸载脚本
```

> **说明**：每个方案文件夹包含完整的独立部署文件，可直接进入执行部署，无需依赖父目录文件。

### 2.3 执行部署

#### 方案一：local-path 自动部署（默认）

```bash
cd k8s-native-kubectl/local-path/
./deploy.sh
```

或手动执行：

```bash
cd k8s-native-kubectl/local-path/

# 创建命名空间（如果不存在）
kubectl create namespace ecloud --dry-run=client -o yaml | kubectl apply -f -

# 部署 ConfigMap
kubectl apply -f tdengine_configmap.yaml

# 部署 Service + StatefulSet
kubectl apply -f tdengine.yaml
```

> **注意**：此方案数据目录和日志均已挂载 PVC，数据持久化。生产环境可直接使用。

#### 方案二：hostPath 手动部署（指定宿主机路径）

**前置准备：**

```bash
# 1. 创建宿主机目录
sudo mkdir -p /mnt/disk1/k3s/tdengine

# 2. 设置权限
sudo chmod 755 /mnt/disk1/k3s/tdengine
```

**部署：**

```bash
cd k8s-native-kubectl/hostpath/
./deploy.sh
```

或手动执行：

```bash
cd k8s-native-kubectl/hostpath/

# 创建命名空间（如果不存在）
kubectl create namespace ecloud --dry-run=client -o yaml | kubectl apply -f -

# 部署 ConfigMap
kubectl apply -f tdengine_configmap.yaml

# 部署 PV + PVC + Service + StatefulSet
kubectl apply -f tdengine_hostpath.yaml
```

部署脚本执行流程：
1. 检查 K3s 集群版本
2. 检查 StorageClass（local-path）或 hostPath 目录
3. 创建命名空间 `ecloud`
4. 部署 ConfigMap
5. 部署 Service + StatefulSet
6. 等待 Pod 启动（约 1-2 分钟）
7. 验证部署状态

### 2.4 验证部署

```bash
# 查看 Pod 状态
kubectl get pods -n ecloud -l app=tdengine

# 查看 Service
kubectl get svc -n ecloud

# 查看 PVC
kubectl get pvc -n ecloud

# 验证 TDengine 服务
kubectl exec -it tdengine-0 -n ecloud -- taos -s "show dnodes; show mnodes"

# 测试 REST API
curl -u root:taosdata http://<node-ip>:30441/rest/sql -d "show databases"
```

## 三、配置参数

### 3.1 资源限制

| 类型 | CPU | 内存 |
|------|-----|------|
| requests | 1 | 2Gi |
| limits | 2 | 4Gi |

### 3.2 存储配置

| 方案 | 数据存储 | 日志存储 | 宿主机路径 | 持久化 |
|------|---------|---------|-----------|--------|
| 方案一：local-path | `/var/lib/taos` | `/var/log/taos` | local-path 自动分配 | 数据+日志持久化 |
| 方案二：hostPath | `/var/lib/taos` | `/var/log/taos` | `/mnt/disk1/k3s/tdengine` | 数据 + 日志持久化 |

### 3.3 端口配置

| 端口 | 用途 | NodePort |
|------|------|---------|
| 6030 | taosd 服务端口 | 30603 |
| 6041 | taosAdapter REST API | 30441 |
| 6060 | taosExplorer 管理界面 | 30660 |

### 3.4 TDengine 核心配置

| 参数 | 值 | 说明 |
|------|-----|------|
| CLUSTER | 0 | 单节点模式 |
| TAOS_REPLICA | 1 | 副本数 |
| TAOS_DEBUG_FLAG | 131 | 日志级别（WARN + ERROR） |
| timezone | UTC | 时区 |
| smlTsDefaultName | ts | schemaless 默认时间戳列名 |

## 四、访问方式

| 服务 | 地址 | 认证 |
|------|------|------|
| taosAdapter REST API | http://192.168.31.222:30441 | root / taosdata |
| taosExplorer 界面 | http://192.168.31.222:30660 | root / taosdata |
| taosd 客户端 | 192.168.31.222:30603 | root / taosdata |

## 五、常用运维命令

```bash
# 查看 Pod 状态
kubectl get pods -n ecloud -l app=tdengine

# 查看 Pod 日志
kubectl logs -f tdengine-0 -n ecloud

# 进入 TDengine 容器
kubectl exec -it tdengine-0 -n ecloud -- taos

# 升级配置（重新 apply YAML）
kubectl apply -f tdengine.yaml

# 回滚版本
kubectl rollout undo statefulset/tdengine -n ecloud

# 卸载（保留 PVC，进入对应目录执行）
./uninstall.sh --keep-data

# 完全清理（包括 PVC，进入对应目录执行）
./uninstall.sh
```

## 六、扩容路径

### 6.1 单节点 → 三节点集群

```bash
# 修改 hostpath/tdengine_hostpath.yaml 或 local-path/tdengine.yaml
# 1. replicas: 1 → 3
# 2. TAOS_CLUSTER: "0" → "1"
# 3. 添加 Pod 反亲和性配置

# 应用更新
kubectl apply -f tdengine.yaml

# 验证
kubectl exec -it tdengine-0 -n ecloud -- taos -s "show dnodes"
```

**注意**：单节点 K3s 扩容三节点时，需移除 `podAntiAffinity` 或添加更多工作节点。

### 6.2 缩容步骤

```bash
# 1. 查看 dnode 列表
kubectl exec -it tdengine-0 -n ecloud -- taos -s "show dnodes"

# 2. 先 drop dnode
drop dnode 3

# 3. 缩容 StatefulSet
kubectl scale statefulset tdengine --replicas=2

# 4. 删除对应 PVC
kubectl delete pvc taosdata-tdengine-2 -n ecloud
```

## 七、与 InfluxDB 共存

迁移期间 TDengine 与 InfluxDB 同时运行在 `ecloud` 命名空间：

| 数据库 | 服务地址 | 用途 |
|--------|---------|------|
| InfluxDB（现有） | influxdb:8086 | 现有业务读写 |
| TDengine（新部署） | 192.168.31.222:30441 | 新数据写入 / 查询验证 |

## 八、参考文档

- [Kustomize 版本部署](../k8s-native/README.md)
- [TDengine-Operator GitHub](https://github.com/taosdata/TDengine-Operator/tree/3.0)
- [TDengine K8s 手动部署指南](https://github.com/taosdata/TDengine-Operator/blob/3.0/src/en/2.1-tdengine-step-by-step.md)
- [TDengine 官方文档](https://docs.tdengine.com/)
