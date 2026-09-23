"""Streaming + reasoning-content patch for lm-eval 0.4.12's OpenAI chat adapter.

Loaded as ``sitecustomize.py`` on ``PYTHONPATH`` by scripts/run_gpqa.sh,
run_mmlu_pro.sh, and run_hle.sh (see EVALS.md for the InferenceX precedent).

Why: GLM-5.2 emits a long CoT in ``reasoning_content`` before the final answer.
With the stock non-streaming adapter the server must buffer the *entire* trace
before sending anything, so the connection looks idle for the full
time-to-last-token and server/LB idle timeouts kill the request mid-reasoning.
Streaming keeps the connection alive with token frames and resets idle timers.

Stock lm-eval 0.4.12 ``TemplateAPI.model_call`` does
``requests.post(...).json()`` and has **no** SSE branch, so merely setting
``stream: True`` in the payload (the InferenceX 0.4.9.2 patch) would try to
JSON-parse an SSE body and crash on this version. This patch therefore also
overrides ``model_call`` / ``amodel_call`` to consume the SSE stream when the
payload requests streaming, and returns the accumulated response in the exact
dict shape ``parse_generations`` expects (``choices[i].message.content`` or the
``reasoning_content`` fallback when content is empty).
"""

import json

from lm_eval.models import api_models
from lm_eval.models.openai_completions import (
    LocalChatCompletion,
    OpenAIChatCompletion,
)

# ------------ SSE accumulation ------------------------------------------------


def _new_stream_state():
    return {
        "content": {},
        "reasoning_content": {},
        "role": {},
        "tool_calls": {},
        "finish_reason": {},
        "usage": None,
        "model": None,
        "id": None,
        "created": None,
    }


def _consume_sse_data(data, state):
    """Consume one SSE ``data:`` payload. Returns True on stream terminator."""
    if data.strip() == "[DONE]":
        return True
    try:
        chunk = json.loads(data)
    except json.JSONDecodeError:
        return False
    state["id"] = state["id"] or chunk.get("id")
    state["model"] = state["model"] or chunk.get("model")
    state["created"] = state["created"] or chunk.get("created")
    if chunk.get("usage"):
        state["usage"] = chunk["usage"]
    for choice in chunk.get("choices") or []:
        idx = choice.get("index", 0)
        delta = choice.get("delta") or {}
        if delta.get("role"):
            state["role"][idx] = delta["role"]
        if delta.get("content"):
            state["content"].setdefault(idx, "")
            state["content"][idx] += delta["content"]
        if delta.get("reasoning_content"):
            state["reasoning_content"].setdefault(idx, "")
            state["reasoning_content"][idx] += delta["reasoning_content"]
        if delta.get("tool_calls"):
            for tc in delta["tool_calls"]:
                tidx = tc.get("index", 0)
                slot = state["tool_calls"].setdefault(
                    tidx,
                    {"id": None, "type": "function", "function": {"name": "", "arguments": ""}},
                )
                if tc.get("id"):
                    slot["id"] = tc["id"]
                if tc.get("type"):
                    slot["type"] = tc["type"]
                fn = tc.get("function") or {}
                if fn.get("name"):
                    slot["function"]["name"] += fn["name"]
                if fn.get("arguments"):
                    slot["function"]["arguments"] += fn["arguments"]
        if choice.get("finish_reason"):
            state["finish_reason"][idx] = choice["finish_reason"]
    return False


def _stream_result(state):
    indices = sorted(
        set(state["content"]) | set(state["reasoning_content"]) | set(state["finish_reason"]) | {0}
    )
    choices = []
    for idx in indices:
        content = state["content"].get(idx, "")
        reasoning = state["reasoning_content"].get(idx, "")
        msg = {"role": state["role"].get(idx, "assistant")}
        # Mirror parse_generations' fallback: prefer content, else reasoning.
        if content:
            msg["content"] = content
        elif reasoning:
            msg["content"] = reasoning
        else:
            msg["content"] = ""
        if reasoning:
            msg["reasoning_content"] = reasoning
        if state["tool_calls"]:
            msg["tool_calls"] = [state["tool_calls"][k] for k in sorted(state["tool_calls"])]
        choices.append(
            {
                "index": idx,
                "message": msg,
                "finish_reason": state["finish_reason"].get(idx, "stop"),
            }
        )
    return {
        "id": state["id"] or "stream-accumulated",
        "object": "chat.completion",
        "model": state["model"] or "",
        "created": state["created"],
        "choices": choices,
        # GLM-5.2 does not emit a usage chunk; supply a zero fallback so any
        # downstream code reading .usage does not KeyError.
        "usage": state["usage"]
        or {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }


def _parse_sse_stream(response):
    """Accumulate a streaming ``requests.Response`` into a chat-completion dict."""
    state = _new_stream_state()
    for line in response.iter_lines(decode_unicode=True):
        if line and line.startswith("data: "):
            if _consume_sse_data(line[6:], state):
                break
        elif line and line.startswith("data:"):
            if _consume_sse_data(line[5:], state):
                break
    return _stream_result(state)


async def _parse_sse_stream_async(response):
    """Accumulate a streaming ``aiohttp`` response into a chat-completion dict."""
    state = _new_stream_state()
    buffer = ""
    async for raw_chunk in response.content:
        buffer += raw_chunk.decode("utf-8", errors="replace")
        while "\n" in buffer:
            line, buffer = buffer.split("\n", 1)
            line = line.rstrip("\r")
            if line.startswith("data: "):
                if _consume_sse_data(line[6:], state):
                    return _stream_result(state)
            elif line.startswith("data:"):
                if _consume_sse_data(line[5:], state):
                    return _stream_result(state)
    for line in buffer.split("\n"):
        line = line.rstrip("\r")
        if line.startswith("data: "):
            _consume_sse_data(line[6:], state)
        elif line.startswith("data:"):
            _consume_sse_data(line[5:], state)
    return _stream_result(state)


# ------------ payload: request streaming --------------------------------------


_openai_create_payload = OpenAIChatCompletion._create_payload


def _create_streaming_payload(self, *args, **kwargs):
    payload = _openai_create_payload(self, *args, **kwargs)
    payload["stream"] = True
    return payload


OpenAIChatCompletion._create_payload = _create_streaming_payload

# Expose the accumulators on api_models (mirrors the InferenceX patch) so tests
# and any future stock code can find them by name.
api_models._parse_sse_stream = _parse_sse_stream
api_models._parse_sse_stream_async = _parse_sse_stream_async


# ------------ model_call / amodel_call: consume the stream ---------------------
# Stock lm-eval 0.4.12 ignores payload["stream"] and does .json(); we branch on
# it, stream the HTTP body, and return the accumulated dict. The non-stream
# branch is preserved verbatim so loglikelihood / other adapters still work.


_orig_model_call = api_models.TemplateAPI.model_call
_orig_amodel_call = api_models.TemplateAPI.amodel_call

try:
    import requests as _requests
except ImportError:  # pragma: no cover - requests is a hard dep of TemplateAPI
    _requests = None


def model_call(self, messages, *, generate=True, gen_kwargs=None, **kwargs):
    import copy as _copy

    gen_kwargs = _copy.deepcopy(gen_kwargs)
    payload = self._create_payload(
        self.create_message(messages),
        generate=generate,
        gen_kwargs=gen_kwargs,
        seed=self._seed,
        eos=self.eos_string,
        **kwargs,
    )
    stream = bool(payload.get("stream"))
    try:
        if stream:
            response = _requests.post(
                self.base_url,
                json=payload,
                headers=self.header,
                verify=self.verify_certificate,
                stream=True,
                timeout=getattr(self, "timeout", None),
            )
            if not response.ok:
                from lm_eval.api.registry import eval_logger as _log

                _log.warning(
                    f"API request failed with error message: {response.text}. Retrying..."
                )
            response.raise_for_status()
            return _parse_sse_stream(response)
        # Non-streaming: identical to stock.
        response = _requests.post(
            self.base_url,
            json=payload,
            headers=self.header,
            verify=self.verify_certificate,
            timeout=getattr(self, "timeout", None),
        )
        if not response.ok:
            from lm_eval.api.registry import eval_logger as _log

            _log.warning(
                f"API request failed with error message: {response.text}. Retrying..."
            )
        response.raise_for_status()
        return response.json()
    except Exception:
        # Re-raise so the tenacity retry wrapper in generate_until can retry.
        raise


async def amodel_call(self, session, sem, messages, *, generate=True, cache_keys=None, ctxlens=None, gen_kwargs=None, **kwargs):
    import copy as _copy

    from lm_eval.api.registry import eval_logger as _log
    from lm_eval.models.api_models import LMEVAL_MODEL_NONE_ANSWER_PLACEHOLDER

    gen_kwargs = _copy.deepcopy(gen_kwargs)
    payload = self._create_payload(
        self.create_message(messages),
        generate=generate,
        gen_kwargs=gen_kwargs,
        seed=self._seed,
        **kwargs,
    )
    cache_method = "generate_until" if generate else "loglikelihood"
    acquired = await sem.acquire()
    try:
        blocked = False
        async with session.post(
            self.base_url,
            json=payload,
            headers=self.header,
        ) as response:
            if not response.ok:
                error_text = await response.text()
                _log.warning(
                    f"API request failed! Status code: {response.status}, "
                    f"Response text: {error_text}. Retrying..."
                )
                # Gateway WAF keyword filter (e.g. "detected keyword: 123") is a
                # permanent, content-based 400 -- retrying resends the exact same
                # payload and will fail identically forever, which otherwise
                # crashes the whole asyncio.gather (no per-task isolation in
                # lm-eval 0.4.12). Score it as an empty/incorrect completion
                # instead so the rest of the batch can finish.
                if response.status == 400 and "detected keyword" in error_text:
                    _log.warning(
                        "Request permanently blocked by gateway keyword filter "
                        "(not a transient error) -- scoring as empty completion "
                        "instead of retrying."
                    )
                    blocked = True
            if not blocked:
                response.raise_for_status()
                if bool(payload.get("stream")):
                    outputs = await _parse_sse_stream_async(response)
                else:
                    outputs = await response.json()
        if blocked:
            outputs = {
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": ""},
                        "finish_reason": "content_filter",
                    }
                ]
            }
        tmp_answers = (
            self.parse_generations(outputs=outputs)
            if generate
            else self.parse_logprobs(outputs=outputs, tokens=messages, ctxlens=ctxlens)
        )
        answers = []
        for a in tmp_answers:
            if a is None:
                _log.warning(
                    f"API returned null content. Content filled with `LMEVAL_MODEL_NONE_ANSWER_PLACEHOLDER = {LMEVAL_MODEL_NONE_ANSWER_PLACEHOLDER}`. Check reasoning_content field or generation limits."
                )
                answers.append(LMEVAL_MODEL_NONE_ANSWER_PLACEHOLDER)
            else:
                answers.append(a)
        if cache_keys:
            for res, cache in zip(answers, cache_keys):
                self.cache_hook.add_partial(cache_method, cache, res)
        return answers
    except BaseException as e:
        _log.error(f"Exception:{repr(e)}, {locals().get('outputs', '(no outputs)')}, retrying.")
        raise
    finally:
        if acquired:
            sem.release()


api_models.TemplateAPI.model_call = model_call
api_models.TemplateAPI.amodel_call = amodel_call


# ------------ parse_generations: reasoning fallback ---------------------------
# When the model puts everything in reasoning_content and leaves content empty,
# use the reasoning trace as the answer (matches InferenceX behavior).


def _parse_generations(outputs, **kwargs):
    results = []
    if not isinstance(outputs, list):
        outputs = [outputs]
    for output in outputs or []:
        try:
            choices = output.get("choices", [])
            parsed = ["" for _ in choices]
            for choice in choices:
                index = choice.get("index", 0)
                message = choice.get("message") or {}
                content = message.get("content")
                if content in (None, "", []):
                    content = message.get("reasoning_content") or ""
                parsed[index] = content
        except Exception:
            parsed = [""]
        results.extend(parsed)
    return results


LocalChatCompletion.parse_generations = staticmethod(_parse_generations)
