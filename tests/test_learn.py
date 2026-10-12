"""Tests for xhisper-learn's word rules and field readers.

Run: python3 -m unittest discover -s tests -v   (or: make check)
"""
import importlib.machinery
import importlib.util
import json
import os
import stat
import subprocess
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

    def test_denied(self):
        with open(self.fake, "w") as f:
            f.write("#!/usr/bin/env python3\n"
                    "import sys, json\n"
                    "for _ in sys.stdin:\n"
                    "    print(json.dumps({'denied': True}), flush=True)\n")
        reader = learn.AxReader()
        try:
            self.assertFalse(reader.attach())  # no text field readable
            self.assertTrue(reader.denied)
        finally:
            reader.close()

    def test_watch_logs_denied_hint(self):
        with open(self.fake, "w") as f:
            f.write("#!/usr/bin/env python3\nimport sys, json\n"
                    "for _ in sys.stdin:\n    print(json.dumps({'denied': True}), flush=True)\n")
        logged = []
        old, old_reader = learn.log, learn.open_reader
        learn.log = logged.append
        learn.open_reader = learn.AxReader  # watch() picks AT-SPI off macOS
        try:
            learn.watch("some dictated words")
        finally:
            learn.log, learn.open_reader = old, old_reader
        self.assertEqual(len(logged), 1)
        self.assertIn("lacks Accessibility", logged[0])
        self.assertNotIn("dictated", logged[0])

    def test_not_denied(self):
        reader = learn.AxReader()
        try:
            self.assertTrue(reader.attach())
            self.assertFalse(reader.denied)
        finally:
            reader.close()


class RuntimeDir(unittest.TestCase):
    """xhisper-learn finds the same runtime dir as xhisper.sh."""

    def fresh(self, **env):
        saved = {k: os.environ.pop(k, None) for k in ("XHISPER_RUNTIME_DIR", "XDG_RUNTIME_DIR")}
        os.environ.update(env)
        try:
            return load().RUNTIME_DIR
        finally:
            for k in ("XHISPER_RUNTIME_DIR", "XDG_RUNTIME_DIR"):
                os.environ.pop(k, None)
                if saved[k] is not None:
                    os.environ[k] = saved[k]

    def test_explicit_wins(self):
        self.assertEqual(self.fresh(XHISPER_RUNTIME_DIR="/x/y", XDG_RUNTIME_DIR="/z"), "/x/y")

    def test_xdg(self):
        self.assertEqual(self.fresh(XDG_RUNTIME_DIR="/run/user/1"), "/run/user/1/xhisper")

    @unittest.skipUnless(sys.platform == "darwin", "macOS per-user temp dir")
    def test_darwin_default(self):
        tmp = subprocess.check_output(["getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip()
        self.assertEqual(self.fresh(), tmp.rstrip("/") + "/xhisper")


if __name__ == "__main__":
    unittest.main()


class Spacing(unittest.TestCase):
    """A dictation pasted right after a word gets one leading space."""

    def test_after_word_or_punctuation(self):
        for before in ("s", ".", "!", "9", ")", "é"):
            self.assertTrue(learn.needs_space(before, "Ok, now"), repr(before))

    def test_no_space(self):
        cases = [(" ", "Ok"), ("\n", "Ok"), ("\t", "Ok"), ("", "Ok"), ("(", "Ok"), ("[", "Ok"),
                 ('"', "Ok"), ("'", "Ok"), ("“", "Ok"), ("/", "Ok"),
                 ("s", ", and"), ("s", "."), ("s", "?"), ("s", ")"), ("s", " Ok"), ("s", "")]
        for before, text in cases:
            self.assertFalse(learn.needs_space(before, text), repr((before, text)))


class PasteTimeDifferences(unittest.TestCase):
    """Only edits made after the paste are learned, not how it landed."""

    class FakeReader:
        def __init__(self, texts):
            self.texts = list(texts)

        def read(self):
            text = self.texts.pop(0) if len(self.texts) > 1 else self.texts[0]
            return text, len(text)

    def setUp(self):
        self.saved = {k: getattr(learn, k) for k in
                      ("POLL_SECONDS", "SETTLE_SECONDS", "WATCH_SECONDS", "add_words", "announce", "log")}
        learn.POLL_SECONDS, learn.SETTLE_SECONDS, learn.WATCH_SECONDS = 0.005, 0.03, 0.4
        self.learned = []
        learn.add_words = lambda words: self.learned.extend(words) or list(words)
        learn.announce = lambda words: None
        learn.log = lambda message: None

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(learn, k, v)

    def test_glued_paste_not_learned(self):
        dictation = "Ok, now I'm trying the push to talk."
        reader = self.FakeReader(["Trying the tool to see if the text goes.Ok, now I'm trying the push to talk."])
        learn.follow(reader, learn.tokenize(dictation))
        self.assertEqual(self.learned, [])

    def test_later_fix_still_learned(self):
        dictation = "Ok, now I'm trying the push to talk."
        reader = self.FakeReader(["goes. Ok, now I'm trying the push to talk.",
                                  "goes. Ok, now I'm trying the ZORBIX to talk."])
        learn.follow(reader, learn.tokenize(dictation))
        self.assertEqual(self.learned, ["ZORBIX"])
