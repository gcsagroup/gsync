"""发布回执不能继承旧包的 UI 结果，也不能把零项或跳过算作通过。"""
import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from candidate_checks import checked_counts, ui_result, UI_CASES

class CandidateTests(unittest.TestCase):
    def test_zero_and_skipped(self):
        for text in ('Ran 0 tests in 0.0s\nOK','Ran 2 tests in 0.1s\nOK (skipped=1)'):
            with self.assertRaises(ValueError): checked_counts('python',text)

    def test_receipt_requires_same_app_and_extension(self):
        current = {p:[{'cdhash':'a'},{'cdhash':'b'}] for p in UI_CASES}
        receipt = {p:{'cdhashes':['a','b'],'observations':{k:{'status':'通过','observed':'测试观察'} for k in cases}} for p,cases in UI_CASES.items()}
        self.assertEqual(ui_result(receipt,current),'通过')
        receipt['mac']['cdhashes'][1]='different'
        self.assertNotEqual(ui_result(receipt,current),'通过')
        self.assertNotEqual(ui_result(None,current),'通过')
