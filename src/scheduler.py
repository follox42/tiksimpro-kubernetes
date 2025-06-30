# ==========================================
# scheduler.py - Scheduler simple
# ==========================================
import os
import time
import logging
import schedule
import subprocess
from datetime import datetime
from src.core.config import Config

# Configuration du logging
logging.basicConfig(
    level=getattr(logging, os.getenv('LOG_LEVEL', 'INFO')),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler('/app/logs/scheduler.log', encoding='utf-8')
    ]
)
logger = logging.getLogger("TikSimPro.Scheduler")

class SimpleScheduler:
    def __init__(self, config_path="config.json"):
        self.config = Config(config_path).load_config()
        self.running = True
        
    def run_bot_for_platform(self, platform):
        """Exécute le bot pour une plateforme spécifique"""
        try:
            logger.info(f"Démarrage du bot pour {platform}")
            
            cmd = [
                "python", "main.py", 
                "--config", "config.json",
                "--publish",
                "--publisher", platform
            ]
            
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
            
            if result.returncode == 0:
                logger.info(f"Publication {platform} réussie")
            else:
                logger.error(f"Échec publication {platform}: {result.stderr}")
                
        except subprocess.TimeoutExpired:
            logger.error(f"Timeout lors de la publication {platform}")
        except Exception as e:
            logger.error(f"Erreur lors de la publication {platform}: {e}")
    
    def setup_schedules(self):
        """Configure les planifications"""
        publishers = self.config.get("publishers", {})
        
        for platform, config in publishers.items():
            if config.get("enabled") and "schedule" in config:
                cron_expr = config["schedule"]["cron"]
                
                # Conversion cron simple vers schedule
                if "*/6" in cron_expr and "* * *" in cron_expr:
                    # Toutes les 6 heures
                    schedule.every(6).hours.do(self.run_bot_for_platform, platform)
                    logger.info(f"Planification {platform}: toutes les 6 heures")
                    
                elif "10 * * *" in cron_expr:
                    # Tous les jours à 10h
                    schedule.every().day.at("10:00").do(self.run_bot_for_platform, platform)
                    logger.info(f"Planification {platform}: tous les jours à 10h")
    
    def run(self):
        """Lance le scheduler"""
        logger.info("Démarrage du scheduler TikSimPro")
        self.setup_schedules()
        
        while self.running:
            try:
                schedule.run_pending()
                time.sleep(60)  # Vérification toutes les minutes
            except KeyboardInterrupt:
                logger.info("Arrêt du scheduler demandé")
                self.running = False
            except Exception as e:
                logger.error(f"Erreur dans le scheduler: {e}")
                time.sleep(300)  # Pause de 5 minutes en cas d'erreur

if __name__ == "__main__":
    scheduler = SimpleScheduler()
    scheduler.run()