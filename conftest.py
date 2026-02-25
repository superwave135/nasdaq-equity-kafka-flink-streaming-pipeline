"""
conftest.py — pytest configuration for the stock-streaming-pipeline project.

'lambda' is a Python reserved keyword and cannot be used as a module name.
Tests import handlers as `lambda_.producer.handler` etc., so we register
`lambda_` as a package alias whose __path__ points to the actual `lambda/`
directory, letting Python's normal file-based import find handler.py files.
"""
import sys
import types
from pathlib import Path

root = Path(__file__).parent
sys.path.insert(0, str(root))

# Register lambda_ package pointing to lambda/ directory
_lambda_pkg = types.ModuleType("lambda_")
_lambda_pkg.__path__ = [str(root / "lambda")]
_lambda_pkg.__package__ = "lambda_"
sys.modules["lambda_"] = _lambda_pkg

for _service in ["producer", "controller", "teardown", "status"]:
    _svc_pkg = types.ModuleType(f"lambda_.{_service}")
    _svc_pkg.__path__ = [str(root / "lambda" / _service)]
    _svc_pkg.__package__ = f"lambda_.{_service}"
    sys.modules[f"lambda_.{_service}"] = _svc_pkg
    setattr(_lambda_pkg, _service, _svc_pkg)
