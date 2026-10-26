"""Run offline Python contracts and ERT without loading the user's init file."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from stardict_fixture import create_dictionary

CORE_TESTS = [
    "crosslang-tests.el", "crosslang-edge-tests.el", "crosslang-entry-tests.el",
    "crosslang-inline-tests.el", "crosslang-safety-tests.el", "crosslang-live-tests.el",
    "crosslang-org-tests.el", "crosslang-shadow-tests.el", "crosslang-bilingual-tests.el",
    "crosslang-all-modes-tests.el", "crosslang-bidirectional-tests.el", "crosslang-below-tests.el",
    "crosslang-pair-tests.el", "crosslang-style-tests.el",
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emacs", default="emacs")
    parser.add_argument("--load-path", action="append", default=[], help="Dependency directory; repeat as needed")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="crosslang-tests-") as temporary:
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PYTHONUTF8="1",
                   CROSSLANG_TEST_PYTHON=sys.executable,
                   CROSSLANG_TEST_DICTIONARY=create_dictionary(Path(temporary) / "dictionary"))
        subprocess.run([sys.executable, "-B", "-m", "unittest", "discover", "-s", "tests", "-p", "test_worker.py", "-v"],
                       cwd=ROOT, env=env, check=True)
        common = [args.emacs, "-Q", "--batch", "-L", str(ROOT), "-L", str(ROOT / "tests")]
        for directory in args.load_path:
            common += ["-L", directory]
        common += ["-l", str(ROOT / "tests" / "bootstrap.el")]
        for files in [CORE_TESTS, ["crosslang-hydra-tests.el"]]:
            command = common.copy()
            for name in files:
                command += ["-l", str(ROOT / "tests" / name)]
            subprocess.run(command + ["-f", "ert-run-tests-batch-and-exit"], cwd=ROOT, env=env, check=True)


if __name__ == "__main__":
    main()
