"""Regression tests for p58_sanitize (synthetic values only)."""

import json
import pathlib
import sys
import unittest

VALIDATION = pathlib.Path(__file__).resolve().parents[1] / "matlab" / "validation" / "phase58"
sys.path.insert(0, str(VALIDATION))

import p58_sanitize as sanitize  # noqa: E402

FAKE_KEY = "FAKE-SESSION-KEY-0123456789ABCDEF"
FAKE_UUID = "11111111-2222-3333-4444-555555555555"
FAKE_HEX = "0123456789abcdef" * 4
FAKE_BEARER = "FAKEBEARERTOKEN0123456789"
FAKE_ARGV = "FAKEARGVTOKEN0123456789"


class SanitizeShapesTest(unittest.TestCase):
    def assert_clean(self, source, *secrets):
        clean, count = sanitize.sanitize_text(source)
        for secret in secrets:
            self.assertNotIn(secret, clean)
        self.assertGreaterEqual(count, len(secrets))
        return clean

    def test_plain_json_field(self):
        clean = self.assert_clean('{"apiKey": "%s", "port": 47823}' % FAKE_KEY, FAKE_KEY)
        self.assertIn("47823", clean)
        self.assertNotIn("apiKey", clean.lower())

    def test_escaped_and_nested_json_field(self):
        escaped = '{\\"apiKey\\": \\"%s\\"}' % FAKE_KEY
        self.assert_clean(escaped, FAKE_KEY)
        doubly = '{"output": "{\\"apiKey\\": \\"%s\\"}"}' % FAKE_KEY
        self.assert_clean(doubly, FAKE_KEY)

    def test_x_api_key_header(self):
        self.assert_clean("x-api-key: %s" % FAKE_KEY, FAKE_KEY)

    def test_authorization_bearer_and_basic(self):
        source = "Authorization: Bearer %s\nAuthorization: Basic %s" % (FAKE_BEARER, FAKE_BEARER)
        clean = self.assert_clean(source, FAKE_BEARER)
        self.assertIn("Authorization", clean)

    def test_api_key_argv_forms(self):
        source = "tool --api-key %s --api-key=%s --other=ok" % (FAKE_ARGV, FAKE_ARGV)
        clean = self.assert_clean(source, FAKE_ARGV)
        self.assertIn("--other=ok", clean)

    def test_bare_uuid_and_long_hex(self):
        self.assert_clean("session=%s digest=%s" % (FAKE_UUID, FAKE_HEX), FAKE_UUID, FAKE_HEX)

    def test_env_style_assignment(self):
        self.assert_clean("MATLAB_MCP_API_KEY=%s" % FAKE_KEY, FAKE_KEY)

    def test_double_encoded_json(self):
        source = json.dumps({"line": json.dumps({"apiKey": FAKE_KEY})})
        self.assert_clean(source, FAKE_KEY)

    def test_control_text_is_byte_identical(self):
        control = "MATLAB R2026a determinant=-4.0 eigenvalue=3.414214 elapsed=1.25s"
        clean, count = sanitize.sanitize_text(control)
        self.assertEqual(clean, control)
        self.assertEqual(count, 0)

    def test_idempotent(self):
        source = "Authorization: Bearer %s; apiKey=%s; id=%s" % (FAKE_BEARER, FAKE_KEY, FAKE_UUID)
        once, _ = sanitize.sanitize_text(source)
        twice, count = sanitize.sanitize_text(once)
        self.assertEqual(once, twice)
        self.assertEqual(count, 0)


class SanitizeStructureTest(unittest.TestCase):
    def test_dict_keys_are_redacted_recursively(self):
        payload = {"nested": {"apiKey": FAKE_KEY}, "list": [{"password": "PRIVATE_PASSWORD"}]}
        clean, count = sanitize.sanitize_value(payload)
        self.assertNotIn(FAKE_KEY, json.dumps(clean))
        self.assertNotIn("PRIVATE_PASSWORD", json.dumps(clean))
        self.assertGreaterEqual(count, 2)

    def test_jsonl_stays_valid_and_preserves_fields(self):
        line = json.dumps({
            "type": "item.completed",
            "item": {"type": "command_execution", "aggregated_output": '{"apiKey": "%s"}' % FAKE_KEY},
            "exit_code": 0,
        })
        clean, count = sanitize.sanitize_jsonl(line + "\n")
        self.assertTrue(clean.endswith("\n"))
        parsed = json.loads(clean)
        self.assertEqual(parsed["exit_code"], 0)
        self.assertEqual(parsed["type"], "item.completed")
        self.assertNotIn(FAKE_KEY, clean)
        self.assertGreaterEqual(count, 1)

    def test_jsonl_unparseable_line_still_scrubbed(self):
        clean, count = sanitize.sanitize_jsonl("not json apiKey=%s\n" % FAKE_KEY)
        self.assertNotIn(FAKE_KEY, clean)
        self.assertGreaterEqual(count, 1)

    def test_replacement_is_deterministic_and_hashed(self):
        first, _ = sanitize.sanitize_text("apiKey=%s" % FAKE_KEY)
        second, _ = sanitize.sanitize_text("apiKey=%s" % FAKE_KEY)
        self.assertEqual(first, second)
        self.assertRegex(first, r"<REDACTED:sha256-[0-9a-f]{12}>")


if __name__ == "__main__":
    unittest.main()
