import importlib.util
import pathlib
import sys
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

        output = publisher.combine_csvs(Client(), "namespace", "bucket", objects).decode()
        self.assertEqual(output.splitlines()[0], "BillingAccountId,BilledCost,_source_object")
        self.assertEqual(len(output.splitlines()), 3)


if __name__ == "__main__":
    unittest.main()
