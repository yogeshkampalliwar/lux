defmodule Lux.Prisms.Hyperliquid.HyperliquidLeveragePrism do
  @moduledoc """
  A prism that sets leverage for a trading pair on Hyperliquid.

  ## Example

      iex> Lux.Prisms.Hyperliquid.HyperliquidLeveragePrism.run(%{
      ...>   coin: "ETH",
      ...>   leverage: 5,
      ...>   is_cross: true
      ...> })
      {:ok, %{status: "success", leverage_result: %{}}}
  """

  use Lux.Prism,
    name: "Hyperliquid Leverage Control",
    description: "Sets leverage for a trading pair on Hyperliquid",
    input_schema: %{
      type: :object,
      properties: %{
        coin: %{type: :string, description: "Trading pair symbol (e.g., 'ETH', 'BTC')"},
        leverage: %{type: :integer, description: "Leverage multiplier (1-100)", minimum: 1, maximum: 100},
        is_cross: %{type: :boolean, description: "True for cross margin, false for isolated", default: true}
      },
      required: ["coin", "leverage"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        status: %{type: :string},
        leverage_result: %{type: :object}
      },
      required: ["status", "leverage_result"]
    }

  import Lux.Python
  alias Lux.Config
  require Lux.Python

  def handler(input, _ctx) do
    with {:ok, private_key} <- get_private_key(),
         {:ok, address} <- {:ok, Config.hyperliquid_account_address()},
         {:ok, api_url} <- {:ok, Config.hyperliquid_api_url()},
         {:ok, %{"success" => true}} <- Lux.Python.import_package("hyperliquid.exchange"),
         {:ok, %{"success" => true}} <- Lux.Python.import_package("hyperliquid_utils.setup"),
         {:ok, result} <- set_leverage(private_key, address, api_url, input) do
      {:ok, %{status: "success", leverage_result: result}}
    else
      {:error, :missing_private_key} -> {:error, "Hyperliquid account private key is not configured"}
      {:error, :missing_api_url} -> {:error, "Hyperliquid API URL is not configured"}
      {:ok, %{"success" => false, "error" => error}} -> {:error, "Failed to import required packages: #{error}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_private_key do
    {:ok, Config.hyperliquid_account_key()}
  rescue
    RuntimeError -> {:error, :missing_private_key}
  end

  defp set_leverage(private_key, address, api_url, params) do
    python_result =
      python variables: %{private_key: private_key, address: address, api_url: api_url, params: params} do
        ~PY"""
        from hyperliquid.exchange import Exchange
        from hyperliquid_utils.setup import setup

        address, info, exchange = setup(private_key, address, api_url, skip_ws=True)
        is_cross = params.get("is_cross", True)
        result = exchange.update_leverage(params["leverage"], params["coin"], is_cross)
        result
        """
      end

    case python_result do
      %{"error" => error} -> {:error, error}
      result when is_map(result) -> {:ok, result}
    end
  end
end
