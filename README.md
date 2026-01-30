## 📌 Autor
**Wagner Comin Sonaglio**  
[![Email](https://img.shields.io/badge/email-wagner.sonaglio%40gmail.com-blue)](mailto:wagner.sonaglio@gmail.com)

ITA – Pesquisa em segurança de redes móveis (5G/6G) e resiliência de C2 UAV

# 5G UAV Testbed – Open5GS + UERANSIM + MAVLink

Este repositório contém um **testbed completo de rede 5G Standalone (SA)** usando **Open5GS** como core, **UERANSIM** para emulação de gNB e UEs, e **MAVLink** para simular comunicação **UAV ↔ GCS** sobre 5G.

O ambiente foi pensado para **experimentos acadêmicos**, **pesquisa em cibersegurança**, **resiliência do canal C2**, e **testes de falhas/ataques** (ex.: DoS, perda de link, reset do gNB).

---

## 🧱 Arquitetura do Testbed

**Componentes principais**
- **Open5GS** – Core 5G (AMF, SMF, UPF, etc.)
- **UERANSIM gNB** – Estação rádio simulada
- **UERANSIM UE (UAV)** – Drone (telemetria + failsafe RTL)
- **UERANSIM UE (GCS)** – Ground Control Station (terminal interativo)
- **UERANSIM UE (ROGUE)** – UE atacante (Scapy/hping3 para testes)
- **Kubernetes (kind)** – Orquestração local
- **Docker** – Runtime de containers

**Fluxo lógico (visão simplificada)**

```text
UAV (UE1)  <----5G---->  gNB  <----NGAP/SBA---->  Open5GS Core
   ↑                                                |
   |----------------- MAVLink (UDP) ----------------|
   ↓
GCS (UE2)

ROGUE (UE3) compartilha o mesmo core e UPF
```

---

## 📁 Estrutura do Repositório

```text
.
├── README.md
├── scripts/
│   ├── Iniciar_Testbed.sh      # Inicializa cluster, core, gNB e UEs
│   └── Parar-Testbed.sh        # Para e faz limpeza total
│
├── config/
│   ├── ngc-values.yaml                   # Valores base do Open5GS
│   ├── open5gs-override.yaml             # UPF como root (tcpdump)
│   ├── ueransim-gnb01-config.yaml
│   ├── ueransim-gnb01-deploy.yaml
│   ├── ueransim-gnb01-svc.yaml
│   ├── ueransim-uav-config.yaml
│   ├── ueransim-uav-deploy.yaml
│   ├── ueransim-uav-svc.yaml
│   ├── ueransim-gcs-config.yaml
│   ├── ueransim-gcs-deploy.yaml
│   ├── ueransim-gcs-svc.yaml
│   ├── ueransim-rogue-config.yaml
│   ├── ueransim-rogue-deploy.yaml
│   └── ueransim-rogue-svc.yaml
│
└── charts/
    └── open5gs-*.tgz          # Chart Helm já baixado
```

> **Observação:** as pastas `config/` e `charts/` podem conter arquivos de exemplo já prontos (valores e charts baixados).

---

## ⚙️ Pré-requisitos

Recomendado:
- **Debian 12 (Bookworm)** / **Ubuntu 22.04+**

Ferramentas:
- Docker + Docker Compose Plugin
- `kubectl`
- `kind`
- `helm`

---

## 01 – Instalação de Dependências

### Ferramentas

```bash
sudo apt update && sudo apt install -y \
  tcpdump \
  traceroute \
  net-tools \
  conntrack \
  jq \
  wireshark
```

### Docker

```bash
sudo apt-get remove docker-compose
sudo apt-get --fix-broken install
sudo apt-get remove docker docker-engine docker.io containerd runc
sudo apt-get update
sudo apt-get install ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo docker run hello-world
sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker $USER
sudo systemctl start docker
sudo systemctl enable docker
newgrp docker
docker --version
docker compose version
```

### kubectl

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
kubectl version --client
```

### kind

```bash
curl -Lo kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
chmod +x kind
sudo mv kind /usr/local/bin/
kind version
```

### Helm

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

---

## 02 – Configuração do Testbed

### Roteamento da Internet

```bash
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-ipforward.conf
sudo sysctl --system
```

### Criar cluster

```bash
kind create cluster --name open5gs-testbed
kubectl cluster-info
kubectl get nodes
```

### Namespace

```bash
kubectl create namespace open5gs
kubectl get namespaces | grep open5gs
```

### Pastas

```bash
mkdir -p charts
mkdir -p config
```

### Baixar charts

```bash
helm pull oci://registry-1.docker.io/gradiantcharts/open5gs --destination charts
```

### Baixar values de exemplo

```bash
wget -P config/ https://gradiant.github.io/5g-charts/docs/open5gs-srsran-5g-zmq/ngc-values.yaml
```

---

## 03 – Deploy do Open5GS (Core 5G)

### Override (UPF como root) – para capturar pacotes

```bash
cat > config/open5gs-override.yaml << 'EOF'
upf:
  containerSecurityContext:
    runAsUser: 0
    runAsGroup: 0
EOF
```

### Instalar/Deploy

```bash
helm install open5gs ./charts/open5gs-*.tgz \
  --namespace open5gs \
  --values config/ngc-values.yaml \
  -f config/open5gs-override.yaml
```

### Validação

```bash
watch -n 10 kubectl get pods -n open5gs
kubectl get pods -n open5gs
kubectl logs -n open5gs $(kubectl get pods -n open5gs -o name | grep amf | head -n 1) --tail=50
```

---

## 04 – Deploy do UERANSIM gNB (GNB01)

### ConfigMap do gNB

```bash
cat > config/ueransim-gnb01-config.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: ueransim-gnb01-config
  namespace: open5gs
data:
  gnb-base.yaml: |
    mcc: "999"
    mnc: "70"
    nci: "0x10"
    idLength: 32
    tac: 1

    amfConfigs:
      - address: open5gs-amf-ngap.open5gs.svc.cluster.local
        port: 38412

    slices:
      - sst: 1
        sd: "0x111111"
EOF
```

```bash
kubectl apply -f config/ueransim-gnb01-config.yaml
```

### Deployment do gNB

```bash
cat > config/ueransim-gnb01-deploy.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ueransim-gnb01
  namespace: open5gs
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ueransim-gnb01
  template:
    metadata:
      labels:
        app: ueransim-gnb01
    spec:
      containers:
        - name: gnb
          image: free5gc/ueransim:latest
          env:
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
          command: ["/bin/sh","-lc"]
          args:
            - |
              cat /config/gnb-base.yaml > /tmp/gnb.yaml
              echo "" >> /tmp/gnb.yaml
              echo "linkIp: ${POD_IP}" >> /tmp/gnb.yaml
              echo "ngapIp: ${POD_IP}" >> /tmp/gnb.yaml
              echo "gtpIp: ${POD_IP}" >> /tmp/gnb.yaml
              echo "ignoreStreamIds: true" >> /tmp/gnb.yaml

              exec /ueransim/nr-gnb -c /tmp/gnb.yaml
          volumeMounts:
            - name: cfg
              mountPath: /config
      volumes:
        - name: cfg
          configMap:
            name: ueransim-gnb01-config
EOF
```

```bash
kubectl apply -f config/ueransim-gnb01-deploy.yaml
```

### Service headless do gNB

```bash
cat > config/ueransim-gnb01-svc.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: ueransim-gnb01
  namespace: open5gs
spec:
  clusterIP: None
  selector:
    app: ueransim-gnb01
EOF
```

```bash
kubectl apply -f config/ueransim-gnb01-svc.yaml
```

### Logs úteis

```bash
kubectl logs -n open5gs deploy/ueransim-gnb01 -f
kubectl logs -n open5gs $(kubectl get pods -n open5gs -o name | grep amf | head -n 1) --tail=50
```

---

## 05 – Limpar e Cadastrar Subscribers

### Remover subscribers atuais

```bash
kubectl exec -n open5gs deployment/open5gs-mongodb -ti -- \
mongosh open5gs --eval '
db.subscribers.deleteMany({});
print("Subscribers removidos");
'
```

### Conferir remoção

```bash
kubectl exec -n open5gs deployment/open5gs-mongodb -ti -- \
mongosh open5gs --eval 'db.subscribers.find().pretty()'
```

### Inserir 3 subscribers (UAV / GCS / ROGUE)

> **Nota prática:** `sqn: Long(256)` evita `SQN out of range` em cenários de reset/instabilidade.

> **Importante:** o bloco completo de `insertMany([...])` deve estar no seu repositório **exatamente como no tutorial** (é grande).  
> Se você quiser, posso também gerar este README já com o bloco inteiro incluído (sem encurtar nada).

---

## 06 – Deploy do UE1 (UAV) – UERANSIM-UAV

Arquivos:
- `config/ueransim-uav-config.yaml` (ConfigMap: `ue.yaml.tpl`, `uav`, `uav.py`)
- `config/ueransim-uav-deploy.yaml` (Deployment)
- `config/ueransim-uav-svc.yaml` (Service headless)

Deploy:

```bash
kubectl apply -f config/ueransim-uav-config.yaml
kubectl apply -f config/ueransim-uav-deploy.yaml
kubectl apply -f config/ueransim-uav-svc.yaml
```

Logs e teste:

```bash
kubectl logs -n open5gs deploy/ueransim-uav -f
kubectl exec -n open5gs deploy/ueransim-uav -- ping -I uesimtun0 -c 4 8.8.8.8
```

---

## 07 – Deploy do UE2 (GCS) – UERANSIM-GCS

Arquivos:
- `config/ueransim-gcs-config.yaml` (ConfigMap: `ue.yaml.tpl`, `gcs`, `gcs.py`)
- `config/ueransim-gcs-deploy.yaml` (Deployment)
- `config/ueransim-gcs-svc.yaml` (Service headless)

Deploy:

```bash
kubectl apply -f config/ueransim-gcs-config.yaml
kubectl apply -f config/ueransim-gcs-deploy.yaml
kubectl apply -f config/ueransim-gcs-svc.yaml
```

---

## 08 – Deploy do UE3 (ROGUE) – UERANSIM-ROGUE

Ferramentas instaladas no container:
- `scapy`
- `hping3`
- `tcpdump`

Deploy:

```bash
kubectl apply -f config/ueransim-rogue-config.yaml
kubectl apply -f config/ueransim-rogue-deploy.yaml
kubectl apply -f config/ueransim-rogue-svc.yaml
```

---

## 09 – Testes

### Log do AMF (registro)

```bash
kubectl logs -n open5gs $(kubectl get pods -n open5gs -o name | grep amf | head -n 1) --tail=80
```

### IP/rotas dos UEs

```bash
kubectl exec -n open5gs deploy/ueransim-uav   -- ip addr show uesimtun0
kubectl exec -n open5gs deploy/ueransim-gcs   -- ip addr show uesimtun0
kubectl exec -n open5gs deploy/ueransim-rogue -- ip addr show uesimtun0
```

### Ping Internet

```bash
kubectl exec -n open5gs deploy/ueransim-uav   -- ping -I uesimtun0 -c 4 8.8.8.8
kubectl exec -n open5gs deploy/ueransim-gcs   -- ping -I uesimtun0 -c 4 8.8.8.8
kubectl exec -n open5gs deploy/ueransim-rogue -- ping -I uesimtun0 -c 4 8.8.8.8
```

### Verificar se o ping passa pelo UPF

```bash
kubectl exec -n open5gs deploy/open5gs-upf -ti -- bash -lc 'tcpdump -ni ogstun icmp'
```

### Deletar / desligar gNB (validar dependência do túnel)

```bash
kubectl scale deployment ueransim-gnb01 -n open5gs --replicas=0
```

---

## 10 – Limpeza Total (Reset completo)

```bash
kubectl delete deploy -n open5gs --all
kubectl delete svc -n open5gs --all
kubectl delete cm -n open5gs --all
helm uninstall open5gs -n open5gs
kubectl delete namespace open5gs
kind delete cluster --name open5gs-testbed
sudo ip link delete uesimtun0 2>/dev/null || true
docker system prune -af
```

---

## ▶️ Uso via scripts

Se você estiver usando os scripts em `scripts/`, a ideia é:

```bash
./scripts/Iniciar-Testbed.sh
./scripts/Parar-Testbed.sh
```

> Ajuste as permissões caso necessário:
> ```bash
> chmod +x scripts/*.sh
> ```

---
