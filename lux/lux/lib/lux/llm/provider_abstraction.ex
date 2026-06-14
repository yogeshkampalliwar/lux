defmodule Lux.LLM.ProviderAbstraction do
  @moduledoc """
  Universal LLM Provider Abstraction Layer.
  
  Supports OpenAI, Anthropic, Ollama, OpenRouter with:
  - Automatic model selection
  - Smart fallback handling  
  - Cost tracking and optimization
  - Performance monitoring

  ## Example

      iex> Lux.LLM.ProviderAbstraction.call("Hello!", [], %{
      ...>   provider: :auto,
      ...>   max_cost_per_1k: 0.001,
      ...>   task_type: :chat
      ...> })
  """

  @behaviour Lux.LLM

  alias Lux.LLM.OpenAI
  alias Lux.LLM.Anthropic

  require Logger

  @providers %{
    openai: %{
      models: %{
        "gpt-4o" => %{cost_input: 0.005, cost_output: 0.015, context: 128_000, tasks: [:chat, :vision]},
        "gpt-4o-mini" => %{cost_input: 0.00015, cost_output: 0.0006, context: 128_000, tasks: [:chat, :vision]},
        "gpt-3.5-turbo" => %{cost_input: 0.0005, cost_output: 0.0015, context: 16_385, tasks: [:chat]},
        "text-embedding-3-large" => %{cost_input: 0.00013, cost_output: 0.0, context: 8_191, tasks: [:embedding]}
      }
    },
    anthropic: %{
      models: %{
        "claude-opus-4-5" => %{cost_input: 0.015, cost_output: 0.075, context: 200_000, tasks: [:chat, :vision]},
        "claude-sonnet-4-5" => %{cost_input: 0.003, cost_output: 0.015, context: 200_000, tasks: [:chat, :vision]},
        "claude-haiku-4-5" => %{cost_input: 0.00025, cost_output: 0.00125, context: 200_000, tasks: [:chat, :vision]}
      }
    },
    ollama: %{
      models: %{
        "llama3.2" => %{cost_input: 0.0, cost_output: 0.0, context: 128_000, tasks: [:chat]},
        "mistral" => %{cost_input: 0.0, cost_output: 0.0, context: 32_000, tasks: [:chat]},
        "codellama" => %{cost_input: 0.0, cost_output: 0.0, context: 16_000, tasks: [:chat]},
        "nomic-embed-text" => %{cost_input: 0.0, cost_output: 0.0, context: 8_192, tasks: [:embedding]}
      }
    },
    openrouter: %{
      models: %{
        "meta-llama/llama-3.1-8b-instruct:free" => %{cost_input: 0.0, cost_output: 0.0, context: 131_072, tasks: [:chat]},
        "google/gemini-flash-1.5" => %{cost_input: 0.000075, cost_output: 0.0003, context: 1_000_000, tasks: [:chat, :vision]},
        "anthropic/claude-3.5-sonnet" => %{cost_input: 0.003, cost_output: 0.015, context: 200_000, tasks: [:chat, :vision]},
        "openai/gpt-4o-mini" => %{cost_input: 0.00015, cost_output: 0.0006, context: 128_000, tasks: [:chat, :vision]}
      }
    }
  }

  @fallback_order [:ollama, :openrouter, :anthropic, :openai]

  @impl true
  def call(prompt, tools, config) do
    provider = Map.get(config, :provider, :auto)
    task_type = Map.get(config, :task_type, :chat)
    max_cost = Map.get(config, :max_cost_per_1k, 999.0)
    min_context = Map.get(config, :min_context, 0)
    max_retries = Map.get(config, :max_retries, 3)

    start_time = System.monotonic_time(:millisecond)

    result = case provider do
      :auto -> auto_select_and_call(prompt, tools, config, task_type, max_cost, min_context, max_retries)
      p when is_atom(p) -> call_provider(p, prompt, tools, config)
      _ -> {:error, "Invalid provider: #{inspect(provider)}"}
    end

    latency = System.monotonic_time(:millisecond) - start_time
    log_metrics(provider, latency, result)
    result
  end

  def list_providers do
    Enum.map(@providers, fn {key, provider} ->
      %{
        id: key,
        model_count: map_size(provider.models),
        models: Map.keys(provider.models),
        has_free_models: Enum.any?(provider.models, fn {_, m} -> m.cost_input == 0.0 end)
      }
    end)
  end

  def select_provider(criteria \\ %{}) do
    task_type = Map.get(criteria, :task_type, :chat)
    max_cost = Map.get(criteria, :max_cost_per_1k, 999.0)
    min_context = Map.get(criteria, :min_context, 0)
    preferred = Map.get(criteria, :preferred_provider)

    candidates = @providers
    |> Enum.flat_map(fn {provider_key, provider} ->
      provider.models
      |> Enum.filter(fn {_, model} ->
        model.cost_input <= max_cost and
        model.context >= min_context and
        task_type in model.tasks
      end)
      |> Enum.map(fn {model_name, model} ->
        %{
          provider: provider_key,
          model: model_name,
          cost_input: model.cost_input,
          cost_output: model.cost_output,
          context_window: model.context,
          score: score_provider(provider_key, model, preferred)
        }
      end)
    end)
    |> Enum.sort_by(& &1.score, :desc)

    case candidates do
      [] -> {:error, "No provider matches criteria"}
      [best | rest] -> {:ok, %{best: best, alternatives: Enum.take(rest, 3)}}
    end
  end

  def estimate_cost(prompt, provider, model_name) do
    token_count = div(String.length(prompt), 4)
    with {:ok, provider_config} <- Map.fetch(@providers, provider),
         {:ok, model} <- Map.fetch(provider_config.models, model_name) do
      cost = token_count / 1000 * model.cost_input
      {:ok, %{
        token_estimate: token_count,
        estimated_cost_usd: Float.round(cost, 8),
        provider: provider,
        model: model_name
      }}
    else
      :error -> {:error, "Provider or model not found"}
    end
  end

  defp auto_select_and_call(prompt, tools, config, task_type, max_cost, min_context, max_retries) do
    preferred = Map.get(config, :preferred_provider)
    order = if preferred, do: [preferred | @fallback_order -- [preferred]], else: @fallback_order
    try_providers_with_fallback(order, prompt, tools, config, task_type, max_cost, min_context, max_retries, 0)
  end

  defp try_providers_with_fallback([], _prompt, _tools, _config, _task, _cost, _ctx, _max, retries) do
    {:error, "All #{retries} providers failed"}
  end

  defp try_providers_with_fallback([provider | rest], prompt, tools, config, task_type, max_cost, min_context, max_retries, retries) do
    if retries >= max_retries do
      {:error, "Max retries (#{max_retries}) exceeded"}
    else
      case find_best_model(provider, task_type, max_cost, min_context) do
        {:ok, model_name} ->
          provider_config = Map.merge(config, %{model: model_name})
          case call_provider(provider, prompt, tools, provider_config) do
            {:ok, _} = success ->
              Logger.info("Successfully called #{provider} with #{model_name}")
              success
            {:error, reason} ->
              Logger.warning("Provider #{provider} failed: #{reason}, trying fallback...")
              try_providers_with_fallback(rest, prompt, tools, config, task_type, max_cost, min_context, max_retries, retries + 1)
          end
        {:error, _} ->
          try_providers_with_fallback(rest, prompt, tools, config, task_type, max_cost, min_context, max_retries, retries + 1)
      end
    end
  end

  defp find_best_model(provider, task_type, max_cost, min_context) do
    case Map.get(@providers, provider) do
      nil -> {:error, "Unknown provider: #{provider}"}
      provider_config ->
        best = provider_config.models
        |> Enum.filter(fn {_, m} ->
          m.cost_input <= max_cost and
          m.context >= min_context and
          task_type in m.tasks
        end)
        |> Enum.sort_by(fn {_, m} -> m.cost_input end)
        |> List.first()

        case best do
          nil -> {:error, "No suitable model"}
          {model_name, _} -> {:ok, model_name}
        end
    end
  end

  defp call_provider(:openai, prompt, tools, config) do
    OpenAI.call(prompt, tools, config)
  end

  defp call_provider(:anthropic, prompt, tools, config) do
    Anthropic.call(prompt, tools, config)
  end

  defp call_provider(:ollama, prompt, tools, config) do
    ollama_config = Map.merge(config, %{
      endpoint: "http://localhost:11434/api/chat"
    })
    OpenAI.call(prompt, tools, ollama_config)
  end

  defp call_provider(:openrouter, prompt, tools, config) do
    openrouter_config = Map.merge(config, %{
      endpoint: "https://openrouter.ai/api/v1/chat/completions",
      api_key: Application.get_env(:lux, :api_keys)[:openrouter]
    })
    OpenAI.call(prompt, tools, openrouter_config)
  end

  defp call_provider(provider, _prompt, _tools, _config) do
    {:error, "Unknown provider: #{inspect(provider)}"}
  end

  defp score_provider(provider_key, model, preferred) do
    cost_score = if model.cost_input == 0.0, do: 100.0, else: 1.0 / model.cost_input
    context_score = model.context / 10_000
    preferred_bonus = if provider_key == preferred, do: 1000.0, else: 0.0
    cost_score + context_score + preferred_bonus
  end

  defp log_metrics(provider, latency_ms, result) do
    status = if match?({:ok, _}, result), do: "success", else: "error"
    Logger.info("LLM call [provider=#{provider}] [latency=#{latency_ms}ms] [status=#{status}]")
  end
end
