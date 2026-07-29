#!/usr/bin/env python3
"""Tests for the lexical XCTest inventory guard."""

from __future__ import annotations

import importlib.util
import unittest


SPEC = importlib.util.spec_from_file_location("test_inventory_script", "Scripts/test-inventory.py")
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class InventoryTests(unittest.TestCase):
    def test_masks_comments_and_strings_but_keeps_code(self) -> None:
        source = '''
        // func testComment() {}
        let fixture = "func testString() {}"
        /* func testBlock() {} */
        func testReal() {}
        '''
        masked = MODULE._mask_comments_and_strings(source)
        self.assertEqual(MODULE.TEST_METHOD.findall(masked), ["testReal"])

    def test_masks_nested_block_comments_and_multiline_strings(self) -> None:
        source = '/* outer /* func testNested() {} */ end */\n"""func testMultiline() {}"""\nfunc testReal() {}'
        masked = MODULE._mask_comments_and_strings(source)
        self.assertEqual(MODULE.TEST_METHOD.findall(masked), ["testReal"])


if __name__ == "__main__":
    unittest.main()
