#!/usr/bin/env python3
"""
Cliente Python con Failover Automático + Reconexión al Primario
Tarea Corta 2 - CE-3101 Bases de Datos
Sistema de Pedidos con detección de caídas, conmutación y retorno automático
"""

import mysql.connector
from mysql.connector import Error
import time
import random
from datetime import datetime
import sys
import threading

class DatabaseFailoverClient:
    def __init__(self, primary_config, secondary_config, retry_policy, enable_auto_return=True):
        """
        Inicializa el cliente con failover y auto-retorno
        
        Args:
            primary_config: Configuración del servidor principal (PC1)
            secondary_config: Configuración del servidor secundario (PC2)
            retry_policy: {'max_retries': int, 'retry_delay': int}
            enable_auto_return: Si True, intenta volver al primario automáticamente
        """
        self.primary_config = primary_config
        self.secondary_config = secondary_config
        self.retry_policy = retry_policy
        self.enable_auto_return = enable_auto_return
        
        self.current_server = 'primary'
        self.connection = None
        self.cursor = None
        
        # Métricas
        self.total_writes = 0
        self.total_reads = 0
        self.failed_writes = 0
        self.failed_reads = 0
        self.downtime_start = None
        self.total_downtime = 0
        self.failover_count = 0
        self.return_to_primary_count = 0
        
        # Control de auto-retorno
        self.check_primary_interval = 10  # Cada 10 segundos verificar si PC1 volvió
        self.last_primary_check = time.time()
        
        # Log
        self.log_file = f"failover_log_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt"
        
    def log(self, message):
        """Registra mensajes en consola y archivo"""
        timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        log_message = f"[{timestamp}] {message}"
        print(log_message)
        
        with open(self.log_file, 'a') as f:
            f.write(log_message + '\n')
    
    def connect(self, config):
        """Intenta conectarse a un servidor"""
        try:
            connection = mysql.connector.connect(**config)
            if connection.is_connected():
                return connection
        except Error as e:
            return None
        return None
    
    def check_primary_available(self):
        """Verifica si el servidor primario está disponible"""
        try:
            test_conn = self.connect(self.primary_config)
            if test_conn:
                test_conn.close()
                return True
        except:
            pass
        return False
    
    def try_return_to_primary(self):
        """Intenta reconectar al servidor primario si estamos en secundario"""
        if self.current_server != 'secondary':
            return False
        
        # Solo verificar cada cierto intervalo
        current_time = time.time()
        if current_time - self.last_primary_check < self.check_primary_interval:
            return False
        
        self.last_primary_check = current_time
        
        self.log("VERIFICANDO DISPONIBILIDAD DEL SERVIDOR PRIMARIO...")

        
        if self.check_primary_available():
            self.log("Servidor primario DISPONIBLE - Iniciando retorno...")
            
            # Intentar conectar
            connection = self.connect(self.primary_config)
            if connection:
                # Cerrar conexión al secundario
                if self.connection:
                    try:
                        self.cursor.close()
                        self.connection.close()
                    except:
                        pass
                
                self.connection = connection
                self.cursor = self.connection.cursor(buffered=True)
                self.current_server = 'primary'
                self.return_to_primary_count += 1
                
                self.log("RETORNO EXITOSO AL SERVIDOR PRIMARIO")
                self.log(f"Ahora operando en PC1 ({self.primary_config['host']})")
                self.log(f"Total de retornos al primario: {self.return_to_primary_count}")

                return True
        
        return False
    
    def initialize_connection(self):
        """Establece la conexión inicial al servidor primary"""
        self.log("Iniciando cliente con failover automático + auto-retorno")
        self.log(f"Servidor primario: {self.primary_config['host']}")
        self.log(f"Servidor secundario: {self.secondary_config['host']}")
        self.log(f"Política de reintentos: {self.retry_policy['max_retries']} intentos, {self.retry_policy['retry_delay']}s entre intentos")
        if self.enable_auto_return:
            self.log(f"Auto-retorno al primario: ACTIVADO (verificación cada {self.check_primary_interval}s)")
        
        self.connection = self.connect(self.primary_config)
        if self.connection:
            self.cursor = self.connection.cursor(buffered=True)
            self.current_server = 'primary'
            self.log(f"Conectado al servidor PRIMARIO ({self.primary_config['host']})")
            return True
        else:
            self.log("No se pudo conectar al servidor primario")
            return self.try_failover()
    
    def try_failover(self):
        """Intenta conmutar al servidor secundario"""
        self.log("INICIANDO PROCESO DE FAILOVER")
        
        retry_count = 0
        max_retries = self.retry_policy['max_retries']
        retry_delay = self.retry_policy['retry_delay']
        
        # Marcar inicio del downtime
        if self.downtime_start is None:
            self.downtime_start = time.time()
        
        while retry_count < max_retries:
            retry_count += 1
            self.log(f"Intento {retry_count}/{max_retries} - Intentando reconectar al servidor primario...")
            
            connection = self.connect(self.primary_config)
            if connection:
                self.connection = connection
                self.cursor = self.connection.cursor(buffered=True)
                self.current_server = 'primary'
                
                # Calcular downtime
                if self.downtime_start:
                    downtime = time.time() - self.downtime_start
                    self.total_downtime += downtime
                    self.log(f"Reconectado al servidor PRIMARIO después de {downtime:.2f} segundos")
                    self.downtime_start = None
                
                return True
            
            self.log(f"Intento {retry_count} fallido")
            
            if retry_count < max_retries:
                self.log(f"Esperando {retry_delay} segundos antes del siguiente intento...")
                time.sleep(retry_delay)
        
        # Todos los reintentos fallaron, conmutar a secundario
        self.log(f"TODOS LOS REINTENTOS FALLARON ({max_retries} intentos)")
        self.log("CONMUTANDO A SERVIDOR SECUNDARIO (FAILOVER)")
        
        connection = self.connect(self.secondary_config)
        if connection:
            self.connection = connection
            self.cursor = self.connection.cursor(buffered=True)
            self.current_server = 'secondary'
            self.failover_count += 1
            
            # Calcular downtime total
            if self.downtime_start:
                downtime = time.time() - self.downtime_start
                self.total_downtime += downtime
                self.log(f"FAILOVER EXITOSO - Conectado al servidor SECUNDARIO ({self.secondary_config['host']})")
                self.log(f"Downtime total: {downtime:.2f} segundos")
                self.log(f"Total de reintentos realizados: {retry_count}")
                self.downtime_start = None
            
            return True
        else:
            self.log("FAILOVER FALLIDO - No se pudo conectar al servidor secundario")
            self.log("SISTEMA SIN DISPONIBILIDAD")
            return False
    
    def execute_write(self):
        """Ejecuta una operación de escritura (INSERT en Pedidos)"""
        try:
            # Obtener un cliente aleatorio
            self.cursor.execute("SELECT id FROM Clientes ORDER BY RAND() LIMIT 1")
            cliente = self.cursor.fetchone()
            
            # Obtener un producto aleatorio
            self.cursor.execute("SELECT id FROM Productos ORDER BY RAND() LIMIT 1")
            producto = self.cursor.fetchone()
            
            if cliente and producto:
                nota = f"Pedido automático #{self.total_writes + 1}"
                query = """
                    INSERT INTO Pedidos (cliente_id, producto_id, nota)
                    VALUES (%s, %s, %s)
                """
                self.cursor.execute(query, (cliente[0], producto[0], nota))
                self.connection.commit()
                
                self.total_writes += 1
                self.log(f"WRITE #{self.total_writes} - Pedido insertado (Cliente: {cliente[0]}, Producto: {producto[0]}) en servidor {self.current_server.upper()}")
                return True
            
        except Error as e:
            self.failed_writes += 1
            self.log(f"WRITE FAILED - Error: {e}")
            
            # Intentar failover
            if self.try_failover():
                # Reintentar la escritura después del failover
                return self.execute_write()
            return False
        
        return False
    
    def execute_read(self):
        """Ejecuta operaciones de lectura"""
        try:
            # Leer estadísticas
            self.cursor.execute("SELECT COUNT(*) FROM Pedidos")
            pedidos_count = self.cursor.fetchone()[0]
            
            self.cursor.execute("SELECT COUNT(*) FROM Clientes")
            clientes_count = self.cursor.fetchone()[0]
            
            self.cursor.execute("SELECT COUNT(*) FROM Productos")
            productos_count = self.cursor.fetchone()[0]
            
            self.total_reads += 1
            self.log(f"READ #{self.total_reads} - Stats: {pedidos_count} pedidos, {clientes_count} clientes, {productos_count} productos - Servidor: {self.current_server.upper()}")
            return True
            
        except Error as e:
            self.failed_reads += 1
            self.log(f"READ FAILED - Error: {e}")
            
            # Intentar failover
            if self.try_failover():
                return self.execute_read()
            return False
    
    def run(self, duration_seconds=300):
        """
        Ejecuta el cliente durante un tiempo determinado
        
        Args:
            duration_seconds: Duración de la prueba en segundos (default: 5 minutos)
        """
        if not self.initialize_connection():
            self.log("No se pudo establecer conexión inicial. Terminando.")
            return
        
        self.log(f"\n Iniciando operaciones continuas por {duration_seconds} segundos...")
        self.log("Escrituras cada 5 segundos | Lecturas cada 2 segundos")
        if self.enable_auto_return:
            self.log(f"Verificación de retorno al primario cada {self.check_primary_interval} segundos")
        
        start_time = time.time()
        last_write_time = start_time
        last_read_time = start_time
        
        try:
            while (time.time() - start_time) < duration_seconds:
                current_time = time.time()
                
                # Verificar si debemos intentar retornar al primario
                if self.enable_auto_return and self.current_server == 'secondary':
                    self.try_return_to_primary()
                
                # Escritura cada 5 segundos
                if current_time - last_write_time >= 5:
                    self.execute_write()
                    last_write_time = current_time
                
                # Lectura cada 2 segundos
                if current_time - last_read_time >= 2:
                    self.execute_read()
                    last_read_time = current_time
                
                time.sleep(0.1)  # Sleep corto para no saturar CPU
                
        except KeyboardInterrupt:
            self.log("\n Prueba interrumpida por el usuario")
        
        self.print_final_report()
    
    def print_final_report(self):
        """Imprime el reporte final de la prueba"""
        self.log(f"Total de escrituras exitosas: {self.total_writes}")
        self.log(f"Total de lecturas exitosas: {self.total_reads}")
        self.log(f"Escrituras fallidas: {self.failed_writes}")
        self.log(f"Lecturas fallidas: {self.failed_reads}")
        self.log(f"Número de failovers: {self.failover_count}")
        self.log(f"Retornos al servidor primario: {self.return_to_primary_count}")
        self.log(f"Downtime total acumulado: {self.total_downtime:.2f} segundos")
        self.log(f"Servidor final activo: {self.current_server.upper()}")
        self.log(f"Log guardado en: {self.log_file}")
        
        if self.connection and self.connection.is_connected():
            self.cursor.close()
            self.connection.close()
            self.log("Conexión cerrada correctamente")


def main():
    """Función principal"""
    
    # Configuración del servidor PRIMARIO (PC1)
    primary_config = {
        'host': '192.168.18.193',
        'database': 'pedidos_db',
        'user': 'backup_user',
        'password': 'BackupPass123!',
        'port': 3306
    }
    
    # Configuración del servidor SECUNDARIO (PC2)
    secondary_config = {
        'host': '192.168.18.192',
        'database': 'pedidos_db',
        'user': 'backup_user',
        'password': 'BackupPass123!',
        'port': 3306
    }
    
    # Política de reintentos
    # Prueba 1: Reintentos rápidos
    retry_policy_fast = {
        'max_retries': 5,
        'retry_delay': 2  # 2 segundos entre intentos
    }
    
    # Prueba 2: Reintento lento
    retry_policy_slow = {
        'max_retries': 1,
        'retry_delay': 10  # 10 segundos
    }
    
    # SELECCIONAR LA POLÍTICA AQUÍ
    print("\n" + "=" * 60)
    print("CLIENTE FAILOVER - DUMP SHIPPING CON AUTO-RETORNO")
    print("=" * 60)
    print("\n Seleccione la política de reintentos:")
    print("1. Rápida: 5 reintentos con 2 segundos de delay")
    print("2. Lenta: 1 reintento con 10 segundos de delay")
    
    choice = input("\n Opción (1 o 2): ").strip()
    
    if choice == '2':
        retry_policy = retry_policy_slow
        print("\n Política LENTA seleccionada")
    else:
        retry_policy = retry_policy_fast
        print("\n Política RÁPIDA seleccionada")
    
    # Habilitar auto-retorno al primario
    enable_auto_return = input("\n ¿Habilitar retorno automático al primario? (s/n, default: s): ").strip().lower()
    enable_auto_return = enable_auto_return != 'n'
    
    if enable_auto_return:
        print("Auto-retorno al primario: ACTIVADO")
    else:
        print("Auto-retorno al primario: DESACTIVADO")
    
    # Duración de la prueba
    duration = int(input("\n Duración de la prueba en segundos (default 300): ").strip() or "300")
    
    # Crear y ejecutar cliente
    client = DatabaseFailoverClient(primary_config, secondary_config, retry_policy, enable_auto_return)
    
    print("\n Simular caida del servidor:")
    print("1. El cliente comenzará a escribir y leer de la base de datos")
    print("2. Durante la ejecución, detenga MySQL en PC1 con:")
    print("   sudo systemctl stop mysql")
    print("3. Observe el proceso de failover a PC2")
    print("4. Luego reinicie MySQL en PC1 con:")
    print("   sudo systemctl start mysql")
    print("\n Presione Enter para comenzar...")
    input()
    
    client.run(duration)


if __name__ == "__main__":
    main()
