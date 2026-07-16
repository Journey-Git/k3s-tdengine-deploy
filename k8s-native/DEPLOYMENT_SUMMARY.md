# TDengine K3s 部署总结

## 一、部署概述

- **目标**：在 K3s 单节点集群上部署 TDengine 3.x 时序数据库
- **部署方式**：手动 K8s YAML（基于 TDengine-Operator 3.0 官方规范）
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
k3s-tdengine-deploy/
├── namespace.yaml       # 命名空间 ecloud
├── configmap.yaml       # taos.cfg 配置
├── service.yaml         # ClusterIP + NodePort Service
├── statefulset.yaml     # TDengine StatefulSet
├── kustomization.yaml   # Kustomize 配置
├── deploy.sh            # 一键部署脚本
├── uninstall.sh         # 卸载脚本
├── values-single-node.yaml   # Helm 单节点配置（备用）
└── values-cluster.yaml       # Helm 集群配置（备用）
```

### 2.3 执行部署

```bash
cd k3s-tdengine-deploy/
./deploy.sh
```

部署脚本执行流程：
1. 检查 K3s 集群版本
2. 检查 StorageClass
3. 创建命名空间 `ecloud`
4. 检查 NodePort 端口占用
5. 执行 `kubectl apply -k .`
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

## 三、遇到的问题及解决方案

### 问题1：镜像拉取失败（ImagePullBackOff）

**现象**：
```
tdengine-0   0/1   ImagePullBackOff
```

**原因**：K3s 配置的镜像加速源已失效

`/etc/rancher/k3s/registries.yaml`：
```yaml
mirrors:
  "docker.io":
    endpoint:
      - "https://docker.mirrors.ustc.edu.cn"    # ❌ 已关闭
      - "https://hub-mirror.c.163.com"           # ❌ 已关闭
      - "https://registry.docker-cn.com"        # ❌ 已关闭
```

**错误日志**：
```
failed to do request: Head "https://docker.mirrors.ustc.edu.cn/...":
dial tcp: lookup docker.mirrors.ustc.edu.cn: no such host
```

**解决方案**：

1. 编辑镜像源配置
```bash
sudo tee /etc/rancher/k3s/registries.yaml << 'EOF'
mirrors:
  "docker.io":
    endpoint:
      - "https://docker.m.daocloud.io"
      - "https://docker.1panel.live"
      - "https://hub.rat.dev"
EOF
```

2. 重启 K3s
```bash
sudo systemctl restart k3s
```

3. 重新部署
```bash
kubectl delete statefulset tdengine -n ecloud
./deploy.sh
```

---

### 问题2：镜像版本不存在

**现象**：
```
Failed to pull image "tdengine/tdengine:3.5.0":
failed to resolve reference "docker.io/tdengine/tdengine:3.5.0"
```

**原因**：Docker Hub 上没有 `3.5.0` 标签

**解决方案**：

将镜像版本改为实际存在的标签：
```yaml
# statefulset.yaml
image: tdengine/tsdb:3.4.1.13
```

**可用标签确认**：
```bash
# 查看本地已下载的镜像
sudo k3s ctr images ls | grep tdengine

# 输出
docker.io/tdengine/tsdb:3.4.1.13  469.3 MiB  linux/amd64,linux/arm64/v8
```

---

### 问题3：命名空间变更

**需求**：将命名空间从 `tdengine` 改为 `ecloud`

**修改文件**：

| 文件 | 修改内容 |
|------|---------|
| `namespace.yaml` | `name: ecloud` |
| `kustomization.yaml` | `namespace: ecloud` |
| `statefulset.yaml` | `namespace: ecloud` |
| `service.yaml` | 两个 Service 的 `namespace: ecloud` |
| `configmap.yaml` | `namespace: ecloud` |
| `deploy.sh` | `NAMESPACE="ecloud"` |
| `uninstall.sh` | `NAMESPACE="ecloud"` |
| `README.md` | 所有 `-n tdengine` 改为 `-n ecloud` |

**操作步骤**：
```bash
# 1. 删除旧命名空间
kubectl delete namespace tdengine

# 2. 重新部署
./deploy.sh
```

---

### 问题4：镜像下载位置

**镜像存储路径**：
```
/var/lib/rancher/k3s/agent/containerd/
```

**查看已下载镜像**：
```bash
sudo k3s ctr images ls | grep tdengine
```

**导出镜像备份**：
```bash
# 导出多架构版本（包含 amd64 + arm64）
sudo k3s ctr images export tdengine-3.4.1.13.tar docker.io/tdengine/tsdb:3.4.1.13

# 导出单架构版本（仅 amd64，体积更小）
sudo k3s ctr images export --platform linux/amd64 tdengine-3.4.1.13-amd64.tar docker.io/tdengine/tsdb:3.4.1.13
```

**导入镜像（离线部署）**：
```bash
sudo k3s ctr images import tdengine-3.4.1.13.tar
```

---

### 问题5：避免重复下载镜像

`imagePullPolicy` 控制镜像拉取行为：

| 策略 | 说明 | 适用场景 |
|------|------|---------|
| `IfNotPresent` | 本地没有时才拉取 | 默认，适合在线环境 |
| `Always` | 每次启动都强制拉取 | 镜像标签不变但内容更新 |
| `Never` | 只使用本地镜像 | 完全离线环境 |

当前配置：`IfNotPresent`

只要本地镜像不被删除，后续 `./deploy.sh` 不会重复下载。

---

## 四、服务端口说明

| 端口 | 用途 | 访问方式 |
|------|------|---------|
| 6030 | taosd 服务端口 | NodePort 30603 |
| 6041 | taosAdapter REST API | NodePort 30441 |
| 6060 | taosExplorer 管理界面 | NodePort 30660 |

## 五、核心配置要点

### 5.1 FQDN 配置（关键）

```yaml
env:
  - name: SERVICE_NAME
    value: "tdengine-service"
  - name: TAOS_FQDN
    value: "$(POD_NAME).$(SERVICE_NAME).$(STS_NAMESPACE).svc.cluster.local"
  - name: TAOS_FIRST_EP
    value: "$(STS_NAME)-0.$(SERVICE_NAME).$(STS_NAMESPACE).svc.cluster.local:$(TAOS_SERVER_PORT)"
```

`TAOS_FQDN` 必须在 K8s 环境中设置，否则 dnode 注册会使用 IP 地址，导致集群通信失败。

### 5.2 探针配置

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

livenessProbe:
  exec:
    command: ["taos-check", "service"]
  initialDelaySeconds: 15
  periodSeconds: 20
```

**版本兼容性说明：**

| TDengine 版本 | `taos-check` 用法 | 说明 |
|-------------|------------------|------|
| 3.3.x 及更早 | `taos-check`（无参数） | 直接检测服务状态 |
| 3.4.x 及以后 | `taos-check [startup\|service]` | 必须指定子命令：`startup` 用于启动检测，`service` 用于就绪/存活检测 |

> 3.4.x 使用无参数 `taos-check` 会报错：`usage: taos-check [startup|service]`，导致 Pod 无法就绪。

### 5.3 存储配置

使用单 PVC（官方推荐）：

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

## 六、运维命令

### 6.1 查看 Pod 状态与日志

```bash
# 查看 Pod 状态
kubectl get pod tdengine-0 -n ecloud

# 查看 Pod 详情（含 Events 事件）
kubectl describe pod tdengine-0 -n ecloud

# 查看实时日志
kubectl logs -f tdengine-0 -n ecloud

# 查看历史日志（最后 100 行）
kubectl logs --tail=100 tdengine-0 -n ecloud
```

### 6.2 进入容器

```bash
# 进入容器 shell
kubectl exec -it tdengine-0 -n ecloud -- /bin/bash

# 进入 taos 命令行
kubectl exec -it tdengine-0 -n ecloud -- taos

# 执行单条 SQL
kubectl exec -it tdengine-0 -n ecloud -- taos -s "show databases"

# 查看容器内进程
kubectl exec -it tdengine-0 -n ecloud -- ps aux

# 查看 taosd 日志
kubectl exec -it tdengine-0 -n ecloud -- tail -f /var/log/taos/taosdlog*
```

### 6.3 数据备份与导出

```bash
# 备份指定数据库
kubectl exec -it tdengine-0 -n ecloud -- taosdump -o /tmp/backup -D product_basic

# 从容器复制备份到本地
kubectl cp ecloud/tdengine-0:/tmp/backup ./backup

# 导出镜像（用于离线部署）
sudo k3s ctr images export tdengine-3.4.1.13.tar docker.io/tdengine/tsdb:3.4.1.13
```

### 6.4 卸载与清理

> **注意**：`kubectl delete statefulset` 只删除 StatefulSet 和 Pod，**不会删除 Service、ConfigMap、PVC**。以下按清理程度提供三种方案。

#### 方案一：卸载脚本（推荐）

```bash
# 完全卸载（含数据删除）
./uninstall.sh

# 保留数据卸载（只删 StatefulSet、Service、ConfigMap，PVC 保留）
./uninstall.sh --keep-data
```

| 模式 | 命令 | 效果 |
|------|------|------|
| 完全卸载 | `./uninstall.sh` | 删除 StatefulSet、Pod、Service、ConfigMap、**PVC（数据删除）** |
| 保留数据 | `./uninstall.sh --keep-data` | 删除 StatefulSet、Pod、Service、ConfigMap，**PVC 保留** |

**Namespace 保留**，可重新部署。保留数据模式适合修改配置后重新部署。

#### 方案二：手动分步删除（按需选择）

```bash
# 1. 删除 StatefulSet（Pod 自动级联删除）
kubectl delete statefulset tdengine -n ecloud

# 2. 删除 Service
kubectl delete service tdengine-service tdengine-nodeport -n ecloud

# 3. 删除 ConfigMap
kubectl delete configmap tdengine-config -n ecloud

# 4. 删除 PVC（数据将被删除！）
kubectl delete pvc -l app=tdengine -n ecloud
kubectl delete pvc taosdata-tdengine-0 -n ecloud

# 5. 删除 Namespace（彻底清理，包含所有资源）
kubectl delete namespace ecloud
```

#### 方案三：一键彻底清理（最彻底，数据不可恢复）

```bash
# 删除整个命名空间，级联删除所有资源
kubectl delete namespace ecloud
```

| 资源 | delete statefulset | ./uninstall.sh | ./uninstall.sh --keep-data | delete namespace |
|------|-------------------|----------------|---------------------------|------------------|
| StatefulSet | ✅ | ✅ | ✅ | ✅ |
| Pod | ✅ | ✅ | ✅ | ✅ |
| Service | ❌ | ✅ | ✅ | ✅ |
| ConfigMap | ❌ | ✅ | ✅ | ✅ |
| PVC（数据） | ❌ | ✅ | ❌ | ✅ |
| Namespace | ❌ | ❌ | ❌ | ✅ |

## 七、附录：三节点集群配置

从单节点扩展为三节点集群，需修改 `statefulset.yaml`：

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: tdengine
  namespace: ecloud
  labels:
    app: tdengine
spec:
  serviceName: tdengine-service
  replicas: 3                    # 单节点: 1 → 三节点: 3
  selector:
    matchLabels:
      app: tdengine
  template:
    metadata:
      labels:
        app: tdengine
    spec:
      # Pod 反亲和性：确保 3 个 Pod 分布在不同物理节点
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: tdengine
              topologyKey: kubernetes.io/hostname
      containers:
        - name: tdengine
          image: tdengine/tsdb:3.4.1.13
          imagePullPolicy: IfNotPresent
          ports:
            - name: tcp6030
              protocol: "TCP"
              containerPort: 6030
            - name: tcp6041
              protocol: "TCP"
              containerPort: 6041
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: SERVICE_NAME
              value: "tdengine-service"
            - name: STS_NAME
              value: "tdengine"
            - name: STS_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: TZ
              value: "UTC"
            - name: TAOS_SERVER_PORT
              value: "6030"
            - name: TAOS_FIRST_EP
              value: "$(STS_NAME)-0.$(SERVICE_NAME).$(STS_NAMESPACE).svc.cluster.local:$(TAOS_SERVER_PORT)"
            - name: TAOS_FQDN
              value: "$(POD_NAME).$(SERVICE_NAME).$(STS_NAMESPACE).svc.cluster.local"
            - name: TAOS_CLUSTER
              value: "1"            # 单节点: "0" → 三节点: "1"
            - name: TAOS_DEBUG_FLAG
              value: "131"
          resources:
            requests:
              cpu: "2"
              memory: "4Gi"
            limits:
              cpu: "4"
              memory: "8Gi"
          volumeMounts:
            - name: taosdata
              mountPath: /var/lib/taos
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
  volumeClaimTemplates:
    - metadata:
        name: taosdata
      spec:
        accessModes:
          - "ReadWriteOnce"
        storageClassName: local-path
        resources:
          requests:
            storage: 20Gi
```

### 集群扩展步骤

```bash
# 1. 修改 statefulset.yaml 后应用
kubectl apply -k .

# 2. 验证集群节点
kubectl exec -it tdengine-0 -n ecloud -- taos -s "show dnodes"

# 3. 验证 mnode
kubectl exec -it tdengine-0 -n ecloud -- taos -s "show mnodes"
```

### 缩容步骤（必须按顺序执行）

```bash
# 1. 查看 dnode 列表
kubectl exec -it tdengine-0 -n ecloud -- taos -s "show dnodes"

# 2. 先 drop dnode（不能直接缩容！）
kubectl exec -it tdengine-0 -n ecloud -- taos -s "drop dnode 3"

# 3. 缩容 StatefulSet
kubectl scale statefulset tdengine --replicas=2

# 4. 删除对应 PVC
kubectl delete pvc taosdata-tdengine-2 -n ecloud
```

**不执行 `drop dnode` 直接缩容会导致 dnode stuck 在 `offline` 或 `dropping` 状态。**

**不执行 `drop dnode` 直接缩容会导致 dnode stuck 在 `offline` 或 `dropping` 状态。**

## 八、镜像升级

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
cd ~/k3s-deploy/relation-service/tdengine/k8s-native

# 应用更新后的 YAML
kubectl apply -k .

# 或只更新镜像
kubectl set image statefulset/tdengine tdengine=tdengine/tsdb:3.4.1.13 -n ecloud

# 验证
kubectl get pods -n ecloud -l app=tdengine -w
kubectl exec -it tdengine-0 -n ecloud -- taosd -V
```

### 回滚

```bash
kubectl set image statefulset/tdengine tdengine=tdengine/tdengine:3.3.6.13 -n ecloud
```

## 九、参考文档

- [TDengine-Operator GitHub](https://github.com/taosdata/TDengine-Operator/tree/3.0)
- [TDengine K8s 手动部署指南](https://github.com/taosdata/TDengine-Operator/blob/3.0/src/en/2.1-tdengine-step-by-step.md)
- [TDengine 官方文档](https://docs.tdengine.com/)
