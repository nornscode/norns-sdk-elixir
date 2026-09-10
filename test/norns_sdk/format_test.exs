defmodule NornsSdk.FormatTest do
  use ExUnit.Case, async: true

  alias NornsSdk.Format
  alias ReqLLM.Message.ContentPart

  # --- to_anthropic_messages/1 ---

  test "converts simple user message" do
    messages = [%{"role" => "user", "content" => "Hello"}]
    assert Format.to_anthropic_messages(messages) == [%{"role" => "user", "content" => "Hello"}]
  end

  test "converts assistant message with text only" do
    messages = [%{"role" => "assistant", "content" => "Hi there"}]
    assert Format.to_anthropic_messages(messages) == [%{"role" => "assistant", "content" => "Hi there"}]
  end

  test "converts assistant message with tool calls" do
    messages = [
      %{
        "role" => "assistant",
        "content" => "Let me search.",
        "tool_calls" => [
          %{"id" => "tc_1", "name" => "search", "arguments" => %{"query" => "test"}}
        ]
      }
    ]

    [msg] = Format.to_anthropic_messages(messages)
    assert msg["role"] == "assistant"
    assert [text_block, tool_block] = msg["content"]
    assert text_block == %{"type" => "text", "text" => "Let me search."}
    assert tool_block == %{"type" => "tool_use", "id" => "tc_1", "name" => "search", "input" => %{"query" => "test"}}
  end

  test "converts assistant message with tool calls but no text" do
    messages = [
      %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [
          %{"id" => "tc_1", "name" => "search", "arguments" => %{"query" => "test"}}
        ]
      }
    ]

    [msg] = Format.to_anthropic_messages(messages)
    assert [tool_block] = msg["content"]
    assert tool_block["type"] == "tool_use"
  end

  test "converts consecutive tool results into single user message" do
    messages = [
      %{"role" => "tool", "tool_call_id" => "tc_1", "name" => "search", "content" => "found it"},
      %{"role" => "tool", "tool_call_id" => "tc_2", "name" => "lookup", "content" => "got it"}
    ]

    [msg] = Format.to_anthropic_messages(messages)
    assert msg["role"] == "user"
    assert [r1, r2] = msg["content"]
    assert r1 == %{"type" => "tool_result", "tool_use_id" => "tc_1", "content" => "found it"}
    assert r2 == %{"type" => "tool_result", "tool_use_id" => "tc_2", "content" => "got it"}
  end

  test "tool result with is_error flag" do
    messages = [
      %{"role" => "tool", "tool_call_id" => "tc_1", "name" => "search", "content" => "boom", "is_error" => true}
    ]

    [msg] = Format.to_anthropic_messages(messages)
    [result] = msg["content"]
    assert result["is_error"] == true
  end

  test "converts full conversation round-trip" do
    messages = [
      %{"role" => "user", "content" => "search for cats"},
      %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [%{"id" => "tc_1", "name" => "search", "arguments" => %{"q" => "cats"}}]
      },
      %{"role" => "tool", "tool_call_id" => "tc_1", "name" => "search", "content" => "found cats"},
      %{"role" => "assistant", "content" => "Here are the results."}
    ]

    result = Format.to_anthropic_messages(messages)
    assert length(result) == 4
    assert Enum.at(result, 0)["role"] == "user"
    assert Enum.at(result, 1)["role"] == "assistant"
    assert Enum.at(result, 2)["role"] == "user"
    assert Enum.at(result, 3)["role"] == "assistant"
  end

  # --- to_anthropic_tools/1 ---

  test "converts neutral tool defs to anthropic format" do
    tools = [
      %{"name" => "search", "description" => "Search things", "parameters" => %{"type" => "object"}}
    ]

    [tool] = Format.to_anthropic_tools(tools)
    assert tool["name"] == "search"
    assert tool["description"] == "Search things"
    assert tool["input_schema"] == %{"type" => "object"}
  end

  test "handles input_schema key as fallback" do
    tools = [
      %{"name" => "search", "description" => "Search", "input_schema" => %{"type" => "object"}}
    ]

    [tool] = Format.to_anthropic_tools(tools)
    assert tool["input_schema"] == %{"type" => "object"}
  end

  # --- from_anthropic_response/1 ---

  test "converts text-only response" do
    body = %{
      "content" => [%{"type" => "text", "text" => "Hello!"}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }

    result = Format.from_anthropic_response(body)
    assert result["status"] == "ok"
    assert result["content"] == "Hello!"
    assert result["finish_reason"] == "stop"
    assert result["usage"] == %{"input_tokens" => 10, "output_tokens" => 5}
    refute Map.has_key?(result, "tool_calls")
  end

  test "converts response with tool use" do
    body = %{
      "content" => [
        %{"type" => "text", "text" => "Let me search."},
        %{"type" => "tool_use", "id" => "tc_1", "name" => "search", "input" => %{"q" => "cats"}}
      ],
      "stop_reason" => "tool_use",
      "usage" => %{"input_tokens" => 20, "output_tokens" => 15}
    }

    result = Format.from_anthropic_response(body)
    assert result["status"] == "ok"
    assert result["content"] == "Let me search."
    assert result["finish_reason"] == "tool_call"
    assert [tc] = result["tool_calls"]
    assert tc["id"] == "tc_1"
    assert tc["name"] == "search"
    assert tc["arguments"] == %{"q" => "cats"}
  end

  test "maps max_tokens to length" do
    body = %{"content" => [], "stop_reason" => "max_tokens", "usage" => %{}}
    assert Format.from_anthropic_response(body)["finish_reason"] == "length"
  end

  test "passes through unknown stop reasons" do
    body = %{"content" => [], "stop_reason" => "something_else", "usage" => %{}}
    assert Format.from_anthropic_response(body)["finish_reason"] == "something_else"
  end

  test "joins multiple text blocks with newline" do
    body = %{
      "content" => [
        %{"type" => "text", "text" => "First."},
        %{"type" => "text", "text" => "Second."}
      ],
      "stop_reason" => "end_turn",
      "usage" => %{}
    }

    assert Format.from_anthropic_response(body)["content"] == "First.\nSecond."
  end

  # --- normalize_model/1 ---

  test "passes through model with provider prefix" do
    assert Format.normalize_model("anthropic:claude-sonnet-4-20250514") == "anthropic:claude-sonnet-4-20250514"
    assert Format.normalize_model("openai:gpt-4o") == "openai:gpt-4o"
  end

  test "infers anthropic for claude models" do
    assert Format.normalize_model("claude-sonnet-4-20250514") == "anthropic:claude-sonnet-4-20250514"
    assert Format.normalize_model("claude-haiku-4-5-20251001") == "anthropic:claude-haiku-4-5-20251001"
  end

  test "infers openai for gpt/o1/o3 models" do
    assert Format.normalize_model("gpt-4o") == "openai:gpt-4o"
    assert Format.normalize_model("o1-preview") == "openai:o1-preview"
    assert Format.normalize_model("o3-mini") == "openai:o3-mini"
  end

  test "infers google for gemini models" do
    assert Format.normalize_model("gemini-2.0-flash") == "google:gemini-2.0-flash"
  end

  test "defaults to anthropic for unknown models" do
    assert Format.normalize_model("some-custom-model") == "anthropic:some-custom-model"
  end

  # --- to_req_llm_context/1 ---

  test "converts neutral messages to ReqLLM context" do
    messages = [
      %{"role" => "user", "content" => "Hello"},
      %{"role" => "assistant", "content" => "Hi there"}
    ]

    ctx = Format.to_req_llm_context(messages)
    assert %ReqLLM.Context{} = ctx
    assert length(ctx.messages) == 2
    assert Enum.at(ctx.messages, 0).role == :user
    assert Enum.at(ctx.messages, 1).role == :assistant
  end

  test "converts tool call messages to ReqLLM context" do
    messages = [
      %{
        "role" => "assistant",
        "content" => "Searching...",
        "tool_calls" => [%{"id" => "tc_1", "name" => "search", "arguments" => %{"q" => "test"}}]
      },
      %{"role" => "tool", "tool_call_id" => "tc_1", "name" => "search", "content" => "found it"}
    ]

    ctx = Format.to_req_llm_context(messages)
    assert length(ctx.messages) == 2
    assistant_msg = Enum.at(ctx.messages, 0)
    assert assistant_msg.role == :assistant
    assert assistant_msg.tool_calls != nil
    assert length(assistant_msg.tool_calls) == 1

    tool_msg = Enum.at(ctx.messages, 1)
    assert tool_msg.role == :tool
    assert tool_msg.tool_call_id == "tc_1"
  end

  # --- worker-side rendering (opaque content) ---

  test "composes the system prompt from the envelope" do
    assert Format.compose_system_prompt(%{"system_prompt" => "You help.", "summary" => "Likes cats.", "date" => "2026-09-09"}) ==
             "You help.\n\nSummary of earlier conversation: Likes cats.\n\nCurrent date: 2026-09-09."

    assert Format.compose_system_prompt(%{"system_prompt" => "You help."}) == "You help."
  end

  test "renders kinded messages and passes plain ones through" do
    plain = %{"role" => "user", "content" => "hi"}
    assert Format.render_message(plain) == plain

    assert %{"content" => "Timer completed."} =
             Format.render_message(%{"role" => "tool", "kind" => "timer_completed", "data" => %{}, "content" => ""})

    assert %{"content" => "Tool 'send_email' is not in this agent's allowed tools."} =
             Format.render_message(%{"role" => "tool", "kind" => "tool_denied", "data" => %{"tool_name" => "send_email"}, "content" => ""})

    rendered = Format.render_message(%{"role" => "user", "kind" => "inherited_context", "content" => %{"ticket_id" => "T-123"}})
    assert rendered["content"] == "[Inherited context from parent agent]\n{\"ticket_id\":\"T-123\"}"
    refute Map.has_key?(rendered, "kind")

    done = Format.render_message(%{"role" => "tool", "kind" => "subagent_completed", "data" => %{"run_id" => 7, "status" => "completed"}, "content" => "42"})
    assert Jason.decode!(done["content"]) == %{"run_id" => 7, "status" => "completed", "output" => "42"}
  end

  test "renders kinds inside to_req_llm_context" do
    ctx = Format.to_req_llm_context([%{"role" => "tool", "tool_call_id" => "c1", "name" => "wait", "kind" => "timer_completed", "data" => %{}, "content" => ""}])
    [msg] = ctx.messages
    assert msg.role == :tool
  end

  test "elides only tool results older than the last two messages" do
    long = String.duplicate("x", 500)

    messages = [
      %{"role" => "user", "content" => "go"},
      %{"role" => "assistant", "content" => "", "tool_calls" => [%{"id" => "c1", "name" => "t", "arguments" => %{}}]},
      %{"role" => "tool", "tool_call_id" => "c1", "content" => long},
      %{"role" => "assistant", "content" => "", "tool_calls" => [%{"id" => "c2", "name" => "t", "arguments" => %{}}]},
      %{"role" => "tool", "tool_call_id" => "c2", "content" => long}
    ]

    out = Format.elide_old_tool_results(messages)
    assert Enum.at(out, 2)["content"] == String.duplicate("x", 200) <> "...(truncated)"
    assert Enum.at(out, 4)["content"] == long
    assert Format.elide_old_tool_results(Enum.take(messages, 4)) == Enum.take(messages, 4)
  end

  test "final_output falls back to the last substantive assistant turn" do
    messages = [
      %{"role" => "user", "content" => "go"},
      %{"role" => "assistant", "content" => "Here's what I found.", "tool_calls" => [%{"id" => "c1", "name" => "t", "arguments" => %{}}]},
      %{"role" => "tool", "tool_call_id" => "c1", "content" => "r"}
    ]

    assert Format.final_output(messages, "") == "Here's what I found."
    assert Format.final_output(messages, "Done.") == "Done."
  end

  # --- to_req_llm_tools/1 ---

  test "converts neutral tool defs to ReqLLM tools" do
    tools = [
      %{"name" => "search", "description" => "Search things", "parameters" => %{"type" => "object"}}
    ]

    result = Format.to_req_llm_tools(tools)
    assert length(result) == 1
    assert %ReqLLM.Tool{} = hd(result)
    assert hd(result).name == "search"
  end

  # --- from_req_llm_response/1 ---

  test "converts text-only ReqLLM response to neutral format" do
    response = %ReqLLM.Response{
      id: "test",
      model: "anthropic:claude-sonnet-4-20250514",
      context: ReqLLM.Context.new(),
      message: %ReqLLM.Message{
        role: :assistant,
        content: [ContentPart.text("Hello!")]
      },
      finish_reason: :stop,
      usage: %{input_tokens: 10, output_tokens: 5}
    }

    result = Format.from_req_llm_response(response)
    assert result["status"] == "ok"
    assert result["content"] == "Hello!"
    assert result["finish_reason"] == "stop"
    assert result["usage"]["input_tokens"] == 10
    assert result["usage"]["output_tokens"] == 5
    refute Map.has_key?(result, "tool_calls")
  end

  test "converts ReqLLM response with tool calls to neutral format" do
    tc = ReqLLM.ToolCall.new("tc_1", "search", Jason.encode!(%{"q" => "cats"}))

    response = %ReqLLM.Response{
      id: "test",
      model: "anthropic:claude-sonnet-4-20250514",
      context: ReqLLM.Context.new(),
      message: %ReqLLM.Message{
        role: :assistant,
        content: [ContentPart.text("Searching...")],
        tool_calls: [tc]
      },
      finish_reason: :tool_calls,
      usage: %{input_tokens: 20, output_tokens: 15}
    }

    result = Format.from_req_llm_response(response)
    assert result["finish_reason"] == "tool_call"
    assert [tool_call] = result["tool_calls"]
    assert tool_call["id"] == "tc_1"
    assert tool_call["name"] == "search"
    assert tool_call["arguments"] == %{"q" => "cats"}
  end

  test "maps ReqLLM :length finish reason" do
    response = %ReqLLM.Response{
      id: "test",
      model: "test",
      context: ReqLLM.Context.new(),
      message: %ReqLLM.Message{role: :assistant, content: []},
      finish_reason: :length,
      usage: %{}
    }

    assert Format.from_req_llm_response(response)["finish_reason"] == "length"
  end

  describe "compaction" do
    test "compose_compaction_prompt/1 carries the def prompt and the earlier summary" do
      assert Format.compose_compaction_prompt(%{"system_prompt" => "P", "summary" => "S"}) ==
               "P\n\nSummary of earlier conversation: S"

      assert Format.compose_compaction_prompt(%{"system_prompt" => "P"}) == "P"
    end

    test "compaction_messages/1 renders the folded history and ends with the instruction" do
      task = %{
        "messages" => [
          %{"role" => "user", "content" => "go"},
          %{"role" => "tool", "tool_call_id" => "c1", "name" => "wait", "kind" => "timer_completed", "data" => %{}, "content" => ""}
        ]
      }

      messages = Format.compaction_messages(task)
      assert [%{"role" => "user", "content" => "go"}, %{"role" => "tool", "content" => "Timer completed."}, %{"role" => "user", "content" => instruction}] = messages
      assert instruction =~ "Write a summary of the conversation so far"
    end

    test "messages_for_task/1 skips elision when core manages the context" do
      big = String.duplicate("x", 300)

      messages = [
        %{"role" => "user", "content" => "a"},
        %{"role" => "tool", "tool_call_id" => "c1", "name" => "t", "content" => big},
        %{"role" => "assistant", "content" => "b"},
        %{"role" => "user", "content" => "c"},
        %{"role" => "assistant", "content" => "d"}
      ]

      assert [_, %{"content" => elided} | _] = Format.messages_for_task(%{"messages" => messages})
      assert String.length(elided) < 300

      assert [_, %{"content" => ^big} | _] =
               Format.messages_for_task(%{"messages" => messages, "context_policy" => %{"compact_at" => 1, "keep" => 1}})
    end
  end
end
