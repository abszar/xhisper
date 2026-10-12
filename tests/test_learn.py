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


class FakeNode:
    """A text accessible. `children` maps a U+FFFC offset to its link target;
    `kids` are the tree children focused_text_node() walks (links count too)."""

    def __init__(self, text, caret=-1, children=None, role="paragraph", states=(), kids=()):
        self.text, self.caret, self.children = text, caret, children or {}
        self.role, self.states = role, set(states)
        self.kids = list(kids) or list(self.children.values())

    def get_text_iface(self):
        return self

    def get_role_name(self):
        return self.role

    def get_state_set(self):
        return type("States", (), {"contains": lambda _, s: s in self.states})()

    def get_child_count(self):
        return len(self.kids)

    def get_child_at_index(self, i):
        return self.kids[i]

    def get_process_id(self):
        return 42


class FakeAtspi:
    """Just the AT-SPI calls focused_text_node() and char_before_caret()
    make, over FakeNode trees. get_desktop() is set per test."""

    class StateType:
        ACTIVE, FOCUSED = "ACTIVE", "FOCUSED"

    get_desktop = None

    class Text:
        get_caret_offset = staticmethod(lambda n: n.caret)
        get_character_count = staticmethod(lambda n: len(n.text))
        get_text = staticmethod(lambda n, start, end: n.text[start:end])

    class Hypertext:
        get_link_index = staticmethod(lambda n, offset: offset)

        @staticmethod
        def get_link(n, index):
            child = n.children.get(index)
            return type("Link", (), {"get_object": lambda self, i: child})() if child else None


class AtspiCaretState(unittest.TestCase):
    """The character before the caret through AT-SPI, browser rich editors
    included (runs on any OS: the tree is faked, open_reader is patched)."""

    def state(self, root):
        class Reader(learn.AtspiReader):
            def __init__(self):
                self.Atspi, self.node = FakeAtspi, None

            def attach(self):
                self.node = root
                return True

        saved = learn.open_reader
        learn.open_reader = Reader
        try:
            return learn.caret_state()
        finally:
            learn.open_reader = saved

    def editor(self, caret, second, second_caret):
        """Chrome's contenteditable: one U+FFFC per paragraph in the focused node."""
        o = learn.OBJECT_CHAR
        return FakeNode(o + o, caret, {0: FakeNode("First line."), 1: FakeNode(second, second_caret)})

    def test_plain_field(self):
        self.assertEqual(self.state(FakeNode("the text goes.", 14)), "C.")

    def test_empty_new_paragraph(self):
        self.assertEqual(self.state(self.editor(1, "", 0)), "C")

    def test_after_text_in_a_paragraph(self):
        self.assertEqual(self.state(self.editor(1, "job finished?", 13)), "C?")

    def test_caret_reported_after_the_placeholder(self):
        self.assertEqual(self.state(self.editor(2, "job finished?", 13)), "C?")

    def test_empty_editor(self):
        root = FakeNode(learn.OBJECT_CHAR, 0, {0: FakeNode("", 0)})
        self.assertEqual(self.state(root), "C")

    def chrome(self, composer):
        """claude.ai in Chrome as AT-SPI showed it live: the page document no
        longer FOCUSED, the composer FOCUSED 17 levels down, and a second,
        empty document in the same window that keeps FOCUSED."""
        o = learn.OBJECT_CHAR
        node = composer
        for _ in range(16):
            node = FakeNode(o, 0, {0: node}, role="section")
        page = FakeNode(o * 4, 0, role="document web", kids=[node])
        stale = FakeNode(o, -1, role="document web", states={"FOCUSED"})
        window = FakeNode(o, 0, role="frame", states={"ACTIVE"},
                          kids=[FakeNode(o * 4, 0, role="panel", kids=[page, stale])])
        app = FakeNode("", -1, role="application", kids=[window])
        return FakeNode("", -1, role="desktop", kids=[app])

    def chrome_state(self, paragraph):
        o = learn.OBJECT_CHAR
        composer = FakeNode(o, 0, {0: paragraph}, role="entry", states={"FOCUSED"})
        desktop = self.chrome(composer)
        saved = learn.open_reader, learn.active_window_pid, FakeAtspi.get_desktop

        class Reader(learn.AtspiReader):
            def __init__(self):
                self.Atspi, self.node = FakeAtspi, None

        learn.open_reader, learn.active_window_pid = Reader, lambda: 42
        FakeAtspi.get_desktop = staticmethod(lambda i: desktop)
        try:
            return learn.caret_state()
        finally:
            learn.open_reader, learn.active_window_pid, FakeAtspi.get_desktop = saved

    def test_claude_ai_after_text_skips_a_stale_document(self):
        self.assertEqual(self.chrome_state(FakeNode("finished?", 9)), "C?")

    def test_claude_ai_empty_composer(self):
        # tiptap's empty paragraph holds its trailing <br> as "\n", caret before it
        self.assertEqual(self.chrome_state(FakeNode("\n", 0)), "C")

    def test_a_focused_document_alone_is_still_found(self):
        o = learn.OBJECT_CHAR
        doc = FakeNode("the text goes.", 14, role="document web", states={"FOCUSED"})
        window = FakeNode(o, 0, role="frame", states={"ACTIVE"}, kids=[doc])
        desktop = FakeNode("", -1, role="desktop", kids=[FakeNode("", -1, role="application", kids=[window])])
        saved = learn.active_window_pid, FakeAtspi.get_desktop
        learn.active_window_pid = lambda: 42
        FakeAtspi.get_desktop = staticmethod(lambda i: desktop)
        try:
            self.assertIs(learn.focused_text_node(FakeAtspi), doc)
        finally:
            learn.active_window_pid, FakeAtspi.get_desktop = saved

    def test_object_without_text_is_a_boundary(self):
        root = FakeNode("word " + learn.OBJECT_CHAR, 6, {5: FakeNode("", -1)})
        self.assertEqual(self.state(root), "C")


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


class SpacingFallback(unittest.TestCase):
    """Unreadable fields (cmux) fall back on xhisper's own last paste."""

    LAST = {"time": 1000.0, "app": "com.cmuxterm.app", "last": "."}

    def decide(self, state, terminal=False, app="com.cmuxterm.app", last=LAST, now=1030.0, text="Ok, now"):
        return learn.leading_space(state, text, terminal, app, last, now)

    def test_readable_field_uses_the_real_character(self):
        self.assertTrue(self.decide("C."))
        self.assertFalse(self.decide("C "))
        self.assertFalse(self.decide("C", last=self.LAST))  # caret at the start of a readable field

    def test_empty_readable_field_is_trusted(self):
        self.assertFalse(self.decide("E", terminal=False))

    def test_unreadable_uses_last_paste(self):
        self.assertTrue(self.decide("U"))
        self.assertTrue(self.decide("", terminal=True))      # read timed out
        self.assertTrue(self.decide("E", terminal=True))     # terminal exposing no text (cmux)

    def test_fallback_limits(self):
        self.assertFalse(self.decide("U", app="com.apple.TextEdit"))          # another app
        self.assertFalse(self.decide("U", now=1000.0 + 121))                   # too old
        self.assertFalse(self.decide("U", last=None))                          # nothing pasted yet
        self.assertFalse(self.decide("U", last=dict(self.LAST, last=" ")))     # ended with a space
        self.assertFalse(self.decide("U", text=", and"))                       # starts with punctuation
