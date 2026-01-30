#!/bin/bash
set -Eeuo pipefail

# Garante compatibilidade de terminal
export TERM=${TERM:-xterm-256color}

# =========================
# Cores e Logs
# =========================
YELLOW="\033[33m"
RESET="\033[0m"
log() { echo -e "${YELLOW}$*${RESET}"; }
die() { echo -e "${YELLOW}[ERRO] $*${RESET}"; exit 1; }

# =========================
# Variáveis de Ambiente
# =========================
CLUSTER_NAME="open5gs-testbed"
NAMESPACE="open5gs"
CONFIG_DIR="config"
CHARTS_DIR="charts"
SLEEP_STEP=3

# =========================
# Funções Auxiliares
# =========================
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Comando '$1' não encontrado."; }

count_bad_pods() {
  awk '{
    ready=$2; status=$3; split(ready,r,"/");
    if (status=="Completed" || status=="Succeeded") next;
    if (status!="Running" || r[1]!=r[2]) bad++;
  } END {print bad+0}'
}

# =========================
# FUNÇÃO DE WATCH (Visual Fixo - Conta Linhas)
# =========================
wait_pods_watch() {
  local ns="$1"
  local selector="${2:-}"
  local loops=0
  local prev_lines=0
  
  echo
  log "[WAIT] Aguardando pods ($selector) em $ns..."
  
  while true; do
    ((++loops))
    
    if [ "$prev_lines" -gt 0 ]; then
       tput cuu "$prev_lines"
       tput ed
    fi
    
    local output
    output="$(kubectl get pods -n "$ns" ${selector:+-l "$selector"} --no-headers=false 2>/dev/null || true)"
    
    if [ -z "$output" ]; then output="[Ainda sem pods detectados...]"; fi
    
    local bad
    local pods_only
    pods_only="$(echo "$output" | grep -v "NAME" || true)"
    
    if [ -z "$pods_only" ]; then bad=1; else bad="$(echo "$pods_only" | count_bad_pods)"; fi
    
    local header_msg=""
    if [ "$bad" -eq 0 ] && [ -n "$pods_only" ]; then
       header_msg="${YELLOW}[WAIT] OK ✅ Loop=${loops} | Todos os pods estão Running/Ready.${RESET}"
    else
       header_msg="${YELLOW}[WAIT] Loop=${loops} | Falta(m): ${bad} pod(s) para ficar Running/Ready.${RESET}"
    fi

    echo -e "$header_msg"
    echo ""
    echo "$output"
    
    local out_lines
    out_lines=$(echo "$output" | wc -l)
    prev_lines=$((1 + 1 + out_lines))

    if [ "$bad" -eq 0 ] && [ -n "$pods_only" ]; then break; fi
    sleep "$SLEEP_STEP"
  done
  echo ""
}

# =========================
# 01 - CONFIGURAÇÃO INICIAL
# =========================
log "========================================"
log " INICIANDO TESTBED 5G COMPLETO (ITA)"
log "========================================"

for c in kind kubectl helm wget; do need_cmd "$c"; done

log "[01] Roteamento e Cluster..."
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-ipforward.conf >/dev/null
sudo sysctl --system >/dev/null

kind get clusters | grep -qx "${CLUSTER_NAME}" || kind create cluster --name "${CLUSTER_NAME}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
mkdir -p "${CONFIG_DIR}" "${CHARTS_DIR}"

# =========================
# 02 - DEPLOY OPEN5GS
# =========================
log "[02] Deploy Open5GS Core..."

# --- CORREÇÃO DE DOWNLOAD ---
log " -> Baixando Helm Chart (OCI)..."
if ! helm pull oci://registry-1.docker.io/gradiantcharts/open5gs --destination "${CHARTS_DIR}"; then
    die "Falha ao baixar o Chart do Open5GS. Verifique sua conexão ou se o Docker Hub está acessível."
fi

log " -> Baixando Values..."
if [ ! -f "${CONFIG_DIR}/ngc-values.yaml" ]; then
    wget -q -P "${CONFIG_DIR}" https://gradiant.github.io/5g-charts/docs/open5gs-srsran-5g-zmq/ngc-values.yaml || die "Falha ao baixar ngc-values.yaml"
fi

cat > "${CONFIG_DIR}/open5gs-override.yaml" << 'EOF'
upf:
  containerSecurityContext:
    runAsUser: 0
    runAsGroup: 0
EOF

# Verifica se o arquivo existe antes de tentar listar
CHART_TGZ=$(find "${CHARTS_DIR}" -name "open5gs-*.tgz" | head -n1)
if [ -z "$CHART_TGZ" ]; then
    die "Arquivo .tgz do Open5GS não encontrado em ${CHARTS_DIR}."
fi

log " -> Instalando Open5GS usando: $CHART_TGZ"
helm upgrade --install open5gs "$CHART_TGZ" -n "${NAMESPACE}" --values "${CONFIG_DIR}/ngc-values.yaml" -f "${CONFIG_DIR}/open5gs-override.yaml"

wait_pods_watch "${NAMESPACE}"

log "⏳ Aguardando 15s para estabilização do Core..."
sleep 15

# =========================
# 03 - CONFIGURAÇÃO gNB01
# =========================
log "[03] Configurando gNB (UERANSIM)..."
cat > "${CONFIG_DIR}/ueransim-gnb01-config.yaml" << 'EOF'
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
kubectl apply -f "${CONFIG_DIR}/ueransim-gnb01-config.yaml"

log "⏳ Aguardando 10s..."
sleep 10

cat > "${CONFIG_DIR}/ueransim-gnb01-deploy.yaml" << 'EOF'
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
kubectl apply -f "${CONFIG_DIR}/ueransim-gnb01-deploy.yaml"

log "⏳ Aguardando 10s..."
sleep 10

cat > "${CONFIG_DIR}/ueransim-gnb01-svc.yaml" << 'EOF'
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
kubectl apply -f "${CONFIG_DIR}/ueransim-gnb01-svc.yaml"

log "⏳ Aguardando 10s..."
sleep 10

wait_pods_watch "${NAMESPACE}" "app=ueransim-gnb01"

log "⏳ Aguardando 30s para estabilização do gNB..."
sleep 30

# =========================
# 04 - MONGODB SUBSCRIBERS
# =========================
log "[04] Cadastrando Assinantes..."

log " -> Limpando subscribers antigos..."
kubectl exec -n open5gs deployment/open5gs-mongodb -i -- \
mongosh open5gs --eval 'db.subscribers.deleteMany({}); print("Assinantes antigos removidos.");'

log "⏳ Aguardando 10s..."
sleep 10

log " -> Inserindo UAV, GCS e ROGUE..."
kubectl exec -n open5gs deployment/open5gs-mongodb -i -- \
mongosh open5gs --eval '
db.subscribers.insertMany([
  {
    schema_version: 1, imsi: "999700000000001",
    slice: [{ sst: 1, sd: "111111", default_indicator: true, session: [{ name: "internet", type: 3, qos: { index: 9, arp: { priority_level: 8, pre_emption_capability: 1, pre_emption_vulnerability: 2 } }, ambr: { downlink: { value: 1000000000, unit: 0 }, uplink: { value: 1000000000, unit: 0 } }, pcc_rule: [] }] }],
    security: { k: "465B5CE8B199B49FAA5F0A2EE238A6BC", opc: "E8ED289DEBA952E4283B54E88E6183CA", amf: "8000", sqn: Long(256) },
    ambr: { downlink: { value: 1000000000, unit: 0 }, uplink: { value: 1000000000, unit: 0 } },
    access_restriction_data: 32, network_access_mode: 0, subscriber_status: 0
  },
  {
    schema_version: 1, imsi: "999700000000002",
    slice: [{ sst: 1, sd: "111111", default_indicator: true, session: [{ name: "internet", type: 3, qos: { index: 9, arp: { priority_level: 8, pre_emption_capability: 1, pre_emption_vulnerability: 2 } }, ambr: { downlink: { value: 1000000000, unit: 0 }, uplink: { value: 1000000000, unit: 0 } }, pcc_rule: [] }] }],
    security: { k: "465B5CE8B199B49FAA5F0A2EE238A6BC", opc: "E8ED289DEBA952E4283B54E88E6183CA", amf: "8000", sqn: Long(256) },
    ambr: { downlink: { value: 1000000000, unit: 0 }, uplink: { value: 1000000000, unit: 0 } },
    access_restriction_data: 32, network_access_mode: 0, subscriber_status: 0
  },
  {
    schema_version: 1, imsi: "999700000000003",
    slice: [{ sst: 1, sd: "111111", default_indicator: true, session: [{ name: "internet", type: 3, qos: { index: 9, arp: { priority_level: 8, pre_emption_capability: 1, pre_emption_vulnerability: 2 } }, ambr: { downlink: { value: 1000000000, unit: 0 }, uplink: { value: 1000000000, unit: 0 } }, pcc_rule: [] }] }],
    security: { k: "465B5CE8B199B49FAA5F0A2EE238A6BC", opc: "E8ED289DEBA952E4283B54E88E6183CA", amf: "8000", sqn: Long(256) },
    ambr: { downlink: { value: 1000000000, unit: 0 }, uplink: { value: 1000000000, unit: 0 } },
    access_restriction_data: 32, network_access_mode: 0, subscriber_status: 0
  }
]);
print("Assinantes cadastrados com sucesso! ✅");
'

log "⏳ Aguardando 15s..."
sleep 15

# =========================
# 06 - DEPLOY INDIVIDUAL (SEQUENCIAL)
# =========================

# --- UAV ---
log "[06] Deploy UE1: UAV (IMSI 001)..."
cat > "${CONFIG_DIR}/ueransim-uav-config.yaml" << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: ueransim-uav-config
  namespace: open5gs
data:
  ue.yaml.tpl: |
    supi: "imsi-999700000000001"
    mcc: "999"
    mnc: "70"

    key: "465B5CE8B199B49FAA5F0A2EE238A6BC"
    op:  "E8ED289DEBA952E4283B54E88E6183CA"
    opType: "OPC"
    amf: "8000"

    gnbSearchList:
      - "__GNB_IP__"

    uacAic:
      mps: false
      mcs: false

    uacAcc:
      normalClass: 0
      class11: false
      class12: false
      class13: false
      class14: false
      class15: false

    sessions:
      - type: "IPv4"
        apn: "internet"
        slice:
          sst: 1
          sd: "0x111111"

    configured-nssai:
      - sst: 1
        sd: "0x111111"

    default-nssai:
      - sst: 1
        sd: "0x111111"

    integrity:
      IA1: true
      IA2: true
      IA3: true

    ciphering:
      EA0: true
      EA1: true
      EA2: true
      EA3: true

    integrityMaxRate:
      uplink: "full"
      downlink: "full"
  uav: |
    #!/bin/bash

    # Obtém o IP do UAV pela interface tun (uesimtun0)
    IP_UAV=$(ip -o -4 addr show dev uesimtun0 | awk '{print $4}' | cut -d/ -f1)
    echo "[UAV] Meu IP (uesimtun0): $IP_UAV"

    # Solicita ao usuário o IP do GCS
    read -p "[UAV] Digite o IP do GCS (tun): " IP_GCS

    # Exibe para conferência
    echo "[UAV] IP do GCS informado: $IP_GCS"

    # Faz a substituição do placeholder no script Python
    sed -i "s|GCS_IP = '.*'|GCS_IP = '$IP_GCS'|g" /tmp/uav.py

    # Executa o script Python
    /opt/mavlink-venv/bin/python3 /tmp/uav.py
  uav.py: |
    import time
    import math
    import socket
    from pymavlink import mavutil

    GCS_IP = '<GCS_IP>'
    UAV_LISTEN_PORT = 14550
    GCS_LISTEN_PORT = 14551

    HB_PERIOD = 1.0
    POS_PERIOD = 0.5

    # Failsafe por perda de HEARTBEAT do GCS
    GCS_HB_TIMEOUT_S = 60.0      # 1 min sem HB do GCS -> RTL
    RETRY_LOG_PERIOD_S = 30.0    # loga tentativa/erro a cada 30s

    # RTL (simples e realista o suficiente)
    RTL_ALT_M = 30.0             # sobe até 30m (se abaixo) antes de voltar
    RTL_HOME_RADIUS_M = 0.2      # raio para considerar chegou em home

    home_lat = -23.2000000
    home_lon = -45.9000000
    lat = home_lat
    lon = home_lon
    rel_alt_m = 0.0

    armed = False
    flying = False
    mode = 'STANDBY'
    target_alt_m = 0.0

    north_m = 0.0
    east_m = 0.0
    target_north_m = 0.0
    target_east_m = 0.0
    move_active = False

    CLIMB_MPS = 2.0
    MOVE_MPS = 5.0

    # Link / failsafe (baseado SOMENTE em heartbeat do GCS)
    last_gcs_hb = time.time()
    link_up = True
    failsafe_active = False
    last_retry_log = 0.0

    # RTL state
    rtl_active = False
    rtl_phase = 'IDLE'  # IDLE | CLIMB | RETURN | LAND

    def log(s):
        print(s, flush=True)

    def send_statustext(tx, text, severity=mavutil.mavlink.MAV_SEVERITY_INFO):
        tx.mav.statustext_send(severity, text.encode('utf-8')[:50])

    def send_ack(tx, command, result):
        tx.mav.command_ack_send(command, result)

    def deg_per_meter_lat():
        return 1.0 / 111320.0

    def deg_per_meter_lon(lat_deg):
        return 1.0 / (111320.0 * max(0.2, math.cos(math.radians(lat_deg))))

    def start_rtl(tx):
        global failsafe_active, rtl_active, rtl_phase, mode
        global move_active, target_north_m, target_east_m, target_alt_m

        failsafe_active = True
        rtl_active = True
        mode = 'RTL'

        if not flying:
            # se estiver no chão, RTL vira basicamente "espera"
            rtl_phase = 'IDLE'
            send_statustext(tx, 'RTL: vehicle not flying (idle)', mavutil.mavlink.MAV_SEVERITY_WARNING)
            log('[UAV] RTL: veículo no chão (idle).')
            return

        # fase 1: subir até RTL_ALT (se necessário)
        if rel_alt_m < RTL_ALT_M:
            target_alt_m = RTL_ALT_M
            rtl_phase = 'CLIMB'
            send_statustext(tx, f'RTL: climbing to {RTL_ALT_M:.1f}m')
            log(f'[UAV] RTL: subindo até {RTL_ALT_M:.1f}m.')
        else:
            rtl_phase = 'RETURN'
            send_statustext(tx, 'RTL: returning to launch')
            log('[UAV] RTL: retornando para HOME.')

        # define home como alvo
        move_active = True
        target_north_m = 0.0
        target_east_m  = 0.0

    def tick_rtl(tx):
        global rtl_active, rtl_phase, mode, move_active
        global target_alt_m

        if not rtl_active or not flying:
            return

        if rtl_phase == 'CLIMB':
            # quando atingir altitude alvo, vai para RETURN
            if abs(rel_alt_m - target_alt_m) < 0.2:
                rtl_phase = 'RETURN'
                send_statustext(tx, 'RTL: returning to launch')
                log('[UAV] RTL: atingiu altitude, retornando para HOME.')

        elif rtl_phase == 'RETURN':
            # se chegou em home, inicia LAND
            dist_home = math.hypot(north_m - 0.0, east_m - 0.0)
            if dist_home <= RTL_HOME_RADIUS_M and (not move_active):
                rtl_phase = 'LAND'
                mode = 'LAND'
                send_statustext(tx, 'RTL: reached home, landing')
                log('[UAV] RTL: chegou em HOME, iniciando pouso.')

        elif rtl_phase == 'LAND':
            # LAND é tratado pelo bloco padrão de LAND
            pass

    def exit_failsafe_link_restored(tx):
        global link_up, failsafe_active
        link_up = True
        # realista: link voltar NÃO cancela RTL automaticamente
        failsafe_active = False
        send_statustext(tx, 'GCS HEARTBEAT RESTORED', mavutil.mavlink.MAV_SEVERITY_INFO)
        log('[UAV] link restaurado: heartbeat do GCS voltou.')

    rx = mavutil.mavlink_connection(f'udpin:0.0.0.0:{UAV_LISTEN_PORT}')
    tx = mavutil.mavlink_connection(f'udpout:{GCS_IP}:{GCS_LISTEN_PORT}')

    log(f'[UAV] ouvindo MAVLink em 0.0.0.0:{UAV_LISTEN_PORT} | enviando para {GCS_IP}:{GCS_LISTEN_PORT}')

    first = rx.recv_match(blocking=True, timeout=30)
    if first is None:
        log('[UAV] nenhuma mensagem recebida em 30s. Abortando.')
        raise SystemExit(1)

    log(f'[UAV] link ativo (primeira msg): {first.get_type()}')

    last_hb_tx = 0.0
    last_pos_tx = 0.0
    last_sim = time.time()

    try:
        while True:
            now = time.time()
            dt = now - last_sim
            last_sim = now

            # 1) DETECÇÃO DE LINK (somente heartbeat do GCS)
            if link_up and (now - last_gcs_hb) > GCS_HB_TIMEOUT_S:
                link_up = False
                log('[UAV] FAILSAFE: heartbeat do GCS perdido (>=60s). Entrando em RTL.')
                send_statustext(tx, 'GCS HEARTBEAT LOST - RTL', mavutil.mavlink.MAV_SEVERITY_CRITICAL)
                start_rtl(tx)
                last_retry_log = 0.0  # força log imediato

            if not link_up:
                if (now - last_retry_log) >= RETRY_LOG_PERIOD_S:
                    last_retry_log = now
                    log('[UAV] tentando reestabelecer link (aguardando heartbeat do GCS)...')
                    send_statustext(tx, 'Attempting link restore...', mavutil.mavlink.MAV_SEVERITY_WARNING)

            # 2) dinâmica de voo
            if flying:
                # altitude
                if abs(rel_alt_m - target_alt_m) < 0.05:
                    rel_alt_m = target_alt_m
                else:
                    step = CLIMB_MPS * dt
                    if rel_alt_m < target_alt_m:
                        rel_alt_m = min(target_alt_m, rel_alt_m + step)
                    else:
                        rel_alt_m = max(target_alt_m, rel_alt_m - step)

                # movimento
                if move_active:
                    dn = target_north_m - north_m
                    de = target_east_m - east_m
                    dist = math.hypot(dn, de)
                    if dist < 0.2:
                        north_m = target_north_m
                        east_m = target_east_m
                        move_active = False
                        send_statustext(tx, 'Reached target position')
                    else:
                        step = min(MOVE_MPS * dt, dist)
                        north_m += (dn / dist) * step
                        east_m  += (de / dist) * step

                lat = home_lat + north_m * deg_per_meter_lat()
                lon = home_lon + east_m  * deg_per_meter_lon(home_lat)

            # tick do RTL (transições CLIMB->RETURN->LAND)
            tick_rtl(tx)

            # LAND mode (padrão)
            if mode == 'LAND' and flying:
                target_alt_m = 0.0
                if rel_alt_m <= 0.05:
                    rel_alt_m = 0.0
                    flying = False
                    move_active = False
                    rtl_active = False
                    rtl_phase = 'IDLE'
                    mode = 'STANDBY'
                    send_statustext(tx, 'Landed')
                    log('[UAV] pousou.')

            # 3) TX: heartbeat do UAV + telemetria
            if now - last_hb_tx >= HB_PERIOD:
                tx.mav.heartbeat_send(
                    mavutil.mavlink.MAV_TYPE_QUADROTOR,
                    mavutil.mavlink.MAV_AUTOPILOT_ARDUPILOTMEGA,
                    0, 0, 0
                )
                last_hb_tx = now
                log('[UAV] heartbeat enviado')

            if now - last_pos_tx >= POS_PERIOD:
                lat_i = int(lat * 1e7)
                lon_i = int(lon * 1e7)
                rel_alt_mm = int(rel_alt_m * 1000)
                alt_mm = rel_alt_mm
                tx.mav.global_position_int_send(
                    int(now * 1000) & 0xFFFFFFFF,
                    lat_i, lon_i,
                    alt_mm, rel_alt_mm,
                    0, 0, 0,
                    0
                )
                last_pos_tx = now

            # 4) RX
            m = rx.recv_match(blocking=False)
            if m:
                t = m.get_type()
                d = m.to_dict()

                # Link: atualiza somente se for HEARTBEAT do GCS
                if t == 'HEARTBEAT':
                    src_sys = getattr(m, 'get_srcSystem', lambda: None)()
                    hb_type = int(d.get('type', -1))
                    if hb_type == mavutil.mavlink.MAV_TYPE_GCS or src_sys == 255:
                        last_gcs_hb = now
                        if not link_up:
                            exit_failsafe_link_restored(tx)

                if t in ('COMMAND_LONG', 'SET_MODE', 'SET_POSITION_TARGET_LOCAL_NED'):
                    log(f'[UAV] recebido: {t} | conteúdo: {d}')

                # durante perda real de link (link_up == False), ignora comandos (não tem GCS de fato)
                if not link_up:
                    time.sleep(0.02)
                    continue

                # comandos normais (quando link está OK)
                if t == 'SET_MODE':
                    cm = int(d.get('custom_mode', 0))
                    if cm == 4:
                        mode = 'GUIDED'
                        rtl_active = False
                        rtl_phase = 'IDLE'
                    elif cm == 5:
                        mode = 'LOITER'
                    elif cm == 9:
                        mode = 'LAND'
                    else:
                        mode = 'STANDBY'
                    send_statustext(tx, 'Mode change requested')

                elif t == 'COMMAND_LONG':
                    cmd = int(d.get('command', -1))
                    p1 = float(d.get('param1', 0.0))
                    p7 = float(d.get('param7', 0.0))

                    # ARM/DISARM
                    if cmd == mavutil.mavlink.MAV_CMD_COMPONENT_ARM_DISARM:
                        if p1 >= 1.0:
                            if armed:
                                send_ack(tx, cmd, mavutil.mavlink.MAV_RESULT_ACCEPTED)
                                send_statustext(tx, 'Already armed')
                            else:
                                armed = True
                                send_ack(tx, cmd, mavutil.mavlink.MAV_RESULT_ACCEPTED)
                                send_statustext(tx, 'Motors armed')
                        else:
                            if flying and rel_alt_m > 0.5:
                                send_ack(tx, cmd, mavutil.mavlink.MAV_RESULT_DENIED)
                                send_statustext(tx, 'Disarm denied: airborne', mavutil.mavlink.MAV_SEVERITY_WARNING)
                            else:
                                armed = False
                                send_ack(tx, cmd, mavutil.mavlink.MAV_RESULT_ACCEPTED)
                                send_statustext(tx, 'Motors disarmed')

                    # TAKEOFF
                    elif cmd == mavutil.mavlink.MAV_CMD_NAV_TAKEOFF:
                        desired = float(p7)

                        if not armed:
                            send_ack(tx, cmd, mavutil.mavlink.MAV_RESULT_DENIED)
                            send_statustext(tx, 'Takeoff denied: not armed', mavutil.mavlink.MAV_SEVERITY_WARNING)
                        elif mode != 'GUIDED':
                            send_ack(tx, cmd, mavutil.mavlink.MAV_RESULT_DENIED)
                            send_statustext(tx, 'Takeoff denied: not GUIDED', mavutil.mavlink.MAV_SEVERITY_WARNING)
                        elif flying:
                            send_ack(tx, cmd, mavutil.mavlink.MAV_RESULT_DENIED)
                            send_statustext(tx, 'Takeoff denied: already flying', mavutil.mavlink.MAV_SEVERITY_WARNING)
                        elif desired <= 0.5:
                            send_ack(tx, cmd, mavutil.mavlink.MAV_RESULT_DENIED)
                            send_statustext(tx, 'Takeoff denied: altitude too low', mavutil.mavlink.MAV_SEVERITY_WARNING)
                        else:
                            flying = True
                            target_alt_m = desired
                            send_ack(tx, cmd, mavutil.mavlink.MAV_RESULT_ACCEPTED)
                            send_statustext(tx, f'Taking off to {desired:.1f}m')

                    # LAND
                    elif cmd == mavutil.mavlink.MAV_CMD_NAV_LAND:
                        if not flying:
                            send_ack(tx, cmd, mavutil.mavlink.MAV_RESULT_DENIED)
                            send_statustext(tx, 'Land denied: not flying', mavutil.mavlink.MAV_SEVERITY_WARNING)
                        else:
                            mode = 'LAND'
                            send_ack(tx, cmd, mavutil.mavlink.MAV_RESULT_ACCEPTED)
                            send_statustext(tx, 'Landing...')

                    else:
                        send_ack(tx, cmd, mavutil.mavlink.MAV_RESULT_UNSUPPORTED)

                elif t == 'SET_POSITION_TARGET_LOCAL_NED':
                    if not flying:
                        send_statustext(tx, 'Move denied: not flying', mavutil.mavlink.MAV_SEVERITY_WARNING)
                    elif mode != 'GUIDED':
                        send_statustext(tx, 'Move denied: not GUIDED', mavutil.mavlink.MAV_SEVERITY_WARNING)
                    else:
                        x = float(d.get('x', 0.0))
                        y = float(d.get('y', 0.0))
                        z = float(d.get('z', 0.0))
                        target_north_m = x
                        target_east_m = y
                        move_active = True
                        desired_alt = max(0.0, -z)
                        if desired_alt > 0.0:
                            target_alt_m = desired_alt
                        send_statustext(tx, f'Moving to N={x:.1f} E={y:.1f} alt~{target_alt_m:.1f}m')

            time.sleep(0.02)

    except KeyboardInterrupt:
        log('\\n[UAV] encerrado.')
EOF
kubectl apply -f "${CONFIG_DIR}/ueransim-uav-config.yaml"

log "⏳ Aguardando 10s..."
sleep 10

cat > "${CONFIG_DIR}/ueransim-uav-deploy.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ueransim-uav
  namespace: open5gs
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ueransim-uav
  template:
    metadata:
      labels:
        app: ueransim-uav
    spec:
      containers:
        - name: ue
          image: free5gc/ueransim:latest
          securityContext:
            privileged: true
            capabilities:
              add: ["NET_ADMIN"]
          env:
            - name: GNB_FQDN
              value: "ueransim-gnb01.open5gs.svc.cluster.local"
          command: ["/bin/sh","-lc"]
          args:
            - |
              set -e
              echo "[UAV] Resolving gNB FQDN: $GNB_FQDN"
              GNB_IP="$(getent hosts "$GNB_FQDN" | awk '{print $1; exit}')"
              if [ -z "$GNB_IP" ]; then
                echo "[UAV] ERROR: could not resolve $GNB_FQDN"
                exit 1
              fi
              echo "[UAV] gNB IP resolved: $GNB_IP"
              sed "s/__GNB_IP__/$GNB_IP/g" /config/ue.yaml.tpl > /tmp/ue.yaml
              echo "=== ue.yaml final (UAV) ==="
              cat /tmp/ue.yaml
              echo "=========================="
              echo "Instalando dependências..."  
              apt-get update && \
              apt-get install -y python3 python3-pip tcpdump nano iputils-ping python3-venv && \
              python3 -m venv /opt/mavlink-venv && \
              . /opt/mavlink-venv/bin/activate && \
              pip install pymavlink
              cp /config/uav.py /tmp/uav.py
              cp /config/uav /usr/local/bin/uav
              chmod +x /usr/local/bin/uav
              exec /ueransim/nr-ue -c /tmp/ue.yaml
          volumeMounts:
            - name: cfg
              mountPath: /config
            - name: devtun
              mountPath: /dev/net/tun
      volumes:
        - name: cfg
          configMap:
            name: ueransim-uav-config
        - name: devtun
          hostPath:
            path: /dev/net/tun
            type: CharDevice
EOF
kubectl apply -f "${CONFIG_DIR}/ueransim-uav-deploy.yaml"

log "⏳ Aguardando 10s..."
sleep 10

cat > "${CONFIG_DIR}/ueransim-uav-svc.yaml" << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: ueransim-uav
  namespace: open5gs
spec:
  clusterIP: None
  selector:
    app: ueransim-uav
EOF
kubectl apply -f "${CONFIG_DIR}/ueransim-uav-svc.yaml"

log "⏳ Aguardando 10s..."
sleep 10

wait_pods_watch "${NAMESPACE}" "app=ueransim-uav"
log "⏳ Aguardando 30s..."
sleep 30

# --- GCS ---
log "[07] Deploy UE2: GCS (IMSI 002)..."
cat > "${CONFIG_DIR}/ueransim-gcs-config.yaml" << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: ueransim-gcs-config
  namespace: open5gs
data:
  ue.yaml.tpl: |
    supi: "imsi-999700000000002"
    mcc: "999"
    mnc: "70"

    key: "465B5CE8B199B49FAA5F0A2EE238A6BC"
    op:  "E8ED289DEBA952E4283B54E88E6183CA"
    opType: "OPC"
    amf: "8000"

    gnbSearchList:
      - "__GNB_IP__"

    uacAic:
      mps: false
      mcs: false

    uacAcc:
      normalClass: 0
      class11: false
      class12: false
      class13: false
      class14: false
      class15: false

    sessions:
      - type: "IPv4"
        apn: "internet"
        slice:
          sst: 1
          sd: "0x111111"

    configured-nssai:
      - sst: 1
        sd: "0x111111"

    default-nssai:
      - sst: 1
        sd: "0x111111"

    integrity:
      IA1: true
      IA2: true
      IA3: true

    ciphering:
      EA0: true
      EA1: true
      EA2: true
      EA3: true

    integrityMaxRate:
      uplink: "full"
      downlink: "full"
  gcs: |
    #!/bin/bash

    # Obtém o IP do GCS pela interface tun (uesimtun0)
    IP_GCS=$(ip -o -4 addr show dev uesimtun0 | awk '{print $4}' | cut -d/ -f1)
    echo "[GCS] Meu IP (uesimtun0): $IP_GCS"

    # Solicita ao usuário o IP do UAV
    read -p "[GCS] Digite o IP do UAV (tun): " IP_UAV

    # Exibe para conferência
    echo "[GCS] IP do UAV informado: $IP_UAV"

    # Substitui placeholder no script Python
    sed -i "s|DRONE_IP = '.*'|DRONE_IP = '$IP_UAV'|g" /tmp/gcs.py

    # Executa o script Python
    /opt/mavlink-venv/bin/python3 /tmp/gcs.py
  gcs.py: |
    import time
    import threading
    import socket
    from collections import deque
    from pymavlink import mavutil

    DRONE_IP = '<IP_UAV>'
    DRONE_LISTEN_PORT = 14550
    CTRL_LISTEN_PORT  = 14551

    SYS_ID  = 255
    COMP_ID = 190

    LINK_TIMEOUT_S = 30.0  # sem telemetria do UAV por 30s => desconectado
    HB_PERIOD_S = 1.0      # heartbeat do GCS 1Hz (independente do input)

    rx = mavutil.mavlink_connection(
        f'udpin:0.0.0.0:{CTRL_LISTEN_PORT}',
        source_system=SYS_ID,
        source_component=COMP_ID
    )
    tx = mavutil.mavlink_connection(
        f'udpout:{DRONE_IP}:{DRONE_LISTEN_PORT}',
        source_system=SYS_ID,
        source_component=COMP_ID
    )

    print(f'[GCS] enviando para {DRONE_IP}:{DRONE_LISTEN_PORT}, ouvindo em {CTRL_LISTEN_PORT}', flush=True)

    # Estado compartilhado
    lock = threading.Lock()
    last_pos = None
    last_ack = None
    last_statustext = None
    last_rx_any = time.time()

    # fila para imprimir “em lote” antes do prompt (terminal limpo)
    rx_events = deque(maxlen=200)

    # Link state
    link_up = True
    stopped = False
    running = True

    def hb_send_once():
        tx.mav.heartbeat_send(
            mavutil.mavlink.MAV_TYPE_GCS,
            mavutil.mavlink.MAV_AUTOPILOT_INVALID,
            0, 0, 0
        )

    def pretty_pos(p):
        lat = p['lat'] / 1e7
        lon = p['lon'] / 1e7
        alt_m = p['alt'] / 1000.0
        rel_alt_m = p['relative_alt'] / 1000.0
        return lat, lon, alt_m, rel_alt_m

    def help_print():
        print(
            """
    === COMANDOS (exemplos) ===
    help
    status

    arm
    disarm

    mode guided
    mode loiter
    mode land

    takeoff 10
    takeoff 10m
    land

    setpos 20 10 15

    pos     -> mostra última posição recebida (GLOBAL_POSITION_INT)
    alt     -> mostra última altitude recebida (GLOBAL_POSITION_INT)

    quit
    """,
            flush=True
        )

    def warn_lost():
        print('[GCS] CONEXÃO PERDIDA (>=30s sem telemetria do UAV).', flush=True)

    def ensure_link_or_warn():
        with lock:
            ok = (not stopped) and link_up
        if not ok:
            warn_lost()
            print('[GCS] Comando NÃO enviado.', flush=True)
            return False
        return True

    def send_arm(value: int):
        if not ensure_link_or_warn():
            return
        tx.mav.command_long_send(
            1, 0,
            mavutil.mavlink.MAV_CMD_COMPONENT_ARM_DISARM,
            0,
            float(value), 0, 0, 0, 0, 0, 0
        )
        print(f'[GCS] ARM_DISARM enviado param1={value}', flush=True)

    def send_takeoff(alt_m: float):
        if not ensure_link_or_warn():
            return
        tx.mav.command_long_send(
            1, 0,
            mavutil.mavlink.MAV_CMD_NAV_TAKEOFF,
            0,
            0, 0, 0, 0, 0, 0,
            float(alt_m)  # param7
        )
        print(f'[GCS] TAKEOFF enviado alt={alt_m}m', flush=True)

    def send_land():
        if not ensure_link_or_warn():
            return
        tx.mav.command_long_send(
            1, 0,
            mavutil.mavlink.MAV_CMD_NAV_LAND,
            0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
        print('[GCS] LAND enviado', flush=True)

    def send_mode(custom_mode: int, name: str):
        if not ensure_link_or_warn():
            return
        tx.mav.set_mode_send(
            1,
            mavutil.mavlink.MAV_MODE_FLAG_CUSTOM_MODE_ENABLED,
            custom_mode
        )
        print(f'[GCS] MODE enviado {name.lower()} (custom_mode={custom_mode})', flush=True)

    def send_setpos(north_m: float, east_m: float, alt_m: float):
        if not ensure_link_or_warn():
            return
        z_down = -float(alt_m)
        tx.mav.set_position_target_local_ned_send(
            int(time.time() * 1000) & 0xFFFFFFFF,
            1, 0,
            mavutil.mavlink.MAV_FRAME_LOCAL_NED,
            0b0000111111000111,
            float(north_m), float(east_m), float(z_down),
            0, 0, 0,
            0, 0, 0,
            0, 0
        )
        print(f'[GCS] SETPOS enviado N={north_m} E={east_m} ALT={alt_m}', flush=True)

    def rx_worker():
        global last_pos, last_ack, last_statustext, last_rx_any, running
        while running:
            try:
                m = rx.recv_match(blocking=True, timeout=0.5)
            except Exception:
                continue
            if not m:
                continue
            t = m.get_type()
            d = m.to_dict()

            with lock:
                last_rx_any = time.time()
                if t == 'GLOBAL_POSITION_INT':
                    last_pos = d
                elif t == 'COMMAND_ACK':
                    last_ack = d
                    rx_events.append(('COMMAND_ACK', d))
                elif t == 'STATUSTEXT':
                    last_statustext = d
                    rx_events.append(('STATUSTEXT', d))
                # HEARTBEAT ignorado (não poluir)

    def hb_worker():
        global running
        while running:
            # heartbeat continua existindo mesmo se você não digitar nada
            with lock:
                ok = (not stopped) and link_up
            if ok:
                try:
                    hb_send_once()
                except Exception:
                    pass
            time.sleep(HB_PERIOD_S)

    # threads
    t_rx = threading.Thread(target=rx_worker, daemon=True)
    t_hb = threading.Thread(target=hb_worker, daemon=True)
    t_rx.start()
    t_hb.start()

    # heartbeats iniciais (só “cosmético”)
    for i in range(3):
        hb_send_once()
        print(f'[GCS] heartbeat inicial {i+1}', flush=True)
        time.sleep(0.5)

    print('\n[GCS] Terminal interativo pronto (digite help)\n', flush=True)

    def flush_rx_events():
        # imprime eventos acumulados ANTES do prompt, mantendo terminal limpo
        printed = 0
        while True:
            with lock:
                if not rx_events:
                    break
                typ, payload = rx_events.popleft()
            print(f"\n[GCS] rx: {typ} | {payload}", flush=True)
            printed += 1
            if printed >= 30:
                break

    try:
        while True:
            # 1) atualiza timeout de link (independente de input)
            now = time.time()
            with lock:
                if link_up and (now - last_rx_any) > LINK_TIMEOUT_S:
                    link_up = False
                    stopped = True

            # 2) imprime o aviso uma vez (terminal limpo)
            with lock:
                became_down = stopped and (not link_up)
            if became_down:
                # só loga uma vez, então zera eventos repetidos
                print('\n[GCS] CONEXÃO PERDIDA (>=30s sem telemetria). Parando TX (sem reconectar).', flush=True)

            # 3) imprime RX pendente antes do prompt
            flush_rx_events()

            cmdline = input('[GCS] Comando> ').strip()
            if not cmdline:
                continue

            parts = cmdline.split()
            cmd = parts[0].lower()

            if cmd in ('help', '?'):
                help_print()
                continue

            if cmd in ('quit', 'exit'):
                print('[GCS] saindo...', flush=True)
                break

            if cmd == 'status':
                with lock:
                    st = last_statustext
                    ak = last_ack
                    lp = last_pos
                    down = stopped or (not link_up)
                if down:
                    warn_lost()

                print('[GCS] --- STATUS ---', flush=True)
                print(f"[GCS] last STATUSTEXT: {st if st else '(nenhum)'}", flush=True)
                print(f"[GCS] last COMMAND_ACK: {ak if ak else '(nenhum)'}", flush=True)
                if lp:
                    lat, lon, alt_m, rel_alt_m = pretty_pos(lp)
                    print(f'[GCS] last POS: lat={lat:.7f} lon={lon:.7f} rel_alt={rel_alt_m:.1f}m', flush=True)
                else:
                    print('[GCS] last POS: (nenhuma)', flush=True)
                continue

            if cmd == 'arm':
                send_arm(1); continue
            if cmd == 'disarm':
                send_arm(0); continue

            if cmd == 'mode' and len(parts) == 2:
                name = parts[1].lower()
                if name == 'guided':
                    send_mode(4, 'GUIDED')
                elif name == 'loiter':
                    send_mode(5, 'LOITER')
                elif name == 'land':
                    send_mode(9, 'LAND')
                else:
                    print('[GCS] modos: guided | loiter | land', flush=True)
                continue

            if cmd == 'takeoff':
                if len(parts) != 2:
                    print('[GCS] uso: takeoff <alt_m>', flush=True); continue
                raw = parts[1].lower().replace('m', '')
                try:
                    send_takeoff(float(raw))
                except ValueError:
                    print('[GCS] uso: takeoff <alt_m>  (ex: takeoff 10 | takeoff 10m)', flush=True)
                continue

            if cmd == 'land':
                send_land(); continue

            if cmd == 'setpos':
                if len(parts) != 4:
                    print('[GCS] uso: setpos <north_m> <east_m> <alt_m>', flush=True); continue
                try:
                    send_setpos(float(parts[1]), float(parts[2]), float(parts[3]))
                except ValueError:
                    print('[GCS] uso: setpos <north_m> <east_m> <alt_m>', flush=True)
                continue

            if cmd == 'pos':
                with lock:
                    lp = last_pos
                if not lp:
                    print('[GCS] ainda não recebi GLOBAL_POSITION_INT', flush=True)
                else:
                    lat, lon, alt_m, rel_alt_m = pretty_pos(lp)
                    print(f'[GCS] POS lat={lat:.7f} lon={lon:.7f} alt={alt_m:.1f}m rel_alt={rel_alt_m:.1f}m', flush=True)
                continue

            if cmd == 'alt':
                with lock:
                    lp = last_pos
                if not lp:
                    print('[GCS] ainda não recebi GLOBAL_POSITION_INT', flush=True)
                else:
                    lat, lon, alt_m, rel_alt_m = pretty_pos(lp)
                    print(f'[GCS] ALT rel_alt={rel_alt_m:.1f}m (alt={alt_m:.1f}m)', flush=True)
                continue

            print('[GCS] comando desconhecido. digite: help', flush=True)

    finally:
        running = False
EOF
kubectl apply -f "${CONFIG_DIR}/ueransim-gcs-config.yaml"

log "⏳ Aguardando 10s..."
sleep 10

cat > "${CONFIG_DIR}/ueransim-gcs-deploy.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ueransim-gcs
  namespace: open5gs
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ueransim-gcs
  template:
    metadata:
      labels:
        app: ueransim-gcs
    spec:
      containers:
        - name: ue
          image: free5gc/ueransim:latest
          securityContext:
            privileged: true
            capabilities:
              add: ["NET_ADMIN"]
          env:
            - name: GNB_FQDN
              value: "ueransim-gnb01.open5gs.svc.cluster.local"
          command: ["/bin/sh","-lc"]
          args:
            - |
              set -e
              echo "[GCS] Resolving gNB FQDN: $GNB_FQDN"
              GNB_IP="$(getent hosts "$GNB_FQDN" | awk '{print $1; exit}')"
              if [ -z "$GNB_IP" ]; then
                echo "[GCS] ERROR: could not resolve $GNB_FQDN"
                exit 1
              fi
              echo "[GCS] gNB IP resolved: $GNB_IP"
              sed "s/__GNB_IP__/$GNB_IP/g" /config/ue.yaml.tpl > /tmp/ue.yaml
              echo "=== ue.yaml final (GCS) ==="
              cat /tmp/ue.yaml
              echo "=========================="
              apt-get update && \
              apt-get install -y python3 python3-pip tcpdump nano iputils-ping python3-venv && \
              python3 -m venv /opt/mavlink-venv && \
              . /opt/mavlink-venv/bin/activate && \
              pip install pymavlink
              cp /config/gcs.py /tmp/gcs.py
              cp /config/gcs /usr/local/bin/gcs
              chmod +x /usr/local/bin/gcs
              exec /ueransim/nr-ue -c /tmp/ue.yaml
          volumeMounts:
            - name: cfg
              mountPath: /config
            - name: devtun
              mountPath: /dev/net/tun
      volumes:
        - name: cfg
          configMap:
            name: ueransim-gcs-config
        - name: devtun
          hostPath:
            path: /dev/net/tun
            type: CharDevice
EOF
kubectl apply -f "${CONFIG_DIR}/ueransim-gcs-deploy.yaml"

log "⏳ Aguardando 10s..."
sleep 10

cat > "${CONFIG_DIR}/ueransim-gcs-svc.yaml" << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: ueransim-gcs
  namespace: open5gs
spec:
  clusterIP: None
  selector:
    app: ueransim-gcs
EOF
kubectl apply -f "${CONFIG_DIR}/ueransim-gcs-svc.yaml"

log "⏳ Aguardando 10s..."
sleep 10

wait_pods_watch "${NAMESPACE}" "app=ueransim-gcs"
log "⏳ Aguardando 30s..."
sleep 30

# --- ROGUE ---
log "[08] Deploy UE3: ROGUE (IMSI 003)..."
cat > "${CONFIG_DIR}/ueransim-rogue-config.yaml" << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: ueransim-rogue-config
  namespace: open5gs
data:
  ue.yaml.tpl: |
    supi: "imsi-999700000000003"
    mcc: "999"
    mnc: "70"

    key: "465B5CE8B199B49FAA5F0A2EE238A6BC"
    op:  "E8ED289DEBA952E4283B54E88E6183CA"
    opType: "OPC"
    amf: "8000"

    gnbSearchList:
      - "__GNB_IP__"

    uacAic:
      mps: false
      mcs: false

    uacAcc:
      normalClass: 0
      class11: false
      class12: false
      class13: false
      class14: false
      class15: false

    sessions:
      - type: "IPv4"
        apn: "internet"
        slice:
          sst: 1
          sd: "0x111111"

    configured-nssai:
      - sst: 1
        sd: "0x111111"

    default-nssai:
      - sst: 1
        sd: "0x111111"

    integrity:
      IA1: true
      IA2: true
      IA3: true

    ciphering:
      EA0: true
      EA1: true
      EA2: true
      EA3: true

    integrityMaxRate:
      uplink: "full"
      downlink: "full"
EOF
kubectl apply -f "${CONFIG_DIR}/ueransim-rogue-config.yaml"

log "⏳ Aguardando 10s..."
sleep 10

cat > "${CONFIG_DIR}/ueransim-rogue-deploy.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ueransim-rogue
  namespace: open5gs
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ueransim-rogue
  template:
    metadata:
      labels:
        app: ueransim-rogue
    spec:
      containers:
        - name: ue
          image: free5gc/ueransim:latest
          securityContext:
            privileged: true
            capabilities:
              add: ["NET_ADMIN"]
          env:
            - name: GNB_FQDN
              value: "ueransim-gnb01.open5gs.svc.cluster.local"
          command: ["/bin/sh","-lc"]
          args:
            - |
              set -e
              echo "[ROGUE] Resolving gNB FQDN: $GNB_FQDN"
              GNB_IP="$(getent hosts "$GNB_FQDN" | awk '{print $1; exit}')"
              if [ -z "$GNB_IP" ]; then
                echo "[ROGUE] ERROR: could not resolve $GNB_FQDN"
                exit 1
              fi
              echo "[ROGUE] gNB IP resolved: $GNB_IP"
              sed "s/__GNB_IP__/$GNB_IP/g" /config/ue.yaml.tpl > /tmp/ue.yaml
              echo "=== ue.yaml final (ROGUE) ==="
              cat /tmp/ue.yaml
              echo "============================"
              apt-get update && \
              apt-get install -y python3 python3-pip python3-venv libsctp-dev lksctp-tools tcpdump nano hping3 iputils-ping && \
              python3 -m venv /opt/rogue-venv && \
              . /opt/rogue-venv/bin/activate && \
              pip install scapy
              exec /ueransim/nr-ue -c /tmp/ue.yaml
          volumeMounts:
            - name: cfg
              mountPath: /config
            - name: devtun
              mountPath: /dev/net/tun
      volumes:
        - name: cfg
          configMap:
            name: ueransim-rogue-config
        - name: devtun
          hostPath:
            path: /dev/net/tun
            type: CharDevice
EOF
kubectl apply -f "${CONFIG_DIR}/ueransim-rogue-deploy.yaml"

log "⏳ Aguardando 10s..."
sleep 10

cat > "${CONFIG_DIR}/ueransim-rogue-svc.yaml" << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: ueransim-rogue
  namespace: open5gs
spec:
  clusterIP: None
  selector:
    app: ueransim-rogue
EOF
kubectl apply -f "${CONFIG_DIR}/ueransim-rogue-svc.yaml"

log "⏳ Aguardando 10s..."
sleep 10

wait_pods_watch "${NAMESPACE}" "app=ueransim-rogue"

log "⏳ Aguardando 60s..."
sleep 60

# =========================
# 09 - FINALIZAÇÃO
# =========================
log "======================================"
log " TESTE DE PING FINAL (UE -> Internet) "
log "======================================"
# Função que insiste no Ping até funcionar, reiniciando o UE se falhar
verificar_conexao() {
  local deploy_name=$1
  local target_ip="8.8.8.8"
  
  log "--- Verificando: $deploy_name ---"
  
  while true; do
    # Tenta pingar (o 'if' impede que o erro pare o script)
    if kubectl exec -n open5gs "deploy/$deploy_name" -- ping -I uesimtun0 -c 4 "$target_ip"; then
       log "✅ $deploy_name: Conectividade ESTABELECIDA!"
       break
    else
       log "⚠️ $deploy_name: Ping falhou!"
       log "🔄 Executando: kubectl rollout restart deployment $deploy_name..."
       
       kubectl rollout restart deployment "$deploy_name" -n open5gs
       
       log "⏳ Aguardando 60s para reinicialização do pod..."
       sleep 60
       
       # O loop volta ao início para tentar pingar novamente
    fi
  done
}

# Executa a verificação para cada UE sequencialmente
verificar_conexao "ueransim-uav"
verificar_conexao "ueransim-gcs"
verificar_conexao "ueransim-rogue"

log "================================="
log "TESTBED 5G SUBIDO COM SUCESSO! ✅"
log "================================="
