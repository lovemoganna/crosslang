"""Generated StarDict files and failure contracts; no model/server required."""
import unittest
from unittest.mock import patch
from local_worker import run, select_loaded_model, merge_replacements, validate_reading_result, error_result
import urllib.error

import os
import tempfile
from stardict_fixture import create_dictionary

DICTIONARY = os.environ.get("CROSSLANG_TEST_DICTIONARY")
_DICTIONARY_TEMP = None


def setUpModule():
    global DICTIONARY, _DICTIONARY_TEMP
    if not DICTIONARY:
        _DICTIONARY_TEMP = tempfile.TemporaryDirectory(prefix="crosslang-dictionary-")
        DICTIONARY = create_dictionary(_DICTIONARY_TEMP.name)


def tearDownModule():
    if _DICTIONARY_TEMP:
        _DICTIONARY_TEMP.cleanup()


class OfflineContracts(unittest.TestCase):
    def test_generated_stardict_english_and_chinese_without_network(self):
        with patch("urllib.request.build_opener", side_effect=AssertionError("No HTTP allowed")):
            for word, expected in [("hello", "喂"), ("学习", "learn")]:
                result = run(dict(operation="explain", text=word, dictionary=DICTIONARY))
                self.assertIn(expected, result["text"])

    def test_dictionary_remains_available_with_selected_but_offline_model(self):
        with patch("urllib.request.build_opener", side_effect=AssertionError("No HTTP allowed")):
            self.assertIn("喂", run(dict(operation="explain", text="hello", model="unavailable",
                                      dictionary=DICTIONARY))["text"])

    def test_missing_resource_honest_failure(self):
        with self.assertRaisesRegex(ValueError, "directory"):
            run(dict(operation="explain", text="hello", dictionary=""))
        with self.assertRaisesRegex(ValueError, "model"):
            run(dict(operation="express", text="你好", target="en"))

    def test_unresolved_references_do_not_become_expressions(self):
        result = run(dict(operation="express", text="帮我把那个弄一下，跟上次一样。",
                          target="en", model="not-invoked"))
        self.assertTrue(result["uncertain"])


class ModelSelection(unittest.TestCase):
    def test_missing_model_has_stable_resource_code(self):
        try:
            select_loaded_model("@loaded", [])
        except ValueError as error:
            self.assertEqual("model-not-loaded", error_result(error)["error_code"])

    def test_unreachable_service_is_not_a_translation_result(self):
        result = error_result(urllib.error.URLError("connection refused"))
        self.assertEqual("service-unavailable", result["error_code"])
        self.assertNotIn("text", result)
    def setUp(self):
        self.models = [
            {"id": "local-text-model", "state": "loaded", "type": "llm"},
            {"id": "unloaded-text-model", "state": "not-loaded", "type": "llm"},
            {"id": "embedding", "state": "loaded", "type": "embeddings"},
        ]

    def test_auto_uses_only_loaded_text_model(self):
        self.assertEqual("local-text-model", select_loaded_model("@loaded", self.models))

    def test_explicit_model_is_not_silently_replaced(self):
        self.assertEqual("local-text-model", select_loaded_model("local-text-model", self.models))
        with self.assertRaisesRegex(ValueError, "not loaded"):
            select_loaded_model("unloaded-text-model", self.models)

    def test_no_loaded_text_model_fails_honestly(self):
        with self.assertRaisesRegex(ValueError, "No.*loaded"):
            select_loaded_model("@loaded", self.models[1:])

    def test_multiple_models_require_explicit_choice(self):
        self.models.append({"id": "second", "state": "loaded", "type": "llm"})
        with self.assertRaisesRegex(ValueError, "Multiple"):
            select_loaded_model("@loaded", self.models)
        self.assertEqual("second", select_loaded_model("second", self.models))


class PartialEdits(unittest.TestCase):
    def test_exact_latin_anchors_preserved(self):
        text = "Please check 交付时间 50 USD."
        result = merge_replacements(text, [{"id": 0, "start": 13, "end": 17}],
                                    {"replacements": [{"id": 0, "text": "the delivery date"}], "uncertain": False})
        self.assertEqual("Please check the delivery date 50 USD.", result["text"])
        self.assertEqual(13, result["edits"][0]["start"])

    def test_bad_id_cannot_change_other_text(self):
        with self.assertRaises(ValueError):
            merge_replacements("API 不变", [{"id": 0, "start": 4, "end": 6}],
                               {"replacements": [{"id": 3, "text": "change all"}], "uncertain": False})

    def test_uncertainty_never_becomes_writable_candidate(self):
        result = merge_replacements("那个", [{"id": 0, "start": 0, "end": 2}],
                                    {"uncertain": True, "clarification": "Which button?"})
        self.assertTrue(result["uncertain"])
        self.assertEqual([], result["edits"])


class ContextualReading(unittest.TestCase):
    def test_unchanged_english_is_rejected_as_chinese_explanation(self):
        with self.assertRaisesRegex(ValueError, "Chinese explanation"):
            validate_reading_result(dict(operation="explain", target="zh", text="bank"),
                                    dict(text="bank", uncertain=False))
        validate_reading_result(dict(operation="explain", target="zh", text="bank"),
                                dict(text="银行", uncertain=False))
    def test_dictionary_hit_does_not_preempt_context(self):
        with patch("local_worker.local_model", return_value={"text": "本句指银行", "source": "local"}) as model:
            result = run(dict(operation="explain", text="bank", dictionary=DICTIONARY,
                              context="The bank approved the loan.", model="@loaded", target="zh"))
            self.assertEqual("本句指银行", result["text"])
            model.assert_called_once()

    def test_context_failure_returns_labelled_real_dictionary(self):
        with patch("local_worker.local_model", side_effect=OSError("offline")):
            result = run(dict(operation="explain", text="bank", dictionary=DICTIONARY,
                              context="The bank approved the loan.", model="@loaded", target="zh"))
            self.assertIn("通用词典释义", result["text"])
            self.assertEqual("offline dictionary", result["source"])

    def test_dictionary_only_still_never_calls_model(self):
        with patch("local_worker.local_model", side_effect=AssertionError("must stay offline")):
            result = run(dict(operation="explain", text="bank", dictionary=DICTIONARY,
                              context="The bank approved the loan.", model=None))
            self.assertEqual("offline dictionary", result["source"])


class BidirectionalExpression(unittest.TestCase):
    def test_chinese_target_prompt_allows_translating_english(self):
        import io
        import json
        from local_worker import local_model
        for output, valid in [("请核对交付日期。", True), ("Please check the date.", False)]:
            with self.subTest(output=output):
                opener = unittest.mock.Mock()
                opener.open.side_effect = [
                    io.BytesIO(json.dumps({"data": [{"id": "local", "state": "loaded", "type": "llm"}]}).encode()),
                    io.BytesIO(json.dumps({"choices": [{"message": {"content": json.dumps({"text": output, "uncertain": False})}}]}).encode())]
                request = dict(operation="express", text="Please check the date.", target="zh", model="local")
                with patch("urllib.request.build_opener", return_value=opener):
                    if valid:
                        self.assertEqual(output, local_model(request)["text"])
                    else:
                        with self.assertRaisesRegex(ValueError, "Chinese translation"):
                            local_model(request)
                payload = json.loads(opener.open.call_args_list[1].args[0].data)
                prompt = payload["messages"][0]["content"]
                self.assertIn("Simplified Chinese", prompt)
                self.assertNotIn("Keep independently written English", prompt)


if __name__ == "__main__":
    unittest.main()
