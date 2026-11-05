#!/usr/bin/env python3
"""Deterministic, process-isolated Teal compiler fuzzing. Python standard library only."""
from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import hashlib
import json
import math
import os
from pathlib import Path
import random
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
VERSION = 1
TOKENS = ('local', 'global', 'record', 'interface', 'enum', 'type', 'function', 'end',
          'return', 'if', 'then', 'else', 'elseif', 'for', 'in', 'do', 'while', 'repeat',
          'until', 'break', 'goto', '::', 'as', 'is', 'where', 'and', 'or', 'not', 'nil',
          'true', 'false', 'number', 'integer', 'string', 'boolean', 'any', 'unknown',
          'userdata', 'metamethod', 'macroexp', 'require', '(', ')', '{', '}', '[', ']',
          '<', '>', ':', ';', ',', '.', '=', '...', '?', '|', '&', '//', '<<', '>>',
          '~', '^', '+', '-', '*', '/', '%', '"x"', "'x'", '[=[x]=]', '--[[', ']]',
          '0', '0xFF', '1e-2', 'v', 'T', '$', '`', '```', '--#pragma arity on\n')


@dataclasses.dataclass(frozen=True)
class Case:
    source: bytes
    profile: str
    expected: int | None = None
    seed: int = 0
    index: int = 0


def expression(rng: random.Random, depth: int) -> tuple[str, int]:
    if depth <= 0 or rng.randrange(4) == 0:
        n = rng.randrange(-20, 21)
        return f'({n})', n
    left, a = expression(rng, depth - 1)
    right, b = expression(rng, depth - 1)
    op = rng.choice(('+', '-', '*'))
    value = a + b if op == '+' else a - b if op == '-' else a * b
    return f'({left} {op} {right})', value


def valid_program(rng: random.Random, size: int = 8) -> tuple[str, int]:
    """Typed grammar with a separately computed bounded integer semantics oracle."""
    lines = ['local total: number = 0']
    expected = 0
    for i in range(rng.randrange(1, size + 1)):
        expr, value = expression(rng, rng.randrange(1, 4))
        kind = rng.randrange(10)
        if kind == 0:
            lines += [f'local v{i}: number = {expr}', f'total = total + v{i}']
        elif kind == 1:
            n = rng.randrange(1, 7)
            lines += [f'for j{i} = 1, {n} do', f'   total = total + {expr}', 'end']
            value *= n
        elif kind == 2:
            lines += [f'local function f{i}(x: number): number', '   return x * 2 + 1',
                      'end', f'total = total + f{i}({expr})']
            value = value * 2 + 1
        elif kind == 3:
            lines += [f'local record R{i}', '   value: number', 'end',
                      f'local r{i}: R{i} = {{value = {expr}}}', f'total = total + r{i}.value']
        elif kind == 4:
            lines += [f'local a{i}: {{number}} = {{{expr}, 2, 3}}',
                      f'for j{i} = 1, #a{i} do', f'   total = total + a{i}[j{i}]', 'end']
            value += 5
        elif kind == 5:
            lines += [f'local function identity{i}<T>(x: T): T', '   return x', 'end',
                      f'total = total + identity{i}({expr})']
        elif kind == 6:
            lines += [f'local function union{i}(u: number | string): number',
                      '   if u is number then', '      return u', '   else', '      return 0',
                      '   end', 'end', f'total = total + union{i}({expr})']
        elif kind == 7:
            lines += [f'local enum E{i}', '   "yes"', '   "no"', 'end',
                      f'local e{i}: E{i} = "yes"', f'if e{i} == "yes" then',
                      f'   total = total + {expr}', 'end']
        elif kind == 8:
            lines += [f'local x{i}: number = 0', 'repeat', f'   x{i} = x{i} + 1',
                      f'until x{i} == 3', f'total = total + {expr} * x{i}']
            value *= 3
        else:
            lines += [f'local function pair{i}(x: number): number, number',
                      '   return x, 2', 'end', f'local a{i}, b{i} = pair{i}({expr})',
                      f'total = total + a{i} + b{i}']
            value += 2
        expected += value
    lines += ['return total', '']
    return '\n'.join(lines), expected


def mutate(rng: random.Random, source: bytes) -> bytes:
    for _ in range(rng.randrange(1, 6)):
        pos = rng.randrange(len(source) + 1)
        end = min(len(source), pos + rng.randrange(1, 25))
        op = rng.randrange(6)
        if op == 0:
            source = source[:pos] + source[end:]
        elif op == 1:
            source = source[:pos] + rng.choice(TOKENS).encode() + source[pos:]
        elif op == 2:
            source = source[:pos]  # incomplete editor buffer
        elif op == 3:
            source = source[:pos] + source[pos:end] * rng.randrange(2, 5) + source[pos:]
        elif op == 4:
            source = source[:pos] + bytes([rng.randrange(256)]) + source[end:]
        else:
            source = source[:pos] + b'\n--[=[' + source[pos:] + b']=]\n'
    return source


def case_for(seed: int, index: int, corpus: list[bytes], max_depth: int = 128, profile: str = 'upstream') -> Case:
    # Each case is independently addressable; scheduling/jobs never affect its bytes.
    rng = random.Random((seed << 64) ^ index)
    source, expected = valid_program(rng)
    selected_profile = profile
    profile = index % 8
    if profile == 0:
        return Case(source.encode(), 'grammar', expected, seed, index)
    if profile == 1:
        # Metamorphic alpha renaming plus trivia; preserve the independent numeric oracle.
        source = re.sub(r'\btotal\b', 'renamed_total', source)
        source = '-- metamorphic\n' + source.replace('\n', '\n-- trivia\n')
        return Case(source.encode(), 'metamorphic', expected, seed, index)
    if profile == 2:
        source = mutate(rng, source.encode())
        return Case(source, 'editor', None, seed, index)
    if profile == 3:
        source = ' '.join(rng.choice(TOKENS) for _ in range(rng.randrange(1, 150)))
        return Case(source.encode(), 'tokens', None, seed, index)
    if profile == 4:
        depth = rng.choice([min(8, max_depth), min(16, max_depth), min(32, max_depth), max_depth])
        style = rng.randrange(4)
        if style == 0:
            source = 'return ' + '(' * depth + '1' + ')' * depth
        elif style == 1:
            source = 'do\n' * depth + 'local n: number = 1\n' + 'end\n' * depth
        elif style == 2:
            source = 'local type T = ' + '{' * depth + 'number' + '}' * depth
        else:
            source = '\n'.join(f'local type T{i} = ' + ('number' if i == 0 else f'T{i-1}') for i in range(depth))
        # Deep inputs are robustness probes, not guaranteed accepted beyond implementation limits.
        return Case(source.encode(), 'deep', None, seed, index)
    if profile == 5:
        original = rng.choice(corpus) if corpus else source.encode()
        return Case(mutate(rng, original), 'corpus-mutation', None, seed, index)
    if profile == 6:
        # Valid wide programs exercise scopes, type declarations and repeated lowering.
        source, expected = valid_program(rng, 40)
        return Case(source.encode(), 'wide', expected, seed, index)
    original = corpus[(index // 8) % len(corpus)] if corpus else source.encode()
    if selected_profile == 'tl-ng' and index % 16 == 15:
        original = original[:rng.randrange(len(original) + 1)]
        return Case(original, 'extension-prefix', None, seed, index)
    return Case(original, 'corpus', None, seed, index)


def limits(memory_mb: int, seconds: float):
    """Called only by the single-threaded launch helper, before exec (POSIX)."""
    import resource
    resource.setrlimit(resource.RLIMIT_CPU, (max(1, math.ceil(seconds)), max(2, math.ceil(seconds) + 1)))
    resource.setrlimit(resource.RLIMIT_FSIZE, (4 * 1024 * 1024, 4 * 1024 * 1024))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    if memory_mb:
        # LuaJIT reserves a large virtual address arena: opt in rather than breaking its startup.
        resource.setrlimit(resource.RLIMIT_AS, (memory_mb * 1024 ** 2,) * 2)


def run_case(case: Case, lua: str, root: Path, target: str, timeout: float,
             memory_mb: int = 0, reference_root: Path | None = None) -> dict:
    with tempfile.TemporaryDirectory(prefix='teal-fuzz-') as tmp:
        tmpdir = Path(tmp)
        source = tmpdir / 'input.tl'
        source.write_bytes(case.source)
        # Launch through Python to set rlimits without unsafe preexec_fn in worker threads.
        command = [sys.executable, str(HERE / 'fuzz.py'), '_launch', str(memory_mb), str(timeout),
                   lua, str(HERE / 'worker.lua'), str(root.resolve()), str(source), target,
                   str(case.expected) if case.expected is not None else '-']
        start = time.monotonic()
        env = os.environ.copy()
        env.pop('LUA_INIT', None)
        for key in list(env):
            if key.startswith(('LUA_INIT_', 'LUA_PATH', 'LUA_CPATH', 'TL_PATH')):
                env.pop(key)
        with (tmpdir / 'stdout').open('wb') as out, (tmpdir / 'stderr').open('wb') as err:
            proc = subprocess.Popen(command, cwd=tmp, env=env, stdout=out, stderr=err, start_new_session=True)
            try:
                proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
                return {'status': 'failure', 'stage': 'timeout', 'message': f'exceeded {timeout}s',
                        'seconds': time.monotonic() - start}
            except BaseException:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
                raise
        stdout = (tmpdir / 'stdout').read_bytes()[-65536:].decode('utf-8', 'replace')
        stderr = (tmpdir / 'stderr').read_bytes()[-65536:].decode('utf-8', 'replace')
        result = None
        for line in stdout.splitlines():
            if line.startswith('FUZZ_RESULT '):
                try:
                    result = json.loads(line[len('FUZZ_RESULT '):])
                except json.JSONDecodeError:
                    pass
        if result is None:
            result = {'status': 'failure', 'stage': 'process', 'message': f'exit {proc.returncode}',
                      'stdout': stdout, 'stderr': stderr}
        elif proc.returncode != 0 and result.get('status') == 'ok':
            result = {'status': 'failure', 'stage': 'process', 'message': f'exit {proc.returncode}', 'stderr': stderr}
        result['seconds'] = time.monotonic() - start
        if reference_root and result['status'] == 'ok':
            reference = run_case(case, lua, reference_root, target, timeout, memory_mb)
            if reference['status'] != 'ok':
                result = {'status': 'failure', 'stage': 'differential-reference', 'reference': reference}
            elif reference['disposition'] != result['disposition']:
                result = {'status': 'failure', 'stage': 'differential', 'candidate': result, 'reference': reference}
        return result


def fingerprint(result: dict) -> str:
    # Match crash site, not source-dependent values or diagnostic locations, during reduction.
    message = result.get('message', '').split('\n')[0]
    message = re.sub(r':\d+:', ':LINE:', message)
    if 'invariant:' in message:
        message = message.split('invariant:', 1)[1].split(':', 1)[0]
    return result['stage'] + ':' + message


def save_failure(directory: Path, case: Case, result: dict, config: dict) -> Path:
    digest = hashlib.sha256(case.source).hexdigest()[:16]
    stem = f'{case.seed}-{case.index}-{config["target"]}-{digest}'
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / (stem + '.tl')
    path.write_bytes(case.source)
    metadata = {'version': VERSION, 'seed': case.seed, 'index': case.index, 'profile': case.profile,
                'expected': case.expected, 'sha256': hashlib.sha256(case.source).hexdigest(),
                'result': result, **config}
    path.with_suffix('.json').write_text(json.dumps(metadata, indent=2) + '\n')
    return path


def minimize(source: bytes, predicate, attempts: int = 100, seconds: float = 60) -> tuple[bytes, int]:
    """Bounded byte-level ddmin. Retains only candidates with the same failure fingerprint."""
    deadline = time.monotonic() + seconds
    calls, granularity = 0, 2
    while source and calls < attempts and time.monotonic() < deadline:
        chunk = max(1, math.ceil(len(source) / granularity))
        reduced = False
        for offset in range(0, len(source), chunk):
            if calls >= attempts or time.monotonic() >= deadline:
                break
            candidate = source[:offset] + source[offset + chunk:]
            calls += 1
            if predicate(candidate):
                source, granularity, reduced = candidate, max(2, granularity - 1), True
                break
        if not reduced:
            if granularity >= len(source):
                break
            granularity = min(len(source), granularity * 2)
    return source, calls


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--seed', type=int, default=1)
    p.add_argument('--cases', type=int, default=1000)
    p.add_argument('--start', type=int, default=0, help='first independently reproducible case index')
    p.add_argument('--seconds', type=float, default=0, help='campaign wall-clock budget (0 = cases only)')
    p.add_argument('--timeout', type=float, default=5, help='wall seconds per isolated case')
    p.add_argument('--jobs', type=int, default=1)
    p.add_argument('--lua', default=shutil.which('lua') or 'lua')
    p.add_argument('--root', type=Path, default=ROOT)
    p.add_argument('--reference-root', type=Path, help='optional second checkout: compare acceptance; may expose intentional changes')
    p.add_argument('--targets', default='5.1,5.3', help='comma-separated generation target matrix')
    p.add_argument('--corpus', type=Path, action='append', default=[])
    p.add_argument('--profile', choices=('upstream', 'tl-ng'), default='upstream',
                   help='tl-ng adds optional custom syntax/editor regression corpus')
    p.add_argument('--max-input', type=int, default=131072, help='maximum corpus/generated bytes')
    p.add_argument('--max-depth', type=int, default=128)
    p.add_argument('--memory-mb', type=int, default=0, help='optional POSIX virtual address limit; 0 leaves VM unlimited')
    p.add_argument('--output', type=Path, default=ROOT / '_temp/fuzz')
    p.add_argument('--replay', type=Path, help='replay .tl file; reads adjacent saved .json oracle/config if present')
    p.add_argument('--minimize', action='store_true', help='reduce replay failure using a bounded ddmin pass')
    p.add_argument('--minimize-attempts', type=int, default=100)
    p.add_argument('--minimize-seconds', type=float, default=60)
    p.add_argument('--stop-on-failure', action='store_true')
    return p


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if min(args.cases, args.start, args.memory_mb) < 0 or args.jobs < 1 or args.timeout <= 0 or args.seconds < 0 or args.max_input < 1 or args.max_depth < 1:
        parser().error('counts/budgets must be nonnegative, jobs/timeout/input/depth positive')
    located_lua = shutil.which(args.lua)
    if not located_lua:
        parser().error(f'Lua interpreter not found/executable: {args.lua}')
    args.lua = str(Path(located_lua).resolve())
    if not (args.root / 'teal/api/v2.lua').is_file():
        parser().error(f'compiler root does not contain teal/api/v2.lua: {args.root}')
    if args.reference_root and not (args.reference_root / 'teal/api/v2.lua').is_file():
        parser().error(f'reference root does not contain teal/api/v2.lua: {args.reference_root}')
    args.output.mkdir(parents=True, exist_ok=True)
    targets = args.targets.split(',')
    if any(t not in ('5.1', '5.2', '5.3', '5.4', '5.5') for t in targets):
        parser().error('unsupported generation target')
    try:
        revision = subprocess.run(['git', '-C', str(args.root), 'rev-parse', 'HEAD'],
                                  capture_output=True, text=True, timeout=2).stdout.strip() or None
    except (OSError, subprocess.TimeoutExpired):
        revision = None
    config = {'compiler_revision': revision, 'python_version': sys.version.split()[0], 'root': str(args.root.resolve()), 'lua': args.lua, 'target': targets[0],
              'timeout': args.timeout, 'memory_mb': args.memory_mb,
              'reference_root': str(args.reference_root.resolve()) if args.reference_root else None}
    def execute(case, target):
        return run_case(case, args.lua, args.root, target, args.timeout, args.memory_mb, args.reference_root)
    if args.replay:
        meta_path = args.replay.with_suffix('.json')
        meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
        case = Case(args.replay.read_bytes(), meta.get('profile', 'replay'), meta.get('expected'), meta.get('seed', 0), meta.get('index', 0))
        target = meta.get('target', targets[0])
        result = execute(case, target)
        print(json.dumps(result, indent=2))
        if args.minimize and result['status'] != 'ok' and case.expected is not None:
            print('Reduction refused: generated-program validity/semantic oracles cannot survive arbitrary source deletion.', file=sys.stderr)
        if args.minimize and result['status'] != 'ok' and case.expected is None:
            signature = fingerprint(result)
            def fails(source):
                candidate = execute(dataclasses.replace(case, source=source), target)
                return candidate['status'] != 'ok' and fingerprint(candidate) == signature
            reduced, calls = minimize(case.source, fails, args.minimize_attempts, args.minimize_seconds)
            reduced_case = dataclasses.replace(case, source=reduced)
            result = execute(reduced_case, target)
            path = save_failure(args.output / 'minimized', reduced_case, result, {**config, 'target': target})
            print(f'minimized {len(case.source)} -> {len(reduced)} bytes in {calls} attempts: {path}')
        return int(result['status'] != 'ok')
    corpus = []
    directories = [HERE / 'corpus', *args.corpus]
    if args.profile == 'tl-ng':
        directories.append(HERE / 'profiles/tl-ng')
    for directory in directories:
        paths = [directory] if directory.is_file() else sorted(directory.rglob('*.tl'))
        for path in paths:
            if path.stat().st_size <= args.max_input:
                corpus.append(path.read_bytes())
    counts: dict[str, int] = {}
    failure_count, completed, submitted = 0, 0, 0
    started = time.monotonic()
    def jobs():
        for index in range(args.start, args.start + args.cases):
            case = case_for(args.seed, index, corpus, args.max_depth, args.profile)
            if len(case.source) > args.max_input:
                case = dataclasses.replace(case, source=case.source[:args.max_input], expected=None, profile='truncated')
            for target in targets:
                yield case, target
    iterator = iter(jobs())
    pending = {}
    stopped = False
    with (args.output / 'results.jsonl').open('w') as log, concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        while True:
            while not stopped and len(pending) < args.jobs:
                if args.seconds and time.monotonic() - started >= args.seconds:
                    stopped = True
                    break
                item = next(iterator, None)
                if item is None:
                    stopped = True
                    break
                case, target = item
                pending[pool.submit(execute, case, target)] = item
                submitted += 1
            if not pending:
                break
            done, _ = concurrent.futures.wait(pending, return_when=concurrent.futures.FIRST_COMPLETED)
            for future in done:
                case, target = pending.pop(future)
                result = future.result()
                completed += 1
                counts[case.profile] = counts.get(case.profile, 0) + 1
                row = {'seed': case.seed, 'index': case.index, 'profile': case.profile, 'target': target, **result}
                log.write(json.dumps(row) + '\n'); log.flush()
                if result['status'] != 'ok':
                    failure_count += 1
                    path = save_failure(args.output / 'failures', case, result, {**config, 'target': target})
                    print(f'FAIL {case.index}/{target} {result["stage"]}: {path}', flush=True)
                    if args.stop_on_failure:
                        stopped = True
                if completed % 100 == 0:
                    print(f'{completed} checks, {failure_count} failures, {time.monotonic()-started:.1f}s', flush=True)
    summary = {'version': VERSION, 'seed': args.seed, 'completed': completed, 'failures': failure_count,
               'seconds': time.monotonic()-started, 'profiles': counts, 'targets': targets,
               'start': args.start, 'cases_requested': args.cases, 'submitted': submitted,
               'max_depth': args.max_depth, 'corpus_entries': len(corpus), 'grammar_profile': args.profile, **config}
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
    return int(failure_count > 0)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '_launch':
        limits(int(sys.argv[2]), float(sys.argv[3]))
        os.execv(sys.argv[4], sys.argv[4:])
    sys.exit(main())
