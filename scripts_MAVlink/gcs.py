# =========================
# IMPORTS
# =========================

import time
# time: usado para timestamps (timeouts), sleep e medir tempo desde o último pacote recebido.

import threading
# threading: cria threads (fluxos paralelos) para:
# - receber telemetria (rx_worker)
# - enviar heartbeats periódicos (hb_worker)

from collections import deque
# deque: fila eficiente para armazenar eventos recebidos (ACK e STATUSTEXT) e imprimir em lote.

import os
os.environ['MAVLINK20'] = '1' 
# Utilizado para forçar a utilização do MAVlink 2.0 - comentar as 2 linhas cima caso queira usar o 1.0.

from pymavlink import mavutil
# pymavlink: biblioteca que implementa MAVLink.
# mavutil oferece funções utilitárias e criação de conexões MAVLink via UDP.


# =========================
# CONFIGURAÇÃO DE REDE (ENDEREÇOS/PORTAS)
# =========================

DRONE_IP = '<IP_UAV>'
# IP do UAV (drone). No testbed, isso costuma ser o IP dentro do túnel (ex: uesimtun0).

DRONE_LISTEN_PORT = 14550
# Porta em que o UAV (drone) está "ouvindo" para receber comandos MAVLink.

CTRL_LISTEN_PORT  = 14551
# Porta em que o GCS vai "ouvir" as mensagens que chegam do drone (telemetria).
# O drone manda telemetria para o IP do GCS nessa porta.


# =========================
# IDENTIDADE MAVLINK DO GCS
# =========================

SYS_ID  = 255
# source_system do GCS. 255 é comum como "GCS".

COMP_ID = 190
# source_component do GCS (id do componente dentro do sistema).
# Não é tão crítico, mas ajuda a diferenciar quem enviou.


# =========================
# PARÂMETROS DE ROBUSTEZ (TIMEOUT / HEARTBEAT)
# =========================

LINK_TIMEOUT_S = 30.0  # sem telemetria do UAV por 30s => desconectado
# Se o GCS ficar 30 segundos sem receber NENHUM pacote útil do drone (telemetria),
# ele considera que o link caiu.

HB_PERIOD_S = 1.0      # heartbeat do GCS 1Hz (independente do input)
# Heartbeat do GCS vai ser enviado a cada 1 segundo por uma thread separada.
# Isso garante que mesmo sem digitar nada no terminal, o heartbeat continua.


# =========================
# CONEXÕES MAVLINK (RX e TX)
# =========================

rx = mavutil.mavlink_connection(
    f'udpin:0.0.0.0:{CTRL_LISTEN_PORT}',
    source_system=SYS_ID,
    source_component=COMP_ID
)
# rx: conexão MAVLink para RECEBER mensagens.
# "udpin:0.0.0.0:14551" significa:
# - abre UDP server local
# - escuta em todas as interfaces (0.0.0.0)
# - porta CTRL_LISTEN_PORT

tx = mavutil.mavlink_connection(
    f'udpout:{DRONE_IP}:{DRONE_LISTEN_PORT}',
    source_system=SYS_ID,
    source_component=COMP_ID
)
# tx: conexão MAVLink para ENVIAR mensagens.
# "udpout:IP:PORT" significa:
# - envia pacotes UDP para o drone no IP/porta especificados.


print(f'[GCS] enviando para {DRONE_IP}:{DRONE_LISTEN_PORT}, ouvindo em {CTRL_LISTEN_PORT}', flush=True)
# Log inicial explicando:
# - para onde ele vai enviar comandos
# - em qual porta ele está ouvindo telemetria
# flush=True garante que imprime na hora mesmo em buffers.


# =========================
# ESTADO COMPARTILHADO (COMPARTILHADO ENTRE THREADS)
# =========================

lock = threading.Lock()
# lock: protege variáveis compartilhadas entre threads (rx_worker, hb_worker e loop principal).
# Evita "corrida" (race condition): um thread lendo enquanto outro escreve.

last_pos = None
# Guarda o último pacote de posição recebido (GLOBAL_POSITION_INT).

last_ack = None
# Guarda o último ACK de comando recebido (COMMAND_ACK).

last_statustext = None
# Guarda a última mensagem de status recebida (STATUSTEXT).

last_rx_any = time.time()
# Momento (timestamp) do último pacote recebido (qualquer um tratado).
# Serve para medir tempo sem telemetria e ativar timeout do link.


# fila para imprimir “em lote” antes do prompt (terminal limpo)
rx_events = deque(maxlen=200)
# rx_events: fila circular (tamanho máximo 200) para armazenar eventos recebidos.
# A ideia: não ficar printando no meio do input(), e sim imprimir antes do prompt.


# =========================
# ESTADO DO LINK / EXECUÇÃO
# =========================

link_up = True
# link_up indica se o link ainda é considerado "em pé".

stopped = False
# stopped indica se a transmissão (TX) foi parada devido a perda de link.
# stopped=True quando considera o link perdido (timeout).

running = True
# running controla o loop das threads rx_worker e hb_worker.
# Quando running = False, as threads param e o programa termina.


# =========================
# FUNÇÕES AUXILIARES (HEARTBEAT / FORMATAÇÃO / HELP)
# =========================

def hb_send_once():
    # Envia um heartbeat MAVLink do tipo GCS.
    # Heartbeat serve para "manter vivo" e sinalizar que o GCS existe na rede.
    tx.mav.heartbeat_send(
        mavutil.mavlink.MAV_TYPE_GCS,          # tipo: estação de controle (GCS)
        mavutil.mavlink.MAV_AUTOPILOT_INVALID, # autopilot inválido, pois não é autopiloto
        0, 0, 0                                # base_mode, custom_mode, system_status (não usados aqui)
    )

def pretty_pos(p):
    # Converte campos da mensagem GLOBAL_POSITION_INT para unidades humanas.
    # lat/lon vêm em graus * 1e7
    # alt e relative_alt vêm em milímetros
    lat = p['lat'] / 1e7
    lon = p['lon'] / 1e7
    alt_m = p['alt'] / 1000.0
    rel_alt_m = p['relative_alt'] / 1000.0
    return lat, lon, alt_m, rel_alt_m

def help_print():
    # Imprime a lista de comandos suportados pelo terminal interativo.
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


# =========================
# CONTROLE DE LINK / BLOQUEIO DE COMANDOS
# =========================

def warn_lost():
    # Mensagem padrão para avisar que a conexão foi considerada perdida.
    print('[GCS] CONEXÃO PERDIDA (>=30s sem telemetria do UAV).', flush=True)

def ensure_link_or_warn():
    # Verifica se pode enviar comandos.
    # Só permite TX se:
    # - não está stopped
    # - link_up ainda está True
    with lock:
        ok = (not stopped) and link_up

    if not ok:
        # Se não estiver OK, avisa e bloqueia envio.
        warn_lost()
        print('[GCS] Comando NÃO enviado.', flush=True)
        return False

    return True


# =========================
# FUNÇÕES DE ENVIO DE COMANDOS MAVLINK
# =========================

def send_arm(value: int):
    # Arma (value=1) ou desarma (value=0) o drone via MAV_CMD_COMPONENT_ARM_DISARM.
    if not ensure_link_or_warn():
        return

    tx.mav.command_long_send(
        1, 0,  # target_system=1, target_component=0 (0 às vezes significa "todos" ou desconhecido)
        mavutil.mavlink.MAV_CMD_COMPONENT_ARM_DISARM,  # comando MAVLink
        0,      # confirmation
        float(value), 0, 0, 0, 0, 0, 0  # param1=value, demais params zerados
    )

    print(f'[GCS] ARM_DISARM enviado param1={value}', flush=True)

def send_takeoff(alt_m: float):
    # Envia comando de decolagem MAV_CMD_NAV_TAKEOFF.
    # O MAVLink usa param7 como altitude alvo (dependendo do autopiloto/modo).
    if not ensure_link_or_warn():
        return

    tx.mav.command_long_send(
        1, 0,
        mavutil.mavlink.MAV_CMD_NAV_TAKEOFF,
        0,
        0, 0, 0, 0, 0, 0,
        float(alt_m)  # param7: altitude
    )

    print(f'[GCS] TAKEOFF enviado alt={alt_m}m', flush=True)

def send_land():
    # Envia comando de pouso MAV_CMD_NAV_LAND.
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
    # Altera modo de voo usando set_mode_send.
    # Para ArduPilot, custom_mode costuma mapear modos:
    # GUIDED, LOITER, LAND etc (valores variam conforme firmware).
    if not ensure_link_or_warn():
        return

    tx.mav.set_mode_send(
        1,  # target_system
        mavutil.mavlink.MAV_MODE_FLAG_CUSTOM_MODE_ENABLED,  # indica que custom_mode é válido
        custom_mode
    )

    print(f'[GCS] MODE enviado {name.lower()} (custom_mode={custom_mode})', flush=True)

def send_setpos(north_m: float, east_m: float, alt_m: float):
    # Envia setpoint de posição LOCAL_NED:
    # - north_m: deslocamento em metros ao Norte
    # - east_m: deslocamento em metros ao Leste
    # - alt_m: altitude em metros (convertida para "Down" negativo no frame NED)
    if not ensure_link_or_warn():
        return

    z_down = -float(alt_m)
    # No frame LOCAL_NED:
    # - eixo Z é "Down" (para baixo positivo).
    # Então para subir alt_m, z_down negativo.

    tx.mav.set_position_target_local_ned_send(
        int(time.time() * 1000) & 0xFFFFFFFF,  # time_boot_ms (aqui se usa timestamp atual em ms "mascarado" em 32 bits)
        1, 0,                                  # target_system=1, target_component=0
        mavutil.mavlink.MAV_FRAME_LOCAL_NED,    # frame de referência
        0b0000111111000111,                    # type_mask: bits definem quais campos são ignorados
        float(north_m), float(east_m), float(z_down),  # posição
        0, 0, 0,                                # velocidades (ignoradas pelo mask)
        0, 0, 0,                                # acelerações (ignoradas)
        0, 0                                    # yaw, yaw_rate (ignoradas)
    )

    print(f'[GCS] SETPOS enviado N={north_m} E={east_m} ALT={alt_m}', flush=True)


# =========================
# THREAD: RECEPÇÃO DE TELEMETRIA (RX)
# =========================

def rx_worker():
    # Thread que fica bloqueada esperando mensagens (rx.recv_match).
    # Quando chega:
    # - atualiza "last_rx_any"
    # - armazena última posição/ack/statustext
    # - põe alguns eventos na fila rx_events
    global last_pos, last_ack, last_statustext, last_rx_any, running

    while running:
        try:
            # blocking=True: espera mensagem até timeout.
            # timeout=0.5: se não vier nada em 0.5s, retorna None.
            m = rx.recv_match(blocking=True, timeout=0.5)
        except Exception:
            # Se der erro na leitura, ignora e continua.
            continue

        if not m:
            # Nenhuma mensagem no período de timeout.
            continue

        t = m.get_type()
        # Tipo da mensagem MAVLink em string, ex: 'GLOBAL_POSITION_INT'.

        d = m.to_dict()
        # Converte mensagem em dicionário (mais fácil de armazenar/imprimir).

        with lock:
            # Atualiza timestamp do último recebimento.
            last_rx_any = time.time()

            if t == 'GLOBAL_POSITION_INT':
                # Guarda posição mais recente.
                last_pos = d

            elif t == 'COMMAND_ACK':
                # Guarda último ACK e registra na fila de eventos.
                last_ack = d
                rx_events.append(('COMMAND_ACK', d))

            elif t == 'STATUSTEXT':
                # Guarda último STATUSTEXT e registra na fila de eventos.
                last_statustext = d
                rx_events.append(('STATUSTEXT', d))

            # HEARTBEAT ignorado para não "poluir" com prints.


# =========================
# THREAD: ENVIO PERIÓDICO DE HEARTBEAT (TX)
# =========================

def hb_worker():
    # Thread que envia heartbeat em intervalos fixos.
    # Isso mantém o drone "vendo" o GCS como ativo.
    global running

    while running:
        # heartbeat continua existindo mesmo se não digitar nada
        with lock:
            ok = (not stopped) and link_up
            # Só envia heartbeat se o link não foi marcado como perdido.

        if ok:
            try:
                hb_send_once()
            except Exception:
                # Se falhar ao enviar, ignora.
                pass

        time.sleep(HB_PERIOD_S)
        # Aguarda o período configurado (1Hz).


# =========================
# CRIAÇÃO/INÍCIO DAS THREADS
# =========================

t_rx = threading.Thread(target=rx_worker, daemon=True)
# Thread daemon: quando o programa principal acabar, ela é finalizada automaticamente.

t_hb = threading.Thread(target=hb_worker, daemon=True)

t_rx.start()
t_hb.start()
# Inicia ambas as threads.


# =========================
# HEARTBEATS INICIAIS (COSMÉTICO)
# =========================

for i in range(3):
    hb_send_once()
    print(f'[GCS] heartbeat inicial {i+1}', flush=True)
    time.sleep(0.5)
# 3 heartbeats no começo apenas para sinalizar "vida" no terminal.
# Não é obrigatório (o hb_worker já faz isso), mas ajuda visualmente.


print('\n[GCS] Terminal interativo pronto (digite help)\n', flush=True)
# Indica que o GCS está pronto para receber comandos digitados.


# =========================
# IMPRESSÃO “EM LOTE” DOS EVENTOS RX
# =========================

def flush_rx_events():
    # Imprime eventos acumulados ANTES do prompt.
    # Isso evita que mensagens "cortem" o input() no meio e baguncem o terminal.
    printed = 0

    while True:
        with lock:
            if not rx_events:
                # Se não há eventos, para.
                break

            typ, payload = rx_events.popleft()
            # Remove o evento mais antigo da fila.

        print(f"\n[GCS] rx: {typ} | {payload}", flush=True)
        # Imprime o evento.

        printed += 1

        if printed >= 30:
            # Limite por iteração para não despejar infinito se vier muita coisa.
            break


# =========================
# LOOP PRINCIPAL (TERMINAL INTERATIVO)
# =========================

try:
    while True:
        # ---------------------------------------------------------
        # 1) Verifica timeout do link (independente de input)
        # ---------------------------------------------------------
        now = time.time()

        with lock:
            # Se o link estava up e passou mais do que LINK_TIMEOUT_S sem receber nada:
            if link_up and (now - last_rx_any) > LINK_TIMEOUT_S:
                link_up = False
                stopped = True
                # Marca o link como perdido e para transmissões.
                # Observação: aqui NÃO implementa reconexão automática.

        # ---------------------------------------------------------
        # 2) Detecta queda para imprimir aviso
        # ---------------------------------------------------------
        with lock:
            became_down = stopped and (not link_up)

        if became_down:
            # Aqui imprime um aviso "de queda".
            print('\n[GCS] CONEXÃO PERDIDA (>=30s sem telemetria). Parando TX (sem reconectar).', flush=True)

        # ---------------------------------------------------------
        # 3) Imprime eventos RX pendentes antes do prompt
        # ---------------------------------------------------------
        flush_rx_events()

        # ---------------------------------------------------------
        # 4) Lê comando do usuário
        # ---------------------------------------------------------
        cmdline = input('[GCS] Comando> ').strip()

        if not cmdline:
            # Se o usuário apertar Enter vazio, volta pro início.
            continue

        parts = cmdline.split()
        # Separa comando em tokens (ex: "takeoff 10" -> ["takeoff","10"])

        cmd = parts[0].lower()
        # Comando principal em lowercase.

        # ---------------------------------------------------------
        # COMANDOS: HELP
        # ---------------------------------------------------------
        if cmd in ('help', '?'):
            help_print()
            continue

        # ---------------------------------------------------------
        # COMANDOS: SAIR
        # ---------------------------------------------------------
        if cmd in ('quit', 'exit'):
            print('[GCS] saindo...', flush=True)
            break

        # ---------------------------------------------------------
        # COMANDOS: STATUS
        # ---------------------------------------------------------
        if cmd == 'status':
            with lock:
                st = last_statustext
                ak = last_ack
                lp = last_pos
                down = stopped or (not link_up)
                # down indica se está "considerado desconectado".

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

        # ---------------------------------------------------------
        # COMANDOS: ARM / DISARM
        # ---------------------------------------------------------
        if cmd == 'arm':
            send_arm(1)
            continue

        if cmd == 'disarm':
            send_arm(0)
            continue

        # ---------------------------------------------------------
        # COMANDOS: MODE
        # ---------------------------------------------------------
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

        # ---------------------------------------------------------
        # COMANDOS: TAKEOFF
        # ---------------------------------------------------------
        if cmd == 'takeoff':
            if len(parts) != 2:
                print('[GCS] uso: takeoff <alt_m>', flush=True)
                continue

            raw = parts[1].lower().replace('m', '')
            # Aceita "10" ou "10m" (remove o 'm').

            try:
                send_takeoff(float(raw))
            except ValueError:
                print('[GCS] uso: takeoff <alt_m>  (ex: takeoff 10 | takeoff 10m)', flush=True)

            continue

        # ---------------------------------------------------------
        # COMANDOS: LAND
        # ---------------------------------------------------------
        if cmd == 'land':
            send_land()
            continue

        # ---------------------------------------------------------
        # COMANDOS: SETPOS
        # ---------------------------------------------------------
        if cmd == 'setpos':
            if len(parts) != 4:
                print('[GCS] uso: setpos <north_m> <east_m> <alt_m>', flush=True)
                continue

            try:
                send_setpos(float(parts[1]), float(parts[2]), float(parts[3]))
            except ValueError:
                print('[GCS] uso: setpos <north_m> <east_m> <alt_m>', flush=True)

            continue

        # ---------------------------------------------------------
        # COMANDOS: POS (última posição)
        # ---------------------------------------------------------
        if cmd == 'pos':
            with lock:
                lp = last_pos

            if not lp:
                print('[GCS] ainda não recebi GLOBAL_POSITION_INT', flush=True)
            else:
                lat, lon, alt_m, rel_alt_m = pretty_pos(lp)
                print(f'[GCS] POS lat={lat:.7f} lon={lon:.7f} alt={alt_m:.1f}m rel_alt={rel_alt_m:.1f}m', flush=True)

            continue

        # ---------------------------------------------------------
        # COMANDOS: ALT (última altitude)
        # ---------------------------------------------------------
        if cmd == 'alt':
            with lock:
                lp = last_pos

            if not lp:
                print('[GCS] ainda não recebi GLOBAL_POSITION_INT', flush=True)
            else:
                lat, lon, alt_m, rel_alt_m = pretty_pos(lp)
                print(f'[GCS] ALT rel_alt={rel_alt_m:.1f}m (alt={alt_m:.1f}m)', flush=True)

            continue

        # ---------------------------------------------------------
        # COMANDO DESCONHECIDO
        # ---------------------------------------------------------
        print('[GCS] comando desconhecido. digite: help', flush=True)

finally:
    # Esse bloco SEMPRE roda, mesmo se der Ctrl+C ou erro.
    running = False
    # Sinaliza para threads pararem.

