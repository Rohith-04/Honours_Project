"""A simulator's zero exit code must never turn an error log into a PASS."""
import unittest
from check_uvm import check


class LogCheckerTests(unittest.TestCase):
    clean = "TEST gpio_smoke_test: PASS (4 checks)\nUVM_ERROR : 0\nUVM_FATAL : 0\n"

    def test_clean_log(self):
        check(self.clean, "gpio_smoke_test")

    def test_wrong_test_cannot_pass(self):
        with self.assertRaises(ValueError):
            check(self.clean, "gpio_pipeline_test")

    def test_uvm_error_despite_pass_banner(self):
        with self.assertRaises(ValueError):
            check(self.clean.replace("UVM_ERROR : 0", "UVM_ERROR : 1"), "gpio_smoke_test")

    def test_missing_uvm_summary(self):
        with self.assertRaises(ValueError):
            check("TEST gpio_smoke_test: PASS (4 checks)\n", "gpio_smoke_test")

    def test_assertion_error_despite_clean_summary(self):
        with self.assertRaises(ValueError):
            check("Error: assertion failed\n" + self.clean, "gpio_smoke_test")

    def test_fatal_after_pass(self):
        with self.assertRaises(ValueError):
            check(self.clean + "UVM_FATAL @ 50: failure\n", "gpio_smoke_test")

    def test_error_with_source_location_despite_clean_summary(self):
        with self.assertRaises(ValueError):
            check(self.clean + "UVM_ERROR driver.svh(42) @ 50: mismatch\n", "gpio_smoke_test")


if __name__ == "__main__":
    unittest.main()
