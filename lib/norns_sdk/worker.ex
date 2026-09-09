defmodule NornsSdk.Worker do
  @moduledoc """
  Worker that connects to Norns, registers agents/tools, and handles tasks.

  Uses ReqLLM for LLM calls, supporting any provider (Anthropic, OpenAI, Google, etc.).
  The provider is inferred from the agent's model string (e.g. `"anthropic:claude-sonnet-5"`
  or just `"claude-sonnet-5"`).

  Add to your supervision tree:

      children = [
        {NornsSdk.Worker,
         url: "http://localhost:4000",
         api_key: "nrn_...",
         llm_api_key: "sk-ant-...",
         agent: my_agent}
      ]

  The `llm_api_key` option is passed per-request to ReqLLM. You can also configure
  API keys via environment variables (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, etc.)
  or application config — see ReqLLM docs.
  """

  use Slipstream

  require Logger

  alias NornsSdk.Format

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    Slipstream.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    api_key = Keyword.get(opts, :api_key, System.get_env("NORNS_API_KEY") || "")
    llm_api_key = Keyword.get(opts, :llm_api_key, System.get_env("ANTHROPIC_API_KEY") || "")
    agent = Keyword.fetch!(opts, :agent)
    worker_id = Keyword.get(opts, :worker_id, "elixir-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}")

    # Create or update the agent on the server so code changes are always picked up
    client = NornsSdk.Client.new(url, api_key: api_key)
    NornsSdk.Client.ensure_agent(client, agent)

    tools_by_name = Map.new(agent.tools, fn mod -> {mod.__tool_name__(), mod} end)

    ws_url =
      url
      |> String.trim_trailing("/")
      |> String.replace("http://", "ws://")
      |> String.replace("https://", "wss://")
      |> Kernel.<>("/worker/websocket?token=#{api_key}&vsn=2.0.0")

    state = %{
      url: url,
      llm_api_key: llm_api_key,
      agent: agent,
      worker_id: worker_id,
      tools_by_name: tools_by_name
    }

    {:ok, state, {:connect, ws_url}}
  end

  @impl true
  def handle_connect(socket) do
    state = socket.assigns

    join_payload = %{
      "worker_id" => state.worker_id,
      "tools" => Enum.map(state.agent.tools, fn mod -> mod.to_registration() end),
      "capabilities" => ["llm", "tools"]
    }

    Logger.info("Connected to Norns, joining worker:lobby as #{state.worker_id}")
    {:ok, join(socket, "worker:lobby", join_payload)}
  end

  @impl true
  def handle_join("worker:lobby", _reply, socket) do
    Logger.info("Joined worker:lobby")
    {:ok, socket}
  end

  @impl true
  def handle_message("worker:lobby", "llm_task", payload, socket) do
    state = socket.assigns

    Task.start(fn ->
      result = execute_llm(payload, state.llm_api_key)
      push(socket, "worker:lobby", "tool_result", Map.put(result, "task_id", payload["task_id"]))
    end)

    {:ok, socket}
  end

  def handle_message("worker:lobby", "tool_task", payload, socket) do
    state = socket.assigns

    Task.start(fn ->
      result = execute_tool(payload, state.tools_by_name)
      push(socket, "worker:lobby", "tool_result", Map.put(result, "task_id", payload["task_id"]))
    end)

    {:ok, socket}
  end

  def handle_message(_topic, _event, _payload, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_disconnect(_reason, socket) do
    Logger.warning("Disconnected from Norns, reconnecting...")
    {:reconnect, socket}
  end

  # --- LLM Execution ---
  # Receives tasks in neutral format, calls LLM via ReqLLM, returns neutral format.

  defp execute_llm(task, api_key) do
    model_str = task["model"] || "claude-sonnet-5"
    # Core sends the def's prompt verbatim and never writes prose for the
    # model: the worker composes the prompt, renders kinded messages, elides
    # old tool results, and decides the final output.
    system_prompt = Format.compose_system_prompt(task)
    messages = (task["messages"] || []) |> Format.render_messages() |> Format.elide_old_tool_results()
    tools = task["tools"] || []

    # Normalize model string to ReqLLM format (e.g. "anthropic:claude-sonnet-5")
    model_id = Format.normalize_model(model_str)

    # Build ReqLLM context from neutral messages
    context = Format.to_req_llm_context(messages)

    # Build ReqLLM tool definitions
    req_tools = Format.to_req_llm_tools(tools)

    opts =
      [max_tokens: 4096, system_prompt: system_prompt, api_key: api_key]
      |> then(fn o -> if req_tools != [], do: Keyword.put(o, :tools, req_tools), else: o end)

    case ReqLLM.generate_text(model_id, context, opts) do
      {:ok, response} ->
        result = Format.from_req_llm_response(response)
        Map.put(result, "final_output", Format.final_output(messages, result["content"]))

      {:error, reason} ->
        Logger.error("LLM call failed: #{inspect(reason)}")
        %{"status" => "error", "error" => inspect(reason)}
    end
  end

  # --- Tool Execution ---

  defp execute_tool(task, tools_by_name) do
    tool_name = task["tool_name"] || ""
    input = task["input"] || %{}

    case Map.get(tools_by_name, tool_name) do
      nil ->
        %{"status" => "error", "error" => "Unknown tool: #{tool_name}"}

      mod ->
        try do
          case mod.execute(input) do
            {:ok, result} -> %{"status" => "ok", "result" => to_string(result)}
            {:error, reason} -> %{"status" => "error", "error" => to_string(reason)}
          end
        rescue
          e -> %{"status" => "error", "error" => Exception.message(e)}
        end
    end
  end
end
