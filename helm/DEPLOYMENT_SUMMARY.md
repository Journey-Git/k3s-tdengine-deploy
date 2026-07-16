# TDengine Helm 部署总结

## 一、部署概述

| 项目 | 内容 |
|------|------|
| **部署方式** | Helm Chart 本地安装 |
| **Chart 版本** | 3.5.0 |
| **TDengine 镜像版本** | 3.4.1.13（覆盖默认 3.3.5.1） |
| **部署模式** | 单节点（后续可扩展为 3 节点集群） |
| **目标集群** | K3s v1.30.3+k3s1 |
| **目标节点** | k3s1 (192.168.31.222) |
| **命名空间** | ecloud（与 InfluxDB 等服务共存） |
| **StorageClass** | local-path |

## 二、部署步骤

### 步骤 1：前置检查

```bash
# 检查 K3s 集群
kubectl get nodes
kubectl get sc

# 检查 Helm
helm version

# 确认命名空间
kubectl get namespace ecloud
```

### 步骤 2：下载 Chart 包

```bash
cd ~/k3s-deploy/relation-service/tdengine

# 下载 Chart 包
wget https://github.com/taosdata/TDengine-Operator/raw/3.0/helm/tdengine-3.5.0.tgz

# 验证下载
ls -la tdengine-3.5.0.tgz
```

### 步骤 3：部署 TDengine

```bash
helm upgrade --install tdengine ./tdengine-3.5.0.tgz \
  --namespace ecloud \
  --create-namespace \
  -f helm/values-single-node.yaml
```

### 步骤 4：创建 NodePort Service

```bash
kubectl apply -f tdengine-nodeport.yaml
```

### 步骤 5：验证部署

```bash
# Pod 状态
kubectl get pods -n ecloud -l app.kubernetes.io/name=tdengine

# Service 状态
kubectl get svc -n ecloud

# PVC 状态
kubectl get pvc -n ecloud

# TDengine 集群状态
kubectl exec -it tdengine-0 -n ecloud -- taos -s "show dnodes; show mnodes"

# REST API 测试
curl -u root:taosdata http://192.168.31.222:30441/rest/sql -d "show databases"
```

## 三、配置参数

### 资源限制

| 类型 | CPU | 内存 |
|------|-----|------|
| requests | 1 | 2Gi |
| limits | 2 | 4Gi |

### 存储配置

| 用途 | 大小 | StorageClass |
|------|------|-------------|
| 数据存储 (dataSize) | 120Gi | local-path |
| 日志存储 (logSize) | 10Gi | local-path |

### 端口配置

| 端口 | 协议 | 组件 | 用途 | NodePort |
|------|------|------|------|---------|
| 6030 | TCP | taosd | 数据库服务端口 | 30603 |
| 6041 | TCP | taosAdapter | REST API（数据写入/查询） | 30441 |
| 6060 | TCP | taosExplorer | Web 管理界面 | 30660 |
| 6044 | UDP | taosd | 内部数据通信 | - |
| 6045 | UDP | taosd | 内部管理通信 | - |

### TDengine 核心配置

| 参数 | 值 | 说明 |
|------|-----|------|
| CLUSTER | 0 | 单节点模式 |
| TAOS_REPLICA | 1 | 副本数 |
| TAOS_DEBUG_FLAG | 131 | 日志级别（WARN + ERROR） |
| timezone | UTC | 时区 |

## 四、访问方式

| 服务 | 地址 | 认证 |
|------|------|------|
| taosAdapter REST API | http://192.168.31.222:30441 | root / taosdata |
| taosExplorer 界面 | http://192.168.31.222:30660 | root / taosdata |
| taosd 客户端 | 192.168.31.222:30603 | root / taosdata |

## 五、常用运维命令

```bash
# 查看部署列表
helm list -n ecloud

# 查看部署状态
helm status tdengine -n ecloud

# 查看 Pod 日志
kubectl logs -f tdengine-0 -n ecloud

# 进入 TDengine 容器
kubectl exec -it tdengine-0 -n ecloud -- taos

# 升级配置
helm upgrade tdengine ./tdengine-3.5.0.tgz -n ecloud -f helm/values-single-node.yaml

# 回滚版本
helm rollback tdengine <revision> -n ecloud

# 卸载（保留 PVC）
helm uninstall tdengine -n ecloud

# 完全清理（包括 PVC）
helm uninstall tdengine -n ecloud
kubectl delete pvc -l app.kubernetes.io/name=tdengine -n ecloud
```

## 六、扩容路径

### 单节点 → 三节点集群

```bash
# 修改 values-cluster.yaml 资源限制（适配单节点 K3s）
# 建议：limits cpu: "2", memory: "4Gi"

# 执行扩容
helm upgrade tdengine ./tdengine-3.5.0.tgz \
  -n ecloud \
  -f helm/values-cluster.yaml

# 验证
kubectl exec -it tdengine-0 -n ecloud -- taos -s "show dnodes; show mnodes"
```

**注意**：单节点 K3s 扩容三节点时，需移除 `podAntiAffinity` 配置或添加更多工作节点。

## 七、与 InfluxDB 共存

迁移期间 TDengine 与 InfluxDB 同时运行在 `ecloud` 命名空间：

| 数据库 | 服务地址 | 用途 |
|--------|---------|------|
| InfluxDB（现有） | influxdb:8086 | 现有业务读写 |
| TDengine（新部署） | 192.168.31.222:30441 | 新数据写入 / 查询验证 |

## 八、文件清单

```
~/k3s-deploy/relation-service/tdengine/
├── tdengine-3.5.0.tgz              # Chart 包
├── helm/
│   ├── values-single-node.yaml     # 单节点配置
│   ├── values-cluster.yaml         # 集群配置
│   └── README-HELM.md              # 详细部署文档
├── tdengine-nodeport.yaml          # NodePort Service
└── DEPLOYMENT_SUMMARY.md           # 本文档
```

## 九、后续操作

1. **数据迁移**：使用 `influx_dump_parallel.py` 导出 InfluxDB 数据，通过 `tdengine_import_parallel.py` 导入 TDengine
2. **业务切换**：双写验证 → 查询切换 → 停止 InfluxDB 写入
3. **监控配置**：配置 TDengine 监控告警

## 十、镜像升级

### 镜像变更说明

| 旧镜像 | 新镜像 |
|--------|--------|
| `tdengine/tdengine:3.3.6.13` | `tdengine/tsdb:3.4.1.13` |

> `tdengine/tsdb` 是 TDengine 3.4.x 社区版官方镜像命名。
>
> - 旧镜像标签页：[https://hub.docker.com/r/tdengine/tdengine/tags](https://hub.docker.com/r/tdengine/tdengine/tags)
> - 新镜像标签页：[https://hub.docker.com/r/tdengine/tsdb/tags](https://hub.docker.com/r/tdengine/tsdb/tags)

### 升级步骤

```bash
cd ~/k3s-deploy/relation-service/tdengine

# 执行升级（保留 PVC 数据）
helm upgrade tdengine ./tdengine-3.5.0.tgz \
  -n ecloud \
  -f helm/values-single-node.yaml

# 验证
kubectl get pods -n ecloud -l app.kubernetes.io/name=tdengine -w
kubectl exec -it tdengine-0 -n ecloud -- taosd -V
```

### 回滚

```bash
helm history tdengine -n ecloud
helm rollback tdengine -n ecloud
```

## 十一、参考文档

- [TDengine-Operator GitHub](https://github.com/taosdata/TDengine-Operator/tree/3.0)
- [Helm部署TDengine集群 官方文档](https://taosdata.github.io/TDengine-Operator/zh/2.2-tdengine-with-helm.html)
- [TDengine 官方文档](https://docs.tdengine.com/)
