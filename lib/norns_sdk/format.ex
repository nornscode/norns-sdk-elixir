defmodule NornsSdk.Format do
  @moduledoc """
  Translates between the provider-neutral wire format (used by the Norns
  orchestrator) and ReqLLM's types.

  ## Neutral format

  Messages:
    - `%{"role" => "user", "content" => "text"}`
    - `%{"role" => "assistant", "content" => "text", "tool_calls" => [%{"id" => ..., "name" => ..., "arguments" => ...}]}`
    - `%{"role" => "tool", "tool_call_id" => "tc_1", "name" => "search", "content" => "result"}`

  Tool definitions:
    - `%{"name" => "search", "description" => "...", "parameters" => %{...}}`

  Finish reasons: `"stop"`, `"tool_call"`, `"length"`, `"error"`
  """

  alias ReqLLM.Context
  alias ReqLLM.ToolCall

  # --- Neutral → ReqLLM ---

  @doc """
  Normalize a model string to ReqLLM's `provider:model` format.

  If the string already contains a colon, it's passed through.
  Otherwise, infers the provider from the model name (claude → anthropic,
  gpt/o1/o3 → openai, gemini → google).
  """
  @spec normalize_model(String.t()) :: String.t()
  def normalize_model(model) do
    if String.contains?(model, ":") do
      model
    else
      provider = infer_provider(model)
      "#{provider}:#{model}"
    end
  end

  # --- Worker-side rendering ---
  #
  # The orchestrator never writes prose for the model ("Content is opaque",
  # norns decision log, 2026-09-09). Where it used to — a timer result, a
  # denied tool, a sub-agent's outcome, a parent's inherited context — the
  # message carries a `kind` plus envelope `data`, and the worker renders it.
  # The worker also composes the system prompt, elides old tool results, and
  # decides the run's final output, because each needs to read text.

  # Chars kept of a tool result once it has aged out of the last two messages.
  @tool_result_cap 200

  @doc """
  The prompt the model sees: the def's prompt verbatim, then the conversation
  summary and the date the orchestrator put in the task envelope.
  """
  @spec compose_system_prompt(map()) :: String.t()
  def compose_system_prompt(task) do
    prompt = task["system_prompt"] || ""
    summary = task["summary"]
    date = task["date"]

    prompt
    |> then(fn p -> if is_binary(summary) and summary != "", do: p <> "\n\nSummary of earlier conversation: " <> summary, else: p end)
    |> then(fn p -> if date, do: p <> "\n\nCurrent date: #{date}.", else: p end)
  end

  @doc "Render a kinded message to plain content. Messages without a kind pass through."
  @spec render_message(map()) :: map()
  def render_message(%{"kind" => kind} = msg) when is_binary(kind) do
    msg
    |> Map.put("content", render_kind(kind, msg["data"] || %{}, msg["content"]))
    |> Map.drop(["kind", "data"])
  end

  def render_message(msg), do: msg

  @spec render_messages([map()]) :: [map()]
  def render_messages(messages), do: Enum.map(messages, &render_message/1)

  defp render_kind("inherited_context", _data, content) do
    "[Inherited context from parent agent]\n" <> encode(content)
  end

  defp render_kind("timer_completed", _data, _content), do: "Timer completed."

  defp render_kind("tool_denied", data, _content) do
    "Tool '#{data["tool_name"]}' is not in this agent's allowed tools."
  end

  defp render_kind("subagent_denied", %{"reason" => "disabled"}, _content) do
    "This agent is not permitted to launch sub-agents."
  end

  defp render_kind("subagent_denied", %{"reason" => "max_depth"} = data, _content) do
    "Sub-agent nesting limit reached (max depth #{data["max_depth"]}). " <>
      "Do the work in this agent instead of delegating further."
  end

  defp render_kind("subagent_denied", data, _content) do
    "Agent '#{data["agent_name"]}' is not in this agent's allowed sub-agents."
  end

  defp render_kind("subagent_list_denied", _data, _content), do: "Listing agents is not permitted for this agent."
  defp render_kind("subagent_not_found", data, _content), do: "Agent '#{data["agent_name"]}' not found"
  defp render_kind("subagent_self", _data, _content), do: "Cannot launch self as a sub-agent"

  defp render_kind("subagent_missing", data, _content) do
    "Sub-agent run #{data["run_id"]} no longer exists, so its result cannot be recovered."
  end

  defp render_kind("subagent_launch_failed", data, _content) do
    "Failed to launch agent '#{data["agent_name"]}': #{data["reason"]}"
  end

  defp render_kind("subagent_completed", data, content) do
    Jason.encode!(%{"run_id" => data["run_id"], "status" => "completed", "output" => content || ""})
  end

  defp render_kind("subagent_failed", data, content) do
    Jason.encode!(%{"run_id" => data["run_id"], "status" => "failed", "error" => content || ""})
  end

  defp render_kind("list_agents", data, _content), do: Jason.encode!(data["agents"] || [])
  defp render_kind(_unknown, data, content) when content in [nil, ""], do: encode(data)
  defp render_kind(_unknown, _data, content), do: encode(content)

  defp encode(value) when is_binary(value), do: value
  defp encode(value), do: Jason.encode!(value)

  @compaction_instruction "Write a summary of the conversation so far for your own future reference. " <>
                            "You will continue the same task with only this summary and the most recent " <>
                            "messages, so keep every fact you would need: the task and its constraints, " <>
                            "decisions made and why, files and identifiers touched, what was tried and " <>
                            "failed, what remains to be done, and anything the user asked for that is not " <>
                            "finished. Fold in the earlier summary if there is one. Write prose or terse " <>
                            "notes, no preamble, no commentary about summarising."

  @doc """
  The system prompt for a `purpose: "compact"` task: the def's prompt (so the
  summary is written from the agent's point of view) plus the earlier summary.
  """
  @spec compose_compaction_prompt(map()) :: String.t()
  def compose_compaction_prompt(task) do
    prompt = task["system_prompt"] || ""
    summary = task["summary"]

    if is_binary(summary) and summary != "" do
      prompt <> "\n\nSummary of earlier conversation: " <> summary
    else
      prompt
    end
  end

  @doc "The messages for a compaction call: the folded history, rendered, then the instruction."
  @spec compaction_messages(map()) :: [map()]
  def compaction_messages(task) do
    render_messages(task["messages"] || []) ++ [%{"role" => "user", "content" => @compaction_instruction}]
  end

  @doc "Rendered messages, elided unless core manages the context itself (`context_policy` in the envelope)."
  @spec messages_for_task(map()) :: [map()]
  def messages_for_task(task) do
    rendered = render_messages(task["messages"] || [])
    if task["context_policy"], do: rendered, else: elide_old_tool_results(rendered)
  end

  @doc "Cap tool results older than the last two messages."
  @spec elide_old_tool_results([map()]) :: [map()]
  def elide_old_tool_results(messages) when length(messages) <= 4, do: messages

  def elide_old_tool_results(messages) do
    {old, recent} = Enum.split(messages, length(messages) - 2)

    Enum.map(old, fn
      %{"role" => "tool", "content" => content} = msg when is_binary(content) and byte_size(content) > @tool_result_cap ->
        Map.put(msg, "content", String.slice(content, 0, @tool_result_cap) <> "...(truncated)")

      msg ->
        msg
    end) ++ recent
  end

  @doc """
  The run's output when the model stops. A turn can say something substantive
  alongside a tool call and then end with an empty "stop" turn; fall back to
  the last non-empty assistant text rather than losing it.
  """
  @spec final_output([map()], term()) :: String.t()
  def final_output(messages, content) do
    text = if is_binary(content), do: content, else: ""

    if String.trim(text) == "" do
      Enum.find_value(Enum.reverse(messages), text, &substantive_assistant_text/1)
    else
      text
    end
  end

  defp substantive_assistant_text(%{"role" => "assistant", "content" => c}) when is_binary(c) do
    if String.trim(c) == "", do: nil, else: c
  end

  defp substantive_assistant_text(_msg), do: nil

  @doc "Convert neutral-format messages to a ReqLLM Context. Kinded messages are rendered first."
  @spec to_req_llm_context([map()]) :: Context.t()
  def to_req_llm_context(messages) do
    messages
    |> render_messages()
    |> Enum.map(&neutral_msg_to_req_llm/1)
    |> Context.new()
  end

  @doc "Convert neutral tool definitions to ReqLLM Tool structs."
  @spec to_req_llm_tools([map()]) :: [ReqLLM.Tool.t()]
  def to_req_llm_tools(tools) do
    Enum.flat_map(tools, fn tool ->
      case ReqLLM.Tool.new(
             name: tool["name"],
             description: tool["description"] || "",
             parameter_schema: tool["parameters"] || tool["input_schema"] || %{},
             callback: fn _args -> {:ok, "noop"} end
           ) do
        {:ok, t} -> [t]
        {:error, _} -> []
      end
    end)
  end

  # --- ReqLLM → Neutral ---

  @doc "Convert a ReqLLM Response to neutral wire format."
  @spec from_req_llm_response(ReqLLM.Response.t()) :: map()
  def from_req_llm_response(response) do
    text = ReqLLM.Response.text(response) || ""
    tool_calls = extract_tool_calls(response)

    result = %{
      "status" => "ok",
      "content" => text,
      "finish_reason" => normalize_finish_reason(response.finish_reason),
      "usage" => normalize_usage(response.usage)
    }

    if tool_calls != [] do
      Map.put(result, "tool_calls", tool_calls)
    else
      result
    end
  end

  defp extract_tool_calls(response) do
    response
    |> ReqLLM.Response.tool_calls()
    |> Enum.map(fn tc ->
      %{
        "id" => tc.id,
        "name" => ToolCall.name(tc),
        "arguments" => ToolCall.args_map(tc) || %{}
      }
    end)
  end

  defp normalize_finish_reason(:stop), do: "stop"
  defp normalize_finish_reason(:tool_calls), do: "tool_call"
  defp normalize_finish_reason(:length), do: "length"
  defp normalize_finish_reason(:error), do: "error"
  defp normalize_finish_reason(other) when is_atom(other), do: to_string(other)
  defp normalize_finish_reason(_), do: "stop"

  defp normalize_usage(nil), do: %{"input_tokens" => 0, "output_tokens" => 0}

  defp normalize_usage(usage) do
    %{
      "input_tokens" => usage[:input_tokens] || usage["input_tokens"] || 0,
      "output_tokens" => usage[:output_tokens] || usage["output_tokens"] || 0
    }
  end

  # --- Neutral → Anthropic API (kept for direct API use / testing) ---

  @doc "Convert neutral-format messages to Anthropic API format."
  def to_anthropic_messages(messages) do
    messages
    |> Enum.chunk_by(fn msg -> msg["role"] == "tool" end)
    |> Enum.flat_map(&convert_chunk/1)
  end

  @doc "Convert neutral tool definitions to Anthropic format."
  def to_anthropic_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        "name" => tool["name"],
        "description" => tool["description"] || "",
        "input_schema" => tool["parameters"] || tool["input_schema"] || %{}
      }
    end)
  end

  @doc "Convert an Anthropic API response body to neutral format."
  def from_anthropic_response(body) do
    content_blocks = body["content"] || []

    text =
      content_blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("\n", & &1["text"])

    tool_calls =
      content_blocks
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(fn block ->
        %{
          "id" => block["id"],
          "name" => block["name"],
          "arguments" => block["input"]
        }
      end)

    finish_reason =
      case body["stop_reason"] do
        "end_turn" -> "stop"
        "tool_use" -> "tool_call"
        "max_tokens" -> "length"
        other -> other || "stop"
      end

    result = %{
      "status" => "ok",
      "content" => text,
      "finish_reason" => finish_reason,
      "usage" => body["usage"] || %{}
    }

    if tool_calls != [] do
      Map.put(result, "tool_calls", tool_calls)
    else
      result
    end
  end

  # --- Internal helpers ---

  defp infer_provider(model) do
    cond do
      String.starts_with?(model, "claude") -> "anthropic"
      String.starts_with?(model, "gpt") -> "openai"
      String.starts_with?(model, "o1") or String.starts_with?(model, "o3") -> "openai"
      String.starts_with?(model, "gemini") -> "google"
      String.starts_with?(model, "mistral") or String.starts_with?(model, "codestral") -> "mistral"
      true -> "anthropic"
    end
  end

  defp neutral_msg_to_req_llm(%{"role" => "user", "content" => content}) do
    Context.user(encode(content))
  end

  defp neutral_msg_to_req_llm(%{"role" => "system", "content" => content}) do
    Context.system(content)
  end

  defp neutral_msg_to_req_llm(%{"role" => "assistant"} = msg) do
    text = msg["content"] || ""
    tool_calls = msg["tool_calls"] || []

    if tool_calls != [] do
      req_tool_calls =
        Enum.map(tool_calls, fn tc ->
          ToolCall.new(tc["id"], tc["name"], Jason.encode!(tc["arguments"] || %{}))
        end)

      Context.assistant(text, tool_calls: req_tool_calls)
    else
      Context.assistant(text)
    end
  end

  defp neutral_msg_to_req_llm(%{"role" => "tool"} = msg) do
    Context.tool_result(
      msg["tool_call_id"],
      msg["name"] || "",
      msg["content"] || ""
    )
  end

  defp convert_chunk([%{"role" => "tool"} | _] = tool_msgs) do
    tool_results =
      Enum.map(tool_msgs, fn msg ->
        result = %{
          "type" => "tool_result",
          "tool_use_id" => msg["tool_call_id"],
          "content" => msg["content"] || ""
        }

        if msg["is_error"] do
          Map.put(result, "is_error", true)
        else
          result
        end
      end)

    [%{"role" => "user", "content" => tool_results}]
  end

  defp convert_chunk(msgs) do
    Enum.map(msgs, &convert_msg/1)
  end

  defp convert_msg(%{"role" => "assistant"} = msg) do
    tool_calls = msg["tool_calls"] || []
    text = msg["content"] || ""

    content =
      if tool_calls != [] do
        text_block = if text != "", do: [%{"type" => "text", "text" => text}], else: []

        tool_blocks =
          Enum.map(tool_calls, fn tc ->
            %{
              "type" => "tool_use",
              "id" => tc["id"],
              "name" => tc["name"],
              "input" => tc["arguments"]
            }
          end)

        text_block ++ tool_blocks
      else
        text
      end

    %{"role" => "assistant", "content" => content}
  end

  defp convert_msg(%{"role" => role, "content" => content}) do
    %{"role" => role, "content" => content}
  end
end
