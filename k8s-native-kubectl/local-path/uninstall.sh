#!/bin/bash

# TDengine K3s 卸载脚本（纯 kubectl 版本 - local-path 方案）
# 支持完全卸载（含数据删除）和保留数据卸载

set -e

NAMESPACE="ecloud"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 解析参数
KEEP_DATA=false
if [ "$1" = "--keep-data" ]; then
    KEEP_DATA=true
    echo "模式: 保留数据卸载（只删除 StatefulSet/Service/ConfigMap，PVC 保留）"
else
    echo "模式: 完全卸载（含数据删除）"
fi

echo "========================================"
echo "TDengine K3s 卸载脚本（纯 kubectl - local-path）"
echo "========================================"

# 1. 删除 StatefulSet（级联删除 Pod）
echo "[1/4] 删除 StatefulSet..."
kubectl delete statefulset tdengine -n ${NAMESPACE} --ignore-not-found=true

# 2. 删除 Service
echo "[2/4] 删除 Service..."
kubectl delete service tdengine-service tdengine-nodeport -n ${NAMESPACE} --ignore-not-found=true

# 3. 删除 ConfigMap
echo "[3/4] 删除 ConfigMap..."
kubectl delete configmap tdengine-config -n ${NAMESPACE} --ignore-not-found=true

# 4. 删除 PVC（可选）
if [ "$KEEP_DATA" = false ]; then
    echo "[4/4] 删除 PVC（数据将被删除！）..."
    kubectl delete pvc -l app=tdengine -n ${NAMESPACE} --ignore-not-found=true
    kubectl delete pvc taosdata-tdengine-0 -n ${NAMESPACE} --ignore-not-found=true
    echo ""
    echo "========================================"
    echo "完全卸载完成！数据已删除。"
    echo "========================================"
else
    echo "[4/4] 跳过 PVC 删除（数据保留）..."
    echo ""
    echo "========================================"
    echo "保留数据卸载完成！"
    echo "========================================"
    echo ""
    echo "保留的 PVC:"
    kubectl get pvc -n ${NAMESPACE} | grep taosdata || echo "无 PVC"
fi

echo ""
echo "Namespace ${NAMESPACE} 保留，可重新部署。"
echo ""
echo "如需单独删除 TDengine 相关 PVC:"
echo "  kubectl delete pvc -l app=tdengine -n ${NAMESPACE}"
echo ""
echo "⚠️  注意：Namespace 下可能还有其他服务，请勿随意删除整个 Namespace。"
echo ""
