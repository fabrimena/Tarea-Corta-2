#!/usr/bin/env bash

# ============================================
# Script de Restauración Automática
# Servidor: PC2 (Secundario)
# ============================================

DB_USER="backup_user"
DB_PASS="BackupPass123!"
DB_NAME="pedidos_db"
BACKUP_DIR="/home/vboxuser2/mysql_backups"
LOG_FILE="/home/vboxuser2/mysql_logs/restore.log"

# Función de logging
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_message "=========================================="
log_message "Iniciando proceso de restauración"

# Buscar el respaldo más reciente
LATEST_BACKUP=$(ls -t "${BACKUP_DIR}"/pedidos_backup_*.sql.gz 2>/dev/null | head -1)

if [ -z "$LATEST_BACKUP" ]; then
    log_message "ERROR: No se encontraron archivos de respaldo"
    exit 1
fi

log_message "Respaldo encontrado: $(basename $LATEST_BACKUP)"

# Descomprimir
log_message "Descomprimiendo archivo..."
gunzip -c "$LATEST_BACKUP" > "${BACKUP_DIR}/temp_restore.sql"

if [ $? -ne 0 ]; then
    log_message "ERROR: Fallo al descomprimir"
    exit 1
fi

# Crear la base de datos si no existe
log_message "Verificando base de datos..."
mysql -u"${DB_USER}" -p"${DB_PASS}" -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};" 2>> "$LOG_FILE"

# Restaurar
log_message "Restaurando base de datos..."
mysql -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" < "${BACKUP_DIR}/temp_restore.sql" 2>> "$LOG_FILE"

if [ $? -eq 0 ]; then
    log_message "Base de datos restaurada exitosamente"
    
    # Verificar cantidad de registros
    CLIENTES=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -se "SELECT COUNT(*) FROM Clientes;")
    PRODUCTOS=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -se "SELECT COUNT(*) FROM Productos;")
    PEDIDOS=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -se "SELECT COUNT(*) FROM Pedidos;")
    
    log_message "Registros restaurados - Clientes: $CLIENTES, Productos: $PRODUCTOS, Pedidos: $PEDIDOS"
else
    log_message "ERROR: Fallo en la restauración"
    exit 1
fi

# Limpiar archivo temporal
rm -f "${BACKUP_DIR}/temp_restore.sql"
# Limpiar archivos antiguos recibidos desde PC1
log_message "Limpiando respaldos antiguos desde PC1..."
find "${BACKUP_DIR}" -name "pedidos_backup_*.sql" -type f -delete 2>> "$LOG_FILE"

# Mantener solo los últimos 2 respaldos desde PC1
ls -t "${BACKUP_DIR}"/pedidos_backup_*.sql.gz 2>/dev/null | tail -n +3 | xargs -r rm -f

log_message "Limpieza de respaldos desde PC1 completada"
log_message "Restauración completada"
log_message "=========================================="
