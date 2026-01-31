# =========================
# IMPORTS
# =========================

import time
# time: usado para medir tempo (dt), controlar períodos (heartbeat/posição), e timeouts do link.

import math
# math: usado para trigonometria e distância (hypot, cos, radians).

import os
os.environ['MAVLINK20'] = '1' 
# Utilizado para forçar a utilização do MAVlink 2.0 - comentar as duas linhas acima caso queira usar o 1.0

from pymavlink import mavutil
# pymavlink: MAVLink via Python. mavutil fornece conexões UDP e constantes MAVLink.


# =========================
# CONFIGURAÇÃO DE REDE (ENDEREÇOS/PORTAS)
# =========================

GCS_IP = '<GCS_IP>'
# IP do GCS (controlador). O UAV enviará telemetria para esse IP.

UAV_LISTEN_PORT = 14550
# Porta local onde o UAV vai ESCUTAR comandos MAVLink (por exemplo: comandos do GCS).

GCS_LISTEN_PORT = 14551
# Porta do GCS onde o UAV vai ENVIAR telemetria e statustexts.


# =========================
# PERÍODOS DE TX (HEARTBEAT E POSIÇÃO)
# =========================

HB_PERIOD = 1.0
# Heartbeat do UAV a cada 1s.

POS_PERIOD = 0.5
# Telemetria de posição (GLOBAL_POSITION_INT) a cada 0.5s.


# =========================
# FAILSAFE POR PERDA DE HEARTBEAT DO GCS
# =========================

GCS_HB_TIMEOUT_S = 60.0      # 1 min sem HB do GCS -> RTL
# Se o UAV ficar 60s sem receber heartbeat do GCS, considera link perdido e entra em RTL.

RETRY_LOG_PERIOD_S = 30.0    # loga tentativa/erro a cada 30s
# Enquanto o link estiver “down”, ele loga “tentando reestabelecer” a cada 30s para não spammar.


# =========================
# PARÂMETROS DO RTL (Return To Launch)
# =========================

RTL_ALT_M = 30.0             # sobe até 30m (se abaixo) antes de voltar
# RTL simples: se estiver abaixo de 30m, sobe até 30m antes de retornar.

RTL_HOME_RADIUS_M = 0.2      # raio para considerar chegou em home
# Quando chegar a 0.2m de “home”, considera que chegou (para fins de simulação).


# =========================
# ESTADO INICIAL: HOME E POSIÇÃO DO VEÍCULO
# =========================

home_lat = -23.2000000
home_lon = -45.9000000
# Coordenadas home (ponto de lançamento). Na simulação, isso é fixo.

lat = home_lat
lon = home_lon
# Posição atual começa em home.

rel_alt_m = 0.0
# Altitude relativa (m) começa em 0 (no chão).


# =========================
# ESTADO DO VEÍCULO / MODO
# =========================

armed = False
# armed: motores armados?

flying = False
# flying: está em voo? (True após takeoff aceito)

mode = 'STANDBY'
# modo “lógico” da simulação (não é MAVLink real, é uma FSM simplificada).

target_alt_m = 0.0
# altitude alvo que o controlador/RTL quer atingir.


# =========================
# MOVIMENTO NO PLANO LOCAL (NORTH/EAST) EM METROS
# =========================

north_m = 0.0
east_m = 0.0
# posição atual no referencial local N/E (home é 0,0).

target_north_m = 0.0
target_east_m = 0.0
# posição alvo para onde o UAV deve ir.

move_active = False
# indica se há um movimento em andamento (indo para um alvo).


# =========================
# LIMITES DE DINÂMICA (VELOCIDADE SIMULADA)
# =========================

CLIMB_MPS = 2.0
# velocidade vertical simulada (2 m/s).

MOVE_MPS = 5.0
# velocidade horizontal simulada (5 m/s).


# =========================
# LINK / FAILSAFE BASEADO SOMENTE NO HEARTBEAT DO GCS
# =========================

last_gcs_hb = time.time()
# timestamp do último heartbeat válido do GCS.

link_up = True
# link_up: se o UAV considera o link ok.

failsafe_active = False
# indica que entrou em failsafe (por exemplo, RTL acionado por perda de link).

last_retry_log = 0.0
# controle para não logar “tentando reestabelecer” toda hora.


# =========================
# ESTADO DO RTL (FSM DO RTL)
# =========================

rtl_active = False
# rtl_active: está executando a sequência de RTL?

rtl_phase = 'IDLE'  # IDLE | CLIMB | RETURN | LAND
# rtl_phase controla qual etapa do RTL está em execução.


# =========================
# FUNÇÕES UTILITÁRIAS (LOG / MAVLINK AUX)
# =========================

def log(s):
    # log centralizado: imprime e força flush (aparece em tempo real no terminal).
    print(s, flush=True)

def send_statustext(tx, text, severity=mavutil.mavlink.MAV_SEVERITY_INFO):
    # Envia STATUSTEXT para o GCS.
    # MAVLink STATUSTEXT tem tamanho limitado; corta em 50 bytes.
    tx.mav.statustext_send(severity, text.encode('utf-8')[:50])

def send_ack(tx, command, result):
    # Envia um ACK (Command Acknowledge) para o comando MAVLink recebido.
    tx.mav.command_ack_send(command, result)


# =========================
# CONVERSÕES METRO -> GRAU (LAT/LON)
# =========================

def deg_per_meter_lat():
    # Aproximação simples: 1 grau de latitude ~ 111.320 km.
    return 1.0 / 111320.0

def deg_per_meter_lon(lat_deg):
    # Para longitude, o fator depende do cos(latitude).
    # max(0.2, cos(...)) evita divisão por número muito pequeno (estabilidade numérica).
    return 1.0 / (111320.0 * max(0.2, math.cos(math.radians(lat_deg))))


# =========================
# RTL: INÍCIO
# =========================

def start_rtl(tx):
    # Inicia RTL: muda estados globais, configura fase e alvos.
    global failsafe_active, rtl_active, rtl_phase, mode
    global move_active, target_north_m, target_east_m, target_alt_m

    failsafe_active = True
    rtl_active = True
    mode = 'RTL'
    # Marca que entrou em modo RTL (simulação).

    if not flying:
        # Se não está voando, não faz sentido executar RTL (não tem o que retornar).
        rtl_phase = 'IDLE'
        send_statustext(tx, 'RTL: vehicle not flying (idle)', mavutil.mavlink.MAV_SEVERITY_WARNING)
        log('[UAV] RTL: veículo no chão (idle).')
        return

    # Se está voando, decide se precisa subir antes de voltar:
    if rel_alt_m < RTL_ALT_M:
        # fase CLIMB: subir até RTL_ALT_M
        target_alt_m = RTL_ALT_M
        rtl_phase = 'CLIMB'
        send_statustext(tx, f'RTL: climbing to {RTL_ALT_M:.1f}m')
        log(f'[UAV] RTL: subindo até {RTL_ALT_M:.1f}m.')
    else:
        # já está alto o suficiente: pode retornar direto
        rtl_phase = 'RETURN'
        send_statustext(tx, 'RTL: returning to launch')
        log('[UAV] RTL: retornando para HOME.')

    # Em ambos os casos, define “home” como alvo (0,0 no frame local).
    move_active = True
    target_north_m = 0.0
    target_east_m  = 0.0


# =========================
# RTL: TICK (TRANSIÇÕES ENTRE FASES)
# =========================

def tick_rtl(tx):
    # Executa transições CLIMB -> RETURN -> LAND.
    # Importante: ele NÃO movimenta diretamente aqui, só muda estados.
    global rtl_active, rtl_phase, mode, move_active
    global target_alt_m

    if not rtl_active or not flying:
        # Se não está em RTL ou não está voando, não faz nada.
        return

    if rtl_phase == 'CLIMB':
        # Quando atinge altitude alvo, muda para RETURN.
        if abs(rel_alt_m - target_alt_m) < 0.2:
            rtl_phase = 'RETURN'
            send_statustext(tx, 'RTL: returning to launch')
            log('[UAV] RTL: atingiu altitude, retornando para HOME.')

    elif rtl_phase == 'RETURN':
        # Chegando em home (0,0) e com movimento concluído, muda para LAND.
        dist_home = math.hypot(north_m - 0.0, east_m - 0.0)
        if dist_home <= RTL_HOME_RADIUS_M and (not move_active):
            rtl_phase = 'LAND'
            mode = 'LAND'
            send_statustext(tx, 'RTL: reached home, landing')
            log('[UAV] RTL: chegou em HOME, iniciando pouso.')

    elif rtl_phase == 'LAND':
        # Não faz nada aqui porque o pouso é tratado no bloco padrão de LAND.
        pass


# =========================
# LINK RESTAURADO
# =========================

def exit_failsafe_link_restored(tx):
    # Chamado quando volta a receber heartbeat do GCS depois do timeout.
    global link_up, failsafe_active

    link_up = True
    # Link voltou.

    # Realista: link voltar não cancela RTL automaticamente (opcional).
    failsafe_active = False

    send_statustext(tx, 'GCS HEARTBEAT RESTORED', mavutil.mavlink.MAV_SEVERITY_INFO)
    log('[UAV] link restaurado: heartbeat do GCS voltou.')


# =========================
# CONEXÕES MAVLINK DO UAV
# =========================

rx = mavutil.mavlink_connection(f'udpin:0.0.0.0:{UAV_LISTEN_PORT}')
# rx: recebe comandos MAVLink em UDP na porta UAV_LISTEN_PORT.

tx = mavutil.mavlink_connection(f'udpout:{GCS_IP}:{GCS_LISTEN_PORT}')
# tx: envia telemetria e mensagens para o GCS no IP/porta definidos.

log(f'[UAV] ouvindo MAVLink em 0.0.0.0:{UAV_LISTEN_PORT} | enviando para {GCS_IP}:{GCS_LISTEN_PORT}')
# Log de inicialização.


# =========================
# ESPERA UMA PRIMEIRA MENSAGEM PARA CONSIDERAR LINK ATIVO
# =========================

first = rx.recv_match(blocking=True, timeout=30)
# Espera (até 30s) a primeira mensagem chegar.
# Isso é um “handshake” simplificado: se não chega nada, aborta.

if first is None:
    log('[UAV] nenhuma mensagem recebida em 30s. Abortando.')
    raise SystemExit(1)

log(f'[UAV] link ativo (primeira msg): {first.get_type()}')
# Loga que recebeu algo (ex: HEARTBEAT, COMMAND_LONG etc).


# =========================
# TIMERS PARA TX E SIMULAÇÃO
# =========================

last_hb_tx = 0.0
# controla quando foi enviado o último heartbeat do UAV.

last_pos_tx = 0.0
# controla quando foi enviada a última posição.

last_sim = time.time()
# usado para calcular dt (delta de tempo) e integrar dinâmica de voo.


# =========================
# LOOP PRINCIPAL
# =========================

try:
    while True:
        now = time.time()

        dt = now - last_sim
        # dt: tempo desde a última iteração.
        # Isso permite simulação “continua” independente do FPS do loop.

        last_sim = now

        # ---------------------------------------------------------
        # 1) DETECÇÃO DE LINK (SOMENTE HEARTBEAT DO GCS)
        # ---------------------------------------------------------

        if link_up and (now - last_gcs_hb) > GCS_HB_TIMEOUT_S:
            # Se o link era considerado up e passou 60s sem HB do GCS:
            link_up = False
            log('[UAV] FAILSAFE: heartbeat do GCS perdido (>=60s). Entrando em RTL.')
            send_statustext(tx, 'GCS HEARTBEAT LOST - RTL', mavutil.mavlink.MAV_SEVERITY_CRITICAL)

            start_rtl(tx)
            # Ativa RTL (em geral CLIMB/RETURN/LAND conforme altitude/voo).

            last_retry_log = 0.0
            # força log imediato no bloco de retry

        if not link_up:
            # Enquanto o link estiver down, loga tentativa a cada 30s.
            if (now - last_retry_log) >= RETRY_LOG_PERIOD_S:
                last_retry_log = now
                log('[UAV] tentando reestabelecer link (aguardando heartbeat do GCS)...')
                send_statustext(tx, 'Attempting link restore...', mavutil.mavlink.MAV_SEVERITY_WARNING)

        # ---------------------------------------------------------
        # 2) DINÂMICA DE VOO (SIMULA ALTURA E MOVIMENTO)
        # ---------------------------------------------------------

        if flying:
            # --------- ALTITUDE ---------
            if abs(rel_alt_m - target_alt_m) < 0.05:
                # Se já está muito perto do alvo, “encaixa” no valor exato.
                rel_alt_m = target_alt_m
            else:
                # Senão, sobe ou desce no máximo CLIMB_MPS * dt.
                step = CLIMB_MPS * dt
                if rel_alt_m < target_alt_m:
                    rel_alt_m = min(target_alt_m, rel_alt_m + step)
                else:
                    rel_alt_m = max(target_alt_m, rel_alt_m - step)

            # --------- MOVIMENTO HORIZONTAL ---------
            if move_active:
                # Diferença entre alvo e posição atual:
                dn = target_north_m - north_m
                de = target_east_m - east_m

                dist = math.hypot(dn, de)
                # Distância Euclidiana no plano N/E.

                if dist < 0.2:
                    # Se muito perto, considera que chegou.
                    north_m = target_north_m
                    east_m = target_east_m
                    move_active = False
                    send_statustext(tx, 'Reached target position')
                else:
                    # Anda em direção ao alvo com velocidade MOVE_MPS.
                    step = min(MOVE_MPS * dt, dist)
                    north_m += (dn / dist) * step
                    east_m  += (de / dist) * step

            # Atualiza lat/lon a partir do deslocamento local.
            lat = home_lat + north_m * deg_per_meter_lat()
            lon = home_lon + east_m  * deg_per_meter_lon(home_lat)

        # ---------------------------------------------------------
        # 2.5) TICK DO RTL (TRANSIÇÕES ENTRE FASES)
        # ---------------------------------------------------------
        tick_rtl(tx)

        # ---------------------------------------------------------
        # 2.6) MODO LAND (POUSO SIMULADO)
        # ---------------------------------------------------------

        if mode == 'LAND' and flying:
            # Em LAND, o alvo de altitude vai para 0.
            target_alt_m = 0.0

            if rel_alt_m <= 0.05:
                # Quando “encosta no chão”, finaliza voo.
                rel_alt_m = 0.0
                flying = False
                move_active = False

                # Reseta RTL
                rtl_active = False
                rtl_phase = 'IDLE'

                mode = 'STANDBY'
                send_statustext(tx, 'Landed')
                log('[UAV] pousou.')

        # ---------------------------------------------------------
        # 3) TX: HEARTBEAT DO UAV + TELEMETRIA
        # ---------------------------------------------------------

        if now - last_hb_tx >= HB_PERIOD:
            # Envia heartbeat MAVLink do UAV.
            tx.mav.heartbeat_send(
                mavutil.mavlink.MAV_TYPE_QUADROTOR,          # tipo do veículo
                mavutil.mavlink.MAV_AUTOPILOT_ARDUPILOTMEGA, # autopiloto simulado
                0, 0, 0
            )
            last_hb_tx = now
            log('[UAV] heartbeat enviado')

        if now - last_pos_tx >= POS_PERIOD:
            # Envia GLOBAL_POSITION_INT.
            # MAVLink usa inteiros escalados para lat/lon e altitudes.
            lat_i = int(lat * 1e7)
            lon_i = int(lon * 1e7)

            rel_alt_mm = int(rel_alt_m * 1000)
            # mm

            alt_mm = rel_alt_mm
            # altitude absoluta = relativa (simulação simples)

            tx.mav.global_position_int_send(
                int(now * 1000) & 0xFFFFFFFF,  # time_boot_ms aproximado (ms) em 32 bits
                lat_i, lon_i,
                alt_mm, rel_alt_mm,
                0, 0, 0,  # vx, vy, vz (não simulados)
                0         # hdg (não simulado)
            )
            last_pos_tx = now

        # ---------------------------------------------------------
        # 4) RX: RECEBE COMANDOS DO GCS
        # ---------------------------------------------------------

        m = rx.recv_match(blocking=False)
        # blocking=False: não trava o loop esperando mensagem.
        # Se não tiver nada, m = None.

        if m:
            t = m.get_type()
            d = m.to_dict()

            # -----------------------------------------------------
            # 4.1) Atualiza link APENAS se for HEARTBEAT do GCS
            # -----------------------------------------------------
            if t == 'HEARTBEAT':
                # Tenta descobrir quem enviou:
                src_sys = getattr(m, 'get_srcSystem', lambda: None)()
                hb_type = int(d.get('type', -1))

                # Considera como GCS se:
                # - o tipo for MAV_TYPE_GCS
                # OU
                # - source_system == 255 (comum para GCS)
                if hb_type == mavutil.mavlink.MAV_TYPE_GCS or src_sys == 255:
                    last_gcs_hb = now
                    if not link_up:
                        exit_failsafe_link_restored(tx)

            # Loga alguns tipos relevantes para debug
            if t in ('COMMAND_LONG', 'SET_MODE', 'SET_POSITION_TARGET_LOCAL_NED'):
                log(f'[UAV] recebido: {t} | conteúdo: {d}')

            # -----------------------------------------------------
            # 4.2) Se link está DOWN, ignora comandos
            # -----------------------------------------------------
            # Ideia: se não tem heartbeat do GCS, assume que não há controle legítimo.
            if not link_up:
                time.sleep(0.02)
                continue

            # -----------------------------------------------------
            # 4.3) Processa comandos quando link está OK
            # -----------------------------------------------------

            if t == 'SET_MODE':
                cm = int(d.get('custom_mode', 0))

                # Mapeamento simplificado de modos (como no GCS):
                if cm == 4:
                    mode = 'GUIDED'
                    # Ao entrar em GUIDED, cancela RTL.
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

                # -----------------------------
                # ARM/DISARM
                # -----------------------------
                if cmd == mavutil.mavlink.MAV_CMD_COMPONENT_ARM_DISARM:
                    if p1 >= 1.0:
                        # ARM
                        if armed:
                            send_ack(tx, cmd, mavutil.mavlink.MAV_RESULT_ACCEPTED)
                            send_statustext(tx, 'Already armed')
                        else:
                            armed = True
                            send_ack(tx, cmd, mavutil.mavlink.MAV_RESULT_ACCEPTED)
                            send_statustext(tx, 'Motors armed')
                    else:
                        # DISARM
                        if flying and rel_alt_m > 0.5:
                            # Não deixa desarmar no ar (segurança).
                            send_ack(tx, cmd, mavutil.mavlink.MAV_RESULT_DENIED)
                            send_statustext(tx, 'Disarm denied: airborne', mavutil.mavlink.MAV_SEVERITY_WARNING)
                        else:
                            armed = False
                            send_ack(tx, cmd, mavutil.mavlink.MAV_RESULT_ACCEPTED)
                            send_statustext(tx, 'Motors disarmed')

                # -----------------------------
                # TAKEOFF
                # -----------------------------
                elif cmd == mavutil.mavlink.MAV_CMD_NAV_TAKEOFF:
                    desired = float(p7)
                    # altitude desejada vem em param7.

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
                        # Takeoff aceito: começa a voar e define alvo de altitude.
                        flying = True
                        target_alt_m = desired
                        send_ack(tx, cmd, mavutil.mavlink.MAV_RESULT_ACCEPTED)
                        send_statustext(tx, f'Taking off to {desired:.1f}m')

                # -----------------------------
                # LAND
                # -----------------------------
                elif cmd == mavutil.mavlink.MAV_CMD_NAV_LAND:
                    if not flying:
                        send_ack(tx, cmd, mavutil.mavlink.MAV_RESULT_DENIED)
                        send_statustext(tx, 'Land denied: not flying', mavutil.mavlink.MAV_SEVERITY_WARNING)
                    else:
                        mode = 'LAND'
                        send_ack(tx, cmd, mavutil.mavlink.MAV_RESULT_ACCEPTED)
                        send_statustext(tx, 'Landing...')

                else:
                    # Comando não suportado nesta simulação.
                    send_ack(tx, cmd, mavutil.mavlink.MAV_RESULT_UNSUPPORTED)

            # -----------------------------------------------------
            # 4.4) SET_POSITION_TARGET_LOCAL_NED (MOVE)
            # -----------------------------------------------------
            elif t == 'SET_POSITION_TARGET_LOCAL_NED':
                if not flying:
                    send_statustext(tx, 'Move denied: not flying', mavutil.mavlink.MAV_SEVERITY_WARNING)

                elif mode != 'GUIDED':
                    send_statustext(tx, 'Move denied: not GUIDED', mavutil.mavlink.MAV_SEVERITY_WARNING)

                else:
                    # Pega setpoint local NED:
                    x = float(d.get('x', 0.0))  # North
                    y = float(d.get('y', 0.0))  # East
                    z = float(d.get('z', 0.0))  # Down (negativo = subir)

                    target_north_m = x
                    target_east_m = y
                    move_active = True

                    desired_alt = max(0.0, -z)
                    # Em NED, z é "down". Se z é negativo, quer subir.
                    if desired_alt > 0.0:
                        target_alt_m = desired_alt

                    send_statustext(tx, f'Moving to N={x:.1f} E={y:.1f} alt~{target_alt_m:.1f}m')

        # Pequeno sleep para evitar 100% CPU.
        time.sleep(0.02)

except KeyboardInterrupt:
    # Se apertar Ctrl+C, encerra de forma limpa.
    log('\\n[UAV] encerrado.')

