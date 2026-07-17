# TDengine K3s 原生 YAML 部署（纯 kubectl 版本）

## 文件结构

```
k8s-native-kubectl/
├── README.md                 # 本文档（公共）
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

> **说明**：每个方案文件夹内包含 2 个 YAML 文件 + 2 个脚本文件，可直接进入对应文件夹独立部署，无需依赖父目录文件。

## 与 Kustomize 版本的区别

| 特性 | 纯 kubectl 版本 | Kustomize 版本 |
|------|----------------|---------------|
| 部署命令 | `kubectl apply -f` | `kubectl apply -k .` |
| 依赖 | 仅需 kubectl | 需要 Kustomize |
| 配置覆盖 | 直接修改 YAML | 通过 kustomization.yaml |
| 标签管理 | 手动维护 | Kustomize 自动注入 |

## 持久化方案选择

| 方案 | 目录 | 数据路径 | 日志路径 | 宿主机路径 | 适用场景 |
|------|------|---------|---------|-----------|---------|
| **方案一：local-path 自动** | `local-path/` | 容器默认（暂不挂载） | `/var/log/taos` | 自动分配 | 简单部署，数据暂不持久化 |
| **方案二：hostPath 手动** | `hostpath/` | `/var/lib/taos` | `/var/log/taos` | `/mnt/disk1/k3s/tdengine` | 需要指定存储路径，数据持久化 |

> **注意**：方案一数据目录（`/var/lib/taos`）暂时未挂载 PVC，使用容器默认路径，重启后数据丢失。如需持久化，使用方案二或取消数据目录注释。

## 部署步骤

### 方案一：local-path 自动部署（默认）

```bash
./deploy.sh
```

或手动执行：

```bash
# 创建命名空间（如果不存在）
kubectl apply -f local-path/tdengine.yaml

# 部署 ConfigMap
kubectl apply -f tdengine_configmap.yaml

# 部署 Service + StatefulSet
kubectl apply -f local-path/tdengine.yaml
```

### 方案二：hostPath 手动部署（指定宿主机路径）

**前置准备：**

```bash
# 1. 创建宿主机目录
sudo mkdir -p /mnt/disk1/k3s/tdengine

# 2. 设置权限
sudo chmod 755 /mnt/disk1/k3s/tdengine
```

**部署：**

```bash
# 使用方案二配置
kubectl apply -f hostpath/tdengine_hostpath.yaml
```

## 验证部署

```bash
# 查看 Pod 状态
kubectl get pods -n ecloud -l app=tdengine

# 查看 Service
kubectl get svc -n ecloud -l app=tdengine

# 查看 PVC
kubectl get pvc -n ecloud

# 验证 TDengine
kubectl exec -it tdengine-0 -n ecloud -- taos -s "show databases"

# 测试 REST API
curl -u root:taosdata http://192.168.31.222:30441/rest/sql -d "show databases"
```

## 卸载

```bash
# 完全卸载（含数据删除）
./uninstall.sh

# 保留数据卸载（只删 StatefulSet/Service/ConfigMap，PVC 保留）
./uninstall.sh --keep-data
```

## 配置说明

### 镜像版本

`local-path/tdengine.yaml` 或 `hostpath/tdengine_hostpath.yaml` 中修改：

```yaml
image: tdengine/tsdb:3.4.1.13
```

### 存储容量

方案一：`local-path/tdengine.yaml` 中修改
方案二：`hostpath/tdengine_hostpath.yaml` 中修改

```yaml
volumeClaimTemplates:
  - metadata:
      name: taosdata
    spec:
      resources:
        requests:
          storage: 5Gi    # 修改此处
```

### 时区配置

`tdengine_configmap.yaml` 中修改：

```yaml
timezone UTC    # 或 Asia/Shanghai
```

### 资源限制

`local-path/tdengine.yaml` 或 `hostpath/tdengine_hostpath.yaml` 中修改：

```yaml
resources:
  requests:
    cpu: "1"
    memory: "2Gi"
  limits:
    cpu: "2"
    memory: "4Gi"
```

## 端口说明

| 端口 | 用途 | 访问方式 |
|------|------|---------|
| 6030 | taosd 服务端口 | ClusterIP / NodePort 30603 |
| 6041 | taosAdapter REST API | ClusterIP / NodePort 30441 |
| 6060 | taosExplorer Web 界面 | ClusterIP / NodePort 30660 |

## 参考文档

- [Kustomize 版本部署](../k8s-native/README.md)
- [TDengine 官方文档](https://docs.tdengine.com/)
