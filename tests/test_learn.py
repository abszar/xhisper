"""Tests for xhisper-learn's word rules and field readers.

Run: python3 -m unittest discover -s tests -v   (or: make check)
"""
import importlib.machinery
import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = tempfile.mkdtemp()
os.environ["XDG_CONFIG_HOME"] = CONFIG  # never touch the real dictionary


def load():
    path = os.path.join(HERE, "..", "xhisper-learn")
    loader = importlib.machinery.SourceFileLoader("xhisper_learn", path)
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader("xhisper_learn", loader))
    loader.exec_module(module)
    return module


learn = load()


def fixes(old, new):
    return learn.corrections(learn.tokenize(old), learn.tokenize(new))


class Rules(unittest.TestCase):
    """The shared learning rules, against this machine's word list."""

    def test_misheard_name(self):
        self.assertEqual(fixes("we deploy to to Ziam now", "we deploy to TOSIAM now"), ["TOSIAM"])

    def test_lowercase_real_change(self):
        self.assertEqual(fixes("deploy with Qulify today", "deploy with coolify today"), ["coolify"])

    def test_accent_fix_not_learned(self):
        self.assertEqual(fixes("la réunion est reporte", "la réunion est reportée"), [])

    def test_pure_insert_not_learned(self):
        self.assertEqual(fixes("ship it", "ship it TOSIAM"), [])

    def test_glued_slip_rejected(self):
        self.assertEqual(fixes("using QLIFY now", "usingcoolifyY now"), [])

    def test_split_word_joined(self):
        self.assertEqual(fixes("the graph QL api", "the GraphQL api"), ["GraphQL"])

    def test_english_word_not_learned(self):
        self.assertEqual(fixes("the hous is red", "the house is red"), [])

    def test_inflected_english_not_learned(self):
        self.assertEqual(fixes("two question here", "two Questions here"), [])

    def test_casing_fix(self):
        self.assertEqual(fixes("ask tosiam", "ask TOSIAM"), ["TOSIAM"])

    def test_long_rewrite_ignored(self):
        self.assertEqual(fixes("a b", "Alpha Beta Gamma Delta Epsilon"), [])


class English(unittest.TestCase):
    WORDS = {"use", "question", "deploy", "ship", "house", "do", "it", "study", "big", "quick", "can"}

    def test_inflections_on_mac(self):
        for w in ["using", "questions", "deployed", "shipping", "houses", "don't", "it's",
                  "studies", "bigger", "quickly", "can't", "Questions"]:
            self.assertTrue(learn.is_english(w, "darwin", self.WORDS), w)

    def test_not_english_on_mac(self):
        for w in ["coolify", "tosiam", "kubectl", "graphql", "TOSIAM"]:
            self.assertFalse(learn.is_english(w, "darwin", self.WORDS), w)

    def test_linux_uses_the_list_only(self):
        self.assertTrue(learn.is_english("use", "linux", self.WORDS))
        self.assertFalse(learn.is_english("using", "linux", self.WORDS))


class Config(unittest.TestCase):
    def write(self, text):
        os.makedirs(os.path.dirname(learn.CONFIG_FILE), exist_ok=True)
        with open(learn.CONFIG_FILE, "w") as f:
            f.write(text)

    def test_absent_key_gives_default(self):
        self.write("auto-edit : true\n")
        self.assertEqual(learn.config_value("learned-sound", "/x.aiff"), "/x.aiff")

    def test_empty_value_is_silent(self):
        self.write("learned-sound :\n")
        self.assertEqual(learn.config_value("learned-sound", "/x.aiff"), "")

    def test_comment_stripped(self):
        self.write("learned-sound : /y.aiff # why\n")
        self.assertEqual(learn.config_value("learned-sound", "/x.aiff"), "/y.aiff")


FAKE_AX = r'''#!/usr/bin/python3
import json, sys
answers = [{"role": "AXTextArea", "text": "héllo wörld", "caret": 5}, {"gone": True}]
assert sys.argv[1:] == ["ax", "--follow"], sys.argv
for i, _ in enumerate(sys.stdin):
    print(json.dumps(answers[min(i, 1)]), flush=True)
'''


class AxReaderProtocol(unittest.TestCase):
    """AxReader against a fake `Xhisper ax --follow` (runs on any OS)."""

    def setUp(self):
        fd, self.fake = tempfile.mkstemp()
        with os.fdopen(fd, "w") as f:
            f.write(FAKE_AX)
        os.chmod(self.fake, stat.S_IRWXU)
        os.environ["XHISPER_APP"] = self.fake

    def tearDown(self):
        os.unlink(self.fake)
        del os.environ["XHISPER_APP"]

    def test_follow(self):
        reader = learn.AxReader()
        try:
            self.assertTrue(reader.attach())
            self.assertEqual(reader.role(), "AXTextArea")
            self.assertEqual(reader.before_caret(3), "llo")
            self.assertIsNone(reader.read())  # second answer: gone
        finally:
            reader.close()

    def test_missing_app(self):
        os.environ["XHISPER_APP"] = "/nonexistent/Xhisper"
        with self.assertRaises(ImportError):
            learn.AxReader()


if __name__ == "__main__":
    unittest.main()
