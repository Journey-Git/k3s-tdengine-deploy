#!/bin/bash
# TDengine K3s 部署脚本（基于 TDengine-Operator 3.0 官方规范）
# 适用环境: K3s 单节点, local-path StorageClass

set -e

NAMESPACE="ecloud"
NODE_IP="192.168.31.222"

echo "================================"
echo "TDengine K3s 部署脚本"
echo "基于 TDengine-Operator 3.0 官方规范"
echo "目标节点: ${NODE_IP}"
echo "================================"

# 检查 kubectl
if ! command -v kubectl &> /dev/null; then
    echo "错误: kubectl 未安装"
    exit 1
fi

# 检查 K3s 版本
echo "[1/7] 检查 K3s 集群..."
kubectl version --short 2>/dev/null || kubectl version

# 检查节点
echo ""
echo "节点状态:"
kubectl get nodes -o wide

# 检查 StorageClass
echo ""
echo "[2/7] 检查 StorageClass..."
kubectl get sc

# 检查命名空间是否存在，如果存在则提示
echo ""
echo "[3/7] 创建命名空间 ${NAMESPACE}..."
if kubectl get namespace ${NAMESPACE} &> /dev/null; then
    echo "命名空间 ${NAMESPACE} 已存在，继续部署..."
else
    kubectl create namespace ${NAMESPACE}
    echo "命名空间 ${NAMESPACE} 创建成功"
fi

# 检查端口是否被占用
echo ""
echo "[4/7] 检查 NodePort 端口..."
for port in 30441 30603 30660; do
    if kubectl get svc --all-namespaces -o jsonpath='{range .items[*]}{range .spec.ports[*]}{.nodePort}{"\n"}{end}{end}' 2>/dev/null | grep -q "^${port}$"; then
        echo "警告: 端口 ${port} 已被占用，请检查现有 Service"
        kubectl get svc --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{": "}{range .spec.ports[*]}{.nodePort}{" "}{end}{"\n"}{end}' | grep "${port}"
    else
        echo "  端口 ${port} 可用"
    fi
done

# 部署
echo ""
echo "[5/7] 部署 TDengine..."
kubectl apply -k .

# 等待 StatefulSet 创建
echo ""
echo "[6/7] 等待 Pod 启动（约 1-2 分钟）..."
echo "  首次启动需要拉取镜像 (~500MB)，请耐心等待..."

for i in {1..60}; do
    POD_STATUS=$(kubectl get pods -n ${NAMESPACE} -l app=tdengine -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
    POD_READY=$(kubectl get pods -n ${NAMESPACE} -l app=tdengine -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
    
    if [ "$POD_STATUS" == "Running" ] && [ "$POD_READY" == "true" ]; then
        echo ""
        echo "  Pod 已就绪!"
        break
    fi
    
    # 显示更详细的状态
    if [ $((i % 6)) -eq 0 ]; then
        echo ""
        echo "  等待中... (${i}/60) 状态: ${POD_STATUS}, Ready: ${POD_READY}"
        kubectl get pods -n ${NAMESPACE} -l app=tdengine 2>/dev/null || true
    else
        echo -n "."
    fi
    sleep 10
done

# 最终验证
echo ""
echo "[7/7] 验证部署状态..."
echo ""
echo "--- Pod 状态 ---"
kubectl get pods -n ${NAMESPACE} -o wide

echo ""
echo "--- Service 状态 ---"
kubectl get svc -n ${NAMESPACE}

echo ""
echo "--- PVC 状态 ---"
kubectl get pvc -n ${NAMESPACE}

echo ""
echo "--- 验证 TDengine 服务 ---"
sleep 5
kubectl exec -it tdengine-0 -n ${NAMESPACE} -- taos -s "show dnodes; show mnodes" 2>/dev/null || echo "  服务验证失败，请检查日志: kubectl logs tdengine-0 -n ${NAMESPACE}"

echo ""
echo "================================"
echo "部署完成!"
echo ""
echo "访问地址（Node IP: ${NODE_IP}）"
echo "  taosAdapter REST API: http://${NODE_IP}:30441"
echo "    - InfluxDB Line Protocol 写入: http://${NODE_IP}:6041/influxdb/v1/write"
echo "  taosExplorer 管理界面: http://${NODE_IP}:30660"
echo "  taosd 服务端口: ${NODE_IP}:30603"
echo ""
echo "默认认证"
echo "  用户名: root"
echo "  密码:   taosdata"
echo ""
echo "快速测试"
echo "  # 查看数据库"
echo "  curl -u root:taosdata http://${NODE_IP}:30441/rest/sql -d 'show databases'"
echo ""
echo "  # 进入容器"
echo "  kubectl exec -it tdengine-0 -n ${NAMESPACE} -- taos"
echo ""
echo "  # 查看日志"
echo "  kubectl logs -f tdengine-0 -n ${NAMESPACE}"
echo ""
echo "数据存储"
echo "  节点本地路径: /var/lib/rancher/k3s/storage/"
echo "  PVC 通过 local-path provisioner 动态分配"
echo "================================"
