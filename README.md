## 📌 Autor

<p align="center">
  <img src="ITA.png" alt="ITA Logo" width="220">
</p>

**WAGNER COMIN SONAGLIO**  
Aluno de **Mestrado** – PPGAO / PG-EEC  
Instituto Tecnológico de Aeronáutica (ITA)  

Pesquisa em **segurança de redes móveis (5G / Open RAN)** e **impacto na resiliência do canal de Comando e Controle (C2) de UAVs**.

**Orientador:** Dr. Lourenço Alves Pereira Júnior  

[![Email](https://img.shields.io/badge/email-wagner.sonaglio%40gmail.com-blue)](mailto:wagner.sonaglio@gmail.com)

# 5G UAV Testbed – Open5GS + UERANSIM + MAVLink

Este repositório contém um **testbed completo de rede 5G Standalone (SA)** usando **Open5GS** como core, **UERANSIM** para emulação de gNB e UEs, e **MAVLink** para simular comunicação **UAV ↔ GCS** sobre 5G.

O ambiente foi pensado para **experimentos acadêmicos**, **pesquisa em cibersegurança**, **resiliência do canal C2**, e **testes de falhas/ataques** (ex.: DoS, perda de link, injeção de C2, reset do gNB, entre outros).

---

## 🧱 Arquitetura do Testbed

**Componentes principais**
- **Open5GS** – Core 5G (AMF, SMF, UPF, etc.)
- **UERANSIM gNB** – Estação rádio simulada
- **UERANSIM UE (UAV)** – Drone (telemetria + failsafe RTL)
- **UERANSIM UE (GCS)** – Ground Control Station (terminal interativo)
- **UERANSIM UE (ROGUE)** – UE atacante (ferramentas de pentest)
- **Kubernetes (kind)** – Orquestração local
- **Docker** – Runtime de containers - Kind

**Fluxo lógico da arquitetura**

```text
================================================================================
🛰️ TESTBED 5G + UAV/GCS + ROGUE (Open5GS + UERANSIM)
================================================================================

┌──────────────────────────────────────────────────────────────────────────────┐
│                          KUBERNETES CLUSTER                                  │
│                          Namespace: open5gs                                  │
└──────────────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────┐
  │           UERANSIM gNB          │
  │   (RAN / Access - gNB Pod)      │
  │                                 │
  │  - NGAP  → AMF (N2)             │
  │  - GTP-U → UPF (N3)             │
  │  - Rádio lógico (sem camada PHY)│
  └───────────────┬─────────────────┘
                  │
                  │  (RAN Access: N2/N3)
                  │
   ┌──────────────┴────────────────────────────────────────────────────────────┐
   │                          OPEN5GS CORE (5GC)                               │
   │                    (Control Plane + User Plane)                           │
   └───────────────────────────────────────────────────────────────────────────┘

   ┌───────────────────────────────────────────────────────────────────────────┐
   │ CONTROL PLANE (SBA + NGAP)                                                │
   │                                                                           │
   │  N2 / NGAP                                                                │
   │   ┌──────────────┐                                                        │
   │   │     AMF      │  ◄─────── gNB (NGAP / N2)                              │
   │   │ open5gs-amf  │                                                        │
   │   └──────┬───────┘                                                        │
   │          │                                                                │
   │          │  SBI / SBA (HTTP/2 + service-based interfaces)                 │
   │          │              (com SCP no meio)                                 │
   │          │                                                                │
   │   ┌──────▼────────────────────────────────────────────────────────────┐   │
   │   │                    SCP (Service Communication Proxy)              │   │
   │   │                      open5gs-scp                                  │   │
   │   └──────┬────────────────────────────────────────────────────────────┘   │
   │          │                                                                │
   │          │  Serviços registram/descobrem via NRF e falam via SCP          │
   │          │                                                                │
   │  ┌───────▼───────┐        ┌──────────────┐        ┌──────────────┐        │
   │  │      NRF      │        │     AUSF     │        │     UDM      │        │
   │  │ open5gs-nrf   │        │ open5gs-ausf │        │ open5gs-udm  │        │
   │  └───────┬───────┘        └───────┬──────┘        └───────┬──────┘        │
   │          │                        │                       │               │
   │          │                        │                       │               │
   │  ┌───────▼───────┐        ┌───────▼───────┐        ┌──────▼───────┐       │
   │  │      SMF      │        │      PCF      │        │      UDR     │       │
   │  │ open5gs-smf   │        │ open5gs-pcf   │        │ open5gs-udr  │       │
   │  └───────┬───────┘        └───────────────┘        └──────┬───────┘       │
   │          │                                                │               │
   │          │ N4                                             │               │
   │          │                                                │               │
   │  ┌───────▼───────┐                                 ┌──────▼──────────┐    │
   │  │      UPF      │                                 │    MongoDB      │    │
   │  │ open5gs-upf   │                                 │ open5gs-mongodb │    │
   │  └───────────────┘                                 └─────────────────┘    │
   │                                                                           │
   │  Serviços adicionais presentes no core:                                   │
   │   - BSF   (open5gs-bsf)   → binding / seleção de PCF em alguns fluxos     │
   │   - NSSF  (open5gs-nssf)  → seleção de slice (NSSAI)                      │
   │   - SEPP  (open5gs-sepp)  → fronteira/segurança inter-PLMN (roaming)      │
   │                                                                           │
   │  Operação / suporte no testbed:                                           │
   │   - open5gs-webui     → UI de gestão                                      │
   │   - open5gs-populate  → popula assinantes/config no DB                    │
   └───────────────────────────────────────────────────────────────────────────┘


   ┌───────────────────────────────────────────────────────────────────────────┐
   │ USER PLANE                                                                │
   │                                                                           │
   │                         N3 (GTP-U)                                        │
   │        gNB ───────────────────────────────────────► UPF                   │
   │                                                   │                       │
   │                                                   │  - Encap/Decap GTP-U  │
   │                                                   │  - NAT/Forwarding     │
   │                                                   │  - PDR/FAR/QER rules  │
   │                                                   │                       │
   │                              N6 (IP)              │                       │
   │                    UE traffic (IP/UDP/TCP/ICMP) ──┘                       │
   └───────────────────────────────────────────────────────────────────────────┘


================================================================================
📌 UEs (UERANSIM) e suas interfaces de dados
================================================================================

  ┌───────────────────────────────┐
  │ UE1: UAV (drone)              │
  │ Pod: ueransim-uav             │
  │ Interface de dados: uesimtun0 │
  │ IP (ex): 10.45.0.X            │
  │                               │
  │ App: uav.py (pymavlink)       │
  │  - RX: UDP 14550              │
  │  - TX: UDP 14551              │
  └───────────────┬───────────────┘
                  │
                  │   Tráfego IP (N6) via UPF
                  │   (túnel uesimtun0 do UE → GTP-U → UPF → UE destino)
                  │
  ┌───────────────▼───────────────┐
  │ UE2: GCS (controlador)        │
  │ Pod: ueransim-gcs             │
  │ Interface de dados: uesimtun0 │
  │ IP (ex): 10.45.0.X            │
  │                               │
  │ App: gcs.py (pymavlink)       │
  │  - TX: UDP 14550 (para UAV)   │
  │  - RX: UDP 14551 (do UAV)     │
  │  - Terminal interativo        │
  └───────────────────────────────┘


================================================================================
🔁 Fluxo MAVLink (plano de usuário / UDP)
================================================================================

  [GCS (UE2)]                             [UPF/N6]                         [UAV (UE1)]
      |                                      |                                 |
      | UDP → 10.45.0.3:14550 (command_long) |                                 |
      |------------------------------------->|-------------------------------->|
      |                                      |                                 |
      | UDP ← 10.45.0.4:14551 (heartbeat/telemetry/statustext)                 |
      |<-------------------------------------|<--------------------------------|
      |                                      |                                 |

  Observação:
  - Isso é tráfego de USER PLANE (dados), não passa no AMF/SMF como “pacote”.
  - AMF/SMF configuram a sessão; quem encaminha IP/UDP é o UPF.


================================================================================
🧨 UE3: ROGUE (atacante) — Vetores e Impactos (compartilha o mesmo Core e UPF)
================================================================================

  ┌───────────────────────────────┐
  │ UE3: ROGUE (atacante)         │
  │ Pod: ueransim-rogue           │
  │ Interface: uesimtun0          │
  │ IP (ex): 10.45.0.X            │
  │                               │
  │ Capacidades no testbed:       │
  │  - DoS Volumétrico            │
  │  - Injeção NAS/SCTP           │
  │  - Spoofing de IMSI           │
  │  - Storm de Sinalização       │
  │  - Injeção de Comandos C2     │
  │  - Interceptação Telemetria   │
  └───────────────┬───────────────┘
                  │
                  │  Mesmo UPF / mesmo “domínio IP” dos UEs
                  │  → compartilha recursos de user-plane
                  │
  ┌───────────────▼───────────────┐
  │ Impacto típico:               │
  │  - Saturação CPU do UPF (100%)│
  │  - Colapso do AMF (Livelock)  │
  │  - Desconexão forçada do GCS  │
  │  - Latência/Jitter no Mavlink │
  │  - Acionamento Failsafe (RTL) │
  │  - Vazamento de GPS/Vídeo     │
  │  - Sequestro de UAV (Hijack)  │
  └───────────────────────────────┘


================================================================================
🧩 Resumo por camadas
================================================================================

  CAMADA 5G (Controle / Sessão)
  - UE (UAV/GCS/ROGUE) fazem registro e sessão via gNB → AMF/SMF → UPF
  - Aqui estão autenticação, criação de PDU Session, regras do UPF etc.

  CAMADA IP (User Plane)
  - Depois da sessão pronta, tráfego vira IP normal (UDP/TCP/ICMP)
  - MAVLink roda como UDP em cima do IP entre IP's' 10.45.0.X

  CAMADA APLICAÇÃO (MAVLink - exemplo)
  - GCS envia COMMAND_LONG / SET_MODE / SET_POSITION_TARGET_LOCAL_NED
  - UAV responde com HEARTBEAT / GLOBAL_POSITION_INT / STATUSTEXT
```

---

## 📁 Estrutura do Repositório

```text
.
├── README.md
├── scripts/
│   ├── Iniciar_Testbed.sh      # Inicializa cluster, core, gNB e UEs
│   └── Parar-Testbed.sh        # Para cluster e faz limpeza total
|
├── scripts_MAVlink/
│   ├── uav.py                  # Simulador do UAV
│   └── gcs.py                  # Simulador do GCS
│
├── config/
│   ├── ngc-values.yaml                   # Valores base do Open5GS
│   ├── open5gs-override.yaml             # UPF como root (possibilita tcpdump)
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

Arquivos:
- `config/ueransim-gnb01-deploy.yaml` (ConfigMap)
- `config/ueransim-gnb01-deploy.yaml` (Deployment)
- `config/ueransim-gnb01-svc.yaml` (Service headless)

Deploy:

```bash
kubectl apply -f config/ueransim-gnb01-config.yaml
kubectl apply -f config/ueransim-gnb01-deploy.yaml
kubectl apply -f config/ueransim-gnb01-svc.yaml
```

### Logs úteis

```bash
kubectl logs -n open5gs deploy/ueransim-gnb01 -f
kubectl logs -n open5gs $(kubectl get pods -n open5gs -o name | grep amf | head -n 1) --tail=50
```

---

## 05 – Limpar e Cadastrar Subscribers

> **Nota prática:** o uso de `sqn: Long(256)` evita erros do tipo  
> `SQN out of range` em cenários de reset, falhas de attach ou instabilidade do lab.
>
> Em ambientes reais, o correto é manter o sincronismo de SQN.  
> Aqui, trata-se de um *workaround* prático para experimentação.

---

#### 🔄 Remover subscribers atuais

```bash
kubectl exec -n open5gs deployment/open5gs-mongodb -ti -- \
mongosh open5gs --eval '
db.subscribers.deleteMany({});
print("Subscribers removidos");
'
```

---

#### 🔍 Conferir remoção

```bash
kubectl exec -n open5gs deployment/open5gs-mongodb -ti -- \
mongosh open5gs --eval 'db.subscribers.find().pretty()'
```

---

#### ➕ Inserir novos subscribers (UAV / GCS / ROGUE)

```bash
kubectl exec -n open5gs deployment/open5gs-mongodb -ti -- \
mongosh open5gs --eval '
db.subscribers.insertMany([
  {
    schema_version: 1,
    imsi: "999700000000001",
    slice: [{
      sst: 1,
      sd: "111111",
      default_indicator: true,
      session: [{
        name: "internet",
        type: 3,
        qos: {
          index: 9,
          arp: {
            priority_level: 8,
            pre_emption_capability: 1,
            pre_emption_vulnerability: 2
          }
        },
        ambr: {
          downlink: { value: 1000000000, unit: 0 },
          uplink:   { value: 1000000000, unit: 0 }
        },
        pcc_rule: []
      }]
    }],
    security: {
      k: "465B5CE8B199B49FAA5F0A2EE238A6BC",
      opc: "E8ED289DEBA952E4283B54E88E6183CA",
      amf: "8000",
      sqn: Long(256)
    },
    ambr: {
      downlink: { value: 1000000000, unit: 0 },
      uplink:   { value: 1000000000, unit: 0 }
    },
    access_restriction_data: 32,
    network_access_mode: 0,
    subscriber_status: 0
  },

  {
    schema_version: 1,
    imsi: "999700000000002",
    slice: [{
      sst: 1,
      sd: "111111",
      default_indicator: true,
      session: [{
        name: "internet",
        type: 3,
        qos: {
          index: 9,
          arp: {
            priority_level: 8,
            pre_emption_capability: 1,
            pre_emption_vulnerability: 2
          }
        },
        ambr: {
          downlink: { value: 1000000000, unit: 0 },
          uplink:   { value: 1000000000, unit: 0 }
        },
        pcc_rule: []
      }]
    }],
    security: {
      k: "465B5CE8B199B49FAA5F0A2EE238A6BC",
      opc: "E8ED289DEBA952E4283B54E88E6183CA",
      amf: "8000",
      sqn: Long(256)
    },
    ambr: {
      downlink: { value: 1000000000, unit: 0 },
      uplink:   { value: 1000000000, unit: 0 }
    },
    access_restriction_data: 32,
    network_access_mode: 0,
    subscriber_status: 0
  },

  {
    schema_version: 1,
    imsi: "999700000000003",
    slice: [{
      sst: 1,
      sd: "111111",
      default_indicator: true,
      session: [{
        name: "internet",
        type: 3,
        qos: {
          index: 9,
          arp: {
            priority_level: 8,
            pre_emption_capability: 1,
            pre_emption_vulnerability: 2
          }
        },
        ambr: {
          downlink: { value: 1000000000, unit: 0 },
          uplink:   { value: 1000000000, unit: 0 }
        },
        pcc_rule: []
      }]
    }],
    security: {
      k: "465B5CE8B199B49FAA5F0A2EE238A6BC",
      opc: "E8ED289DEBA952E4283B54E88E6183CA",
      amf: "8000",
      sqn: Long(256)
    },
    ambr: {
      downlink: { value: 1000000000, unit: 0 },
      uplink:   { value: 1000000000, unit: 0 }
    },
    access_restriction_data: 32,
    network_access_mode: 0,
    subscriber_status: 0
  }
]);

print("3 subscribers inseridos com sucesso");
'
```

---

#### ✅ Conferir inserção

```bash
kubectl exec -n open5gs deployment/open5gs-mongodb -ti -- \
mongosh open5gs --eval 'db.subscribers.find().pretty()'
```

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

### Comunicação MAVlink do UAV x GCS

Entrar no bash do UAV e executar o app "uav":
```bash
kubectl exec -it -n open5gs deploy/ueransim-uav -- bash
uav
```
Entrar no bash do GCS e executar o app "gcs":
```bash
kubectl exec -it -n open5gs deploy/ueransim-gcs -- bash
gcs
help
```

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

### Desligar gNB ou UPF (validar dependência do túnel GTP-U)

```bash
kubectl scale deployment ueransim-gnb01 -n open5gs --replicas=0
kubectl scale deployment ueransim-upf -n open5gs --replicas=0
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

Se você estiver usando os scripts em `scripts/`, o comando é:

```bash
./scripts/Iniciar-Testbed.sh
./scripts/Parar-Testbed.sh
```

Os scripts funcionam após a instalação das dependências. 
Eles geram e fazem download dos arquivos de configuração de forma automática, sem necessidade de baixar os arquivos em "config" e "charts".

> Ajuste as permissões caso necessário:
> ```bash
> chmod +x scripts/*.sh
> ```

## Observações

### Utilização do Protocolo MAVlink 1.0 

Por padrão os scripts estão utilizando o MAVlink 2.0. Caso opte pela versão 1.0, deve-se editar os arquivos "/tmp/uav.py" e "/tmp/gcs.py" dentro dos seus respectivos PODs e comentar as seguintes linhas:
```bash
import os
os.environ['MAVLINK20'] = '1'
```

---
