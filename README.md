# NornsSdk

[![CI](https://github.com/nornscode/norns-sdk-elixir/actions/workflows/ci.yml/badge.svg)](https://github.com/nornscode/norns-sdk-elixir/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Hex.pm](https://img.shields.io/hexpm/v/norns_sdk.svg)](https://hex.pm/packages/norns_sdk)

Elixir SDK for [Norns](https://github.com/nornscode/norns). Define agents and tools, connect as a worker, or send messages as a client.

## Install

```elixir
{:norns_sdk, "~> 0.3"}
```

## Quickstart

1. Start Norns locally (`docker compose up` in the Norns repo).
2. Set `NORNS_API_KEY` and `ANTHROPIC_API_KEY` in your environment.
3. Add the worker to your supervision tree.
4. Send messages with `NornsSdk.Client.send_message/4`.

## Worker

```elixir
defmodule MyTools.SearchDocs do
  use NornsSdk.Tool,
    name: "search_docs",
    description: "Search product documentation"

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{"query" => %{"type" => "string"}},
      "required" => ["query"]
    }
  end

  @impl true
  def execute(%{"query" => query}) do
    results = MyApp.Docs.search(query)
    {:ok, results}
  end
end

agent = NornsSdk.Agent.new(
  name: "support-bot",
  model: "claude-sonnet-5",
  system_prompt: "You are a customer support agent.",
  tools: [MyTools.SearchDocs],
  mode: :conversation
)

children = [
  {NornsSdk.Worker,
   url: "http://localhost:4000",
   api_key: System.get_env("NORNS_API_KEY"),
   llm_api_key: System.get_env("ANTHROPIC_API_KEY"),
   agent: agent}
]
```

The worker connects via WebSocket, registers the agent and tools, and handles LLM + tool tasks from the orchestrator. Reconnects automatically.

## Client

```elixir
client = NornsSdk.Client.new("http://localhost:4000", api_key: "nrn_...")

# Fire and forget
{:ok, %{run_id: 42}} = NornsSdk.Client.send_message(client, "support-bot", "Hello!")

# Block until completion
{:ok, result} = NornsSdk.Client.send_message(client, "support-bot", "Hello!", wait: true)
IO.puts(result.output)

# With conversation key
{:ok, result} = NornsSdk.Client.send_message(client, "support-bot", "Follow up",
  conversation_key: "slack:U01ABC", wait: true)

# Inspect runs — reads return typed structs (access fields with dot syntax)
{:ok, run} = NornsSdk.Client.get_run(client, 42)
run.status   # "completed"
{:ok, events} = NornsSdk.Client.get_events(client, 42)
```

## Human-in-the-loop

An agent can call the built-in `ask_human` tool to pause and ask a question.
The run parks with status `"waiting"` until someone answers, and survives a
restart while parked.

```elixir
{:ok, result} = NornsSdk.Client.send_message(client, "support-bot", "Book me a table", wait: true)

if NornsSdk.MessageResult.waiting?(result) do
  IO.puts(result.waiting_for.question)   # "7pm or 8pm?"
  :ok = NornsSdk.Client.reply(client, result.run_id, "7pm")
end
```

`wait: true` returns as soon as the agent parks — it's waiting on you, so it
won't progress on its own. Sending the agent another message with
`send_message/4` answers the question too, which is usually what a chat or
Slack client wants; `reply/3` targets one specific run.

## Streaming

`stream/4` sends a message and forwards the run's events to a subscriber process
as they happen. This is the idiomatic Elixir shape — events arrive in your
mailbox, so it drops straight into a `GenServer` or `LiveView` `handle_info/2`.

```elixir
{:ok, _stream_pid} = NornsSdk.Client.stream(client, "support-bot", "Research quantum computing")

# Events arrive as {:norns_event, stream_pid, %NornsSdk.StreamEvent{}}.
# The terminal events are "completed" and "error".
receive do
  {:norns_event, _pid, %NornsSdk.StreamEvent{type: "completed"} = ev} ->
    IO.puts(ev.data["output"])

  {:norns_event, _pid, %NornsSdk.StreamEvent{type: type, data: data}} ->
    IO.inspect({type, data}, label: "event")

  {:norns_closed, _pid, reason} ->
    # Socket closed before a terminal event (disconnect / timeout).
    IO.inspect(reason, label: "stream closed")
end
```

Pass `subscriber: pid` to deliver events to a process other than the caller.

## Docs

- [Release checklist](docs/release-v0.1-checklist.md)
- [Changelog](CHANGELOG.md)

## License

MIT
