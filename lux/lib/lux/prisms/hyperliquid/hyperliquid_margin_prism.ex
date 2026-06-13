defmodule Lux.Prisms.Hyperliquid.HyperliquidMarginPrism do
  @moduledoc """
  A prism that manages margin on Hyperliquid positions.

  ## Example

      iex> Lux.Prisms.Hyperliquid.HyperliquidMarginPrism.run(%{
      ...>   coin: "ETH",
      ...>   amount: 100.0,
      ...>   is_buy: true
      ...> })
      {:ok, %{status: "success", margin_result: %{}}}
  """

  use Lux.Prism,
    name: "Hyperliquid Margin Management",
    description: "Adds or removes margin from Hyperliquid positions",
    input_schema: %{
      type: :object,
      properties: %{
        coin: %{type: :string, description: "Trading pair symbol"},
        amount: %{type: :number, description: "Margin amount in USD (positive to add, negative to remove)"},
        is_buy: %{type: :boolean, description: "True for long position, false for short"}
      },
      required: ["coin", "amount", "is_buy"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        status: %{type: :string},
        margin_result: %{type: :object}
      },
      required: ["status", "margin_result"]
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
         {:ok, result} <- update_margin(private_key, address, api_url, input) do
      {:ok, %{status: "success", margin_result: result}}
    else
      {:error, :missing_private_key} -> {:error, "Hyperliquid account private key is not configured"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_private_key do
    {:ok, Config.hyperliquid_account_key()}
  rescue
    RuntimeError -> {:error, :missing_private_key}
  end

  defp update_margin(private_key, address, api_url, params) do
    python_result =
      python variables: %{private_key: private_key, address: address, api_url: api_url, params: params} do
        ~PY"""
        from hyperliquid.exchange import Exchange
        from hyperliquid_utils.setup import setup

        address, info, exchange = setup(private_key, address, api_url, skip_ws=True)
        result = exchange.update_isolated_margin(
          params["amount"],
          params["is_buy"],
          params["coin"]
        )
        result
        """
      end

    case python_result do
      %{"error" => error} -> {:error, error}
      result when is_map(result) -> {:ok, result}
    end
  end
end
