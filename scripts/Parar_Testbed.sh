#!/bin/bash

# Cores do print (echo)
YELLOW="\033[33m"
RESET="\033[0m"

# Variáveis globais
CLUSTER_NAME="open5gs-testbed"
NAMESPACE="open5gs"

echo -e "${YELLOW}========================================${RESET}"
echo -e "${YELLOW} RESET COMPLETO DO TESTBED 5G${RESET}"
echo -e "${YELLOW} Cluster : ${CLUSTER_NAME}${RESET}"
echo -e "${YELLOW} Namespace: ${NAMESPACE}${RESET}"
echo -e "${YELLOW}========================================${RESET}"
echo

echo -e "${YELLOW}[1/10] Deletando Deployments no namespace ${NAMESPACE}...${RESET}"
kubectl delete deploy -n "${NAMESPACE}" --all --ignore-not-found

echo -e "${YELLOW}[2/10] Deletando Services no namespace ${NAMESPACE}...${RESET}"
kubectl delete svc -n "${NAMESPACE}" --all --ignore-not-found

echo -e "${YELLOW}[3/10] Deletando ConfigMaps no namespace ${NAMESPACE}...${RESET}"
kubectl delete cm -n "${NAMESPACE}" --all --ignore-not-found

echo -e "${YELLOW}[4/10] Helm uninstall (open5gs)...${RESET}"
helm uninstall open5gs -n "${NAMESPACE}" 2>/dev/null || true

echo -e "${YELLOW}[5/10] Deletando namespace ${NAMESPACE}...${RESET}"
kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=false

echo -e "${YELLOW}[6/10] Deletando cluster kind (${CLUSTER_NAME})...${RESET}"
kind delete cluster --name "${CLUSTER_NAME}" || true

echo -e "${YELLOW}[7/10] Limpando interface TUN...${RESET}"
sudo ip link delete uesimtun0 2>/dev/null || true

echo -e "${YELLOW}[8/10] Limpando Docker...${RESET}"
docker system prune -af

echo -e "${YELLOW}[9/10] Apagando diretório dos charts...${RESET}"
rm -rf charts/

echo -e "${YELLOW}[10/10] Apagando diretório de configurações...${RESET}"
rm -rf config/

echo
echo -e "${YELLOW}========================================${RESET}"
echo -e "${YELLOW} RESET FINALIZADO COM SUCESSO ✅${RESET}"
echo -e "${YELLOW}========================================${RESET}"

