# TDengine K3s 部署文档

本项目提供两种部署方式：原生 K8s YAML 和 Helm Chart。

## 目录结构

```
k3s-tdengine-deploy/
├── README.md                          # 本文档
├── k8s-native/                        # 原生 K8s YAML 部署
│   ├── README.md                      # 原生部署详细文档
│   ├── deploy.sh                      # 一键部署脚本
│   ├── uninstall.sh                   # 卸载脚本
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── service.yaml
│   ├── statefulset.yaml               # 单节点配置
│   └── DEPLOYMENT_SUMMARY.md          # 部署总结（含三节点集群配置）
│
└── helm/                              # Helm Chart 部署
    ├── README-HELM.md                 # Helm 部署文档
    ├── values-single-node.yaml        # 单节点 values
    └── values-cluster.yaml            # 三节点集群 values
```

## 部署方式选择

| 方式 | 适用场景 | 命令 | 文档 |
|------|---------|------|------|
| **原生 K8s YAML** | 需要精细控制、学习 K8s 资源 | `kubectl apply -k k8s-native/` | [k8s-native/README.md](k8s-native/README.md) |
| **Helm Chart** | 快速部署、参数化配置 | `helm install tdengine tdengine/tdengine -f helm/values-single-node.yaml` | [helm/README-HELM.md](helm/README-HELM.md) |

## 快速开始

### 方式一：原生 K8s YAML（推荐）

```bash
cd k8s-native/
./deploy.sh
```

### 方式二：Helm Chart

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
