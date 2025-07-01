from core.config import Config  # fonctionne si PYTHONPATH=src

def test_config_loads():
    cfg = Config.load()
    assert isinstance(cfg, dict)
