#!/usr/bin/env bash

# ============================================
# Script de Respaldo Automático - Dump Shipping
# Servidor: PC1 (Principal)
# Destino: PC2 (Secundario)
# ============================================

# Variables de configuración
DB_USER="backup_user"
DB_PASS="BackupPass123!"
DB_NAME="pedidos_db"
BACKUP_DIR="/home/vboxuser1/mysql_backups"
LOG_FILE="/home/vboxuser1/mysql_logs/backup.log"
REMOTE_USER="vboxuser2"
REMOTE_HOST="192.168.18.192"
REMOTE_DIR="/home/vboxuser2/mysql_backups"
RETENTION_DAYS=7

# Timestamp para nombre del archivo
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="pedidos_backup_${TIMESTAMP}.sql"
COMPRESSED_FILE="${BACKUP_FILE}.gz"

# Función de logging
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Inicio del proceso
log_message "=========================================="
log_message "Iniciando respaldo de base de datos"

# 1. Crear dump de la base de datos
log_message "Creando dump de ${DB_NAME}..."
mysqldump -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" > "${BACKUP_DIR}/${BACKUP_FILE}" 2>> "$LOG_FILE"

if [ $? -eq 0 ]; then
    log_message "Dump creado exitosamente: ${BACKUP_FILE}"
else
    log_message "ERROR: Fallo al crear el dump"
    exit 1
fi

# 2. Comprimir el archivo
log_message "Comprimiendo archivo..."
gzip "${BACKUP_DIR}/${BACKUP_FILE}"

if [ $? -eq 0 ]; then
    log_message "Archivo comprimido: ${COMPRESSED_FILE}"
else
    log_message "ERROR: Fallo al comprimir"
    exit 1
fi

# 3. Transferir a PC2 usando SCP
log_message "Transfiriendo a servidor secundario (${REMOTE_HOST})..."
scp "${BACKUP_DIR}/${COMPRESSED_FILE}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/" 2>> "$LOG_FILE"

if [ $? -eq 0 ]; then
    log_message "Transferencia completada exitosamente"
else
    log_message "ERROR: Fallo en la transferencia"
    exit 1
fi

# 4. Limpiar archivos antiguos 
# Mantener solo los últimos 2 respaldos más recientes
find "${BACKUP_DIR}" -name "pedidos_backup_*.sql" -type f -delete
ls -t "${BACKUP_DIR}"/pedidos_backup_*.sql.gz 2>/dev/null | tail -n +3 | xargs -r rm -f

log_message "Limpieza completada"
# 5. Calcular tamaño del respaldo
BACKUP_SIZE=$(du -h "${BACKUP_DIR}/${COMPRESSED_FILE}" | cut -f1)
log_message "Tamaño del respaldo: ${BACKUP_SIZE}"

log_message "Respaldo completado exitosamente"
log_message "=========================================="
