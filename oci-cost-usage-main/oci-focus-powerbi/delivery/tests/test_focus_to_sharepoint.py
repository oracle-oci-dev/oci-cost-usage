import importlib.util
import json
import pathlib
import sys
import tempfile
import types
import unittest


sys.modules.setdefault("oci", types.ModuleType("oci"))


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


if __name__ == "__main__":
    unittest.main()
