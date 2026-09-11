import json
import sys
from pathlib import Path

import pytest

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests" / "fixtures"
sys.path.insert(0, str(ROOT / "backend"))


@pytest.fixture
def load_fixture():
    def load(name):
        return json.loads((FIXTURES / name).read_text())

    return load


@pytest.fixture
def config_dir(tmp_path, monkeypatch):
    path = tmp_path / "ytm-config"
    monkeypatch.setenv("YTM_CONFIG_DIR", str(path))
    return path
