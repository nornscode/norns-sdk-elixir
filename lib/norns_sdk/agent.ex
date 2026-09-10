defmodule NornsSdk.Agent do
  @moduledoc """
  Declarative agent definition.

  ## Usage

      agent = NornsSdk.Agent.new(
        name: "support-bot",
        model: "claude-sonnet-5",
        system_prompt: "You are a customer support agent.",
        tools: [MyTools.SearchDocs, MyTools.SendEmail],
        mode: :conversation,
        on_failure: :retry_last_step
      )
  """

  @enforce_keys [:name]
  defstruct [
    :name,
    model: "claude-sonnet-5",
    system_prompt: "",
    tools: [],
    mode: :task,
    checkpoint_policy: :on_tool_call,
    context_strategy: :sliding_window,
    context_window: 20,
    max_steps: 50,
    on_failure: :retry_last_step,
    # %{compact_at: input_tokens, keep: messages}: fold older history into a
    # summary once a response reports compact_at tokens. Pair it with
    # context_strategy: :none; the summarisation is served by this worker.
    context_policy: nil
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          model: String.t(),
          system_prompt: String.t(),
          tools: [module()],
          mode: :task | :conversation,
          checkpoint_policy: :every_step | :on_tool_call | :manual,
          context_strategy: :sliding_window | :none,
          context_window: pos_integer(),
          max_steps: pos_integer(),
          on_failure: :stop | :retry_last_step,
          context_policy: nil | %{compact_at: pos_integer(), keep: pos_integer()}
        }

  def new(opts) when is_list(opts) do
    struct!(__MODULE__, opts)
  end

  def to_registration(%__MODULE__{} = agent) do
    %{
      "name" => agent.name,
      "model" => agent.model,
      "system_prompt" => agent.system_prompt,
      "mode" => Atom.to_string(agent.mode),
      "checkpoint_policy" => Atom.to_string(agent.checkpoint_policy),
      "context_strategy" => Atom.to_string(agent.context_strategy),
      "context_window" => agent.context_window,
      "max_steps" => agent.max_steps,
      "on_failure" => Atom.to_string(agent.on_failure),
      "context_policy" => context_policy(agent),
      "tools" => Enum.map(agent.tools, fn mod -> mod.__tool_name__() end)
    }
  end

  @doc false
  def context_policy(%__MODULE__{context_policy: %{compact_at: at} = policy}),
    do: %{"compact_at" => at, "keep" => Map.get(policy, :keep, 20)}

  def context_policy(_agent), do: nil
end
