defmodule NornsSdk.Client do
  @moduledoc """
  Client for interacting with Norns agents.

  Sends messages, queries runs, manages conversations.

  ## Usage

      client = NornsSdk.Client.new("http://localhost:4000", api_key: "nrn_...")

      # Fire and forget
      {:ok, %{run_id: 42}} = NornsSdk.Client.send_message(client, "support-bot", "Hello!")

      # Block until completion
      {:ok, result} = NornsSdk.Client.send_message(client, "support-bot", "Hello!", wait: true)
      result.output
  """

  alias NornsSdk.{AgentResponse, ConversationResponse, EventResponse, MessageResult, RunResponse}

  defstruct [:base_url, :api_key]

  @type t :: %__MODULE__{base_url: String.t(), api_key: String.t()}

  def new(url, opts \\ []) do
    %__MODULE__{
      base_url: String.trim_trailing(url, "/"),
      api_key: Keyword.get(opts, :api_key, System.get_env("NORNS_API_KEY") || "")
    }
  end

  # --- Agents ---

  def list_agents(%__MODULE__{} = client) do
    case get(client, "/api/v1/agents") do
      {:ok, %{"data" => agents}} -> {:ok, Enum.map(agents, &AgentResponse.from_map/1)}
      error -> error
    end
  end

  def get_agent(%__MODULE__{} = client, id) when is_integer(id) do
    case get(client, "/api/v1/agents/#{id}") do
      {:ok, %{"data" => agent}} -> {:ok, AgentResponse.from_map(agent)}
      error -> error
    end
  end

  def get_agent(%__MODULE__{} = client, name) when is_binary(name) do
    case list_agents(client) do
      {:ok, agents} ->
        case Enum.find(agents, &(&1.name == name)) do
          nil -> {:error, :not_found}
          agent -> {:ok, agent}
        end

      error ->
        error
    end
  end

  def create_agent(%__MODULE__{} = client, %NornsSdk.Agent{} = agent) do
    case post(client, "/api/v1/agents", agent_body(agent)) do
      {:ok, %{"data" => a}} -> {:ok, AgentResponse.from_map(a)}
      error -> error
    end
  end

  def update_agent(%__MODULE__{} = client, id, %NornsSdk.Agent{} = agent) when is_integer(id) do
    case put(client, "/api/v1/agents/#{id}", agent_body(agent)) do
      {:ok, %{"data" => a}} -> {:ok, AgentResponse.from_map(a)}
      error -> error
    end
  end

  def ensure_agent(%__MODULE__{} = client, %NornsSdk.Agent{} = agent) do
    case get_agent(client, agent.name) do
      {:ok, %AgentResponse{id: id}} ->
        update_agent(client, id, agent)

      {:error, :not_found} ->
        create_agent(client, agent)
    end
  end

  # --- Messages ---

  def send_message(%__MODULE__{} = client, agent, content, opts \\ []) do
    with {:ok, agent_id} <- resolve_agent_id(client, agent),
         {:ok, %{"run_id" => run_id} = resp} <-
           post(client, "/api/v1/agents/#{agent_id}/messages", message_body(content, opts)) do
      if Keyword.get(opts, :wait, false) do
        await_result(client, run_id, opts)
      else
        {:ok, accepted_result(run_id, resp, opts)}
      end
    end
  end

  defp await_result(client, run_id, opts) do
    case poll_until_complete(client, run_id, Keyword.get(opts, :timeout, 30_000)) do
      {:ok, %RunResponse{} = run} ->
        {:ok,
         %MessageResult{
           run_id: run_id,
           status: run.status,
           output: run.output,
           conversation_key: Keyword.get(opts, :conversation_key),
           waiting_for: run.waiting_for
         }}

      error ->
        error
    end
  end

  defp accepted_result(run_id, resp, opts) do
    %MessageResult{
      run_id: run_id,
      status: Map.get(resp, "status", "accepted"),
      output: nil,
      conversation_key: Keyword.get(opts, :conversation_key)
    }
  end

  @doc """
  Answer a run that is parked on an `ask_human` question.

  Sending the agent a normal message with `send_message/4` does the same thing
  and is usually what a conversational client wants. Use `reply/3` when you
  want to answer one specific run — for example when an agent has several
  conversations parked at once.

  ## Example

      {:ok, result} = NornsSdk.Client.send_message(client, "support-bot", "Book it", wait: true)

      if NornsSdk.MessageResult.waiting?(result) do
        IO.puts(result.waiting_for.question)
        :ok = NornsSdk.Client.reply(client, result.run_id, "yes, go ahead")
      end
  """
  @spec reply(t(), integer(), String.t()) :: :ok | {:error, term()}
  def reply(%__MODULE__{} = client, run_id, answer) when is_binary(answer) do
    case post(client, "/api/v1/runs/#{run_id}/reply", %{"answer" => answer}) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp message_body(content, opts) do
    %{"content" => content}
    |> maybe_put("conversation_key", Keyword.get(opts, :conversation_key))
  end

  # --- Runs ---

  def get_run(%__MODULE__{} = client, run_id) do
    case get(client, "/api/v1/runs/#{run_id}") do
      {:ok, %{"data" => run}} -> {:ok, RunResponse.from_map(run)}
      error -> error
    end
  end

  def get_events(%__MODULE__{} = client, run_id) do
    case get(client, "/api/v1/runs/#{run_id}/events") do
      {:ok, %{"data" => events}} -> {:ok, Enum.map(events, &EventResponse.from_map/1)}
      error -> error
    end
  end

  # --- Conversations ---

  def list_conversations(%__MODULE__{} = client, agent) do
    with {:ok, agent_id} <- resolve_agent_id(client, agent) do
      case get(client, "/api/v1/agents/#{agent_id}/conversations") do
        {:ok, %{"data" => convos}} -> {:ok, Enum.map(convos, &ConversationResponse.from_map/1)}
        error -> error
      end
    end
  end

  def get_conversation(%__MODULE__{} = client, agent, key) do
    with {:ok, agent_id} <- resolve_agent_id(client, agent) do
      case get(client, "/api/v1/agents/#{agent_id}/conversations/#{key}") do
        {:ok, %{"data" => convo}} -> {:ok, ConversationResponse.from_map(convo)}
        error -> error
      end
    end
  end

  def delete_conversation(%__MODULE__{} = client, agent, key) do
    with {:ok, agent_id} <- resolve_agent_id(client, agent) do
      delete(client, "/api/v1/agents/#{agent_id}/conversations/#{key}")
    end
  end

  # --- Streaming ---

  @doc """
  Send a message and stream the run's events to a subscriber process.

  Sends the message (fire-and-forget), then starts a `NornsSdk.StreamClient`
  that joins the run's channel and forwards each event to the subscriber's
  mailbox as:

      {:norns_event, stream_pid, %NornsSdk.StreamEvent{type: type, data: data}}

  The terminal events are `"completed"` and `"error"`; the stream process stops
  after forwarding one. If the socket closes first, the subscriber receives
  `{:norns_closed, stream_pid, reason}`. Returns `{:ok, stream_pid}`.

  ## Options

    * `:subscriber` — pid to receive events (defaults to the calling process).
    * `:conversation_key` — multi-turn conversation key.

  ## Example

      {:ok, _pid} = NornsSdk.Client.stream(client, "support-bot", "Research quantum computing")

      receive do
        {:norns_event, _pid, %NornsSdk.StreamEvent{type: "completed"} = ev} ->
          IO.puts(ev.data["output"])
      end
  """
  @spec stream(t(), integer() | String.t(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def stream(%__MODULE__{} = client, agent, content, opts \\ []) do
    subscriber = Keyword.get(opts, :subscriber, self())

    with {:ok, agent_id} <- resolve_agent_id(client, agent),
         {:ok, %{"run_id" => run_id}} <-
           post(client, "/api/v1/agents/#{agent_id}/messages", message_body(content, opts)) do
      NornsSdk.StreamClient.start_link(
        base_url: client.base_url,
        api_key: client.api_key,
        agent_id: agent_id,
        run_id: run_id,
        subscriber: subscriber
      )
    end
  end

  # --- Internal ---

  defp poll_until_complete(client, run_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_loop(client, run_id, deadline, 500)
  end

  defp poll_loop(client, run_id, deadline, interval) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      case get_run(client, run_id) do
        # "waiting" is not terminal, but it is a stopping point: the agent is
        # parked on a question and will not progress until someone answers.
        {:ok, %RunResponse{status: status} = run}
        when status in ["completed", "failed", "error", "waiting"] ->
          {:ok, run}

        {:ok, _} ->
          Process.sleep(interval)
          next_interval = min(trunc(interval * 1.5), 3_000)
          poll_loop(client, run_id, deadline, next_interval)

        error ->
          error
      end
    end
  end

  defp resolve_agent_id(_client, id) when is_integer(id), do: {:ok, id}

  defp resolve_agent_id(client, name) when is_binary(name) do
    case get_agent(client, name) do
      {:ok, %AgentResponse{id: id}} -> {:ok, id}
      {:error, _} = error -> error
    end
  end

  defp get(client, path) do
    case Req.get(client.base_url <> path, headers: auth_headers(client)) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post(client, path, body) do
    case Req.post(client.base_url <> path, json: body, headers: auth_headers(client)) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put(client, path, body) do
    case Req.put(client.base_url <> path, json: body, headers: auth_headers(client)) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete(client, path) do
    case Req.delete(client.base_url <> path, headers: auth_headers(client)) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp auth_headers(client) do
    [{"authorization", "Bearer #{client.api_key}"}]
  end

  defp agent_body(%NornsSdk.Agent{} = agent) do
    %{
      "name" => agent.name,
      "system_prompt" => agent.system_prompt,
      "status" => "idle",
      "model" => agent.model,
      "max_steps" => agent.max_steps,
      "model_config" => %{
        "mode" => to_string(agent.mode),
        "checkpoint_policy" => to_string(agent.checkpoint_policy),
        "context_strategy" => to_string(agent.context_strategy),
        "context_window" => agent.context_window,
        "on_failure" => to_string(agent.on_failure),
        "context_policy" => NornsSdk.Agent.context_policy(agent)
      }
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
