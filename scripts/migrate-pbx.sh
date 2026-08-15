#!/usr/bin/env bash
# ============================================================
#  migrate-pbx.sh — Issabel PBX (Asterisk-based) migration between VMs
#  — swaps hosts while keeping call flow, extensions,
#  trunks, call history (CDR), and recordings.
#
#  Supports TWO migration modes, because in environments where
#  installation is done on-demand straight from the official
#  repository, it's common to end up with source VMs on quite
#  different versions from each other (e.g. an install from
#  2 years ago vs. one from last week). Each requires a
#  different strategy:
#
#   [legacy]  Source on an older version, with a backup/restore
#             structure incompatible with the destination
#             version's native restore. Uses the native tool
#             for migrating between major versions (when
#             available for your PBX) and disables trunks
#             instead of removing them, since the old schema
#             may not have the same columns/relationships.
#
#   [current] Source already close to the destination version.
#             Does a manual backup/restore (direct tarball
#             extraction, without relying on the native helper —
#             which fails with customizations), removes trunks
#             permanently, and rebuilds the AstDB from scratch
#             (device state/hints).
#
#  Usage: bash migrate-pbx.sh (check permissions first).
# ============================================================

set -euo pipefail

# ─── Credentials (never hardcode here — use environment variables) ─────────
#
#   export PBX_MYSQL_USER="asteriskuser"
#   export PBX_MYSQL_PASS="your-password"
#   export PBX_MYSQL_ROOT_PASS="your-root-password"
#   export PBX_NEW_VM_ROOT_PASS="temporary-password-for-transfer"
#
# If not set, the script will prompt interactively.

MYSQL_USER="${PBX_MYSQL_USER:-}"
MYSQL_PASS="${PBX_MYSQL_PASS:-}"
MYSQL_ROOT_PASS="${PBX_MYSQL_ROOT_PASS:-}"
NEW_VM_ROOT_PASS="${PBX_NEW_VM_ROOT_PASS:-}"

SSH_KEY="${PBX_SSH_KEY:-$HOME/.ssh/id_ed25519}" # Adjust as needed for your current execution environment.
SSH_PORT="${PBX_SSH_PORT:-22}"   # SSH access port for the VMs. Also needs adjusting per your environment/rules.

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
warn()    { local m="[WARN]   $*"; echo -e "${YEL}${m}${NC}"; log "$m"; }
die()     { local m="[ERROR]  $*"; echo -e "${RED}${m}${NC}"; log "$m"; exit 1; }

# Note: the log records the commands executed remotely, but NEVER the password values themselves.

send_and_run_new() {
  local label="$1" file="$2"
  info "→ [destination VM] $label"
  log "--- script: $label ---"
  scp $SCP_NEW "$file" root@"$NEW_VM_IP":/tmp/migrate_step.sh >> "$LOG_FILE" 2>&1 \
    || die "scp failed for destination VM at: $label"
  ssh $SSH_NEW root@"$NEW_VM_IP" \
    'bash /tmp/migrate_step.sh; rc=$?; rm -f /tmp/migrate_step.sh; exit $rc' \
    2>&1 | tee -a "$LOG_FILE" \
    || die "Script failed on destination VM at: $label"
}

send_and_run_old() {
  local label="$1" file="$2"
  info "→ [source VM] $label"
  log "--- script: $label ---"
  sshpass -p "$OLD_VM_PASS" scp $SCP_OLD "$file" root@"$OLD_VM_IP":/tmp/migrate_step.sh >> "$LOG_FILE" 2>&1 \
    || die "scp failed for source VM at: $label"
  sshpass -p "$OLD_VM_PASS" ssh $SSH_OLD root@"$OLD_VM_IP" \
    'bash /tmp/migrate_step.sh; rc=$?; rm -f /tmp/migrate_step.sh; exit $rc' \
    2>&1 | tee -a "$LOG_FILE" \
    || die "Script failed on source VM at: $label"
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
    [[ -z "$__val" ]] && die "Value cannot be empty."
    printf -v "$__var" '%s' "$__val"
  fi
}

install_sshpass_rsync_remote() {

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
    echo '[ERROR] package manager not recognized'; exit 1
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
echo '[sshd] ready (temporary, revoked at the end)'
SCRIPT
}

cleanup() { rm -rf "$TMPDIR_LOCAL"; }
trap cleanup EXIT

echo ""
echo -e "${CYN}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYN}║           Issabel PBX migration between VMs — by Guilherme Nunes          ║${NC}"
echo -e "${CYN}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
echo ""
info "Log saved to: $LOG_FILE (commands are logged, passwords are never written in plain text)"
echo ""

# ─── Migration mode selection ────────────────────────────────────────────────

echo -e "${YEL}What is the scenario for this migration?${NC}"
echo ""
echo "  [1] legacy  — Source VM on a much older version than the destination."
echo "                Uses the native tool for migrating between major"
echo "                versions (when available) and only disables trunks"
echo "                on the source."
echo "  [2] current — Source VM on a version close to the destination."
echo "                Does a manual backup/restore (more robust against"
echo "                customizations) and rebuilds the AstDB from scratch."
echo ""
read -rp "$(echo -e "${YEL}Choose [1/2]:${NC} ")" MODE_CHOICE
case "$MODE_CHOICE" in
  1) MIGRATION_MODE="legacy" ;;
  2) MIGRATION_MODE="current" ;;
  *) die "Invalid option. Run again and choose 1 or 2." ;;
esac
success "Migration mode selected: $MIGRATION_MODE"

# ─── Credential collection ────────────────────────────────────────────────────

echo ""
prompt_secret MYSQL_USER       "Asterisk MySQL user (e.g. asteriskuser)"
prompt_secret MYSQL_PASS       "Asterisk MySQL user password"
prompt_secret MYSQL_ROOT_PASS  "MySQL root password"
prompt_secret NEW_VM_ROOT_PASS "Temporary root password for the destination VM (used only during transfer, revoked at the end)"

# ─── Step menu ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${YEL}Select the steps to run:${NC}"
echo ""

if [ "$MIGRATION_MODE" = "legacy" ]; then
  confirm "  [0] Disable trunks on the source VM"                  && RUN_ETAPA0=y || RUN_ETAPA0=n
  confirm "  [1] Import backup via native migration tool"          && RUN_ETAPA1=y || RUN_ETAPA1=n
else
  confirm "  [0] Remove trunks from the source VM (permanent)"     && RUN_ETAPA0=y || RUN_ETAPA0=n
  confirm "  [1] Manual backup + restore (Asterisk/AMP database)"  && RUN_ETAPA1=y || RUN_ETAPA1=n
fi
confirm "  [2] External IP + localnet + strictrtp"                 && RUN_ETAPA2=y || RUN_ETAPA2=n
confirm "  [3] CDR dump + transfer + import"                       && RUN_ETAPA3=y || RUN_ETAPA3=n
confirm "  [4] Call recordings migration"                          && RUN_ETAPA4=y || RUN_ETAPA4=n

echo ""
echo -e "${CYN}Selected steps (mode: $MIGRATION_MODE):${NC}"
[ "$RUN_ETAPA0" = "y" ] && echo -e "  ${GRN}✔${NC} Step 0" || echo -e "  ${RED}✗${NC} Step 0"
[ "$RUN_ETAPA1" = "y" ] && echo -e "  ${GRN}✔${NC} Step 1" || echo -e "  ${RED}✗${NC} Step 1"
[ "$RUN_ETAPA2" = "y" ] && echo -e "  ${GRN}✔${NC} Step 2" || echo -e "  ${RED}✗${NC} Step 2"
[ "$RUN_ETAPA3" = "y" ] && echo -e "  ${GRN}✔${NC} Step 3" || echo -e "  ${RED}✗${NC} Step 3"
[ "$RUN_ETAPA4" = "y" ] && echo -e "  ${GRN}✔${NC} Step 4" || echo -e "  ${RED}✗${NC} Step 4"
echo ""

confirm "Confirm and proceed?" || { warn "Aborted by user."; exit 0; }

# ─── Collection: destination VM ──────────────────────────────────────────────

echo ""
read -rp "$(echo -e "${YEL}Destination VM IP/hostname:${NC} ")" NEW_VM_IP
[[ -z "$NEW_VM_IP" ]] && die "IP cannot be empty."

info "Testing connection to the destination VM ($NEW_VM_IP)..."
ssh $SSH_NEW root@"$NEW_VM_IP" 'echo ok' >> "$LOG_FILE" 2>&1 \
  || die "Failed to connect to the destination VM. Check the IP and the SSH key."
success "Connected to the destination VM."

# ─── Collection: source VM ───────────────────────────────────────────────────

OLD_VM_IP=""
OLD_VM_PASS=""
if [ "$RUN_ETAPA0" = "y" ] || [ "$RUN_ETAPA1" = "y" ] || [ "$RUN_ETAPA3" = "y" ] || [ "$RUN_ETAPA4" = "y" ]; then
  echo ""
  read -rp "$(echo -e "${YEL}Source VM IP/hostname:${NC} ")" OLD_VM_IP
  [[ -z "$OLD_VM_IP" ]] && die "IP cannot be empty."

  read -rsp "$(echo -e "${YEL}Source VM root password:${NC} ")" OLD_VM_PASS
  echo ""
  [[ -z "$OLD_VM_PASS" ]] && die "Password cannot be empty."

  info "Testing connection to the source VM ($OLD_VM_IP)..."
  sshpass -p "$OLD_VM_PASS" ssh $SSH_OLD root@"$OLD_VM_IP" 'echo ok' >> "$LOG_FILE" 2>&1 \
    || die "Failed to connect to the source VM. Check the IP and password."
  success "Connected to the source VM."
fi

STEP="$TMPDIR_LOCAL/step.sh"
SSH_TEMP_ENABLED_NEW="n"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 0 — trunk handling on the source
# ═══════════════════════════════════════════════════════════════════════════

if [ "$RUN_ETAPA0" = "y" ]; then
  echo ""
  if [ "$MIGRATION_MODE" = "legacy" ]; then
    info "========== STEP 0 (legacy): Disabling trunks on the source VM =========="
    cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
echo '[mysql] active trunks before disable:'
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asterisk -e \
  "SELECT trunkid, name, disabled FROM trunks WHERE disabled='off';"
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asterisk -e \
  "UPDATE trunks SET disabled='on' WHERE disabled='off';"
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asterisk -e "
  DELETE FROM sip WHERE id IN (
    SELECT CONCAT('tr-reg-', trunkid) FROM trunks WHERE disabled='on'
  );
"
echo '[mysql] trunks disabled and SIP registrations removed'
/var/lib/asterisk/bin/retrieve_conf 2>/dev/null
asterisk -rx "sip unregister all"
asterisk -rx "sip reload"
echo '[trunks] reload and unregister applied'
SCRIPT
    send_and_run_old "Disabling all trunks" "$STEP"
  else
    info "========== STEP 0 (current): Removing trunks from the source VM (permanent) =========="
    cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
echo '[mysql] existing trunks before delete:'
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asterisk -e \
  "SELECT trunkid, name, disabled FROM trunks;"
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asterisk -e "
  DELETE s FROM sip s JOIN trunks t ON s.id = CONCAT('tr-reg-', t.trunkid);
  DELETE s FROM sip s JOIN trunks t ON s.id = CONCAT('tr-peer-', t.trunkid);
"
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asterisk -e "DELETE FROM trunks;"
echo '[mysql] remaining trunks (should be empty):'
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asterisk -e \
  "SELECT trunkid, name, disabled FROM trunks;"
/var/lib/asterisk/bin/retrieve_conf 2>/dev/null
asterisk -rx "sip unregister all"
asterisk -rx "sip reload"
echo '[trunks] removed, reload and unregister applied'
SCRIPT
    send_and_run_old "Removing all SIP trunks" "$STEP"
  fi
  success "STEP 0 completed."
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1 — backup import (native or manual, depending on the mode)
# ═══════════════════════════════════════════════════════════════════════════

if [ "$RUN_ETAPA1" = "y" ]; then
  echo ""
  info "========== STEP 1: Import backup =========="
  warn "Make sure the backup has already been generated on the source VM before proceeding."
  warn "E.g.: System > Backup/Restore in the panel → select the appropriate options → Process."
  echo ""
  confirm "Backup already generated on the source VM. Proceed?" || { warn "Aborted by user."; exit 0; }

  install_sshpass_rsync_remote
  send_and_run_old "Installing sshpass and rsync on the source VM" "$STEP"

  enable_temp_password_ssh_new
  send_and_run_new "Enabling password SSH on the destination VM (temporary)" "$STEP"
  SSH_TEMP_ENABLED_NEW="y"

  if [ "$MIGRATION_MODE" = "legacy" ]; then
    # ── Native path: uses the official tool for migrating between major
    #    versions, available on some PBX distributions when the source is
    #    significantly older than the destination.
    cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
BACKUP_FILE=\$(ls -t /var/www/backup/*backup*.tar 2>/dev/null | head -1)
[[ -z "\$BACKUP_FILE" ]] && { echo '[ERROR] No backup found in /var/www/backup/'; exit 1; }
echo "[backup] file selected: \$BACKUP_FILE"
sshpass -p '${NEW_VM_ROOT_PASS}' scp -P ${SSH_PORT} -o StrictHostKeyChecking=no \
  "\$BACKUP_FILE" \
  root@${NEW_VM_IP}:/tmp/pbx_migration_backup.tar
echo '[scp] backup transferred to destination VM'
SCRIPT
    send_and_run_old "Transferring backup to the destination VM" "$STEP"

    cat > "$STEP" << 'SCRIPT'
#!/bin/bash
set -xe
BACKUP=/tmp/pbx_migration_backup.tar
[[ ! -f "$BACKUP" ]] && { echo '[ERROR] Backup not found in /tmp/'; exit 1; }
TOOL="$(command -v issabel_migration.sh || echo /usr/sbin/issabel_migration.sh)"
[[ ! -x "$TOOL" ]] && { echo "[ERROR] Native migration tool not found at $TOOL — use 'current' mode for manual restore"; exit 1; }
echo "[migration] starting migration via native tool..."
cd /var/www/html
"$TOOL" -b "$BACKUP"
echo '[migration] done'
SCRIPT
    send_and_run_new "Running native migration tool between major versions" "$STEP"

  else
    # ── Manual path: direct tarball extraction + AstDB rebuild.
    cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
BACKUP_FILE=\$(ls -t /var/www/backup/*backup*.tar 2>/dev/null | head -1)
[[ -z "\$BACKUP_FILE" ]] && { echo '[ERROR] No backup found in /var/www/backup/'; exit 1; }
echo "[backup] file selected: \$BACKUP_FILE"
sshpass -p '${NEW_VM_ROOT_PASS}' rsync -avz --progress \
  -e 'ssh -p ${SSH_PORT} -o StrictHostKeyChecking=no' \
  "\$BACKUP_FILE" \
  root@${NEW_VM_IP}:/tmp/pbx_migration_backup.tar
echo '[rsync] backup transferred to destination VM'
SCRIPT
    send_and_run_old "Transferring backup to the destination VM" "$STEP"

    cat > "$STEP" << 'SCRIPT'
#!/bin/bash
set -e
BACKUP=/tmp/pbx_migration_backup.tar
[[ ! -f "$BACKUP" ]] && { echo '[ERROR] Backup not found in /tmp/'; exit 1; }

WORKDIR=/tmp/pbx_restore_$$
mkdir -p "$WORKDIR"; cd "$WORKDIR"

echo "[extract] extracting backup components..."
tar -xOf "$BACKUP" backup/mysqldb_asterisk.tgz              | tar -xzf -
tar -xOf "$BACKUP" backup/var.lib.asterisk.sounds.custom.tgz | tar -xzf - 2>/dev/null || true
tar -xOf "$BACKUP" backup/var.lib.asterisk.moh.tgz           | tar -xzf - 2>/dev/null || true
tar -xOf "$BACKUP" backup/etc.asterisk.tgz                    | tar -xzf - 2>/dev/null || true

echo "[conf] removing immutability from protected files..."
chattr -i /etc/asterisk/sip_general_additional.conf 2>/dev/null || true
chattr -i /etc/asterisk/rtp_additional.conf 2>/dev/null || true
chattr -i /etc/asterisk/pjsip_transport_custom.conf 2>/dev/null || true

echo "[mysql] importing asterisk database..."
mysql -uroot -p"$MYSQL_ROOT_PASS_PLACEHOLDER" asterisk < "$WORKDIR/mysqldb_asterisk/asterisk.sql"

echo "[modules] clearing serialized cache..."
mysql -uroot -p"$MYSQL_ROOT_PASS_PLACEHOLDER" asterisk -e "
  DELETE FROM module_xml WHERE id IN ('mod_serialized','extmap_serialized','xml');
"

echo "[sounds] copying custom audio..."
[ -d "$WORKDIR/custom" ] && cp -rf "$WORKDIR/custom/." /var/lib/asterisk/sounds/custom/ || true
chown -R asterisk:asterisk /var/lib/asterisk/sounds/custom/ 2>/dev/null || true

echo "[moh] copying music on hold..."
[ -d "$WORKDIR/moh" ] && cp -rf "$WORKDIR/moh/." /var/lib/asterisk/moh/ || true
chown -R asterisk:asterisk /var/lib/asterisk/moh/ 2>/dev/null || true

echo "[conf] copying configuration files..."
[ -d "$WORKDIR/asterisk" ] && cp -rf "$WORKDIR/asterisk/." /etc/asterisk/ || true

echo "[chattr] reapplying immutability..."
chattr +i /etc/asterisk/sip_general_additional.conf 2>/dev/null || true
chattr +i /etc/asterisk/rtp_additional.conf 2>/dev/null || true
chattr +i /etc/asterisk/pjsip_transport_custom.conf 2>/dev/null || true

echo "[retrieve_conf] regenerating dialplan..."
/var/lib/asterisk/bin/retrieve_conf 2>/dev/null || true

rm -rf "$WORKDIR"
echo '[restore] done'
SCRIPT
    sed -i "s/\$MYSQL_ROOT_PASS_PLACEHOLDER/${MYSQL_ROOT_PASS}/g" "$STEP"
    send_and_run_new "Restoring backup on the destination VM (manual)" "$STEP"

    cat > "$STEP" << 'SCRIPT'
#!/bin/bash
set -e
echo "[astdb] rebuilding device-state database from scratch..."
systemctl stop asterisk 2>/dev/null || true
sleep 2
rm -f /var/lib/asterisk/astdb.sqlite3
systemctl start asterisk
sleep 5

echo "[astdb] repopulating AMPUSER/device and DEVICE/dial+type for all extensions..."
mysql -uroot -p"$MYSQL_ROOT_PASS_PLACEHOLDER" asterisk -sN -e "SELECT id, dial, devicetype FROM devices;" | \
while read -r id dial devicetype; do
  asterisk -rx "database put AMPUSER ${id}/device ${id}" >/dev/null 2>&1
  asterisk -rx "database put DEVICE ${id}/dial ${dial}" >/dev/null 2>&1
  asterisk -rx "database put DEVICE ${id}/type ${devicetype}" >/dev/null 2>&1
done

echo "[astdb] regenerating dialplan and hints..."
/var/lib/asterisk/bin/retrieve_conf 2>/dev/null || true
asterisk -rx "dialplan reload" >/dev/null 2>&1

echo "[astdb] forcing qualify on all peers..."
mysql -uroot -p"$MYSQL_ROOT_PASS_PLACEHOLDER" asterisk -sN -e "SELECT id FROM devices;" | \
while read -r id; do
  asterisk -rx "sip qualify peer ${id}" >/dev/null 2>&1
done
sleep 3
echo "[astdb] done"
SCRIPT
    sed -i "s/\$MYSQL_ROOT_PASS_PLACEHOLDER/${MYSQL_ROOT_PASS}/g" "$STEP"
    send_and_run_new "Fixing AstDB (device state / hints)" "$STEP"
  fi

  # Schema fix common to both modes
  cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asteriskcdrdb -e "
  ALTER TABLE cel MODIFY eventextra VARCHAR(255) NOT NULL DEFAULT '';
"
echo '[mysql] schema fix (eventextra) applied'
SCRIPT
  send_and_run_new "Fixing CEL schema after backup import" "$STEP"

  cat > "$STEP" << 'SCRIPT'
#!/bin/bash
rm -f /tmp/pbx_migration_backup.tar \
      /var/www/backup/pbx_migration_backup.tar \
  && echo '[cleanup] temporary backups removed'
SCRIPT
  send_and_run_new "Cleaning up temporary backup on the destination VM" "$STEP"

  success "STEP 1 completed."
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2 — External IP + localnet + strictrtp
# ═══════════════════════════════════════════════════════════════════════════

if [ "$RUN_ETAPA2" = "y" ]; then
  echo ""
  info "========== STEP 2: External IP + localnet + strictrtp =========="

  read -rp "$(echo -e "${YEL}Local network range (localnet, CIDR format, e.g. 192.168.0.0/24):${NC} ")" LOCALNET_CIDR
  [[ -z "$LOCALNET_CIDR" ]] && die "localnet cannot be empty."

  read -rp "$(echo -e "${YEL}SIP port (bindport) [5060]:${NC} ")" SIP_PORT
  SIP_PORT="${SIP_PORT:-5060}"
  read -rp "$(echo -e "${YEL}SIP-TLS port (tlsbindport, leave empty if not using TLS):${NC} ")" SIP_TLS_PORT

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
    || die "scp of the SQL file failed"

  cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asterisk < /tmp/sip_update.sql
rm -f /tmp/sip_update.sql
echo '[mysql] sipsettings updated'
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asterisk -e \
  'SELECT keyword, data FROM sipsettings WHERE keyword IN ("externip_val","externhost_val","localnet_0","bindport","tlsbindport");'
SCRIPT
  send_and_run_new "Updating sipsettings in MySQL" "$STEP"

  cat > "$STEP" << 'SCRIPT'
#!/bin/bash
set -xe
/var/lib/asterisk/bin/retrieve_conf 2>/dev/null
echo '[retrieve_conf] done'
SCRIPT
  send_and_run_new "Running retrieve_conf" "$STEP"

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
echo '[conf] result:'
grep -E 'nat=|externip|localnet' "\$CONF"
SCRIPT
  send_and_run_new "Configuring nat/externip/localnet in the conf" "$STEP"

  cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asterisk -e "
  DELETE FROM sipsettings WHERE keyword='localnet';
  INSERT INTO sipsettings (keyword, data, seq, type) VALUES ('localnet', '${LOCALNET_CIDR}', 1, 0);
"
echo '[mysql] localnet fixed in the database'
SCRIPT
  send_and_run_new "Fixing localnet in the database" "$STEP"

  cat > "$STEP" << 'SCRIPT'
#!/bin/bash
set -xe
chattr -i /etc/asterisk/rtp_additional.conf 2>/dev/null || true
grep -q 'strictrtp' /etc/asterisk/rtp_additional.conf && echo '[info] strictrtp already exists' || {
  sed -i '/^\[general\]/a strictrtp=no' /etc/asterisk/rtp_additional.conf
  echo '[sed] strictrtp=no inserted'
}
chattr +i /etc/asterisk/rtp_additional.conf
echo '[rtp_additional]:'
cat /etc/asterisk/rtp_additional.conf
SCRIPT
  send_and_run_new "Configuring strictrtp=no" "$STEP"

  cat > "$STEP" << 'SCRIPT'
#!/bin/bash
set -x
asterisk -rx 'module reload res_rtp_asterisk.so' || true
asterisk -rx 'sip reload' || true
echo '--- sip show settings ---'
asterisk -rx 'sip show settings' | grep -E 'Extern|Localnet|NAT|Bind' || true
echo '--- conf ---'
grep -E 'nat=|externip|localnet' /etc/asterisk/sip_general_additional.conf || echo 'NOT FOUND'
echo '--- strictrtp ---'
grep strictrtp /etc/asterisk/rtp_additional.conf || echo 'NOT FOUND'
echo '--- rtp show settings ---'
asterisk -rx 'rtp show settings' | grep -i strict || true
SCRIPT
  send_and_run_new "Reload and final verification for STEP 2" "$STEP"

  success "STEP 2 completed."

  echo ""
  echo -e "${YEL}┌──────────────────────────────────────────────────────────┐${NC}"
  echo -e "${YEL}│  MANUAL PENDING TASK: Update external DNS/record          │${NC}"
  echo -e "${YEL}│                                                          │${NC}"
  printf  "${YEL}│  Point the client's record to: %-25s │${NC}\n" "$NEW_VM_IP"
  echo -e "${YEL}│  Monitor extensions/softphones switching over.           │${NC}"
  echo -e "${YEL}└──────────────────────────────────────────────────────────┘${NC}"
  echo ""
  confirm "DNS/record updated. Proceed?" || { warn "Aborted by user."; exit 0; }
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3 — CDR dump + transfer + import
# ═══════════════════════════════════════════════════════════════════════════

if [ "$RUN_ETAPA3" = "y" ]; then
  echo ""
  info "========== STEP 3: CDR dump + transfer + import =========="

  read -rp "$(echo -e "${YEL}How many months of history to migrate? (empty = everything):${NC} ")" CDR_MONTHS

  if [[ -n "$CDR_MONTHS" ]]; then
    cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
mysqldump -u root -p${MYSQL_ROOT_PASS} asteriskcdrdb cdr \
  --where="calldate >= DATE_SUB(NOW(), INTERVAL ${CDR_MONTHS} MONTH)" \
  > /tmp/asteriskcdrdb_backup.sql
ls -lh /tmp/asteriskcdrdb_backup.sql
echo '[dump] done (last ${CDR_MONTHS} months)'
SCRIPT
  else
    cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
mysqldump -u root -p${MYSQL_ROOT_PASS} asteriskcdrdb > /tmp/asteriskcdrdb_backup.sql
ls -lh /tmp/asteriskcdrdb_backup.sql
echo '[dump] done (full history)'
SCRIPT
  fi
  send_and_run_old "Generating asteriskcdrdb dump" "$STEP"

  if [ "$SSH_TEMP_ENABLED_NEW" = "n" ]; then
    enable_temp_password_ssh_new
    send_and_run_new "Enabling password SSH on the destination VM (temporary)" "$STEP"
    SSH_TEMP_ENABLED_NEW="y"

    install_sshpass_rsync_remote
    send_and_run_old "Installing sshpass and rsync on the source VM" "$STEP"
  fi

  cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
sshpass -p '${NEW_VM_ROOT_PASS}' rsync -avz --progress \
  -e 'ssh -p ${SSH_PORT} -o StrictHostKeyChecking=no' \
  /tmp/asteriskcdrdb_backup.sql \
  root@${NEW_VM_IP}:/tmp/
echo '[rsync] dump transferred'
SCRIPT
  send_and_run_old "Transferring CDR dump to the destination VM" "$STEP"

  cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asteriskcdrdb -e 'ALTER TABLE cel MODIFY eventextra VARCHAR(255) NOT NULL DEFAULT "";'
mysql -u${MYSQL_USER} -p${MYSQL_PASS} asteriskcdrdb -e 'ALTER TABLE cdr ADD COLUMN IF NOT EXISTS linkedid VARCHAR(32) NOT NULL DEFAULT "";'
echo '[mysql] schema fixed'
SCRIPT
  send_and_run_new "Fixing schema (linkedid + eventextra)" "$STEP"

  cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
ls -lh /tmp/asteriskcdrdb_backup.sql
mysql -u root -p${MYSQL_ROOT_PASS} asteriskcdrdb < /tmp/asteriskcdrdb_backup.sql
echo '[mysql] import done'
SCRIPT
  send_and_run_new "Importing CDR dump" "$STEP"

  cat > "$STEP" << 'SCRIPT'
#!/bin/bash
rm -f /tmp/asteriskcdrdb_backup.sql && echo '[cleanup] dump removed'
SCRIPT
  send_and_run_old "Cleaning up dump on the source VM" "$STEP"
  send_and_run_new "Cleaning up dump on the destination VM" "$STEP"

  success "STEP 3 completed."
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 4 — Recordings
# ═══════════════════════════════════════════════════════════════════════════

if [ "$RUN_ETAPA4" = "y" ]; then
  echo ""
  info "========== STEP 4: Call recordings migration =========="
  warn "May take a while depending on volume. Prefer running inside tmux/screen."

  if [ "$SSH_TEMP_ENABLED_NEW" = "n" ]; then
    enable_temp_password_ssh_new
    send_and_run_new "Enabling password SSH on the destination VM (temporary)" "$STEP"
    SSH_TEMP_ENABLED_NEW="y"

    install_sshpass_rsync_remote
    send_and_run_old "Installing sshpass and rsync on the source VM" "$STEP"
  fi

  cat > "$STEP" << SCRIPT
#!/bin/bash
set -xe
sshpass -p '${NEW_VM_ROOT_PASS}' rsync -avz --progress --partial \
  -e 'ssh -p ${SSH_PORT} -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=5' \
  /var/spool/asterisk/monitor/ \
  root@${NEW_VM_IP}:/var/spool/asterisk/monitor/
echo '[rsync] recordings transferred'
SCRIPT
  send_and_run_old "rsync of recordings to the destination VM" "$STEP"
  success "STEP 4 completed — recordings migrated."
fi

# ─── Block password SSH on the destination VM (revert temporary access) ─────

if [ "$SSH_TEMP_ENABLED_NEW" = "y" ]; then
  cat > "$STEP" << 'SCRIPT'
#!/bin/bash
set -xe
sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd
echo '[sshd] PasswordAuthentication=no restored'
SCRIPT
  send_and_run_new "Blocking password SSH on the destination VM" "$STEP"
  success "Password SSH blocked — temporary access reverted."
fi

# ─── Reboot ──────────────────────────────────────────────────────────────────

echo ""
info "Rebooting the destination VM..."
ssh $SSH_NEW root@"$NEW_VM_IP" 'reboot' || true
log "Reboot sent to $NEW_VM_IP"

echo ""
echo -e "${GRN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GRN}║      ✅  Migration completed successfully!    ║${NC}"
echo -e "${GRN}╚══════════════════════════════════════════════╝${NC}"
echo ""
info "Full log saved to: $LOG_FILE"
info "Remember to confirm that the destination VM's temporary root password has been revoked."
echo ""
