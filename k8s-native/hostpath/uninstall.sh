#!/bin/bash

# TDengine K3s 卸载脚本（Kustomize 版本 - hostPath 方案）
# 支持完全卸载（含数据删除）和保留数据卸载
# 注意: hostPath 数据在宿主机上，需手动清理

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
echo "TDengine K3s 卸载脚本（Kustomize - hostPath）"
echo "========================================"

# 1. 使用 Kustomize 删除资源
echo "[1/3] 删除 Kustomize 管理的资源..."
cd ${SCRIPT_DIR}

if [ "$KEEP_DATA" = true ]; then
    # 保留数据：手动删除 TDengine 相关资源，不删 PVC，不删 Namespace
    kubectl delete statefulset tdengine -n ${NAMESPACE} --ignore-not-found=true
    kubectl delete service tdengine-service tdengine-nodeport -n ${NAMESPACE} --ignore-not-found=true
    kubectl delete configmap tdengine-config -n ${NAMESPACE} --ignore-not-found=true
else
    # 完全卸载：使用 kustomize 删除所有（不含 Namespace）
    kubectl delete -k . --ignore-not-found=true
fi

# 2. 清理 PVC（如果完全卸载）
if [ "$KEEP_DATA" = false ]; then
    echo "[2/3] 清理 PVC..."
    kubectl delete pvc -l app=tdengine -n ${NAMESPACE} --ignore-not-found=true
    kubectl delete pvc taosdata-tdengine-0 -n ${NAMESPACE} --ignore-not-found=true
fi

# 3. 验证清理
echo "[3/3] 验证清理状态..."
echo ""
echo "剩余资源:"
kubectl get all -n ${NAMESPACE} 2>/dev/null || echo "Namespace ${NAMESPACE} 为空或无法访问"

echo ""
echo "========================================"
if [ "$KEEP_DATA" = false ]; then
    echo "完全卸载完成！K8s 资源已删除。"
    echo "========================================"
    echo ""
    echo "⚠️  hostPath 数据仍在宿主机上，需手动清理:"
    echo "    /mnt/disk1/k3s/tdengine/data"
    echo "    /mnt/disk1/k3s/tdengine/log"
    echo ""
    echo "  清理命令:"
    echo "    ssh <node> \"rm -rf /mnt/disk1/k3s/tdengine\""
else
    echo "保留数据卸载完成！"
    echo "========================================"
    echo ""
    echo "保留的 PVC:"
    kubectl get pvc -n ${NAMESPACE} 2>/dev/null || echo "无 PVC"
fi

echo ""
