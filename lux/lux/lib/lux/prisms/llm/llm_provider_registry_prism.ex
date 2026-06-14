defmodule Lux.Prisms.LLM.LLMProviderRegistryPrism do
  @moduledoc """
  A prism that manages a registry of LLM providers with automatic
  selection, fallback handling, and cost optimization.

  Supports: OpenAI, Anthropic (Claude), Ollama, OpenRouter

  ## Example

      iex> Lux.Prisms.LLM.LLMProviderRegistryPrism.handler(%{
      ...>   action: "list_providers"
      ...> }, %{})

      iex> Lux.Prisms.LLM.LLMProviderRegistryPrism.handler(%{
      ...>   action: "select_provider",
      ...>   criteria: %{max_cost_per_1k: 0.01, min_context: 8000}
      ...> }, %{})
  """

  use Lux.Prism,
    name: "LLM Provider Registry",
    description: "Manages multiple LLM providers with smart selection and fallback",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Action to perform",
          enum: ["list_providers", "select_provider", "get_provider_info", "check_health"]
        },
        criteria: %{
          type: :object,
          description: "Selection criteria for auto provider selection",
          properties: %{
            max_cost_per_1k: %{type: :number, description: "Max cost per 1K tokens in USD"},
            min_context: %{type: :integer, description: "Minimum context window size"},
            preferred_provider: %{type: :string, description: "Preferred provider name"},
            task_type: %{
              type: :string,
              description: "Task type: chat, completion, embedding, vision",
              enum: ["chat", "completion", "embedding", "vision"]
            }
          }
        },
        provider_name: %{type: :string, description: "Specific provider name for info/health check"}
      },
      required: ["action"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        providers: %{type: :array},
        selected_provider: %{type: :object},
        health_status: %{type: :object},
        status: %{type: :string}
      },
      required: ["status"]
    }

  require Logger

  # Real LLM Provider Registry with actual model specs
  @providers %{
    "openai" => %{
      name: "OpenAI",
      base_url: "https://api.openai.com/v1",
      models: %{
        "gpt-4o" => %{
          context_window: 128_000,
          cost_per_1k_input: 0.005,
          cost_per_1k_output: 0.015,
          supports: ["chat", "vision", "function_calling"],
          max_output: 16_384
        },
        "gpt-4o-mini" => %{
          context_window: 128_000,
          cost_per_1k_input: 0.00015,
          cost_per_1k_output: 0.0006,
          supports: ["chat", "vision", "function_calling"],
          max_output: 16_384
        },
        "gpt-3.5-turbo" => %{
          context_window: 16_385,
          cost_per_1k_input: 0.0005,
          cost_per_1k_output: 0.0015,
          supports: ["chat", "function_calling"],
          max_output: 4_096
        },
        "text-embedding-3-large" => %{
          context_window: 8_191,
          cost_per_1k_input: 0.00013,
          cost_per_1k_output: 0.0,
          supports: ["embedding"],
          max_output: 3_072
        }
      },
      health_endpoint: "/models",
      auth_header: "Authorization",
      auth_prefix: "Bearer"
    },
    "anthropic" => %{
      name: "Anthropic",
      base_url: "https://api.anthropic.com/v1",
      models: %{
        "claude-opus-4-5" => %{
          context_window: 200_000,
          cost_per_1k_input: 0.015,
          cost_per_1k_output: 0.075,
          supports: ["chat", "vision", "function_calling"],
          max_output: 8_192
        },
        "claude-sonnet-4-5" => %{
          context_window: 200_000,
          cost_per_1k_input: 0.003,
          cost_per_1k_output: 0.015,
          supports: ["chat", "vision", "function_calling"],
          max_output: 8_192
        },
        "claude-haiku-4-5" => %{
          context_window: 200_000,
          cost_per_1k_input: 0.00025,
          cost_per_1k_output: 0.00125,
          supports: ["chat", "vision"],
          max_output: 4_096
        }
      },
      health_endpoint: "/models",
      auth_header: "x-api-key",
      auth_prefix: ""
    },
    "ollama" => %{
      name: "Ollama",
      base_url: "http://localhost:11434/api",
      models: %{
        "llama3.2" => %{
          context_window: 128_000,
          cost_per_1k_input: 0.0,
          cost_per_1k_output: 0.0,
          supports: ["chat", "completion"],
          max_output: 4_096
        },
        "mistral" => %{
          context_window: 32_000,
          cost_per_1k_input: 0.0,
          cost_per_1k_output: 0.0,
          supports: ["chat", "completion"],
          max_output: 4_096
        },
        "codellama" => %{
          context_window: 16_000,
          cost_per_1k_input: 0.0,
          cost_per_1k_output: 0.0,
          supports: ["chat", "completion"],
          max_output: 4_096
        },
        "nomic-embed-text" => %{
          context_window: 8_192,
          cost_per_1k_input: 0.0,
          cost_per_1k_output: 0.0,
          supports: ["embedding"],
          max_output: 768
        }
      },
      health_endpoint: "/tags",
      auth_header: nil,
      auth_prefix: nil
    },
    "openrouter" => %{
      name: "OpenRouter",
      base_url: "https://openrouter.ai/api/v1",
      models: %{
        "meta-llama/llama-3.1-8b-instruct:free" => %{
          context_window: 131_072,
          cost_per_1k_input: 0.0,
          cost_per_1k_output: 0.0,
          supports: ["chat"],
          max_output: 4_096
        },
        "google/gemini-flash-1.5" => %{
          context_window: 1_000_000,
          cost_per_1k_input: 0.000075,
          cost_per_1k_output: 0.0003,
          supports: ["chat", "vision"],
          max_output: 8_192
        },
        "anthropic/claude-3.5-sonnet" => %{
          context_window: 200_000,
          cost_per_1k_input: 0.003,
          cost_per_1k_output: 0.015,
          supports: ["chat", "vision", "function_calling"],
          max_output: 8_192
        },
        "openai/gpt-4o-mini" => %{
          context_window: 128_000,
          cost_per_1k_input: 0.00015,
          cost_per_1k_output: 0.0006,
          supports: ["chat", "vision"],
          max_output: 16_384
        }
      },
      health_endpoint: "/models",
      auth_header: "Authorization",
      auth_prefix: "Bearer"
    }
  }

  def handler(input, _ctx) do
    case input.action do
      "list_providers" -> list_providers()
      "select_provider" -> select_provider(Map.get(input, :criteria, %{}))
      "get_provider_info" -> get_provider_info(Map.get(input, :provider_name))
      "check_health" -> check_health(Map.get(input, :provider_name))
      _ -> {:error, "Unknown action: #{input.action}"}
    end
  end

  defp list_providers do
    providers = Enum.map(@providers, fn {key, provider} ->
      %{
        id: key,
        name: provider.name,
        model_count: map_size(provider.models),
        models: Map.keys(provider.models),
        base_url: provider.base_url,
        is_free: key == "ollama"
      }
    end)

    {:ok, %{providers: providers, total: length(providers), status: "success"}}
  end

  defp select_provider(criteria) do
    max_cost = Map.get(criteria, :max_cost_per_1k, 999.0)
    min_context = Map.get(criteria, :min_context, 0)
    task_type = Map.get(criteria, :task_type, "chat")
    preferred = Map.get(criteria, :preferred_provider)

    scored = @providers
    |> Enum.flat_map(fn {provider_key, provider} ->
      provider.models
      |> Enum.filter(fn {_model_key, model} ->
        model.cost_per_1k_input <= max_cost and
        model.context_window >= min_context and
        task_type in model.supports
      end)
      |> Enum.map(fn {model_key, model} ->
        score = calculate_score(provider_key, model, preferred)
        %{
          provider: provider_key,
          provider_name: provider.name,
          model: model_key,
          context_window: model.context_window,
          cost_per_1k_input: model.cost_per_1k_input,
          cost_per_1k_output: model.cost_per_1k_output,
          supports: model.supports,
          score: score,
          base_url: provider.base_url
        }
      end)
    end)
    |> Enum.sort_by(& &1.score, :desc)

    case scored do
      [] ->
        {:error, "No provider matches the given criteria"}
      [best | alternatives] ->
        {:ok, %{
          selected_provider: best,
          alternatives: Enum.take(alternatives, 3),
          criteria_used: criteria,
          status: "success"
        }}
    end
  end

  defp calculate_score(provider_key, model, preferred) do
    # Higher score = better choice
    cost_score = if model.cost_per_1k_input == 0.0, do: 100, else: 50 / model.cost_per_1k_input
    context_score = model.context_window / 1000
    preferred_bonus = if provider_key == preferred, do: 1000, else: 0

    cost_score + context_score + preferred_bonus
  end

  defp get_provider_info(nil), do: {:error, "provider_name is required"}
  defp get_provider_info(provider_name) do
    case Map.get(@providers, provider_name) do
      nil -> {:error, "Provider '#{provider_name}' not found. Available: #{Map.keys(@providers) |> Enum.join(", ")}"}
      provider ->
        {:ok, %{
          provider: provider_name,
          name: provider.name,
          base_url: provider.base_url,
          models: provider.models,
          model_count: map_size(provider.models),
          status: "success"
        }}
    end
  end

  defp check_health(provider_name) do
    providers_to_check = if provider_name, do: [provider_name], else: Map.keys(@providers)

    health = Enum.map(providers_to_check, fn name ->
      provider = Map.get(@providers, name)
      if provider do
        url = provider.base_url <> provider.health_endpoint
        start = System.monotonic_time(:millisecond)
        result = check_provider_health(url)
        latency = System.monotonic_time(:millisecond) - start

        {name, %{
          status: if(result == :ok, do: "healthy", else: "unreachable"),
          latency_ms: latency,
          url: url
        }}
      else
        {name, %{status: "unknown", error: "Provider not found"}}
      end
    end)
    |> Map.new()

    {:ok, %{health_status: health, checked_at: DateTime.utc_now() |> DateTime.to_iso8601(), status: "success"}}
  end

  defp check_provider_health(url) do
    case Req.get(url, receive_timeout: 5000) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
