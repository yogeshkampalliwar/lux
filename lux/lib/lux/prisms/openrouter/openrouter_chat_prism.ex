defmodule Lux.Prisms.OpenRouter.OpenRouterChatPrism do
  @moduledoc """
  A prism that sends chat completion requests to OpenRouter API.

  ## Example

      iex> Lux.Prisms.OpenRouter.OpenRouterChatPrism.run(%{
      ...>   model: "openai/gpt-4",
      ...>   messages: [%{role: "user", content: "Hello!"}],
      ...>   temperature: 0.7
      ...> })
      {:ok, %{status: "success", content: "Hello! How can I help?", model: "openai/gpt-4"}}
  """

  use Lux.Prism,
    name: "OpenRouter Chat Completion",
    description: "Sends chat completion requests via OpenRouter API supporting 200+ LLM models",
    input_schema: %{
      type: :object,
      properties: %{
        model: %{
          type: :string,
          description: "Model ID e.g. openai/gpt-4, anthropic/claude-3-opus, mistralai/mixtral-8x7b"
        },
        messages: %{
          type: :array,
          description: "Chat messages array",
          items: %{
            type: :object,
            properties: %{
              role: %{type: :string, enum: ["system", "user", "assistant"]},
              content: %{type: :string}
            },
            required: ["role", "content"]
          }
        },
        temperature: %{
          type: :number,
          description: "Sampling temperature 0.0-2.0",
          default: 0.7
        },
        max_tokens: %{
          type: :integer,
          description: "Maximum tokens to generate",
          default: 1000
        }
      },
      required: ["model", "messages"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        status: %{type: :string},
        content: %{type: :string},
        model: %{type: :string},
        usage: %{type: :object}
      },
      required: ["status", "content"]
    }

  alias Lux.Config

  def handler(input, _ctx) do
    model       = input[:model]       || input["model"]
    messages    = input[:messages]    || input["messages"]
    temperature = input[:temperature] || input["temperature"] || 0.7
    max_tokens  = input[:max_tokens]  || input["max_tokens"]  || 1000

    with {:ok, api_key} <- get_api_key(),
         {:ok, result}  <- call_openrouter(api_key, model, messages, temperature, max_tokens) do
      {:ok, result}
    else
      {:error, :missing_key} ->
        {:error, "OpenRouter API key not configured"}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_api_key do
    key = Config.get(:openrouter_api_key) ||
          System.get_env("OPENROUTER_API_KEY")
    if key, do: {:ok, key}, else: {:error, :missing_key}
  rescue
    _ -> {:error, :missing_key}
  end

  defp call_openrouter(api_key, model, messages, temperature, max_tokens) do
    body = Jason.encode!(%{
      model: model,
      messages: messages,
      temperature: temperature,
      max_tokens: max_tokens
    })

    case Req.post("https://openrouter.ai/api/v1/chat/completions",
      headers: [
        {"Authorization", "Bearer #{api_key}"},
        {"Content-Type", "application/json"},
        {"HTTP-Referer", "https://github.com/Spectral-Finance/lux"},
        {"X-Title", "Lux Framework"}
      ],
      body: body
    ) do
      {:ok, %{status: 200, body: body}} ->
        content = get_in(body, ["choices", Access.at(0), "message", "content"])
        usage   = body["usage"] || %{}
        {:ok, %{
          status:  "success",
          content: content || "",
          model:   body["model"] || model,
          usage:   usage
        }}
      {:ok, %{status: status, body: body}} ->
        {:error, "OpenRouter error #{status}: #{inspect(body)}"}
      {:error, reason} ->
        {:error, "HTTP error: #{inspect(reason)}"}
    end
  end
end
