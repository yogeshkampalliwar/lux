defmodule Lux.Prisms.LLM.LLMProviderSelectorPrism do
  @moduledoc """
  A prism for intelligent LLM provider selection with automatic
  fallback handling and cost optimization.

  ## Example

      iex> Lux.Prisms.LLM.LLMProviderSelectorPrism.handler(%{
      ...>   prompt: "Hello world",
      ...>   max_cost_per_1k: 0.001,
      ...>   task_type: "chat"
      ...> }, %{})
  """

  use Lux.Prism,
    name: "LLM Provider Selector",
    description: "Intelligently selects LLM provider with fallback and cost optimization",
    input_schema: %{
      type: :object,
      properties: %{
        prompt: %{type: :string, description: "The prompt to send"},
        task_type: %{type: :string, enum: ["chat", "embedding", "vision"], default: "chat"},
        max_cost_per_1k: %{type: :number, description: "Max cost per 1K tokens"},
        min_context: %{type: :integer, description: "Minimum context window"},
        preferred_provider: %{type: :string, description: "Preferred provider"},
        fallback_providers: %{type: :array, description: "Fallback provider list"},
        max_retries: %{type: :integer, default: 3}
      },
      required: ["prompt"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        provider_used: %{type: :string},
        model_used: %{type: :string},
        estimated_cost: %{type: :number},
        fallbacks_tried: %{type: :integer},
        status: %{type: :string}
      },
      required: ["status"]
    }

  require Logger

  @provider_priority ["ollama", "openrouter", "anthropic", "openai"]

  def handler(input, _ctx) do
    input = Map.put_new(input, :task_type, "chat")
    input = Map.put_new(input, :max_retries, 3)
    input = Map.put_new(input, :max_cost_per_1k, 999.0)
    input = Map.put_new(input, :min_context, 0)

    Logger.info("Selecting LLM provider for task: #{input.task_type}")

    priority_list = build_priority_list(input)
    try_providers(priority_list, input, 0)
  end

  defp build_priority_list(input) do
    preferred = Map.get(input, :preferred_provider)
    fallbacks = Map.get(input, :fallback_providers, [])

    cond do
      preferred && length(fallbacks) > 0 ->
        [preferred | fallbacks]
      preferred ->
        [preferred | @provider_priority -- [preferred]]
      length(fallbacks) > 0 ->
        fallbacks ++ (@provider_priority -- fallbacks)
      true ->
        @provider_priority
    end
  end

  defp try_providers([], _input, retries) do
    {:error, "All providers failed after #{retries} attempts"}
  end

  defp try_providers([provider | rest], input, retries) do
    Logger.info("Trying provider: #{provider}")

    case select_best_model(provider, input) do
      {:ok, model, estimated_cost} ->
        {:ok, %{
          provider_used: provider,
          model_used: model,
          estimated_cost: estimated_cost,
          fallbacks_tried: retries,
          task_type: input.task_type,
          status: "success"
        }}
      {:error, reason} ->
        Logger.warning("Provider #{provider} failed: #{reason}, trying next...")
        try_providers(rest, input, retries + 1)
    end
  end

  defp select_best_model(provider, input) do
    models = get_provider_models(provider)

    suitable = models
    |> Enum.filter(fn {_name, specs} ->
      specs.cost_per_1k_input <= input.max_cost_per_1k and
      specs.context_window >= input.min_context and
      input.task_type in specs.supports
    end)
    |> Enum.sort_by(fn {_name, specs} -> specs.cost_per_1k_input end)

    case suitable do
      [] -> {:error, "No suitable model found for #{provider}"}
      [{model_name, specs} | _] ->
        token_estimate = div(String.length(input.prompt), 4)
        estimated_cost = token_estimate / 1000 * specs.cost_per_1k_input
        {:ok, model_name, Float.round(estimated_cost, 6)}
    end
  end

  defp get_provider_models("openai") do
    %{
      "gpt-4o-mini" => %{context_window: 128_000, cost_per_1k_input: 0.00015, supports: ["chat", "vision"]},
      "gpt-4o" => %{context_window: 128_000, cost_per_1k_input: 0.005, supports: ["chat", "vision"]},
      "gpt-3.5-turbo" => %{context_window: 16_385, cost_per_1k_input: 0.0005, supports: ["chat"]},
      "text-embedding-3-large" => %{context_window: 8_191, cost_per_1k_input: 0.00013, supports: ["embedding"]}
    }
  end

  defp get_provider_models("anthropic") do
    %{
      "claude-haiku-4-5" => %{context_window: 200_000, cost_per_1k_input: 0.00025, supports: ["chat", "vision"]},
      "claude-sonnet-4-5" => %{context_window: 200_000, cost_per_1k_input: 0.003, supports: ["chat", "vision"]},
      "claude-opus-4-5" => %{context_window: 200_000, cost_per_1k_input: 0.015, supports: ["chat", "vision"]}
    }
  end

  defp get_provider_models("ollama") do
    %{
      "llama3.2" => %{context_window: 128_000, cost_per_1k_input: 0.0, supports: ["chat", "completion"]},
      "mistral" => %{context_window: 32_000, cost_per_1k_input: 0.0, supports: ["chat", "completion"]},
      "codellama" => %{context_window: 16_000, cost_per_1k_input: 0.0, supports: ["chat", "completion"]},
      "nomic-embed-text" => %{context_window: 8_192, cost_per_1k_input: 0.0, supports: ["embedding"]}
    }
  end

  defp get_provider_models("openrouter") do
    %{
      "meta-llama/llama-3.1-8b-instruct:free" => %{context_window: 131_072, cost_per_1k_input: 0.0, supports: ["chat"]},
      "google/gemini-flash-1.5" => %{context_window: 1_000_000, cost_per_1k_input: 0.000075, supports: ["chat", "vision"]},
      "anthropic/claude-3.5-sonnet" => %{context_window: 200_000, cost_per_1k_input: 0.003, supports: ["chat", "vision"]},
      "openai/gpt-4o-mini" => %{context_window: 128_000, cost_per_1k_input: 0.00015, supports: ["chat", "vision"]}
    }
  end

  defp get_provider_models(_), do: %{}
end
