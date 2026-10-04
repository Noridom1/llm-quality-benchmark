"""Streaming patch for inspect_ai's OpenAI completions provider (SciCode).

Loaded as ``sitecustomize.py`` on ``PYTHONPATH`` by benchmarks/scicode/run.sh.

Why: SciCode sets ``max_tokens=32784`` and GLM-5.2 emits a long CoT in
``reasoning_content`` before the final code. With the stock non-streaming
``client.chat.completions.create`` the server must buffer the entire generation
before sending anything, so the connection looks idle for the full
time-to-last-token and a server/LB idle timeout shorter than that kills the
request mid-CoT. Streaming keeps the connection alive with token frames.

inspect's ``generate_completions`` asserts the response is a ``ChatCompletion``
and feeds it to ``model_output_from_openai``; a raw async stream is not. So
this patch reimplements the direct (non-batcher) branch of
``generate_completions`` to request ``stream=True`` and accumulate the
``AsyncStream`` into a real ``ChatCompletion``; the rest of the contract
(``set_response``, ``chat_choices_from_openai``, ``model_output_from_openai``,
the BadRequestError/UnprocessableEntityError handling) is preserved verbatim.
The batcher path (incompatible with streaming) falls through to the original.

Disable with ``INSPECT_STREAM=0``.
"""

import inspect as _inspect
import os
from typing import Literal

from openai import BadRequestError, UnprocessableEntityError
from openai._types import NOT_GIVEN
from openai.types.chat.chat_completion import (
    ChatCompletion,
    ChatCompletionMessage,
    Choice,
)

from inspect_ai.log._samples import set_active_model_event_call
from inspect_ai.model._model_call import as_error_response
from inspect_ai.model._openai import (
    chat_choices_from_openai,
    messages_to_openai,
    model_output_from_openai,
    openai_chat_tool_choice,
    openai_chat_tools,
    openai_handle_bad_request,
    openai_media_filter,
)
from inspect_ai.model._providers import openai_completions as _oc
from inspect_ai.model._providers.openai_completions import (
    completion_params_completions,
)

_ORIG_GENERATE_COMPLETIONS = _oc.generate_completions
_STREAM = os.getenv("INSPECT_STREAM", "1") != "0"


async def _accumulate_async_stream(stream) -> ChatCompletion:
    content_parts: list[str] = []
    role = None
    finish = None
    model = None
    id_ = None
    usage = None
    async for chunk in stream:
        id_ = id_ or getattr(chunk, "id", None)
        model = model or getattr(chunk, "model", None)
        if getattr(chunk, "usage", None):
            usage = chunk.usage
        if not getattr(chunk, "choices", None):
            continue
        ch = chunk.choices[0]
        delta = getattr(ch, "delta", None)
        if delta is None:
            continue
        if getattr(delta, "role", None):
            role = delta.role
        if getattr(delta, "content", None):
            content_parts.append(delta.content)
        if getattr(ch, "finish_reason", None):
            finish = ch.finish_reason
    message = ChatCompletionMessage(role=role or "assistant", content="".join(content_parts) or None)
    choice = Choice(index=0, message=message, finish_reason=finish or "stop")
    # GLM-5.2 emits no usage chunk in streaming mode; leave usage None
    # (model_output_from_openai handles completion.usage=None gracefully).
    return ChatCompletion(
        id=id_ or "stream-accumulated",
        object="chat.completion",
        created=0,
        model=model or "",
        choices=[choice],
        usage=usage,
    )


async def generate_completions(*args, **kwargs):
    if not _STREAM:
        return await _ORIG_GENERATE_COMPLETIONS(*args, **kwargs)

    # Bind to the real signature so both positional and keyword calls work.
    bound = _inspect.signature(_ORIG_GENERATE_COMPLETIONS).bind(*args, **kwargs)
    bound.apply_defaults()
    p = bound.arguments
    client = p["client"]
    http_hooks = p["http_hooks"]
    input = p["input"]
    tools = p["tools"]
    tool_choice = p["tool_choice"]
    config = p["config"]
    prompt_cache_key = p["prompt_cache_key"]
    prompt_cache_retention = p["prompt_cache_retention"]
    safety_identifier = p["safety_identifier"]
    openai_api = p["openai_api"]
    batcher = p["batcher"]

    # Only the direct (non-batcher) path can stream; batching cannot.
    if batcher is not None:
        return await _ORIG_GENERATE_COMPLETIONS(*args, **kwargs)

    request_id = http_hooks.start_request()

    OPENAI_IMAGE_DEFAULT_TOKENS = 4096
    if "vision" in openai_api.model_family():
        if isinstance(config.max_tokens, int):
            config.max_tokens = max(config.max_tokens, OPENAI_IMAGE_DEFAULT_TOKENS)
        else:
            config.max_tokens = OPENAI_IMAGE_DEFAULT_TOKENS

    system_role: Literal["developer", "system"] = (
        "developer" if (openai_api.is_o_series() or openai_api.is_gpt_5()) else "system"
    )

    request = dict(
        messages=await messages_to_openai(input, system_role),
        tools=openai_chat_tools(tools) if len(tools) > 0 else NOT_GIVEN,
        tool_choice=openai_chat_tool_choice(tool_choice) if len(tools) > 0 else NOT_GIVEN,
        extra_headers={http_hooks.REQUEST_ID_HEADER: request_id} | (config.extra_headers or {}),
        stream=True,
        **completion_params_completions(openai_api, config, len(tools) > 0),
    )
    if isinstance(prompt_cache_key, str):
        request["prompt_cache_key"] = prompt_cache_key
    if isinstance(prompt_cache_retention, str):
        request["prompt_cache_retention"] = prompt_cache_retention
    if isinstance(safety_identifier, str):
        request["safety_identifier"] = safety_identifier

    model_call = set_active_model_event_call(request=request, filter=openai_media_filter)

    try:
        stream = await client.chat.completions.create(**request)
        completion = await _accumulate_async_stream(stream)
        assert isinstance(completion, ChatCompletion)
        model_call.set_response(completion.model_dump(), http_hooks.end_request(request_id))
        choices = chat_choices_from_openai(completion, tools)
        return model_output_from_openai(completion, choices), model_call
    except (BadRequestError, UnprocessableEntityError) as e:
        model_call.set_error(as_error_response(e.body), http_hooks.end_request(request_id))
        return openai_handle_bad_request(openai_api.service_model_name(), e), model_call


_oc.generate_completions = generate_completions
