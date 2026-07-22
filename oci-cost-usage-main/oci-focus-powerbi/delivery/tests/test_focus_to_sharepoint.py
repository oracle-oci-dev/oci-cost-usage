import importlib.util
import io
import json
import pathlib
import sys
import tempfile
import types
import unittest


oci_stub = types.ModuleType("oci")
oci_stub.object_storage = types.SimpleNamespace(models=types.SimpleNamespace())
sys.modules.setdefault("oci", oci_stub)
fdk_stub = types.ModuleType("fdk")
fdk_stub.response = types.SimpleNamespace(Response=lambda *args, **kwargs: None)
sys.modules.setdefault("fdk", fdk_stub)


MODULE = pathlib.Path(__file__).parents[1] / "focus_to_sharepoint.py"
spec = importlib.util.spec_from_file_location("focus_to_sharepoint", MODULE)
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class CombineCsvTests(unittest.TestCase):
    def test_combines_multiple_matching_partitions_with_provenance(self):
        objects = [types.SimpleNamespace(name="focus/csv/2026/07/01.csv"), types.SimpleNamespace(name="focus/csv/2026/07/02.csv")]

        class Client:
            def get_object(self, namespace, bucket, name):
                amount = "1" if name.endswith("01.csv") else "2"
                content = f"BillingAccountId,BilledCost\nacct,{amount}\n".encode()
                return types.SimpleNamespace(data=types.SimpleNamespace(content=content))

        with tempfile.TemporaryDirectory() as directory:
            output_path = pathlib.Path(directory) / "combined.csv"
            rows = publisher.combine_csvs(Client(), "namespace", "bucket", objects, str(output_path))
            output = output_path.read_text()
        self.assertEqual(output.splitlines()[0], "BillingAccountId,BilledCost,_source_object")
        self.assertEqual(len(output.splitlines()), 3)
        self.assertEqual(rows, 2)

    def test_completed_week_start_uses_previous_utc_week(self):
        self.assertEqual(publisher.completed_week_start(__import__("datetime").date(2026, 7, 22)), __import__("datetime").date(2026, 7, 13))

    def test_completed_day_objects_requires_a_complete_matching_manifest(self):
        usage_date = __import__("datetime").date(2026, 7, 13)

        class Client:
            def get_object(self, namespace, bucket, name):
                if name != "manifests/2026/07/13.json":
                    raise AssertionError(name)
                manifest = {"status": "complete", "usage_date": "2026-07-13"}
                return types.SimpleNamespace(data=types.SimpleNamespace(content=json.dumps(manifest).encode()))

            def list_objects(self, *args, **kwargs):
                raise AssertionError("The pagination stub should not call list_objects")

        client = Client()
        publisher.oci.pagination = types.SimpleNamespace(
            list_call_get_all_results=lambda *args, **kwargs: types.SimpleNamespace(
                data=types.SimpleNamespace(objects=[types.SimpleNamespace(name="focus/csv/2026/07/13/report.csv")])
            )
        )
        objects = publisher.completed_day_objects(client, "namespace", "bucket", usage_date)
        self.assertEqual([item.name for item in objects], ["focus/csv/2026/07/13/report.csv"])

    def test_existing_par_metadata_reuses_a_valid_stored_url(self):
        expires = (__import__("datetime").datetime.now(__import__("datetime").timezone.utc) + __import__("datetime").timedelta(days=30)).isoformat()
        metadata = {"url": "https://objectstorage.example/p/token", "object_name": publisher.CSV_OBJECT_NAME, "expires_at": expires}

        class Client:
            def get_object(self, namespace, bucket, name):
                self.requested_name = name
                return types.SimpleNamespace(data=types.SimpleNamespace(content=json.dumps(metadata).encode()))

        client = Client()
        result = publisher.existing_par_metadata(client, "namespace", "bucket")
        self.assertEqual(result["url"], metadata["url"])
        self.assertEqual(client.requested_name, publisher.PAR_OBJECT_NAME)

    def test_create_object_read_par_builds_powerbi_url(self):
        captured = {}
        original_models = getattr(publisher.oci.object_storage, "models", None)

        class Details:
            def __init__(self, **kwargs):
                captured.update(kwargs)
                self.name = kwargs["name"]

        class Client:
            base_client = types.SimpleNamespace(endpoint="https://objectstorage.us-ashburn-1.oraclecloud.com")

            def create_preauthenticated_request(self, namespace, bucket, details):
                self.namespace = namespace
                self.bucket = bucket
                self.details = details
                return types.SimpleNamespace(data=types.SimpleNamespace(access_uri="/p/token/n/ns/b/bucket/o/powerbi/file.csv", name=details.name, id="par-id"))

        try:
            publisher.oci.object_storage.models = types.SimpleNamespace(CreatePreauthenticatedRequestDetails=Details)
            result = publisher.create_object_read_par(Client(), "namespace", "bucket", 30)
        finally:
            if original_models is None:
                delattr(publisher.oci.object_storage, "models")
            else:
                publisher.oci.object_storage.models = original_models

        self.assertEqual(captured["access_type"], "ObjectRead")
        self.assertEqual(captured["object_name"], publisher.CSV_OBJECT_NAME)
        self.assertEqual(result["url"], "https://objectstorage.us-ashburn-1.oraclecloud.com/p/token/n/ns/b/bucket/o/powerbi/file.csv")

    def test_parse_request_rejects_invalid_json(self):
        with self.assertRaises(SystemExit):
            publisher.parse_request(io.BytesIO(b"not json"))

    def test_parse_request_defaults_empty_body_to_empty_dict(self):
        self.assertEqual(publisher.parse_request(None), {})
        self.assertEqual(publisher.parse_request(io.BytesIO(b"")), {})

    def test_handler_parses_week_start_and_returns_runs_manifest(self):
        captured = {}
        original_run, original_response = publisher.run, publisher.response.Response
        try:
            def fake_run(week_start, rotate_par):
                captured["week_start"] = week_start
                captured["rotate_par"] = rotate_par
                return {"powerbi_url": "https://example/par"}

            publisher.run = fake_run
            publisher.response.Response = lambda _ctx, response_data, **_kwargs: json.loads(response_data)
            result = publisher.handler(None, io.BytesIO(b'{"week_start":"2026-07-13","rotate_par":true}'))
        finally:
            publisher.run, publisher.response.Response = original_run, original_response

        self.assertEqual(captured["week_start"], __import__("datetime").date(2026, 7, 13))
        self.assertTrue(captured["rotate_par"])
        self.assertEqual(result["powerbi_url"], "https://example/par")

    def test_handler_returns_failed_status_on_error(self):
        original_run, original_response = publisher.run, publisher.response.Response
        try:
            def failing_run(week_start, rotate_par):
                raise RuntimeError("boom")

            publisher.run = failing_run
            publisher.response.Response = lambda _ctx, response_data, **_kwargs: json.loads(response_data)
            result = publisher.handler(None, io.BytesIO(b"{}"))
        finally:
            publisher.run, publisher.response.Response = original_run, original_response

        self.assertEqual(result["status"], "failed")
        self.assertIn("boom", result["error"])


if __name__ == "__main__":
    unittest.main()
