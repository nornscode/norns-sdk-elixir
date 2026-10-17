defmodule NornsSdk.HistoryTest do
  use ExUnit.Case, async: true

  alias NornsSdk.History

  defp user(content), do: %{"role" => "user", "content" => content}

  defp full(run_id, messages, extra \\ %{}),
    do: Map.merge(%{"task_id" => "t", "run_id" => run_id, "messages" => messages}, extra)

  defp delta(run_id, base_count, drop, append) do
    %{
      "task_id" => "t",
      "run_id" => run_id,
      "messages_delta" => %{"base_count" => base_count, "drop" => drop, "append" => append}
    }
  end

  test "remembers a full task and applies deltas to it" do
    {:ok, first, history} = History.resolve(full(1, [user("hi")]), History.new())
    assert first["messages"] == [user("hi")]

    {:ok, second, history} =
      History.resolve(delta(1, 1, 0, [%{"role" => "assistant", "content" => "yo"}]), history)

    assert second["messages"] == [user("hi"), %{"role" => "assistant", "content" => "yo"}]
    refute Map.has_key?(second, "messages_delta")
    assert second["task_id"] == "t"

    # A dropped prefix (compaction, a sliding window).
    {:ok, third, _history} = History.resolve(delta(1, 2, 1, [user("more")]), history)
    assert Enum.map(third["messages"], & &1["content"]) == ["yo", "more"]
  end

  test "misses on an unknown or wrong-sized base, without disturbing what is held" do
    assert :miss = History.resolve(delta(7, 1, 0, []), History.new())

    {:ok, _task, history} = History.resolve(full(7, [user("a"), user("b")]), History.new())
    assert :miss = History.resolve(delta(7, 1, 0, []), history)
    assert {:ok, %{"messages" => [_, _]}, _} = History.resolve(delta(7, 2, 0, []), history)
  end

  test "leaves the cache alone for compaction tasks" do
    {:ok, _task, history} = History.resolve(full(1, [user("a"), user("b")]), History.new())

    {:ok, compact, history} =
      History.resolve(full(1, [user("a")], %{"purpose" => "compact"}), history)

    assert compact["messages"] == [user("a")]
    assert {:ok, %{"messages" => [_, _]}, _} = History.resolve(delta(1, 2, 0, []), history)
  end

  test "evicts the run used longest ago first" do
    history =
      Enum.reduce(1..257, History.new(), fn run_id, history ->
        {:ok, _task, history} = History.resolve(full(run_id, [user("#{run_id}")]), history)
        history
      end)

    assert map_size(history.runs) == 256
    assert :miss = History.resolve(delta(1, 1, 0, []), history)
    assert {:ok, _, _} = History.resolve(delta(2, 1, 0, []), history)
    assert {:ok, _, _} = History.resolve(delta(257, 1, 0, []), history)
  end
end
