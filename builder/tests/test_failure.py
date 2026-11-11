"""What the app's measurements may say of an error (failure.py): its class,
where the builder's own code met it and its errno, never its words."""

import unittest

from cartouche_builder import failure


def builder_function(source: str, module: str = "cartouche_builder.library"):
    """The function SOURCE defines, as if module MODULE of the builder held it."""
    scope = {"__name__": module}
    exec(compile(source, module.replace(".", "/") + ".py", "exec"), scope)  # noqa: S102 - the test's own code
    return next(value for key, value in scope.items() if callable(value) and not key.startswith("__"))


def raised(call, *args) -> BaseException:
    """The exception CALL raises, with its traceback, which assertRaises drops."""
    try:
        call(*args)
    except Exception as error:  # noqa: BLE001
        return error
    raise AssertionError(f"{call} raised nothing")


class Failure(unittest.TestCase):
    def test_the_class_where_and_errno(self):
        scan = builder_function("def scan(path):\n    open(path)\n")
        error = raised(scan, "/Users/player/Jeux/missing/Zelda.ipa")
        self.assertEqual(failure.describe(error), {"exception": "FileNotFoundError", "where": "library.scan", "errno": 2})

    def test_the_builders_frame_nearest_to_the_error(self):
        inner = builder_function("def unpack(value):\n    return {}[value]\n", "cartouche_builder.ipa")
        outer = builder_function("def build(value, inner):\n    return inner(value)\n", "cartouche_builder.batch")
        error = raised(outer, "Mario Kart World", inner)
        self.assertEqual(failure.describe(error), {"exception": "KeyError", "where": "ipa.unpack"})

    def test_an_error_raised_outside_the_builder_has_no_place(self):
        self.assertEqual(failure.describe(raised(int, "Zelda")), {"exception": "ValueError"})

    def test_only_names_and_numbers(self):
        self.assertEqual(failure.name("CalledProcessError"), "CalledProcessError")
        for text in ("", "No space left", "/Users/player", "é", "a" * 49, "1Error"):
            self.assertIsNone(failure.name(text))
        error = OSError("No space left on /Volumes/Jeux")
        error.errno = -1
        self.assertEqual(failure.describe(error), {"exception": "OSError"})
        self.assertEqual(failure.where(None), None)


if __name__ == "__main__":
    unittest.main()
