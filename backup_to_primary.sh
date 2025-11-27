#!/usr/bin/env bash
# backup_to_primary.sh
# PC2 -> PC1, envía y solicita restauración SOLO si hay writes nuevos en PC2

DB_USER="backup_user"
DB_PASS="BackupPass123!"
DB_NAME="pedidos_db"
BACKUP_DIR="/home/vboxuser2/mysql_backups"
LOG_FILE="/home/vboxuser2/mysql_logs/backup_to_primary.log"
REMOTE_USER="vboxuser1"
REMOTE_HOST="192.168.18.193"
REMOTE_DIR="/home/vboxuser1/mysql_backups_from_secondary"
LAST_SENT_FILE="${BACKUP_DIR}/last_sent_id.txt"
RETENTION_DAYS=7

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="pedidos_backup_from_secondary_${TIMESTAMP}.sql"
COMPRESSED_FILE="${BACKUP_FILE}.gz"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Asegurar directorio
mkdir -p "$BACKUP_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

# 1) Comprobar si PC1 es accesible (ping + puerto MySQL)
ping -c 1 -W 2 "$REMOTE_HOST" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    log_message "PC1 no accesible (ping falló). Solo crear dump local."
    PC1_UP=0
else
    nc -z -w 2 "$REMOTE_HOST" 3306 > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_message "PC1 accesible pero MySQL en PC1 no responde."
        PC1_UP=0
    else
        PC1_UP=1
    fi
fi

# 2) Calcular MAX(id) actual en PC2
CURRENT_MAX_ID=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -se "SELECT COALESCE(MAX(id),0) FROM Pedidos;")
if [ -z "$CURRENT_MAX_ID" ]; then
    log_message "ERROR: No se pudo obtener MAX(id) de Pedidos en PC2"
    exit 1
fi

# 3) Leer last_sent_id (si existe)
if [ -f "$LAST_SENT_FILE" ]; then
    LAST_SENT_ID=$(cat "$LAST_SENT_FILE")
else
    LAST_SENT_ID=0
fi

log_message "MAX(id) local: ${CURRENT_MAX_ID} | last_sent_id: ${LAST_SENT_ID} | PC1_up: ${PC1_UP}"

# Siempre crear dump local (para historial)
log_message "Creando dump local de ${DB_NAME}..."
mysqldump -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" > "${BACKUP_DIR}/${BACKUP_FILE}" 2>> "$LOG_FILE"
if [ $? -ne 0 ]; then
    log_message "ERROR: fallo al crear dump local"
    exit 1
fi
gzip -f "${BACKUP_DIR}/${BACKUP_FILE}"

# Si PC1 está arriba y hay nuevos registros en PC2 (CURRENT_MAX_ID > LAST_SENT_ID) => enviar
if [ "$PC1_UP" -eq 1 ] && [ "$CURRENT_MAX_ID" -gt "$LAST_SENT_ID" ]; then
    log_message "Nuevos pedidos detectados y PC1 disponible. Enviando dump a PC1..."
    scp "${BACKUP_DIR}/${COMPRESSED_FILE}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/" 2>> "$LOG_FILE"
    if [ $? -ne 0 ]; then
        log_message "ERROR: Fallo en scp hacia PC1"
        exit 1
    fi

    # Crear archivo trigger remoto para pedir restauración
    ssh "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p ${REMOTE_DIR} && touch ${REMOTE_DIR}/restore_requested" 2>> "$LOG_FILE"
    if [ $? -ne 0 ]; then
        log_message "ERROR: No se pudo crear restore_requested en PC1"
        exit 1
    fi

    # Actualizar last_sent_id (local y envío opcional a PC1)
    echo "$CURRENT_MAX_ID" > "$LAST_SENT_FILE"
    ssh "${REMOTE_USER}@${REMOTE_HOST}" "echo $CURRENT_MAX_ID > ${REMOTE_DIR}/last_sent_id_from_secondary.txt" 2>> "$LOG_FILE" || true

    log_message "Dump enviado y restore_requested creado en PC1. last_sent_id actualizado a ${CURRENT_MAX_ID}."
else
    log_message "No se envía a PC1: condición no cumplida (PC1_up=${PC1_UP}, CURRENT_MAX_ID>${LAST_SENT_ID}?)"
fi

# Limpieza local de backups antiguos
log_message "Limpiando backups locales > ${RETENTION_DAYS} días..."
find "${BACKUP_DIR}" -name "pedidos_backup_from_secondary_*.sql.gz" -type f -mtime +$RETENTION_DAYS -delete 2>> "$LOG_FILE"

log_message "Backup bidireccional (PC2->PC1) finalizado"
