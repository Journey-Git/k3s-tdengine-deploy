#!/bin/bash

# TDengine K3s 部署脚本（Kustomize 版本）
# 使用 kubectl apply -k . 部署，支持 Kustomize 配置覆盖

set -e

NAMESPACE="ecloud"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================"
echo "TDengine K3s 部署脚本（Kustomize）"
echo "========================================"

# 1. 检查 K3s 集群
echo "[1/5] 检查 K3s 集群状态..."
kubectl get nodes > /dev/null 2>&1 || {
    echo "错误: 无法连接 K3s 集群，请检查 kubectl 配置"
    exit 1
}

# 2. 检查 hostPath 目录
echo "[2/5] 检查 hostPath 目录..."
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
HOST_PATH="/mnt/disk1/k3s/tdengine"
echo "  节点: ${NODE_NAME}"
echo "  hostPath: ${HOST_PATH}"
echo "  请确保宿主机目录 ${HOST_PATH}/data 和 ${HOST_PATH}/log 已创建"
echo "  mkdir -p ${HOST_PATH}/data ${HOST_PATH}/log"

# 3. 检查 Kustomize
echo "[3/5] 检查 Kustomize..."
kubectl kustomize --help > /dev/null 2>&1 || {
    echo "警告: kubectl kustomize 不可用，将尝试直接 apply"
}

# 4. 部署 TDengine
echo "[4/5] 部署 TDengine..."
cd ${SCRIPT_DIR}
kubectl apply -k .

# 5. 验证部署
echo "[5/5] 验证部署状态..."
echo ""
echo "等待 Pod 启动（最多 2 分钟）..."
kubectl wait --for=condition=ready pod -l app=tdengine -n ${NAMESPACE} --timeout=120s || {
    echo "警告: Pod 未在 2 分钟内就绪，请手动检查状态"
}

echo ""
echo "========================================"
echo "部署完成！"
echo "========================================"
echo ""
echo "Pod 状态:"
kubectl get pods -n ${NAMESPACE} -l app=tdengine

echo ""
echo "Service 状态:"
kubectl get svc -n ${NAMESPACE} -l app=tdengine

echo ""
echo "PVC 状态:"
kubectl get pvc -n ${NAMESPACE} -l app=tdengine

echo ""
echo "访问方式:"
echo "  - taosAdapter REST API: http://<node-ip>:30441"
echo "  - taosd 客户端: <node-ip>:30603"
echo "  - taosExplorer Web: http://<node-ip>:30660"
echo ""
echo "验证命令:"
echo "  kubectl exec -it tdengine-0 -n ${NAMESPACE} -- taos -s 'show databases'"
echo "  curl -u root:taosdata http://<node-ip>:30441/rest/sql -d 'show databases'"
echo ""
