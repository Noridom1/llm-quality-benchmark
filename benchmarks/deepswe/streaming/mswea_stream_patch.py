"""Streaming patch for mini-swe-agent's litellm model (DeepSWE / pier).

This file is NOT run on the host. The host-side ``sitecustomize.py`` (in
``benchmarks/deepswe/streaming/``) writes this exact text into pier's agent
container at ``/opt/mswea-stream/mswea_stream_patch.py`` (during the pier
install phase, which has network) and sets ``PYTHONPATH=/opt/mswea-stream`` in
the mini-swe-agent subprocess env (``MiniSweAgent.build_process_env``). Python
auto-imports the sibling ``sitecustomize.py`` at interpreter startup, which in
turn imports this module and applies the patch.

Why: pier runs ``mini-swe-agent`` (installed from PyPI, currently 2.4.6) inside
a Docker container. GLM-5.2 emits a long CoT in ``reasoning_content``; the stock
non-streaming ``litellm.completion`` buffers the entire generation and the
connection idle-times-out mid-CoT. Streaming keeps the connection alive with
token frames. mini-swe-agent 2.4.6's ``LitellmModel._query`` returns the raw
``litellm.completion`` result and assumes it is a ``ModelResponse`` -- a
streaming call returns a *generator* of chunks, so naively setting
``stream=True`` breaks ``query()``. This patch sets ``stream=True`` when safe and
rebuilds the full ``ModelResponse`` via ``litellm.stream_chunk_builder`` so the
rest of ``query()`` (``choices[0].message``, ``model_dump()``, cost,
``tool_calls``) is unchanged.

Disable with ``MSWEA_STREAM=0``.
"""

import os

import litellm
from minisweagent.models import litellm_model as _lm
from minisweagent.models.utils.actions_toolcall import BASH_TOOL

_STREAM = os.getenv("MSWEA_STREAM", "1") != "0"
_ORIG_QUERY = _lm.LitellmModel._query


def _query(self, messages, **kwargs):
    merged = self.config.model_kwargs | kwargs
    if _STREAM and not merged.get("stream"):
        merged["stream"] = True
    try:
        response = litellm.completion(
            model=self.config.model_name,
            messages=messages,
            # Preserve 2.4.6's hardcoded tool schema (the bash tool the agent
            # uses to act). Must not drop it, or the model can't call tools.
            tools=[BASH_TOOL],
            **merged,
        )
    except litellm.exceptions.AuthenticationError as e:
        e.message += (
            " You can permanently set your API key with"
            " `mini-extra config set KEY VALUE`."
        )
        raise e
    # litellm.completion(stream=True) yields a generator of chunks, not a
    # ModelResponse. Reassemble into one via stream_chunk_builder so query()'s
    # downstream contract (choices[0].message incl. tool_calls, model_dump(),
    # cost) is unchanged.
    if _STREAM and merged.get("stream"):
        response = litellm.stream_chunk_builder(list(response), messages=messages)
    return response


if _STREAM:
    _lm.LitellmModel._query = _query
