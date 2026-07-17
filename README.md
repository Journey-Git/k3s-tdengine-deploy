# TDengine K3s 部署文档

本项目提供三种部署方式：原生 K8s YAML（Kustomize）、原生 K8s YAML（纯 kubectl）和 Helm Chart。

## 目录结构

```
k3s-tdengine-deploy/
├── README.md                          # 本文档
│
├── k8s-native/                        # 原生 K8s YAML 部署（Kustomize）
│   ├── README.md                        # Kustomize 部署文档
│   ├── DEPLOYMENT_SUMMARY.md            # 部署总结
│   ├── deploy.sh                        # 一键部署脚本（调用子文件夹）
│   └── uninstall.sh                     # 卸载脚本（调用子文件夹）
│   │
│   ├── local-path/                      # 方案一：local-path 自动管理
│   │   ├── tdengine_configmap.yaml      # taos.cfg 配置
│   │   ├── kustomization.yaml           # Kustomize 配置
│   │   ├── deploy.sh                    # 一键部署脚本
│   │   ├── uninstall.sh                 # 卸载脚本
│   │   └── tdengine.yaml                # 完整配置（Namespace + Service + StatefulSet）
│   │                                      数据暂不持久化（注释状态）
│   │
│   └── hostpath/                        # 方案二：hostPath 手动指定路径
│       ├── tdengine_configmap.yaml      # taos.cfg 配置
│       ├── kustomization.yaml           # Kustomize 配置
│       ├── deploy.sh                    # 一键部署脚本
│       ├── uninstall.sh                 # 卸载脚本
│       └── tdengine_hostpath.yaml       # 完整配置（PV + PVC + Namespace + Service + StatefulSet）
│
├── k8s-native-kubectl/                # 原生 K8s YAML 部署（纯 kubectl）
│   ├── README.md                        # 纯 kubectl 部署文档
│   ├── deploy.sh                        # 一键部署脚本（调用子文件夹）
│   └── uninstall.sh                     # 卸载脚本（调用子文件夹）
│   │
│   ├── local-path/                      # 方案一：local-path 自动管理
│   │   ├── tdengine_configmap.yaml      # taos.cfg 配置
│   │   ├── deploy.sh                    # 一键部署脚本
│   │   ├── uninstall.sh                 # 卸载脚本
│   │   └── tdengine.yaml                # 完整配置（Namespace + Service + StatefulSet）
│   │                                      数据暂不持久化（注释状态）
│   │
│   └── hostpath/                        # 方案二：hostPath 手动指定路径
│       ├── tdengine_configmap.yaml      # taos.cfg 配置
│       ├── deploy.sh                    # 一键部署脚本
│       ├── uninstall.sh                 # 卸载脚本
│       └── tdengine_hostpath.yaml       # 完整配置（PV + PVC + Namespace + Service + StatefulSet）
│
└── helm/                                # Helm Chart 部署
    ├── README-HELM.md
    ├── values-single-node.yaml
    └── values-cluster.yaml
```

> **说明**：
> - 父目录（`k8s-native/`、`k8s-native-kubectl/`）只保留文档和脚本，不包含 YAML 部署文件
> - 每个方案文件夹（`local-path/`、`hostpath/`）包含完整的独立部署文件，可直接进入执行部署
> - 方案一（`local-path/`）：数据目录暂不挂载 PVC，重启后数据丢失，适合测试/开发
> - 方案二（`hostpath/`）：数据持久化到指定宿主机路径，适合生产环境

## 部署方式选择

| 方式 | 适用场景 | 命令 | 文档 |
|------|---------|------|------|
| **Kustomize** | 需要配置覆盖、标签注入 | `cd k8s-native/local-path/ && kubectl apply -k .` | [k8s-native/README.md](k8s-native/README.md) |
| **纯 kubectl** | 简单直接、无需 Kustomize | `cd k8s-native-kubectl/local-path/ && ./deploy.sh` | [k8s-native-kubectl/README.md](k8s-native-kubectl/README.md) |
| **Helm Chart** | 快速部署、参数化配置 | `helm install tdengine tdengine/tdengine -f helm/values-single-node.yaml` | [helm/README-HELM.md](helm/README-HELM.md) |

## 快速开始

### 方式一：Kustomize（推荐）

```bash
cd k8s-native/local-path/
./deploy.sh
```

### 方式二：纯 kubectl

```bash
cd k8s-native-kubectl/local-path/
./deploy.sh
```

### 方式三：Helm Chart

```bash
helm repo add tdengine https://taosdata.github.io/TDengine-Operator
helm repo update

helm install tdengine tdengine/tdengine \
  --namespace ecloud \
  --create-namespace \
  -f helm/values-single-node.yaml
```

## 验证部署

```bash
# 查看 Pod
kubectl get pods -n ecloud -l app=tdengine

# 进入 taos shell
kubectl exec -it tdengine-0 -n ecloud -- taos

# 测试 REST API
curl -u root:taosdata http://<node-ip>:30441/rest/sql -d "show databases"
```

## 参考文档

- [TDengine-Operator GitHub](https://github.com/taosdata/TDengine-Operator/tree/3.0)
- [TDengine 官方文档](https://docs.tdengine.com/)
