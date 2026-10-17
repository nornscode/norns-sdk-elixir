defmodule NornsSdk.History do
  @moduledoc """
  The message list Norns last sent this worker, per run.

  Once a worker joins with `features: ["message_cache"]`, Norns sends a run's
  later steps as the change since the last task on this connection:
  `messages_delta: %{base_count, drop, append}` — of the `base_count`
  messages held, drop the first `drop`, append the rest. A delta against a
  base this worker does not hold is a miss: the worker answers
  `message_cache_miss` and Norns resends the whole list at the same step.
  Bounded by run count; the run used longest ago goes first.
  """

  @max_runs 256

  @type t :: %{runs: %{optional(term()) => {non_neg_integer(), [map()]}}, tick: non_neg_integer()}

  @spec new() :: t()
  def new, do: %{runs: %{}, tick: 0}

  @doc "The task with `\"messages\"` filled in and the updated cache, or `:miss`."
  @spec resolve(map(), t()) :: {:ok, map(), t()} | :miss
  # A prefix to summarise, not the history; leaves the cache alone.
  def resolve(%{"purpose" => "compact"} = task, history), do: {:ok, task, history}

  def resolve(
        %{"messages_delta" => %{"base_count" => n, "drop" => d, "append" => append}} = task,
        history
      ) do
    case held(history, task["run_id"]) do
      previous when is_list(previous) and length(previous) == n ->
        messages = Enum.drop(previous, d) ++ append
        task = task |> Map.delete("messages_delta") |> Map.put("messages", messages)
        {:ok, task, remember(history, task["run_id"], messages)}

      _ ->
        :miss
    end
  end

  def resolve(%{"messages" => messages, "run_id" => run_id} = task, history)
      when is_list(messages) and not is_nil(run_id),
      do: {:ok, task, remember(history, run_id, messages)}

  def resolve(task, history), do: {:ok, task, history}

  defp held(%{runs: runs}, run_id) do
    case Map.get(runs, run_id) do
      {_tick, messages} -> messages
      nil -> nil
    end
  end

  defp remember(%{runs: runs, tick: tick}, run_id, messages) do
    runs = Map.put(runs, run_id, {tick, messages})
    runs = if map_size(runs) > @max_runs, do: evict_oldest(runs), else: runs
    %{runs: runs, tick: tick + 1}
  end

  defp evict_oldest(runs) do
    {oldest, _} = Enum.min_by(runs, fn {_run_id, {tick, _messages}} -> tick end)
    Map.delete(runs, oldest)
  end
end
