#!/usr/bin/env bash
# restore_from_secondary.sh
# PC1: solo restaura cuando existe restore_requested (pedida por PC2)

DB_USER="backup_user"
DB_PASS="BackupPass123!"
DB_NAME="pedidos_db"
BACKUP_DIR="/home/vboxuser1/mysql_backups_from_secondary"
LOG_FILE="/home/vboxuser1/mysql_logs/restore_from_secondary.log"
RESTORE_FLAG="${BACKUP_DIR}/restore_requested"
LAST_RESTORED_FILE="${BACKUP_DIR}/last_restored_id.txt"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

mkdir -p "$BACKUP_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

log_message "Iniciando check-restauracion (seguro)"

# Si no hay solicitud de restauracion, salimos
if [ ! -f "$RESTORE_FLAG" ]; then
    log_message "No existe restore_requested. Nada que hacer."
    exit 0
fi

# Esperar a que MySQL esté arriba
MYSQL_UP=0
for i in {1..10}; do
    nc -z -w 2 127.0.0.1 3306 > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        MYSQL_UP=1
        break
    fi
    log_message "Esperando MySQL local... intento $i"
    sleep 1
done

if [ "$MYSQL_UP" -ne 1 ]; then
    log_message "MySQL no está disponible localmente. Abortando restauración por ahora."
    exit 1
fi

# Buscar el backup más reciente en el directorio
LATEST_BACKUP=$(ls -t "${BACKUP_DIR}"/pedidos_backup_from_secondary_*.sql.gz 2>/dev/null | head -1)
if [ -z "$LATEST_BACKUP" ]; then
    log_message "ERROR: No se encontró backup desde PC2, pero existe restore_requested. Abortando."
    # limpiar flag para evitar loop? mejor no; para investigar manualmente
    exit 1
fi

log_message "Restaurando desde: $(basename "$LATEST_BACKUP")"

# Descomprimir y restaurar en caliente
gunzip -c "$LATEST_BACKUP" > "${BACKUP_DIR}/temp_restore.sql"
if [ $? -ne 0 ]; then
    log_message "ERROR: Falló descompresión"
    exit 1
fi

# Obtener MAX(id) del dump antes de ejecutar. En su lugar, restauramos y luego comprobamos conteo.
mysql -u"${DB_USER}" -p"${DB_PASS}" -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};" 2>> "$LOG_FILE"

mysql -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" < "${BACKUP_DIR}/temp_restore.sql" 2>> "$LOG_FILE"
if [ $? -ne 0 ]; then
    log_message "ERROR: Falló la restauración"
    rm -f "${BACKUP_DIR}/temp_restore.sql"
    exit 1
fi

# Comprobar conteo de Pedidos y actualizar last_restored_id
PEDIDOS=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -se "SELECT COALESCE(MAX(id),0) FROM Pedidos;")
echo "${PEDIDOS}" > "${LAST_RESTORED_FILE}"

# Borrar temp y flag
rm -f "${BACKUP_DIR}/temp_restore.sql"
rm -f "$RESTORE_FLAG"

log_message "Restauración completada. MAX(id) en restauración: ${PEDIDOS}"
log_message "Borrado restore_requested y actualizado last_restored_id."

# Limpieza de archivos
# Mantener solo los últimos 2 backups recibidos desde PC2
ls -t "${BACKUP_DIR}"/pedidos_backup_from_secondary_*.sql.gz 2>/dev/null \
    | tail -n +3 | xargs -r rm -f

exit 0
