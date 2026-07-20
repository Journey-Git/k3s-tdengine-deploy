#!/bin/bash

# TDengine K3s 部署脚本（纯 kubectl 版本 - hostPath 方案）
# 使用 kubectl apply -f 直接部署，无需 Kustomize

set -e

NAMESPACE="ecloud"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================"
echo "TDengine K3s 部署脚本（纯 kubectl - hostPath）"
echo "========================================"

# 1. 检查 K3s 集群
echo "[1/5] 检查 K3s 集群状态..."
kubectl get nodes > /dev/null 2>&1 || {
    echo "错误: 无法连接 K3s 集群，请检查 kubectl 配置"
    exit 1
}

# 2. 检查并创建 hostPath 目录
echo "[2/5] 检查 hostPath 目录..."
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
HOST_PATH="/mnt/disk1/k3s/tdengine"
echo "  节点: ${NODE_NAME}"
echo "  hostPath: ${HOST_PATH}"

# 通过 kubectl 在节点上创建目录
echo "  检查并创建宿主机目录..."
LOCAL_PATH_POD=$(kubectl get pod -n kube-system -l app=local-path-provisioner -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "${LOCAL_PATH_POD}" ]; then
    kubectl exec -it ${LOCAL_PATH_POD} -n kube-system -- sh -c "mkdir -p ${HOST_PATH}/data ${HOST_PATH}/log && chmod 755 ${HOST_PATH}/data ${HOST_PATH}/log" > /dev/null 2>&1 && {
        echo "  ✓ 宿主机目录已创建"
    } || {
        echo "  ⚠️  无法通过 local-path-provisioner 创建目录"
        echo "  请手动在节点 ${NODE_NAME} 上执行:"
        echo "    sudo mkdir -p ${HOST_PATH}/data ${HOST_PATH}/log"
        echo "    sudo chmod 755 ${HOST_PATH}/data ${HOST_PATH}/log"
    }
else
    echo "  ⚠️  无法自动创建目录，请手动在节点 ${NODE_NAME} 上执行:"
    echo "    sudo mkdir -p ${HOST_PATH}/data ${HOST_PATH}/log"
    echo "    sudo chmod 755 ${HOST_PATH}/data ${HOST_PATH}/log"
fi

# 3. 创建命名空间（如果不存在）
echo "[3/5] 创建命名空间 ${NAMESPACE}..."
kubectl get namespace ${NAMESPACE} > /dev/null 2>&1 || {
    echo "命名空间 ${NAMESPACE} 不存在，创建中..."
    kubectl create namespace ${NAMESPACE}
    echo "命名空间 ${NAMESPACE} 已创建"
}

# 4. 部署 TDengine
echo "[4/5] 部署 TDengine..."
kubectl apply -f ${SCRIPT_DIR}/tdengine_configmap.yaml
kubectl apply -f ${SCRIPT_DIR}/tdengine_hostpath.yaml

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
