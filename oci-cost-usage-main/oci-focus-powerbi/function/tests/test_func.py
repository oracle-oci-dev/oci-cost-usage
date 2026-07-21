import gzip
import io
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import types
import unittest
import zipfile
from datetime import date


# The pure helper tests do not need OCI or the FDK installed locally. The
# deployed Function installs both from requirements.txt.
oci_stub = types.ModuleType("oci")
oci_stub.exceptions = types.SimpleNamespace(ServiceError=Exception)
oci_stub.pagination = types.SimpleNamespace()
oci_stub.object_storage = types.SimpleNamespace(ObjectStorageClient=lambda **kwargs: None)
oci_stub.auth = types.SimpleNamespace(signers=types.SimpleNamespace(get_resource_principals_signer=lambda: None))
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

    def test_materialize_zip_extracts_and_validates_focus_csv(self):
        with tempfile.TemporaryDirectory() as directory:
            archive_path = pathlib.Path(directory) / "report.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("partition.csv", "BillingAccountId,BilledCost,ChargePeriodStart\nacct,1,2026-07-19T00:00:00Z\n")
            files = func.materialize_csvs(str(archive_path), archive_path.name, directory)
            self.assertEqual(files[0][0], "partition.csv")
            self.assertGreater(files[0][2], 0)

    def test_materialize_zip_rejects_unsafe_member_path(self):
        with tempfile.TemporaryDirectory() as directory:
            archive_path = pathlib.Path(directory) / "bad.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("../report.csv", "BillingAccountId,BilledCost,ChargePeriodStart\n")
            with self.assertRaises(func.FocusExportError):
                func.materialize_csvs(str(archive_path), archive_path.name, directory)

    def test_requested_force_requires_a_json_boolean(self):
        self.assertFalse(func.requested_force({}))
        self.assertTrue(func.requested_force({"force": True}))
        with self.assertRaises(func.FocusExportError):
            func.requested_force({"force": "false"})

    def test_handler_reports_an_unavailable_partition_as_pending(self):
        original = (func.list_source_objects, func.oci.auth.signers.get_resource_principals_signer,
                    func.oci.object_storage.ObjectStorageClient, func.response.Response, os.environ.get("TARGET_BUCKET"))
        try:
            func.list_source_objects = lambda *args: []
            func.oci.auth.signers.get_resource_principals_signer = lambda: types.SimpleNamespace(tenancy_id="source-bucket")
            func.oci.object_storage.ObjectStorageClient = lambda **kwargs: types.SimpleNamespace(get_namespace=lambda: types.SimpleNamespace(data="namespace"))
            func.response.Response = lambda _ctx, response_data, **_kwargs: json.loads(response_data)
            os.environ["TARGET_BUCKET"] = "target-bucket"
            result = func.handler(None, io.BytesIO(b'{"start_date":"2026-07-19","end_date":"2026-07-19"}'))
            self.assertEqual(result["pending_dates"], ["2026-07-19"])
            self.assertEqual(result["manifests"], [])
        finally:
            func.list_source_objects, func.oci.auth.signers.get_resource_principals_signer, func.oci.object_storage.ObjectStorageClient, func.response.Response, old_bucket = original
            if old_bucket is None:
                os.environ.pop("TARGET_BUCKET", None)
            else:
                os.environ["TARGET_BUCKET"] = old_bucket


if __name__ == "__main__":
    unittest.main()
