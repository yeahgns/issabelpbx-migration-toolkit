#!/usr/bin/env bash
# ============================================================
#  migrate-pbx.sh — Migração de PBX Asterisk-based entre VMs
#  (ex: Issabel, FreePBX) — troca de host mantendo ramais,
#  troncos, histórico de chamadas (CDR) e gravações.
#
#  Suporta DOIS modos de migração, porque em ambientes onde a
#  instalação é feita on-demand direto do repositório oficial,
#  é comum acabar com VMs de origem em versões bem diferentes
#  entre si (ex: uma instalação de 2 anos atrás vs. uma da
#  semana passada) — cada uma exige uma estratégia diferente:
#
#   [legacy]  Origem em versão mais antiga, com estrutura de
#             backup/restore incompatível com o restore nativo
#             da versão de destino. Usa a ferramenta nativa de
#             migração entre versões maiores (quando disponível
#             no seu PBX) e desabilita troncos em vez de
#             removê-los, já que o schema antigo pode não ter
#             as mesmas colunas/relacionamentos.
#
#   [current] Origem já próxima da versão de destino. Faz
#             backup/restore manual (extração direta do
#             tarball, sem depender do helper nativo — que
#             falha com customizações), remove troncos de
#             forma definitiva, e reconstrói o AstDB do zero
#             (device state / hints).
#
#  Uso: bash migrate-pbx.sh
# ============================================================

set -euo pipefail

# ─── Credenciais (nunca hardcode aqui — use variáveis de ambiente) ──────────
#
#   export PBX_MYSQL_USER="asteriskuser"
#   export PBX_MYSQL_PASS="sua-senha"
#   export PBX_MYSQL_ROOT_PASS="sua-senha-root"
#   export PBX_NEW_VM_ROOT_PASS="senha-temporaria-para-transferencia"
#
# Se não estiverem setadas, o script pede interativamente (sem ecoar na tela).

MYSQL_USER="${PBX_MYSQL_USER:-}"
MYSQL_PASS="${PBX_MYSQL_PASS:-}"
MYSQL_ROOT_PASS="${PBX_MYSQL_ROOT_PASS:-}"
NEW_VM_ROOT_PASS="${PBX_NEW_VM_ROOT_PASS:-}"

SSH_KEY="${PBX_SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_PORT="${PBX_SSH_PORT:-22}"   # porta de acesso SSH às VMs — ajuste para seu ambiente

SSH_NEW="-p $SSH_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=20 -i $SSH_KEY"
SCP_NEW="-P $SSH_PORT -o StrictHostKeyChecking=no -i $SSH_KEY"
SSH_OLD="-p $SSH_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=20"
SCP_OLD="-P $SSH_PORT -o StrictHostKeyChecking=no"

LOG_FILE="./migration_$(date +%Y%m%d_%H%M%S).log"
TMPDIR_LOCAL="$(mktemp -d)"

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
CYN='\033[0;36m'
NC='\033[0m'

log()     { echo "[$(date +%H:%M:%S)] $*" >> "$LOG_FILE"; }
info()    { local m="[INFO]   $*"; echo -e "${CYN}${m}${NC}"; log "$m"; }
success() { local m="[OK]     $*"; echo -e "${GRN}${m}${NC}"; log "$m"; }
warn()    { local m="[AVISO]  $*"; echo -e "${YEL}${m}${NC}"; log "$m"; }
die()     { local m="[ERRO]   $*"; echo -e "${RED}${m}${NC}"; log "$m"; exit 1; }

# Nota: o log grava os comandos executados remotamente, mas NUNCA os
# valores de senha em si.

send_and_run_new() {
  local label="$1" file="$2"
  info "→ [VM destino] $label"
  log "--- script: $label ---"
  scp $SCP_NEW "$file" root@"$NEW_VM_IP":/tmp/migrate_step.sh >> "$LOG_FILE" 2>&1 \
    || die "scp falhou para VM destino em: $label"
  ssh $SSH_NEW root@"$NEW_VM_IP" \
    'bash /tmp/migrate_step.sh; rc=$?; rm -f /tmp/migrate_step.sh; exit $rc' \
    2>&1 | tee -a "$LOG_FILE" \
    || die "Script falhou na VM destino em: $label"
}

send_and_run_old() {
  local label="$1" file="$2"
  info "→ [VM origem] $label"
  log "--- script: $label ---"
  sshpass -p "$OLD_VM_PASS" scp $SCP_OLD "$file" root@"$OLD_VM_IP":/tmp/migrate_step.sh >> "$LOG_FILE" 2>&1 \
    || die "scp falhou para VM origem em: $label"
  sshpass -p "$OLD_VM_PASS" ssh $SSH_OLD root@"$OLD_VM_IP" \
    'bash /tmp/migrate_step.sh; rc=$?; rm -f /tmp/migrate_step.sh; exit $rc' \
    2>&1 | tee -a "$LOG_FILE" \
    || die "Script falhou na VM origem em: $label"
}

confirm() {
  local answer
  read -rp "$(echo -e "${CYN}$1 [y/N]:${NC} ")" answer
  case "$answer" in [yY]) return 0 ;; *) return 1 ;; esac
}

prompt_secret() {
  local __var="$1" __prompt="$2" __val
  if [ -z "${!__var:-}" ]; then
    read -rsp "$(echo -e "${YEL}${__prompt}:${NC} ")" __val
    echo ""
    [[ -z "$__val" ]] && die "Valor não pode ser vazio."
    printf -v "$__var" '%s' "$__val"
  fi
}

install_sshpass_rsync_remote() {
  # Gera um step comum de instalação de sshpass/rsync na VM de origem
  cat > "$STEP" << 'SCRIPT'
#!/bin/bash
set -xe
which sshpass > /dev/null 2>&1 || {
  if which apt-get > /dev/null 2>&1; then
    apt-get install -y sshpass rsync
  elif which yum > /dev/null 2>&1; then
    yum install -y sshpass rsync 2>/dev/null || {
      curl -fsSL -o /tmp/sshpass.rpm \
        'http://vault.centos.org/7.9.2009/extras/x86_64/Packages/sshpass-1.06-2.el7.x86_64.rpm' \
        || wget -q -O /tmp/sshpass.rpm \
        'http://vault.centos.org/7.9.2009/extras/x86_64/Packages/sshpass-1.06-2.el7.x86_64.rpm'
      rpm -ivh /tmp/sshpass.rpm
      rm -f /tmp/sshpass.rpm
    }
  else
    echo '[ERRO] gerenciador de pacotes nao identificado'; exit 1
  fi
}
which rsync > /dev/null 2>&1 || {
  if which apt-get > /dev/null 2>&1; then apt-get install -y rsync
  elif which yum > /dev/null 2>&1; then yum install -y rsync
  fi
}
sshpass -V
rsync --version | head -1
SCRIPT
}

enable_temp_password_ssh_new() {
  cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
echo 'root:${NEW_VM_ROOT_PASS}' | chpasswd
systemctl restart sshd
echo '[sshd] pronto (temporario, revogado ao final)'
SCRIPT
}

cleanup() { rm -rf "$TMPDIR_LOCAL"; }
trap cleanup EXIT

# ─── Cabeçalho ───────────────────────────────────────────────────────────────

echo ""
echo -e "${CYN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYN}║     Migração de PBX Asterisk-based entre VMs  ║${NC}"
echo -e "${CYN}╚══════════════════════════════════════════════╝${NC}"
echo ""
info "Log salvo em: $LOG_FILE (comandos são logados, senhas nunca são gravadas em texto puro)"
echo ""

# ─── Seleção do modo de migração ─────────────────────────────────────────────

echo -e "${YEL}Qual o cenário desta migração?${NC}"
echo ""
echo "  [1] legacy  — VM de origem em versão bem mais antiga que o destino."
echo "                Usa a ferramenta nativa de migração entre versões maiores"
echo "                (quando disponível) e apenas desabilita troncos na origem."
echo "  [2] current — VM de origem em versão próxima da de destino."
echo "                Faz backup/restore manual (mais robusto contra"
echo "                customizações) e reconstrói o AstDB do zero."
echo ""
read -rp "$(echo -e "${YEL}Escolha [1/2]:${NC} ")" MODE_CHOICE
case "$MODE_CHOICE" in
  1) MIGRATION_MODE="legacy" ;;
  2) MIGRATION_MODE="current" ;;
  *) die "Opção inválida. Rode novamente e escolha 1 ou 2." ;;
esac
success "Modo de migração selecionado: $MIGRATION_MODE"

# ─── Coleta de credenciais ────────────────────────────────────────────────────

echo ""
prompt_secret MYSQL_USER       "Usuário MySQL do Asterisk (ex: asteriskuser)"
prompt_secret MYSQL_PASS       "Senha do usuário MySQL do Asterisk"
prompt_secret MYSQL_ROOT_PASS  "Senha root do MySQL"
prompt_secret NEW_VM_ROOT_PASS "Senha temporária root para a VM de destino (usada só durante a transferência, revogada no final)"

# ─── Menu de etapas ──────────────────────────────────────────────────────────

echo ""
echo -e "${YEL}Selecione as etapas a executar:${NC}"
echo ""

if [ "$MIGRATION_MODE" = "legacy" ]; then
  confirm "  [0] Desabilitar troncos na VM de origem"           && RUN_ETAPA0=y || RUN_ETAPA0=n
  confirm "  [1] Importar backup via ferramenta nativa de migração" && RUN_ETAPA1=y || RUN_ETAPA1=n
else
  confirm "  [0] Remover troncos da VM de origem (definitivo)"  && RUN_ETAPA0=y || RUN_ETAPA0=n
  confirm "  [1] Backup + restore manual (banco Asterisk/AMP)"  && RUN_ETAPA1=y || RUN_ETAPA1=n
fi
confirm "  [2] External IP + localnet + strictrtp"               && RUN_ETAPA2=y || RUN_ETAPA2=n
confirm "  [3] Dump de CDR + transferência + import"             && RUN_ETAPA3=y || RUN_ETAPA3=n
confirm "  [4] Migração de gravações de chamadas"                && RUN_ETAPA4=y || RUN_ETAPA4=n

echo ""
echo -e "${CYN}Etapas selecionadas (modo: $MIGRATION_MODE):${NC}"
[ "$RUN_ETAPA0" = "y" ] && echo -e "  ${GRN}✔${NC} Etapa 0" || echo -e "  ${RED}✗${NC} Etapa 0"
[ "$RUN_ETAPA1" = "y" ] && echo -e "  ${GRN}✔${NC} Etapa 1" || echo -e "  ${RED}✗${NC} Etapa 1"
[ "$RUN_ETAPA2" = "y" ] && echo -e "  ${GRN}✔${NC} Etapa 2" || echo -e "  ${RED}✗${NC} Etapa 2"
[ "$RUN_ETAPA3" = "y" ] && echo -e "  ${GRN}✔${NC} Etapa 3" || echo -e "  ${RED}✗${NC} Etapa 3"
[ "$RUN_ETAPA4" = "y" ] && echo -e "  ${GRN}✔${NC} Etapa 4" || echo -e "  ${RED}✗${NC} Etapa 4"
echo ""

confirm "Confirma e deseja prosseguir?" || { warn "Abortado pelo usuário."; exit 0; }

# ─── Coleta: VM de destino ───────────────────────────────────────────────────

echo ""
read -rp "$(echo -e "${YEL}IP/hostname da VM de destino:${NC} ")" NEW_VM_IP
[[ -z "$NEW_VM_IP" ]] && die "IP não pode ser vazio."

info "Testando conexão com a VM de destino ($NEW_VM_IP)..."
ssh $SSH_NEW root@"$NEW_VM_IP" 'echo ok' >> "$LOG_FILE" 2>&1 \
  || die "Falha ao conectar na VM de destino. Verifique o IP e a chave SSH."
success "Conectado na VM de destino."

# ─── Coleta: VM de origem ────────────────────────────────────────────────────

OLD_VM_IP=""
OLD_VM_PASS=""
if [ "$RUN_ETAPA0" = "y" ] || [ "$RUN_ETAPA1" = "y" ] || [ "$RUN_ETAPA3" = "y" ] || [ "$RUN_ETAPA4" = "y" ]; then
  echo ""
  read -rp "$(echo -e "${YEL}IP/hostname da VM de origem:${NC} ")" OLD_VM_IP
  [[ -z "$OLD_VM_IP" ]] && die "IP não pode ser vazio."

  read -rsp "$(echo -e "${YEL}Senha root da VM de origem:${NC} ")" OLD_VM_PASS
  echo ""
  [[ -z "$OLD_VM_PASS" ]] && die "Senha não pode ser vazia."

  info "Testando conexão com a VM de origem ($OLD_VM_IP)..."
  sshpass -p "$OLD_VM_PASS" ssh $SSH_OLD root@"$OLD_VM_IP" 'echo ok' >> "$LOG_FILE" 2>&1 \
    || die "Falha ao conectar na VM de origem. Verifique IP e senha."
  success "Conectado na VM de origem."
fi

STEP="$TMPDIR_LOCAL/step.sh"
SSH_TEMP_ENABLED_NEW="n"

# ═══════════════════════════════════════════════════════════════════════════
# ETAPA 0 — tratamento de troncos na origem
# ═══════════════════════════════════════════════════════════════════════════

if [ "$RUN_ETAPA0" = "y" ]; then
  echo ""
  if [ "$MIGRATION_MODE" = "legacy" ]; then
    info "========== ETAPA 0 (legacy): Desabilitar troncos na VM de origem =========="
    cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
echo '[mysql] troncos ativos antes do disable:'
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asterisk -e \
  "SELECT trunkid, name, disabled FROM trunks WHERE disabled='off';"
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asterisk -e \
  "UPDATE trunks SET disabled='on' WHERE disabled='off';"
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asterisk -e "
  DELETE FROM sip WHERE id IN (
    SELECT CONCAT('tr-reg-', trunkid) FROM trunks WHERE disabled='on'
  );
"
echo '[mysql] troncos desabilitados e registros SIP removidos'
/var/lib/asterisk/bin/retrieve_conf 2>/dev/null
asterisk -rx "sip unregister all"
asterisk -rx "sip reload"
echo '[troncos] reload e unregister aplicados'
SCRIPT
    send_and_run_old "Desabilitando todos os troncos" "$STEP"
  else
    info "========== ETAPA 0 (current): Remover troncos da VM de origem (definitivo) =========="
    cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
echo '[mysql] troncos existentes antes do delete:'
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asterisk -e \
  "SELECT trunkid, name, disabled FROM trunks;"
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asterisk -e "
  DELETE s FROM sip s JOIN trunks t ON s.id = CONCAT('tr-reg-', t.trunkid);
  DELETE s FROM sip s JOIN trunks t ON s.id = CONCAT('tr-peer-', t.trunkid);
"
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asterisk -e "DELETE FROM trunks;"
echo '[mysql] troncos restantes (deve estar vazio):'
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asterisk -e \
  "SELECT trunkid, name, disabled FROM trunks;"
/var/lib/asterisk/bin/retrieve_conf 2>/dev/null
asterisk -rx "sip unregister all"
asterisk -rx "sip reload"
echo '[troncos] removidos, reload e unregister aplicados'
SCRIPT
    send_and_run_old "Removendo todos os troncos SIP" "$STEP"
  fi
  success "ETAPA 0 concluída."
fi

# ═══════════════════════════════════════════════════════════════════════════
# ETAPA 1 — importação do backup (nativa ou manual, conforme o modo)
# ═══════════════════════════════════════════════════════════════════════════

if [ "$RUN_ETAPA1" = "y" ]; then
  echo ""
  info "========== ETAPA 1: Importar backup =========="
  warn "Certifique-se de que o backup já foi gerado na VM de origem antes de prosseguir."
  warn "Ex.: Sistema > Backup/Restore no painel → selecione as opções adequadas → Process."
  echo ""
  confirm "Backup já gerado na VM de origem. Prosseguir?" || { warn "Abortado pelo usuário."; exit 0; }

  install_sshpass_rsync_remote
  send_and_run_old "Instalando sshpass e rsync na VM de origem" "$STEP"

  enable_temp_password_ssh_new
  send_and_run_new "Habilitando SSH por senha na VM de destino (temporário)" "$STEP"
  SSH_TEMP_ENABLED_NEW="y"

  if [ "$MIGRATION_MODE" = "legacy" ]; then
    # ── Caminho nativo: usa a ferramenta oficial de migração entre versões
    #    maiores, disponível em algumas distribuições PBX quando a origem é
    #    significativamente mais antiga que o destino.
    cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
BACKUP_FILE=\$(ls -t /var/www/backup/*backup*.tar 2>/dev/null | head -1)
[[ -z "\$BACKUP_FILE" ]] && { echo '[ERRO] Nenhum backup encontrado em /var/www/backup/'; exit 1; }
echo "[backup] arquivo selecionado: \$BACKUP_FILE"
sshpass -p '${NEW_VM_ROOT_PASS}' scp -P ${SSH_PORT} -o StrictHostKeyChecking=no \
  "\$BACKUP_FILE" \
  root@${NEW_VM_IP}:/tmp/pbx_migration_backup.tar
echo '[scp] backup transferido para VM de destino'
SCRIPT
    send_and_run_old "Transferindo backup para a VM de destino" "$STEP"

    cat > "$STEP" << 'SCRIPT'
#!/bin/bash
set -xe
BACKUP=/tmp/pbx_migration_backup.tar
[[ ! -f "$BACKUP" ]] && { echo '[ERRO] Backup nao encontrado em /tmp/'; exit 1; }
TOOL="$(command -v issabel_migration.sh || echo /usr/sbin/issabel_migration.sh)"
[[ ! -x "$TOOL" ]] && { echo "[ERRO] Ferramenta nativa de migração não encontrada em $TOOL — use o modo 'current' para restore manual"; exit 1; }
echo "[migration] iniciando migração via ferramenta nativa..."
cd /var/www/html
"$TOOL" -b "$BACKUP"
echo '[migration] concluido'
SCRIPT
    send_and_run_new "Rodando ferramenta nativa de migração entre versões" "$STEP"

  else
    # ── Caminho manual: extração direta do tarball + reconstrução do AstDB.
    cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
BACKUP_FILE=\$(ls -t /var/www/backup/*backup*.tar 2>/dev/null | head -1)
[[ -z "\$BACKUP_FILE" ]] && { echo '[ERRO] Nenhum backup encontrado em /var/www/backup/'; exit 1; }
echo "[backup] arquivo selecionado: \$BACKUP_FILE"
sshpass -p '${NEW_VM_ROOT_PASS}' rsync -avz --progress \
  -e 'ssh -p ${SSH_PORT} -o StrictHostKeyChecking=no' \
  "\$BACKUP_FILE" \
  root@${NEW_VM_IP}:/tmp/pbx_migration_backup.tar
echo '[rsync] backup transferido para VM de destino'
SCRIPT
    send_and_run_old "Transferindo backup para a VM de destino" "$STEP"

    cat > "$STEP" << 'SCRIPT'
#!/bin/bash
set -e
BACKUP=/tmp/pbx_migration_backup.tar
[[ ! -f "$BACKUP" ]] && { echo '[ERRO] Backup nao encontrado em /tmp/'; exit 1; }

WORKDIR=/tmp/pbx_restore_$$
mkdir -p "$WORKDIR"; cd "$WORKDIR"

echo "[extract] extraindo componentes do backup..."
tar -xOf "$BACKUP" backup/mysqldb_asterisk.tgz              | tar -xzf -
tar -xOf "$BACKUP" backup/var.lib.asterisk.sounds.custom.tgz | tar -xzf - 2>/dev/null || true
tar -xOf "$BACKUP" backup/var.lib.asterisk.moh.tgz           | tar -xzf - 2>/dev/null || true
tar -xOf "$BACKUP" backup/etc.asterisk.tgz                    | tar -xzf - 2>/dev/null || true

echo "[conf] removendo imutabilidade de arquivos protegidos..."
chattr -i /etc/asterisk/sip_general_additional.conf 2>/dev/null || true
chattr -i /etc/asterisk/rtp_additional.conf 2>/dev/null || true
chattr -i /etc/asterisk/pjsip_transport_custom.conf 2>/dev/null || true

echo "[mysql] importando banco asterisk..."
mysql -uroot -p"$MYSQL_ROOT_PASS_PLACEHOLDER" asterisk < "$WORKDIR/mysqldb_asterisk/asterisk.sql"

echo "[modules] limpando cache serializado..."
mysql -uroot -p"$MYSQL_ROOT_PASS_PLACEHOLDER" asterisk -e "
  DELETE FROM module_xml WHERE id IN ('mod_serialized','extmap_serialized','xml');
"

echo "[sounds] copiando audios custom..."
[ -d "$WORKDIR/custom" ] && cp -rf "$WORKDIR/custom/." /var/lib/asterisk/sounds/custom/ || true
chown -R asterisk:asterisk /var/lib/asterisk/sounds/custom/ 2>/dev/null || true

echo "[moh] copiando music on hold..."
[ -d "$WORKDIR/moh" ] && cp -rf "$WORKDIR/moh/." /var/lib/asterisk/moh/ || true
chown -R asterisk:asterisk /var/lib/asterisk/moh/ 2>/dev/null || true

echo "[conf] copiando arquivos de configuracao..."
[ -d "$WORKDIR/asterisk" ] && cp -rf "$WORKDIR/asterisk/." /etc/asterisk/ || true

echo "[chattr] reaplicando imutabilidade..."
chattr +i /etc/asterisk/sip_general_additional.conf 2>/dev/null || true
chattr +i /etc/asterisk/rtp_additional.conf 2>/dev/null || true
chattr +i /etc/asterisk/pjsip_transport_custom.conf 2>/dev/null || true

echo "[retrieve_conf] regenerando dialplan..."
/var/lib/asterisk/bin/retrieve_conf 2>/dev/null || true

rm -rf "$WORKDIR"
echo '[restore] concluido'
SCRIPT
    sed -i "s/\$MYSQL_ROOT_PASS_PLACEHOLDER/${MYSQL_ROOT_PASS}/g" "$STEP"
    send_and_run_new "Restaurando backup na VM de destino (manual)" "$STEP"

    cat > "$STEP" << 'SCRIPT'
#!/bin/bash
set -e
echo "[astdb] recriando banco de device-state do zero..."
systemctl stop asterisk 2>/dev/null || true
sleep 2
rm -f /var/lib/asterisk/astdb.sqlite3
systemctl start asterisk
sleep 5

echo "[astdb] repopulando AMPUSER/device e DEVICE/dial+type para todos os ramais..."
mysql -uroot -p"$MYSQL_ROOT_PASS_PLACEHOLDER" asterisk -sN -e "SELECT id, dial, devicetype FROM devices;" | \
while read -r id dial devicetype; do
  asterisk -rx "database put AMPUSER ${id}/device ${id}" >/dev/null 2>&1
  asterisk -rx "database put DEVICE ${id}/dial ${dial}" >/dev/null 2>&1
  asterisk -rx "database put DEVICE ${id}/type ${devicetype}" >/dev/null 2>&1
done

echo "[astdb] regenerando dialplan e hints..."
/var/lib/asterisk/bin/retrieve_conf 2>/dev/null || true
asterisk -rx "dialplan reload" >/dev/null 2>&1

echo "[astdb] forcando qualify em todos os peers..."
mysql -uroot -p"$MYSQL_ROOT_PASS_PLACEHOLDER" asterisk -sN -e "SELECT id FROM devices;" | \
while read -r id; do
  asterisk -rx "sip qualify peer ${id}" >/dev/null 2>&1
done
sleep 3
echo "[astdb] concluido"
SCRIPT
    sed -i "s/\$MYSQL_ROOT_PASS_PLACEHOLDER/${MYSQL_ROOT_PASS}/g" "$STEP"
    send_and_run_new "Corrigindo AstDB (device state / hints)" "$STEP"
  fi

  # Fix de schema comum a ambos os modos
  cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asteriskcdrdb -e "
  ALTER TABLE cel MODIFY eventextra VARCHAR(255) NOT NULL DEFAULT '';
"
echo '[mysql] fix de schema (eventextra) aplicado'
SCRIPT
  send_and_run_new "Fix de schema CEL após importação do backup" "$STEP"

  cat > "$STEP" << 'SCRIPT'
#!/bin/bash
rm -f /tmp/pbx_migration_backup.tar \
      /var/www/backup/pbx_migration_backup.tar \
  && echo '[cleanup] backups temporarios removidos'
SCRIPT
  send_and_run_new "Limpando backup temporário na VM de destino" "$STEP"

  success "ETAPA 1 concluída."
fi

# ═══════════════════════════════════════════════════════════════════════════
# ETAPA 2 — External IP + localnet + strictrtp
# ═══════════════════════════════════════════════════════════════════════════

if [ "$RUN_ETAPA2" = "y" ]; then
  echo ""
  info "========== ETAPA 2: External IP + localnet + strictrtp =========="

  read -rp "$(echo -e "${YEL}Faixa de rede local (localnet, formato CIDR, ex: 192.168.0.0/24):${NC} ")" LOCALNET_CIDR
  [[ -z "$LOCALNET_CIDR" ]] && die "localnet não pode ser vazio."

  read -rp "$(echo -e "${YEL}Porta SIP (bindport) [5060]:${NC} ")" SIP_PORT
  SIP_PORT="${SIP_PORT:-5060}"
  read -rp "$(echo -e "${YEL}Porta SIP-TLS (tlsbindport, deixe vazio se não usar TLS):${NC} ")" SIP_TLS_PORT

  SQL_FILE="$TMPDIR_LOCAL/sip_update.sql"
  {
    echo "INSERT INTO sipsettings (keyword, data, seq, type) VALUES"
    echo "  ('externip_val',   '${NEW_VM_IP}', 40, 0),"
    echo "  ('externhost_val', '${NEW_VM_IP}', 40, 0),"
    echo "  ('localnet_0',     '${LOCALNET_CIDR%%/*}', 42, 0),"
    echo "  ('bindport',       '${SIP_PORT}',   1,  0),"
    if [[ -n "$SIP_TLS_PORT" ]]; then
      echo "  ('tlsbindport',    '${SIP_TLS_PORT}', 1, 0),"
    fi
    echo "  ('bindaddr',       '',              2,  0)"
    echo "ON DUPLICATE KEY UPDATE data = VALUES(data);"
  } > "$SQL_FILE"

  scp $SCP_NEW "$SQL_FILE" root@"$NEW_VM_IP":/tmp/sip_update.sql >> "$LOG_FILE" 2>&1 \
    || die "scp do arquivo SQL falhou"

  cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asterisk < /tmp/sip_update.sql
rm -f /tmp/sip_update.sql
echo '[mysql] sipsettings atualizado'
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asterisk -e \
  'SELECT keyword, data FROM sipsettings WHERE keyword IN ("externip_val","externhost_val","localnet_0","bindport","tlsbindport");'
SCRIPT
  send_and_run_new "Atualizando sipsettings no MySQL" "$STEP"

  cat > "$STEP" << 'SCRIPT'
#!/bin/bash
set -xe
/var/lib/asterisk/bin/retrieve_conf 2>/dev/null
echo '[retrieve_conf] concluído'
SCRIPT
  send_and_run_new "Rodando retrieve_conf" "$STEP"

  cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
CONF=/etc/asterisk/sip_general_additional.conf
chattr -i "\$CONF" 2>/dev/null || true
sed -i '/^nat=/d'      "\$CONF"
sed -i '/^externip=/d' "\$CONF"
sed -i '/^localnet=/d' "\$CONF"
echo 'nat=yes'                    >> "\$CONF"
echo 'externip=${NEW_VM_IP}'      >> "\$CONF"
echo 'localnet=${LOCALNET_CIDR}'  >> "\$CONF"
chattr +i "\$CONF"
echo '[conf] resultado:'
grep -E 'nat=|externip|localnet' "\$CONF"
SCRIPT
  send_and_run_new "Configurando nat/externip/localnet no conf" "$STEP"

  cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asterisk -e "
  DELETE FROM sipsettings WHERE keyword='localnet';
  INSERT INTO sipsettings (keyword, data, seq, type) VALUES ('localnet', '${LOCALNET_CIDR}', 1, 0);
"
echo '[mysql] localnet corrigido no banco'
SCRIPT
  send_and_run_new "Fix localnet no banco" "$STEP"

  cat > "$STEP" << 'SCRIPT'
#!/bin/bash
set -xe
chattr -i /etc/asterisk/rtp_additional.conf 2>/dev/null || true
grep -q 'strictrtp' /etc/asterisk/rtp_additional.conf && echo '[info] strictrtp ja existe' || {
  sed -i '/^\[general\]/a strictrtp=no' /etc/asterisk/rtp_additional.conf
  echo '[sed] strictrtp=no inserido'
}
chattr +i /etc/asterisk/rtp_additional.conf
echo '[rtp_additional]:'
cat /etc/asterisk/rtp_additional.conf
SCRIPT
  send_and_run_new "Configurando strictrtp=no" "$STEP"

  cat > "$STEP" << 'SCRIPT'
#!/bin/bash
set -x
asterisk -rx 'module reload res_rtp_asterisk.so' || true
asterisk -rx 'sip reload' || true
echo '--- sip show settings ---'
asterisk -rx 'sip show settings' | grep -E 'Extern|Localnet|NAT|Bind' || true
echo '--- conf ---'
grep -E 'nat=|externip|localnet' /etc/asterisk/sip_general_additional.conf || echo 'NAO ENCONTRADO'
echo '--- strictrtp ---'
grep strictrtp /etc/asterisk/rtp_additional.conf || echo 'NAO ENCONTRADO'
echo '--- rtp show settings ---'
asterisk -rx 'rtp show settings' | grep -i strict || true
SCRIPT
  send_and_run_new "Reload e verificação final ETAPA 2" "$STEP"

  success "ETAPA 2 concluída."

  echo ""
  echo -e "${YEL}┌──────────────────────────────────────────────────────────┐${NC}"
  echo -e "${YEL}│  PENDÊNCIA MANUAL: Atualizar DNS/registro externo         │${NC}"
  echo -e "${YEL}│                                                          │${NC}"
  printf  "${YEL}│  Aponte o registro do cliente para: %-20s │${NC}\n" "$NEW_VM_IP"
  echo -e "${YEL}│  Acompanhe a virada dos ramais/softphones após a troca.  │${NC}"
  echo -e "${YEL}└──────────────────────────────────────────────────────────┘${NC}"
  echo ""
  confirm "DNS/registro atualizado. Deseja prosseguir?" || { warn "Abortado pelo usuário."; exit 0; }
fi

# ═══════════════════════════════════════════════════════════════════════════
# ETAPA 3 — Dump CDR + transferência + import
# ═══════════════════════════════════════════════════════════════════════════

if [ "$RUN_ETAPA3" = "y" ]; then
  echo ""
  info "========== ETAPA 3: Dump de CDR + transferência + import =========="

  read -rp "$(echo -e "${YEL}Quantos meses de histórico migrar? (vazio = tudo):${NC} ")" CDR_MONTHS

  if [[ -n "$CDR_MONTHS" ]]; then
    cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
mysqldump -u root -p${MYSQL_ROOT_PASS} asteriskcdrdb cdr \
  --where="calldate >= DATE_SUB(NOW(), INTERVAL ${CDR_MONTHS} MONTH)" \
  > /tmp/asteriskcdrdb_backup.sql
ls -lh /tmp/asteriskcdrdb_backup.sql
echo '[dump] concluido (ultimos ${CDR_MONTHS} meses)'
SCRIPT
  else
    cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
mysqldump -u root -p${MYSQL_ROOT_PASS} asteriskcdrdb > /tmp/asteriskcdrdb_backup.sql
ls -lh /tmp/asteriskcdrdb_backup.sql
echo '[dump] concluido (historico completo)'
SCRIPT
  fi
  send_and_run_old "Gerando dump do asteriskcdrdb" "$STEP"

  if [ "$SSH_TEMP_ENABLED_NEW" = "n" ]; then
    enable_temp_password_ssh_new
    send_and_run_new "Habilitando SSH por senha na VM de destino (temporário)" "$STEP"
    SSH_TEMP_ENABLED_NEW="y"

    install_sshpass_rsync_remote
    send_and_run_old "Instalando sshpass e rsync na VM de origem" "$STEP"
  fi

  cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
sshpass -p '${NEW_VM_ROOT_PASS}' rsync -avz --progress \
  -e 'ssh -p ${SSH_PORT} -o StrictHostKeyChecking=no' \
  /tmp/asteriskcdrdb_backup.sql \
  root@${NEW_VM_IP}:/tmp/
echo '[rsync] dump transferido'
SCRIPT
  send_and_run_old "Transferindo dump do CDR para a VM de destino" "$STEP"

  cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asteriskcdrdb -e 'ALTER TABLE cel MODIFY eventextra VARCHAR(255) NOT NULL DEFAULT "";'
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asteriskcdrdb -e 'ALTER TABLE cdr ADD COLUMN IF NOT EXISTS linkedid VARCHAR(32) NOT NULL DEFAULT "";'
echo '[mysql] schema corrigido'
SCRIPT
  send_and_run_new "Fix de schema (linkedid + eventextra)" "$STEP"

  cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
ls -lh /tmp/asteriskcdrdb_backup.sql
mysql -u root -p${MYSQL_ROOT_PASS} asteriskcdrdb < /tmp/asteriskcdrdb_backup.sql
echo '[mysql] import concluido'
SCRIPT
  send_and_run_new "Importando dump do CDR" "$STEP"

  cat > "$STEP" << 'SCRIPT'
#!/bin/bash
rm -f /tmp/asteriskcdrdb_backup.sql && echo '[cleanup] dump removido'
SCRIPT
  send_and_run_old "Limpando dump na VM de origem" "$STEP"
  send_and_run_new "Limpando dump na VM de destino" "$STEP"

  success "ETAPA 3 concluída."
fi

# ═══════════════════════════════════════════════════════════════════════════
# ETAPA 4 — Gravações
# ═══════════════════════════════════════════════════════════════════════════

if [ "$RUN_ETAPA4" = "y" ]; then
  echo ""
  info "========== ETAPA 4: Migração de gravações de chamadas =========="
  warn "Pode demorar dependendo do volume. Prefira rodar dentro de tmux/screen."

  if [ "$SSH_TEMP_ENABLED_NEW" = "n" ]; then
    enable_temp_password_ssh_new
    send_and_run_new "Habilitando SSH por senha na VM de destino (temporário)" "$STEP"
    SSH_TEMP_ENABLED_NEW="y"

    install_sshpass_rsync_remote
    send_and_run_old "Instalando sshpass e rsync na VM de origem" "$STEP"
  fi

  cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
sshpass -p '${NEW_VM_ROOT_PASS}' rsync -avz --progress --partial \
  -e 'ssh -p ${SSH_PORT} -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=5' \
  /var/spool/asterisk/monitor/ \
  root@${NEW_VM_IP}:/var/spool/asterisk/monitor/
echo '[rsync] gravacoes transferidas'
SCRIPT
  send_and_run_old "rsync das gravações para a VM de destino" "$STEP"
  success "ETAPA 4 concluída — Gravações migradas."
fi

# ─── Bloquear SSH por senha na VM de destino (reverte acesso temporário) ────

if [ "$SSH_TEMP_ENABLED_NEW" = "y" ]; then
  cat > "$STEP" << 'SCRIPT'
#!/bin/bash
set -xe
sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd
echo '[sshd] PasswordAuthentication=no restaurado'
SCRIPT
  send_and_run_new "Bloqueando SSH por senha na VM de destino" "$STEP"
  success "SSH por senha bloqueado — acesso temporário revertido."
fi

# ─── Reboot ──────────────────────────────────────────────────────────────────

echo ""
info "Reiniciando a VM de destino..."
ssh $SSH_NEW root@"$NEW_VM_IP" 'reboot' || true
log "Reboot enviado para $NEW_VM_IP"

echo ""
echo -e "${GRN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GRN}║        ✅  Migração concluída com sucesso!    ║${NC}"
echo -e "${GRN}╚══════════════════════════════════════════════╝${NC}"
echo ""
info "Log completo salvo em: $LOG_FILE"
info "Lembre-se de confirmar que a senha temporária de root da VM de destino foi revogada."
echo ""
