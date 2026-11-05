"""Run with python3 -m unittest discover -s extras/fuzz -p 'test_*.py'."""
import json
import contextlib
import io
import os
from pathlib import Path
import random
import shutil
import tempfile
import time
import unittest
from unittest import mock

import fuzz


class GeneratorTests(unittest.TestCase):
    def test_independent_addressable_cases(self):
        cases = [fuzz.case_for(42, i, [b'return 1']) for i in range(64)]
        self.assertEqual(cases, [fuzz.case_for(42, i, [b'return 1']) for i in range(64)])
        self.assertNotEqual(cases, [fuzz.case_for(43, i, [b'return 1']) for i in range(64)])
        self.assertEqual(len({c.profile for c in cases}), 8)
        for i in reversed(range(64)):
            self.assertEqual(cases[i], fuzz.case_for(42, i, [b'return 1']))

    def test_expression_has_independent_arithmetic_oracle(self):
        for seed in range(100):
            text, expected = fuzz.expression(random.Random(seed), 3)
            self.assertEqual(eval(text, {'__builtins__': {}}), expected)

    def test_minimizer_preserves_predicate_and_budget(self):
        reduced, calls = fuzz.minimize(b'prefix CRASH suffix', lambda b: b'CRASH' in b, 100, 2)
        self.assertEqual(reduced, b'CRASH')
        self.assertLessEqual(calls, 100)
        unchanged, calls = fuzz.minimize(b'abcdef', lambda b: False, 2, 2)
        self.assertEqual(unchanged, b'abcdef')
        self.assertEqual(calls, 2)

    def test_artifacts_keep_binary_input_and_oracle(self):
        with tempfile.TemporaryDirectory() as tmp:
            case = fuzz.Case(b'\x00\xffreturn 1', 'bytes', 1, 12, 9)
            path = fuzz.save_failure(Path(tmp), case, {'status': 'failure', 'stage': 'test'}, {'target': '5.1'})
            self.assertEqual(path.read_bytes(), case.source)
            meta = json.loads(path.with_suffix('.json').read_text())
            self.assertEqual(meta['expected'], 1)
            self.assertEqual(meta['seed'], 12)

    def test_refuses_invalid_oracle_reduction(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'case.tl'
            path.write_text('return 2')
            path.with_suffix('.json').write_text(json.dumps({'expected': 1}))
            result = {'status': 'failure', 'stage': 'execute', 'message': 'invariant: semantic oracle'}
            with mock.patch.object(fuzz, 'run_case', return_value=result), mock.patch.object(fuzz, 'minimize') as reducer:
                status = fuzz.main(['--replay', str(path), '--minimize', '--output', str(Path(tmp)/'out')])
                self.assertEqual(status, 1)
                reducer.assert_not_called()


class CompilerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = shutil.which('lua') or shutil.which('luajit')
        if not cls.lua:
            raise unittest.SkipTest('Lua interpreter unavailable')

    def run_case(self, case, lua=None, **kwargs):
        return fuzz.run_case(case, lua or self.lua, fuzz.ROOT, '5.1', 3, **kwargs)

    def test_relative_interpreter_and_invalid_configuration_fail_fast(self):
        with tempfile.TemporaryDirectory() as tmp:
            relative = os.path.relpath(self.lua)
            status = fuzz.main(['--lua', relative, '--cases', '0', '--output', tmp])
            self.assertEqual(status, 0)
            meta = json.loads((Path(tmp) / 'summary.json').read_text())
            self.assertTrue(Path(meta['lua']).is_absolute())
            with contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as missing:
                    fuzz.main(['--lua', '/nonexistent/teal-fuzz-lua', '--cases', '10', '--output', tmp])
                self.assertEqual(missing.exception.code, 2)
                with self.assertRaises(SystemExit) as bad_root:
                    fuzz.main(['--lua', self.lua, '--root', tmp, '--cases', '10', '--output', tmp])
                self.assertEqual(bad_root.exception.code, 2)
            self.assertFalse((Path(tmp) / 'failures').exists())

    def test_generated_semantics_and_profiles(self):
        corpus = [p.read_bytes() for p in sorted((fuzz.HERE/'corpus').glob('*.tl'))]
        for i in range(48):
            with self.subTest(index=i):
                result = self.run_case(fuzz.case_for(20261105, i, corpus, max_depth=32))
                self.assertEqual(result['status'], 'ok', result)

    def test_luajit_closed_programs(self):
        lua = shutil.which('luajit')
        if not lua:
            self.skipTest('LuaJIT unavailable')
        for i in (0, 1, 6, 8, 9, 14):
            with self.subTest(index=i):
                result = self.run_case(fuzz.case_for(100, i, []), lua=lua)
                self.assertEqual(result['status'], 'ok', result)
                self.assertEqual(result['executed'], 1)

    def test_semantic_bug_is_not_silently_accepted(self):
        result = self.run_case(fuzz.Case(b'return 2', 'grammar', expected=1))
        self.assertEqual(result['status'], 'failure')
        self.assertEqual(result['stage'], 'execute')
        self.assertIn('expected 1, got 2', result['message'])

    def test_malformed_input_is_expected_rejection(self):
        result = self.run_case(fuzz.Case(b'local x: number = ', 'editor'))
        self.assertEqual(result['status'], 'ok', result)
        self.assertEqual(result['disposition'], 'rejected')

    def test_reference_checkout_acceptance_comparison(self):
        result = self.run_case(fuzz.Case(b'return 1', 'grammar', 1), reference_root=fuzz.ROOT)
        self.assertEqual(result['status'], 'ok', result)

    def test_corpus_input_never_executes(self):
        # A type-correct but nonterminating input must still finish: only generated closed cases execute.
        result = self.run_case(fuzz.Case(b'while true do end', 'corpus'))
        self.assertEqual(result['status'], 'ok', result)
        self.assertEqual(result['executed'], 0)

    def test_timeout_isolated_and_process_crash_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / 'fake-lua'
            script.write_text('#!/usr/bin/env python3\nimport time\ntime.sleep(30)\n')
            script.chmod(0o755)
            started = time.monotonic()
            result = fuzz.run_case(fuzz.Case(b'', 'test'), str(script), fuzz.ROOT, '5.1', .2)
            self.assertEqual(result['stage'], 'timeout', result)
            self.assertLess(time.monotonic() - started, 2)
            script.write_text('#!/usr/bin/env python3\nimport os,signal\nos.kill(os.getpid(),signal.SIGKILL)\n')
            result = fuzz.run_case(fuzz.Case(b'', 'test'), str(script), fuzz.ROOT, '5.1', 2)
            self.assertEqual(result['status'], 'failure')
            self.assertEqual(result['stage'], 'process')


if __name__ == '__main__':
    unittest.main()
