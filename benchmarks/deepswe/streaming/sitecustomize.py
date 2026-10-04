"""Host-side streaming patch for DeepSWE (pier -> mini-swe-agent in container).

Loaded as ``sitecustomize.py`` on ``PYTHONPATH`` by benchmarks/deepswe/run.sh /
benchmarks/deepswe/run_batches.sh (``uv tool run --from datacurve-pier`` runs pier
as a host Python process, so Python auto-imports this module at startup).

Why: pier runs the ``mini-swe-agent`` CLI inside a per-task Docker container.
mini-swe-agent is installed from PyPI (2.4.6) into that container, so the local
editable ``minisweagent`` patch used by SWE-bench Pro does NOT apply here, and
naively setting ``stream=True`` breaks 2.4.6's ``_query`` (it would return a
generator instead of a ModelResponse). This patch makes pier bake an in-container
streaming patch (``mswea_stream_patch.py``) into the image at install time (which
has network) and export ``PYTHONPATH=/opt/mswea-stream`` so the mini-swe-agent
subprocess auto-loads it via its own ``sitecustomize.py``.

It monkeypatches three methods on ``MiniSweAgent``:
  * ``install_spec`` -- appends an ``InstallStep`` that ``mkdir -p /opt/mswea-stream``
    and writes both ``mswea_stream_patch.py`` and a ``sitecustomize.py`` there.
  * ``build_process_env`` -- adds ``PYTHONPATH=/opt/mswea-stream`` (prepended) so
    the container's mini-swe-agent process imports our ``sitecustomize`` first.

The in-container patch is read from this file's sibling ``mswea_stream_patch.py``
and base64-embedded in the install step, so pier needs no host filesystem access
to the patch at install time (only at the moment it builds the install spec),
and there is no extra network fetch inside the container.

Disable everything with ``MSWEA_STREAM=0``.
"""

import base64
import os
from pathlib import Path

_PATCH_DIR = Path(__file__).resolve().parent
_PATCH_FILE = _PATCH_DIR / "mswea_stream_patch.py"

_STREAM = os.getenv("MSWEA_STREAM", "1") != "0"

# sitecustomize.py written into the container at /opt/mswea-stream/. Python
# auto-imports it at startup; it just loads the real patch module.
_CONTAINER_SITECUSTOMIZE = """\
import os, sys
if os.getenv("MSWEA_STREAM", "1") != "0":
    try:
        import mswea_stream_patch  # noqa: F401  (applies patch on import)
    except Exception as _e:
        sys.stderr.write("mswea_stream_patch failed: %r\\n" % (_e,))
"""


def _apply():
    if not _STREAM or not _PATCH_FILE.is_file():
        return
    try:
        from pier.agents.installed.mini_swe_agent import MiniSweAgent
        from pier.models.agent.install import InstallStep
    except Exception:
        # pier not importable in this interpreter -- nothing to do.
        return
    # Idempotency: never double-wrap if this module is re-imported.
    if getattr(MiniSweAgent, "_mswea_stream_patched", False):
        return

    patch_b64 = base64.b64encode(_PATCH_FILE.read_bytes()).decode("ascii")
    site_b64 = base64.b64encode(_CONTAINER_SITECUSTOMIZE.encode()).decode("ascii")

    _orig_install_spec = MiniSweAgent.install_spec
    _orig_build_process_env = MiniSweAgent.build_process_env

    def install_spec(self):
        spec = _orig_install_spec(self)
        # Append after pier's own install steps (which install uv + mini-swe-agent).
        # Runs as the agent user (no root needed): just write two files into a dir.
        write_step = InstallStep(
            user="agent",
            run=(
                "set -euo pipefail\n"
                "mkdir -p /opt/mswea-stream\n"
                f"echo '{patch_b64}' | base64 -d > /opt/mswea-stream/mswea_stream_patch.py\n"
                f"echo '{site_b64}' | base64 -d > /opt/mswea-stream/sitecustomize.py\n"
                # Sanity-check it parses; a SyntaxError here fails the install
                # loudly rather than silently disabling streaming.
                'python_bin="$(head -n 1 "$(command -v mini-swe-agent)" | sed \'s/^#!//\')"\n'
                '"$python_bin" -c "import ast; ast.parse(open(\'/opt/mswea-stream/mswea_stream_patch.py\').read())"\n'
            ),
        )
        spec.steps.append(write_step)
        return spec

    def build_process_env(self, base=None, **kwargs):
        env = _orig_build_process_env(self, base, **kwargs)
        if _STREAM:
            # Prepend our dir so our sitecustomize wins over any bundled one.
            existing = env.get("PYTHONPATH", "")
            env["PYTHONPATH"] = (
                f"/opt/mswea-stream{(':' + existing) if existing else ''}"
            )
        return env

    MiniSweAgent.install_spec = install_spec
    MiniSweAgent.build_process_env = build_process_env
    MiniSweAgent._mswea_stream_patched = True


_apply()
