"""使用回环 WebDAV 验证断网、恢复和真实重试间隔。文件控制仅限测试进程。"""
import importlib.util
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("dav_fixture", root / "services/local/server.py")
dav = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dav)
directory = Path(sys.argv[1])
class FaultHandler(dav.Handler):
    def do_PROPFIND(self):
        if (directory / "offline").exists():
            self.body()
            self.send(503)
            return
        super().do_PROPFIND()

service = dav.StorageServer(("127.0.0.1", 0), directory / "remote", "qa", "synthetic-dav-secret", "synthetic-cloud-token")
service.RequestHandlerClass = FaultHandler
(directory / "port").write_text(str(service.server_port))
service.serve_forever()
