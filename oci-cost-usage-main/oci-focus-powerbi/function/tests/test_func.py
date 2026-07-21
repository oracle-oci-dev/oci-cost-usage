import gzip
import importlib.util
import pathlib
import sys
import tempfile
import types
import unittest
from datetime import date


# The pure helper tests do not need OCI or the FDK installed locally. The
# deployed Function installs both from requirements.txt.
oci_stub = types.ModuleType("oci")
oci_stub.exceptions = types.SimpleNamespace(ServiceError=Exception)
oci_stub.pagination = types.SimpleNamespace()
oci_stub.object_storage = types.SimpleNamespace()
sys.modules.setdefault("oci", oci_stub)
fdk_stub = types.ModuleType("fdk")
fdk_stub.response = types.SimpleNamespace(Response=lambda *args, **kwargs: None)
sys.modules.setdefault("fdk", fdk_stub)

MODULE = pathlib.Path(__file__).parents[1] / "func.py"
spec = importlib.util.spec_from_file_location("func", MODULE)
func = importlib.util.module_from_spec(spec)
spec.loader.exec_module(func)


class FocusExporterTests(unittest.TestCase):
    def test_requested_dates_default_is_two_day_lookback(self):
        original = func.utc_now
        func.utc_now = lambda: __import__("datetime").datetime(2026, 7, 20, tzinfo=__import__("datetime").timezone.utc)
        try:
            self.assertEqual(func.requested_dates({}), [date(2026, 7, 18), date(2026, 7, 19)])
        finally:
            func.utc_now = original

    def test_decompress_validates_focus_header_and_streams_csv(self):
        with tempfile.TemporaryDirectory() as directory:
            gz_path = pathlib.Path(directory) / "report.csv.gz"
            csv_path = pathlib.Path(directory) / "report.csv"
            with gzip.open(gz_path, "wb") as stream:
                stream.write(b"BillingAccountId,BilledCost,ChargePeriodStart\nacct,1.23,2026-07-19T00:00:00Z\n")
            size, columns = func.decompress_and_validate(str(gz_path), str(csv_path))
            self.assertGreater(size, 0)
            self.assertIn("BilledCost", columns)
            self.assertIn("acct,1.23", csv_path.read_text())

    def test_decompress_rejects_non_focus_csv(self):
        with tempfile.TemporaryDirectory() as directory:
            gz_path = pathlib.Path(directory) / "bad.csv.gz"
            with gzip.open(gz_path, "wb") as stream:
                stream.write(b"wrong,columns\n1,2\n")
            with self.assertRaises(func.FocusExportError):
                func.decompress_and_validate(str(gz_path), str(pathlib.Path(directory) / "bad.csv"))


if __name__ == "__main__":
    unittest.main()
