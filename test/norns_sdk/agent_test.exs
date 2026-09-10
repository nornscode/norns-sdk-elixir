defmodule NornsSdk.AgentTest do
  use ExUnit.Case, async: true

  alias NornsSdk.Agent

  test "new/1 creates agent with defaults" do
    agent = Agent.new(name: "test-bot")
    assert agent.name == "test-bot"
    assert agent.model == "claude-sonnet-5"
    assert agent.mode == :task
    assert agent.on_failure == :retry_last_step
    assert agent.max_steps == 50
    assert agent.tools == []
  end

  test "new/1 accepts all fields" do
    agent =
      Agent.new(
        name: "bot",
        model: "claude-haiku-4-5-20251001",
        system_prompt: "You are helpful.",
        mode: :conversation,
        checkpoint_policy: :every_step,
        context_window: 10,
        max_steps: 25,
        on_failure: :stop
      )

    assert agent.mode == :conversation
    assert agent.checkpoint_policy == :every_step
    assert agent.context_window == 10
    assert agent.max_steps == 25
    assert agent.on_failure == :stop
  end

  test "to_registration/1 produces wire format" do
    agent = Agent.new(name: "bot", mode: :conversation)
    reg = Agent.to_registration(agent)

    assert reg["name"] == "bot"
    assert reg["mode"] == "conversation"
    assert reg["on_failure"] == "retry_last_step"
    assert is_list(reg["tools"])
  end

  test "registers context_policy with a default keep" do
    agent = Agent.new(name: "a", context_policy: %{compact_at: 100_000}, context_strategy: :none)
    assert Agent.to_registration(agent)["context_policy"] == %{"compact_at" => 100_000, "keep" => 20}
    assert Agent.to_registration(Agent.new(name: "b"))["context_policy"] == nil
  end
end
