"""Tests for bin/kopia-web-signin. Run: python3 -m unittest discover -s test -p 'test_*.py'"""
import importlib.machinery
import importlib.util
import os
import stat
import tempfile
import unittest
from pathlib import Path

HELPER = Path(__file__).resolve().parents[1] / "bin" / "kopia-web-signin"
loader = importlib.machinery.SourceFileLoader("signin", str(HELPER))
spec = importlib.util.spec_from_loader("signin", loader)
signin = importlib.util.module_from_spec(spec)
loader.exec_module(signin)

URL = "http://127.0.0.1:51516"


class Env:
    """A private home and runtime directory for one test."""

    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="kopia-signin-")
        root = Path(self.tmp.name)
        os.chmod(root, 0o700)
        self.home = root / "home"
        self.runtime = root / "run"
        self.home.mkdir(mode=0o700)
        self.runtime.mkdir(mode=0o700)

    def password_file(self, text, mode=0o600, name="ui.env"):
        path = self.home / name
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
        os.write(fd, text.encode())
        os.close(fd)
        os.chmod(path, mode)
        return str(path)

    def close(self):
        self.tmp.cleanup()


class ParsePassword(unittest.TestCase):
    def test_env_file_forms(self):
        self.assertEqual(signin.parse_password(b"KOPIA_SERVER_PASSWORD=s3cret\n"), "s3cret")
        self.assertEqual(signin.parse_password(b'# c\nOTHER=1\nKOPIA_SERVER_PASSWORD="p@ss word"\n'), "p@ss word")
        self.assertEqual(signin.parse_password(b"export KOPIA_SERVER_PASSWORD='single'\n"), "single")
        self.assertEqual(signin.parse_password(b"justapassword\n"), "justapassword")

    def test_nothing_usable(self):
        for raw in (b"", b"A=1\nB=2\n", b"KOPIA_SERVER_PASSWORD=\n", b"\xff\xfe"):
            self.assertIsNone(signin.parse_password(raw))

    def test_control_characters_refused(self):
        self.assertIsNone(signin.parse_password(b"KOPIA_SERVER_PASSWORD=a\x00b\n"))


class SignedLink(unittest.TestCase):
    def test_link(self):
        self.assertEqual(signin.signed_link(URL, "user", "p@ss word"), "http://user:p%40ss%20word@127.0.0.1:51516/")
        self.assertEqual(signin.signed_link("https://backup.example/ui?x=1", "u", "p"), "https://u:p@backup.example/ui?x=1")

    def test_refuses_bad_input(self):
        for url in ("ftp://x", "http://a:b@127.0.0.1", "javascript:alert(1)", "http://x\n/"):
            with self.assertRaises(signin.Refused):
                signin.signed_link(url, "user", "p")
        with self.assertRaises(signin.Refused):
            signin.signed_link(URL, "us er", "p")

    def test_page_escapes_the_link(self):
        page = signin.redirect_page('http://u:"<x>&@h/').decode()
        self.assertNotIn('"<x>', page)
        self.assertIn("&quot;&lt;x&gt;&amp;", page)
        self.assertIn('name="referrer" content="no-referrer"', page)


class ReadPassword(unittest.TestCase):
    def setUp(self):
        self.env = Env()

    def tearDown(self):
        self.env.close()

    def test_reads_private_file(self):
        path = self.env.password_file("KOPIA_SERVER_PASSWORD=stand-in\n")
        self.assertEqual(signin.read_password(path), "stand-in")

    def test_refuses_group_or_world_readable(self):
        path = self.env.password_file("KOPIA_SERVER_PASSWORD=x\n", mode=0o644)
        with self.assertRaisesRegex(signin.Refused, "chmod 600"):
            signin.read_password(path)

    def test_refuses_symlink(self):
        target = self.env.password_file("KOPIA_SERVER_PASSWORD=x\n")
        link = self.env.home / "link.env"
        os.symlink(target, link)
        with self.assertRaises(signin.Refused):
            signin.read_password(str(link))

    def test_refuses_symlinked_parent(self):
        self.env.password_file("KOPIA_SERVER_PASSWORD=x\n")
        alias = Path(self.env.tmp.name) / "alias"
        os.symlink(self.env.home, alias)
        with self.assertRaises(signin.Refused):
            signin.read_password(str(alias / "ui.env"))

    def test_refuses_fifo_without_blocking(self):
        fifo = self.env.home / "pipe.env"
        os.mkfifo(fifo, 0o600)
        with self.assertRaises(signin.Refused):
            signin.read_password(str(fifo))

    def test_refuses_oversized(self):
        path = self.env.password_file("KOPIA_SERVER_PASSWORD=" + "x" * 5000 + "\n")
        with self.assertRaises(signin.Refused):
            signin.read_password(path)

    def test_refuses_relative_path(self):
        with self.assertRaises(signin.Refused):
            signin.read_password("ui.env")


class PrivatePage(unittest.TestCase):
    def setUp(self):
        self.env = Env()

    def tearDown(self):
        self.env.close()

    def test_page_is_private_and_removed(self):
        dirfd, name = signin.write_page(str(self.env.runtime), b"<p>page</p>")
        try:
            folder = self.env.runtime / signin.FOLDER
            self.assertEqual(stat.S_IMODE(os.stat(folder).st_mode), 0o700)
            page = folder / name
            self.assertEqual(stat.S_IMODE(os.stat(page).st_mode), 0o600)
            self.assertEqual(page.read_bytes(), b"<p>page</p>")
            signin.remove_page(dirfd, name)
            self.assertFalse(page.exists())
        finally:
            os.close(dirfd)

    def test_refuses_planted_folder_symlink(self):
        elsewhere = Path(self.env.tmp.name) / "elsewhere"
        elsewhere.mkdir(mode=0o700)
        os.symlink(elsewhere, self.env.runtime / signin.FOLDER)
        with self.assertRaises(signin.Refused):
            signin.write_page(str(self.env.runtime), b"x")
        self.assertEqual(list(elsewhere.iterdir()), [])

    def test_refuses_shared_runtime_dir(self):
        os.chmod(self.env.runtime, 0o755)
        with self.assertRaises(signin.Refused):
            signin.write_page(str(self.env.runtime), b"x")

    def test_stale_pages_are_cleared(self):
        dirfd, name = signin.write_page(str(self.env.runtime), b"old")
        os.close(dirfd)
        old = self.env.runtime / signin.FOLDER / name
        os.utime(old, (1, 1))
        planted = self.env.runtime / signin.FOLDER / "not-ours"
        os.symlink("/etc/hostname", planted)
        dirfd, fresh = signin.write_page(str(self.env.runtime), b"new")
        try:
            self.assertFalse(old.exists())
            self.assertFalse(os.path.lexists(planted))
            self.assertTrue((self.env.runtime / signin.FOLDER / fresh).exists())
        finally:
            os.close(dirfd)

    def test_missing_runtime_dir_fails_closed(self):
        with self.assertRaises(signin.Refused):
            signin.write_page("", b"x")


if __name__ == "__main__":
    unittest.main()
