#!/bin/bash
# TDengine K3s 卸载脚本（基于 TDengine-Operator 3.0 官方规范）
# 用法:
#   ./uninstall.sh           # 完全卸载（含数据）
#   ./uninstall.sh --keep-data  # 只删除 StatefulSet，保留 PVC（数据保留）

set -e

NAMESPACE="ecloud"
KEEP_DATA=false

# 解析参数
if [ "$1" == "--keep-data" ]; then
    KEEP_DATA=true
fi

echo "================================"
echo "TDengine K3s 卸载脚本"
echo "================================"

if [ "$KEEP_DATA" == true ]; then
    echo "模式: 保留数据（只删除 StatefulSet、Service、ConfigMap）"
    echo ""
    read -p "确认要卸载 TDengine 吗？数据将保留 (y/N) " confirm
else
    echo "模式: 完全卸载（含数据删除）"
    echo ""
    read -p "确认要卸载 TDengine 吗？所有数据将被删除！(y/N) " confirm
fi

if [[ $confirm != [yY] ]]; then
    echo "取消卸载"
    exit 0
fi

echo ""
echo "[1/3] 删除 StatefulSet..."
kubectl delete statefulset tdengine -n ${NAMESPACE} --ignore-not-found=true

echo ""
echo "[2/3] 删除 Service..."
kubectl delete service tdengine-service tdengine-nodeport -n ${NAMESPACE} --ignore-not-found=true

echo ""
echo "[3/3] 删除 ConfigMap..."
kubectl delete configmap tdengine-config -n ${NAMESPACE} --ignore-not-found=true

if [ "$KEEP_DATA" == false ]; then
    echo ""
    echo "[4/4] 删除 PVC（数据将被删除）..."
    kubectl delete pvc -l app=tdengine -n ${NAMESPACE} --ignore-not-found=true
    kubectl delete pvc taosdata-tdengine-0 -n ${NAMESPACE} --ignore-not-found=true 2>/dev/null || true
fi

echo ""
echo "================================"
echo "卸载完成!"

if [ "$KEEP_DATA" == true ]; then
    echo ""
    echo "数据已保留，PVC 状态:"
    kubectl get pvc -n ${NAMESPACE}
    echo ""
    echo "如需重新部署，直接执行:"
    echo "  ./deploy.sh"
else
    echo ""
    echo "如需完全删除命名空间，请执行:"
    echo "  kubectl delete namespace ${NAMESPACE}"
    echo ""
    echo "注意：PVC 删除后数据不可恢复！"
fi

echo "================================"
