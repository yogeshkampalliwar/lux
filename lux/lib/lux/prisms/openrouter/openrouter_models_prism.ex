defmodule Lux.Prisms.OpenRouter.OpenRouterModelsPrism do
  @moduledoc """
  A prism that fetches available models from OpenRouter API.

  ## Example

      iex> Lux.Prisms.OpenRouter.OpenRouterModelsPrism.run(%{})
      {:ok, %{status: "success", models: [...], total: 200}}

      iex> Lux.Prisms.OpenRouter.OpenRouterModelsPrism.run(%{
      ...>   filter: "anthropic"
      ...> })
      {:ok, %{status: "success", models: [...], total: 5}}
  """

  use Lux.Prism,
    name: "OpenRouter Models List",
    description: "Fetches all available LLM models from OpenRouter with pricing info",
    input_schema: %{
      type: :object,
      properties: %{
        filter: %{
          type: :string,
          description: "Optional filter by provider e.g. openai, anthropic, mistralai"
        }
      }
    },
    output_schema: %{
      type: :object,
      properties: %{
        status: %{type: :string},
        models: %{type: :array},
        total: %{type: :integer}
      },
      required: ["status", "models", "total"]
    }

  alias Lux.Config

  def handler(input, _ctx) do
    filter = input[:filter] || input["filter"]

    with {:ok, api_key} <- get_api_key(),
         {:ok, models}  <- fetch_models(api_key, filter) do
      {:ok, %{
        status: "success",
        models: models,
        total:  length(models)
      }}
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

  defp fetch_models(api_key, filter) do
    case Req.get("https://openrouter.ai/api/v1/models",
      headers: [
        {"Authorization", "Bearer #{api_key}"},
        {"Content-Type", "application/json"}
      ]
    ) do
      {:ok, %{status: 200, body: body}} ->
        models = body["data"] || []
        filtered = if filter do
          Enum.filter(models, fn m ->
            String.contains?(
              String.downcase(m["id"] || ""),
              String.downcase(filter)
            )
          end)
        else
          models
        end
        result = Enum.map(filtered, fn m ->
          %{
            id:              m["id"],
            name:            m["name"],
            context_length:  m["context_length"],
            pricing:         m["pricing"]
          }
        end)
        {:ok, result}
      {:ok, %{status: status, body: body}} ->
        {:error, "OpenRouter error #{status}: #{inspect(body)}"}
      {:error, reason} ->
        {:error, "HTTP error: #{inspect(reason)}"}
    end
  end
end
